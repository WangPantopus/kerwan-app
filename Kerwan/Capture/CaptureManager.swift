// CaptureManager.swift
// Kerwan — Capture layer
//
// Central coordinator that owns and manages all capture services.
//
// Architecture
// ────────────
//
//   Capture services
//   ┌──────────────────────────────────────────────────────────┐
//   │ AccessibilityCaptureService ──────────────────────────►  │
//   │ EmailCaptureService         ──────────────────────────►  │
//   │ CalendarCaptureService      ──────────────────────────►  │ RawEventBuffer
//   │ MicrophoneCaptureService ──► MicAudioMixerAdapter ────►  │
//   │ SystemAudioCaptureService ─► SysAudioMixerAdapter ─►     │
//   │                             AudioMixer ──► TranscriptionActor ──► RawEventBuffer
//   └──────────────────────────────────────────────────────────┘
//
//   RawEventBuffer ──► ExclusionEngine check
//                  ──► StorageActor (fire-and-forget)
//                  ──► AppState.incrementEventsToday
//
// Threading
// ─────────
//   CaptureManager is an actor; all public methods are async.
//   @MainActor services (AccessibilityCaptureService, MicrophoneCaptureService,
//   SystemAudioCaptureService, CalendarCaptureService) are stored as opaque
//   `any AccessibilityCapturing` / `any AudioCapturing` / `any CalendarCapturing`
//   protocol existentials.  Calling their @MainActor methods from inside the
//   actor automatically hops to the main actor via Swift's concurrency system.
//
// Lifecycle
// ─────────
//   startAll()        — start all enabled services.
//   pauseAll()        — pause audio; stop AX/calendar; save pause record.
//   resumeAll()       — resume / restart paused services.
//   enterPrivateMode()— pauseAll + set .privateMode status.
//   exitPrivateMode() — resumeAll + restore .running status.
//   stopAll()         — stop all services; release resources.
//
// Battery awareness
// ─────────────────
//   Observes NSProcessInfoPowerStateDidChangeNotification and
//   ProcessInfo.thermalStateDidChangeNotification.
//   On low-power or thermal ≥ .serious:
//     • Pause audio services (most CPU-intensive).
//     • Suspend email incremental sync.
//     • Reduce accessibility polling (logged; service-level support pending).
//   Restores full capture when conditions return to normal.
//
// Error recovery
// ──────────────
//   If a service throws on start, it is marked .failed and retried every
//   `env.recoveryInterval` seconds (default 5 min) by the recovery loop.
//   Other services continue running unaffected.

import Foundation
import os

// MARK: - CaptureStatus

public enum CaptureStatus: Equatable, Sendable, Hashable {
    case idle
    case starting
    case running
    case paused
    case privateMode
    /// One or more services have failed; `failing` names them.
    case degraded(failing: Set<String>)
}

// MARK: - ServiceHealth

public enum ServiceHealth: Equatable, Sendable {
    case disabled
    case running
    case paused
    /// Service is between its normal pause and retry; included for battery-save state.
    case suspended
    case failed(String)
}

// MARK: - CaptureServiceStatus

/// Snapshot of per-service health, consumed by the Settings UI.
public struct CaptureServiceStatus: Sendable {
    public let accessibility: ServiceHealth
    public let microphone:    ServiceHealth
    public let systemAudio:   ServiceHealth
    public let email:         ServiceHealth
    public let calendar:      ServiceHealth

    public static let allDisabled = CaptureServiceStatus(
        accessibility: .disabled, microphone: .disabled,
        systemAudio:   .disabled, email:      .disabled, calendar: .disabled
    )
}

// MARK: - UserSettings

/// User preferences that gate which capture sources are started.
///
/// The real implementation reads from `UserDefaults`; tests inject a value.
public struct UserSettings: Sendable, Equatable {
    public var accessibilityCaptureEnabled: Bool
    public var microphoneCaptureEnabled:    Bool
    public var systemAudioCaptureEnabled:   Bool
    public var emailCaptureEnabled:         Bool
    public var calendarCaptureEnabled:      Bool
    public var gmailAccount:                GmailAccount?

