import Foundation
import UserNotifications
import os

/// Drives the pre-call briefing pipeline and post-meeting summarisation.
///
/// ## Pre-call flow (triggered 2 min before each meeting)
///
/// `CalendarCaptureService` posts `.kerwanPreCallBriefingNeeded`.
/// `BriefingScheduler` picks it up and:
/// 1. Resolves attendee emails/names → ``Contact`` records (via storage, or creates stubs).
/// 2. Fetches the last 5 interactions and open promises per contact.
/// 3. Generates 3-5 bullet points via Ollama (degrades gracefully when unavailable).
/// 4. Posts `.kerwanBriefingReady` for ``BriefingWindowController`` to display.
/// 5. Pushes a macOS notification as a fallback for when the app is backgrounded.
/// 6. Schedules a post-meeting summarisation task (fires `endDate + 30 s`).
///
/// ## Post-meeting flow (endDate + 30 s)
///
/// 1. Fetches all `.audio` raw events recorded during the meeting window.
/// 2. Sends the transcript to Ollama for extraction of decisions, action items,
///    promises, and follow-ups.
/// 3. Saves the result as an ``Interaction`` linked to the meeting attendees.
/// 4. Pushes a "Meeting Summary ready" macOS notification.
///
/// ## Dependency injection
///
/// Both `OllamaClient` and `BriefingStorage` are optional at construction time
/// so the actor starts cleanly even before the storage workstream is wired in.
/// Inject storage via ``setStorage(_:)`` before or after ``start()``.
public actor BriefingScheduler {

    // MARK: - Constants

    /// Reuses the same model as the classification pipeline for consistency.
    static let model = ClassificationActor.classificationModel

    // MARK: - Logging

    private static let logger = Logger(subsystem: "com.kerwan.app", category: "BriefingScheduler")

    // MARK: - Dependencies

    private let ollama: OllamaClient
    private var storage: (any BriefingStorage)?

    // MARK: - State

    private var listenerTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates a `BriefingScheduler`.
    ///
    /// - Parameters:
    ///   - ollama: A configured `OllamaClient` pointed at the local Ollama server.
    ///   - storage: Optional `BriefingStorage` for contact/history lookups.
    ///             Inject later via ``setStorage(_:)`` if not available at init.
    init(ollama: OllamaClient, storage: (any BriefingStorage)? = nil) {
        self.ollama   = ollama
        self.storage  = storage
    }

    // MARK: - Dependency Injection

    /// Injects the storage backend. Safe to call before or after ``start()``.
    func setStorage(_ storage: any BriefingStorage) {
        self.storage = storage
        Self.logger.info("BriefingStorage injected into BriefingScheduler")
    }

    // MARK: - Lifecycle

    /// Starts listening for `.kerwanPreCallBriefingNeeded` notifications.
    /// Safe to call multiple times; subsequent calls are no-ops.
    func start() {
        guard listenerTask == nil else { return }
        listenerTask = Task { [weak self] in
            let stream = NotificationCenter.default.notifications(named: .kerwanPreCallBriefingNeeded)
            for await note in stream {
                guard let self else { break }
                guard let brief = note.calendarEventBrief else {
                    Self.logger.warning("PreCallBriefingNeeded notification missing CalendarEventBrief — skipped")
                    continue
                }
                await self.handleBriefingNeeded(brief)
            }
        }
        Self.logger.info("BriefingScheduler started")
    }

    /// Stops the notification listener and cancels any in-flight work.
    func stop() {
        listenerTask?.cancel()
        listenerTask = nil
        Self.logger.info("BriefingScheduler stopped")
    }

    // MARK: - Pre-call Pipeline

    private func handleBriefingNeeded(_ event: CalendarEventBrief) async {
        Self.logger.info("Briefing pipeline starting for '\(event.title, privacy: .public)' at \(event.startDate, privacy: .public)")

        let ollamaAvailable = await ollama.isHealthy()

        // 1. Resolve attendees → contacts + context
        let attendees = await fetchAttendeeContexts(for: event)

        // 2. Generate bullet points
        let bullets: [String]
        if ollamaAvailable {
            bullets = await generateBulletPoints(event: event, attendees: attendees)
        } else {
            Self.logger.warning("Ollama unavailable — delivering context-only briefing")
            bullets = fallbackBullets(from: attendees)
        }

        let briefing = PreCallBriefing(event: event, attendees: attendees, bulletPoints: bullets)

        // 3. Deliver to the panel UI
        await MainActor.run {
            NotificationCenter.default.post(
                name: .kerwanBriefingReady,
                object: nil,
                userInfo: [BriefingNotificationKey.briefing: briefing]
            )
        }
        Self.logger.info("Briefing delivered for '\(event.title, privacy: .public)'")

        // 4. Fallback macOS notification
        await pushPreCallNotification(event: event, attendees: attendees)

        // 5. Schedule post-meeting summarisation
        schedulePostMeetingSummary(event: event)
    }

    // MARK: - Attendee Context

    private func fetchAttendeeContexts(for event: CalendarEventBrief) async -> [AttendeeContext] {
        guard let storage else {
            // No storage yet — return stub contacts from the attendee list
            return makeStubContexts(event: event)
        }

        let pairs = zipAttendeePairs(emails: event.attendeeEmails, names: event.attendeeNames)
        var contexts: [AttendeeContext] = []

        for (email, name) in pairs {
            guard let contact = await resolveContact(email: email, name: name, storage: storage) else { continue }

            let interactions: [Interaction]
            let promises: [Promise]
            do {
                async let ia = storage.fetchRecentInteractions(contactId: contact.id, limit: 5)
                async let pr = storage.fetchOpenPromises(contactId: contact.id)
                (interactions, promises) = try await (ia, pr)
            } catch {
                Self.logger.error("Context fetch failed for \(contact.id, privacy: .public): \(error, privacy: .public)")
                interactions = []
                promises     = []
            }
            contexts.append(AttendeeContext(
                contact: contact,
                recentInteractions: interactions,
                openPromises: promises
            ))
        }
        return contexts
    }

    private func resolveContact(
        email: String?,
        name: String?,
        storage: any BriefingStorage
    ) async -> Contact? {
        do {
            if let email, !email.isEmpty {
                if let c = try await storage.findContact(byEmail: email) { return c }
            }
            if let name, !name.isEmpty {
                if let c = try await storage.findContact(byName: name) { return c }
            }
            // Create a stub so the name appears in the panel even without history
            let displayName = name ?? email ?? "Unknown Attendee"
            let contact = Contact(displayName: displayName, emailPrimary: email, needsReview: true)
            try await storage.upsertContact(contact)
            return contact
        } catch {
            Self.logger.error("Contact resolution error: \(error, privacy: .public)")
            return nil
        }
    }

    private func makeStubContexts(event: CalendarEventBrief) -> [AttendeeContext] {
        let pairs = zipAttendeePairs(emails: event.attendeeEmails, names: event.attendeeNames)
        return pairs.compactMap { (email, name) -> AttendeeContext? in
            let displayName = name ?? email ?? "Unknown"
            let contact = Contact(displayName: displayName, emailPrimary: email, needsReview: true)
            return AttendeeContext(contact: contact, recentInteractions: [], openPromises: [])
        }
    }

    /// Zips email and name arrays into pairs, padding with `nil` for unequal lengths.
    private func zipAttendeePairs(
        emails: [String],
        names: [String]
    ) -> [(email: String?, name: String?)] {
        let count = max(emails.count, names.count)
        return (0..<count).map { i in
            (
                email: i < emails.count ? emails[i] : nil,
                name:  i < names.count  ? names[i]  : nil
            )
        }
    }

    // MARK: - LLM Bullet Generation

    private func generateBulletPoints(
        event: CalendarEventBrief,
        attendees: [AttendeeContext]
    ) async -> [String] {
        let prompt = buildBriefingPrompt(event: event, attendees: attendees)
        do {
            let raw = try await ollama.complete(
                prompt: prompt,
                system: "You are a concise executive assistant. Output bullet points only — no headers, no preamble. Use '•' to start each point.",
                model: Self.model
            )
            return parseBullets(raw)
        } catch {
            Self.logger.error("Briefing LLM call failed: \(error, privacy: .public)")
            return fallbackBullets(from: attendees)
        }
    }

    private func buildBriefingPrompt(event: CalendarEventBrief, attendees: [AttendeeContext]) -> String {
        let timeFmt = DateFormatter()
        timeFmt.dateStyle = .none
        timeFmt.timeStyle = .short

        var lines: [String] = [
            "Generate a brief pre-call preparation summary. I'm about to have a meeting with these people.",
            "",
            "Meeting: \(event.title)",
            "Time: \(timeFmt.string(from: event.startDate))",
            "",
            "Attendees:"
        ]

        let relFmt = RelativeDateTimeFormatter()

        for ctx in attendees {
            var desc = "• \(ctx.contact.displayName)"
            if let company = ctx.contact.company { desc += " (\(company))" }
            lines.append(desc)

            if let lastDate = ctx.lastInteractionDate, let summary = ctx.lastInteractionSummary {
                lines.append("  Last interaction \(relFmt.localizedString(for: lastDate, relativeTo: Date())): \(summary)")
            } else {
                lines.append("  No prior interactions recorded.")
            }

            let userOwes = ctx.openPromises.filter { $0.direction == .userPromised }
            let theyOwe  = ctx.openPromises.filter { $0.direction == .contactPromised }
            if !userOwes.isEmpty {
                lines.append("  I owe them: \(userOwes.map(\.description).joined(separator: "; "))")
            }
            if !theyOwe.isEmpty {
                lines.append("  They owe me: \(theyOwe.map(\.description).joined(separator: "; "))")
            }
        }

        lines += [
            "",
            "Write 3-5 bullet points I should know going into this call.",
            "Focus on: what was last discussed, what I owe them, what they owe me, any sensitivities."
        ]
        return lines.joined(separator: "\n")
    }

    private func parseBullets(_ raw: String) -> [String] {
        raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line -> String in
                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    return "• " + line.dropFirst(2)
                }
                if line.hasPrefix("•") { return line }
                // Numbered list: "1. foo"
                if let dotIdx = line.firstIndex(of: "."),
                   line[line.startIndex..<dotIdx].allSatisfy(\.isNumber) {
                    return "• " + line[line.index(after: dotIdx)...].trimmingCharacters(in: .whitespaces)
                }
                return "• " + line
            }
            .prefix(7)
            .map { String($0) }
    }

    private func fallbackBullets(from attendees: [AttendeeContext]) -> [String] {
        var bullets: [String] = []
        for ctx in attendees {
            if let summary = ctx.lastInteractionSummary {
                bullets.append("• \(ctx.contact.displayName): Last discussed — \(summary)")
            }
            let overdue = ctx.openPromises.filter(\.isOverdue)
            if !overdue.isEmpty {
                bullets.append("• ⚠️ Overdue items with \(ctx.contact.displayName): \(overdue.map(\.description).joined(separator: "; "))")
            }
        }
        if bullets.isEmpty {
            bullets = ["• No prior interaction history found for the invited attendees."]
        }
        return bullets
    }

    // MARK: - macOS Notification (pre-call)

    private func pushPreCallNotification(
        event: CalendarEventBrief,
        attendees: [AttendeeContext]
    ) async {
        let names = attendees.prefix(3).map { $0.contact.displayName }.joined(separator: ", ")
        let body  = names.isEmpty ? "Briefing ready." : "With: \(names)"

        let content = UNMutableNotificationContent()
        content.title           = "Meeting in 2 min: \(event.title)"
        content.body            = body
        content.sound           = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "com.kerwan.briefing.pre.\(event.id)",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Self.logger.error("Pre-call notification failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Post-Meeting Scheduling

    private func schedulePostMeetingSummary(event: CalendarEventBrief) {
        let delay = event.endDate.timeIntervalSinceNow + 30
        guard delay > 0 else { return }

        // Capture value-type dependencies so the detached task is Sendable.
        let ollamaCopy  = ollama
        let storageCopy = storage

        Task {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return // Cancelled
            }
            await BriefingScheduler.runPostMeetingSummary(
                event: event,
                ollama: ollamaCopy,
                storage: storageCopy
            )
        }
        Self.logger.info(
            "Post-meeting summary scheduled for '\(event.title, privacy: .public)' in \(Int(delay))s"
        )
    }

    // MARK: - Post-Meeting Pipeline (static — no actor isolation required)

    private static func runPostMeetingSummary(
        event: CalendarEventBrief,
        ollama: OllamaClient,
        storage: (any BriefingStorage)?
    ) async {
        logger.info("Post-meeting pipeline starting for '\(event.title, privacy: .public)'")

        guard let storage else {
            logger.warning("No storage — skipping post-meeting summary for '\(event.title, privacy: .public)'")
            return
        }

        // 1. Fetch transcription raw events from the meeting window
        let transcript: String
        do {
            let events = try await storage.fetchRawEvents(
                from: event.startDate,
                to:   event.endDate,
                source: .audio
            )
            transcript = events.compactMap(\.rawText).filter { !$0.isEmpty }.joined(separator: "\n\n")
        } catch {
            logger.error("Failed to fetch meeting transcripts: \(error, privacy: .public)")
            return
        }

        guard !transcript.isEmpty else {
            logger.info("No transcript data for '\(event.title, privacy: .public)' — skipping")
            return
        }

        // 2. Check Ollama availability
        guard await ollama.isHealthy() else {
            logger.warning("Ollama unavailable — skipping post-meeting summary")
            return
        }

        // 3. Summarise via LLM
        let prompt = """
            Summarize this meeting titled "\(event.title)".

            Transcript:
            \(transcript.prefix(8_000))

            Extract and present clearly:
            • Key decisions made
            • Action items (who does what, by when)
            • Promises made (by whom, to whom)
            • Follow-ups needed

            Be concise. Use bullet points under each heading.
            """

        let summary: String
        do {
            summary = try await ollama.complete(
                prompt: prompt,
                system: "You are a concise meeting note-taker. Produce a structured, brief summary.",
                model: ClassificationActor.classificationModel
            )
        } catch {
            logger.error("Post-meeting LLM call failed: \(error, privacy: .public)")
            return
        }

        // 4. Save as an Interaction so it appears in the timeline
        let interaction = Interaction(
            source: .calendar,
            interactionType: .meeting,
            startedAt: event.startDate,
            endedAt:   event.endDate,
            summary:   String(summary.prefix(500)),
            sentiment: .neutral,
            importance: 0.7,
            contentTags: ["post-meeting-summary"],
            isReviewed: false
        )
        do {
            try await storage.insertInteraction(interaction)
            logger.info("Post-meeting interaction saved: \(interaction.id, privacy: .public)")
        } catch {
            logger.error("Failed to save post-meeting interaction: \(error, privacy: .public)")
        }

        // 5. Push summary notification
        await pushPostMeetingNotification(event: event, summary: summary)
    }

    private static func pushPostMeetingNotification(
        event: CalendarEventBrief,
        summary: String
    ) async {
        // Use first non-empty line as the notification body preview
        let preview = summary
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            ?? "Tap to review."

        let content = UNMutableNotificationContent()
        content.title = "Meeting Summary: \(event.title)"
        content.body  = preview
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.kerwan.briefing.post.\(event.id)",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            logger.info("Post-meeting notification delivered for '\(event.title, privacy: .public)'")
        } catch {
            logger.error("Post-meeting notification failed: \(error, privacy: .public)")
        }
    }
}
