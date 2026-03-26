// CalendarCaptureServiceTests.swift
// Kerwan — Calendar capture tests
//
// All tests use an injectable CalendarCaptureService.Environment; no live
// EventKit calls, no real timers, no NotificationCenter.default side-effects.
//
// Note: `Recorder<T>` is defined in GmailOAuthManagerTests.swift and is
// accessible here because both files compile in the same test module.
//
// Test groups
// ───────────
//  CalendarAttendeeInfoTests         — Codable round-trip
//  CalendarCaptureMetadataTests      — encode/decode, snake_case keys, rawText
//  CalendarCaptureServiceLifecycleTests — start happy path, access denied, stop
//  CalendarMonitoringTests           — EKEventStore change → diff → emit
//  CalendarBriefingTests             — pre-call briefing timing, no double-fire
//  CalendarUpcomingQueryTests        — getUpcomingEvents(within:)

import XCTest
@testable import Kerwan

// MARK: - Recorder (local copy; also defined in Email tests target)

/// Thread-safe list for observing side-effecting calls.
fileprivate final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [T] = []
    var values: [T] { lock.withLock { _values } }
    func record(_ value: T) { lock.withLock { _values.append(value) } }
}

// MARK: - XCTAssertThrowsErrorAsync

fileprivate func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error to be thrown. \(message)", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

// MARK: - BatchQueue
//
// Cycles through an array of response batches in order; the last batch repeats
// for any call beyond the configured array length. Needed because
// fetchEvents is a @Sendable closure that must capture mutable state via a
// reference type (can't capture inout).

private final class BatchQueue<T>: @unchecked Sendable {
    private var batches: [[T]]
    private var index   = 0
    private let lock    = NSLock()

    init(_ batches: [[T]]) { self.batches = batches }

    func next() -> [T] {
        lock.withLock {
            let i = min(index, batches.count - 1)
            index += 1
            return batches[i]
        }
    }

    var callCount: Int { lock.withLock { index } }
}

// MARK: - MockCalendarDelegate

actor MockCalendarDelegate: CaptureEventDelegate {
    private(set) var allEvents: [CaptureEvent] = []
    func didCapture(_ events: [CaptureEvent]) async {
        allEvents.append(contentsOf: events)
    }
}

// MARK: - Test fixtures

private let t0 = Date(timeIntervalSince1970: 1_000_000)  // fixed "now" in tests

private func makeEventData(
    id:             String                  = "evt-1",
    title:          String                  = "Team Standup",
    notes:          String?                 = nil,
    location:       String?                 = nil,
    startOffset:    TimeInterval            = 3600,   // 1 h from t0
    duration:       TimeInterval            = 1800,   // 30 min
    isAllDay:       Bool                    = false,
    calendarTitle:  String?                 = "Work",
    organizerEmail: String?                 = nil,
    attendees:      [CalendarAttendeeInfo]  = [],
    recurrenceRule: String?                 = nil
) -> CalendarEventData {
    CalendarEventData(
        eventIdentifier: id,
        title:           title,
        notes:           notes,
        location:        location,
        startDate:       t0.addingTimeInterval(startOffset),
        endDate:         t0.addingTimeInterval(startOffset + duration),
        isAllDay:        isAllDay,
        calendarTitle:   calendarTitle,
        organizerEmail:  organizerEmail,
        attendees:       attendees,
        recurrenceRule:  recurrenceRule
    )
}

private func makeAttendee(name: String, email: String?, status: String = "accepted") -> CalendarAttendeeInfo {
    CalendarAttendeeInfo(name: name, email: email, status: status)
}

// MARK: - Environment factory

extension CalendarCaptureService.Environment {

