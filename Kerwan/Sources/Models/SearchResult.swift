import Foundation

/// A single result from a keyword (FTS5) or semantic (sqlite-vec) search query.
///
/// Search results are a denormalized, UI-ready view combining data from
/// multiple entity tables. The ``relevanceScore`` blends FTS5 rank and
/// cosine similarity (for hybrid search) into a single 0.0–1.0 score
/// for sort ordering.
public struct SearchResult: Codable, Sendable, Identifiable, Hashable {
    /// Unique identifier (UUID string), matching the source entity's ID.
    public let id: EntityID

    /// The type of entity this result points to.
    public let type: SearchResultType

    /// A short title suitable for display in a result list
    /// (e.g., "Meeting with Jane Smith" or "Invoice discussion promise").
    public let title: String

    /// A snippet of matching text with search terms highlighted or
    /// contextualized (e.g., "...discussed the **pricing** for Q2...").
    public let snippet: String

    /// The timestamp most relevant to this result (interaction start time,
    /// promise extraction time, session start, etc.).
    public let timestamp: Date

    /// Combined relevance score from 0.0 (weakly relevant) to 1.0
    /// (highly relevant). Blends FTS5 rank and cosine similarity.
    public let relevanceScore: Double

    /// The display name of the contact associated with this result, if any.
    public let contactName: String?

    /// The display name of the client associated with this result, if any.
    public let clientName: String?

    public init(
        id: EntityID,
        type: SearchResultType,
        title: String,
        snippet: String,
        timestamp: Date,
        relevanceScore: Double,
        contactName: String? = nil,
        clientName: String? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.snippet = snippet
        self.timestamp = timestamp
        self.relevanceScore = max(0.0, min(1.0, relevanceScore))
        self.contactName = contactName
        self.clientName = clientName
    }
}

/// The entity type a search result refers to.
public enum SearchResultType: String, Codable, Sendable, CaseIterable {
    /// An ``Interaction`` record (meeting, email, call, etc.).
    case interaction
    /// A ``Contact`` record.
    case contact
    /// A ``Promise`` (action item / commitment).
    case promise
    /// A ``WorkSession`` (billable time block).
    case workSession
}
