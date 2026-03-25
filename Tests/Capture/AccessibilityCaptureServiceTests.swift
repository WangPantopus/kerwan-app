// AccessibilityCaptureServiceTests.swift
// KerwanTests — Capture layer
//
// Unit tests for AccessibilityCaptureService.
//
// Test strategy
// ─────────────
// All system APIs are replaced via AccessibilityCaptureService.Environment:
//   • NSWorkspace / frontmostApplication  → closure returning nil or a canned value
//   • AX window-title query               → synchronous closure (no real AX calls)
//   • isProcessTrusted / requestTrust     → flags on the test harness
//   • ExclusionEngine                     → MockExclusionEngine
//   • minimumEventDuration = 0            → all events pass the duration gate in tests
//   • debounceInterval = 2.0              → default; overridden per-test where needed
//
// NSWorkspace notifications are tested via a dedicated NotificationCenter
// instance.  The notification handler extracts the NSRunningApplication from
// userInfo — for those tests we post with a MockRunningApplication subclass.
//
// Core business logic (handleActivation, pollTitleChange) is called directly,
// avoiding the need to fabricate notification-delivery timing.

import XCTest
import AppKit
@testable import Kerwan

// MARK: - Test doubles

// MARK: MockCaptureEventDelegate

/// Accumulates all events received from the service under test.
actor MockCaptureEventDelegate: CaptureEventDelegate {
    private(set) var allEvents: [RawEvent] = []
    private(set) var callCount: Int = 0

    func didCapture(_ events: [RawEvent]) async {
        allEvents.append(contentsOf: events)
        callCount += 1
    }

    func reset() {
        allEvents = []
        callCount = 0
    }
}

// MARK: MockExclusionEngine

final class MockExclusionEngine: ExclusionChecking, @unchecked Sendable {
    var blockedApps: Set<String> = []

    func shouldExclude(_ event: RawEvent) -> Bool {
        guard let app = event.sourceApp else { return false }
        return blockedApps.contains(app)
    }
}

// MARK: MockRunningApplication

/// Minimal NSRunningApplication subclass for notification-based integration tests.
///
/// Only `localizedName`, `bundleIdentifier`, and `processIdentifier` are
/// overridden — all other NSRunningApplication API remains unimplemented.
/// This is safe because the service only reads those three properties from
/// the notification's userInfo value.
final class MockRunningApplication: NSRunningApplication {
    private let _localizedName: String
    private let _bundleIdentifier: String
    private let _processIdentifier: pid_t

    init(name: String, bundleID: String, pid: pid_t) {
        _localizedName = name
        _bundleIdentifier = bundleID
        _processIdentifier = pid
        super.init()
    }

    override var localizedName: String? { _localizedName }
    override var bundleIdentifier: String? { _bundleIdentifier }
    override var processIdentifier: pid_t { _processIdentifier }
}

// MARK: - Test harness

@MainActor
final class AccessibilityCaptureServiceTests: XCTestCase {

    private var delegate: MockCaptureEventDelegate!
    private var exclusionEngine: MockExclusionEngine!
    private var testNC: NotificationCenter!

    // Controls what the injected AX query returns for any PID.
    nonisolated(unsafe) private var stubbedWindowTitle: String? = "Default Window"

    // Counter for verifying query invocation counts.
    nonisolated(unsafe) private var titleQueryCount = 0

    // Trust flags
    nonisolated(unsafe) private var isTrusted = true
    nonisolated(unsafe) private var trustRequested = false

    private var service: AccessibilityCaptureService!

    // MARK: setUp / tearDown

    override func setUp() async throws {
        try await super.setUp()
        delegate = MockCaptureEventDelegate()
        exclusionEngine = MockExclusionEngine()
        testNC = NotificationCenter()
        stubbedWindowTitle = "Default Window"
        titleQueryCount = 0
        isTrusted = true
        trustRequested = false
        service = makeService()
    }

    override func tearDown() async throws {
        await service.stop()
        service = nil
        delegate = nil
        exclusionEngine = nil
        testNC = nil
        try await super.tearDown()
    }

    // MARK: - Test environment factory