    /// Creates a test environment backed by in-memory test doubles.
    ///
    /// - Parameters:
    ///   - accessGranted: Whether `requestAccess` returns `true`.
    ///   - accessError: When non-nil, `requestAccess` throws instead of returning.
    ///   - eventBatches: Successive return values of `fetchEvents` (last repeats).
    ///   - notificationCenter: Isolated NC so tests can post to it directly.
    ///   - postedNotifications: Records every call to `postNotification`.
    ///   - currentDate: Fixed or time-advancing clock.
    ///   - briefingCheckInterval: Shortened for tests (default 0.001 s).
    ///   - briefingLeadTime: Seconds before event start to fire briefing.
    fileprivate static func mock(
        accessGranted:         Bool                                                             = true,
        accessError:           Error?                                                           = nil,
        eventBatches:          [[CalendarEventData]]                                            = [[]],
        notificationCenter:    NotificationCenter                                               = NotificationCenter(),
        postedNotifications:   Recorder<(Notification.Name, [String: Any])>                     = Recorder(),
        currentDate:           @escaping @Sendable () -> Date                                   = { t0 },
        briefingCheckInterval: TimeInterval                                                     = 0.001,
        briefingLeadTime:      TimeInterval                                                     = 120,
        historyLookback:       TimeInterval                                                     = 0,
        forwardWindow:         TimeInterval                                                     = 0
    ) -> CalendarCaptureService.Environment {

        let queue   = BatchQueue(eventBatches)
        let noteRec = postedNotifications

        return CalendarCaptureService.Environment(
            requestAccess: {
                if let err = accessError { throw err }
                return accessGranted
            },
            fetchEvents:        { _, _ in queue.next() },
            notificationCenter: notificationCenter,
            postNotification:   { name, info in noteRec.record((name, info)) },
            currentDate:        currentDate,
            briefingCheckInterval: briefingCheckInterval,
            briefingLeadTime:      briefingLeadTime,
            historyLookback:       historyLookback,
            forwardWindow:         forwardWindow
        )
    }
}

// MARK: - CalendarAttendeeInfoTests

final class CalendarAttendeeInfoTests: XCTestCase {

    func test_codableRoundTrip() throws {
        let a = CalendarAttendeeInfo(name: "Alice", email: "alice@example.com", status: "accepted")
        let d = try JSONDecoder().decode(CalendarAttendeeInfo.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(d, a)
    }

    func test_nilEmail_roundTrip() throws {
        let a = CalendarAttendeeInfo(name: "Bob", email: nil, status: "unknown")
        let d = try JSONDecoder().decode(CalendarAttendeeInfo.self, from: JSONEncoder().encode(a))
        XCTAssertNil(d.email)
    }

    func test_nilName_roundTrip() throws {
        let a = CalendarAttendeeInfo(name: nil, email: "c@d.com", status: "declined")
        let d = try JSONDecoder().decode(CalendarAttendeeInfo.self, from: JSONEncoder().encode(a))
        XCTAssertNil(d.name)
        XCTAssertEqual(d.status, "declined")
    }
}

// MARK: - CalendarCaptureMetadataTests

final class CalendarCaptureMetadataTests: XCTestCase {

    func test_from_setsAllFields() {
        let data = makeEventData(
            id:             "id-42",
            title:          "Design Review",
            notes:          "Discuss mockups",
            location:       "Room 3",
            calendarTitle:  "Work",
            organizerEmail: "org@example.com",
            attendees:      [makeAttendee(name: "Alice", email: "a@x.com")],
            recurrenceRule: "FREQ=WEEKLY"
        )
        let meta = CalendarCaptureMetadata.from(data)
        XCTAssertEqual(meta.eventIdentifier, "id-42")
        XCTAssertEqual(meta.calendarTitle,   "Work")
        XCTAssertEqual(meta.location,        "Room 3")
        XCTAssertFalse(meta.isAllDay)
        XCTAssertEqual(meta.attendees.count, 1)
        XCTAssertEqual(meta.organizerEmail,  "org@example.com")
        XCTAssertEqual(meta.recurrenceRule,  "FREQ=WEEKLY")
    }

    func test_rawText_includesTitleAndNotes() {
        let meta = CalendarCaptureMetadata.from(
            makeEventData(title: "Budget Call", notes: "Q2 planning")
        )
        XCTAssertEqual(meta.rawText, "Budget Call\nQ2 planning")
    }

    func test_rawText_nilNotes_isJustTitle() {
        let meta = CalendarCaptureMetadata.from(makeEventData(title: "Lunch", notes: nil))
        XCTAssertEqual(meta.rawText, "Lunch")
    }

