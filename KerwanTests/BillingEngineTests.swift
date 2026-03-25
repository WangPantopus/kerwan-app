import XCTest
@testable import Kerwan

// MARK: - Helpers

/// Fixed base date for deterministic test timestamps.
private let billingBase = Date(timeIntervalSince1970: 1_700_000_000)

/// Builds a minimal ``ClassifiedEvent`` for BillingEngine tests.
private func makeClassifiedEvent(
    id:           String  = UUID().uuidString,
    clientId:     String? = "client-billing",
    start:        Date    = billingBase,
    durationSecs: Int     = 1_800
) -> ClassifiedEvent {
    ClassifiedEvent(
        rawEventId:    id,
        clientId:      clientId,
        projectId:     nil,
        startedAt:     start,
        endedAt:       start.addingTimeInterval(Double(durationSecs)),
        durationSecs:  durationSecs,
        billableGuess: "yes",
        confidence:    1.0,
        source:        .audio
    )
}

/// Builds a minimal ``WorkSession`` for narrative generation tests.
private func makeWorkSession(
    id:           EntityID = UUID().uuidString,
    clientId:     EntityID? = "client-billing",
    durationSecs: Int = 3_600
) -> WorkSession {
    WorkSession(
        id:             id,
        clientId:       clientId,
        startedAt:      billingBase,
        endedAt:        billingBase.addingTimeInterval(Double(durationSecs)),
        durationSecs:   durationSecs,
        billableStatus: .suggested,
        confidence:     0.9
    )
}

// MARK: - Storage that always throws on listClassifiedEvents

private actor FailingListStorage: BillingEngineStorage {
    enum Err: Error { case intentional }
    func listClassifiedEvents(since: Date) async throws -> [ClassifiedEvent] {
        throw Err.intentional
    }
    func insertWorkSession(_ session: WorkSession) async throws {}
    func updateWorkSession(id: EntityID, description: String?, invoiceText: String?) async throws {}
}

// MARK: - Storage where every insertWorkSession throws

private actor ThrowingInsertStorage: BillingEngineStorage {
    enum Err: Error { case insertFailed }
    var classifiedEvents: [ClassifiedEvent] = []

    func listClassifiedEvents(since: Date) async throws -> [ClassifiedEvent] {
        classifiedEvents
    }
    func insertWorkSession(_ session: WorkSession) async throws {
        throw Err.insertFailed
    }
    func updateWorkSession(id: EntityID, description: String?, invoiceText: String?) async throws {}
}

// MARK: - BillingEngineTests

final class BillingEngineTests: XCTestCase {

    // Shared mocked URLSession backed by MockOllamaURLProtocol.
    private var session: URLSession!
    private var client:  OllamaClient!

    override func setUp() {
        super.setUp()
        MockOllamaURLProtocol.reset()
        session = MockOllamaURLProtocol.makeSession()
        client  = OllamaClient(session: session)
    }

    override func tearDown() {
        MockOllamaURLProtocol.reset()
        session = nil
        client  = nil
        super.tearDown()
    }

    // MARK: - Constants

    func test_billing_constants_narrativeModel() {
        XCTAssertEqual(BillingEngine.narrativeModel, "llama3:8b-instruct-q4_K_M")
    }

    func test_billing_constants_clusteringLookBack_is48Hours() {
        XCTAssertEqual(BillingEngine.clusteringLookBack, 48 * 3_600, accuracy: 1.0)
    }

    // MARK: - runDailyClustering: empty events

    func test_billing_runDailyClustering_emptyEvents_noSessionsInserted() async throws {
        let storage = MockBillingStorage()
        let engine  = BillingEngine(client: client, storage: storage)

        try await engine.runDailyClustering()

        let inserted = await storage.insertedSessions
        XCTAssertTrue(inserted.isEmpty, "No sessions should be inserted for zero events")
    }

    // MARK: - runDailyClustering: single event produces one session