    private func makeService(
        minimumEventDuration: TimeInterval = 0,   // 0 → emit all events in tests
        debounceInterval: TimeInterval = 2.0
    ) -> AccessibilityCaptureService {
        let env = AccessibilityCaptureService.Environment(
            notificationCenter: testNC,
            frontmostApplication: { nil },
            queryWindowTitle: { [weak self] _ in
                guard let self else { return nil }
                self.titleQueryCount += 1
                return self.stubbedWindowTitle
            },
            isProcessTrusted: { [weak self] in self?.isTrusted ?? false },
            requestTrust: { [weak self] in
                self?.trustRequested = true
                return false
            },
            minimumEventDuration: minimumEventDuration,
            debounceInterval: debounceInterval,
            exclusionEngine: exclusionEngine
        )
        return AccessibilityCaptureService(delegate: delegate, environment: env)
    }

    // MARK: - Permission

    func testStartRequestsTrustWhenNotGranted() {
        isTrusted = false
        service.start()
        XCTAssertTrue(trustRequested)
    }

    func testStartDoesNotRequestTrustWhenAlreadyGranted() {
        isTrusted = true
        service.start()
        XCTAssertFalse(trustRequested)
    }

    func testDoubleStartIsNoop() {
        service.start()
        service.start()
        XCTAssertTrue(service.isRunning)
    }

    // MARK: - Basic event creation