    func test_rawText_emptyNotes_isJustTitle() {
        let meta = CalendarCaptureMetadata.from(makeEventData(title: "Call", notes: ""))
        XCTAssertEqual(meta.rawText, "Call")
    }

    func test_isAllDay_propagated() {
        let meta = CalendarCaptureMetadata.from(makeEventData(isAllDay: true))
        XCTAssertTrue(meta.isAllDay)
    }

    func test_snakeCaseKeys() {
        // Pass non-nil values so optional fields are included in the encoded JSON.
        let json = CalendarCaptureMetadata.from(makeEventData(
            organizerEmail: "organizer@example.com",
            recurrenceRule: "FREQ=WEEKLY"
        )).jsonString!
        for key in ["event_identifier", "calendar_title", "is_all_day",
                    "organizer_email", "recurrence_rule", "raw_text"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "Missing JSON key: \(key)")
        }
    }

    func test_encodeDecode_roundTrip() throws {
        let original = CalendarCaptureMetadata.from(
            makeEventData(id: "rt-1", title: "Stand-up",
                          attendees: [makeAttendee(name: "Dev", email: "dev@x.com")])
        )
        let decoded = CalendarCaptureMetadata.decode(from: original.jsonString!)!
        XCTAssertEqual(decoded, original)
    }

    func test_decode_invalidJSON_returnsNil() {
        XCTAssertNil(CalendarCaptureMetadata.decode(from: "not json"))
    }
}

// MARK: - CalendarCaptureServiceLifecycleTests

@MainActor
final class CalendarCaptureServiceLifecycleTests: XCTestCase {

    // MARK: Access granted

    func test_start_emitsRawEventForEachLoadedEvent() async throws {
        let events  = (1...3).map { makeEventData(id: "e\($0)", title: "Event \($0)") }
        let env     = CalendarCaptureService.Environment.mock(eventBatches: [events])
        let delegate = MockCalendarDelegate()
        let service  = CalendarCaptureService(environment: env)

        try await service.start(delegate: delegate)
        service.stop()

        let captured = await delegate.allEvents
        XCTAssertEqual(captured.count, 3)
    }

    func test_start_rawEvents_haveCalendarSourceAndApp() async throws {
        let env      = CalendarCaptureService.Environment.mock(
            eventBatches: [[makeEventData(id: "e1")]]
        )
        let delegate = MockCalendarDelegate()
        let service  = CalendarCaptureService(environment: env)

        try await service.start(delegate: delegate)
        service.stop()

        let event = await delegate.allEvents.first
        XCTAssertEqual(event?.source,    .calendar)
        XCTAssertEqual(event?.sourceApp, "Calendar")
    }

    func test_start_rawEvent_startedAtMatchesEventStart() async throws {
        let data     = makeEventData(id: "e1", startOffset: 7200)  // t0 + 2 h
        let env      = CalendarCaptureService.Environment.mock(eventBatches: [[data]])
        let delegate = MockCalendarDelegate()
        let service  = CalendarCaptureService(environment: env)

        try await service.start(delegate: delegate)
        service.stop()

        let event = await delegate.allEvents.first
        XCTAssertEqual(event?.startedAt, data.startDate)
        XCTAssertEqual(event?.endedAt,   data.endDate)
    }

    func test_start_metadataJSON_containsEventIdentifier() async throws {
        let env      = CalendarCaptureService.Environment.mock(
            eventBatches: [[makeEventData(id: "my-id-99")]]
        )
        let delegate = MockCalendarDelegate()
        let service  = CalendarCaptureService(environment: env)

        try await service.start(delegate: delegate)
        service.stop()

        let json = await delegate.allEvents.first?.metadataJSON ?? ""
        XCTAssertTrue(json.contains("my-id-99"))
    }

    func test_start_setsIsRunning() async throws {
        let env     = CalendarCaptureService.Environment.mock()
        let service = CalendarCaptureService(environment: env)

        try await service.start(delegate: MockCalendarDelegate())
        XCTAssertTrue(service.isRunning)
        service.stop()
    }

