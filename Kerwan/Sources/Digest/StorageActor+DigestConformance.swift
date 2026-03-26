import Foundation
import KerwanStorage

// MARK: - StorageActor: DigestStorageService

/// Declares that `StorageActor` (from `KerwanStorage`) conforms to the
/// `DigestStorageService` protocol defined in the `Kerwan` app target.
///
/// The SQL work is performed by the `*Raw` helpers in
/// `KerwanStorage/StorageActor+Digest.swift`, which return named primitive structs
/// (`ContactRawRow`, `PromiseRawRow`, etc.).  This file assembles those into
/// Kerwan-target model types (`Contact`, `Promise`, `WorkSession`, `Project`, `Digest`).
extension StorageActor: DigestStorageService {

    // MARK: - countInteractionsByType(from:to:)

    public func countInteractionsByType(from: Date, to: Date) async throws -> [InteractionType: Int] {
        let raw = try countInteractionsByTypeRaw(from: from, to: to)
        var result: [InteractionType: Int] = [:]
        for (typeString, count) in raw {
            switch typeString {
            case "meeting":
                result[.meeting, default: 0] += count
            case "email":
                result[.emailSent, default: 0] += count
            case "message":
                result[.slackDM, default: 0] += count
            case "call":
                result[.phoneCalled, default: 0] += count
            case "document", "codeReview", "other":
                result[.appActivity, default: 0] += count
            default:
                if let mapped = InteractionType(rawValue: typeString) {
                    result[mapped, default: 0] += count
                }
            }
        }
        return result
    }

    // MARK: - fetchOpenPromises(limit:)

    public func fetchOpenPromises(limit: Int) async throws -> [Promise] {
        let rows = try fetchOpenPromisesRaw(limit: limit)
        return rows.map(Self.promise(from:))
    }

    // MARK: - fetchContactsNotSeen(since:limit:)

    public func fetchContactsNotSeen(since notSeenSince: Date, limit: Int) async throws -> [Contact] {
        let rows = try fetchContactsNotSeenRaw(since: notSeenSince, limit: limit)
        return rows.map(Self.contact(from:))
    }

    // MARK: - countUnreviewedWorkSessions()

    public func countUnreviewedWorkSessions() async throws -> Int {
        return try countUnreviewedWorkSessionsRaw()
    }

    // MARK: - fetchWorkSessions(from:to:)

    public func fetchWorkSessions(from: Date, to: Date) async throws -> [WorkSession] {
        let rows = try fetchWorkSessionsRaw(from: from, to: to)
        return rows.map(Self.workSession(from:))
    }

    // MARK: - fetchProjectsForSessionIds(_:)

    public func fetchProjectsForSessionIds(_ ids: [EntityID]) async throws -> [EntityID: Project] {
        guard !ids.isEmpty else { return [:] }
        // Resolve session IDs → project IDs via a targeted session query.
        let sessions = try fetchWorkSessionsInIdsRaw(ids: ids)
        let projectIds = Array(Set(sessions.compactMap { $0.projectId }))
        guard !projectIds.isEmpty else { return [:] }

        let rows = try fetchProjectsRaw(forProjectIds: projectIds)
        var map: [EntityID: Project] = [:]
        for row in rows {
            let project = Self.project(from: row)
            map[project.id] = project
        }
        return map
    }

    // MARK: - fetchContactsWithDecliningActivity(referencePeriodDays:limit:)

    public func fetchContactsWithDecliningActivity(
        referencePeriodDays: Int,
        limit: Int
    ) async throws -> [Contact] {
        let rows = try fetchContactsWithDecliningActivityRaw(
            referencePeriodDays: referencePeriodDays,
            limit: limit
        )
        return rows.map(Self.contact(from:))
    }

    // MARK: - fetchOpenPromisesOlderThan(days:)

    public func fetchOpenPromisesOlderThan(days: Int) async throws -> [Promise] {
        let rows = try fetchOpenPromisesOlderThanRaw(days: days)
        return rows.map(Self.promise(from:))
    }

    // MARK: - saveDigest(_:)

    public func saveDigest(_ digest: Digest) async throws {
        let quietNamesJSON = (try? JSONEncoder().encode(digest.quietContactNames))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try saveDigestRaw(
            id:                     digest.id,
            kindRaw:                digest.kind.rawValue,
            generatedAtTs:          digest.generatedAt.timeIntervalSince1970,
            title:                  digest.title,
            bodyText:               digest.bodyText,
            meetingCount:           digest.meetingCount,
            emailCount:             digest.emailCount,
            slackCount:             digest.slackCount,
            openPromiseCount:       digest.openPromiseCount,
            unreviewedSessionCount: digest.unreviewedSessionCount,
            quietContactNamesJSON:  quietNamesJSON,
            totalHoursTracked:      digest.totalHoursTracked,
            estimatedBillableHours: digest.estimatedBillableHours,
            sessionsReviewedCount:  digest.sessionsReviewedCount,
            sessionsPendingCount:   digest.sessionsPendingCount,
            priorWeekBillableHours: digest.priorWeekBillableHours
        )
    }

