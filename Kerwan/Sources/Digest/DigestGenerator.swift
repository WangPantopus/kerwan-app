import Foundation
import os

// MARK: - DigestStorageService

/// All storage operations required by `DigestGenerator`.
/// Implemented by `StorageActor` in the KerwanStorage workstream.
protocol DigestStorageService: Actor {
    /// Count of interactions in [from, to) grouped by type.
    func countInteractionsByType(from: Date, to: Date) async throws -> [InteractionType: Int]

    /// Open promises, sorted by due date ascending (nil-due last).
    func fetchOpenPromises(limit: Int) async throws -> [Promise]

    /// Contacts whose most recent interaction predates `notSeenSince`.
    func fetchContactsNotSeen(since notSeenSince: Date, limit: Int) async throws -> [Contact]

    /// Count of work sessions with `.suggested` billable status.
    func countUnreviewedWorkSessions() async throws -> Int

    /// Work sessions whose `startedAt` falls in [from, to).
    func fetchWorkSessions(from: Date, to: Date) async throws -> [WorkSession]

    /// Projects keyed by ID for the given set of sessions.
    func fetchProjectsForSessionIds(_ ids: [EntityID]) async throws -> [EntityID: Project]

    /// Contacts whose interaction frequency declined vs the prior period.
    func fetchContactsWithDecliningActivity(referencePeriodDays: Int, limit: Int) async throws -> [Contact]

    /// Open promises extracted at least `olderThanDays` days ago.
    func fetchOpenPromisesOlderThan(days: Int) async throws -> [Promise]

    /// Persist a newly generated digest.
    func saveDigest(_ digest: Digest) async throws

    /// Most recent digest of the given kind, or nil if none exists.
    func fetchLatestDigest(kind: DigestKind) async throws -> Digest?
}

// MARK: - Ollama types (private)

private struct OllamaRequest: Encodable {
    let model: String
    let prompt: String
    let stream: Bool
    let options: Options

    struct Options: Encodable {
        let temperature: Double
        let num_predict: Int
    }
}

private struct OllamaResponse: Decodable {
    let response: String
}

// MARK: - DigestGenerator

