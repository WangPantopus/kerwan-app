import XCTest
@testable import Kerwan

// MARK: - Mock search storage

/// In-memory implementation of ``SearchEngineStorage`` for testing.
///
/// All storage data is pre-seeded via actor-isolated `seed(...)` methods so
/// tests can configure responses without mutating actor state from outside.
actor MockSearchEngineStorage: SearchEngineStorage {

    // Seeded raw data (used by enrichment methods)
    private var storedInteractions: [Interaction] = []
    private var storedPromises:     [Promise]     = []
    private var storedContacts:     [Contact]     = []

    // Pre-built search result arrays (returned by query methods)
    private var _keywordInteractionResults: [SearchResult] = []
    private var _keywordPromiseResults:     [SearchResult] = []
    private var _vectorInteractionPairs:    [(interactionId: EntityID, distance: Float)] = []
    private var _vectorPromisePairs:        [(promiseId: EntityID,     distance: Float)] = []
    private var _contactInteractionResults: [SearchResult] = []
    private var _dateRangeResults:          [SearchResult] = []
    private var _openPromiseResults:        [SearchResult] = []
    private var _workSessionResults:        [SearchResult] = []

    // Call counters for verifying targeted-query dispatch
    private(set) var contactQueryCount:   Int = 0
    private(set) var dateRangeQueryCount: Int = 0
    private(set) var promiseQueryCount:   Int = 0
    private(set) var workSessionCount:    Int = 0

    // MARK: Seed helpers

    func seed(interactions: [Interaction])                                 { storedInteractions = interactions }
    func seed(promises: [Promise])                                         { storedPromises     = promises }
    func seed(contacts: [Contact])                                         { storedContacts     = contacts }
    func seed(keywordInteractionResults r: [SearchResult])                 { _keywordInteractionResults = r }
    func seed(keywordPromiseResults r: [SearchResult])                     { _keywordPromiseResults = r }
    func seed(vectorInteractionPairs r: [(interactionId: EntityID, distance: Float)]) { _vectorInteractionPairs = r }
    func seed(vectorPromisePairs r: [(promiseId: EntityID, distance: Float)])          { _vectorPromisePairs = r }
    func seed(contactInteractionResults r: [SearchResult])                 { _contactInteractionResults = r }
    func seed(dateRangeResults r: [SearchResult])                          { _dateRangeResults = r }
    func seed(openPromiseResults r: [SearchResult])                        { _openPromiseResults = r }
    func seed(workSessionResults r: [SearchResult])                        { _workSessionResults = r }

    // MARK: SearchEngineStorage

    func keywordSearchInteractions(query: String, limit: Int) async throws -> [SearchResult] {
        Array(_keywordInteractionResults.prefix(limit))
    }
    func keywordSearchPromises(query: String, limit: Int) async throws -> [SearchResult] {
        Array(_keywordPromiseResults.prefix(limit))
    }
    func vectorSearchInteractions(embedding: [Float], limit: Int) async throws
        -> [(interactionId: EntityID, distance: Float)]
    {
        Array(_vectorInteractionPairs.prefix(limit))
    }
    func vectorSearchPromises(embedding: [Float], limit: Int) async throws
        -> [(promiseId: EntityID, distance: Float)]
    {
        Array(_vectorPromisePairs.prefix(limit))
    }
    func fetchInteractions(ids: [EntityID]) async throws -> [Interaction] {
        storedInteractions.filter { ids.contains($0.id) }
    }
    func fetchContact(id: EntityID) async throws -> Contact? {
        storedContacts.first { $0.id == id }
    }
    func fetchPromises(ids: [EntityID]) async throws -> [Promise] {
        storedPromises.filter { ids.contains($0.id) }
    }
    func fetchInteractions(forContactId: EntityID, limit: Int) async throws -> [SearchResult] {
        contactQueryCount += 1
        return Array(_contactInteractionResults.prefix(limit))
    }
    func fetchInteractions(
        inDateRange dateRange: DateInterval,
        interactionTypes: [InteractionType]?,
        limit: Int
    ) async throws -> [SearchResult] {
        dateRangeQueryCount += 1
        return Array(_dateRangeResults.prefix(limit))
    }
    func fetchOpenPromises(forContactId: EntityID?, limit: Int) async throws -> [SearchResult] {
        promiseQueryCount += 1
        return Array(_openPromiseResults.prefix(limit))
    }
    func fetchWorkSessions(inDateRange: DateInterval?, limit: Int) async throws -> [SearchResult] {
        workSessionCount += 1
        return Array(_workSessionResults.prefix(limit))
    }
}