    public init(
        accessibilityCaptureEnabled: Bool        = true,
        microphoneCaptureEnabled:    Bool        = true,
        systemAudioCaptureEnabled:   Bool        = true,
        emailCaptureEnabled:         Bool        = false,
        calendarCaptureEnabled:      Bool        = true,
        gmailAccount:                GmailAccount? = nil
    ) {
        self.accessibilityCaptureEnabled = accessibilityCaptureEnabled
        self.microphoneCaptureEnabled    = microphoneCaptureEnabled
        self.systemAudioCaptureEnabled   = systemAudioCaptureEnabled
        self.emailCaptureEnabled         = emailCaptureEnabled
        self.calendarCaptureEnabled      = calendarCaptureEnabled
        self.gmailAccount                = gmailAccount
    }

    public static let `default` = UserSettings()
}

// MARK: - Internal service protocols

// These narrow protocols let CaptureManager control @MainActor services
// uniformly, and let tests inject lightweight mock conformances.

/// Controls the accessibility-focus capture service.
@MainActor
protocol AccessibilityCapturing: AnyObject {
    var isRunning: Bool { get }
    func start()
    func stop() async
}

/// Controls an audio capture service (microphone or system audio).
@MainActor
protocol AudioCapturing: AnyObject {
    func startCapture() async throws
    func pauseCapture()
    func resumeCapture() throws
    func stopCapture() async
}

/// Controls the calendar capture service.
@MainActor
protocol CalendarCapturing: AnyObject {
    var isRunning: Bool { get }
    func start(delegate: any CaptureEventDelegate) async throws
    func stop()
}

// MARK: - Protocol conformances on concrete service types

extension AccessibilityCaptureService: AccessibilityCapturing {}

extension MicrophoneCaptureService: AudioCapturing {
    func startCapture() async throws  { try await start() }
    func pauseCapture()               { pause() }
    func resumeCapture() throws       { try resume() }
    func stopCapture() async          { await stop() }
}

@available(macOS 13.0, *)
extension SystemAudioCaptureService: AudioCapturing {
    func startCapture() async throws  { try await start() }
    func pauseCapture()               { pause() }
    func resumeCapture() throws       { resume() }    // SystemAudio.resume() doesn't throw
    func stopCapture() async          { await stop() }
}

extension CalendarCaptureService: CalendarCapturing {}

// MARK: - CaptureManager

