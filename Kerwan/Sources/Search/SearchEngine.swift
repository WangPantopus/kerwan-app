import Foundation
import os

/// Unified search across keyword (FTS5), semantic (sqlite-vec KNN), and natural-language queries.
///
/// ## Query lifecycle
///
/// 1. **Intent classification** — ``classifyQuery(_:)`` calls Ollama with `format: json`
///    to categorise the query into one of six ``QueryIntent/SearchType`` values.
///    Results are cached for ``intentCacheTTL`` (30 s) to avoid redundant LLM calls
///    during rapid re-queries.
///
/// 2. **Parallel retrieval** — three searches run concurrently via `async let`:
///    - Keyword FTS5 (top ``topK`` interactions + promises)
///    - Semantic KNN (embed query → top ``topK`` interactions + promises, enriched)
///    - Targeted domain query based on intent (contact timeline, date window, etc.)
///
/// 3. **RRF merge** — ``mergeAndRank(keyword:semantic:targeted:contactMatchedIDs:filters:now:)``
///    fuses all results using Reciprocal Rank Fusion (k = ``rrfK`` = 60) with boosts:
///    - Targeted source: ×1.5
///    - Recency within 7 days: ×1.5; within 30 days: ×1.2
///    - Contact-match (result ID in `contactMatchedIDs`): ×2.0
///
/// 4. **Score normalisation** — final scores are normalised to 0.0–1.0 and returned
///    sorted descending.
///
/// ## Public API
///
/// ```swift
/// // Unrestricted search:
/// let results = try await engine.search(query: "pricing discussion with Acme")
///
/// // Filtered to a contact + date window:
/// let results = try await engine.search(
///     query: "last month follow-ups",
///     filters: SearchFilters(contactId: "...", dateRange: interval)
/// )
/// ```
public actor SearchEngine {

    // MARK: - Constants

    /// Ollama model used for intent classification.
    public static let intentModel = "llama3:8b-instruct-q4_K_M"

    /// Maximum number of results fetched from each keyword or semantic source.
    public static let topK = 50

    /// How long a cached ``QueryIntent`` remains valid before re-classifying.
    public static let intentCacheTTL: Duration = .seconds(30)

    /// Reciprocal Rank Fusion constant. Higher values reduce individual rank impact.
    public static let rrfK: Double = 60

    // MARK: - Logging

    private static let logger = Logger(subsystem: "com.kerwan.app", category: "SearchEngine")

    // MARK: - Dependencies

    private let client:    OllamaClient
    private let storage:   any SearchEngineStorage
    private let embedding: EmbeddingService

    // MARK: - State

    /// Cached intent keyed by normalised query string.
    private var intentCache: [String: (intent: QueryIntent, cachedAt: Date)] = [:]

    // MARK: - Init

    /// Creates a `SearchEngine`.
    ///
    /// - Parameters:
    ///   - client: A configured ``OllamaClient`` for intent classification.
    ///   - storage: A ``SearchEngineStorage``-conforming actor.
    ///   - embedding: A running ``EmbeddingService`` for query vectorisation.
    public init(
        client:    OllamaClient,
        storage:   any SearchEngineStorage,
        embedding: EmbeddingService
    ) {
        self.client    = client
        self.storage   = storage
        self.embedding = embedding
    }

    // MARK: - Public: Unified Search

    /// Executes a unified search and returns results ranked by combined relevance.
    ///
    /// - Parameters:
    ///   - query: Natural-language search query.
    ///   - filters: Optional filters to narrow the result set.
    /// - Returns: Results sorted by RRF score descending, normalised to 0.0–1.0.
    public func search(
        query:   String,
        filters: SearchFilters = SearchFilters()
    ) async throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Step 1: Classify intent (cached; falls back to .general on failure).
        let intent = await classifyQuery(trimmed)

        // Step 2: Embed query vector for semantic search.
        let queryVector = try await embedding.embedQuery(trimmed)

        // Step 3: Parallel retrieval across all three search paths.
        async let kwTask  = keywordSearch(query: trimmed)
        async let semTask = semanticSearch(vector: queryVector)
        async let tgtTask = targetedSearch(intent: intent, filters: filters, query: trimmed)

        let kwResults  = try await kwTask
        let semResults = try await semTask
        let (tgtResults, contactMatchedIDs) = try await tgtTask

        // Step 4: Merge with RRF and return ranked results.
        return mergeAndRank(
            keyword:           kwResults,
            semantic:          semResults,
            targeted:          tgtResults,
            contactMatchedIDs: contactMatchedIDs,
            filters:           filters
        )
    }

    // MARK: - Internal: Intent Classification

    /// Classifies `query` and returns a structured ``QueryIntent``.
    ///
    /// Results are cached for ``intentCacheTTL`` (30 s). Any Ollama failure silently
    /// falls back to ``QueryIntent/generalFallback``.
    ///
    /// Internal visibility allows tests to verify intent extraction without calling
    /// the full `search` pipeline.
    func classifyQuery(_ query: String) async -> QueryIntent {
        // Cache hit?
        if let cached = intentCache[query] {
            let elapsed = -cached.cachedAt.timeIntervalSinceNow
            let ttl     = TimeInterval(Self.intentCacheTTL.components.seconds)
            if elapsed < ttl { return cached.intent }
            intentCache.removeValue(forKey: query)
        }

        do {
            let raw = try await client.completeJSON(
                prompt: Self.intentPrompt(for: query),
                system: Self.intentSystemPrompt,
                model:  Self.intentModel
            )
            guard let dict     = raw as? [String: Any],
                  let jsonData = try? JSONSerialization.data(withJSONObject: dict)
            else { return .generalFallback }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let intent = try decoder.decode(QueryIntent.self, from: jsonData)

            intentCache[query] = (intent: intent, cachedAt: Date())
            return intent

        } catch {
            Self.logger.warning(
                "Intent classification failed for '\(query, privacy: .public)': \(error, privacy: .public)"
            )
            return .generalFallback
        }
    }

    // MARK: - Internal: Merge & Rank (nonisolated — callable without await in tests)

    /// Fuses keyword, semantic, and targeted results using Reciprocal Rank Fusion.
    ///
    /// ### Scoring formula
    ///
    /// For each source, item at rank `r` (1-based) contributes `1/(k + r)` to the
    /// item's raw score. Targeted results receive a 1.5× source boost applied at
    /// contribution time. After summing, per-item multipliers are applied:
    ///
    /// - Recency ≤7 d → ×1.5; ≤30 d → ×1.2
    /// - Contact match (`contactMatchedIDs`) → ×2.0
    ///
    /// Final scores are normalised so the top result has `relevanceScore = 1.0`.
    ///
    /// This method is `nonisolated` so tests can invoke it synchronously.
    nonisolated func mergeAndRank(
        keyword:           [SearchResult],
        semantic:          [SearchResult],
        targeted:          [SearchResult],
        contactMatchedIDs: Set<EntityID>,
        filters:           SearchFilters,
        now:               Date = Date()
    ) -> [SearchResult] {
        var scores:      [EntityID: Double]      = [:]
        var resultsByID: [EntityID: SearchResult] = [:]

        func addRanked(_ results: [SearchResult], boost: Double) {
            for (index, result) in results.enumerated() {
                let contribution = (1.0 / (Self.rrfK + Double(index + 1))) * boost
                scores[result.id, default: 0.0] += contribution
                if resultsByID[result.id] == nil {
                    resultsByID[result.id] = result
                }
            }
        }

        addRanked(keyword,  boost: 1.0)
        addRanked(semantic, boost: 1.0)
        addRanked(targeted, boost: 1.5)

        // Apply recency and contact-match multipliers.
        for id in scores.keys {
            guard let result = resultsByID[id] else { continue }
            var mult = 1.0
            let age  = now.timeIntervalSince(result.timestamp)
            if age <= 7 * 86_400       { mult *= 1.5 }
            else if age <= 30 * 86_400 { mult *= 1.2 }
            if contactMatchedIDs.contains(id) { mult *= 2.0 }
            scores[id]? *= mult
        }

        let sorted = scores.sorted { $0.value > $1.value }
        guard let maxScore = sorted.first?.value, maxScore > 0 else { return [] }

        return sorted.compactMap { id, score in
            guard let r = resultsByID[id] else { return nil }
            return SearchResult(
                id:             r.id,
                type:           r.type,
                title:          r.title,
                snippet:        r.snippet,
                timestamp:      r.timestamp,
                relevanceScore: score / maxScore,
                contactName:    r.contactName,
                clientName:     r.clientName
            )
        }
    }

    // MARK: - Private: Keyword Search

    /// Runs FTS5 keyword search across interactions and promises.
    private func keywordSearch(query: String) async throws -> [SearchResult] {
        async let interactions = storage.keywordSearchInteractions(query: query, limit: Self.topK)
        async let promises     = storage.keywordSearchPromises(query: query, limit: Self.topK)
        let (i, p) = try await (interactions, promises)
        return i + p
    }

    // MARK: - Private: Semantic Search

    /// Embeds the query, runs KNN search on both interaction and promise vectors,
    /// enriches the raw pairs into ``SearchResult`` objects, and returns them.
    private func semanticSearch(vector: [Float]) async throws -> [SearchResult] {
        async let iSearch = storage.vectorSearchInteractions(embedding: vector, limit: Self.topK)
        async let pSearch = storage.vectorSearchPromises(embedding: vector, limit: Self.topK)
        let (iPairs, pPairs) = try await (iSearch, pSearch)

        // Compute max distance for similarity normalisation (all vectors same space).
        let allDists = iPairs.map { Double($0.distance) } + pPairs.map { Double($0.distance) }
        let maxDist  = max(allDists.max() ?? 1.0, 1e-6)

        // Parallel enrichment fetch.
        let iIDs = iPairs.map(\.interactionId)
        let pIDs = pPairs.map(\.promiseId)
        async let iFetch = storage.fetchInteractions(ids: iIDs)
        async let pFetch = storage.fetchPromises(ids: pIDs)
        let (interactions, promises) = try await (iFetch, pFetch)

        let interactionMap = Dictionary(uniqueKeysWithValues: interactions.map { ($0.id, $0) })
        let promiseMap     = Dictionary(uniqueKeysWithValues: promises.map     { ($0.id, $0) })

        var results: [SearchResult] = []

        for pair in iPairs {
            guard let ix = interactionMap[pair.interactionId] else { continue }
            let similarity = max(0.0, 1.0 - Double(pair.distance) / maxDist)
            results.append(SearchResult(
                id:             ix.id,
                type:           .interaction,
                title:          ix.summary ?? "Interaction",
                snippet:        ix.summary ?? "",
                timestamp:      ix.startedAt,
                relevanceScore: similarity
            ))
        }

        for pair in pPairs {
            guard let p = promiseMap[pair.promiseId] else { continue }
            let similarity = max(0.0, 1.0 - Double(pair.distance) / maxDist)
            results.append(SearchResult(
                id:             p.id,
                type:           .promise,
                title:          p.description,
                snippet:        p.sourceQuote ?? p.description,
                timestamp:      p.extractedAt,
                relevanceScore: similarity
            ))
        }

        return results
    }

    // MARK: - Private: Targeted Search

    /// Runs an intent-specific storage query and returns results plus the set of
    /// contact-matched IDs (used later to apply the ×2.0 contact boost in RRF).
    private func targetedSearch(
        intent:  QueryIntent,
        filters: SearchFilters,
        query:   String
    ) async throws -> ([SearchResult], Set<EntityID>) {
        var results: [SearchResult] = []
        var contactMatchedIDs: Set<EntityID> = []

        switch intent.searchType {
        case .person:
            if let contactId = filters.contactId {
                // Filters already identify the contact; fetch their interaction timeline.
                let r = try await storage.fetchInteractions(
                    forContactId: contactId,
                    limit: Self.topK
                )
                results           = r
                contactMatchedIDs = Set(r.map(\.id))
            } else if let name = intent.contactName, !name.isEmpty {
                // Fall back to FTS5 using the detected name as a query.
                results = try await storage.keywordSearchInteractions(
                    query: name,
                    limit: Self.topK
                )
            }

        case .promise:
            // Combine open promises with keyword hits on promise descriptions.
            let open = try await storage.fetchOpenPromises(
                forContactId: filters.contactId,
                limit: Self.topK
            )
            let kw = try await storage.keywordSearchPromises(query: query, limit: Self.topK)
            let existing = Set(open.map(\.id))
            results = open + kw.filter { !existing.contains($0.id) }

        case .billing:
            results = try await storage.fetchWorkSessions(
                inDateRange: filters.dateRange,
                limit: Self.topK
            )

        case .timerange:
            let range = intent.dateRange?.dateInterval ?? filters.dateRange
            if let range {
                results = try await storage.fetchInteractions(
                    inDateRange: range,
                    interactionTypes: filters.includeTypes,
                    limit: Self.topK
                )
            }

        case .topic, .general:
            // Keyword + semantic is sufficient; no targeted query.
            break
        }

        return (results, contactMatchedIDs)
    }

    // MARK: - Private: Prompt builders

    private static let intentSystemPrompt =
        "You classify search queries. Respond only with a valid JSON object. No markdown, no explanation."

    private static func intentPrompt(for query: String) -> String {
        """
        Classify this search query. Query: "\(query)"

        Return exactly this JSON (no other text):
        {
          "search_type": "<person|promise|billing|timerange|topic|general>",
          "keywords": ["word1", "word2"],
          "date_range": {"from": "2024-01-01T00:00:00Z", "to": "2024-12-31T23:59:59Z"} or null,
          "contact_name": "Full Name" or null
        }

        search_type definitions:
        - person: mentions a specific person by name
        - promise: about commitments, action items, follow-ups, to-dos
        - billing: about hours, invoices, work sessions, billing
        - timerange: references a time period (last week, in March, yesterday)
        - topic: asks about a specific topic or subject
        - general: anything else
        """
    }
}