// MARK: - Test helpers

/// Builds a minimal ``SearchResult`` for testing, using distant timestamps by default
/// to avoid unintended recency boosts.
private func makeResult(
    id:        String = UUID().uuidString,
    type:      SearchResultType = .interaction,
    timestamp: Date = Date(timeIntervalSinceNow: -60 * 86_400)  // 60 days ago → no recency boost
) -> SearchResult {
    SearchResult(
        id:             id,
        type:           type,
        title:          "Test \(id)",
        snippet:        "Snippet \(id)",
        timestamp:      timestamp,
        relevanceScore: 0.5
    )
}

/// Returns NDJSON data for a single `api/generate` response containing `intentDict` as the
/// JSON-constrained output. The dict is serialised, then embedded in the `response` field.
private func makeIntentNDJSON(_ intentDict: [String: Any]) -> Data {
    let intentData = (try? JSONSerialization.data(withJSONObject: intentDict)) ?? Data()
    let intentStr  = String(data: intentData, encoding: .utf8) ?? "{}"
    // Escape for embedding in the NDJSON "response" string value.
    let escaped = intentStr
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let ndjson = "{\"response\":\"\(escaped)\",\"done\":true}\n"
    return ndjson.data(using: .utf8) ?? Data()
}

/// NDJSON for a general-intent response — the default fallback used in most tests.
private func makeGeneralIntentNDJSON() -> Data {
    makeIntentNDJSON([
        "search_type": "general",
        "keywords":    [String](),
        "date_range":  NSNull(),
        "contact_name": NSNull()
    ])
}

/// 768-element `{"embedding": [...]}` response for `api/embeddings`.
private func makeQueryEmbeddingResponse() -> Data {
    let vec: [Double] = Array(repeating: 0.1, count: 768)
    return (try? JSONSerialization.data(withJSONObject: ["embedding": vec])) ?? Data()
}

/// Registers the default handlers on `MockOllamaURLProtocol`:
/// - `api/generate`   → general intent NDJSON (overridable with `intentData`)
/// - `api/embeddings` → 768-dim zero vector
private func registerSearchMocks(intentData: Data? = nil) {
    MockOllamaURLProtocol.register(path: "api/generate") { _ in
        (200, intentData ?? makeGeneralIntentNDJSON())
    }
    MockOllamaURLProtocol.register(path: "api/embeddings") { _ in
        (200, makeQueryEmbeddingResponse())
    }
}

/// Creates a `SearchEngine` wired to mock Ollama and the given storage.
private func makeEngine(storage: MockSearchEngineStorage) -> SearchEngine {
    let session    = MockOllamaURLProtocol.makeSession()
    let client     = OllamaClient(session: session)
    let embStorage = MockEmbeddingStorage()     // reuse from EmbeddingServiceTests
    let embService = EmbeddingService(client: client, storage: embStorage)
    return SearchEngine(client: client, storage: storage, embedding: embService)
}

// MARK: - SearchFiltersTests

final class SearchFiltersTests: XCTestCase {

    func test_searchFilters_defaultsAllNil() {
        let f = SearchFilters()
        XCTAssertNil(f.contactId)
        XCTAssertNil(f.clientId)
        XCTAssertNil(f.source)
        XCTAssertNil(f.dateRange)
        XCTAssertNil(f.includeTypes)
    }

    func test_searchFilters_storesAllFields() {
        let range = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 86_400)
        let f = SearchFilters(
            contactId:    "c1",
            clientId:     "cl1",
            source:       .email,
            dateRange:    range,
            includeTypes: [.meeting, .emailSent]
        )
        XCTAssertEqual(f.contactId,       "c1")
        XCTAssertEqual(f.clientId,        "cl1")
        XCTAssertEqual(f.source,          .email)
        XCTAssertEqual(f.dateRange,       range)
        XCTAssertEqual(f.includeTypes,    [.meeting, .emailSent])
    }

    func test_searchFilters_isMutable() {
        var f = SearchFilters()
        f.contactId = "x"
        XCTAssertEqual(f.contactId, "x")
    }
}

// MARK: - QueryIntentTests

final class QueryIntentTests: XCTestCase {

