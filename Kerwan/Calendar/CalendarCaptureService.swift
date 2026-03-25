// CalendarCaptureService.swift
// Kerwan — Calendar capture layer
//
// Captures EKEvents via EventKit and produces RawEvents (source: .calendar)
// for the Kerwan classification pipeline.
//
// Lifecycle
// ─────────
//   1. start(delegate:)
//        → requestAccess  (throws CalendarCaptureError.accessDenied on denial)
//        → load 90 days history + 7 days future  → emit RawEvents
//        → observe EKEventStoreChangedNotification
//        → launch pre-call briefing loop (30 s tick)
//   2. EKEventStore changed
//        → re-query today → +7 days
//        → diff against knownEventIDs
//        → emit RawEvents for new occurrences only
//   3. Briefing loop (every 30 s)
//        → check cachedEvents for starts within next 2 min
//        → post Notification.Name.kerwanPreCallBriefingNeeded (once per event)
//   4. stop() → cancel loop, remove observer
//
// Mocking strategy
// ────────────────
//   All EventKit calls are wrapped in the injectable Environment struct.
//   The live environment extracts EKEvent data into CalendarEventData value
//   types before returning, so EventKit objects never escape the main thread.
//   Tests inject predetermined CalendarEventData arrays via mock closures.
//
// EventKit threading
// ──────────────────
//   @MainActor is required — requestFullAccessToEvents (and the older
//   requestAccess completion-handler variant) must be called on the main
//   thread. All EKEventStore operations are therefore synchronous and
//   confined to the main actor.

import EventKit
import Foundation
import os

// MARK: - Notification names

extension Notification.Name {
    /// Posted when a calendar event is about to start (within `briefingLeadTime`).
    ///
    /// `userInfo` keys: `KerwanNotificationKey.attendeeEmails` → `[String]`
    ///                  `KerwanNotificationKey.calendarEvent`  → `CalendarEvent`
    public static let kerwanPreCallBriefingNeeded =
        Notification.Name("com.kerwan.preCallBriefingNeeded")
}

// MARK: - KerwanNotificationKey

public enum KerwanNotificationKey {
    public static let attendeeEmails = "attendeeEmails"
    public static let calendarEvent  = "calendarEvent"
}

// MARK: - CalendarCaptureError

public enum CalendarCaptureError: Error, LocalizedError, Sendable, Equatable {
    case accessDenied
    case accessRequestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Calendar access denied — visit System Settings › Privacy & Security"
        case .accessRequestFailed(let reason):
            return "Calendar access request failed: \(reason)"
        }
    }
}

// MARK: - CalendarEvent

/// Lightweight, `Sendable` snapshot of an EKEvent.
///
/// Used for `getUpcomingEvents(within:)` queries and pre-call briefing payloads.
public struct CalendarEvent: Sendable {
    public let eventIdentifier: String
    public let title:           String
    public let startDate:       Date
    public let endDate:         Date
    public let attendees:       [(name: String, email: String?)]
    public let isAllDay:        Bool

    public init(
        eventIdentifier: String,
        title:           String,
        startDate:       Date,
        endDate:         Date,
        attendees:       [(name: String, email: String?)],
        isAllDay:        Bool
    ) {
        self.eventIdentifier = eventIdentifier
        self.title           = title
        self.startDate       = startDate
        self.endDate         = endDate
        self.attendees       = attendees
        self.isAllDay        = isAllDay
    }
}

// MARK: - CalendarAttendeeInfo

/// Sendable attendee snapshot embedded in `CalendarCaptureMetadata`.
public struct CalendarAttendeeInfo: Codable, Sendable, Equatable {
    public let name:   String?
    public let email:  String?
    /// One of: "accepted", "declined", "tentative", "pending", "delegated", "unknown".
    public let status: String

    public init(name: String?, email: String?, status: String) {
        self.name   = name
        self.email  = email
        self.status = status
    }
}

// MARK: - CalendarEventData

/// Sendable value-type snapshot of an `EKEvent`.
///
/// The live `Environment.fetchEvents` closure extracts all data from EKEvent
/// into this struct before returning, allowing EventKit objects to remain on
/// the main thread and avoiding Sendable violations.
public struct CalendarEventData: Sendable {
    public let eventIdentifier: String
    public let title:           String
    public let notes:           String?
    public let location:        String?
    public let startDate:       Date
    public let endDate:         Date
    public let isAllDay:        Bool
    public let calendarTitle:   String?
    public let organizerEmail:  String?
    public let attendees:       [CalendarAttendeeInfo]
    /// Human-readable description of the first recurrence rule, nil if non-recurring.
    public let recurrenceRule:  String?

