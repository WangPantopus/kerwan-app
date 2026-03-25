// CaptureManagerTests.swift
// Kerwan — CaptureManager integration tests
//
// These tests wire together mock implementations of every service and verify
// that events flow correctly through the full capture → exclusion → storage
// pipeline.  No real audio hardware, EventKit, IMAP, or Accessibility calls
// are made.
//
// Test groups
// ───────────
//  RawEventBufferTests          — exclusion filter, storage write, event count
//  CaptureManagerLifecycleTests — startAll, pauseAll, resumeAll, stopAll
//  PrivateModeTests             — enter/exit private mode, status transitions
//  BatteryAwarenessTests        — low power and thermal notifications
//  ErrorRecoveryTests           — failed services are retried after recoveryInterval
//  EventPipelineIntegrationTests— end-to-end: mock service → buffer → storage

import XCTest
@testable import Kerwan

// MARK: - Mock AppState

actor MockAppState: AppStateManaging {
    private(set) var statusHistory:   [CaptureStatus] = []
    private(set) var eventsToday:     Int             = 0
    private(set) var resetCount:      Int             = 0

    func setCaptureStatus(_ status: CaptureStatus) async {
        statusHistory.append(status)
    }
    func incrementEventsToday(by count: Int) async {
        eventsToday += count
    }
    func resetEventsToday() async {
        eventsToday = 0
        resetCount += 1
    }

    var lastStatus: CaptureStatus? { statusHistory.last }
}

// MARK: - Mock Storage

actor MockStorage: StorageManaging {
    private(set) var savedEvents: [RawEvent] = []
    private var shouldThrow: Bool

    init(shouldThrow: Bool = false) { self.shouldThrow = shouldThrow }

    func setShouldThrow(_ value: Bool) { shouldThrow = value }

    func saveRawEvent(_ event: RawEvent) async throws {
        if shouldThrow { throw StorageError.fake }
        savedEvents.append(event)
    }

    enum StorageError: Error { case fake }
}

// MARK: - Mock accessibility service

@MainActor
final class MockAccessibilityService: AccessibilityCapturing {
    private(set) var startCallCount = 0
    private(set) var stopCallCount  = 0
    var isRunning = false

    func start() { startCallCount += 1; isRunning = true }
    func stop() async { stopCallCount += 1; isRunning = false }
}

// MARK: - Mock audio service

@MainActor
final class MockAudioService: AudioCapturing {
    private(set) var startCount  = 0
    private(set) var pauseCount  = 0
    private(set) var resumeCount = 0
    private(set) var stopCount   = 0
    var throwOnStart = false

    func startCapture() async throws {
        if throwOnStart { throw MockAudioError.boom }
        startCount += 1
    }
    func pauseCapture()         { pauseCount += 1 }
    func resumeCapture() throws { resumeCount += 1 }
    func stopCapture() async    { stopCount += 1 }

    enum MockAudioError: Error { case boom }
}

// MARK: - Mock calendar service

@MainActor
final class MockCalendarService: CalendarCapturing {
    private(set) var startCallCount = 0
    private(set) var stopCallCount  = 0
    var throwOnStart: Error? = nil
    var isRunning = false

    func start(delegate: any CaptureEventDelegate) async throws {
        if let err = throwOnStart { throw err }
        startCallCount += 1; isRunning = true
    }
    func stop() { stopCallCount += 1; isRunning = false }

    struct MockCalendarError: Error {}
}

// MARK: - Mock email service (wraps EmailCaptureService via actor)

// EmailCaptureService is a concrete actor. We can't easily subclass it, so
// for these tests we use a thin wrapper actor instead of an injected mock.
// The EventPipelineIntegrationTests below call the buffer directly.

// MARK: - Mock exclusion engine

final class CMockExclusionEngine: ExclusionChecking, @unchecked Sendable {
    var blockedSources: Set<CaptureSource> = []
    func shouldExclude(_ event: RawEvent) -> Bool {
        blockedSources.contains(event.source)
    }
}

// MARK: - Mock WhisperTranscribing

actor MockWhisperClient: WhisperTranscribing {
    func loadModel(atPath path: String) async throws {}
    func transcribe(audioData: Data, sampleRate: Int) async throws -> [TranscriptSegment] { [] }
    func isModelLoaded() async throws -> Bool { false }
    func unloadModel() async throws {}
}

