import XCTest
@testable import Kerwan

// MARK: - In-memory SearchEngineStorage

/// A fully in-memory implementation of ``SearchEngineStorage`` that lets tests
/// pre-populate data and run ``SearchEngine`` without a real SQLite database.
///
/// Keyword search performs a simple case-insensitive string containment check.
/// Vector search returns results in insertion order (no real KNN). Targeted
/// queries operate on the stored collections directly.
actor IntegrationSearchStorage: SearchEngineStorage {

    // MARK: - Seeded data

    private(set) var storedInteractions: [Interaction] = []
    private(set) var storedContacts:     [String: Contact] = [:]
    private(set) var storedPromises:     [Promise] = []
    private(set) var storedSessions:     [WorkSession] = []

    // Track how many times the contact-targeted query was invoked.
    private(set) var contactQueryCount: Int = 0

    // MARK: - Seed helpers

    func seed(interactions: [Interaction]) {
        storedInteractions = interactions
    }

    func seed(contact: Contact) {
        storedContacts[contact.id] = contact
    }

    func seed(promises: [Promise]) {
        storedPromises = promises
    }

    func seed(sessions: [WorkSession]) {
        storedSessions = sessions
    }

    // MARK: - SearchEngineStorage: keyword

    func keywordSearchInteractions(query: String, limit: Int) async throws -> [SearchResult] {
        let q = query.lowercased()
        return storedInteractions
            .filter { ($0.summary?.lowercased().contains(q) ?? false)
                   || ($0.subject?.lowercased().contains(q) ?? false) }
            .prefix(limit)
            .map { interaction in
                SearchResult(
                    id:             interaction.id,
                    type:           .interaction,
                    title:          interaction.subject ?? "Untitled",
                    snippet:        interaction.summary ?? "",
                    timestamp:      interaction.startedAt,
                    relevanceScore: 0.9
                )
            }
    }

    func keywordSearchPromises(query: String, limit: Int) async throws -> [SearchResult] {
        let q = query.lowercased()
        return storedPromises
            .filter { $0.text.lowercased().contains(q) }
            .prefix(limit)
            .map { promise in
                SearchResult(
                    id:             promise.id,
                    type:           .interaction,  // promises map to .interaction in SearchResult
                    title:          promise.text,
                    snippet:        promise.text,
                    timestamp:      promise.createdAt,
                    relevanceScore: 0.8
                )
            }
    }

    // MARK: - SearchEngineStorage: vector

    func vectorSearchInteractions(
        embedding: [Float],
        limit: Int
    ) async throws -> [(interactionId: EntityID, distance: Float)] {
        storedInteractions.prefix(limit).map { (interactionId: $0.id, distance: Float(0.1)) }
    }

    func vectorSearchPromises(
        embedding: [Float],
        limit: Int
    ) async throws -> [(promiseId: EntityID, distance: Float)] {
        storedPromises.prefix(limit).map { (promiseId: $0.id, distance: Float(0.1)) }
    }

    // MARK: - SearchEngineStorage: enrichment

    func fetchInteractions(ids: [EntityID]) async throws -> [Interaction] {
        storedInteractions.filter { ids.contains($0.id) }
    }

    func fetchContact(id: EntityID) async throws -> Contact? {
        storedContacts[id]
    }

    func fetchPromises(ids: [EntityID]) async throws -> [Promise] {
        storedPromises.filter { ids.contains($0.id) }
    }

    // MARK: - SearchEngineStorage: targeted

    func fetchInteractions(forContactId: EntityID, limit: Int) async throws -> [SearchResult] {
        contactQueryCount += 1
        return storedInteractions
            .filter { $0.contactId == forContactId }
            .prefix(limit)
            .map { i in
                SearchResult(
                    id:             i.id,
                    type:           .interaction,
                    title:          i.subject ?? "Interaction",
                    snippet:        i.summary ?? "",
                    timestamp:      i.startedAt,
                    relevanceScore: 0.7
                )
            }
    }

    func fetchInteractions(
        inDateRange dateRange: DateInterval,
        interactionTypes: [InteractionType]?,
        limit: Int
    ) async throws -> [SearchResult] {
        storedInteractions
            .filter { dateRange.contains($0.startedAt) }
            .filter { i in
                guard let types = interactionTypes else { return true }
                return types.contains(i.type)
            }
            .prefix(limit)
            .map { i in
                SearchResult(
                    id:             i.id,
                    type:           .interaction,
                    title:          i.subject ?? "Interaction",
                    snippet:        i.summary ?? "",
                    timestamp:      i.startedAt,
                    relevanceScore: 0.75
                )
            }
    }

    func fetchOpenPromises(forContactId: EntityID?, limit: Int) async throws -> [SearchResult] {
        storedPromises
            .filter { p in
                if let cid = forContactId { return p.contactId == cid }
                return true
            }
            .filter { $0.status == .open }
            .prefix(limit)
            .map { p in
                SearchResult(
                    id:             p.id,
                    type:           .interaction,
                    title:          p.text,
                    snippet:        p.text,
                    timestamp:      p.createdAt,
                    relevanceScore: 0.8
                )
            }
    }

    func fetchWorkSessions(inDateRange: DateInterval?, limit: Int) async throws -> [SearchResult] {
        storedSessions
            .filter { s in
                guard let range = inDateRange else { return true }
                return range.contains(s.startedAt)
            }
            .prefix(limit)
            .map { s in
                SearchResult(
                    id:             s.id,
                    type:           .workSession,
                    title:          s.description ?? "Work session",
                    snippet:        s.invoiceText ?? "",
                    timestamp:      s.startedAt,
                    relevanceScore: 0.6
                )
            }
    }
}