    func test_billing_runDailyClustering_singleEvent_insertsSession() async throws {
        let storage = MockBillingStorage()
        await storage.seed(events: [makeClassifiedEvent()])
        let engine = BillingEngine(client: client, storage: storage)

        try await engine.runDailyClustering()

        let inserted = await storage.insertedSessions
        XCTAssertEqual(inserted.count, 1)
        XCTAssertEqual(inserted[0].clientId, "client-billing")
    }

    // MARK: - runDailyClustering: two close events cluster into one session

    func test_billing_runDailyClustering_twoCloseEvents_oneSession() async throws {
        let storage = MockBillingStorage()
        await storage.seed(events: [
            makeClassifiedEvent(id: "e1", start: billingBase,                    durationSecs: 600),
            makeClassifiedEvent(id: "e2", start: billingBase.addingTimeInterval(300), durationSecs: 600)
        ])
        let engine = BillingEngine(client: client, storage: storage)

        try await engine.runDailyClustering()

        let inserted = await storage.insertedSessions
        XCTAssertEqual(inserted.count, 1, "Two events within 15 min should cluster into one session")
    }

    // MARK: - runDailyClustering: two far-apart events produce two sessions

    func test_billing_runDailyClustering_twoFarEvents_twoSessions() async throws {
        let storage = MockBillingStorage()
        await storage.seed(events: [
            makeClassifiedEvent(id: "e1", start: billingBase,
                                durationSecs: 600),
            makeClassifiedEvent(id: "e2", start: billingBase.addingTimeInterval(7_200),
                                durationSecs: 600)   // 2 hours later
        ])
        let engine = BillingEngine(client: client, storage: storage)

        try await engine.runDailyClustering()

        let inserted = await storage.insertedSessions
        XCTAssertEqual(inserted.count, 2)
    }

    // MARK: - runDailyClustering: session fields reflect clustered data

    func test_billing_runDailyClustering_sessionStatus_isSuggested() async throws {
        let storage = MockBillingStorage()
        await storage.seed(events: [makeClassifiedEvent()])
        let engine = BillingEngine(client: client, storage: storage)

        try await engine.runDailyClustering()

        let session = await storage.insertedSessions.first!
        XCTAssertEqual(session.billableStatus, .suggested)
    }

    func test_billing_runDailyClustering_sessionDuration_matchesEventDuration() async throws {
        let storage = MockBillingStorage()
        await storage.seed(events: [makeClassifiedEvent(durationSecs: 1_800)])
        let engine = BillingEngine(client: client, storage: storage)

        try await engine.runDailyClustering()

        let session = await storage.insertedSessions.first!
        XCTAssertEqual(session.durationSecs, 1_800)
    }

    // MARK: - runDailyClustering: initial storage fetch failure propagates

    func test_billing_runDailyClustering_fetchThrows_propagatesError() async throws {
        let storage = FailingListStorage()
        let engine  = BillingEngine(client: client, storage: storage)

        do {
            try await engine.runDailyClustering()
            XCTFail("Expected an error to be thrown")
        } catch {
            // Expected: initial listClassifiedEvents failure must propagate.
        }
    }

    // MARK: - runDailyClustering: per-session insert failure is non-fatal

    func test_billing_runDailyClustering_insertThrows_doesNotPropagate() async throws {
        let storage = ThrowingInsertStorage()
        storage.classifiedEvents = [makeClassifiedEvent()]
        let engine = BillingEngine(client: client, storage: storage)

        // Must NOT throw even though insertWorkSession always throws.
        try await engine.runDailyClustering()
    }

    // MARK: - runNarrativeGeneration: empty input is a no-op

    func test_billing_runNarrativeGeneration_emptySessions_noStorageCall() async throws {
        let storage = MockBillingStorage()
        let engine  = BillingEngine(client: client, storage: storage)

        try await engine.runNarrativeGeneration(for: [])

        let updates = await storage.updatedNarratives
        XCTAssertTrue(updates.isEmpty)
    }

