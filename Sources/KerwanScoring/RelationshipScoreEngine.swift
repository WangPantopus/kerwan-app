import Foundation
import KerwanStorage
import os.log

// MARK: - RelationshipScoreEngine

/// Computes 0–10 relationship scores for all active contacts and persists them.
///
/// ## Scoring formula
///
/// | Factor            | Max  | Description                                              |
/// |-------------------|------|----------------------------------------------------------|
/// | Recency           | 3.0  | How recently the user interacted with the contact        |
/// | Frequency         | 2.0  | How often in the last 30 days                            |
/// | Promise bonus     | 2.0  | Starts full; −0.5 per overdue promise (user-made)        |
/// | Direction balance | 1.5  | Balanced outbound/inbound vs. one-sided                  |
/// | Sentiment trend   | 1.5  | Improving, stable, or declining sentiment trajectory     |
/// | **Total**         | 10.0 | Clamped to [0, 10]                                       |
///
/// ## Threading
///
/// `RelationshipScoreEngine` is an `actor`. All public methods are async and
/// safe to call from any concurrency context.  The heavy lifting (SQL queries)
/// happens on `StorageActor`, which serialises writes.
///
/// ## Usage
///
/// ```swift
/// let engine = RelationshipScoreEngine(storage: storageActor)
/// // Score a single contact on demand (e.g. when opening a contact profile):
/// let result = try await engine.scoreContact(contactId)
/// // Run the nightly batch:
/// let report = try await engine.runNightlyScoring()
/// ```
public actor RelationshipScoreEngine {

    // MARK: - Dependencies

    private let storage: StorageActor
    private let log = Logger(subsystem: "com.kerwan.app", category: "RelationshipScoring")

    // MARK: - Constants

    /// Window used to classify a contact as "active". Contacts with no interaction
    /// in this window are skipped during the nightly pass.
    public static let activeWindowDays: Double = 90

    /// Recency thresholds (in days). Contacts last seen within each window earn the
    /// corresponding points.
    private enum RecencyThreshold {
        static let today: Double = 1       // ≤ 1 day  → 3 pts
        static let week:  Double = 7       // ≤ 7 days → 2 pts
        static let month: Double = 30      // ≤ 30 days→ 1 pt
        // > 30 days → 0 pts
    }

    /// Frequency thresholds (interactions in last 30 days).
    private enum FrequencyThreshold {
        static let high:   Int = 10  // > 10 → 2.0 pts
        static let medium: Int = 5   // 5–10 → 1.5 pts
        static let low:    Int = 1   // 1–4  → 1.0 pt
        // 0 → 0.0 pts
    }

    /// Each overdue promise deducts this many points from the 2.0 promise bonus.
    private static let promisePenaltyPerOverdue: Double = 0.5

    /// Minimum change in weighted-average sentiment between recent and prior windows
    /// that constitutes "improving" or "declining" (rather than "stable").
    private static let sentimentTrendThreshold: Double = 0.15

    // MARK: - Init

    /// Creates a scoring engine backed by the given storage actor.
    ///
    /// - Parameter storage: The app's shared `StorageActor` instance.
    public init(storage: StorageActor) {
        self.storage = storage
    }

    // MARK: - Public API

    /// Scores every contact that has had at least one interaction in the last 90 days.
    ///
    /// Results are written to `contacts.relationship_score` inside a single batch
    /// transaction for efficiency. The method is designed to be called nightly by
    /// `NightlyScoringScheduler`; it is also safe to call on demand.
    ///
    /// - Returns: A `RelationshipScoringReport` summarising the pass.
    /// - Throws: `StorageError` only if the batch write itself fails; individual
    ///   contact computation errors are collected into `report.failedContactIds`.
    public func runNightlyScoring(now: Date = Date()) async throws -> RelationshipScoringReport {
        let startedAt = Date()
        log.info("Nightly scoring pass started.")

        let cutoff = now.addingTimeInterval(-Self.activeWindowDays * 86400)
        let contactIds = await storage.fetchActiveContactIds(since: cutoff)

        log.info("Active contacts to score: \(contactIds.count)")

        var updates: [(contactId: String, score: Double, lastSeenAt: Date)] = []
        var failed: [String] = []

        for contactId in contactIds {
            let inputs = await storage.fetchScoreInputs(contactId: contactId, now: now)
            let components = computeComponents(inputs: inputs, now: now)
            let lastSeenAt = inputs.lastInteractionAt ?? .distantPast
            updates.append((contactId: contactId, score: components.total, lastSeenAt: lastSeenAt))
            log.debug("""
                Scored \(contactId): \(String(format: "%.2f", components.total)) \
                (R:\(components.recency) F:\(components.frequency) \
                P:\(components.promiseBonus) D:\(components.directionBalance) \
                S:\(components.sentimentTrend))
                """)
        }

        // Batch write — one transaction for all updates
        do {
            try await storage.batchUpdateRelationshipScores(updates, scoredAt: now)
        } catch {
            // If the batch fails, try contacts one-by-one to salvage partial results
            log.warning("Batch score update failed (\(error)). Falling back to individual updates.")
            var salvaged: [(contactId: String, score: Double, lastSeenAt: Date)] = []
            for update in updates {
                do {
                    try await storage.updateRelationshipScore(
                        contactId:  update.contactId,
                        score:      update.score,
                        lastSeenAt: update.lastSeenAt,
                        scoredAt:   now
                    )
                    salvaged.append(update)
                } catch {
                    log.error("Failed to persist score for \(update.contactId): \(error)")
                    failed.append(update.contactId)
                }
            }
            updates = salvaged
        }

        let finishedAt = Date()
        let report = RelationshipScoringReport(
            contactsScored:   updates.count,
            failedContactIds: failed,
            startedAt:        startedAt,
            finishedAt:       finishedAt
        )
        log.info("""
            Nightly scoring complete. Scored: \(report.contactsScored), \
            Failed: \(report.failedContactIds.count), \
            Duration: \(String(format: "%.2f", report.duration))s
            """)
        return report
    }

    /// Computes and persists the relationship score for a single contact.
    ///
    /// Use this for real-time refresh when a contact profile is opened or when
    /// a new interaction is recorded. Prefer `runNightlyScoring()` for bulk updates.
    ///
    /// - Parameters:
    ///   - contactId: The contact to score.
    ///   - now:       Reference timestamp (override in tests for determinism).
    /// - Returns: A `RelationshipScoreResult` with the score and per-factor breakdown.
    /// - Throws: `StorageError` if the score cannot be written back.
    @discardableResult
    public func scoreContact(_ contactId: String, now: Date = Date()) async throws -> RelationshipScoreResult {
        let inputs     = await storage.fetchScoreInputs(contactId: contactId, now: now)
        let components = computeComponents(inputs: inputs, now: now)
        let lastSeenAt = inputs.lastInteractionAt ?? .distantPast

        try await storage.updateRelationshipScore(
            contactId:  contactId,
            score:      components.total,
            lastSeenAt: lastSeenAt,
            scoredAt:   now
        )

        return RelationshipScoreResult(
            contactId:  contactId,
            components: components,
            computedAt: now
        )
    }

    // MARK: - Pure calculation (internal for testability)

    /// Computes all five scoring factors from a `ContactScoreInputs` snapshot.
    ///
    /// This is a pure function with no side effects — it can be called without
    /// a live database and is therefore fully unit-testable.
    func computeComponents(inputs: ContactScoreInputs, now: Date) -> RelationshipScoreComponents {
        RelationshipScoreComponents(
            recency:          recencyScore(inputs.lastInteractionAt, now: now),
            frequency:        frequencyScore(inputs.interactionCount30d),
            promiseBonus:     promiseBonusScore(overdueCount: inputs.overduePromiseCount),
            directionBalance: directionBalanceScore(inputs.directionCounts30d),
            sentimentTrend:   sentimentTrendScore(
                                  recent: inputs.recentSentiment,
                                  prior:  inputs.priorSentiment
                              )
        )
    }

    // MARK: - Factor calculations

    /// **Recency factor** — 0, 1, 2, or 3 points.
    ///
    /// Returns 0 when `lastInteractionAt` is `nil` (no interaction ever recorded).
    func recencyScore(_ lastInteractionAt: Date?, now: Date) -> Double {
        guard let last = lastInteractionAt else { return 0.0 }
        let ageDays = now.timeIntervalSince(last) / 86400.0
        switch ageDays {
        case ...RecencyThreshold.today:  return 3.0
        case ...RecencyThreshold.week:   return 2.0
        case ...RecencyThreshold.month:  return 1.0
        default:                          return 0.0
        }
    }

    /// **Frequency factor** — 0, 1, 1.5, or 2 points.
    func frequencyScore(_ count30d: Int) -> Double {
        switch count30d {
        case 0:
            return 0.0
        case 1 ..< FrequencyThreshold.medium:
            return 1.0
        case FrequencyThreshold.medium ... FrequencyThreshold.high:
            return 1.5
        default: // > FrequencyThreshold.high
            return 2.0
        }
    }

    /// **Promise bonus factor** — 0 to 2 points.
    ///
    /// Starts at 2.0. Each overdue user-made promise deducts 0.5, floored at 0.
    func promiseBonusScore(overdueCount: Int) -> Double {
        max(0.0, 2.0 - Double(overdueCount) * Self.promisePenaltyPerOverdue)
    }

    /// **Direction balance factor** — 0, 0.5–1.5 points.
    ///
    /// Mutual interactions (meetings) are counted as 0.5 outbound + 0.5 inbound.
    /// A perfect balance (or all-mutual) yields 1.5; completely one-sided yields 0.5.
    /// Returns 0 when there are no interactions in the 30-day window.
    func directionBalanceScore(_ counts: DirectionCounts) -> Double {
        guard counts.total > 0 else { return 0.0 }

        // If no directional interactions at all, all interactions are mutual → balanced.
        let directional = counts.outbound + counts.inbound
        if directional == 0 {
            return 1.5
        }

        // Distribute mutual interactions equally between effective outbound and inbound.
        let halfMutual  = Double(counts.mutual) * 0.5
        let effectiveOut = Double(counts.outbound) + halfMutual
        let effectiveIn  = Double(counts.inbound)  + halfMutual

        let balanceRatio = min(effectiveOut, effectiveIn) / max(effectiveOut, effectiveIn)
        // Linear mapping: ratio 0 → score 0.5, ratio 1 → score 1.5
        return 0.5 + balanceRatio * 1.0
    }

    /// **Sentiment trend factor** — 0.5, 1.0, or 1.5 points.
    ///
    /// - When prior data exists: compares the weighted average of recent (0–30 d) to
    ///   prior (31–90 d) sentiment. A delta > 0.15 is improving (1.5); < −0.15 is
    ///   declining (0.5); otherwise stable (1.0).
    /// - When only recent data exists: uses the absolute recent average.
    ///   - avg ≥ 0.65 → 1.5 (positive)
    ///   - avg ≥ 0.35 → 1.0 (neutral)
    ///   - avg < 0.35 → 0.5 (negative)
    /// - Returns 1.0 when there are no sentiment data at all (neutral default).
    func sentimentTrendScore(recent: SentimentCounts, prior: SentimentCounts) -> Double {
        let recentAvg = recent.weightedAverage ?? 0.5  // default neutral

        guard let priorAvg = prior.weightedAverage else {
            // No prior-window data: use absolute recent average
            if recent.total == 0 { return 1.0 }
            switch recentAvg {
            case 0.65...: return 1.5
            case 0.35...: return 1.0
            default:      return 0.5
            }
        }

        let delta = recentAvg - priorAvg
        switch delta {
        case Self.sentimentTrendThreshold...:    return 1.5  // improving
        case ..<(-Self.sentimentTrendThreshold): return 0.5  // declining
        default:                                  return 1.0  // stable
        }
    }
}