    func test_emptyCalendar_completesWithZeroEvents() async throws {
        let env      = CalendarCaptureService.Environment.mock(eventBatches: [[]])
        let delegate = MockCalendarDelegate()
        let service  = CalendarCaptureService(environment: env)

        try await service.start(delegate: delegate)
        service.stop()

        let captured = await delegate.allEvents
        XCTAssertEqual(captured.count, 0)
    }

    // MARK: Access denied

    func test_start_accessDenied_throws() async throws {
        let env     = CalendarCaptureService.Environment.mock(accessGranted: false)
        let service = CalendarCaptureService(environment: env)

        await XCTAssertThrowsErrorAsync(
            try await service.start(delegate: MockCalendarDelegate())
        ) { err in
            XCTAssertEqual(err as? CalendarCaptureError, .accessDenied)
        }
    }

    func test_start_accessRequestFailed_throws() async throws {
        struct FakeError: Error {}
        let env     = CalendarCaptureService.Environment.mock(accessError: FakeError())
        let service = CalendarCaptureService(environment: env)

        await XCTAssertThrowsErrorAsync(
            try await service.start(delegate: MockCalendarDelegate())
        ) { err in
            guard case CalendarCaptureError.accessRequestFailed = err else {
                XCTFail("Expected accessRequestFailed, got \(err)"); return
            }
        }
    }

    func test_start_accessDenied_doesNotSetIsRunning() async throws {
        let env     = CalendarCaptureService.Environment.mock(accessGranted: false)
        let service = CalendarCaptureService(environment: env)

        _ = try? await service.start(delegate: MockCalendarDelegate())
        XCTAssertFalse(service.isRunning)
    }

    // MARK: Stop

    func test_stop_clearsIsRunning() async throws {
        let env     = CalendarCaptureService.Environment.mock()
        let service = CalendarCaptureService(environment: env)

        try await service.start(delegate: MockCalendarDelegate())
        service.stop()
        XCTAssertFalse(service.isRunning)
    }

    func test_stop_beforeStart_doesNotCrash() {
        let service = CalendarCaptureService(environment: .mock())
        service.stop()   // should be safe no-op
    }
}

// MARK: - CalendarMonitoringTests

@MainActor
final class CalendarMonitoringTests: XCTestCase {

    func test_storeChangeNotification_emitsOnlyNewEvent() async throws {
        let initial = [makeEventData(id: "e1"), makeEventData(id: "e2")]
        let updated = [makeEventData(id: "e1"), makeEventData(id: "e2"), makeEventData(id: "e3")]

        let nc       = NotificationCenter()
        let env      = CalendarCaptureService.Environment.mock(
            eventBatches:       [initial, updated],
            notificationCenter: nc
        )
        let delegate = MockCalendarDelegate()
        let service  = CalendarCaptureService(environment: env)

        try await service.start(delegate: delegate)
        // e1 and e2 already captured (2 RawEvents emitted by initial load)

        // Simulate EKEventStore change
        nc.post(name: NSNotification.Name.EKEventStoreChanged, object: nil)
        try await Task.sleep(nanoseconds: 30_000_000)  // 30 ms — let observer task run

        service.stop()

        let captured = await delegate.allEvents
        // Should have initial 2 + 1 new = 3 total; e3 is the only new one
        XCTAssertEqual(captured.count, 3)
        let ids = captured.compactMap { $0.metadataJSON }
            .compactMap { CalendarCaptureMetadata.decode(from: $0)?.eventIdentifier }
        XCTAssertTrue(ids.contains("e3"))
    }

    func test_storeChange_doesNotReEmitExistingEvents() async throws {
        let events = [makeEventData(id: "stable")]
        let nc     = NotificationCenter()
        let env    = CalendarCaptureService.Environment.mock(
            eventBatches:       [events, events],  // same events on both fetches
            notificationCenter: nc
        )
        let delegate = MockCalendarDelegate()
        let service  = CalendarCaptureService(environment: env)

        try await service.start(delegate: delegate)

        nc.post(name: NSNotification.Name.EKEventStoreChanged, object: nil)
        try await Task.sleep(nanoseconds: 30_000_000)

        service.stop()

        let captured = await delegate.allEvents
        XCTAssertEqual(captured.count, 1, "Existing event must not be emitted again")
    }