    public init(
        eventIdentifier: String,
        title:           String,
        notes:           String?                = nil,
        location:        String?                = nil,
        startDate:       Date,
        endDate:         Date,
        isAllDay:        Bool                   = false,
        calendarTitle:   String?                = nil,
        organizerEmail:  String?                = nil,
        attendees:       [CalendarAttendeeInfo] = [],
        recurrenceRule:  String?                = nil
    ) {
        self.eventIdentifier = eventIdentifier
        self.title           = title
        self.notes           = notes
        self.location        = location
        self.startDate       = startDate
        self.endDate         = endDate
        self.isAllDay        = isAllDay
        self.calendarTitle   = calendarTitle
        self.organizerEmail  = organizerEmail
        self.attendees       = attendees
        self.recurrenceRule  = recurrenceRule
    }
}

// MARK: - CalendarEventData + EKEvent extraction

extension CalendarEventData {
    /// Extracts a `CalendarEventData` from a live `EKEvent`.
    ///
    /// Called on the main thread inside `Environment.fetchEvents` so that
    /// EventKit objects never escape their thread of origin.
    static func from(_ event: EKEvent) -> CalendarEventData {
        CalendarEventData(
            eventIdentifier: event.eventIdentifier ?? UUID().uuidString,
            title:           event.title ?? "(No Title)",
            notes:           event.notes,
            location:        event.location,
            startDate:       event.startDate ?? Date(),
            endDate:         event.endDate   ?? Date(),
            isAllDay:        event.isAllDay,
            calendarTitle:   event.calendar?.title,
            organizerEmail:  event.organizer.flatMap { extractEmail(from: $0.url) },
            attendees:       (event.attendees ?? []).map {
                CalendarAttendeeInfo(
                    name:   $0.name,
                    email:  extractEmail(from: $0.url),
                    status: $0.participantStatus.statusString
                )
            },
            recurrenceRule:  event.recurrenceRules?.first.map { "\($0)" }
        )
    }

    private static func extractEmail(from url: URL) -> String? {
        let s = url.absoluteString
        guard s.hasPrefix("mailto:") else { return s.isEmpty ? nil : s }
        let addr = String(s.dropFirst("mailto:".count))
        return addr.isEmpty ? nil : addr
    }
}

// MARK: - EKParticipantStatus → String

private extension EKParticipantStatus {
    var statusString: String {
        switch self {
        case .accepted:  return "accepted"
        case .declined:  return "declined"
        case .tentative: return "tentative"
        case .pending:   return "pending"
        case .delegated: return "delegated"
        default:         return "unknown"
        }
    }
}

// MARK: - CalendarCaptureMetadata

/// JSON payload for `RawEvent`s with `source == .calendar`.
///
/// Embedded in `RawEvent.metadataJSON`; keys use snake_case to match
/// the ClassificationActor's expectations and the eventual SQLite schema.
public struct CalendarCaptureMetadata: Codable, Sendable, Equatable {

    // MARK: Fields

    public let eventIdentifier: String
    public let calendarTitle:   String?
    public let location:        String?
    public let isAllDay:        Bool
    public let attendees:       [CalendarAttendeeInfo]
    public let organizerEmail:  String?
    public let recurrenceRule:  String?
    /// Concatenation of title and notes for the AI classification pipeline.
    public let rawText:         String?

    // MARK: CodingKeys

    enum CodingKeys: String, CodingKey {
        case eventIdentifier = "event_identifier"
        case calendarTitle   = "calendar_title"
        case location
        case isAllDay        = "is_all_day"
        case attendees
        case organizerEmail  = "organizer_email"
        case recurrenceRule  = "recurrence_rule"
        case rawText         = "raw_text"
    }

    // MARK: Init

    public init(
        eventIdentifier: String,
        calendarTitle:   String?,
        location:        String?,
        isAllDay:        Bool,
        attendees:       [CalendarAttendeeInfo],
        organizerEmail:  String?,
        recurrenceRule:  String?,
        rawText:         String?
    ) {
        self.eventIdentifier = eventIdentifier
        self.calendarTitle   = calendarTitle
        self.location        = location
        self.isAllDay        = isAllDay
        self.attendees       = attendees
        self.organizerEmail  = organizerEmail
        self.recurrenceRule  = recurrenceRule
        self.rawText         = rawText
    }

    // MARK: JSON helpers

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    private static let decoder = JSONDecoder()

    /// Encodes to a compact JSON string; returns `nil` on failure.
    public var jsonString: String? {
        guard let data = try? Self.encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decodes from a JSON string; returns `nil` on failure.
    public static func decode(from json: String) -> CalendarCaptureMetadata? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(CalendarCaptureMetadata.self, from: data)
    }

    // MARK: Builder

