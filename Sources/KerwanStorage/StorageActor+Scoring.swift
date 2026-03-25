import Foundation
import SQLite3
import os.log

// MARK: - StorageActor + Scoring queries

/// Database operations used exclusively by `RelationshipScoreEngine`.
///
/// Separated into an extension to keep the core `StorageActor.swift` focused on
/// generic CRUD. The scoring-specific methods are `public` so that `KerwanScoring`
/// (a separate module) can call them via the shared `StorageActor` instance.
extension StorageActor {

    // MARK: - Active contact discovery

    /// Returns the IDs of all contacts that have at least one interaction since `since`.
    ///
    /// The nightly scoring job calls this to build the work list.  Using
    /// `interactions.started_at` rather than `contacts.last_seen_at` avoids stale
    /// data during the first run after the `last_seen_at` column was added.
    ///
    /// - Parameter since: Lower bound for `interactions.started_at` (typically now − 90 d).
    /// - Returns: Distinct, non-nil contact IDs. Empty when no active contacts exist.
    public func fetchActiveContactIds(since: Date) -> [String] {
        let cutoff = since.timeIntervalSince1970
        return (try? withReadConnection { conn in
            var ids: [String] = []
            try conn.query(
                """
                SELECT DISTINCT contact_id
                FROM interactions
                WHERE contact_id IS NOT NULL
                  AND started_at >= ?
                ORDER BY contact_id
                """,
                bindings: [.real(cutoff)]
            ) { stmt in
                if let id = conn.columnText(stmt, at: 0) {
                    ids.append(id)
                }
            }
            return ids
        }) ?? []
    }

    // MARK: - Score input fetch

    /// Fetches all data required to compute a relationship score for one contact.
    ///
    /// Executes six indexed queries:
    /// 1. Most-recent interaction timestamp (recency factor).
    /// 2. Interaction count in the last 30 days (frequency factor).
    /// 3. Direction histogram in the last 30 days (balance factor).
    /// 4. Count of open, overdue user-made promises (promise-bonus factor).
    /// 5. Sentiment histogram for the recent window 0–30 days (trend factor).
    /// 6. Sentiment histogram for the prior window 31–90 days (trend factor).
    ///
    /// - Parameters:
    ///   - contactId: The contact whose data to fetch.
    ///   - now: Reference point for all time windows. Pass `Date()` in production;
    ///     override in tests for determinism.
    public func fetchScoreInputs(contactId: String, now: Date) -> ContactScoreInputs {
        let nowTs  = now.timeIntervalSince1970
        let ago30d = nowTs - 30 * 86400
        let ago90d = nowTs - 90 * 86400

        // 1. Most recent interaction (all time)
        let lastAt: Date? = (try? withReadConnection { conn -> Date? in
            let ts: Double? = try conn.scalar(
                "SELECT MAX(started_at) FROM interactions WHERE contact_id = ?",
                bindings: [.text(contactId)]
            )
            guard let ts else { return nil }
            return Date(timeIntervalSince1970: ts)
        }) ?? nil

        // 2. Interaction count — last 30 days
        let count30d: Int = {
            let v: Int64? = try? withReadConnection { conn in
                try conn.scalar(
                    """
                    SELECT COUNT(*) FROM interactions
                    WHERE contact_id = ? AND started_at >= ?
                    """,
                    bindings: [.text(contactId), .real(ago30d)]
                )
            }
            return Int(v ?? 0)
        }()

        // 3. Direction histogram — last 30 days.
        // All vars are mutated inside the non-@Sendable handler closure passed to
        // conn.query(), which is non-escaping and therefore safe.
        let dirCounts: DirectionCounts = (try? withReadConnection { conn -> DirectionCounts in
            var out = 0, inb = 0, mut = 0
            try conn.query(
                """
                SELECT direction, COUNT(*) FROM interactions
                WHERE contact_id = ? AND started_at >= ?
                GROUP BY direction
                """,
                bindings: [.text(contactId), .real(ago30d)]
            ) { stmt in
                let dir = conn.columnText(stmt, at: 0) ?? "mutual"
                let cnt = Int(conn.columnInt64(stmt, at: 1))
                switch dir {
                case Interaction.Direction.outbound.rawValue: out += cnt
                case Interaction.Direction.inbound.rawValue:  inb += cnt
                default:                                       mut += cnt
                }
            }
            return DirectionCounts(outbound: out, inbound: inb, mutual: mut)
        }) ?? DirectionCounts()

        // 4. Overdue open promises made by the user
        let overdueCount: Int = {
            let v: Int64? = try? withReadConnection { conn in
                try conn.scalar(
                    """
                    SELECT COUNT(*) FROM promises
                    WHERE contact_id = ?
                      AND status = 'open'
                      AND due_date IS NOT NULL
                      AND due_date < ?
                    """,
                    bindings: [.text(contactId), .real(nowTs)]
                )
            }
            return Int(v ?? 0)
        }()

        // Helper: builds a SentimentCounts from a given time window.
        // Defined as a local closure to avoid capturing mutable vars across @Sendable.
        func sentimentCounts(from fromTs: Double, to toTs: Double) -> SentimentCounts {
            (try? withReadConnection { conn -> SentimentCounts in
                var pos = 0, neu = 0, neg = 0, unk = 0
                try conn.query(
                    """
                    SELECT sentiment, COUNT(*) FROM interactions
                    WHERE contact_id = ?
                      AND started_at >= ?
                      AND started_at < ?
                    GROUP BY sentiment
                    """,
                    bindings: [.text(contactId), .real(fromTs), .real(toTs)]
                ) { stmt in
                    let sent = conn.columnText(stmt, at: 0) ?? "unknown"
                    let cnt  = Int(conn.columnInt64(stmt, at: 1))
                    switch sent {
                    case Interaction.Sentiment.positive.rawValue: pos += cnt
                    case Interaction.Sentiment.neutral.rawValue:  neu += cnt
                    case Interaction.Sentiment.negative.rawValue: neg += cnt
                    default:                                       unk += cnt
                    }
                }
                return SentimentCounts(positive: pos, neutral: neu, negative: neg, unknown: unk)
            }) ?? SentimentCounts()
        }

        // 5 & 6. Sentiment histograms (recent = 0–30 d, prior = 31–90 d)
        let recentSentiment = sentimentCounts(from: ago30d, to: nowTs)
        let priorSentiment  = sentimentCounts(from: ago90d, to: ago30d)

        return ContactScoreInputs(
            lastInteractionAt:   lastAt,
            interactionCount30d: count30d,
            directionCounts30d:  dirCounts,
            overduePromiseCount: overdueCount,
            recentSentiment:     recentSentiment,
            priorSentiment:      priorSentiment
        )
    }

