import Foundation
import SQLite3

// MARK: - StorageActor+Digest
//
// Public primitive-typed helpers that underpin the `DigestStorageService`
// protocol conformance declared in the Kerwan app target.
//
// Because `DigestStorageService` uses Kerwan-target model types (`Contact`,
// `Promise`, `WorkSession`, `Project`, `Digest`, `InteractionType`, …) that
// are not visible from this module, every method here returns or accepts
// primitive Swift types only (strings, doubles, arrays of tuples).  The
// protocol conformance and model-type assembly live in
// `Kerwan/Sources/Digest/StorageActor+DigestConformance.swift`.
//
// Read access goes through `withReadConnection(_:)`.
// Write access goes through `withWriteConnection(_:)`.
// Both are `internal` accessors defined at the bottom of StorageActor.swift.

extension StorageActor {

    // MARK: - Interaction counts

    /// Returns a `[String: Int]` map from interaction-type raw values to counts
    /// for interactions whose `started_at` is in `[from, to)`.
    public func countInteractionsByTypeRaw(from: Date, to: Date) throws -> [String: Int] {
        let fromTs = from.timeIntervalSince1970
        let toTs   = to.timeIntervalSince1970
        return try withReadConnection { conn in
            var counts: [String: Int] = [:]
            try conn.query(
                """
                SELECT type, count(*) FROM interactions
                WHERE started_at >= ? AND started_at < ?
                GROUP BY type
                """,
                bindings: [SQLiteValue.real(fromTs), SQLiteValue.real(toTs)]
            ) { stmt in
                if let rawType = conn.columnText(stmt, at: 0) {
                    counts[rawType] = Int(conn.columnInt64(stmt, at: 1))
                }
            }
            return counts
        }
    }

    // MARK: - Open promises

    /// Returns open promises as raw row tuples ordered by due date ASC (NULL last),
    /// capped at `limit`.
    public func fetchOpenPromisesRaw(limit: Int) throws -> [PromiseRawRow] {
        return try withReadConnection { conn in
            var rows: [PromiseRawRow] = []
            try conn.query(
                """
                SELECT id, contact_id, client_id, interaction_id,
                       text, due_date, created_at
                FROM promises
                WHERE status = 'open'
                ORDER BY due_date ASC NULLS LAST, created_at DESC
                LIMIT ?
                """,
                bindings: [SQLiteValue.integer(Int64(limit))]
            ) { stmt in
                let dueDateTs: Double? = sqlite3_column_type(stmt, 5) == SQLITE_NULL
                    ? nil
                    : conn.columnDouble(stmt, at: 5)
                rows.append(PromiseRawRow(
                    id:            conn.columnText(stmt, at: 0) ?? "",
                    contactId:     conn.columnText(stmt, at: 1),
                    clientId:      conn.columnText(stmt, at: 2),
                    interactionId: conn.columnText(stmt, at: 3),
                    text:          conn.columnText(stmt, at: 4) ?? "",
                    dueDateTs:     dueDateTs,
                    createdAtTs:   conn.columnDouble(stmt, at: 6)
                ))
            }
            return rows
        }
    }

    // MARK: - Contacts not seen since

    /// Returns contacts whose `last_seen_at` is strictly before `notSeenSince`,
    /// ordered oldest-seen first, capped at `limit`.
    public func fetchContactsNotSeenRaw(
        since notSeenSince: Date,
        limit: Int
    ) throws -> [ContactRawRow] {
        let cutoffTs = notSeenSince.timeIntervalSince1970
        return try withReadConnection { conn in
            var rows: [ContactRawRow] = []
            try conn.query(
                """
                SELECT id, display_name, email_primary, company,
                       created_at, updated_at, relationship_score, last_seen_at
                FROM contacts
                WHERE last_seen_at < ?
                ORDER BY last_seen_at ASC
                LIMIT ?
                """,
                bindings: [SQLiteValue.real(cutoffTs), SQLiteValue.integer(Int64(limit))]
            ) { stmt in
                rows.append(ContactRawRow(
                    id:                conn.columnText(stmt, at: 0) ?? "",
                    displayName:       conn.columnText(stmt, at: 1) ?? "",
                    emailPrimary:      conn.columnText(stmt, at: 2),
                    company:           conn.columnText(stmt, at: 3),
                    createdAtTs:       conn.columnDouble(stmt, at: 4),
                    updatedAtTs:       conn.columnDouble(stmt, at: 5),
                    relationshipScore: conn.columnDouble(stmt, at: 6),
                    lastSeenAtTs:      conn.columnDouble(stmt, at: 7)
                ))
            }
            return rows
        }
    }