    func test_storeChange_updatesUpcomingEventsCache() async throws {
        let now    = t0
        let nc     = NotificationCenter()
        // Second fetch returns a new event starting in 5 minutes
        let newEvt = makeEventData(id: "new", startOffset: 300)
        let env    = CalendarCaptureService.Environment.mock(
            eventBatches:       [[], [newEvt]],
            notificationCenter: nc,
            currentDate:        { now }
        )
        let service = CalendarCaptureService(environment: env)
        try await service.start(delegate: MockCalendarDelegate())

        nc.post(name: NSNotification.Name.EKEventStoreChanged, object: nil)
        try await Task.sleep(nanoseconds: 30_000_000)

        let upcoming = service.getUpcomingEvents(within: 10)
        service.stop()

        XCTAssertTrue(upcoming.contains { $0.eventIdentifier == "new" })
    }

    func test_storeChange_allDayEvent_stillEmitted() async throws {
        let nc  = NotificationCenter()
        let env = CalendarCaptureService.Environment.mock(
            eventBatches:       [[], [makeEventData(id: "allday", isAllDay: true)]],
            notificationCenter: nc
        )
        let delegate = MockCalendarDelegate()
        let service  = CalendarCaptureService(environment: env)

        try await service.start(delegate: delegate)
        nc.post(name: NSNotification.Name.EKEventStoreChanged, object: nil)
        try await Task.sleep(nanoseconds: 30_000_000)
        service.stop()

        let captured = await delegate.allEvents
        XCTAssertTrue(captured.contains { event in
            guard let json = event.metadataJSON,
                  let meta = CalendarCaptureMetadata.decode(from: json) else { return false }
            return meta.isAllDay
        })
    }
}

// MARK: - CalendarBriefingTests

@MainActor
final class CalendarBriefingTests: XCTestCase {

    func test_briefing_firesForImminentEvent() async throws {
        // Event starts 60 s from t0 — within the 120 s lead time
        let event  = makeEventData(id: "soon", startOffset: 60,
                                   attendees: [makeAttendee(name: "Bob", email: "bob@x.com")])
        let rec    = Recorder<(Notification.Name, [String: Any])>()
        let env    = CalendarCaptureService.Environment.mock(
            eventBatches:        [[event]],
            postedNotifications: rec,
            currentDate:         { t0 },
            briefingCheckInterval: 0.001,
            briefingLeadTime:      120
        )
        let service = CalendarCaptureService(environment: env)
        try await service.start(delegate: MockCalendarDelegate())
        try await Task.sleep(nanoseconds: 50_000_000)  // 50 ms — let briefing loop tick
        service.stop()

        XCTAssertFalse(rec.values.isEmpty, "Briefing notification should have been posted")
        let name = rec.values.first?.0
        XCTAssertEqual(name, Notification.Name.kerwanPreCallBriefingNeeded)
    }

    func test_briefing_includesAttendeeEmails() async throws {
        let event = makeEventData(
            id:           "meeting",
            startOffset:  60,
            attendees:    [
                makeAttendee(name: "Alice", email: "alice@x.com"),
                makeAttendee(name: "Bob",   email: "bob@x.com")
            ]
        )
        let rec = Recorder<(Notification.Name, [String: Any])>()
        let env = CalendarCaptureService.Environment.mock(
            eventBatches:        [[event]],
            postedNotifications: rec,
            currentDate:         { t0 },
            briefingCheckInterval: 0.001,
            briefingLeadTime:      120
        )
        let service = CalendarCaptureService(environment: env)
        try await service.start(delegate: MockCalendarDelegate())
        try await Task.sleep(nanoseconds: 50_000_000)
        service.stop()

        let emails = rec.values.first?.1[KerwanNotificationKey.attendeeEmails] as? [String]
        XCTAssertEqual(Set(emails ?? []), ["alice@x.com", "bob@x.com"])
    }

