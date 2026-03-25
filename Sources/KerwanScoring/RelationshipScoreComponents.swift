import Foundation

// MARK: - RelationshipScoreComponents

/// The individual factor contributions that sum to a contact's relationship score.
///
/// Exposed alongside the final score so the UI can explain *why* a contact received
/// a particular score and surface actionable nudges (e.g. "3 overdue promises are
/// reducing your score by 1.5 points").
public struct RelationshipScoreComponents: Sendable, Equatable {

    // MARK: - Factor values

    /// Points from interaction recency. Range: 0–3.
    ///
    /// - 3.0: interaction within the last 24 hours
    /// - 2.0: interaction within the last 7 days
    /// - 1.0: interaction within the last 30 days
    /// - 0.0: no interaction in the last 30 days (or ever)
    public let recency: Double

    /// Points from interaction frequency over the last 30 days. Range: 0–2.
    ///
    /// - 2.0: > 10 interactions / month
    /// - 1.5: 5–10 interactions / month
    /// - 1.0: 1–4 interactions / month
    /// - 0.0: no interactions
    public let frequency: Double

    /// Bonus from keeping open promises. Range: 0–2.
    ///
    /// Starts at 2.0 and loses 0.5 for each overdue promise (capped at −2.0).
    /// Four or more overdue promises yield 0.
    public let promiseBonus: Double

    /// Points from outbound/inbound interaction balance over the last 30 days. Range: 0–1.5.
    ///
    /// - 1.5: balanced or all-mutual (e.g. all meetings)
    /// - 0.5: completely one-sided (only outbound or only inbound)
    /// - 0.0: no interactions in the window
    public let directionBalance: Double

    /// Points from sentiment trajectory. Range: 0–1.5.
    ///
    /// Compares the weighted-average sentiment of the last 30 days against the
    /// preceding 31–90 day window:
    /// - 1.5: improving (delta > 0.15)
    /// - 1.0: stable    (|delta| ≤ 0.15) — or no prior data and recent avg ≥ 0.35
    /// - 0.5: declining (delta < −0.15)  — or no prior data and recent avg < 0.35
    public let sentimentTrend: Double

    // MARK: - Computed total

    /// Final relationship score, clamped to [0, 10].
    ///
    /// Theoretical maximum: recency(3) + frequency(2) + promiseBonus(2)
    ///   + directionBalance(1.5) + sentimentTrend(1.5) = **10.0**
    public var total: Double {
        let raw = recency + frequency + promiseBonus + directionBalance + sentimentTrend
        return max(0.0, min(10.0, raw))
    }

    public init(
        recency: Double,
        frequency: Double,
        promiseBonus: Double,
        directionBalance: Double,
        sentimentTrend: Double
    ) {
        self.recency          = recency
        self.frequency        = frequency
        self.promiseBonus     = promiseBonus
        self.directionBalance = directionBalance
        self.sentimentTrend   = sentimentTrend
    }
}

// MARK: - RelationshipScoreResult

/// The outcome of scoring a single contact.
public struct RelationshipScoreResult: Sendable {
    /// The contact that was scored.
    public let contactId: String
    /// Final 0–10 score (already clamped).
    public let score: Double
    /// Per-factor breakdown for UI explanation and debugging.
    public let components: RelationshipScoreComponents
    /// When the score was calculated.
    public let computedAt: Date

    public init(
        contactId: String,
        components: RelationshipScoreComponents,
        computedAt: Date = Date()
    ) {
        self.contactId  = contactId
        self.components = components
        self.score      = components.total
        self.computedAt = computedAt
    }
}

// MARK: - RelationshipScoringReport

/// Summary of a completed nightly scoring pass.
public struct RelationshipScoringReport: Sendable {
    /// Number of contacts whose scores were successfully computed and written.
    public let contactsScored: Int
    /// Contact IDs that failed to score (e.g. due to a storage error). Normally empty.
    public let failedContactIds: [String]
    /// Wall-clock duration of the full scoring pass.
    public let duration: TimeInterval
    /// When the pass started.
    public let startedAt: Date
    /// When the pass finished.
    public let finishedAt: Date

    public init(
        contactsScored: Int,
        failedContactIds: [String],
        startedAt: Date,
        finishedAt: Date
    ) {
        self.contactsScored   = contactsScored
        self.failedContactIds = failedContactIds
        self.startedAt        = startedAt
        self.finishedAt       = finishedAt
        self.duration         = finishedAt.timeIntervalSince(startedAt)
    }
}
