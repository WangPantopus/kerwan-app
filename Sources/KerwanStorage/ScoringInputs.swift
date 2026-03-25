import Foundation

// MARK: - SentimentCounts

/// Raw sentiment histogram for a time window of interactions.
///
/// Used by `RelationshipScoreEngine` to compute the sentiment-trend factor.
public struct SentimentCounts: Sendable, Equatable {
    public let positive: Int
    public let neutral: Int
    public let negative: Int
    public let unknown: Int

    public init(positive: Int = 0, neutral: Int = 0, negative: Int = 0, unknown: Int = 0) {
        self.positive = positive
        self.neutral  = neutral
        self.negative = negative
        self.unknown  = unknown
    }

    /// Total interactions across all sentiment categories.
    public var total: Int { positive + neutral + negative + unknown }

    /// Weighted average where positive=1.0, neutral/unknown=0.5, negative=0.0.
    /// Returns `nil` when there are no interactions.
    public var weightedAverage: Double? {
        guard total > 0 else { return nil }
        let sum = Double(positive) * 1.0
                + Double(neutral)  * 0.5
                + Double(negative) * 0.0
                + Double(unknown)  * 0.5
        return sum / Double(total)
    }
}

// MARK: - DirectionCounts

/// Raw direction histogram for a time window of interactions.
///
/// Used by `RelationshipScoreEngine` to compute the direction-balance factor.
public struct DirectionCounts: Sendable, Equatable {
    /// User-initiated interactions (e.g. sent email, made call).
    public let outbound: Int
    /// Contact-initiated interactions (e.g. received email).
    public let inbound: Int
    /// Mutually-initiated interactions (e.g. meeting, Slack DM thread).
    public let mutual: Int

    public init(outbound: Int = 0, inbound: Int = 0, mutual: Int = 0) {
        self.outbound = outbound
        self.inbound  = inbound
        self.mutual   = mutual
    }

    /// Total interactions across all direction categories.
    public var total: Int { outbound + inbound + mutual }
}

// MARK: - ContactScoreInputs

/// All data needed to compute a single contact's relationship score.
///
/// Fetched from the database by `StorageActor.fetchScoreInputs(contactId:now:)`.
/// The `RelationshipScoreEngine` receives this struct and performs the pure calculation.
public struct ContactScoreInputs: Sendable {
    /// Timestamp of the most recent interaction with this contact (across all time).
    /// `nil` if there have been no interactions.
    public let lastInteractionAt: Date?

    /// Number of interactions in the last 30 days.
    public let interactionCount30d: Int

    /// Direction breakdown for interactions in the last 30 days.
    public let directionCounts30d: DirectionCounts

    /// Number of open, overdue promises *made by the user* to this contact.
    /// An overdue promise has `status = 'open'`, a non-nil `due_date`, and `due_date < now`.
    public let overduePromiseCount: Int

    /// Sentiment histogram for interactions in the last 0–30 days.
    public let recentSentiment: SentimentCounts

    /// Sentiment histogram for interactions in the last 31–90 days.
    /// Empty (all zeros) when the contact has no interactions in that window.
    public let priorSentiment: SentimentCounts

    public init(
        lastInteractionAt: Date?,
        interactionCount30d: Int,
        directionCounts30d: DirectionCounts,
        overduePromiseCount: Int,
        recentSentiment: SentimentCounts,
        priorSentiment: SentimentCounts
    ) {
        self.lastInteractionAt   = lastInteractionAt
        self.interactionCount30d = interactionCount30d
        self.directionCounts30d  = directionCounts30d
        self.overduePromiseCount = overduePromiseCount
        self.recentSentiment     = recentSentiment
        self.priorSentiment      = priorSentiment
    }
}