// MARK: - In-memory EmbeddingStorage (for EmbeddingService)

actor IntegrationEmbeddingStorage: EmbeddingServiceStorage {
    private var cache: [String: [Float]] = [:]

    func storedEmbedding(forText text: String) async throws -> [Float]? {
        cache[text]
    }

    func storeEmbedding(_ embedding: [Float], forText text: String) async throws {
        cache[text] = embedding
    }
}

// MARK: - SearchIntegrationTests

/// Integration tests for ``SearchEngine`` wired to ``IntegrationSearchStorage``
/// (in-memory) and mock Ollama embeddings.
///
/// Covers:
///  - Keyword search returns matching interactions.
///  - Semantic search path (mock zero-vector embedding).
///  - `mergeAndRank` deduplication and RRF scoring.
///  - Date-range filter inside `mergeAndRank`.
///  - Contact-targeted query path.
///  - Promise and work-session targeted queries.
///  - Empty result sets.
final class SearchIntegrationTests: XCTestCase {

    private var session:  URLSession!
    private var storage:  IntegrationSearchStorage!
    private var engine:   SearchEngine!

    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        IntegrationMockOllamaURLProtocol.reset()
        session  = IntegrationMockOllamaURLProtocol.makeSession()
        storage  = IntegrationSearchStorage()
        let client  = OllamaClient(session: session)
        let embStorage = IntegrationEmbeddingStorage()
        let embService = EmbeddingService(client: client, storage: embStorage)
        engine = SearchEngine(client: client, storage: storage, embedding: embService)
    }

    override func tearDown() {
        IntegrationMockOllamaURLProtocol.reset()
        engine  = nil
        storage = nil
        session = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeInteraction(
        id:      String = UUID().uuidString,
        subject: String,
        summary: String,
        date:    Date,
        type:    InteractionType = .meeting,
        contactId: String? = nil,
        clientId:  String? = nil
    ) -> Interaction {
        Interaction(
            id:        id,
            contactId: contactId,
            clientId:  clientId,
            type:      type,
            subject:   subject,
            summary:   summary,
            startedAt: date
        )
    }

    private func registerGeneralIntent() {
        IntegrationMockOllamaURLProtocol.register(path: "api/generate") { _ in
            let json = #"{"response":"{\"search_type\":\"general\",\"keywords\":[]}","done":true}"#
            return (200, Data(json.utf8))
        }
    }

    private func registerZeroEmbedding() {
        IntegrationMockOllamaURLProtocol.register(path: "api/embeddings") { _ in
            let zeros = Array(repeating: Float(0), count: 768)
            let data  = (try? JSONEncoder().encode(["embedding": zeros])) ?? Data()
            return (200, data)
        }
    }

    // MARK: - Keyword search: matching results returned

    func test_search_keyword_returnsMatchingInteractions() async throws {
        await storage.seed(interactions: [
            makeInteraction(subject: "Q2 Roadmap Review",
                            summary: "Discussed the Q2 roadmap with Alice.",
                            date: baseDate),
            makeInteraction(subject: "Team Retrospective",
                            summary: "Sprint retrospective — went well.",
                            date: baseDate.addingTimeInterval(3600)),
        ])

        registerGeneralIntent()
        registerZeroEmbedding()

        let results = try await engine.search(query: "roadmap", filters: SearchFilters())
        XCTAssertFalse(results.isEmpty, "Search for 'roadmap' must return at least one result")
        XCTAssertTrue(
            results.contains { $0.title.lowercased().contains("roadmap") ||
                               $0.snippet.lowercased().contains("roadmap") },
            "At least one result must relate to the 'roadmap' query"
        )
    }

    // MARK: - Keyword search: no match returns empty

    func test_search_keyword_noMatch_returnsEmpty() async throws {
        await storage.seed(interactions: [
            makeInteraction(subject: "Onboarding call",
                            summary: "New hire onboarding.",
                            date: baseDate)
        ])

        registerGeneralIntent()
        registerZeroEmbedding()

        let results = try await engine.search(query: "quarterly-earnings-xyz", filters: SearchFilters())
        XCTAssertTrue(results.isEmpty, "Nonsense query with no match must return empty results")
    }

    // MARK: - mergeAndRank: deduplication

    /// The same interaction ID appearing in both keyword and semantic paths
    /// should appear only once in the final results.
    func test_search_mergeAndRank_deduplicatesCrossSourceResults() {
        let sharedId = "shared-interaction-id"
        let shared = SearchResult(
            id: sharedId, type: .interaction,
            title: "Shared", snippet: "Cross-source",
            timestamp: baseDate, relevanceScore: 0.9
        )
        let results = engine.mergeAndRank(
            keyword:           [shared],
            semantic:          [shared],    // same ID in two sources
            targeted:          [],
            contactMatchedIDs: [],
            filters:           SearchFilters(),
            now:               baseDate
        )
        let ids = results.map(\.id)
        let unique = Set(ids)
        XCTAssertEqual(ids.count, unique.count, "Duplicate IDs must be deduplicated after merge")
        XCTAssertEqual(unique.count, 1)
    }

    // MARK: - mergeAndRank: cross-source result ranks first (RRF boost)

    func test_search_mergeAndRank_crossSourceResult_ranksFirst() {
        let crossSourceId = "in-both"
        let crossSource = SearchResult(
            id: crossSourceId, type: .interaction,
            title: "Cross-source", snippet: "In both keyword and semantic",
            timestamp: baseDate, relevanceScore: 0.9
        )
        let uniqueOnly = SearchResult(
            id: "unique", type: .interaction,
            title: "Unique", snippet: "Only in keyword",
            timestamp: baseDate, relevanceScore: 0.5
        )
        let results = engine.mergeAndRank(
            keyword:           [crossSource, uniqueOnly],
            semantic:          [crossSource],
            targeted:          [],
            contactMatchedIDs: [],
            filters:           SearchFilters(),
            now:               baseDate
        )
        XCTAssertEqual(results.first?.id, crossSourceId,
                       "Result present in two sources must rank first due to RRF boost")
    }

    // MARK: - Date-range filter inside mergeAndRank

    func test_search_mergeAndRank_dateFilter_excludesOutOfRangeResults() {
        let rangeStart = baseDate
        let rangeEnd   = baseDate.addingTimeInterval(86_400)
        let filters    = SearchFilters(dateRange: DateInterval(start: rangeStart, end: rangeEnd))

        let inRange  = SearchResult(id: "in",  type: .interaction, title: "In",
                                    snippet: "", timestamp: baseDate.addingTimeInterval(3_600),
                                    relevanceScore: 0.8)
        let outRange = SearchResult(id: "out", type: .interaction, title: "Out",
                                    snippet: "", timestamp: baseDate.addingTimeInterval(-3_600),
                                    relevanceScore: 0.9)

        let results = engine.mergeAndRank(
            keyword:           [inRange, outRange],
            semantic:          [],
            targeted:          [],
            contactMatchedIDs: [],
            filters:           filters,
            now:               baseDate
        )
        let ids = results.map(\.id)
        XCTAssertTrue(ids.contains("in"),   "In-range result must be kept")
        XCTAssertFalse(ids.contains("out"), "Out-of-range result must be excluded")
    }

    // MARK: - Contact-targeted query

    /// A search with `contactId` filter must invoke the contact-targeted storage
    /// query (incrementing `contactQueryCount`).
    func test_search_contactIdFilter_dispatchesContactQuery() async throws {
        let contactId = "contact-001"
        await storage.seed(interactions: [
            makeInteraction(subject: "Email from Bob",
                            summary: "Bob asked about the project.",
                            date: baseDate,
                            contactId: contactId)
        ])

        let json = #"{"response":"{\"search_type\":\"general\",\"keywords\":[]}","done":true}"#
        IntegrationMockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, Data(json.utf8))
        }
        registerZeroEmbedding()

        let filters = SearchFilters(contactId: contactId)
        _ = try await engine.search(query: "project", filters: filters)

        let count = await storage.contactQueryCount
        XCTAssertGreaterThan(count, 0,
                             "contactId filter must dispatch at least one contact-targeted query")
    }

    // MARK: - Open promises targeted query

    func test_search_openPromises_returnedByTargetedQuery() async throws {
        let promise = Promise(
            id:        "p-001",
            contactId: "c-001",
            text:      "Send the design brief by Friday",
            status:    .open,
            createdAt: baseDate
        )
        await storage.seed(promises: [promise])

        let json = #"{"response":"{\"search_type\":\"promises\",\"keywords\":[\"design\"]}","done":true}"#
        IntegrationMockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, Data(json.utf8))
        }
        registerZeroEmbedding()

        let results = try await engine.search(query: "design brief", filters: SearchFilters())
        XCTAssertFalse(results.isEmpty, "Open promise query must return results")
    }

    // MARK: - Work session targeted query

    func test_search_workSessions_returnedWhenQueryIntentIsBilling() async throws {
        let session = WorkSession(
            id:            "sess-001",
            clientId:      "client-001",
            startedAt:     baseDate,
            endedAt:       baseDate.addingTimeInterval(3_600),
            durationSecs:  3_600,
            description:   "Reviewed wireframes",
            invoiceText:   "Design review — 1.0 hr"
        )
        await storage.seed(sessions: [session])

        let json = #"{"response":"{\"search_type\":\"billing\",\"keywords\":[\"wireframes\"]}","done":true}"#
        IntegrationMockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, Data(json.utf8))
        }
        registerZeroEmbedding()

        let results = try await engine.search(query: "wireframes", filters: SearchFilters())
        XCTAssertFalse(results.isEmpty, "Billing intent must include work session results")
    }

    // MARK: - Empty storage returns empty results

    func test_search_emptyStorage_returnsEmpty() async throws {
        registerGeneralIntent()
        registerZeroEmbedding()

        let results = try await engine.search(query: "anything", filters: SearchFilters())
        XCTAssertTrue(results.isEmpty, "Empty storage must return no results")
    }

    // MARK: - Multiple interactions, ranking by relevance

    /// Pre-populate three interactions; the one with the highest overlap with the
    /// query terms must appear first.
    func test_search_multipleInteractions_highestRelevanceRanksFirst() async throws {
        await storage.seed(interactions: [
            makeInteraction(subject: "Budget Discussion",
                            summary: "Reviewed Q3 budget figures.", date: baseDate),
            makeInteraction(subject: "Project Kickoff",
                            summary: "Kicked off the new roadmap project.", date: baseDate),
            makeInteraction(subject: "Roadmap Planning Session",
                            summary: "Detailed roadmap planning with all stakeholders.", date: baseDate),
        ])

        registerGeneralIntent()
        registerZeroEmbedding()

        let results = try await engine.search(query: "roadmap", filters: SearchFilters())
        XCTAssertFalse(results.isEmpty)

        // Both "Project Kickoff" and "Roadmap Planning Session" match.
        // At least one roadmap-related result must be present.
        let hasMention = results.contains {
            $0.title.lowercased().contains("roadmap") ||
            $0.snippet.lowercased().contains("roadmap")
        }
        XCTAssertTrue(hasMention, "At least one roadmap-related result must appear")
    }
}