    // MARK: - Unreviewed work session count

    /// Returns the count of work sessions where `reviewed = 0`.
    public func countUnreviewedWorkSessionsRaw() throws -> Int {
        let v: Int64? = try? withReadConnection { conn in
            try conn.scalar("SELECT count(*) FROM work_sessions WHERE reviewed = 0")
        }
        return Int(v ?? 0)
    }

    // MARK: - Work sessions in date range

    /// Returns work sessions whose `started_at` falls in `[from, to)`.
    public func fetchWorkSessionsRaw(from: Date, to: Date) throws -> [WorkSessionRawRow] {
        let fromTs = from.timeIntervalSince1970
        let toTs   = to.timeIntervalSince1970
        return try withReadConnection { conn in
            var rows: [WorkSessionRawRow] = []
            try conn.query(
                """
                SELECT id, client_id, project_id, started_at, ended_at,
                       duration_seconds, billable, reviewed
                FROM work_sessions
                WHERE started_at >= ? AND started_at < ?
                ORDER BY started_at DESC
                """,
                bindings: [SQLiteValue.real(fromTs), SQLiteValue.real(toTs)]
            ) { stmt in
                rows.append(WorkSessionRawRow(
                    id:              conn.columnText(stmt, at: 0) ?? "",
                    clientId:        conn.columnText(stmt, at: 1),
                    projectId:       conn.columnText(stmt, at: 2),
                    startedAtTs:     conn.columnDouble(stmt, at: 3),
                    endedAtTs:       conn.columnDouble(stmt, at: 4),
                    durationSeconds: conn.columnDouble(stmt, at: 5),
                    billableRaw:     conn.columnText(stmt, at: 6) ?? "undecided",
                    reviewed:        conn.columnBool(stmt, at: 7)
                ))
            }
            return rows
        }
    }

    // MARK: - Work sessions by IDs