// MARK: - Helpers

private func makeRawEvent(source: CaptureSource = .calendar) -> RawEvent {
    RawEvent(source: source, sourceApp: "Test", startedAt: Date(), endedAt: Date())
}

// MARK: - Environment factory for tests

extension CaptureManager.Environment {

    /// Builds a test environment with all services replaced by controllable mocks.
    @MainActor
    static func mock(
        axService:      MockAccessibilityService? = nil,
        micService:     MockAudioService?         = nil,
        sysService:     MockAudioService?         = nil,
        calService:     MockCalendarService?      = nil,
        emailService:   EmailCaptureService?      = nil,
        gmailAccount:   GmailAccount?             = nil,
        powerMode:      @escaping @Sendable () -> Bool                       = { false },
        thermalState:   @escaping @Sendable () -> ProcessInfo.ThermalState   = { .nominal },
        nc:             NotificationCenter                                    = NotificationCenter(),
        currentDate:    @escaping @Sendable () -> Date                        = { Date() },
        recoveryInterval: TimeInterval                                        = 300
    ) -> CaptureManager.Environment {

        let axSvc  = axService  ?? MockAccessibilityService()
        let micSvc = micService ?? MockAudioService()
        let sysSvc = sysService ?? MockAudioService()
        let calSvc = calService ?? MockCalendarService()

        let whisper      = MockWhisperClient()
        let appState     = MockAppState()
        let storage      = MockStorage()
        let buffer       = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         storage,
            appState:        appState
        )
        let transcription = TranscriptionActor(
            whisperClient:         whisper,
            eventDelegate:         buffer,
            classificationDelegate: nil
        )
        let mixer    = AudioMixer(delegate: transcription)
        let micAdapt = MicAudioMixerAdapter(mixer: mixer)
        let sysAdapt = SysAudioMixerAdapter(mixer: mixer)

        return CaptureManager.Environment(
            accessibilityService: axSvc,
            microphoneService:    micSvc,
            systemAudioService:   sysSvc,
            emailService:         emailService,
            gmailAccount:         gmailAccount,
            calendarService:      calSvc,
            audioMixer:           mixer,
            transcriptionActor:   transcription,
            micMixerAdapter:      micAdapt,
            sysMixerAdapter:      sysAdapt,
            isLowPowerMode:       powerMode,
            thermalState:         thermalState,
            notificationCenter:   nc,
            currentDate:          currentDate,
            recoveryInterval:     recoveryInterval
        )
    }
}

// MARK: - RawEventBufferTests

final class RawEventBufferTests: XCTestCase {

    func test_didCapture_storesNonExcludedEvents() async throws {
        let storage  = MockStorage()
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         storage,
            appState:        appState
        )

        let events = [makeRawEvent(), makeRawEvent()]
        await buffer.didCapture(events)
        try await Task.sleep(nanoseconds: 30_000_000)  // let background task run