    func test_queryIntent_generalFallback_isGeneral() {
        XCTAssertEqual(QueryIntent.generalFallback.searchType, .general)
        XCTAssertTrue(QueryIntent.generalFallback.keywords.isEmpty)
        XCTAssertNil(QueryIntent.generalFallback.dateRange)
        XCTAssertNil(QueryIntent.generalFallback.contactName)
    }

    func test_queryIntent_decoding_snakeCaseMaps() throws {
        let json = """
        {
          "search_type": "person",
          "keywords": ["Jane", "Smith"],
          "date_range": null,
          "contact_name": "Jane Smith"
        }
        """.data(using: .utf8)!
        let intent = try JSONDecoder().decode(QueryIntent.self, from: json)
        XCTAssertEqual(intent.searchType,   .person)
        XCTAssertEqual(intent.keywords,     ["Jane", "Smith"])
        XCTAssertNil(intent.dateRange)
        XCTAssertEqual(intent.contactName,  "Jane Smith")
    }

    func test_queryIntent_dateRange_convertsToDateInterval() {
        let from = Date(timeIntervalSince1970: 0)
        let to   = Date(timeIntervalSince1970: 86_400)
        let range = QueryIntent.DateRange(from: from, to: to)
        let interval = range.dateInterval
        XCTAssertNotNil(interval)
        XCTAssertEqual(interval?.start, from)
        XCTAssertEqual(interval?.end,   to)
    }

    func test_queryIntent_dateRange_nilWhenMissingBound() {
        let range = QueryIntent.DateRange(from: Date(), to: nil)
        XCTAssertNil(range.dateInterval)
    }

    func test_queryIntent_allSearchTypesDecodable() throws {
        for type in QueryIntent.SearchType.allCases {
            let json = "{\"search_type\":\"\(type.rawValue)\",\"keywords\":[],\"date_range\":null,\"contact_name\":null}"
                .data(using: .utf8)!
            let intent = try JSONDecoder().decode(QueryIntent.self, from: json)
            XCTAssertEqual(intent.searchType, type)
        }
    }

    func test_queryIntent_encoding_usesSnakeCase() throws {
        let intent = QueryIntent(searchType: .promise, keywords: ["follow-up"])
        let data   = try JSONEncoder().encode(intent)
        let dict   = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(dict["search_type"])
        XCTAssertNil(dict["searchType"])
        XCTAssertNotNil(dict["keywords"])
    }
}

// MARK: - SearchEngineMergeRankTests

final class SearchEngineMergeRankTests: XCTestCase {

    private var storage: MockSearchEngineStorage!
    private var engine:  SearchEngine!

    override func setUp() {
        super.setUp()
        storage = MockSearchEngineStorage()
        registerSearchMocks()
        engine = makeEngine(storage: storage)
    }

    override func tearDown() {
        MockOllamaURLProtocol.reset()
        super.tearDown()
    }

    // MARK: Basic cases

    func test_mergeAndRank_allEmpty_returnsEmpty() {
        let results = engine.mergeAndRank(
            keyword: [], semantic: [], targeted: [],
            contactMatchedIDs: [], filters: SearchFilters()
        )
        XCTAssertTrue(results.isEmpty)
    }