    // MARK: - Score write-back

    /// Persists a computed relationship score for a single contact.
    ///
    /// Also advances `last_seen_at` when `lastSeenAt` is more recent than the
    /// stored value (monotonic update, same semantics as `upsertContact`).
    ///
    /// - Parameters:
    ///   - contactId:  The contact to update.
    ///   - score:      Clamped 0–10 relationship score.
    ///   - lastSeenAt: Most-recent interaction date returned by `fetchScoreInputs`.
    ///   - scoredAt:   Timestamp to stamp on `updated_at` (defaults to `Date()`).
    public func updateRelationshipScore(
        contactId: String,
        score: Double,
        lastSeenAt: Date,
        scoredAt: Date = Date()
    ) throws {
        let clampedScore  = max(0.0, min(10.0, score))
        let lastSeenTs    = lastSeenAt.timeIntervalSince1970
        let scoredAtTs    = scoredAt.timeIntervalSince1970
        try withWriteConnection { conn in
            try conn.execute(
                """
                UPDATE contacts
                SET relationship_score = \(clampedScore),
                    last_seen_at       = MAX(last_seen_at, \(lastSeenTs)),
                    updated_at         = \(scoredAtTs)
                WHERE id = '\(contactId)'
                """
            )
        }
    }

    /// Applies a batch of score updates inside a single write transaction.
    ///
    /// More efficient than calling `updateRelationshipScore` in a loop when
    /// updating hundreds of contacts during the nightly pass.
    ///
    /// - Parameter updates: Array of `(contactId, score, lastSeenAt)` tuples.
    public func batchUpdateRelationshipScores(
        _ updates: [(contactId: String, score: Double, lastSeenAt: Date)],
        scoredAt: Date = Date()
    ) throws {
        guard !updates.isEmpty else { return }
        let scoredAtTs = scoredAt.timeIntervalSince1970
        try withWriteConnection { conn in
            try conn.transaction {
                for update in updates {
                    let clampedScore = max(0.0, min(10.0, update.score))
                    let lastSeenTs   = update.lastSeenAt.timeIntervalSince1970
                    try conn.execute(
                        """
                        UPDATE contacts
                        SET relationship_score = \(clampedScore),
                            last_seen_at       = MAX(last_seen_at, \(lastSeenTs)),
                            updated_at         = \(scoredAtTs)
                        WHERE id = '\(update.contactId)'
                        """
                    )
                }
            }
        }
    }
}