        let saved = await storage.savedEvents
        XCTAssertEqual(saved.count, 2)
    }

    func test_didCapture_incrementsEventCount() async {
        let storage  = MockStorage()
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         storage,
            appState:        appState
        )

        await buffer.didCapture([makeRawEvent(), makeRawEvent(), makeRawEvent()])
        let today = await appState.eventsToday
        XCTAssertEqual(today, 3)
    }

    func test_didCapture_exclusionEngineFiltersEvents() async throws {
        let engine   = CMockExclusionEngine()
        engine.blockedSources = [.audio]
        let storage  = MockStorage()
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: engine,
            storage:         storage,
            appState:        appState
        )

        await buffer.didCapture([
            makeRawEvent(source: .audio),     // blocked
            makeRawEvent(source: .calendar),  // allowed
            makeRawEvent(source: .audio),     // blocked
        ])
        try await Task.sleep(nanoseconds: 30_000_000)

        let saved = await storage.savedEvents
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.source, .calendar)
    }

    func test_didCapture_excludedEventsNotCounted() async {
        let engine   = CMockExclusionEngine()
        engine.blockedSources = [.audio]
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: engine,
            storage:         MockStorage(),
            appState:        appState
        )

        await buffer.didCapture([
            makeRawEvent(source: .audio),
            makeRawEvent(source: .calendar),
        ])

        let today = await appState.eventsToday
        XCTAssertEqual(today, 1)
    }

    func test_didCapture_allExcluded_doesNotCallStorage() async throws {
        let engine   = CMockExclusionEngine()
        engine.blockedSources = [.audio, .calendar]
        let storage  = MockStorage()
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: engine,
            storage:         storage,
            appState:        appState
        )

        await buffer.didCapture([
            makeRawEvent(source: .audio),
            makeRawEvent(source: .calendar),
        ])
        try await Task.sleep(nanoseconds: 30_000_000)

        let saved = await storage.savedEvents
        XCTAssertTrue(saved.isEmpty)
    }

    func test_didCapture_storageFailure_doesNotPropagate() async {
        let storage  = MockStorage(shouldThrow: true)
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         storage,
            appState:        appState
        )
        // Should not throw — fire-and-forget storage
        await buffer.didCapture([makeRawEvent()])
        try? await Task.sleep(nanoseconds: 30_000_000)
        // Test passes if no crash occurs; storage failure is swallowed silently
    }

    func test_didCapture_emptyEvents_noSideEffects() async throws {
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         MockStorage(),
            appState:        appState
        )
        await buffer.didCapture([])
        let today = await appState.eventsToday
        XCTAssertEqual(today, 0)
    }

    func test_totalAcceptedCount_tracked() async {
        let buffer = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         MockStorage(),
            appState:        MockAppState()
        )
        await buffer.didCapture([makeRawEvent(), makeRawEvent()])
        await buffer.didCapture([makeRawEvent()])
        let total = await buffer.totalAcceptedCount
        XCTAssertEqual(total, 3)
    }

    func test_totalExcludedCount_tracked() async {
        let engine = CMockExclusionEngine()
        engine.blockedSources = [.audio]
        let buffer = RawEventBuffer(
            exclusionEngine: engine,
            storage:         MockStorage(),
            appState:        MockAppState()
        )
        await buffer.didCapture([
            makeRawEvent(source: .audio),
            makeRawEvent(source: .audio),
            makeRawEvent(source: .calendar),
        ])
        let excl = await buffer.totalExcludedCount
        XCTAssertEqual(excl, 2)
    }
}

// MARK: - CaptureManagerLifecycleTests

@MainActor
final class CaptureManagerLifecycleTests: XCTestCase {

    func test_startAll_startsAllEnabledServices() async throws {
        let ax   = MockAccessibilityService()
        let mic  = MockAudioService()
        let sys  = MockAudioService()
        let cal  = MockCalendarService()
        let appState = MockAppState()
        let storage  = MockStorage()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         storage,
            appState:        appState
        )
        let env = CaptureManager.Environment.mock(
            axService: ax, micService: mic, sysService: sys, calService: cal
        )
        let manager = CaptureManager(rawEventBuffer: buffer, appState: appState, environment: env)

        await manager.startAll()

        XCTAssertEqual(ax.startCallCount,   1)
        XCTAssertEqual(mic.startCount,      1)
        XCTAssertEqual(sys.startCount,      1)
        XCTAssertEqual(cal.startCallCount,  1)