    func test_mergeAndRank_singleResult_scores1() {
        let r = makeResult(id: "r1")
        let results = engine.mergeAndRank(
            keyword: [r], semantic: [], targeted: [],
            contactMatchedIDs: [], filters: SearchFilters()
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].relevanceScore, 1.0, accuracy: 1e-9)
    }

    func test_mergeAndRank_sortedDescending() {
        // r1 at rank 1, r2 at rank 2 in keyword; no overlap.
        let r1 = makeResult(id: "r1")
        let r2 = makeResult(id: "r2")
        let results = engine.mergeAndRank(
            keyword: [r1, r2], semantic: [], targeted: [],
            contactMatchedIDs: [], filters: SearchFilters()
        )
        XCTAssertEqual(results[0].id, "r1")
        XCTAssertEqual(results[1].id, "r2")
        XCTAssertGreaterThan(results[0].relevanceScore, results[1].relevanceScore)
    }

    // MARK: Overlap / multi-source boost

    func test_mergeAndRank_overlapBoostsAboveUniqueResult() {
        // "shared" appears in both keyword (rank 1) and semantic (rank 1).
        // "unique" appears only in keyword (rank 2).
        // shared should outscore unique.
        let shared = makeResult(id: "shared")
        let unique = makeResult(id: "unique")
        let results = engine.mergeAndRank(
            keyword:  [shared, unique],
            semantic: [shared],
            targeted: [],
            contactMatchedIDs: [], filters: SearchFilters()
        )
        XCTAssertEqual(results[0].id, "shared")
    }

    func test_mergeAndRank_deduplicates_sameID() {
        // The same ID in two sources should produce exactly one result.
        let r = makeResult(id: "dup")
        let results = engine.mergeAndRank(
            keyword: [r], semantic: [r], targeted: [r],
            contactMatchedIDs: [], filters: SearchFilters()
        )
        XCTAssertEqual(results.count, 1)
    }

    // MARK: Source boost (targeted ×1.5)

    func test_mergeAndRank_targetedBoostOutranksKeywordRank1() {
        // targeted-only at rank 1 vs keyword-only at rank 1.
        // targeted gets 1.5× boost so it wins.
        let kw  = makeResult(id: "kw")   // keyword rank 1
        let tgt = makeResult(id: "tgt")  // targeted rank 1
        let results = engine.mergeAndRank(
            keyword: [kw], semantic: [], targeted: [tgt],
            contactMatchedIDs: [], filters: SearchFilters()
        )
        // kw:  1/(60+1)       ≈ 0.01639
        // tgt: 1/(60+1)×1.5   ≈ 0.02459
        XCTAssertEqual(results[0].id, "tgt")
    }

    // MARK: Recency boost

    func test_mergeAndRank_recentItemOvercomesRankDisadvantage() {
        let old    = Date(timeIntervalSinceNow: -60 * 86_400)   // 60 d → no boost
        let recent = Date(timeIntervalSinceNow: -1 * 86_400)    // 1 d  → ×1.5

        let rOld    = makeResult(id: "old",    timestamp: old)
        let rRecent = makeResult(id: "recent", timestamp: recent)

        // rOld at keyword rank 1, rRecent at rank 2.
        let results = engine.mergeAndRank(
            keyword: [rOld, rRecent], semantic: [], targeted: [],
            contactMatchedIDs: [], filters: SearchFilters(),
            now: Date()
        )
        // old:    1/61         ≈ 0.01639
        // recent: 1/62 × 1.5  ≈ 0.02419 → wins despite rank 2
        XCTAssertEqual(results[0].id, "recent")
    }

    func test_mergeAndRank_within30Days_gets1_2xBoost() {
        let moderate = Date(timeIntervalSinceNow: -15 * 86_400)  // 15 d → ×1.2
        let old      = Date(timeIntervalSinceNow: -60 * 86_400)  // 60 d → ×1.0

        let rMod = makeResult(id: "mod", timestamp: moderate)
        let rOld = makeResult(id: "old", timestamp: old)

        let results = engine.mergeAndRank(
            keyword: [rOld, rMod], semantic: [], targeted: [],
            contactMatchedIDs: [], filters: SearchFilters(),
            now: Date()
        )
        // old: 1/61           ≈ 0.01639
        // mod: 1/62 × 1.2    ≈ 0.01935 → wins despite rank 2
        XCTAssertEqual(results[0].id, "mod")
    }

    // MARK: Contact-match boost (×2.0)

    func test_mergeAndRank_contactMatchOvercomesRankDisadvantage() {
        let old = Date(timeIntervalSinceNow: -60 * 86_400)

        let noMatch = makeResult(id: "no-match", timestamp: old)  // keyword rank 1
        let match   = makeResult(id: "match",    timestamp: old)  // keyword rank 2

        let results = engine.mergeAndRank(
            keyword: [noMatch, match], semantic: [], targeted: [],
            contactMatchedIDs: ["match"],
            filters: SearchFilters(),
            now: Date()
        )
        // no-match: 1/61          ≈ 0.01639
        // match:    1/62 × 2.0   ≈ 0.03226 → wins despite rank 2
        XCTAssertEqual(results[0].id, "match")
    }

    func test_mergeAndRank_contactMatchAndRecencyStackMultipliers() {
        let recent = Date(timeIntervalSinceNow: -1 * 86_400)   // ×1.5
        let old    = Date(timeIntervalSinceNow: -60 * 86_400)

        // "winner" has both recency boost AND contact-match boost.
        let winner = makeResult(id: "winner", timestamp: recent)
        let loser  = makeResult(id: "loser",  timestamp: old)

        let results = engine.mergeAndRank(
            keyword: [winner, loser], semantic: [], targeted: [],
            contactMatchedIDs: ["winner"],
            filters: SearchFilters(),
            now: Date()
        )
        XCTAssertEqual(results[0].id, "winner")
    }

    // MARK: Normalisation

    func test_mergeAndRank_topScoreAlways1() {
        let results = engine.mergeAndRank(
            keyword:  [makeResult(id: "a"), makeResult(id: "b"), makeResult(id: "c")],
            semantic: [makeResult(id: "a")],
            targeted: [],
            contactMatchedIDs: [], filters: SearchFilters()
        )
        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results[0].relevanceScore, 1.0, accuracy: 1e-9)
    }

    func test_mergeAndRank_allScoresBetweenZeroAndOne() {
        let rs = (0..<5).map { makeResult(id: "r\($0)") }
        let results = engine.mergeAndRank(
            keyword: rs, semantic: Array(rs.prefix(3)), targeted: [],
            contactMatchedIDs: [], filters: SearchFilters()
        )
        for r in results {
            XCTAssertGreaterThanOrEqual(r.relevanceScore, 0.0)
            XCTAssertLessThanOrEqual(r.relevanceScore,    1.0)
        }
    }
}