    /// Returns work sessions whose `id` is in the given array.
    /// Used to resolve session IDs to project IDs for `fetchProjectsForSessionIds`.
    public func fetchWorkSessionsInIdsRaw(ids: [String]) throws -> [WorkSessionRawRow] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        return try withReadConnection { conn in
            var rows: [WorkSessionRawRow] = []
            try conn.query(
                """
                SELECT id, client_id, project_id, started_at, ended_at,
                       duration_seconds, billable, reviewed
                FROM work_sessions
                WHERE id IN (\(placeholders))
                """,
                bindings: ids.map { SQLiteValue.text($0) }
            ) { stmt in
                rows.append(WorkSessionRawRow(
                    id:              conn.columnText(stmt, at: 0) ?? "",
                    clientId:        conn.columnText(stmt, at: 1),
                    projectId:       conn.columnText(stmt, at: 2),
                    startedAtTs:     conn.columnDouble(stmt, at: 3),
                    endedAtTs:       conn.columnDouble(stmt, at: 4),
                    durationSeconds: conn.columnDouble(stmt, at: 5),
                    billableRaw:     conn.columnText(stmt, at: 6) ?? "undecided",
                    reviewed:        conn.columnBool(stmt, at: 7)
                ))
            }
            return rows
        }
    }

    // MARK: - Projects by IDs

    /// Returns projects for the given project ID strings.
    public func fetchProjectsRaw(forProjectIds projectIds: [String]) throws -> [ProjectRawRow] {
        guard !projectIds.isEmpty else { return [] }
        let placeholders = projectIds.map { _ in "?" }.joined(separator: ", ")
        return try withReadConnection { conn in
            var rows: [ProjectRawRow] = []
            try conn.query(
                "SELECT id, client_id, name, budget, status, created_at FROM projects WHERE id IN (\(placeholders))",
                bindings: projectIds.map { SQLiteValue.text($0) }
            ) { stmt in
                let budget: Double? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
                    ? nil
                    : conn.columnDouble(stmt, at: 3)
                let statusRaw = conn.columnText(stmt, at: 4) ?? "active"
                rows.append(ProjectRawRow(
                    id:          conn.columnText(stmt, at: 0) ?? "",
                    clientId:    conn.columnText(stmt, at: 1) ?? "",
                    name:        conn.columnText(stmt, at: 2) ?? "",
                    hourlyRate:  budget,
                    isActive:    statusRaw == "active",
                    createdAtTs: conn.columnDouble(stmt, at: 5)
                ))
            }
            return rows
        }
    }

    // MARK: - Contacts with declining activity

    /// Returns contacts whose interaction count declined vs the prior period.
    public func fetchContactsWithDecliningActivityRaw(
        referencePeriodDays: Int,
        limit: Int
    ) throws -> [ContactRawRow] {
        let now         = Date().timeIntervalSince1970
        let periodSecs  = Double(referencePeriodDays) * 86_400
        let recentStart = now - periodSecs
        let priorStart  = now - 2 * periodSecs

        return try withReadConnection { conn in
            var rows: [ContactRawRow] = []
            try conn.query(
                """
                SELECT c.id, c.display_name, c.email_primary, c.company,
                       c.created_at, c.updated_at, c.relationship_score, c.last_seen_at
                FROM contacts c
                LEFT JOIN (
                    SELECT contact_id, count(*) AS cnt
                    FROM interactions
                    WHERE started_at >= ? AND started_at < ?
                    GROUP BY contact_id
                ) AS recent ON recent.contact_id = c.id
                LEFT JOIN (
                    SELECT contact_id, count(*) AS cnt
                    FROM interactions
                    WHERE started_at >= ? AND started_at < ?
                    GROUP BY contact_id
                ) AS prior ON prior.contact_id = c.id
                WHERE COALESCE(recent.cnt, 0) < COALESCE(prior.cnt, 0)
                ORDER BY (COALESCE(prior.cnt, 0) - COALESCE(recent.cnt, 0)) DESC
                LIMIT ?
                """,
                bindings: [
                    SQLiteValue.real(recentStart), SQLiteValue.real(now),
                    SQLiteValue.real(priorStart),  SQLiteValue.real(recentStart),
                    SQLiteValue.integer(Int64(limit)),
                ]
            ) { stmt in
                rows.append(ContactRawRow(
                    id:                conn.columnText(stmt, at: 0) ?? "",
                    displayName:       conn.columnText(stmt, at: 1) ?? "",
                    emailPrimary:      conn.columnText(stmt, at: 2),
                    company:           conn.columnText(stmt, at: 3),
                    createdAtTs:       conn.columnDouble(stmt, at: 4),
                    updatedAtTs:       conn.columnDouble(stmt, at: 5),
                    relationshipScore: conn.columnDouble(stmt, at: 6),
                    lastSeenAtTs:      conn.columnDouble(stmt, at: 7)
                ))
            }
            return rows
        }
    }

    // MARK: - Open promises older than N days

    /// Returns open promises whose `created_at` is at least `days` days ago.
    public func fetchOpenPromisesOlderThanRaw(days: Int) throws -> [PromiseRawRow] {
        let cutoffTs = Date().timeIntervalSince1970 - Double(days) * 86_400
        return try withReadConnection { conn in
            var rows: [PromiseRawRow] = []
            try conn.query(
                """
                SELECT id, contact_id, client_id, interaction_id,
                       text, due_date, created_at
                FROM promises
                WHERE status = 'open' AND created_at <= ?
                ORDER BY due_date ASC NULLS LAST, created_at ASC
                """,
                bindings: [SQLiteValue.real(cutoffTs)]
            ) { stmt in
                let dueDateTs: Double? = sqlite3_column_type(stmt, 5) == SQLITE_NULL
                    ? nil
                    : conn.columnDouble(stmt, at: 5)
                rows.append(PromiseRawRow(
                    id:            conn.columnText(stmt, at: 0) ?? "",
                    contactId:     conn.columnText(stmt, at: 1),
                    clientId:      conn.columnText(stmt, at: 2),
                    interactionId: conn.columnText(stmt, at: 3),
                    text:          conn.columnText(stmt, at: 4) ?? "",
                    dueDateTs:     dueDateTs,
                    createdAtTs:   conn.columnDouble(stmt, at: 6)
                ))
            }
            return rows
        }
    }

    // MARK: - Save digest

    /// Persists a digest record. All fields are passed as primitives.
    public func saveDigestRaw(
        id: String,
        kindRaw: String,
        generatedAtTs: Double,
        title: String,
        bodyText: String,
        meetingCount: Int,
        emailCount: Int,
        slackCount: Int,
        openPromiseCount: Int,
        unreviewedSessionCount: Int,
        quietContactNamesJSON: String,
        totalHoursTracked: Double?,
        estimatedBillableHours: Double?,
        sessionsReviewedCount: Int?,
        sessionsPendingCount: Int?,
        priorWeekBillableHours: Double?
    ) throws {
        try withWriteConnection { conn in
            let sql = """
                INSERT OR REPLACE INTO digests
                    (id, kind, generated_at, title, body_text,
                     meeting_count, email_count, slack_count,
                     open_promise_count, unreviewed_session_count, quiet_contact_names,
                     total_hours_tracked, estimated_billable_hours,
                     sessions_reviewed_count, sessions_pending_count,
                     prior_week_billable_hours)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """
            let stmt = try conn.prepare(sql)
            defer { sqlite3_finalize(stmt) }
            let bindings: [SQLiteValue] = [
                .text(id),
                .text(kindRaw),
                .real(generatedAtTs),
                .text(title),
                .text(bodyText),
                .integer(Int64(meetingCount)),
                .integer(Int64(emailCount)),
                .integer(Int64(slackCount)),
                .integer(Int64(openPromiseCount)),
                .integer(Int64(unreviewedSessionCount)),
                .text(quietContactNamesJSON),
                totalHoursTracked.map      { SQLiteValue.real($0) }          ?? .null,
                estimatedBillableHours.map { SQLiteValue.real($0) }          ?? .null,
                sessionsReviewedCount.map  { SQLiteValue.integer(Int64($0)) } ?? .null,
                sessionsPendingCount.map   { SQLiteValue.integer(Int64($0)) } ?? .null,
                priorWeekBillableHours.map { SQLiteValue.real($0) }          ?? .null,
            ]
            try conn.bind(bindings, to: stmt)
            try conn.step(stmt)
        }
    }

    // MARK: - Fetch latest digest

    /// Returns the most-recent digest row of `kindRaw`, or `nil` if none exists.
    public func fetchLatestDigestRaw(kindRaw: String) throws -> DigestRawRow? {
        return try withReadConnection { conn in
            var row: DigestRawRow?
            try conn.query(
                """
                SELECT id, kind, generated_at, title, body_text,
                       meeting_count, email_count, slack_count,
                       open_promise_count, unreviewed_session_count, quiet_contact_names,
                       total_hours_tracked, estimated_billable_hours,
                       sessions_reviewed_count, sessions_pending_count,
                       prior_week_billable_hours
                FROM digests
                WHERE kind = ?
                ORDER BY generated_at DESC
                LIMIT 1
                """,
                bindings: [SQLiteValue.text(kindRaw)]
            ) { stmt in
                let totalHours: Double? = sqlite3_column_type(stmt, 11) == SQLITE_NULL
                    ? nil : conn.columnDouble(stmt, at: 11)
                let estBillable: Double? = sqlite3_column_type(stmt, 12) == SQLITE_NULL
                    ? nil : conn.columnDouble(stmt, at: 12)
                let sessReviewed: Int? = sqlite3_column_type(stmt, 13) == SQLITE_NULL
                    ? nil : Int(conn.columnInt64(stmt, at: 13))
                let sessPending: Int? = sqlite3_column_type(stmt, 14) == SQLITE_NULL
                    ? nil : Int(conn.columnInt64(stmt, at: 14))
                let priorBill: Double? = sqlite3_column_type(stmt, 15) == SQLITE_NULL
                    ? nil : conn.columnDouble(stmt, at: 15)
                row = DigestRawRow(
                    id:                     conn.columnText(stmt, at: 0) ?? "",
                    kindRaw:                conn.columnText(stmt, at: 1) ?? kindRaw,
                    generatedAtTs:          conn.columnDouble(stmt, at: 2),
                    title:                  conn.columnText(stmt, at: 3) ?? "",
                    bodyText:               conn.columnText(stmt, at: 4) ?? "",
                    meetingCount:           Int(conn.columnInt64(stmt, at: 5)),
                    emailCount:             Int(conn.columnInt64(stmt, at: 6)),
                    slackCount:             Int(conn.columnInt64(stmt, at: 7)),
                    openPromiseCount:       Int(conn.columnInt64(stmt, at: 8)),
                    unreviewedSessionCount: Int(conn.columnInt64(stmt, at: 9)),
                    quietContactNamesJSON:  conn.columnText(stmt, at: 10) ?? "[]",
                    totalHoursTracked:      totalHours,
                    estimatedBillableHours: estBillable,
                    sessionsReviewedCount:  sessReviewed,
                    sessionsPendingCount:   sessPending,
                    priorWeekBillableHours: priorBill
                )
            }
            return row
        }
    }
}

