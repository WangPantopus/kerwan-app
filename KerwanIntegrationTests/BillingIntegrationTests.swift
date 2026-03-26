import XCTest
@testable import Kerwan

// MARK: - In-memory BillingEngine storage spy

/// Full ``BillingEngineStorage`` implementation that stores everything in memory
/// and exposes inserted sessions and narrative updates for assertion.
actor SpyBillingEngineStorage: BillingEngineStorage {

    private(set) var insertedSessions:  [WorkSession]                              = []
    private(set) var updatedNarratives: [(id: String, description: String?, invoiceText: String?)] = []
    var classifiedEvents: [ClassifiedEvent] = []

    func seed(events: [ClassifiedEvent]) {
        classifiedEvents = events
    }

    func listClassifiedEvents(since: Date) async throws -> [ClassifiedEvent] {
        classifiedEvents.filter { $0.startedAt >= since }
    }

    func insertWorkSession(_ session: WorkSession) async throws {
        insertedSessions.append(session)
    }

    func updateWorkSession(id: EntityID, description: String?, invoiceText: String?) async throws {
        updatedNarratives.append((id: id, description: description, invoiceText: invoiceText))
    }
}

// MARK: - WorkSessionExport (mirrors the private struct inside InvoiceExporter)

/// Mirrors the shape of `InvoiceExporter`'s private `WorkSessionExport` JSON output
/// so integration tests can decode and assert on the exported JSON structure.
private struct WorkSessionExport: Decodable {
    let id:             String
    let clientId:       String?
    let projectId:      String?
    let startedAt:      Date
    let endedAt:        Date
    let durationSecs:   Int
    let durationHours:  Double
    let billableStatus: String
    let description:    String?
    let invoiceText:    String?
    let reviewedAt:     Date?
}

// MARK: - BillingIntegrationTests

/// Integration tests for the billing pipeline:
///
/// 1. ``SessionClusteringEngine`` — pure clustering logic, no external dependencies.
/// 2. ``BillingEngine`` — clustering + narrative LLM call + storage writes.
/// 3. ``InvoiceExporter`` — CSV and JSON export from real ``WorkSession`` objects.
///
/// Ollama is mocked via ``IntegrationMockOllamaURLProtocol``. Storage is handled
/// by the in-memory ``SpyBillingEngineStorage``.
final class BillingIntegrationTests: XCTestCase {