    // MARK: - fetchLatestDigest(kind:)

    public func fetchLatestDigest(kind: DigestKind) async throws -> Digest? {
        guard let row = try fetchLatestDigestRaw(kindRaw: kind.rawValue) else { return nil }
        let quietNames = (try? JSONDecoder().decode(
            [String].self,
            from: Data(row.quietContactNamesJSON.utf8)
        )) ?? []
        return Digest(
            id:                       row.id,
            kind:                     DigestKind(rawValue: row.kindRaw) ?? kind,
            generatedAt:              Date(timeIntervalSince1970: row.generatedAtTs),
            title:                    row.title,
            bodyText:                 row.bodyText,
            meetingCount:             row.meetingCount,
            emailCount:               row.emailCount,
            slackCount:               row.slackCount,
            openPromiseCount:         row.openPromiseCount,
            unreviewedSessionCount:   row.unreviewedSessionCount,
            quietContactNames:        quietNames,
            totalHoursTracked:        row.totalHoursTracked,
            estimatedBillableHours:   row.estimatedBillableHours,
            sessionsReviewedCount:    row.sessionsReviewedCount,
            sessionsPendingCount:     row.sessionsPendingCount,
            priorWeekBillableHours:   row.priorWeekBillableHours
        )
    }

    // MARK: - Row-to-model assemblers (private, static)

    private static func contact(from row: ContactRawRow) -> Contact {
        let created  = row.createdAtTs  > 0 ? Date(timeIntervalSince1970: row.createdAtTs)  : .distantPast
        let updated  = row.updatedAtTs  > 0 ? Date(timeIntervalSince1970: row.updatedAtTs)  : .distantPast
        let lastSeen = row.lastSeenAtTs > 0 ? Date(timeIntervalSince1970: row.lastSeenAtTs) : .distantPast
        return Contact(
            id:                row.id,
            displayName:       row.displayName,
            company:           row.company,
            emailPrimary:      row.emailPrimary,
            relationshipScore: row.relationshipScore,
            firstSeenAt:       created,
            lastSeenAt:        lastSeen,
            createdAt:         created,
            updatedAt:         updated,
            needsReview:       false
        )
    }

    private static func promise(from row: PromiseRawRow) -> Promise {
        let created = row.createdAtTs > 0 ? Date(timeIntervalSince1970: row.createdAtTs) : .distantPast
        let dueDate = row.dueDateTs.map { Date(timeIntervalSince1970: $0) }
        return Promise(
            id:            row.id,
            interactionId: row.interactionId,
            contactId:     row.contactId,
            clientId:      row.clientId,
            direction:     .userPromised,
            description:   row.text,
            dueDate:       dueDate,
            status:        .open,
            extractedAt:   created
        )
    }

    private static func workSession(from row: WorkSessionRawRow) -> WorkSession {
        let started = row.startedAtTs > 0 ? Date(timeIntervalSince1970: row.startedAtTs) : .distantPast
        let ended   = row.endedAtTs   > 0 ? Date(timeIntervalSince1970: row.endedAtTs)   : .distantPast

        // Map KerwanStorage billable column values to Kerwan-target BillableStatus.
        let billable: BillableStatus
        switch row.billableRaw {
        case "billable":
            billable = row.reviewed ? .confirmed : .suggested
        case "nonBillable":
            billable = .nonBillable
        case "undecided":
            billable = row.reviewed ? .confirmed : .suggested
        default:
            // New-schema values ('suggested','confirmed','rejected','nonBillable')
            // pass through directly.
            billable = BillableStatus(rawValue: row.billableRaw) ?? .suggested
        }

        return WorkSession(
            id:             row.id,
            clientId:       row.clientId,
            projectId:      row.projectId,
            startedAt:      started,
            endedAt:        ended,
            durationSecs:   Int(row.durationSeconds),
            billableStatus: billable,
            reviewedAt:     row.reviewed ? ended : nil
        )
    }

    private static func project(from row: ProjectRawRow) -> Project {
        let created = row.createdAtTs > 0 ? Date(timeIntervalSince1970: row.createdAtTs) : .distantPast
        return Project(
            id:         row.id,
            clientId:   row.clientId,
            name:       row.name,
            hourlyRate: row.hourlyRate,
            isActive:   row.isActive,
            createdAt:  created
        )
    }
}