    func test_briefing_doesNotFireTwiceForSameEvent() async throws {
        let event = makeEventData(id: "once", startOffset: 60)
        let rec   = Recorder<(Notification.Name, [String: Any])>()
        let env   = CalendarCaptureService.Environment.mock(
            eventBatches:        [[event]],
            postedNotifications: rec,
            currentDate:         { t0 },
            briefingCheckInterval: 0.001,
            briefingLeadTime:      120
        )
        let service = CalendarCaptureService(environment: env)
        try await service.start(delegate: MockCalendarDelegate())
        try await Task.sleep(nanoseconds: 100_000_000)  // 100 ms — many briefing ticks
        service.stop()

        XCTAssertEqual(rec.values.count, 1, "Briefing must fire exactly once per event")
    }

    func test_briefing_doesNotFireForDistantEvent() async throws {
        // Event starts 600 s from t0 — outside 120 s lead time
        let event = makeEventData(id: "distant", startOffset: 600)
        let rec   = Recorder<(Notification.Name, [String: Any])>()
        let env   = CalendarCaptureService.Environment.mock(
            eventBatches:        [[event]],
            postedNotifications: rec,
            currentDate:         { t0 },
            briefingCheckInterval: 0.001,
            briefingLeadTime:      120
        )
        let service = CalendarCaptureService(environment: env)
        try await service.start(delegate: MockCalendarDelegate())
        try await Task.sleep(nanoseconds: 50_000_000)
        service.stop()

        XCTAssertTrue(rec.values.isEmpty, "No briefing for distant event")
    }

    func test_briefing_doesNotFireForPastEvent() async throws {
        // Event started 300 s before t0
        let event = makeEventData(id: "past", startOffset: -300)
        let rec   = Recorder<(Notification.Name, [String: Any])>()
        let env   = CalendarCaptureService.Environment.mock(
            eventBatches:        [[event]],
            postedNotifications: rec,
            currentDate:         { t0 },
            briefingCheckInterval: 0.001,
            briefingLeadTime:      120
        )
        let service = CalendarCaptureService(environment: env)
        try await service.start(delegate: MockCalendarDelegate())
        try await Task.sleep(nanoseconds: 50_000_000)
        service.stop()

        XCTAssertTrue(rec.values.isEmpty, "No briefing for past event")
    }

    func test_briefing_stopCancelsFurtherFiring() async throws {
        let event = makeEventData(id: "ev", startOffset: 60)
        let rec   = Recorder<(Notification.Name, [String: Any])>()
        let env   = CalendarCaptureService.Environment.mock(
            eventBatches:        [[event]],
            postedNotifications: rec,
            currentDate:         { t0 },
            briefingCheckInterval: 0.001,
            briefingLeadTime:      120
        )
        let service = CalendarCaptureService(environment: env)
        try await service.start(delegate: MockCalendarDelegate())
        try await Task.sleep(nanoseconds: 50_000_000)
        service.stop()

        let countAtStop = rec.values.count

        // Wait another 50 ms — no new notifications should arrive
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(rec.values.count, countAtStop, "No briefings after stop()")
    }

    func test_briefing_firesForMultipleDistinctEvents() async throws {
        let events = [
            makeEventData(id: "a", startOffset:  60),
            makeEventData(id: "b", startOffset:  90),
        ]
        let rec = Recorder<(Notification.Name, [String: Any])>()
        let env = CalendarCaptureService.Environment.mock(
            eventBatches:        [events],
            postedNotifications: rec,
            currentDate:         { t0 },
            briefingCheckInterval: 0.001,
            briefingLeadTime:      120
        )
        let service = CalendarCaptureService(environment: env)
        try await service.start(delegate: MockCalendarDelegate())
        try await Task.sleep(nanoseconds: 100_000_000)
        service.stop()

        XCTAssertEqual(rec.values.count, 2, "Each imminent event fires one briefing")
    }
}

// MARK: - CalendarUpcomingQueryTests

@MainActor
final class CalendarUpcomingQueryTests: XCTestCase {