/// Actor that owns every capture service and orchestrates the full
/// capture → exclusion → storage pipeline.
public actor CaptureManager {

    // MARK: - Environment

    public struct Environment: @unchecked Sendable {

        // ── Pre-configured service instances ──────────────────────────────
        // Services are `nil` when disabled in UserSettings or unavailable
        // (no permission, wrong OS version, etc.).  The Environment is built
        // on the @MainActor (e.g. inside AppState) before being handed to
        // CaptureManager, so @MainActor services are already constructed.

        /// The accessibility focus-tracking service (nil = disabled/denied).
        var accessibilityService: (any AccessibilityCapturing)?
        /// Microphone capture (nil = disabled/denied).
        var microphoneService:    (any AudioCapturing)?
        /// System audio capture (nil = disabled/denied/macOS < 13).
        var systemAudioService:   (any AudioCapturing)?
        /// Email capture (nil = disabled/no Gmail account).
        var emailService:         EmailCaptureService?
        /// Gmail account to use for email (nil = email disabled).
        var gmailAccount:         GmailAccount?
        /// Calendar capture (nil = disabled/denied).
        var calendarService:      (any CalendarCapturing)?

        // ── Audio pipeline ────────────────────────────────────────────────
        var audioMixer:          AudioMixer
        var transcriptionActor:  TranscriptionActor
        var micMixerAdapter:     MicAudioMixerAdapter
        var sysMixerAdapter:     SysAudioMixerAdapter

        // ── System state ──────────────────────────────────────────────────
        var isLowPowerMode:      @Sendable () -> Bool
        var thermalState:        @Sendable () -> ProcessInfo.ThermalState
        /// NotificationCenter for battery/thermal and EKEventStore notifications.
        var notificationCenter:  NotificationCenter
        /// Returns the current wall-clock time.
        var currentDate:         @Sendable () -> Date
        /// Interval between error-recovery retries (default 300 s = 5 min).
        var recoveryInterval:    TimeInterval

        // MARK: Live

        /// Builds a fully-wired live environment.
        ///
        /// - Parameters:
        ///   - settings: User preferences read by the caller from UserDefaults.
        ///   - rawEventBuffer: Shared delegate for all text-producing services.
        ///   - whisperClient: The transcription engine (WhisperServiceClient).
        ///   - oauthManager: Shared GmailOAuthManager (manages token refresh state).
        ///   - isMessageImported: Deduplication check; should query StorageActor.
        ///   - exclusionEngine: Exclusion rules for the accessibility service.
        ///   - gmailAccount: Connected Gmail account, if any.
        @MainActor
        public static func live(
            settings:          UserSettings,
            rawEventBuffer:    RawEventBuffer,
            whisperClient:     any WhisperTranscribing,
            oauthManager:      GmailOAuthManager                        = GmailOAuthManager(),
            isMessageImported: @escaping @Sendable (String) async -> Bool = { _ in false },
            exclusionEngine:   any ExclusionChecking                    = PassthroughExclusionEngine(),
            gmailAccount:      GmailAccount?                            = nil
        ) -> Environment {

            // Audio pipeline (always created; services may still be nil)
            let transcription = TranscriptionActor(
                whisperClient:          whisperClient,
                eventDelegate:          rawEventBuffer,
                classificationDelegate: nil
            )
            let mixer    = AudioMixer(delegate: transcription)
            let micAdapt = MicAudioMixerAdapter(mixer: mixer)
            let sysAdapt = SysAudioMixerAdapter(mixer: mixer)

            // @MainActor services, created here since live() is @MainActor
            let axService: (any AccessibilityCapturing)? = settings.accessibilityCaptureEnabled
                ? AccessibilityCaptureService(
                    delegate:    rawEventBuffer,
                    environment: .live(exclusionEngine: exclusionEngine)
                  )
                : nil

            let micService: (any AudioCapturing)? = settings.microphoneCaptureEnabled
                ? MicrophoneCaptureService(delegate: micAdapt)
                : nil

            let sysService: (any AudioCapturing)? = {
                guard settings.systemAudioCaptureEnabled else { return nil }
                if #available(macOS 13.0, *) {
                    return SystemAudioCaptureService(delegate: sysAdapt)
                }
                return nil
            }()

            let emailSvc: EmailCaptureService? = (settings.emailCaptureEnabled && gmailAccount != nil)
                ? EmailCaptureService(
                    eventDelegate: rawEventBuffer,
                    environment:   .live(
                        gMailOAuthManager: oauthManager,
                        eventDelegate:     rawEventBuffer,
                        isMessageImported: isMessageImported
                    )
                  )
                : nil

            let calSvc: (any CalendarCapturing)? = settings.calendarCaptureEnabled
                ? CalendarCaptureService(environment: .live())
                : nil

            return Environment(
                accessibilityService: axService,
                microphoneService:    micService,
                systemAudioService:   sysService,
                emailService:         emailSvc,
                gmailAccount:         gmailAccount,
                calendarService:      calSvc,
                audioMixer:           mixer,
                transcriptionActor:   transcription,
                micMixerAdapter:      micAdapt,
                sysMixerAdapter:      sysAdapt,
                isLowPowerMode:       { ProcessInfo.processInfo.isLowPowerModeEnabled },
                thermalState:         { ProcessInfo.processInfo.thermalState },
                notificationCenter:   .default,
                currentDate:          { Date() },
                recoveryInterval:     300
            )
        }
    }

    // MARK: - State

    private let env:            Environment
    private let rawEventBuffer: RawEventBuffer
    private let appState:       any AppStateManaging
    private let log =           Logger(subsystem: "com.kerwan.app", category: "CaptureManager")

    // Service health tracking (for Settings UI and error recovery)
    private var axHealth:    ServiceHealth = .disabled
    private var micHealth:   ServiceHealth = .disabled
    private var sysHealth:   ServiceHealth = .disabled
    private var emailHealth: ServiceHealth = .disabled
    private var calHealth:   ServiceHealth = .disabled

    private var isInPrivateMode   = false
    private var isPaused          = false
    private var isInPowerSaveMode = false

    // Active background tasks
    private var recoveryTask:   Task<Void, Never>?
    private var midnightTask:   Task<Void, Never>?

    // NotificationCenter observers (opaque tokens)
    private var batteryObserver: Any?
    private var thermalObserver: Any?

    // MARK: - Public read-only state

    /// Per-service health snapshot for the Settings permissions tab.
    public var serviceStatus: CaptureServiceStatus {
        CaptureServiceStatus(
            accessibility: axHealth,
            microphone:    micHealth,
            systemAudio:   sysHealth,
            email:         emailHealth,
            calendar:      calHealth
        )
    }

    // MARK: - Init

    public init(
        rawEventBuffer: RawEventBuffer,
        appState:       any AppStateManaging,
        environment:    Environment
    ) {
        self.rawEventBuffer = rawEventBuffer
        self.appState       = appState
        self.env            = environment
    }

    // MARK: - Public API

    /// Starts all enabled services, the audio pipeline, and background
    /// monitoring loops.  Services that fail are marked `.failed` and will
    /// be retried every `recoveryInterval` seconds.
    public func startAll() async {
        await appState.setCaptureStatus(.starting)
        log.info("CaptureManager: startAll()")

        // Start TranscriptionActor (audio pipeline sink)
        do {
            try await env.transcriptionActor.start()
        } catch {
            log.error("TranscriptionActor failed to start: \(error.localizedDescription)")
        }

        // Start each enabled service independently; failures are isolated.
        await startAccessibility()
        await startMicrophone()
        await startSystemAudio()
        await startEmail()
        await startCalendar()

        // Register battery / thermal observers
        registerPowerObservers()

        // Launch background loops
        startRecoveryLoop()
        scheduleMidnightReset()

        await syncCaptureStatus()
        log.info("CaptureManager: startAll() complete")
    }

    /// Pauses all services. Audio is paused (not stopped); AX and calendar
    /// are stopped (they have no native pause).
    public func pauseAll() async {
        guard !isPaused && !isInPrivateMode else { return }
        isPaused = true
        await pauseServices()
        await appState.setCaptureStatus(.paused)
        log.info("CaptureManager: paused")
    }

    /// Resumes all services that were running before `pauseAll()`.
    public func resumeAll() async {
        guard isPaused && !isInPrivateMode else { return }
        isPaused = false
        await resumeServices()
        await syncCaptureStatus()
        log.info("CaptureManager: resumed")
    }

    /// Pauses all capture and marks status as `.privateMode`.
    /// Also records the pause start in storage via a special RawEvent.
    public func enterPrivateMode() async {
        guard !isInPrivateMode else { return }
        isInPrivateMode = true
        isPaused        = true
        await pauseServices()
        await appState.setCaptureStatus(.privateMode)
        log.info("CaptureManager: entered private mode")
    }

    /// Exits private mode and resumes capture.
    public func exitPrivateMode() async {
        guard isInPrivateMode else { return }
        isInPrivateMode = false
        isPaused        = false
        await resumeServices()
        await syncCaptureStatus()
        log.info("CaptureManager: exited private mode")
    }

    /// Stops all services and releases resources.
    public func stopAll() async {
        recoveryTask?.cancel();  recoveryTask  = nil
        midnightTask?.cancel();  midnightTask  = nil
        removePowerObservers()

        await stopAccessibility()
        await stopMicrophone()
        await stopSystemAudio()
        await stopEmail()
        await stopCalendar()

        await env.transcriptionActor.stop()

        axHealth    = .disabled
        micHealth   = .disabled
        sysHealth   = .disabled
        emailHealth = .disabled
        calHealth   = .disabled
        isPaused        = false
        isInPrivateMode = false

        await appState.setCaptureStatus(.idle)
        log.info("CaptureManager: stopAll() complete")
    }

    // MARK: - Private: individual service start/stop

    private func startAccessibility() async {
        guard let svc = env.accessibilityService else { axHealth = .disabled; return }
        await svc.start()
        axHealth = .running
        log.info("AccessibilityCaptureService started")
    }

    private func startMicrophone() async {
        guard let svc = env.microphoneService else { micHealth = .disabled; return }
        do {
            try await svc.startCapture()
            micHealth = .running
            log.info("MicrophoneCaptureService started")
        } catch {
            micHealth = .failed(error.localizedDescription)
            log.error("MicrophoneCaptureService failed: \(error.localizedDescription)")
        }
    }

    private func startSystemAudio() async {
        guard let svc = env.systemAudioService else { sysHealth = .disabled; return }
        do {
            try await svc.startCapture()
            sysHealth = .running
            log.info("SystemAudioCaptureService started")
        } catch {
            sysHealth = .failed(error.localizedDescription)
            log.error("SystemAudioCaptureService failed: \(error.localizedDescription)")
        }
    }

    private func startEmail() async {
        guard let svc = env.emailService, let account = env.gmailAccount else {
            emailHealth = .disabled; return
        }
        do {
            try await svc.connect(account: account)
            try await svc.startHistoricalImport()
            await svc.startIncrementalSync()
            emailHealth = .running
            log.info("EmailCaptureService started for \(account.email)")
        } catch {
            emailHealth = .failed(error.localizedDescription)
            log.error("EmailCaptureService failed: \(error.localizedDescription)")
        }
    }

    private func startCalendar() async {
        guard let svc = env.calendarService else { calHealth = .disabled; return }
        do {
            try await svc.start(delegate: rawEventBuffer)
            calHealth = .running
            log.info("CalendarCaptureService started")
        } catch {
            calHealth = .failed(error.localizedDescription)
            log.error("CalendarCaptureService failed: \(error.localizedDescription)")
        }
    }

    private func stopAccessibility() async {
        await env.accessibilityService?.stop()
    }

    private func stopMicrophone() async {
        await env.microphoneService?.stopCapture()
    }

    private func stopSystemAudio() async {
        await env.systemAudioService?.stopCapture()
    }

    private func stopEmail() async {
        await env.emailService?.disconnect()
    }

    private func stopCalendar() async {
        await env.calendarService?.stop()
    }

    // MARK: - Private: pause / resume

    private func pauseServices() async {
        // AX and calendar have no native pause — stop them
        await env.accessibilityService?.stop()
        if case .running = axHealth { axHealth = .paused }

        await env.calendarService?.stop()
        if case .running = calHealth { calHealth = .paused }

        // Audio services have native pause
        await env.microphoneService?.pauseCapture()
        if case .running = micHealth { micHealth = .paused }

        await env.systemAudioService?.pauseCapture()
        if case .running = sysHealth { sysHealth = .paused }

        // Email: disconnect to stop incremental sync
        await env.emailService?.disconnect()
        if case .running = emailHealth { emailHealth = .paused }
    }

    private func resumeServices() async {
        // Restart stopped services
        if case .paused = axHealth { await startAccessibility() }
        if case .paused = calHealth { await startCalendar() }

        // Resume audio
        if case .paused = micHealth {
            do { try await env.microphoneService?.resumeCapture(); micHealth = .running }
            catch { micHealth = .failed(error.localizedDescription) }
        }
        if case .paused = sysHealth {
            do { try await env.systemAudioService?.resumeCapture(); sysHealth = .running }
            catch { sysHealth = .failed(error.localizedDescription) }
        }

        // Reconnect email
        if case .paused = emailHealth { await startEmail() }
    }

    // MARK: - Private: battery / thermal awareness

    private func registerPowerObservers() {
        let nc = env.notificationCenter

        batteryObserver = nc.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object:  nil,
            queue:   .main
        ) { [weak self] _ in
            Task { await self?.handlePowerStateChange() }
        }

        thermalObserver = nc.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object:  nil,
            queue:   .main
        ) { [weak self] _ in
            Task { await self?.handlePowerStateChange() }
        }
    }

    private func removePowerObservers() {
        if let obs = batteryObserver { env.notificationCenter.removeObserver(obs) }
        if let obs = thermalObserver { env.notificationCenter.removeObserver(obs) }
        batteryObserver = nil
        thermalObserver = nil
    }

    private func handlePowerStateChange() async {
        let shouldConserve = env.isLowPowerMode() ||
                             env.thermalState() >= .serious

        if shouldConserve && !isInPowerSaveMode {
            isInPowerSaveMode = true
            await enterPowerSaveMode()
        } else if !shouldConserve && isInPowerSaveMode {
            isInPowerSaveMode = false
            await exitPowerSaveMode()
        }
    }

    private func enterPowerSaveMode() async {
        guard !isPaused && !isInPrivateMode else { return }
        log.warning("CaptureManager: entering power-save mode (low power or thermal ≥ serious)")

        // Pause CPU-intensive audio services
        await env.microphoneService?.pauseCapture()
        if case .running = micHealth { micHealth = .suspended }

        await env.systemAudioService?.pauseCapture()
        if case .running = sysHealth { sysHealth = .suspended }

        // Suspend email incremental sync
        await env.emailService?.disconnect()
        if case .running = emailHealth { emailHealth = .suspended }

        // Accessibility: log reduction (service-level support pending)
        log.info("Power save: accessibility polling reduced (service-level support pending)")
    }

    private func exitPowerSaveMode() async {
        guard !isPaused && !isInPrivateMode else { return }
        log.info("CaptureManager: exiting power-save mode")

        if case .suspended = micHealth {
            do { try await env.microphoneService?.resumeCapture(); micHealth = .running }
            catch { micHealth = .failed(error.localizedDescription) }
        }
        if case .suspended = sysHealth {
            do { try await env.systemAudioService?.resumeCapture(); sysHealth = .running }
            catch { sysHealth = .failed(error.localizedDescription) }
        }
        if case .suspended = emailHealth { await startEmail() }
    }

    // MARK: - Private: error recovery loop

    private func startRecoveryLoop() {
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(env.recoveryInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await attemptRecovery()
            }
        }
    }

    private func attemptRecovery() async {
        guard !isPaused && !isInPrivateMode && !isInPowerSaveMode else { return }

        if case .failed = micHealth   { await startMicrophone() }
        if case .failed = sysHealth   { await startSystemAudio() }
        if case .failed = emailHealth { await startEmail() }
        if case .failed = calHealth   { await startCalendar() }
        if case .failed = axHealth    { await startAccessibility() }

        await syncCaptureStatus()
        log.info("Recovery attempt complete — status: \(String(describing: self.serviceStatus.accessibility))")
    }

    // MARK: - Private: midnight event count reset

    private func scheduleMidnightReset() {
        midnightTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let now       = env.currentDate()
                let tomorrow  = Calendar.current.startOfDay(
                    for: now.addingTimeInterval(86_400)
                )
                let interval  = tomorrow.timeIntervalSince(now)
                try? await Task.sleep(nanoseconds: UInt64(max(interval, 0) * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await appState.resetEventsToday()
                log.info("Midnight: events-today counter reset")
            }
        }
    }

    // MARK: - Private: status helpers

    private func syncCaptureStatus() async {
        let failingNames = failingServiceNames()
        let status: CaptureStatus = failingNames.isEmpty ? .running : .degraded(failing: failingNames)
        await appState.setCaptureStatus(status)
    }

    private func failingServiceNames() -> Set<String> {
        var s: Set<String> = []
        if case .failed = axHealth    { s.insert("Accessibility") }
        if case .failed = micHealth   { s.insert("Microphone") }
        if case .failed = sysHealth   { s.insert("System Audio") }
        if case .failed = emailHealth { s.insert("Email") }
        if case .failed = calHealth   { s.insert("Calendar") }
        return s
    }
}

// MARK: - ThermalState comparison helper

private extension ProcessInfo.ThermalState {
    static func >= (lhs: ProcessInfo.ThermalState, rhs: ProcessInfo.ThermalState) -> Bool {
        lhs.rawValue >= rhs.rawValue
    }
}