/// An actor that generates daily and weekly digests, stores them, and fires
/// macOS notifications with the AI-generated summary.
///
/// **Lifecycle:**
/// 1. `start(...)` — stores dependencies and launches the timer loop.
/// 2. The loop sleeps until the next configured digest time, generates the
///    appropriate digest, then reschedules.
/// 3. `generateDailyDigest()` and `generateWeeklyDigest()` can also be called
///    directly (e.g., for on-demand refresh from the Today view).
actor DigestGenerator {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "DigestGenerator"
    )

    // MARK: Dependencies

    private var storage: (any DigestStorageService)?
    private var notificationScheduler: NotificationScheduler?
    private var digestTime: String = "09:00"

    /// Weak reference to AppState so we don't create a retain cycle.
    private weak var appState: AppState?

    // MARK: - Start

    /// Begins the background timer loop. Safe to call multiple times; the
    /// previous task is cancelled before a new one starts.
    private var loopTask: Task<Void, Never>?

    func start(
        storage: any DigestStorageService,
        notificationScheduler: NotificationScheduler,
        appState: AppState,
        digestTime: String = "09:00"
    ) {
        self.storage = storage
        self.notificationScheduler = notificationScheduler
        self.appState = appState
        self.digestTime = digestTime

        loopTask?.cancel()
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
        Self.logger.info("DigestGenerator started (time: \(digestTime, privacy: .public))")
    }

    /// Updates the configured digest time and restarts the loop.
    func updateDigestTime(_ time: String) {
        digestTime = time
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    // MARK: - Timer loop

    private func runLoop() async {
        while !Task.isCancelled {
            let nextFire = nextFireDate(timeString: digestTime)
            let delay = nextFire.timeIntervalSinceNow
            Self.logger.debug("Next digest in \(Int(delay / 3600), privacy: .public)h \(Int((delay.truncatingRemainder(dividingBy: 3600)) / 60), privacy: .public)m")

            do {
                try await Task.sleep(for: .seconds(max(1, delay)))
            } catch {
                return // Task cancelled
            }

            await generateDailyDigest()

            // Also generate weekly digest on Fridays (weekday == 6 in Gregorian).
            let weekday = Calendar.current.component(.weekday, from: Date())
            if weekday == 6 {
                await generateWeeklyDigest()
            }
        }
    }

    // MARK: - Daily digest

    func generateDailyDigest() async {
        Self.logger.info("Generating daily digest")
        guard let storage else {
            Self.logger.debug("No storage — skipping daily digest")
            return
        }

        let cal = Calendar.current
        let now = Date()
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        let yesterdayStart = cal.startOfDay(for: yesterday)
        let yesterdayEnd   = cal.startOfDay(for: now)

        do {
            // Fetch all inputs in parallel.
            async let typeCounts       = storage.countInteractionsByType(from: yesterdayStart, to: yesterdayEnd)
            async let openPromises     = storage.fetchOpenPromises(limit: 10)
            async let quietContacts    = storage.fetchContactsNotSeen(since: cal.date(byAdding: .day, value: -7, to: now)!, limit: 5)
            async let unreviewedCount  = storage.countUnreviewedWorkSessions()

            let (tc, op, qc, uc) = try await (typeCounts, openPromises, quietContacts, unreviewedCount)

            let meetings   = tc[.meeting] ?? 0
            let emailsSent = tc[.emailSent] ?? 0
            let emailsRecv = tc[.emailReceived] ?? 0
            let slack      = tc[.slackDM] ?? 0

            let title = buildDailyTitle(date: now)
            let body  = await buildDailyBody(
                meetings: meetings,
                emails: emailsSent + emailsRecv,
                slack: slack,
                openPromises: op,
                quietContacts: qc,
                unreviewedCount: uc
            )

            let digest = Digest(
                kind: .daily,
                generatedAt: now,
                title: title,
                bodyText: body,
                meetingCount: meetings,
                emailCount: emailsSent + emailsRecv,
                slackCount: slack,
                openPromiseCount: op.count,
                unreviewedSessionCount: uc,
                quietContactNames: qc.map(\.displayName)
            )

            try await storage.saveDigest(digest)
            Self.logger.info("Daily digest saved (\(digest.id, privacy: .public))")

            await notifyDigestReady(title: title, body: body, kind: .daily)

        } catch {
            Self.logger.error("Daily digest failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Weekly digest

    func generateWeeklyDigest() async {
        Self.logger.info("Generating weekly digest")
        guard let storage else { return }

        let cal = Calendar.current
        let now = Date()

        var weekComps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        weekComps.weekday = 2  // Monday
        let weekStart = cal.date(from: weekComps) ?? cal.date(byAdding: .day, value: -6, to: now)!
        let weekEnd   = cal.date(byAdding: .day, value: 7, to: weekStart)!

        let priorWeekStart = cal.date(byAdding: .weekOfYear, value: -1, to: weekStart)!

        do {
            async let thisSessions  = storage.fetchWorkSessions(from: weekStart, to: weekEnd)
            async let priorSessions = storage.fetchWorkSessions(from: priorWeekStart, to: weekStart)
            async let openPromises  = storage.fetchOpenPromisesOlderThan(days: 3)
            async let declContacts  = storage.fetchContactsWithDecliningActivity(referencePeriodDays: 14, limit: 5)

            let (ts, ps, op, dc) = try await (thisSessions, priorSessions, openPromises, declContacts)

            let projectIds = Array(Set(ts.compactMap(\.projectId)))
            let projectMap = try await storage.fetchProjectsForSessionIds(projectIds)

            let totalHours    = ts.map(\.durationHours).reduce(0, +)
            let reviewed      = ts.filter { $0.billableStatus == .confirmed }.count
            let pending       = ts.filter { $0.billableStatus == .suggested }.count
            let billableHours = ts.filter { $0.billableStatus == .confirmed }
                .reduce(0.0) { $0 + $1.durationHours }
            let priorBillable = ps.filter { $0.billableStatus == .confirmed }
                .map(\.durationHours).reduce(0, +)

            // Estimate value using project rates (fall back to 0 when unknown).
            let estimatedValue = ts.filter { $0.billableStatus == .confirmed }
                .reduce(0.0) {
                    $0 + $1.durationHours * (projectMap[$1.projectId ?? ""]?.hourlyRate ?? 0)
                }

            let title = buildWeeklyTitle(weekStart: weekStart)
            let body  = await buildWeeklyBody(
                totalHours: totalHours,
                billableHours: billableHours,
                priorBillableHours: priorBillable,
                reviewed: reviewed,
                pending: pending,
                decliningContacts: dc,
                agingPromises: op,
                estimatedValue: estimatedValue
            )

            let digest = Digest(
                kind: .weekly,
                generatedAt: now,
                title: title,
                bodyText: body,
                openPromiseCount: op.count,
                unreviewedSessionCount: pending,
                quietContactNames: dc.map(\.displayName),
                totalHoursTracked: totalHours,
                estimatedBillableHours: billableHours,
                sessionsReviewedCount: reviewed,
                sessionsPendingCount: pending,
                priorWeekBillableHours: priorBillable
            )

            try await storage.saveDigest(digest)
            Self.logger.info("Weekly digest saved (\(digest.id, privacy: .public))")

            await notifyDigestReady(title: title, body: body, kind: .weekly)

        } catch {
            Self.logger.error("Weekly digest failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Text generation

    private func buildDailyBody(
        meetings: Int,
        emails: Int,
        slack: Int,
        openPromises: [Promise],
        quietContacts: [Contact],
        unreviewedCount: Int
    ) async -> String {
        let prompt = """
        Generate a brief daily professional digest in 2-3 sentences. Be direct and actionable.

        Yesterday's activity:
        - \(meetings) meeting\(meetings == 1 ? "" : "s")
        - \(emails) email\(emails == 1 ? "" : "s")
        - \(slack) Slack message\(slack == 1 ? "" : "s")

        Open priorities (\(openPromises.count) promises):
        \(openPromises.prefix(3).map { p in
            let due = p.dueDate.map { " (due \(Self.shortDate($0)))" } ?? ""
            return "- \(p.description)\(due)"
        }.joined(separator: "\n"))

        Relationships going quiet: \(quietContacts.prefix(3).map(\.displayName).joined(separator: ", "))

        Unreviewed billing: \(unreviewedCount) session\(unreviewedCount == 1 ? "" : "s")

        Write only 2-3 sentences. Focus on the most important action today. Do not use bullet points.
        """

        if let ai = try? await callOllama(prompt: prompt) {
            return ai
        }
        // Fallback template
        return buildDailyTemplate(meetings: meetings, emails: emails, openPromises: openPromises, quietContacts: quietContacts, unreviewedCount: unreviewedCount)
    }

    private func buildWeeklyBody(
        totalHours: Double,
        billableHours: Double,
        priorBillableHours: Double,
        reviewed: Int,
        pending: Int,
        decliningContacts: [Contact],
        agingPromises: [Promise],
        estimatedValue: Double
    ) async -> String {
        let delta = billableHours - priorBillableHours
        let deltaStr = delta >= 0 ? "+\(String(format: "%.1f", delta))h" : "\(String(format: "%.1f", delta))h"

        let prompt = """
        Generate a brief weekly professional digest in 2-3 sentences. Be direct and focus on revenue and relationships.

        This week:
        - \(String(format: "%.1f", totalHours))h total tracked
        - \(String(format: "%.1f", billableHours))h confirmed billable (\(deltaStr) vs last week)
        - \(reviewed) sessions reviewed, \(pending) still pending
        - Estimated value: $\(Int(estimatedValue))

        Relationship health:
        \(decliningContacts.prefix(3).map { "- \($0.displayName) — interaction declining" }.joined(separator: "\n"))

        Aging promises (\(agingPromises.count)):
        \(agingPromises.prefix(3).map { "- \($0.description)" }.joined(separator: "\n"))

        Write only 2-3 sentences. Do not use bullet points.
        """

        if let ai = try? await callOllama(prompt: prompt) {
            return ai
        }
        return buildWeeklyTemplate(totalHours: totalHours, billableHours: billableHours, priorBillableHours: priorBillableHours, reviewed: reviewed, pending: pending, agingPromises: agingPromises)
    }

    // MARK: - Fallback templates

    private func buildDailyTemplate(
        meetings: Int,
        emails: Int,
        openPromises: [Promise],
        quietContacts: [Contact],
        unreviewedCount: Int
    ) -> String {
        var parts: [String] = []
        if meetings > 0 || emails > 0 {
            parts.append("Yesterday you had \(meetings) meeting\(meetings == 1 ? "" : "s") and \(emails) email\(emails == 1 ? "" : "s").")
        }
        if openPromises.count > 0 {
            let due = openPromises.filter { $0.isOverdue }
            if due.isEmpty {
                parts.append("You have \(openPromises.count) open commitment\(openPromises.count == 1 ? "" : "s") to follow up on.")
            } else {
                parts.append("\(due.count) commitment\(due.count == 1 ? " is" : "s are") overdue — address \(due.count == 1 ? "it" : "them") today.")
            }
        }
        if !quietContacts.isEmpty {
            parts.append("Consider reaching out to \(quietContacts.first!.displayName)\(quietContacts.count > 1 ? " and \(quietContacts.count - 1) other\(quietContacts.count == 2 ? "" : "s")" : "") — the relationship is going quiet.")
        }
        if unreviewedCount > 0 {
            parts.append("\(unreviewedCount) billing session\(unreviewedCount == 1 ? " needs" : "s need") your review.")
        }
        return parts.joined(separator: " ")
    }

    private func buildWeeklyTemplate(
        totalHours: Double,
        billableHours: Double,
        priorBillableHours: Double,
        reviewed: Int,
        pending: Int,
        agingPromises: [Promise]
    ) -> String {
        let delta = billableHours - priorBillableHours
        var parts: [String] = []
        parts.append("This week you tracked \(String(format: "%.1f", totalHours))h, with \(String(format: "%.1f", billableHours))h confirmed billable.")
        if abs(delta) > 0.5 {
            parts.append("That's \(delta > 0 ? "up" : "down") \(String(format: "%.1f", abs(delta)))h vs last week.")
        }
        if pending > 0 {
            parts.append("\(pending) session\(pending == 1 ? "" : "s") still need\(pending == 1 ? "s" : "") review before you can invoice.")
        }
        if !agingPromises.isEmpty {
            parts.append("\(agingPromises.count) open commitment\(agingPromises.count == 1 ? "" : "s") aging — consider clearing them before the weekend.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Title builders

    private func buildDailyTitle(date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let greeting: String
        if hour < 12 { greeting = "Morning Digest" }
        else if hour < 17 { greeting = "Afternoon Digest" }
        else { greeting = "Evening Digest" }
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        return "\(greeting) · \(f.string(from: date))"
    }

    private func buildWeeklyTitle(weekStart: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        let end = Calendar.current.date(byAdding: .day, value: 6, to: weekStart)!
        return "Weekly Digest · \(f.string(from: weekStart))–\(f.string(from: end))"
    }

    // MARK: - Ollama integration

    private func callOllama(prompt: String) async throws -> String {
        guard let url = URL(string: "http://localhost:11434/api/generate") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = OllamaRequest(
            model: "llama3",
            prompt: prompt,
            stream: false,
            options: .init(temperature: 0.3, num_predict: 350)
        )
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(OllamaResponse.self, from: data)
        let text = decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw URLError(.zeroByteResource) }
        return text
    }

    // MARK: - Notification delivery

    private func notifyDigestReady(title: String, body: String, kind: DigestKind) async {
        await notificationScheduler?.deliverDigestNotification(title: title, body: body, kind: kind)
        NotificationCenter.default.post(name: .kerwanNewDigestReady, object: nil)
    }

    // MARK: - Date helpers

    private func nextFireDate(timeString: String) -> Date {
        let parts = timeString.split(separator: ":").compactMap { Int($0) }
        let hour   = parts.count > 0 ? parts[0] : 9
        let minute = parts.count > 1 ? parts[1] : 0

        let cal = Calendar.current
        let now = Date()
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour   = hour
        comps.minute = minute
        comps.second = 0

        var candidate = cal.date(from: comps) ?? now
        // If the time has already passed today, advance to tomorrow.
        if candidate <= now {
            candidate = cal.date(byAdding: .day, value: 1, to: candidate) ?? now
        }
        return candidate
    }

    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}

// MARK: - Notification name

extension Notification.Name {
    /// Posted by `DigestGenerator` after a new digest is saved and the
    /// notification is delivered. Observed by `TodayViewModel` to reload.
    static let kerwanNewDigestReady = Notification.Name("com.kerwan.app.newDigestReady")
}