        await manager.stopAll()
    }

    func test_startAll_setsRunningStatus() async throws {
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         MockStorage(),
            appState:        appState
        )
        let env     = CaptureManager.Environment.mock()
        let manager = CaptureManager(rawEventBuffer: buffer, appState: appState, environment: env)

        await manager.startAll()

        let status = await appState.lastStatus
        XCTAssertEqual(status, .running)

        await manager.stopAll()
    }

    func test_startAll_failingMicrophoneDoesNotBlockOtherServices() async throws {
        let mic = MockAudioService(); mic.throwOnStart = true
        let ax  = MockAccessibilityService()
        let cal = MockCalendarService()
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         MockStorage(),
            appState:        appState
        )
        let env     = CaptureManager.Environment.mock(axService: ax, micService: mic, calService: cal)
        let manager = CaptureManager(rawEventBuffer: buffer, appState: appState, environment: env)

        await manager.startAll()

        XCTAssertEqual(ax.startCallCount,  1, "AX should start despite mic failure")
        XCTAssertEqual(cal.startCallCount, 1, "Calendar should start despite mic failure")
        let snapshot = await manager.serviceStatus
        if case .failed = snapshot.microphone {} else {
            XCTFail("Microphone should be in .failed state")
        }

        await manager.stopAll()
    }

    func test_stopAll_stopsAllServices() async throws {
        let ax  = MockAccessibilityService()
        let mic = MockAudioService()
        let sys = MockAudioService()
        let cal = MockCalendarService()
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         MockStorage(),
            appState:        appState
        )
        let env     = CaptureManager.Environment.mock(
            axService: ax, micService: mic, sysService: sys, calService: cal
        )
        let manager = CaptureManager(rawEventBuffer: buffer, appState: appState, environment: env)

        await manager.startAll()
        await manager.stopAll()

        XCTAssertEqual(ax.stopCallCount,  1)
        XCTAssertEqual(mic.stopCount,     1)
        XCTAssertEqual(sys.stopCount,     1)
        XCTAssertEqual(cal.stopCallCount, 1)
    }

    func test_stopAll_setsIdleStatus() async throws {
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         MockStorage(),
            appState:        appState
        )
        let env     = CaptureManager.Environment.mock()
        let manager = CaptureManager(rawEventBuffer: buffer, appState: appState, environment: env)

        await manager.startAll()
        await manager.stopAll()

        let status = await appState.lastStatus
        XCTAssertEqual(status, .idle)
    }

    func test_pauseAll_pausesAudioServices() async throws {
        let mic = MockAudioService()
        let sys = MockAudioService()
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         MockStorage(),
            appState:        appState
        )
        let env     = CaptureManager.Environment.mock(micService: mic, sysService: sys)
        let manager = CaptureManager(rawEventBuffer: buffer, appState: appState, environment: env)

        await manager.startAll()
        await manager.pauseAll()

        XCTAssertEqual(mic.pauseCount, 1)
        XCTAssertEqual(sys.pauseCount, 1)

        let status = await appState.lastStatus
        XCTAssertEqual(status, .paused)

        await manager.stopAll()
    }

    func test_pauseAll_stopsAccessibilityService() async throws {
        let ax = MockAccessibilityService()
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         MockStorage(),
            appState:        appState
        )
        let env     = CaptureManager.Environment.mock(axService: ax)
        let manager = CaptureManager(rawEventBuffer: buffer, appState: appState, environment: env)

        await manager.startAll()
        await manager.pauseAll()

        // AX has no pause — stop() is called
        XCTAssertGreaterThanOrEqual(ax.stopCallCount, 1)
        await manager.stopAll()
    }

    func test_resumeAll_resumesAudioServices() async throws {
        let mic = MockAudioService()
        let sys = MockAudioService()
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         MockStorage(),
            appState:        appState
        )
        let env     = CaptureManager.Environment.mock(micService: mic, sysService: sys)
        let manager = CaptureManager(rawEventBuffer: buffer, appState: appState, environment: env)

        await manager.startAll()
        await manager.pauseAll()
        await manager.resumeAll()

        XCTAssertEqual(mic.resumeCount, 1)
        XCTAssertEqual(sys.resumeCount, 1)

        let status = await appState.lastStatus
        XCTAssertEqual(status, .running)

        await manager.stopAll()
    }

    func test_disabledServices_areNilInEnvironment() async throws {
        // When all services are nil, startAll runs without crashing
        let whisper = MockWhisperClient()
        let appState = MockAppState()
        let storage  = MockStorage()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         storage,
            appState:        appState
        )
        let transcription = TranscriptionActor(
            whisperClient:         whisper,
            eventDelegate:         buffer,
            classificationDelegate: nil
        )
        let mixer    = AudioMixer(delegate: transcription)
        let micAdapt = MicAudioMixerAdapter(mixer: mixer)
        let sysAdapt = SysAudioMixerAdapter(mixer: mixer)

        let env = CaptureManager.Environment(
            accessibilityService: nil,
            microphoneService:    nil,
            systemAudioService:   nil,
            emailService:         nil,
            gmailAccount:         nil,
            calendarService:      nil,
            audioMixer:           mixer,
            transcriptionActor:   transcription,
            micMixerAdapter:      micAdapt,
            sysMixerAdapter:      sysAdapt,
            isLowPowerMode:       { false },
            thermalState:         { .nominal },
            notificationCenter:   NotificationCenter(),
            currentDate:          { Date() },
            recoveryInterval:     300
        )
        let manager = CaptureManager(rawEventBuffer: buffer, appState: appState, environment: env)

        await manager.startAll()
        let snapshot = await manager.serviceStatus
        XCTAssertEqual(snapshot.accessibility, .disabled)
        XCTAssertEqual(snapshot.microphone,    .disabled)
        XCTAssertEqual(snapshot.calendar,      .disabled)
        await manager.stopAll()
    }
}