// MARK: - Raw row value types
//
// Named structs replace anonymous tuples so the compiler can infer types in
// complex expressions without hitting the "unable to type-check in reasonable
// time" limit and to keep function signatures readable.

/// A contact record as read from the `contacts` table.
public struct ContactRawRow: Sendable {
    public let id: String
    public let displayName: String
    public let emailPrimary: String?
    public let company: String?
    public let createdAtTs: Double
    public let updatedAtTs: Double
    public let relationshipScore: Double
    public let lastSeenAtTs: Double
}

/// A promise record as read from the `promises` table.
public struct PromiseRawRow: Sendable {
    public let id: String
    public let contactId: String?
    public let clientId: String?
    public let interactionId: String?
    public let text: String
    public let dueDateTs: Double?
    public let createdAtTs: Double
}

/// A work-session record as read from the `work_sessions` table.
public struct WorkSessionRawRow: Sendable {
    public let id: String
    public let clientId: String?
    public let projectId: String?
    public let startedAtTs: Double
    public let endedAtTs: Double
    public let durationSeconds: Double
    public let billableRaw: String
    public let reviewed: Bool
}

/// A project record as read from the `projects` table.
public struct ProjectRawRow: Sendable {
    public let id: String
    public let clientId: String
    public let name: String
    public let hourlyRate: Double?
    public let isActive: Bool
    public let createdAtTs: Double
}

/// A digest record as read from the `digests` table.
public struct DigestRawRow: Sendable {
    public let id: String
    public let kindRaw: String
    public let generatedAtTs: Double
    public let title: String
    public let bodyText: String
    public let meetingCount: Int
    public let emailCount: Int
    public let slackCount: Int
    public let openPromiseCount: Int
    public let unreviewedSessionCount: Int
    public let quietContactNamesJSON: String
    public let totalHoursTracked: Double?
    public let estimatedBillableHours: Double?
    public let sessionsReviewedCount: Int?
    public let sessionsPendingCount: Int?
    public let priorWeekBillableHours: Double?
}
