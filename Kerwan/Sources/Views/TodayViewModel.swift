import SwiftUI
import os

// MARK: - TodayStorageService

/// Storage operations required by `TodayViewModel`.
/// Implemented by `StorageActor` in the KerwanStorage workstream.
protocol TodayStorageService: Actor {
    /// Most recently generated daily digest, or nil if none exists yet.
    func fetchLatestDailyDigest() async throws -> Digest?

    /// Interactions of type `.meeting` whose `startedAt` is today.
    /// Sorted by `startedAt` ascending.
    func fetchMeetingsToday() async throws -> [Interaction]

    /// Contacts for the given IDs (used to enrich meeting rows).
    func fetchContacts(ids: [EntityID]) async throws -> [Contact]

    /// Open promises with `dueDate` within the next `withinDays` days,
    /// sorted by due date ascending (nil-due last).
    func fetchOpenPromisesDueSoon(withinDays: Int) async throws -> [Promise]

    /// The `limit` most recent work sessions with `.suggested` billable status,
    /// sorted by `startedAt` descending.
    func fetchUnreviewedSessions(limit: Int) async throws -> [WorkSession]

    /// Clients keyed by session client-ID for the quick-review rows.
    func fetchClientsForSessionIds(_ ids: [EntityID]) async throws -> [EntityID: Client]

    /// Work sessions from yesterday, keyed to their client, for the activity chart.
    /// Returns [(client, totalHours)] sorted by hours descending.
    func fetchYesterdayHoursByClient() async throws -> [(client: Client, hours: Double)]

    // MARK: Mutations

    func updatePromiseStatus(_ id: EntityID, status: PromiseStatus) async throws
    func updateWorkSession(_ session: WorkSession) async throws
}

// MARK: - TodayViewModel

@Observable
@MainActor
final class TodayViewModel {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "TodayViewModel"
    )

    // MARK: Data

    private(set) var latestDigest: Digest? = nil

    /// Meetings scheduled or ongoing today.
    var todaysMeetings: [Interaction] = []
    private(set) var meetingContacts: [EntityID: Contact] = [:]

    /// Promises due within the next 3 days.
    var dueSoonPromises: [Promise] = []
    private(set) var promiseContacts: [EntityID: Contact] = [:]

    /// Up to 3 unreviewed billing sessions for quick approval.
    private(set) var quickReviewSessions: [WorkSession] = []
    private(set) var sessionClients: [EntityID: Client] = [:]

    /// Yesterday's hours broken out by client, for the chart.
    var yesterdayHoursByClient: [(client: Client, hours: Double)] = []

    // MARK: UI state

    var isLoading: Bool = false
    var error: String? = nil

    // MARK: Dependencies

    private var storage: (any TodayStorageService)?
    private weak var appState: AppState?

    // MARK: - Init

    init(storage: (any TodayStorageService)? = nil, appState: AppState? = nil) {
        self.storage = storage
        self.appState = appState
    }

    // MARK: - Load

    func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let storage else { return }

        do {
            async let digestTask    = storage.fetchLatestDailyDigest()
            async let meetingsTask  = storage.fetchMeetingsToday()
            async let promisesTask  = storage.fetchOpenPromisesDueSoon(withinDays: 3)
            async let sessionsTask  = storage.fetchUnreviewedSessions(limit: 3)
            async let chartTask     = storage.fetchYesterdayHoursByClient()

            let (digest, meetings, promises, sessions, chart) = try await (
                digestTask, meetingsTask, promisesTask, sessionsTask, chartTask
            )

            latestDigest = digest
            todaysMeetings = meetings
            dueSoonPromises = promises
            quickReviewSessions = sessions
            yesterdayHoursByClient = chart

            // Enrich with contact lookups.
            let meetingContactIds = Array(Set(meetings.compactMap(\.contactId)))
            let promiseContactIds = Array(Set(promises.compactMap(\.contactId)))
            let allContactIds = Array(Set(meetingContactIds + promiseContactIds))

            if !allContactIds.isEmpty {
                let contacts = try await storage.fetchContacts(ids: allContactIds)
                let contactMap = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })
                meetingContacts = contactMap.filter { meetingContactIds.contains($0.key) }
                promiseContacts = contactMap.filter { promiseContactIds.contains($0.key) }
            }

            let sessionClientIds = Array(Set(sessions.compactMap(\.clientId)))
            if !sessionClientIds.isEmpty {
                sessionClients = try await storage.fetchClientsForSessionIds(sessionClientIds)
            }

        } catch {
            Self.logger.error("TodayViewModel load failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    /// Reloads only the digest — called when `kerwanNewDigestReady` is posted.
    func refreshDigest() async {
        guard let storage else { return }
        do {
            latestDigest = try await storage.fetchLatestDailyDigest()
        } catch {
            Self.logger.error("Digest refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Promise actions

    func markPromiseDone(_ promise: Promise) async {
        await updatePromise(promise, status: .done)
        appState?.updateOpenPromiseCount(max(0, (appState?.openPromiseCount ?? 1) - 1))
    }

    func snoozePromise(_ promise: Promise) async {
        await updatePromise(promise, status: .snoozed)
    }

    func dismissPromise(_ promise: Promise) async {
        await updatePromise(promise, status: .dismissed)
    }

    private func updatePromise(_ promise: Promise, status: PromiseStatus) async {
        dueSoonPromises.removeAll { $0.id == promise.id }
        guard let storage else { return }
        do {
            try await storage.updatePromiseStatus(promise.id, status: status)
        } catch {
            Self.logger.error("Promise update failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
            // Re-insert on failure.
            dueSoonPromises.insert(promise, at: 0)
        }
    }

    // MARK: - Session quick-review actions

    func confirmSession(_ session: WorkSession) async {
        await updateSessionStatus(session, to: .confirmed)
        appState?.updatePendingReviewCount(max(0, (appState?.pendingReviewCount ?? 1) - 1))
    }

    func rejectSession(_ session: WorkSession) async {
        await updateSessionStatus(session, to: .rejected)
        appState?.updatePendingReviewCount(max(0, (appState?.pendingReviewCount ?? 1) - 1))
    }

    private func updateSessionStatus(_ session: WorkSession, to status: BillableStatus) async {
        quickReviewSessions.removeAll { $0.id == session.id }
        guard let storage else { return }

        let updated = WorkSession(
            id: session.id,
            clientId: session.clientId,
            projectId: session.projectId,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            durationSecs: session.durationSecs,
            billableStatus: status,
            confidence: session.confidence,
            description: session.description,
            invoiceText: session.invoiceText,
            reviewedAt: Date()
        )
        do {
            try await storage.updateWorkSession(updated)
        } catch {
            Self.logger.error("Session update failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
            quickReviewSessions.insert(session, at: 0)
        }
    }

    // MARK: - Computed helpers

    /// Meetings that start from now onward (or started in the last 30 minutes).
    var upcomingMeetings: [Interaction] {
        let cutoff = Date().addingTimeInterval(-1800)
        return todaysMeetings.filter { $0.startedAt >= cutoff }
    }

    var overdueSoonPromises: [Promise] {
        dueSoonPromises.filter { $0.isOverdue }
    }

    var totalYesterdayHours: Double {
        yesterdayHoursByClient.map(\.1).reduce(0, +)
    }
}