    // MARK: - runNarrativeGeneration: two-line LLM response is parsed correctly

    func test_billing_runNarrativeGeneration_twoLineResponse_setsBothFields() async throws {
        // Ollama returns a single streaming chunk containing a two-line narrative.
        let ndjson = #"{"response":"Reviewed Q2 roadmap with Acme.\nQ2 roadmap review — 1.0 hrs","done":true}"#
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, Data(ndjson.utf8))
        }

        let storage = MockBillingStorage()
        let session = makeWorkSession()
        let engine  = BillingEngine(client: client, storage: storage)

        try await engine.runNarrativeGeneration(for: [session])

        let updates = await storage.updatedNarratives
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].id, session.id)
        XCTAssertEqual(updates[0].description, "Reviewed Q2 roadmap with Acme.")
        XCTAssertEqual(updates[0].invoiceText, "Q2 roadmap review — 1.0 hrs")
    }

    // MARK: - runNarrativeGeneration: single-line LLM response → invoiceText is nil

    func test_billing_runNarrativeGeneration_singleLineResponse_invoiceTextNil() async throws {
        let ndjson = #"{"response":"Reviewed Q2 roadmap with Acme.","done":true}"#
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, Data(ndjson.utf8))
        }

        let storage = MockBillingStorage()
        let session = makeWorkSession()
        let engine  = BillingEngine(client: client, storage: storage)

        try await engine.runNarrativeGeneration(for: [session])

        let updates = await storage.updatedNarratives
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].description, "Reviewed Q2 roadmap with Acme.")
        XCTAssertNil(updates[0].invoiceText)
    }

    // MARK: - runNarrativeGeneration: LLM failure is non-fatal

    func test_billing_runNarrativeGeneration_ollamaFailure_doesNotThrow() async throws {
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            (500, Data(#"{"error":"model not found"}"#.utf8))
        }

        let storage = MockBillingStorage()
        let session = makeWorkSession()
        let engine  = BillingEngine(client: client, storage: storage)

        // Per-session LLM failure must NOT propagate as a thrown error.
        try await engine.runNarrativeGeneration(for: [session])

        let updates = await storage.updatedNarratives
        XCTAssertTrue(updates.isEmpty, "Failed session must not produce a storage update")
    }

    // MARK: - runNarrativeGeneration: correct session ID is updated

    func test_billing_runNarrativeGeneration_updatesCorrectSessionId() async throws {
        let ndjson = #"{"response":"Description.\nInvoice line.","done":true}"#
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, Data(ndjson.utf8))
        }

        let storage  = MockBillingStorage()
        let sessionA = makeWorkSession(id: "session-AAA")
        let sessionB = makeWorkSession(id: "session-BBB")
        let engine   = BillingEngine(client: client, storage: storage)

        try await engine.runNarrativeGeneration(for: [sessionA, sessionB])

        let updates = await storage.updatedNarratives
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates[0].id, "session-AAA")
        XCTAssertEqual(updates[1].id, "session-BBB")
    }

    // MARK: - runNarrativeGeneration: multiple sessions, one fails, others succeed

    func test_billing_runNarrativeGeneration_partialFailure_othersStillUpdated() async throws {
        var callCount = 0
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            callCount += 1
            if callCount == 1 {
                // First call fails.
                return (500, Data(#"{"error":"timeout"}"#.utf8))
            }
            // Subsequent calls succeed.
            let ndjson = #"{"response":"Design review.\nDesign review — 2.0 hrs","done":true}"#
            return (200, Data(ndjson.utf8))
        }

        let storage  = MockBillingStorage()
        let sessions = (0..<3).map { makeWorkSession(id: "sess-\($0)") }
        let engine   = BillingEngine(client: client, storage: storage)

        try await engine.runNarrativeGeneration(for: sessions)

        let updates = await storage.updatedNarratives
        // First session fails (not updated), last two succeed.
        XCTAssertEqual(updates.count, 2)
    }
}