    static func from(_ data: CalendarEventData) -> CalendarCaptureMetadata {
        let rawText = buildRawText(title: data.title, notes: data.notes)
        return CalendarCaptureMetadata(
            eventIdentifier: data.eventIdentifier,
            calendarTitle:   data.calendarTitle,
            location:        data.location,
            isAllDay:        data.isAllDay,
            attendees:       data.attendees,
            organizerEmail:  data.organizerEmail,
            recurrenceRule:  data.recurrenceRule,
            rawText:         rawText.isEmpty ? nil : rawText
        )
    }

    private static func buildRawText(title: String, notes: String?) -> String {
        var parts = [title]
        if let n = notes, !n.isEmpty { parts.append(n) }
        return parts.joined(separator: "\n")
    }
}

// MARK: - CalendarCaptureService

/// Captures EKEvents via EventKit and produces `RawEvent`s for the
/// Kerwan classification pipeline.
///
/// ## Lifecycle
/// ```swift
/// let svc = CalendarCaptureService(environment: .live())
/// try await svc.start(delegate: buffer)
/// // … later …
/// svc.stop()
/// ```
///
/// ## Threading
/// `@MainActor` is required because EventKit's `requestFullAccessToEvents`
/// and the notification-observer callback both run on the main thread.
@MainActor
public final class CalendarCaptureService {

    // MARK: - Environment

    public struct Environment: @unchecked Sendable {

        /// Requests full calendar access. Returns `true` if granted.
        var requestAccess: @Sendable () async throws -> Bool

        /// Returns all events in `[start, end)`. Called on `@MainActor`.
        var fetchEvents: @Sendable (Date, Date) -> [CalendarEventData]

        /// NotificationCenter used to observe `EKEventStoreChangedNotification`
        /// (injectable so tests can post the notification directly).
        var notificationCenter: NotificationCenter

        /// Posts a user-visible notification (injectable for tests).
        var postNotification: @Sendable (Notification.Name, [String: Any]) -> Void

        /// Returns the current wall-clock time (injectable for tests).
        var currentDate: @Sendable () -> Date

        /// Interval between pre-call briefing checks (default 30 s).
        var briefingCheckInterval: TimeInterval

        /// Seconds before a meeting start to trigger the briefing (default 120 s = 2 min).
        var briefingLeadTime: TimeInterval

        /// Historical lookback for the initial load (default 90 days).
        var historyLookback: TimeInterval

        /// Forward window for the initial load and change monitoring (default 7 days).
        var forwardWindow: TimeInterval

        // MARK: Live

