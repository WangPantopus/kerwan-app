import Foundation

/// Narrows a search to a subset of the corpus.
///
/// All fields are optional; an empty `SearchFilters()` represents an unrestricted
/// search across the entire database. Active fields are combined as AND conditions.
public struct SearchFilters: Sendable {
    /// Restrict results to interactions involving this contact.
    public var contactId: EntityID?

    /// Restrict results to interactions attributed to this client.
    public var clientId: EntityID?

    /// Restrict results to interactions originating from this capture source.
    public var source: EventSource?

    /// Restrict results to interactions whose `startedAt` falls within this interval.
    public var dateRange: DateInterval?

    /// Restrict to these interaction types. `nil` means all types.
    public var includeTypes: [InteractionType]?

    public init(
        contactId:    EntityID? = nil,
        clientId:     EntityID? = nil,
        source:       EventSource? = nil,
        dateRange:    DateInterval? = nil,
        includeTypes: [InteractionType]? = nil
    ) {
        self.contactId    = contactId
        self.clientId     = clientId
        self.source       = source
        self.dateRange    = dateRange
        self.includeTypes = includeTypes
    }
}

// MARK: - QueryIntent

/// The structured intent extracted from a natural-language query by the LLM.
///
/// ``SearchEngine`` uses this to choose which targeted storage queries to run
/// alongside the baseline keyword and semantic searches.
///
/// `CodingKeys` maps Swift camelCase properties to the snake_case keys returned
/// by Ollama's JSON-constrained output.
public struct QueryIntent: Codable, Sendable {

    // MARK: SearchType

    /// Primary semantic category of the query.
    public enum SearchType: String, Codable, Sendable, CaseIterable {
        /// Query mentions a specific person by name.
        case person
        /// Query asks about commitments, action items, or follow-ups.
        case promise
        /// Query asks about hours tracked, invoices, or billable time.
        case billing
        /// Query references a specific date, week, month, or relative time period.
        case timerange
        /// Query asks about a specific topic, subject, or keyword theme.
        case topic
        /// Does not match any of the above categories.
        case general
    }

    // MARK: DateRange

    /// An optional date range extracted from the query.
    public struct DateRange: Codable, Sendable {
        /// Start of the range, inclusive.
        public var from: Date?
        /// End of the range, inclusive.
        public var to: Date?

        public init(from: Date? = nil, to: Date? = nil) {
            self.from = from
            self.to   = to
        }

        /// Converts to a `DateInterval` when both bounds are present.
        public var dateInterval: DateInterval? {
            guard let from, let to else { return nil }
            return DateInterval(start: from, end: to)
        }
    }

    // MARK: Properties

    /// The classified intent type.
    public let searchType: SearchType

    /// Keywords extracted from the query for targeted retrieval.
    public let keywords: [String]

    /// Date range extracted from the query, if any.
    public let dateRange: DateRange?

    /// Contact name detected in the query, present for `.person` searches.
    public let contactName: String?

    // MARK: Init

    public init(
        searchType:  SearchType,
        keywords:    [String] = [],
        dateRange:   DateRange? = nil,
        contactName: String? = nil
    ) {
        self.searchType  = searchType
        self.keywords    = keywords
        self.dateRange   = dateRange
        self.contactName = contactName
    }

    // MARK: CodingKeys

    enum CodingKeys: String, CodingKey {
        case searchType  = "search_type"
        case keywords
        case dateRange   = "date_range"
        case contactName = "contact_name"
    }
}

// MARK: - QueryIntent + convenience

extension QueryIntent {
    /// Fallback intent returned when classification fails.
    static let generalFallback = QueryIntent(searchType: .general)
}