// MARK: - PrivateModeTests

@MainActor
final class PrivateModeTests: XCTestCase {

    func test_enterPrivateMode_pausesServices() async throws {
        let mic  = MockAudioService()
        let sys  = MockAudioService()
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         MockStorage(),
            appState:        appState
        )
        let env     = CaptureManager.Environment.mock(micService: mic, sysService: sys)
        let manager = CaptureManager(rawEventBuffer: buffer, appState: appState, environment: env)

        await manager.startAll()
        await manager.enterPrivateMode()

        XCTAssertEqual(mic.pauseCount, 1)
        XCTAssertEqual(sys.pauseCount, 1)
        let status = await appState.lastStatus
        XCTAssertEqual(status, .privateMode)

        await manager.stopAll()
    }

    func test_exitPrivateMode_resumesServices() async throws {
        let mic  = MockAudioService()
        let sys  = MockAudioService()
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         MockStorage(),
            appState:        appState
        )
        let env     = CaptureManager.Environment.mock(micService: mic, sysService: sys)
        let manager = CaptureManager(rawEventBuffer: buffer, appState: appState, environment: env)

        await manager.startAll()
        await manager.enterPrivateMode()
        await manager.exitPrivateMode()

        XCTAssertEqual(mic.resumeCount, 1)
        XCTAssertEqual(sys.resumeCount, 1)
        let status = await appState.lastStatus
        XCTAssertEqual(status, .running)

        await manager.stopAll()
    }

    func test_doubleEnterPrivateMode_isNoOp() async throws {
        let mic  = MockAudioService()
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         MockStorage(),
            appState:        appState
        )
        let env     = CaptureManager.Environment.mock(micService: mic)
        let manager = CaptureManager(rawEventBuffer: buffer, appState: appState, environment: env)

        await manager.startAll()
        await manager.enterPrivateMode()
        await manager.enterPrivateMode()  // no-op

        XCTAssertEqual(mic.pauseCount, 1, "Pause called only once")
        await manager.stopAll()
    }
}

// MARK: - BatteryAwarenessTests

@MainActor
final class BatteryAwarenessTests: XCTestCase {

    func test_lowPower_pausesAudioServices() async throws {
        var lowPower = false
        let mic  = MockAudioService()
        let sys  = MockAudioService()
        let nc   = NotificationCenter()
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         MockStorage(),
            appState:        appState
        )
        let env = CaptureManager.Environment.mock(
            micService:  mic,
            sysService:  sys,
            powerMode:   { lowPower },
            nc:          nc
        )
        let manager = CaptureManager(rawEventBuffer: buffer, appState: appState, environment: env)

        await manager.startAll()
        lowPower = true
        nc.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        try await Task.sleep(nanoseconds: 40_000_000)  // let observer task run

        XCTAssertEqual(mic.pauseCount, 1, "Mic should pause on low power")
        XCTAssertEqual(sys.pauseCount, 1, "System audio should pause on low power")

