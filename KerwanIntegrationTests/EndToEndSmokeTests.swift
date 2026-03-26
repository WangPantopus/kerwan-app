import XCTest
@testable import Kerwan

// MARK: - Combined spy that satisfies both ClassificationStorage and SearchEngineStorage

/// A single actor that implements **both** ``ClassificationStorage`` *and*
/// ``SearchEngineStorage``. This lets a smoke test wire the entire
/// classification → search pipeline through one shared in-memory store.
actor CombinedPipelineStorage: ClassificationStorage, SearchEngineStorage {

    // ── Stored collections ────────────────────────────────────────────────

    private(set) var contacts:     [String: Contact]     = [:]
    private(set) var clients:      [String: Client]      = [:]
    private(set) var interactions: [String: Interaction] = [:]
    private(set) var promises:     [String: Promise]     = [:]
    private(set) var embeddings:   [String: [Float]]     = [:]
    private(set) var sessions:     [String: WorkSession] = [:]

    private(set) var contactQueryCount: Int = 0

    // ── Seed helpers ──────────────────────────────────────────────────────

    func seedClient(_ client: Client)   { clients[client.id]   = client }
    func seedContact(_ contact: Contact) { contacts[contact.id] = contact }

    // ── ClassificationStorage ─────────────────────────────────────────────

    func findContact(byEmail email: String) async throws -> Contact? {
        contacts.values.first { $0.emailPrimary?.lowercased() == email.lowercased() }
    }

    func findContact(byName name: String) async throws -> Contact? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return contacts.values.first {
            $0.displayName.trimmingCharacters(in: .whitespaces).lowercased() == n
        }
    }

    func upsertContact(_ contact: Contact) async throws {
        contacts[contact.id] = contact
    }

    func listClients() async throws -> [Client] {
        Array(clients.values)
    }

    func insertInteraction(_ interaction: Interaction) async throws {
        interactions[interaction.id] = interaction
    }

    func insertPromise(_ promise: Promise) async throws {
        promises[promise.id] = promise
    }

    func storeInteractionEmbedding(interactionId: EntityID, vector: [Float]) async throws {
        embeddings[interactionId] = vector
    }

    // ── SearchEngineStorage ───────────────────────────────────────────────

    func keywordSearchInteractions(query: String, limit: Int) async throws -> [SearchResult] {
        let q = query.lowercased()
        return Array(
            interactions.values
                .filter { ($0.summary?.lowercased().contains(q) ?? false)
                       || ($0.subject?.lowercased().contains(q) ?? false) }
                .prefix(limit)
                .map { i in
                    SearchResult(
                        id: i.id, type: .interaction,
                        title: i.subject ?? "Interaction",
                        snippet: i.summary ?? "",
                        timestamp: i.startedAt,
                        relevanceScore: 0.9
                    )
                }
        )
    }

    func keywordSearchPromises(query: String, limit: Int) async throws -> [SearchResult] {
        let q = query.lowercased()
        return Array(
            promises.values
                .filter { $0.text.lowercased().contains(q) }
                .prefix(limit)
                .map { p in
                    SearchResult(
                        id: p.id, type: .interaction,
                        title: p.text, snippet: p.text,
                        timestamp: p.createdAt,
                        relevanceScore: 0.8
                    )
                }
        )
    }

    func vectorSearchInteractions(embedding: [Float], limit: Int) async throws
        -> [(interactionId: EntityID, distance: Float)]
    {
        Array(interactions.keys.prefix(limit).map { (interactionId: $0, distance: Float(0.1)) })
    }

    func vectorSearchPromises(embedding: [Float], limit: Int) async throws
        -> [(promiseId: EntityID, distance: Float)]
    {
        Array(promises.keys.prefix(limit).map { (promiseId: $0, distance: Float(0.1)) })
    }

    func fetchInteractions(ids: [EntityID]) async throws -> [Interaction] {
        ids.compactMap { interactions[$0] }
    }

    func fetchContact(id: EntityID) async throws -> Contact? {
        contacts[id]
    }

    func fetchPromises(ids: [EntityID]) async throws -> [Promise] {
        ids.compactMap { promises[$0] }
    }

    func fetchInteractions(forContactId: EntityID, limit: Int) async throws -> [SearchResult] {
        contactQueryCount += 1
        return Array(
            interactions.values
                .filter { $0.contactId == forContactId }
                .prefix(limit)
                .map { i in
                    SearchResult(
                        id: i.id, type: .interaction,
                        title: i.subject ?? "Interaction",
                        snippet: i.summary ?? "",
                        timestamp: i.startedAt,
                        relevanceScore: 0.7
                    )
                }
        )
    }

    func fetchInteractions(
        inDateRange dateRange: DateInterval,
        interactionTypes: [InteractionType]?,
        limit: Int
    ) async throws -> [SearchResult] {
        Array(
            interactions.values
                .filter { dateRange.contains($0.startedAt) }
                .prefix(limit)
                .map { i in
                    SearchResult(
                        id: i.id, type: .interaction,
                        title: i.subject ?? "Interaction",
                        snippet: i.summary ?? "",
                        timestamp: i.startedAt,
                        relevanceScore: 0.75
                    )
                }
        )
    }

    func fetchOpenPromises(forContactId: EntityID?, limit: Int) async throws -> [SearchResult] {
        Array(
            promises.values
                .filter { p in
                    if let cid = forContactId { return p.contactId == cid }
                    return true
                }
                .filter { $0.status == .open }
                .prefix(limit)
                .map { p in
                    SearchResult(
                        id: p.id, type: .interaction,
                        title: p.text, snippet: p.text,
                        timestamp: p.createdAt,
                        relevanceScore: 0.8
                    )
                }
        )
    }

    func fetchWorkSessions(inDateRange: DateInterval?, limit: Int) async throws -> [SearchResult] {
        Array(
            sessions.values
                .filter { s in
                    guard let range = inDateRange else { return true }
                    return range.contains(s.startedAt)
                }
                .prefix(limit)
                .map { s in
                    SearchResult(
                        id: s.id, type: .workSession,
                        title: s.description ?? "Work session",
                        snippet: s.invoiceText ?? "",
                        timestamp: s.startedAt,
                        relevanceScore: 0.6
                    )
                }
        )
    }
}