// MARK: - SearchEngineClassifyQueryTests

final class SearchEngineClassifyQueryTests: XCTestCase {

    private var storage: MockSearchEngineStorage!
    private var engine:  SearchEngine!

    override func setUp() {
        super.setUp()
        storage = MockSearchEngineStorage()
        engine  = makeEngine(storage: storage)
    }

    override func tearDown() {
        MockOllamaURLProtocol.reset()
        super.tearDown()
    }

    func test_classifyQuery_parsesPersonIntent() async {
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            let data = makeIntentNDJSON([
                "search_type":  "person",
                "keywords":     ["Jane", "Smith"],
                "date_range":   NSNull(),
                "contact_name": "Jane Smith"
            ])
            return (200, data)
        }

        let intent = await engine.classifyQuery("Jane Smith meetings")
        XCTAssertEqual(intent.searchType,   .person)
        XCTAssertEqual(intent.keywords,     ["Jane", "Smith"])
        XCTAssertEqual(intent.contactName,  "Jane Smith")
    }

    func test_classifyQuery_parsesPromiseIntent() async {
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            let data = makeIntentNDJSON([
                "search_type":  "promise",
                "keywords":     ["follow-up"],
                "date_range":   NSNull(),
                "contact_name": NSNull()
            ])
            return (200, data)
        }

        let intent = await engine.classifyQuery("what did I promise to send?")
        XCTAssertEqual(intent.searchType, .promise)
    }

    func test_classifyQuery_fallsBackToGeneralOnOllamaError() async {
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            (500, Data(#"{"error":"model not loaded"}"#.utf8))
        }

        let intent = await engine.classifyQuery("anything")
        XCTAssertEqual(intent.searchType, .general)
    }

    func test_classifyQuery_fallsBackToGeneralOnInvalidJSON() async {
        // Server returns non-JSON text.
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            let ndjson = "{\"response\":\"not json at all\",\"done\":true}\n"
            return (200, ndjson.data(using: .utf8)!)
        }

        let intent = await engine.classifyQuery("test")
        XCTAssertEqual(intent.searchType, .general)
    }

    func test_classifyQuery_cachedResultReturnedWithoutSecondCall() async {
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()

        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            counter.value += 1
            return (200, makeIntentNDJSON([
                "search_type": "topic", "keywords": [], "date_range": NSNull(), "contact_name": NSNull()
            ]))
        }

        let _ = await engine.classifyQuery("pricing strategy")
        let _ = await engine.classifyQuery("pricing strategy")  // same query → cache hit

        XCTAssertEqual(counter.value, 1, "Ollama should only be called once for the same query within TTL")
    }
}

// MARK: - SearchEngineSearchTests

final class SearchEngineSearchTests: XCTestCase {

    private var storage: MockSearchEngineStorage!
    private var engine:  SearchEngine!

    override func setUp() {
        super.setUp()
        storage = MockSearchEngineStorage()
        registerSearchMocks()
        engine = makeEngine(storage: storage)
    }

    override func tearDown() {
        MockOllamaURLProtocol.reset()
        super.tearDown()
    }

    func test_search_emptyQueryReturnsEmpty() async throws {
        let results = try await engine.search(query: "   ")
        XCTAssertTrue(results.isEmpty)
    }