        public static func live() -> Environment {
            let store = EKEventStore()
            return Environment(
                requestAccess: {
                    if #available(macOS 14.0, *) {
                        return try await store.requestFullAccessToEvents()
                    } else {
                        return try await withCheckedThrowingContinuation { cont in
                            store.requestAccess(to: .event) { granted, error in
                                if let error {
                                    cont.resume(throwing: error)
                                } else {
                                    cont.resume(returning: granted)
                                }
                            }
                        }
                    }
                },
                fetchEvents: { start, end in
                    let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
                    return store.events(matching: pred).map { CalendarEventData.from($0) }
                },
                notificationCenter:   .default,
                postNotification:     { name, info in
                    NotificationCenter.default.post(name: name, object: nil, userInfo: info)
                },
                currentDate:          { Date() },
                briefingCheckInterval: 30,
                briefingLeadTime:      120,
                historyLookback:       60 * 60 * 24 * 90,  // 90 days
                forwardWindow:         60 * 60 * 24 * 7    // 7 days
            )
        }
    }

    // MARK: - State

    private let env:  Environment
    private let log = Logger(subsystem: "com.kerwan.app", category: "CalendarCaptureService")

    private weak var delegate:     (any CaptureEventDelegate)?
    private var knownEventIDs:     Set<String>    = []
    private var cachedEvents:      [CalendarEvent] = []
    private var storeObserver:     Any?
    private var briefingTask:      Task<Void, Never>?

    /// `true` after a successful `start(delegate:)` call.
    public private(set) var isRunning = false

    // MARK: - Init

    public init(environment: Environment = .live()) {
        self.env = environment
    }

    // MARK: - Public API

    /// Requests calendar access, imports the initial event window, and starts
    /// live monitoring and pre-call briefing.
    ///
    /// - Throws: `CalendarCaptureError.accessDenied` if the user denies access,
    ///           `CalendarCaptureError.accessRequestFailed(_:)` on system error.
    public func start(delegate: any CaptureEventDelegate) async throws {
        self.delegate = delegate

        let granted: Bool
        do {
            granted = try await env.requestAccess()
        } catch {
            log.error("Calendar access request failed: \(error.localizedDescription)")
            throw CalendarCaptureError.accessRequestFailed(error.localizedDescription)
        }

        guard granted else {
            log.warning("Calendar access denied")
            throw CalendarCaptureError.accessDenied
        }

        // Initial load: history window → future window
        let now    = env.currentDate()
        let past   = now.addingTimeInterval(-env.historyLookback)
        let future = now.addingTimeInterval(env.forwardWindow)
        let initial = env.fetchEvents(past, future)
        await emitAndCache(initial, isInitialLoad: true)

        // Observe EKEventStore changes for live monitoring
        storeObserver = env.notificationCenter.addObserver(
            forName: NSNotification.Name.EKEventStoreChanged,
            object:  nil,
            queue:   .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.handleStoreChange()
            }
        }

        // Start the pre-call briefing loop
        briefingTask = Task { [weak self] in
            await self?.briefingLoop()
        }

        isRunning = true
        log.info("CalendarCaptureService started — \(initial.count) event(s) loaded")
    }

    /// Stops live monitoring and the pre-call briefing loop.
    public func stop() {
        if let observer = storeObserver {
            env.notificationCenter.removeObserver(observer)
            storeObserver = nil
        }
        briefingTask?.cancel()
        briefingTask = nil
        isRunning    = false
        log.info("CalendarCaptureService stopped")
    }

    /// Returns cached events whose start time falls within the next `minutes` minutes.
    public func getUpcomingEvents(within minutes: Int) -> [CalendarEvent] {
        let now    = env.currentDate()
        let cutoff = now.addingTimeInterval(Double(minutes) * 60)
        return cachedEvents.filter { $0.startDate >= now && $0.startDate <= cutoff }
    }

    // MARK: - Private: store change handler

    private func handleStoreChange() async {
        let now   = env.currentDate()
        let start = Calendar.current.startOfDay(for: now)
        let end   = now.addingTimeInterval(env.forwardWindow)
        let fresh = env.fetchEvents(start, end)
        await emitAndCache(fresh, isInitialLoad: false)
        log.info("EKEventStore changed — re-queried \(fresh.count) event(s)")
    }

    // MARK: - Private: event emission and caching

    /// Converts `CalendarEventData` items to `RawEvent`s and delegates them.
    ///
    /// - Parameter isInitialLoad: When `true`, all events are added to `knownEventIDs`
    ///   but *only events not already known* generate `RawEvent`s, preventing
    ///   duplicates on service restart.
    private func emitAndCache(_ eventData: [CalendarEventData], isInitialLoad: Bool) async {
        var newRawEvents:      [RawEvent]       = []
        var freshCalendarEvents: [CalendarEvent] = []

        for data in eventData {
            let isNew = !knownEventIDs.contains(data.eventIdentifier)
            knownEventIDs.insert(data.eventIdentifier)

            let calEvent = CalendarEvent(
                eventIdentifier: data.eventIdentifier,
                title:           data.title,
                startDate:       data.startDate,
                endDate:         data.endDate,
                attendees:       data.attendees.map { (name: $0.name ?? "", email: $0.email) },
                isAllDay:        data.isAllDay
            )
            freshCalendarEvents.append(calEvent)

            if isNew {
                let meta = CalendarCaptureMetadata.from(data)
                newRawEvents.append(RawEvent(
                    source:       .calendar,
                    sourceApp:    "Calendar",
                    startedAt:    data.startDate,
                    endedAt:      data.endDate,
                    metadataJSON: meta.jsonString
                ))
            }
        }

        // Refresh the upcoming-events cache
        if isInitialLoad {
            cachedEvents = freshCalendarEvents
        } else {
            var byID = Dictionary(uniqueKeysWithValues: cachedEvents.map { ($0.eventIdentifier, $0) })
            for e in freshCalendarEvents { byID[e.eventIdentifier] = e }
            cachedEvents = byID.values.sorted { $0.startDate < $1.startDate }
        }

        if !newRawEvents.isEmpty {
            await delegate?.didCapture(newRawEvents)
        }
    }

    // MARK: - Private: pre-call briefing loop

    private func briefingLoop() async {
        var firedEventIDs: Set<String> = []

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(env.briefingCheckInterval * 1_000_000_000))
            guard !Task.isCancelled else { break }

            let now    = env.currentDate()
            let cutoff = now.addingTimeInterval(env.briefingLeadTime)

            for event in cachedEvents {
                guard !firedEventIDs.contains(event.eventIdentifier) else { continue }
                guard event.startDate > now, event.startDate <= cutoff  else { continue }

                firedEventIDs.insert(event.eventIdentifier)
                let emails = event.attendees.compactMap(\.email)
                env.postNotification(.kerwanPreCallBriefingNeeded, [
                    KerwanNotificationKey.attendeeEmails: emails,
                    KerwanNotificationKey.calendarEvent:  event
                ])
                log.info("Pre-call briefing triggered for '\(event.title, privacy: .private)' at \(event.startDate)")
            }
        }
    }
}