// MARK: - EndToEndSmokeTests

/// End-to-end smoke tests that exercise the complete data flow:
///
/// ```
/// Raw events → ClassificationActor → (contacts / interactions / promises)
///                                            ↓
///                                      SearchEngine → ranked results
/// ```
///
/// All external I/O is mocked:
///  - Ollama: ``IntegrationMockOllamaURLProtocol`` — deterministic JSON.
///  - Storage: ``CombinedPipelineStorage`` — shared in-memory store used by
///    both the classification and search layers.
///
/// No network, no SQLite, no filesystem required.
final class EndToEndSmokeTests: XCTestCase {

    private var pipelineStorage: CombinedPipelineStorage!
    private var classificationActor: ClassificationActor!
    private var searchEngine: SearchEngine!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        IntegrationMockOllamaURLProtocol.reset()
        session          = IntegrationMockOllamaURLProtocol.makeSession()
        pipelineStorage  = CombinedPipelineStorage()

        let client     = OllamaClient(session: session)
        let embStorage = IntegrationEmbeddingStorage()
        let embService = EmbeddingService(client: client, storage: embStorage)

        classificationActor = ClassificationActor(client: client, storage: pipelineStorage)
        searchEngine        = SearchEngine(client: client, storage: pipelineStorage, embedding: embService)
    }

    override func tearDown() {
        IntegrationMockOllamaURLProtocol.reset()
        classificationActor = nil
        searchEngine        = nil
        pipelineStorage     = nil
        session             = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func registerOllama(classificationResult: String, embedding: [Float]? = nil) {
        let escaped = classificationResult
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let ndjson = #"{"response":"\#(escaped)","done":true}"#
        IntegrationMockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, Data(ndjson.utf8))
        }
        let vec = embedding ?? Array(repeating: Float(0), count: 768)
        IntegrationMockOllamaURLProtocol.register(path: "api/embeddings") { _ in
            let data = (try? JSONEncoder().encode(["embedding": vec])) ?? Data()
            return (200, data)
        }
        IntegrationMockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }
    }

    private func classificationJSON(eventId: String, email: String,
                                    name: String, summary: String) -> String {
        """
        [{"id":"\(eventId)","contact_names":["\(name)"],"contact_emails":["\(email)"],\
        "client_guess":null,"project_guess":null,"content_types":["meeting"],\
        "direction":"inbound","promises":[],"topics":["project"],\
        "billable":"yes","importance":"high","sentiment":"positive","summary":"\(summary)"}]
        """
    }

    // MARK: - Smoke test 1: 10 app-focus events, one contact created per unique email

    /// Simulate 10 distinct app-focus events for different users.
    /// After classification, there should be 10 distinct contacts.
    func test_endToEnd_tenAppFocusEvents_tenContactsCreated() async throws {
        var eventIds: [String] = []
        var classificationArray: [[String: Any]] = []

        for i in 0..<10 {
            let eid = "evt-appfocus-\(i)"
            eventIds.append(eid)
            classificationArray.append([
                "id": eid,
                "contact_names": ["User \(i)"],
                "contact_emails": ["user\(i)@example.com"],
                "client_guess": NSNull(),
                "project_guess": NSNull(),
                "content_types": ["appFocus"],
                "direction": "inbound",
                "promises": [],
                "topics": ["work"],
                "billable": "no",
                "importance": "low",
                "sentiment": "neutral",
                "summary": "User \(i) was active in the app."
            ] as [String: Any])
        }

        let jsonData = try JSONSerialization.data(withJSONObject: classificationArray)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"
        registerOllama(classificationResult: jsonString)

        let events = eventIds.map { eid in
            RawEvent(id: eid, source: .appFocus, startedAt: Date(),
                     rawText: "Focus event \(eid)")
        }
        classificationActor.enqueue(events)
        await classificationActor.runClassificationCycle()

        let contacts = await pipelineStorage.contacts
        XCTAssertEqual(contacts.count, 10,
                       "10 app-focus events must produce 10 distinct contacts")
    }

    // MARK: - Smoke test 2: email events → interactions searchable

    /// Simulate 5 email events, each from a different contact. After classification
    /// and a search query, at least one of the email interactions must be found.
    func test_endToEnd_fiveEmailEvents_interactionsSearchable() async throws {
        let eventId = "evt-email-001"

        let classificationResult = classificationJSON(
            eventId: eventId,
            email:   "alice@acme.com",
            name:    "Alice Acme",
            summary: "Email from Alice about the Q3 budget proposal."
        )
        registerOllama(classificationResult: classificationResult)

        let event = RawEvent(id: eventId, source: .email, startedAt: Date(),
                             rawText: "Hi, here is the Q3 budget proposal.")
        classificationActor.enqueue([event])
        await classificationActor.runClassificationCycle()

        // Ensure the interaction is in storage before searching.
        let storedInteractions = await pipelineStorage.interactions
        XCTAssertFalse(storedInteractions.isEmpty, "Email event must produce at least one interaction")

        // Now search — use "general" intent response.
        IntegrationMockOllamaURLProtocol.reset()
        let generalIntent = #"{"response":"{\"search_type\":\"general\",\"keywords\":[\"budget\"]}","done":true}"#
        IntegrationMockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, Data(generalIntent.utf8))
        }
        let zeroVec = Array(repeating: Float(0), count: 768)
        IntegrationMockOllamaURLProtocol.register(path: "api/embeddings") { _ in
            let data = (try? JSONEncoder().encode(["embedding": zeroVec])) ?? Data()
            return (200, data)
        }

        let results = try await searchEngine.search(query: "budget", filters: SearchFilters())
        XCTAssertFalse(results.isEmpty, "Email interaction must be findable via keyword search")
    }

    // MARK: - Smoke test 3: meeting transcript → contact, interaction, promise all created

    /// Simulate one long meeting transcript with an explicit promise ("send the report").
    /// After classification, verify contact, interaction, and promise are all stored.
    func test_endToEnd_meetingTranscript_contactInteractionPromiseCreated() async throws {
        let eventId = "evt-meeting-001"

        let classificationResult = """
        [{"id":"\(eventId)","contact_names":["Bob Builder"],"contact_emails":["bob@build.com"],\
        "client_guess":"Build Corp","project_guess":null,"content_types":["meeting"],\
        "direction":"inbound","promises":[{"description":"Send the project report","who":"me","due_date":null}],\
        "topics":["project","report"],"billable":"yes","importance":"high",\
        "sentiment":"positive","summary":"Meeting with Bob about the project report."}]
        """
        registerOllama(classificationResult: classificationResult)
        await pipelineStorage.seedClient(Client(id: "build-corp-123", name: "Build Corp"))

        let event = RawEvent(
            id:       eventId,
            source:   .audio,
            startedAt: Date(),
            rawText:  "Bob: Can you send me the project report by Friday? Me: Sure, I will."
        )
        classificationActor.enqueue([event])
        await classificationActor.runClassificationCycle()

        let contacts = await pipelineStorage.contacts
        XCTAssertFalse(contacts.isEmpty, "Meeting must create a contact")
        XCTAssertTrue(contacts.values.contains { $0.emailPrimary == "bob@build.com" },
                      "Contact with email bob@build.com must exist")

        let interactions = await pipelineStorage.interactions
        XCTAssertEqual(interactions.count, 1, "Exactly one interaction must be created")

        let promises = await pipelineStorage.promises
        XCTAssertEqual(promises.count, 1, "Exactly one promise must be extracted")
        XCTAssertTrue(promises.values.first?.text.contains("report") == true,
                      "Promise text must mention 'report'")

        let interaction = interactions.values.first!
        XCTAssertEqual(interaction.clientId, "build-corp-123",
                       "Interaction must be linked to the known client")
    }

    // MARK: - Smoke test 4: excluded events never classified

    /// 5 events — 3 excluded, 2 not. After one classification cycle, the 3 excluded
    /// events must never reach Ollama and only 2 interactions must be created.
    func test_endToEnd_mixedExcludedEvents_onlyNonExcludedClassified() async throws {
        let goodId1 = "evt-good-1"
        let goodId2 = "evt-good-2"

        let classificationResult = """
        [{"id":"\(goodId1)","contact_names":["Alice"],"contact_emails":["a@x.com"],\
        "client_guess":null,"project_guess":null,"content_types":["email"],"direction":"inbound",\
        "promises":[],"topics":[],"billable":"yes","importance":"medium","sentiment":"neutral",\
        "summary":"Email from Alice."},\
        {"id":"\(goodId2)","contact_names":["Bob"],"contact_emails":["b@x.com"],\
        "client_guess":null,"project_guess":null,"content_types":["email"],"direction":"inbound",\
        "promises":[],"topics":[],"billable":"yes","importance":"medium","sentiment":"neutral",\
        "summary":"Email from Bob."}]
        """
        registerOllama(classificationResult: classificationResult)

        let events: [RawEvent] = [
            RawEvent(id: goodId1,     source: .email,    startedAt: Date(), isExcluded: false),
            RawEvent(id: "excl-1",    source: .appFocus, startedAt: Date(), isExcluded: true),
            RawEvent(id: goodId2,     source: .email,    startedAt: Date(), isExcluded: false),
            RawEvent(id: "excl-2",    source: .appFocus, startedAt: Date(), isExcluded: true),
            RawEvent(id: "excl-3",    source: .appFocus, startedAt: Date(), isExcluded: true),
        ]

        classificationActor.enqueue(events)

        let pendingAfterEnqueue = await classificationActor.pendingEventCount
        XCTAssertEqual(pendingAfterEnqueue, 2, "Only 2 non-excluded events must be in the queue")

        await classificationActor.runClassificationCycle()

        let interactions = await pipelineStorage.interactions
        XCTAssertEqual(interactions.count, 2,
                       "Exactly 2 interactions created — one per non-excluded event")
    }

    // MARK: - Smoke test 5: search after pipeline produces ranked results

    /// Full round-trip: classify 3 events with known summaries, then run a keyword
    /// search that should return the most relevant one first.
    func test_endToEnd_classifyThenSearch_rankedResultsReturned() async throws {
        let id1 = "evt-rank-1"
        let id2 = "evt-rank-2"
        let id3 = "evt-rank-3"

        let classificationResult = """
        [{"id":"\(id1)","contact_names":["Alice"],"contact_emails":["a@test.com"],\
        "client_guess":null,"project_guess":null,"content_types":["meeting"],"direction":"inbound",\
        "promises":[],"topics":["roadmap"],"billable":"yes","importance":"high","sentiment":"positive",\
        "summary":"Detailed roadmap planning session covering all Q3 milestones."},\
        {"id":"\(id2)","contact_names":["Bob"],"contact_emails":["b@test.com"],\
        "client_guess":null,"project_guess":null,"content_types":["meeting"],"direction":"inbound",\
        "promises":[],"topics":["budget"],"billable":"yes","importance":"medium","sentiment":"neutral",\
        "summary":"Budget review — Q3 numbers look good."},\
        {"id":"\(id3)","contact_names":["Carol"],"contact_emails":["c@test.com"],\
        "client_guess":null,"project_guess":null,"content_types":["email"],"direction":"inbound",\
        "promises":[],"topics":["unrelated"],"billable":"no","importance":"low","sentiment":"neutral",\
        "summary":"Out-of-office notice."}]
        """
        registerOllama(classificationResult: classificationResult)

        let events = [id1, id2, id3].map { eid in
            RawEvent(id: eid, source: .audio, startedAt: Date(), rawText: "Transcript \(eid)")
        }
        classificationActor.enqueue(events)
        await classificationActor.runClassificationCycle()

        // Confirm 3 interactions were stored.
        let interactions = await pipelineStorage.interactions
        XCTAssertEqual(interactions.count, 3)

        // Now search for "roadmap" — should return the first interaction.
        IntegrationMockOllamaURLProtocol.reset()
        let intent = #"{"response":"{\"search_type\":\"general\",\"keywords\":[\"roadmap\"]}","done":true}"#
        IntegrationMockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, Data(intent.utf8))
        }
        IntegrationMockOllamaURLProtocol.register(path: "api/embeddings") { _ in
            let data = (try? JSONEncoder().encode(["embedding": Array(repeating: Float(0), count: 768)])) ?? Data()
            return (200, data)
        }

        let results = try await searchEngine.search(query: "roadmap", filters: SearchFilters())
        XCTAssertFalse(results.isEmpty, "Roadmap query must return at least one result")
        XCTAssertTrue(
            results.contains { $0.snippet.lowercased().contains("roadmap") ||
                               $0.title.lowercased().contains("roadmap") },
            "At least one result must reference 'roadmap'"
        )
    }

    // MARK: - Smoke test 6: Ollama down during classification — queue preserved

    /// When Ollama is unavailable, the classification cycle must skip silently.
    /// All events must remain in the queue, and zero interactions must be stored.
    func test_endToEnd_ollamaDown_allEventsPreserved() async throws {
        IntegrationMockOllamaURLProtocol.register(path: "api/tags") { _ in
            (503, Data(#"{"error":"unavailable"}"#.utf8))
        }

        let events = (0..<5).map { i in
            RawEvent(id: "evt-down-\(i)", source: .email, startedAt: Date(),
                     rawText: "Some email \(i)")
        }
        classificationActor.enqueue(events)
        await classificationActor.runClassificationCycle()

        let remaining = await classificationActor.pendingEventCount
        XCTAssertEqual(remaining, 5,
                       "All 5 events must remain queued when Ollama is unreachable")

        let interactions = await pipelineStorage.interactions
        XCTAssertTrue(interactions.isEmpty,
                      "Zero interactions must be created when Ollama is down")
    }
}