    private var session:  URLSession!
    private var client:   OllamaClient!
    private var storage:  SpyBillingEngineStorage!
    private var engine:   BillingEngine!

    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        IntegrationMockOllamaURLProtocol.reset()
        session = IntegrationMockOllamaURLProtocol.makeSession()
        client  = OllamaClient(session: session)
        storage = SpyBillingEngineStorage()
        engine  = BillingEngine(client: client, storage: storage)
    }

    override func tearDown() {
        IntegrationMockOllamaURLProtocol.reset()
        engine  = nil
        storage = nil
        client  = nil
        session = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeEvent(
        id:           String  = UUID().uuidString,
        clientId:     String? = "client-A",
        start:        Date    = Date(),
        durationSecs: Int     = 1_800
    ) -> ClassifiedEvent {
        ClassifiedEvent(
            rawEventId:    id,
            clientId:      clientId,
            startedAt:     start,
            endedAt:       start.addingTimeInterval(Double(durationSecs)),
            durationSecs:  durationSecs,
            billableGuess: "yes",
            confidence:    0.9,
            source:        .audio
        )
    }

    private func registerNarrativeResponse(_ text: String) {
        let ndjson = #"{"response":"\#(text)","done":true}"#
        IntegrationMockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, Data(ndjson.utf8))
        }
    }

    // =========================================================================
    // MARK: - SessionClusteringEngine (pure unit-style integration tests)
    // =========================================================================

    /// Two events for the same client within 15 minutes must cluster into one session.
    func test_clustering_twoCloseEvents_sameClient_oneSession() {
        let events = [
            makeEvent(id: "e1", start: baseDate,                         durationSecs: 600),
            makeEvent(id: "e2", start: baseDate.addingTimeInterval(600), durationSecs: 600),
        ]
        let candidates = SessionClusteringEngine().cluster(events: events)
        XCTAssertEqual(candidates.count, 1,
                       "Two events within the idle gap must cluster into one session")
    }

    /// Two events for the same client separated by more than 15 minutes must
    /// produce two separate sessions.
    func test_clustering_twoFarEvents_sameClient_twoSessions() {
        // Gap (end-to-start) must exceed extendedGapThreshold (2700s/45 min) to force a hard split.
        // e1 ends at baseDate+600, e2 starts at baseDate+3400 → gap = 2800s > 2700s.
        let events = [
            makeEvent(id: "e1", start: baseDate,                              durationSecs: 600),
            makeEvent(id: "e2", start: baseDate.addingTimeInterval(3_400),    durationSecs: 600),
        ]
        let candidates = SessionClusteringEngine().cluster(events: events)
        XCTAssertEqual(candidates.count, 2,
                       "Events separated by more than the extended idle gap must form separate sessions")
    }

    /// Events attributed to different clients must always produce separate sessions.
    func test_clustering_twoCloseEvents_differentClients_twoSessions() {
        let events = [
            makeEvent(id: "e1", clientId: "client-A", start: baseDate,                         durationSecs: 600),
            makeEvent(id: "e2", clientId: "client-B", start: baseDate.addingTimeInterval(300), durationSecs: 600),
        ]
        let candidates = SessionClusteringEngine().cluster(events: events)
        XCTAssertEqual(candidates.count, 2,
                       "Different clients must never be merged into the same session")
    }

    /// The session's duration must equal the sum of all clustered event durations.
    func test_clustering_sessionDuration_equalsSumOfEventDurations() {
        let d1 = 900, d2 = 1800
        // Use non-overlapping events so activeDurationSecs == d1 + d2.
        let events = [
            makeEvent(id: "e1", start: baseDate,                          durationSecs: d1),
            makeEvent(id: "e2", start: baseDate.addingTimeInterval(Double(d1)), durationSecs: d2),
        ]
        let candidates = SessionClusteringEngine().cluster(events: events)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].activeDurationSecs, d1 + d2,
                       "Session duration must equal the sum of non-overlapping event durations")
    }

    /// Ten events for three different clients must produce three sessions.
    func test_clustering_multipleClients_producesSessionPerClient() {
        var events: [ClassifiedEvent] = []
        for client in ["A", "B", "C"] {
            for i in 0..<3 {
                events.append(makeEvent(
                    id:       "e-\(client)-\(i)",
                    clientId: "client-\(client)",
                    start:    baseDate.addingTimeInterval(Double(i) * 30),
                    durationSecs: 300
                ))
            }
        }
        let candidates = SessionClusteringEngine().cluster(events: events)
        XCTAssertEqual(candidates.count, 3,
                       "Each client's events should form exactly one session")
    }

    // =========================================================================
    // MARK: - BillingEngine.runDailyClustering
    // =========================================================================

    /// A single event must produce a single `WorkSession` with `.suggested` status.
    func test_billingEngine_singleEvent_insertsSuggestedSession() async throws {
        await storage.seed(events: [makeEvent()])
        try await engine.runDailyClustering()

        let inserted = await storage.insertedSessions
        XCTAssertEqual(inserted.count, 1)
        XCTAssertEqual(inserted[0].billableStatus, .suggested)
    }

    /// The inserted session must carry the correct `clientId`.
    func test_billingEngine_singleEvent_sessionHasCorrectClientId() async throws {
        await storage.seed(events: [makeEvent(clientId: "specific-client")])
        try await engine.runDailyClustering()

        let inserted = await storage.insertedSessions
        XCTAssertEqual(inserted[0].clientId, "specific-client")
    }

    /// Two events close together for the same client → one session inserted.
    func test_billingEngine_twoCloseEvents_oneSessionInserted() async throws {
        let now = Date()
        await storage.seed(events: [
            makeEvent(id: "e1", start: now,                         durationSecs: 600),
            makeEvent(id: "e2", start: now.addingTimeInterval(300), durationSecs: 600),
        ])
        try await engine.runDailyClustering()

        let inserted = await storage.insertedSessions
        XCTAssertEqual(inserted.count, 1)
    }

    /// Two events far apart → two sessions.
    func test_billingEngine_twoFarEvents_twoSessionsInserted() async throws {
        let now = Date()
        await storage.seed(events: [
            makeEvent(id: "e1", start: now,                              durationSecs: 600),
            makeEvent(id: "e2", start: now.addingTimeInterval(7_200),    durationSecs: 600),
        ])
        try await engine.runDailyClustering()

        let inserted = await storage.insertedSessions
        XCTAssertEqual(inserted.count, 2)
    }

    // =========================================================================
    // MARK: - BillingEngine.runNarrativeGeneration
    // =========================================================================

    /// A two-line LLM response must set both `description` and `invoiceText`.
    func test_billingEngine_narrativeGeneration_twoLineResponse_setsBothFields() async throws {
        registerNarrativeResponse(
            "Reviewed the Q2 roadmap with Alice.\\nQ2 roadmap review — 1.5 hrs"
        )

        let sess = WorkSession(
            id: "sess-001", clientId: "client-A",
            startedAt: baseDate, endedAt: baseDate.addingTimeInterval(5_400),
            durationSecs: 5_400
        )
        try await engine.runNarrativeGeneration(for: [sess])

        let updates = await storage.updatedNarratives
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].description, "Reviewed the Q2 roadmap with Alice.")
        XCTAssertEqual(updates[0].invoiceText, "Q2 roadmap review — 1.5 hrs")
    }

    /// A single-line LLM response must set `description` and leave `invoiceText` nil.
    func test_billingEngine_narrativeGeneration_singleLineResponse_noInvoiceText() async throws {
        registerNarrativeResponse("Sprint planning session with the team.")

        let sess = WorkSession(
            id: "sess-002", clientId: "client-B",
            startedAt: baseDate, endedAt: baseDate.addingTimeInterval(3_600),
            durationSecs: 3_600
        )
        try await engine.runNarrativeGeneration(for: [sess])

        let updates = await storage.updatedNarratives
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].description, "Sprint planning session with the team.")
        XCTAssertNil(updates[0].invoiceText)
    }

    /// An Ollama failure must be non-fatal — narrative generation for successful
    /// sessions must still proceed.
    func test_billingEngine_narrativeGeneration_partialFailure_othersSucceed() async throws {
        var callCount = 0
        IntegrationMockOllamaURLProtocol.register(path: "api/generate") { _ in
            callCount += 1
            if callCount == 1 {
                return (500, Data(#"{"error":"timeout"}"#.utf8))
            }
            let text = "Design review.\\nDesign review — 2.0 hrs"
            return (200, Data(#"{"response":"\#(text)","done":true}"#.utf8))
        }

        let sessions = (0..<3).map { i in
            WorkSession(id: "sess-\(i)", clientId: "c",
                        startedAt: baseDate, endedAt: baseDate.addingTimeInterval(3_600),
                        durationSecs: 3_600)
        }
        try await engine.runNarrativeGeneration(for: sessions)

        let updates = await storage.updatedNarratives
        XCTAssertEqual(updates.count, 2,
                       "First session fails (no update), last two must be updated")
    }

    // =========================================================================
    // MARK: - InvoiceExporter
    // =========================================================================

    private func makeBillableSession(
        id:       String = UUID().uuidString,
        clientId: String = "client-A",
        duration: Int    = 3_600,
        desc:     String = "Design review",
        invoice:  String = "Design review — 1.0 hr"
    ) -> WorkSession {
        WorkSession(
            id:            id,
            clientId:      clientId,
            startedAt:     baseDate,
            endedAt:       baseDate.addingTimeInterval(Double(duration)),
            durationSecs:  duration,
            billableStatus: .confirmed,
            description:   desc,
            invoiceText:   invoice
        )
    }

    /// `exportCSV` must write a file that begins with the UTF-8 BOM and the
    /// correct header line.
    func test_invoiceExporter_csv_hasBOMAndHeader() throws {
        let exporter = InvoiceExporter()
        let sessions = [makeBillableSession()]
        let client   = Client(id: "client-A", name: "Acme Corp")
        let url      = try exporter.exportCSV(sessions: sessions, client: client)

        let data   = try Data(contentsOf: url)
        let string = String(data: data, encoding: .utf8) ?? ""
        defer { try? FileManager.default.removeItem(at: url) }

        // Swift's UTF-8 decoder strips the BOM character when decoding, so check raw bytes instead.
        XCTAssertTrue(data.prefix(3) == Data([0xEF, 0xBB, 0xBF]), "CSV must start with UTF-8 BOM")
        XCTAssertTrue(string.contains("Date,Client,Project,Description,Hours,Rate,Amount"),
                      "CSV must contain the expected header line")
    }

    /// `exportCSV` must contain a data row for each session, with the correct
    /// client name and duration.
    func test_invoiceExporter_csv_containsSessionDataRow() throws {
        let exporter  = InvoiceExporter()
        let client    = Client(id: "client-A", name: "Acme Corp")
        let sessions  = [
            makeBillableSession(duration: 7_200, desc: "Roadmap review",
                                invoice: "Roadmap review — 2.0 hrs")
        ]
        let url = try exporter.exportCSV(sessions: sessions, client: client)
        let string = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(string.contains("Acme Corp"), "CSV must include client name")
        XCTAssertTrue(string.contains("2.00"),      "CSV must include session hours (2.00)")
    }

    /// `exportCSV` with multiple sessions must contain one row per session.
    func test_invoiceExporter_csv_multipleSessionsMultipleRows() throws {
        let exporter = InvoiceExporter()
        let client   = Client(id: "client-A", name: "Acme Corp")
        let sessions = (0..<4).map { i in
            makeBillableSession(id: "s-\(i)", duration: 1_800)
        }
        let url    = try exporter.exportCSV(sessions: sessions, client: client)
        let string = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        defer { try? FileManager.default.removeItem(at: url) }

        // 1 header + 4 data rows + trailing CRLF → split gives 6 components
        let rows = string.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(rows.count, 5,  // 1 header + 4 data
                       "CSV must have exactly one row per session plus the header")
    }

    /// `exportJSON` must produce valid JSON decodable back into the expected structure.
    func test_invoiceExporter_json_decodesBackToExpectedStructure() throws {
        let exporter = InvoiceExporter()
        let session  = makeBillableSession(duration: 5_400,
                                           desc: "Architecture review",
                                           invoice: "Architecture review — 1.5 hrs")
        let url  = try exporter.exportJSON(sessions: [session])
        let data = try Data(contentsOf: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))

        // The JSON must be an array with one element.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([WorkSessionExport].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].invoiceText, "Architecture review — 1.5 hrs")
    }

    /// `exportJSON` with empty sessions produces a JSON empty array `[]`.
    func test_invoiceExporter_json_emptySessions_emptyArray() throws {
        let exporter = InvoiceExporter()
        let url      = try exporter.exportJSON(sessions: [])
        let data     = try Data(contentsOf: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([WorkSessionExport].self, from: data)
        XCTAssertTrue(decoded.isEmpty)
    }

    // =========================================================================
    // MARK: - Full billing pipeline: cluster → narrative → export
    // =========================================================================

    /// Simulate the complete billing flow for one client:
    ///  1. Pre-populate classified events.
    ///  2. `runDailyClustering` → inserts a session.
    ///  3. `runNarrativeGeneration` → updates description + invoiceText.
    ///  4. `exportCSV` → produces a valid CSV.
    func test_billingPipeline_clusterNarrativeExport_endToEnd() async throws {
        // Step 1 — Seed one classified event.
        await storage.seed(events: [makeEvent(clientId: "acme-client", durationSecs: 3_600)])

        // Step 2 — Cluster into a session.
        try await engine.runDailyClustering()
        let inserted = await storage.insertedSessions
        XCTAssertEqual(inserted.count, 1)

        // Step 3 — Generate narrative for the session.
        registerNarrativeResponse("Met with Acme team.\\nDesign session — 1.0 hr")
        try await engine.runNarrativeGeneration(for: inserted)

        let updates = await storage.updatedNarratives
        XCTAssertEqual(updates.count, 1)
        let descriptionText = updates[0].description ?? ""
        let invoiceText     = updates[0].invoiceText ?? ""

        // Step 4 — Merge narrative into a confirmed session and export.
        var confirmed = inserted[0]
        confirmed.description = descriptionText
        confirmed.invoiceText = invoiceText

        let acmeClient = Client(id: "acme-client", name: "Acme Corp")
        let csvURL = try InvoiceExporter().exportCSV(sessions: [confirmed], client: acmeClient)
        defer { try? FileManager.default.removeItem(at: csvURL) }

        let csvContent = (try? String(contentsOf: csvURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(csvContent.contains("Acme Corp"), "CSV must reference the client name")
    }
}