    func testActivationCreatesAppFocusEvent() async throws {
        service.start()

        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")
        // Switching apps closes the first event.
        await service.handleActivation(appName: "Xcode", pid: 200, bundleID: "com.apple.dt.Xcode")

        let events = await delegate.allEvents
        XCTAssertEqual(events.count, 1)

        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.source, .appFocus)
        XCTAssertEqual(event.sourceApp, "Safari")
        XCTAssertNotNil(event.endedAt)
        XCTAssertNotNil(event.durationSeconds)
    }

    func testActivationMetadataContainsBundleIDAndTitle() async throws {
        stubbedWindowTitle = "Google — Safari"
        service.start()

        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")
        await service.handleActivation(appName: "Finder", pid: 201, bundleID: "com.apple.finder")

        let events = await delegate.allEvents
        let meta = try XCTUnwrap(
            events.first?
                .metadataJSON
                .flatMap { AppFocusMetadata.decode(from: $0) }
        )
        XCTAssertEqual(meta.bundleIdentifier, "com.apple.safari")
        XCTAssertEqual(meta.windowTitle, "Google — Safari")
        XCTAssertEqual(meta.pid, 100)
    }

    func testActivationWithNoWindowTitleStoresNil() async throws {
        stubbedWindowTitle = nil
        service.start()

        await service.handleActivation(appName: "Finder", pid: 201, bundleID: "com.apple.finder")
        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")

        let events2 = await delegate.allEvents
        let meta = try XCTUnwrap(
            events2.first?
                .metadataJSON
                .flatMap { AppFocusMetadata.decode(from: $0) }
        )
        XCTAssertNil(meta.windowTitle)
    }

    func testEventHasSourceAppSet() async throws {
        service.start()
        await service.handleActivation(appName: "Terminal", pid: 300, bundleID: "com.apple.Terminal")
        await service.handleActivation(appName: "Safari",   pid: 100, bundleID: "com.apple.safari")

        let events3 = await delegate.allEvents
        let event = try XCTUnwrap(events3.first)
        XCTAssertEqual(event.sourceApp, "Terminal")
    }

    // MARK: - Duplicate suppression

    func testDuplicateActivationForSameAppIsIgnored() async {
        service.start()
        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")
        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")

        // First event is still open (no second app switch), so nothing emitted yet.
        let count = await delegate.callCount
        XCTAssertEqual(count, 0)
    }

    // MARK: - Debounce

    func testBriefDetourIsDiscarded() async {
        // debounceInterval = 2s; all activations happen instantly so the
        // Xcode detour is always within the window.
        service.start()
        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")
        await service.handleActivation(appName: "Xcode",  pid: 200, bundleID: "com.apple.dt.Xcode")
        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")

        // Stop to flush the resumed Safari event.
        await service.stop()

        let events = await delegate.allEvents
        let xcodeEvents = events.filter { $0.sourceApp == "Xcode" }
        XCTAssertTrue(xcodeEvents.isEmpty, "Brief detour to Xcode must be discarded by debounce")
    }

    func testBriefDetourAllowsResumingApp() async {
        service.start()
        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")
        await service.handleActivation(appName: "Xcode",  pid: 200, bundleID: "com.apple.dt.Xcode")
        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")
        await service.stop()

        let safariEvents = (await delegate.allEvents).filter { $0.sourceApp == "Safari" }
        XCTAssertFalse(safariEvents.isEmpty, "Safari must have at least one recorded event after resuming")
    }

    func testNoBriefDetourWhenDebounceDisabled() async {
        // Use a 0-second debounce — every switch is "after" the window.
        service = makeService(debounceInterval: 0)
        service.start()

        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")
        await service.handleActivation(appName: "Xcode",  pid: 200, bundleID: "com.apple.dt.Xcode")
        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")
        await service.stop()

        let xcodeEvents = (await delegate.allEvents).filter { $0.sourceApp == "Xcode" }
        XCTAssertFalse(xcodeEvents.isEmpty, "With zero debounce, Xcode event should not be discarded")
    }

    // MARK: - Stop finalises open event

    func testStopFinalizesOpenEvent() async throws {
        service.start()
        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")
        await service.stop()

        let events = await delegate.allEvents
        XCTAssertEqual(events.count, 1)
        XCTAssertNotNil(try XCTUnwrap(events.first).endedAt)
    }

    func testStopIsIdempotent() async {
        service.start()
        await service.stop()
        await service.stop()  // must not crash or emit duplicate events

        XCTAssertFalse(service.isRunning)
    }

    func testStopWithNoOpenEventEmitsNothing() async {
        service.start()
        await service.stop()  // no activation happened

        let count = await delegate.callCount
        XCTAssertEqual(count, 0)
    }

    // MARK: - Window-title polling

    func testPollTitleChangeClosesCurrentEventAndOpensNew() async throws {
        service.start()
        stubbedWindowTitle = "Tab A — Safari"
        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")

        stubbedWindowTitle = "Tab B — Safari"
        await service.pollTitleChange()

        let events = await delegate.allEvents
        XCTAssertEqual(events.count, 1, "First Safari event must be emitted on title change")

        let emitted = try XCTUnwrap(events.first)
        XCTAssertEqual(emitted.sourceApp, "Safari")
        XCTAssertNotNil(emitted.endedAt)
        XCTAssertEqual(
            AppFocusMetadata.decode(from: emitted.metadataJSON ?? "")?.windowTitle,
            "Tab A — Safari",
            "Emitted event should carry the OLD title"
        )
    }

    func testPollNewTitleIsStoredInNextEvent() async throws {
        service.start()
        stubbedWindowTitle = "Tab A — Safari"
        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")

        stubbedWindowTitle = "Tab B — Safari"
        await service.pollTitleChange()

        // The NEW event (Tab B) is still open. Close it via stop().
        await service.stop()

        let events = await delegate.allEvents
        XCTAssertEqual(events.count, 2)

        let second = try XCTUnwrap(events.last)
        XCTAssertEqual(
            AppFocusMetadata.decode(from: second.metadataJSON ?? "")?.windowTitle,
            "Tab B — Safari"
        )
    }

    func testPollNoChangeDoesNotEmitEvent() async {
        stubbedWindowTitle = "Tab A"
        service.start()
        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")

        // Title unchanged
        await service.pollTitleChange()

        let count = await delegate.callCount
        XCTAssertEqual(count, 0)
    }

    func testPollNilToNilDoesNotEmitEvent() async {
        stubbedWindowTitle = nil
        service.start()
        await service.handleActivation(appName: "Finder", pid: 201, bundleID: "com.apple.finder")

        await service.pollTitleChange()

        let count = await delegate.callCount
        XCTAssertEqual(count, 0, "nil→nil must not produce a new event")
    }

    func testPollNilToNonNilEmitsEvent() async {
        stubbedWindowTitle = nil
        service.start()
        await service.handleActivation(appName: "Finder", pid: 201, bundleID: "com.apple.finder")

        stubbedWindowTitle = "Documents"
        await service.pollTitleChange()

        let count = await delegate.callCount
        XCTAssertEqual(count, 1, "nil→title transition must produce a new event")
    }

    func testPollWhenNotRunningDoesNothing() async {
        // Service was never started.
        await service.pollTitleChange()
        let count = await delegate.callCount
        XCTAssertEqual(count, 0)
    }

    func testPollInvokesAXQuery() async {
        service.start()
        stubbedWindowTitle = "Window 1"
        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")

        let countBefore = titleQueryCount
        await service.pollTitleChange()

        XCTAssertGreaterThan(titleQueryCount, countBefore, "Polling must invoke the AX query")
    }

    // MARK: - Exclusion engine

    func testExcludedAppEventIsNotDelivered() async {
        exclusionEngine.blockedApps = ["Notes"]
        service.start()

        await service.handleActivation(appName: "Notes",  pid: 400, bundleID: "com.apple.Notes")
        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")

        let events = await delegate.allEvents
        XCTAssertTrue(
            events.allSatisfy { $0.sourceApp != "Notes" },
            "Events from excluded apps must not reach the delegate"
        )
    }

    func testNonExcludedAppEventIsDelivered() async {
        exclusionEngine.blockedApps = ["Notes"]
        service.start()

        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")
        await service.handleActivation(appName: "Notes",  pid: 400, bundleID: "com.apple.Notes")

        let events = await delegate.allEvents
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.sourceApp, "Safari")
    }

    // MARK: - Minimum duration gate

    func testSubDurationEventsAreDropped() async throws {
        // Re-create the service with a 60-second minimum to prove ALL sub-60s events drop.
        service = makeService(minimumEventDuration: 60)
        service.start()

        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")
        await service.handleActivation(appName: "Xcode",  pid: 200, bundleID: "com.apple.dt.Xcode")
        await service.stop()

        // Both events are instantaneous in tests, well under 60 s.
        let count = await delegate.callCount
        XCTAssertEqual(count, 0, "All sub-60s events must be filtered when minimum is 60 s")
    }

    func testEventsAboveMinDurationAreEmitted() async throws {
        // minimumEventDuration = 0 (default for tests) → all pass through.
        service.start()
        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")
        await service.handleActivation(appName: "Xcode",  pid: 200, bundleID: "com.apple.dt.Xcode")

        let count = await delegate.callCount
        XCTAssertEqual(count, 1)
    }

    // MARK: - Metadata integrity

    func testEachEventHasUniqueID() async {
        service.start()
        stubbedWindowTitle = "Window A"
        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")

        stubbedWindowTitle = "Window B"
        await service.pollTitleChange()

        stubbedWindowTitle = "Window C"
        await service.pollTitleChange()

        await service.stop()

        let ids = (await delegate.allEvents).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "All emitted event IDs must be unique")
    }

    func testEventTimestampsAreChronological() async throws {
        service.start()
        await service.handleActivation(appName: "App A", pid: 1, bundleID: "com.a")
        try await Task.sleep(for: .milliseconds(5))
        await service.handleActivation(appName: "App B", pid: 2, bundleID: "com.b")
        try await Task.sleep(for: .milliseconds(5))
        await service.stop()

        let events = await delegate.allEvents
        for (e, next) in zip(events, events.dropFirst()) {
            XCTAssertLessThanOrEqual(e.startedAt, next.startedAt)
        }
    }

    func testEndedAtIsAfterStartedAt() async throws {
        service.start()
        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")
        try await Task.sleep(for: .milliseconds(5))
        await service.stop()

        let allEvts = await delegate.allEvents
        let event = try XCTUnwrap(allEvts.first)
        let endedAt = try XCTUnwrap(event.endedAt)
        XCTAssertGreaterThanOrEqual(endedAt, event.startedAt)
    }

    // MARK: - Notification-based integration

    func testNotificationPostingTriggersActivation() async throws {
        service.start()
        stubbedWindowTitle = "bash — Terminal"

        let mockApp = MockRunningApplication(
            name: "Terminal",
            bundleID: "com.apple.Terminal",
            pid: 999
        )
        testNC.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: mockApp]
        )

        // Allow the Task posted by the notification handler to execute.
        try await Task.sleep(for: .milliseconds(50))

        // Switch away to close the Terminal event.
        await service.handleActivation(appName: "Safari", pid: 100, bundleID: "com.apple.safari")
        await service.stop()

        let terminal = (await delegate.allEvents).filter { $0.sourceApp == "Terminal" }
        XCTAssertFalse(terminal.isEmpty, "Notification-driven activation must produce an event")
    }

    func testNotificationWithMissingUserInfoIsIgnored() async throws {
        service.start()

        // Post without userInfo — should not crash.
        testNC.post(name: NSWorkspace.didActivateApplicationNotification, object: nil, userInfo: nil)

        try await Task.sleep(for: .milliseconds(20))

        let count = await delegate.callCount
        XCTAssertEqual(count, 0)
    }

    // MARK: - RawEvent model

    func testRawEventClosedAtSetsEndedAt() throws {
        let start = Date(timeIntervalSinceNow: -10)
        let event = RawEvent(source: .appFocus, startedAt: start)
        let closed = event.closed(at: Date())
        XCTAssertNotNil(closed.endedAt)
        XCTAssertGreaterThanOrEqual(closed.durationSeconds ?? 0, 9.9)
    }

    func testRawEventOpenEventHasNilDuration() {
        let event = RawEvent(source: .appFocus)
        XCTAssertNil(event.durationSeconds)
    }

    func testRawEventWithMetadataReplacesJSON() {
        let event = RawEvent(source: .appFocus, metadataJSON: "old")
        let updated = event.withMetadata("new")
        XCTAssertEqual(updated.metadataJSON, "new")
        XCTAssertEqual(event.metadataJSON, "old")  // original unchanged
    }

    func testAppFocusMetadataRoundTrip() throws {
        let original = AppFocusMetadata(
            bundleIdentifier: "com.apple.safari",
            windowTitle: "Hello — Safari",
            pid: 42
        )
        let json = try XCTUnwrap(original.jsonString)
        let decoded = try XCTUnwrap(AppFocusMetadata.decode(from: json))
        XCTAssertEqual(decoded.bundleIdentifier, original.bundleIdentifier)
        XCTAssertEqual(decoded.windowTitle, original.windowTitle)
        XCTAssertEqual(decoded.pid, original.pid)
    }

    func testAppFocusMetadataNilTitleRoundTrip() throws {
        let meta = AppFocusMetadata(
            bundleIdentifier: "com.apple.finder",
            windowTitle: nil,
            pid: 201
        )
        let json = try XCTUnwrap(meta.jsonString)
        let decoded = try XCTUnwrap(AppFocusMetadata.decode(from: json))
        XCTAssertNil(decoded.windowTitle)
    }

    func testAppFocusMetadataDecodeReturnsNilForGarbage() {
        XCTAssertNil(AppFocusMetadata.decode(from: "not json"))
        XCTAssertNil(AppFocusMetadata.decode(from: ""))
    }

    // MARK: - Exclusion protocol conformers

    func testPassthroughExclusionEngineAllowsAll() {
        let engine = PassthroughExclusionEngine()
        XCTAssertFalse(engine.shouldExclude(RawEvent(source: .appFocus, sourceApp: "Anything")))
        XCTAssertFalse(engine.shouldExclude(RawEvent(source: .slack)))
    }

    func testMockExclusionEngineBlocksCorrectly() {
        exclusionEngine.blockedApps = ["Blocked"]
        XCTAssertTrue(exclusionEngine.shouldExclude(RawEvent(source: .appFocus, sourceApp: "Blocked")))
        XCTAssertFalse(exclusionEngine.shouldExclude(RawEvent(source: .appFocus, sourceApp: "Allowed")))
        XCTAssertFalse(exclusionEngine.shouldExclude(RawEvent(source: .appFocus, sourceApp: nil)))
    }

    // MARK: - CaptureSource

    func testCaptureSourceRawValues() {
        XCTAssertEqual(CaptureSource.appFocus.rawValue, "appFocus")
        XCTAssertEqual(CaptureSource.slack.rawValue, "slack")
    }

    func testCaptureSourceCaseIterable() {
        XCTAssertTrue(CaptureSource.allCases.contains(.appFocus))
        XCTAssertTrue(CaptureSource.allCases.contains(.slack))
    }
}
