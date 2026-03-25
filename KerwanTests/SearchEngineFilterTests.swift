import XCTest
@testable import Kerwan

/// Tests for ``SearchEngine/mergeAndRank`` date-range filtering.
///
/// ``SearchEngine/search(query:filters:)`` integration tests (intent dispatch,
/// keyword/semantic/targeted paths) are already covered exhaustively in
/// ``SearchEngineTests``. This file focuses on the pre-filter step inside
/// `mergeAndRank` that applies ``SearchFilters/dateRange`` to remove results
/// whose timestamps fall outside the requested window.
final class SearchEngineFilterTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a ``SearchEngine`` wired to mock Ollama and the given storage.
    /// Mirrors the private `makeEngine` in SearchEngineTests so filter tests
    /// can also exercise the full `search()` pipeline when needed.
    private func makeEngine(storage: MockSearchEngineStorage) -> SearchEngine {
        let session    = MockOllamaURLProtocol.makeSession()
        let client     = OllamaClient(session: session)
        let embStorage = MockEmbeddingStorage()
        let embService = EmbeddingService(client: client, storage: embStorage)
        return SearchEngine(client: client, storage: storage, embedding: embService)
    }

    /// Builds a ``SearchResult`` with a controllable timestamp and ID.
    private func makeResult(
        id:        String = UUID().uuidString,
        timestamp: Date,
        score:     Double = 0.5
    ) -> SearchResult {
        SearchResult(
            id:             id,
            type:           .interaction,
            title:          "Test result",
            snippet:        "Snippet",
            timestamp:      timestamp,
            relevanceScore: score
        )
    }

    /// A fixed "now" that tests use as an anchor so date arithmetic is deterministic.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - dateRange filter: exclusion

    /// Results whose timestamp predates the start of the filter window are removed.
    func test_mergeAndRank_dateRange_excludesResultBeforeRange() {
        let storage = MockSearchEngineStorage()
        let engine  = makeEngine(storage: storage)

        let rangeStart = now
        let rangeEnd   = now.addingTimeInterval(86_400)          // +1 day
        let filters    = SearchFilters(dateRange: DateInterval(start: rangeStart, end: rangeEnd))

        let tooOld   = makeResult(timestamp: rangeStart.addingTimeInterval(-1))   // 1 sec before
        let inRange  = makeResult(id: "in-range", timestamp: rangeStart.addingTimeInterval(3_600))

        let results = engine.mergeAndRank(
            keyword:           [tooOld, inRange],
            semantic:          [],
            targeted:          [],
            contactMatchedIDs: [],
            filters:           filters,
            now:               now
        )

        let ids = results.map(\.id)
        XCTAssertFalse(ids.contains(tooOld.id),  "Pre-range result must be excluded")
        XCTAssertTrue(ids.contains("in-range"),   "In-range result must be kept")
    }

    /// Results whose timestamp falls after the end of the filter window are removed.
    func test_mergeAndRank_dateRange_excludesResultAfterRange() {
        let storage = MockSearchEngineStorage()
        let engine  = makeEngine(storage: storage)

        let rangeEnd = now.addingTimeInterval(86_400)
        let filters  = SearchFilters(dateRange: DateInterval(start: now, end: rangeEnd))

        let tooNew  = makeResult(timestamp: rangeEnd.addingTimeInterval(1))   // 1 sec after end
        let inRange = makeResult(id: "in-range", timestamp: now.addingTimeInterval(3_600))

        let results = engine.mergeAndRank(
            keyword:           [tooNew, inRange],
            semantic:          [],
            targeted:          [],
            contactMatchedIDs: [],
            filters:           filters,
            now:               now
        )

        XCTAssertFalse(results.map(\.id).contains(tooNew.id), "Post-range result must be excluded")
        XCTAssertTrue(results.map(\.id).contains("in-range"))
    }

    // MARK: - dateRange filter: boundary inclusion

    /// `DateInterval.contains` is start-inclusive and end-inclusive in Swift;
    /// a result timestamped exactly at the boundary must be kept.
    func test_mergeAndRank_dateRange_boundaryTimestamp_isIncluded() {
        let storage = MockSearchEngineStorage()
        let engine  = makeEngine(storage: storage)

        let rangeEnd = now.addingTimeInterval(86_400)
        let filters  = SearchFilters(dateRange: DateInterval(start: now, end: rangeEnd))

        // Timestamp exactly at start boundary.
        let atStart = makeResult(id: "at-start", timestamp: now)
        // Timestamp exactly at end boundary.
        let atEnd   = makeResult(id: "at-end",   timestamp: rangeEnd)

        let results = engine.mergeAndRank(
            keyword:           [atStart, atEnd],
            semantic:          [],
            targeted:          [],
            contactMatchedIDs: [],
            filters:           filters,
            now:               now
        )

        let ids = results.map(\.id)
        XCTAssertTrue(ids.contains("at-start"), "Start-boundary timestamp must be included")
        XCTAssertTrue(ids.contains("at-end"),   "End-boundary timestamp must be included")
    }

    // MARK: - dateRange filter: all results filtered → empty return

    func test_mergeAndRank_dateRange_allResultsOutsideRange_returnsEmpty() {
        let storage = MockSearchEngineStorage()
        let engine  = makeEngine(storage: storage)

        let rangeStart = now
        let rangeEnd   = now.addingTimeInterval(3_600)
        let filters    = SearchFilters(dateRange: DateInterval(start: rangeStart, end: rangeEnd))

        let before = makeResult(timestamp: rangeStart.addingTimeInterval(-7_200))
        let after  = makeResult(timestamp: rangeEnd.addingTimeInterval(7_200))

        let results = engine.mergeAndRank(
            keyword:           [before],
            semantic:          [after],
            targeted:          [],
            contactMatchedIDs: [],
            filters:           filters,
            now:               now
        )

        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - No filter: all results pass through

    func test_mergeAndRank_nilDateRange_noFilteringApplied() {
        let storage = MockSearchEngineStorage()
        let engine  = makeEngine(storage: storage)

        let r1 = makeResult(id: "r1", timestamp: now.addingTimeInterval(-86_400 * 365)) // 1 year old
        let r2 = makeResult(id: "r2", timestamp: now.addingTimeInterval( 86_400 * 365)) // 1 year future
        let r3 = makeResult(id: "r3", timestamp: now)

        let results = engine.mergeAndRank(
            keyword:           [r1, r2, r3],
            semantic:          [],
            targeted:          [],
            contactMatchedIDs: [],
            filters:           SearchFilters(),   // no dateRange
            now:               now
        )

        let ids = Set(results.map(\.id))
        XCTAssertTrue(ids.contains("r1"))
        XCTAssertTrue(ids.contains("r2"))
        XCTAssertTrue(ids.contains("r3"))
    }

    // MARK: - Filter applies across all three source arrays

    /// The dateRange filter must be applied to keyword, semantic, AND targeted
    /// results independently — not just one of the three arrays.
    func test_mergeAndRank_dateRange_appliedToAllThreeSources() {
        let storage = MockSearchEngineStorage()
        let engine  = makeEngine(storage: storage)

        let rangeStart = now
        let rangeEnd   = now.addingTimeInterval(86_400)
        let filters    = SearchFilters(dateRange: DateInterval(start: rangeStart, end: rangeEnd))

        let stale = makeResult(id: "stale", timestamp: rangeStart.addingTimeInterval(-3_600))
        let fresh = makeResult(id: "fresh", timestamp: rangeStart.addingTimeInterval( 3_600))

        // Each source contributes one stale and one fresh result.
        let results = engine.mergeAndRank(
            keyword:           [makeResult(id: "kw-stale", timestamp: stale.timestamp),
                                makeResult(id: "kw-fresh", timestamp: fresh.timestamp)],
            semantic:          [makeResult(id: "sem-stale", timestamp: stale.timestamp),
                                makeResult(id: "sem-fresh", timestamp: fresh.timestamp)],
            targeted:          [makeResult(id: "tgt-stale", timestamp: stale.timestamp),
                                makeResult(id: "tgt-fresh", timestamp: fresh.timestamp)],
            contactMatchedIDs: [],
            filters:           filters,
            now:               now
        )

        let ids = Set(results.map(\.id))
        // All stale results (from all three sources) must be excluded.
        XCTAssertFalse(ids.contains("kw-stale"),  "Stale keyword result must be excluded")
        XCTAssertFalse(ids.contains("sem-stale"), "Stale semantic result must be excluded")
        XCTAssertFalse(ids.contains("tgt-stale"), "Stale targeted result must be excluded")
        // All fresh results must survive.
        XCTAssertTrue(ids.contains("kw-fresh"))
        XCTAssertTrue(ids.contains("sem-fresh"))
        XCTAssertTrue(ids.contains("tgt-fresh"))
    }

    // MARK: - Filter interacts correctly with RRF scoring

    /// A result that survives the date-range filter and appears in multiple
    /// sources still receives boosted RRF score (appears in the top results).
    func test_mergeAndRank_dateRange_survivingResultsStillRankedByRRF() {
        let storage = MockSearchEngineStorage()
        let engine  = makeEngine(storage: storage)

        let rangeStart = now.addingTimeInterval(-86_400)
        let rangeEnd   = now
        let filters    = SearchFilters(dateRange: DateInterval(start: rangeStart, end: rangeEnd))

        // Result "shared-id" appears in both keyword and semantic — it should rank highest.
        let sharedTimestamp = now.addingTimeInterval(-3_600)
        let shared   = makeResult(id: "shared-id", timestamp: sharedTimestamp, score: 0.9)
        let unique   = makeResult(id: "unique-id", timestamp: sharedTimestamp, score: 0.5)

        let results = engine.mergeAndRank(
            keyword:           [shared, unique],
            semantic:          [shared],           // shared appears in two sources
            targeted:          [],
            contactMatchedIDs: [],
            filters:           filters,
            now:               now
        )

        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.id, "shared-id",
                       "Result in two sources should rank first after date-range filter passes it")
    }

    // MARK: - Edge: empty result arrays with active filter return empty

    func test_mergeAndRank_dateRange_emptyInputs_returnsEmpty() {
        let storage = MockSearchEngineStorage()
        let engine  = makeEngine(storage: storage)

        let filters = SearchFilters(dateRange: DateInterval(start: now, end: now.addingTimeInterval(3_600)))

        let results = engine.mergeAndRank(
            keyword:           [],
            semantic:          [],
            targeted:          [],
            contactMatchedIDs: [],
            filters:           filters,
            now:               now
        )

        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - contactId filter dispatches targeted contact query

    /// When `filters.contactId` is set, calling the full `search()` pipeline
    /// should dispatch a contact-specific targeted query (incrementing
    /// `MockSearchEngineStorage.contactQueryCount`).
    func test_search_withContactIdFilter_dispatchesContactQuery() async throws {
        MockOllamaURLProtocol.reset()

        // Intent classification returns "general" so the engine won't dispatch a
        // person intent — only the explicit contactId filter should trigger it.
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            let json = #"{"response":"{\"search_type\":\"general\",\"keywords\":[]}","done":true}"#
            return (200, Data(json.utf8))
        }
        MockOllamaURLProtocol.register(path: "api/embeddings") { _ in
            let zeros = Array(repeating: Float(0), count: 768)
            let encoded = try! JSONEncoder().encode(["embedding": zeros])
            return (200, encoded)
        }

        let storage = MockSearchEngineStorage()
        await storage.seed(contactInteractionResults: [])
        let engine  = makeEngine(storage: storage)

        let filters = SearchFilters(contactId: "contact-xyz")
        _ = try await engine.search(query: "project update", filters: filters)

        let count = await storage.contactQueryCount
        XCTAssertGreaterThan(count, 0,
                             "Explicit contactId filter must trigger a contact targeted query")
    }
}
