import SwiftUI
import os

/// Observable application state shared across the entire SwiftUI view hierarchy.
///
/// `AppState` is the single source of truth for all UI-visible data in Kerwan.
/// It is `@Observable` (macOS 14 Observation framework, back-deployed to macOS 13
/// via the Swift Observation package) and `@MainActor`-isolated so every read and
/// write from a SwiftUI view body is safe without extra synchronization.
///
/// Service actors (`CaptureManager`, `AppStorageService`) publish updates by
/// dispatching mutations on the main actor:
/// ```swift
/// Task { @MainActor in appState.updateCaptureStatus(.capturing) }
/// ```
///
/// Inject via `@Environment(AppState.self)` in child views.
@Observable
@MainActor
final class AppState {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "AppState"
    )

    // MARK: - Capture State

    /// Current operating mode of the passive capture system.
    var captureStatus: CaptureStatus = .idle

    /// Whether WhisperService is currently producing a transcription segment.
    /// Drives the pulse animation on the menu bar icon.
    var activeTranscription: Bool = false

    // MARK: - Counts

    /// Total raw events captured since midnight (local time).
    var eventsToday: Int = 0

    /// Work sessions with `.undecided` billable status awaiting user review.
    var pendingReviewCount: Int = 0

    /// Promises in `.open` state that the user has not yet acted on.
    var openPromiseCount: Int = 0

    /// Unbilled hours accumulated across sessions with `.undecided` or `.billable`
    /// status that have not yet been invoiced. Drives the Billing sidebar badge.
    var unbilledHours: Double = 0.0

    // MARK: - Navigation

    /// The sidebar item currently selected in the main window.
    ///
    /// Setting this from outside the window (e.g. from a menu bar action) causes
    /// `ContentView` to sync the new value into `@SceneStorage` and update the
    /// visible selection. The view is the source of truth for persistence;
    /// this property is the programmatic entry point.
    var selectedSidebarItem: SidebarItem? = .today

    /// The contact whose detail panel is open.
    var selectedContact: Contact? = nil

    /// The client whose detail panel is open.
    var selectedClient: Client? = nil

    // MARK: - Search

    /// Live-typed search query string.
    var searchQuery: String = ""

    /// Results from the most recently completed search pass.
    var searchResults: [SearchResult] = []

    /// Whether a storage / embedding round-trip is currently in flight.
    var isSearching: Bool = false

    // MARK: - License

    /// The features enabled by the currently resolved license.
    ///
    /// Defaults to ``LicenseFeatures/free`` until ``LicenseManager/validate()``
    /// completes. Views gate paid UI elements on this value.
    var licenseFeatures: LicenseFeatures = .free

    /// Whether the most recently resolved license was accepted as valid.
    var isLicenseValid: Bool = false

    /// Updates the observable license state.
    ///
    /// Called by `KerwanAppDelegate` after ``LicenseManager/validate()`` resolves.
    func updateLicense(features: LicenseFeatures, isValid: Bool) {
        licenseFeatures = features
        isLicenseValid  = isValid
        Self.logger.info(
            "License updated: plan=\(features.plan, privacy: .public) valid=\(isValid, privacy: .public)"
        )
    }

    // MARK: - Browser Extension

    /// Whether the Chrome extension is currently connected via the NMH socket.
    var isBrowserExtensionConnected: Bool = false

    /// Whether browser context capture (LinkedIn / Gmail) is enabled.
    /// Mirrors the toggle in `BrowserSettingsTab`; persisted to UserDefaults.
    var browserCaptureEnabled: Bool = UserDefaults.standard.object(forKey: "browserCaptureEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(browserCaptureEnabled, forKey: "browserCaptureEnabled") }
    }

    // MARK: - Service Availability

    /// Whether the WhisperService XPC connection is established and healthy.
    var isWhisperServiceConnected: Bool = false

    /// Whether the Ollama subprocess is running and accepting requests.
    var isOllamaRunning: Bool = false

    /// Whether the WhisperKit model is loaded and ready for transcription.
    var isModelLoaded: Bool = false

    // MARK: - App Initialization

    /// Whether all services have completed their startup sequence.
    private(set) var isInitialized: Bool = false

    /// The most recent user-visible error string, cleared on next successful action.
    var lastError: String? = nil

    // MARK: - Legacy compatibility shims
    // These preserve the API used by existing views pending a full migration.

    /// Convenience accessor; equivalent to `captureStatus.isActive`.
    var isCaptureActive: Bool { captureStatus.isActive }

    /// Number of sessions started today (updated by the billing engine loop).
    var todaySessionCount: Int = 0

    /// Total minutes of audio captured today (updated by the lifecycle loop).
    var todayCapturedMinutes: Double = 0.0

    // MARK: - Init

    // MARK: - Degradation

    /// Live health status for Whisper, Ollama, IMAP, AX, and Database subsystems.
    var degradation = GracefulDegradationManager()

    init() {
        Self.logger.info("AppState initialized")
    }

    // MARK: - Mutations (thread-safe via @MainActor isolation)

    /// Updates the capture status and logs the transition.
    func updateCaptureStatus(_ status: CaptureStatus) {
        captureStatus = status
        Self.logger.debug("Capture status → \(status.description, privacy: .public)")
    }

    /// Records the total raw-event count for today.
    func updateEventsToday(_ count: Int) {
        eventsToday = count
    }

    /// Updates the count of sessions awaiting billability review.
    func updatePendingReviewCount(_ count: Int) {
        pendingReviewCount = count
    }

    /// Updates the count of open (unactioned) promises.
    func updateOpenPromiseCount(_ count: Int) {
        openPromiseCount = count
    }

    /// Updates the total unbilled hours shown on the Billing sidebar badge.
    func updateUnbilledHours(_ hours: Double) {
        unbilledHours = max(0, hours)
    }

    /// Signals that WhisperService has started or finished a transcription pass.
    func updateTranscriptionState(_ active: Bool) {
        activeTranscription = active
    }

    /// Updates the WhisperService XPC connectivity state.
    func updateWhisperServiceConnection(_ connected: Bool) {
        isWhisperServiceConnected = connected
    }

    /// Updates the Ollama subprocess availability.
    func updateOllamaRunning(_ running: Bool) {
        isOllamaRunning = running
    }

    /// Updates whether the WhisperKit model is loaded.
    func updateModelLoaded(_ loaded: Bool) {
        isModelLoaded = loaded
    }

    /// Records a user-visible error for display in the menu bar status line or a HUD.
    func reportError(_ message: String) {
        lastError = message
        Self.logger.error("Error reported to AppState: \(message, privacy: .public)")
    }

    /// Clears the currently displayed error message.
    func clearError() {
        lastError = nil
    }

    /// Called by `AppLifecycle` once all services have finished their startup sequence.
    func markInitialized() {
        isInitialized = true
        Self.logger.info("AppState: all services initialized")
    }
}