        await manager.stopAll()
    }

    func test_thermalSerious_pausesAudioServices() async throws {
        var state = ProcessInfo.ThermalState.nominal
        let mic  = MockAudioService()
        let sys  = MockAudioService()
        let nc   = NotificationCenter()
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         MockStorage(),
            appState:        appState
        )
        let env = CaptureManager.Environment.mock(
            micService:    mic,
            sysService:    sys,
            thermalState:  { state },
            nc:            nc
        )
        let manager = CaptureManager(rawEventBuffer: buffer, appState: appState, environment: env)

        await manager.startAll()
        state = .serious
        nc.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        try await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(mic.pauseCount, 1, "Mic should pause on thermal serious")
        XCTAssertEqual(sys.pauseCount, 1)

        await manager.stopAll()
    }

    func test_powerRestored_resumesAudioServices() async throws {
        var lowPower = false
        let mic  = MockAudioService()
        let sys  = MockAudioService()
        let nc   = NotificationCenter()
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         MockStorage(),
            appState:        appState
        )
        let env = CaptureManager.Environment.mock(
            micService: mic, sysService: sys,
            powerMode:  { lowPower }, nc: nc
        )
        let manager = CaptureManager(rawEventBuffer: buffer, appState: appState, environment: env)

        await manager.startAll()

        lowPower = true
        nc.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        try await Task.sleep(nanoseconds: 40_000_000)

        lowPower = false
        nc.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        try await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(mic.resumeCount, 1, "Mic should resume when power is restored")
        XCTAssertEqual(sys.resumeCount, 1)

        await manager.stopAll()
    }

    func test_powerStateToggle_doesNotDoubleApply() async throws {
        var lowPower = false
        let mic  = MockAudioService()
        let nc   = NotificationCenter()
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         MockStorage(),
            appState:        appState
        )
        let env = CaptureManager.Environment.mock(
            micService: mic, powerMode: { lowPower }, nc: nc
        )
        let manager = CaptureManager(rawEventBuffer: buffer, appState: appState, environment: env)

        await manager.startAll()

        lowPower = true
        nc.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        nc.post(name: .NSProcessInfoPowerStateDidChange, object: nil)  // duplicate
        try await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(mic.pauseCount, 1, "Duplicate notifications must not double-pause")
        await manager.stopAll()
    }
}

// MARK: - ErrorRecoveryTests

@MainActor
final class ErrorRecoveryTests: XCTestCase {

    func test_failedService_markedInServiceStatus() async throws {
        let mic = MockAudioService(); mic.throwOnStart = true
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         MockStorage(),
            appState:        appState
        )
        let env     = CaptureManager.Environment.mock(micService: mic)
        let manager = CaptureManager(rawEventBuffer: buffer, appState: appState, environment: env)

        await manager.startAll()
        let snapshot = await manager.serviceStatus
        if case .failed = snapshot.microphone {} else {
            XCTFail("Expected .failed for mic")
        }
        await manager.stopAll()
    }

    func test_failedService_degradedCaptureStatus() async throws {
        let mic = MockAudioService(); mic.throwOnStart = true
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         MockStorage(),
            appState:        appState
        )
        let env     = CaptureManager.Environment.mock(micService: mic)
        let manager = CaptureManager(rawEventBuffer: buffer, appState: appState, environment: env)

        await manager.startAll()
        let status = await appState.lastStatus
        if case .degraded(let names) = status {
            XCTAssertTrue(names.contains("Microphone"))
        } else {
            XCTFail("Expected .degraded status, got \(String(describing: status))")
        }
        await manager.stopAll()
    }

    func test_recoveryLoop_retriesFailedService() async throws {
        let mic  = MockAudioService(); mic.throwOnStart = true
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         MockStorage(),
            appState:        appState
        )
        let env = CaptureManager.Environment.mock(
            micService:       mic,
            recoveryInterval: 0.01   // 10 ms — fires quickly in tests
        )
        let manager = CaptureManager(rawEventBuffer: buffer, appState: appState, environment: env)

        await manager.startAll()
        // After first start, mic fails.  Clear the throw flag so next retry succeeds.
        mic.throwOnStart = false

        try await Task.sleep(nanoseconds: 80_000_000)  // > 2× recovery interval

        let snapshot = await manager.serviceStatus
        XCTAssertEqual(snapshot.microphone, .running,
                       "Recovery loop should have restarted the mic service")

        await manager.stopAll()
    }
}

// MARK: - MidnightResetTests

@MainActor
final class MidnightResetTests: XCTestCase {

    func test_midnightTask_resetsEventCount() async throws {
        // Use a current date just before "midnight" so the calculated sleep
        // is very short.  We place "now" as 1 second before midnight.
        let calendar = Calendar.current
        var comps    = calendar.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 23; comps.minute = 59; comps.second = 59
        let almostMidnight = calendar.date(from: comps) ?? Date()
        var callCount = 0
        let dateProvider: @Sendable () -> Date = {
            callCount += 1
            return callCount == 1 ? almostMidnight : Date()
        }

        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         MockStorage(),
            appState:        appState
        )
        let env     = CaptureManager.Environment.mock(currentDate: dateProvider)
        let manager = CaptureManager(rawEventBuffer: buffer, appState: appState, environment: env)