    func test_search_keywordResultsAppearsInOutput() async throws {
        let kwResult = makeResult(id: "kw-hit")
        await storage.seed(keywordInteractionResults: [kwResult])

        let results = try await engine.search(query: "pricing")
        XCTAssertTrue(results.contains { $0.id == "kw-hit" })
    }

    func test_search_semanticResultsAppearInOutput() async throws {
        // Seed a stored interaction that the vector search pair will resolve to.
        let ix = Interaction(
            id: "sem-ix",
            source: .audio,
            interactionType: .meeting,
            startedAt: Date(timeIntervalSinceNow: -86_400),
            summary: "Pricing discussion"
        )
        await storage.seed(interactions: [ix])
        await storage.seed(vectorInteractionPairs: [(interactionId: "sem-ix", distance: 0.1)])

        let results = try await engine.search(query: "pricing")
        XCTAssertTrue(results.contains { $0.id == "sem-ix" })
    }

    func test_search_personIntentDispatchesContactQuery() async throws {
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, makeIntentNDJSON([
                "search_type": "person", "keywords": ["Jane"],
                "date_range": NSNull(), "contact_name": "Jane"
            ]))
        }

        let contactResult = makeResult(id: "contact-ix")
        await storage.seed(contactInteractionResults: [contactResult])

        let filter = SearchFilters(contactId: "contact-123")
        _ = try await engine.search(query: "Jane meetings", filters: filter)

        let count = await storage.contactQueryCount
        XCTAssertEqual(count, 1, "Person intent with contactId should trigger fetchInteractions(forContactId:)")
    }

    func test_search_promiseIntentDispatchesPromiseQuery() async throws {
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, makeIntentNDJSON([
                "search_type": "promise", "keywords": ["send"],
                "date_range": NSNull(), "contact_name": NSNull()
            ]))
        }

        _ = try await engine.search(query: "what did I promise to send?")

        let count = await storage.promiseQueryCount
        XCTAssertGreaterThanOrEqual(count, 1, "Promise intent should trigger fetchOpenPromises")
    }

    func test_search_billingIntentDispatchesWorkSessionQuery() async throws {
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, makeIntentNDJSON([
                "search_type": "billing", "keywords": ["hours"],
                "date_range": NSNull(), "contact_name": NSNull()
            ]))
        }

        _ = try await engine.search(query: "how many hours did I log last month?")

        let count = await storage.workSessionCount
        XCTAssertEqual(count, 1, "Billing intent should trigger fetchWorkSessions")
    }

    func test_search_timerangeIntentDispatchesDateRangeQuery() async throws {
        let from = Date(timeIntervalSinceNow: -7 * 86_400)
        let to   = Date()
        let isoFormatter = ISO8601DateFormatter()

        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, makeIntentNDJSON([
                "search_type": "timerange",
                "keywords": [],
                "date_range": [
                    "from": isoFormatter.string(from: from),
                    "to":   isoFormatter.string(from: to)
                ],
                "contact_name": NSNull()
            ]))
        }

        _ = try await engine.search(query: "meetings this week")

        let count = await storage.dateRangeQueryCount
        XCTAssertEqual(count, 1, "Timerange intent with date_range should trigger fetchInteractions(inDateRange:)")
    }

    func test_search_resultsAreSortedByRelevanceDescending() async throws {
        // Three distinct keyword results; no overlap with other sources.
        let rs = (0..<3).map { makeResult(id: "r\($0)") }
        await storage.seed(keywordInteractionResults: rs)

        let results = try await engine.search(query: "anything")
        guard results.count >= 2 else { return }
        for i in 0..<(results.count - 1) {
            XCTAssertGreaterThanOrEqual(
                results[i].relevanceScore,
                results[i + 1].relevanceScore,
                "Results at index \(i) should have score ≥ index \(i+1)"
            )
        }
    }

    func test_search_generalIntentDoesNotTriggerTargetedQueries() async throws {
        // Default mock returns "general" intent.
        registerSearchMocks()

        _ = try await engine.search(query: "random stuff")

        let contactCount   = await storage.contactQueryCount
        let dateRangeCount = await storage.dateRangeQueryCount
        let workCount      = await storage.workSessionCount
        XCTAssertEqual(contactCount,   0, "General intent should not query contact timeline")
        XCTAssertEqual(dateRangeCount, 0, "General intent should not query date range")
        XCTAssertEqual(workCount,      0, "General intent should not query work sessions")
    }
}
