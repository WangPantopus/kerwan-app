import Foundation

/// The subset of storage operations required by the search pipeline.
///
/// ``SearchEngine`` depends on this protocol rather than the concrete `StorageActor`
/// so the search layer remains fully testable with an in-memory mock and decoupled
/// from the storage workstream.
///
/// ## Keyword search
/// `keywordSearchInteractions` and `keywordSearchPromises` are backed by FTS5 virtual
/// tables. Results must be ordered by BM25 rank (closest match first). Each returned
/// ``SearchResult`` carries a pre-built `snippet` and a `relevanceScore` in `0.0–1.0`
/// derived from the BM25 rank.
///
/// ## Vector search
/// `vectorSearchInteractions` and `vectorSearchPromises` query sqlite-vec KNN indices.
/// They return raw `(id, distance)` pairs so the caller can normalise distance to
/// similarity (`1.0 – distance/maxDistance`) and apply Reciprocal Rank Fusion.
///
/// ## Targeted queries
/// Called based on ``QueryIntent`` to retrieve results within a specific domain
/// (contact timeline, date window, open promises, billing sessions). Each targeted
/// method returns pre-enriched ``SearchResult`` objects with `contactName` and
/// `clientName` populated where available.
public protocol SearchEngineStorage: Actor {

    // MARK: - Keyword Search

    /// Returns the top `limit` FTS5 keyword search results for interactions.
    func keywordSearchInteractions(query: String, limit: Int) async throws -> [SearchResult]

    /// Returns the top `limit` FTS5 keyword search results for promises.
    func keywordSearchPromises(query: String, limit: Int) async throws -> [SearchResult]

    // MARK: - Vector Search

    /// Returns the `limit` nearest interaction embedding vectors and their distances.
    ///
    /// Distances are Euclidean or cosine depending on the index configuration.
    /// The caller normalises to a `0.0–1.0` similarity score before ranking.
    func vectorSearchInteractions(
        embedding: [Float],
        limit: Int
    ) async throws -> [(interactionId: EntityID, distance: Float)]

    /// Returns the `limit` nearest promise embedding vectors and their distances.
    func vectorSearchPromises(
        embedding: [Float],
        limit: Int
    ) async throws -> [(promiseId: EntityID, distance: Float)]

    // MARK: - Enrichment

    /// Fetches ``Interaction`` records for the given IDs in a single batch.
    func fetchInteractions(ids: [EntityID]) async throws -> [Interaction]

    /// Fetches the ``Contact`` record for `id`, or `nil` if not found.
    func fetchContact(id: EntityID) async throws -> Contact?

    /// Fetches ``Promise`` records for the given IDs in a single batch.
    func fetchPromises(ids: [EntityID]) async throws -> [Promise]

    // MARK: - Targeted Queries

    /// Returns the most recent `limit` interactions involving `contactId`.
    ///
    /// Results must include `contactName` and `clientName` where available.
    func fetchInteractions(forContactId: EntityID, limit: Int) async throws -> [SearchResult]

    /// Returns interactions whose `startedAt` falls within `dateRange`.
    ///
    /// - Parameters:
    ///   - dateRange: The time window to query.
    ///   - interactionTypes: If non-nil, restricts to these types.
    ///   - limit: Maximum number of results.
    func fetchInteractions(
        inDateRange dateRange: DateInterval,
        interactionTypes: [InteractionType]?,
        limit: Int
    ) async throws -> [SearchResult]

    /// Returns open promises, optionally filtered to a specific contact.
    ///
    /// - Parameters:
    ///   - forContactId: When non-nil, restricts to this contact's promises.
    ///   - limit: Maximum number of results.
    func fetchOpenPromises(forContactId: EntityID?, limit: Int) async throws -> [SearchResult]

    /// Returns work sessions, optionally filtered to a date range.
    ///
    /// - Parameter inDateRange: When non-nil, restricts to sessions within this window.
    func fetchWorkSessions(inDateRange: DateInterval?, limit: Int) async throws -> [SearchResult]
}