        await manager.startAll()
        try await Task.sleep(nanoseconds: 2_500_000_000)  // wait past midnight

        let resets = await appState.resetCount
        XCTAssertGreaterThanOrEqual(resets, 1, "Midnight reset should have fired")

        await manager.stopAll()
    }
}

// MARK: - EventPipelineIntegrationTests

/// End-to-end: verify events emitted by a mock service arrive in storage.
@MainActor
final class EventPipelineIntegrationTests: XCTestCase {

    func test_calendarEvent_flowsToStorage() async throws {
        let storage  = MockStorage()
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         storage,
            appState:        appState
        )

        // Simulate CalendarCaptureService emitting an event
        let event = RawEvent(
            source:       .calendar,
            sourceApp:    "Calendar",
            startedAt:    Date(),
            endedAt:      Date().addingTimeInterval(3600)
        )
        await buffer.didCapture([event])
        try await Task.sleep(nanoseconds: 30_000_000)

        let saved = await storage.savedEvents
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.source, .calendar)
    }

    func test_emailEvent_flowsToStorage() async throws {
        let storage  = MockStorage()
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         storage,
            appState:        appState
        )

        let event = RawEvent(source: .email, sourceApp: "Gmail", startedAt: Date())
        await buffer.didCapture([event])
        try await Task.sleep(nanoseconds: 30_000_000)

        let saved = await storage.savedEvents
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.source, .email)
    }

    func test_multipleServices_eventsAggregated() async throws {
        let storage  = MockStorage()
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         storage,
            appState:        appState
        )

        // Simulate different services emitting concurrently
        async let a: () = buffer.didCapture([makeRawEvent(source: .calendar)])
        async let b: () = buffer.didCapture([makeRawEvent(source: .email)])
        async let c: () = buffer.didCapture([makeRawEvent(source: .appFocus)])
        _ = await (a, b, c)
        try await Task.sleep(nanoseconds: 50_000_000)

        let saved = await storage.savedEvents
        XCTAssertEqual(saved.count, 3)
        let sources = Set(saved.map(\.source))
        XCTAssertEqual(sources, [.calendar, .email, .appFocus])
    }

    func test_exclusionEngine_blocksSensitiveSource() async throws {
        let engine   = CMockExclusionEngine()
        engine.blockedSources = [.screenCapture]
        let storage  = MockStorage()
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: engine,
            storage:         storage,
            appState:        appState
        )

        await buffer.didCapture([
            makeRawEvent(source: .screenCapture),  // blocked
            makeRawEvent(source: .calendar),       // allowed
        ])
        try await Task.sleep(nanoseconds: 30_000_000)

        let saved = await storage.savedEvents
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.source, .calendar)
    }

    func test_eventCount_incrementedAcrossMultipleBatches() async {
        let appState = MockAppState()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         MockStorage(),
            appState:        appState
        )

        for _ in 0..<5 {
            await buffer.didCapture([makeRawEvent(), makeRawEvent()])
        }

        let today = await appState.eventsToday
        XCTAssertEqual(today, 10)
    }

    func test_startAll_captureManagerWiresMockServices() async throws {
        let ax  = MockAccessibilityService()
        let cal = MockCalendarService()
        let appState = MockAppState()
        let storage  = MockStorage()
        let buffer   = RawEventBuffer(
            exclusionEngine: PassthroughExclusionEngine(),
            storage:         storage,
            appState:        appState
        )
        let env     = CaptureManager.Environment.mock(axService: ax, calService: cal)
        let manager = CaptureManager(rawEventBuffer: buffer, appState: appState, environment: env)

        await manager.startAll()

        XCTAssertTrue(ax.isRunning)
        XCTAssertTrue(cal.isRunning)

        // Emit an event through the buffer (simulating what the services would do)
        await buffer.didCapture([makeRawEvent(source: .calendar)])
        try await Task.sleep(nanoseconds: 30_000_000)

        let saved = await storage.savedEvents
        XCTAssertEqual(saved.count, 1)

        await manager.stopAll()
    }
}