    func test_getUpcomingEvents_returnsEventsWithinWindow() async throws {
        let events = [
            makeEventData(id: "in-5",   startOffset:  300),   //  5 min — inside 10-min window
            makeEventData(id: "in-9",   startOffset:  540),   //  9 min — inside
            makeEventData(id: "out-11", startOffset:  660),   // 11 min — outside
        ]
        let env     = CalendarCaptureService.Environment.mock(
            eventBatches: [events],
            currentDate:  { t0 }
        )
        let service = CalendarCaptureService(environment: env)
        try await service.start(delegate: MockCalendarDelegate())

        let upcoming = service.getUpcomingEvents(within: 10)
        service.stop()

        let ids = Set(upcoming.map(\.eventIdentifier))
        XCTAssertTrue(ids.contains("in-5"))
        XCTAssertTrue(ids.contains("in-9"))
        XCTAssertFalse(ids.contains("out-11"))
    }

    func test_getUpcomingEvents_excludesPastEvents() async throws {
        let events = [
            makeEventData(id: "past",   startOffset: -60),    // 1 min ago
            makeEventData(id: "future", startOffset:  60),    // 1 min from now
        ]
        let env     = CalendarCaptureService.Environment.mock(
            eventBatches: [events],
            currentDate:  { t0 }
        )
        let service = CalendarCaptureService(environment: env)
        try await service.start(delegate: MockCalendarDelegate())

        let upcoming = service.getUpcomingEvents(within: 10)
        service.stop()

        XCTAssertFalse(upcoming.contains { $0.eventIdentifier == "past" })
        XCTAssertTrue(upcoming.contains  { $0.eventIdentifier == "future" })
    }

    func test_getUpcomingEvents_emptyWhenNoEvents() async throws {
        let env     = CalendarCaptureService.Environment.mock(eventBatches: [[]])
        let service = CalendarCaptureService(environment: env)
        try await service.start(delegate: MockCalendarDelegate())

        let upcoming = service.getUpcomingEvents(within: 60)
        service.stop()

        XCTAssertTrue(upcoming.isEmpty)
    }

    func test_getUpcomingEvents_withinZeroMinutes_isEmpty() async throws {
        let events = [makeEventData(id: "e1", startOffset: 30)]
        let env    = CalendarCaptureService.Environment.mock(
            eventBatches: [events],
            currentDate:  { t0 }
        )
        let service = CalendarCaptureService(environment: env)
        try await service.start(delegate: MockCalendarDelegate())

        let upcoming = service.getUpcomingEvents(within: 0)
        service.stop()

        XCTAssertTrue(upcoming.isEmpty)
    }

    func test_getUpcomingEvents_attendees_preserved() async throws {
        let event = makeEventData(
            id:        "mtg",
            startOffset: 60,
            attendees: [
                makeAttendee(name: "Alice", email: "alice@x.com"),
                makeAttendee(name: "Bob",   email: nil)
            ]
        )
        let env     = CalendarCaptureService.Environment.mock(
            eventBatches: [[event]],
            currentDate:  { t0 }
        )
        let service = CalendarCaptureService(environment: env)
        try await service.start(delegate: MockCalendarDelegate())

        let upcoming = service.getUpcomingEvents(within: 5)
        service.stop()

        let attendees = upcoming.first?.attendees ?? []
        XCTAssertEqual(attendees.count, 2)
        XCTAssertTrue(attendees.contains { $0.name == "Alice" && $0.email == "alice@x.com" })
        XCTAssertTrue(attendees.contains { $0.name == "Bob"   && $0.email == nil           })
    }
}

// MARK: - XCTAssertThrowsErrorAsync (shared helper, mirrors the one used in Email tests)

// Note: If GmailOAuthManagerTests.swift already defines this function in the
// same test module, remove this copy to avoid a duplicate-declaration error.
// It is reproduced here so this file can compile stand-alone.
//
// func XCTAssertThrowsErrorAsync<T>(
//     _ expression: @autoclosure () async throws -> T,
//     _ message:    @autoclosure () -> String = "",
//     file:         StaticString = #filePath,
//     line:         UInt         = #line,
//     _ errorHandler: (Error) -> Void = { _ in }
// ) async {
//     do {
//         _ = try await expression()
//         XCTFail("Expected error but none was thrown. \(message())", file: file, line: line)
//     } catch {
//         errorHandler(error)
//     }
// }
