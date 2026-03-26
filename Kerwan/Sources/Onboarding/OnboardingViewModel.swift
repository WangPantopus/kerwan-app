import SwiftUI
import AVFoundation
import CoreGraphics
import EventKit
import AppKit
import Combine
import os

// MARK: - OnboardingStep

enum OnboardingStep: Int, CaseIterable {
    case welcome     = 0
    case permissions = 1
    case email       = 2
    case aiSetup     = 3
    case ready       = 4

    var title: String {
        switch self {
        case .welcome:     return "Welcome"
        case .permissions: return "Permissions"
        case .email:       return "Email"
        case .aiSetup:     return "AI Setup"
        case .ready:       return "Ready"
        }
    }

    /// Whether the user can skip this step and be re-prompted later.
    var isSkippable: Bool {
        switch self {
        case .permissions, .email, .aiSetup: return true
        case .welcome, .ready:               return false
        }
    }
}

// MARK: - OnboardingPermissionItem

/// A single permission entry shown in the Permissions step.
struct OnboardingPermissionItem: Identifiable {
    let id: KerwanPermission
    var status: PermissionStatus
}

// MARK: - OnboardingViewModel

@Observable
@MainActor
final class OnboardingViewModel {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "OnboardingViewModel"
    )

    // MARK: - UserDefaults keys

    private enum Keys {
        static let completed          = "com.kerwan.app.onboardingCompleted"
        static let lastStep           = "com.kerwan.app.onboardingLastStep"
        static let skippedPermissions = "com.kerwan.app.onboardingSkippedPermissions"
        static let skippedEmail       = "com.kerwan.app.onboardingSkippedEmail"
        static let skippedAI          = "com.kerwan.app.onboardingSkippedAI"
    }

    // MARK: - Persistence helpers (static, safe to call before init)

    /// Returns true if the user has fully completed onboarding.
    static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: Keys.completed)
    }

    /// The raw step index the user reached before quitting (used to resume).
    static var savedStepIndex: Int {
        UserDefaults.standard.integer(forKey: Keys.lastStep)
    }

    // MARK: - Navigation state

    var currentStep: OnboardingStep
    /// Drives the slide direction of the inter-step transition.
    var isAnimatingForward: Bool = true

    // MARK: - Permissions step

    var permissions: [OnboardingPermissionItem] = KerwanPermission.allCases.map {
        OnboardingPermissionItem(id: $0, status: .notDetermined)
    }
    var isRequestingPermission: Bool = false
    var permissionsSkipped: Bool = false

    // MARK: - Email step

    var isConnectingGmail: Bool = false
    var gmailConnected: Bool = false
    var emailSkipped: Bool = false

    // MARK: - AI Setup step

    var isDownloading: Bool = false
    var whisperProgress: Double = 0
    var ollamaProgress: Double = 0
    var whisperComplete: Bool = false
    var ollamaComplete: Bool = false
    var downloadError: String? = nil
    var aiSetupSkipped: Bool = false

    // MARK: - Dependencies

    private let gmailOAuth: GmailOAuthManager
    private let whisperModel: ModelManager
    private let ollamaManager: OllamaManager

    /// Combine subscriptions kept alive for the lifetime of this view model.
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(
        gmailOAuth: GmailOAuthManager = GmailOAuthManager(),
        whisperModel: ModelManager = ModelManager(),
        ollamaManager: OllamaManager = OllamaManager()
    ) {
        self.gmailOAuth    = gmailOAuth
        self.whisperModel  = whisperModel
        self.ollamaManager = ollamaManager

        let saved = UserDefaults.standard.integer(forKey: Keys.lastStep)
        self.currentStep = OnboardingStep(rawValue: saved) ?? .welcome
        self.permissionsSkipped = UserDefaults.standard.bool(forKey: Keys.skippedPermissions)
        self.emailSkipped       = UserDefaults.standard.bool(forKey: Keys.skippedEmail)
        self.aiSetupSkipped     = UserDefaults.standard.bool(forKey: Keys.skippedAI)
        refreshPermissions()
    }

    // MARK: - Navigation

    func advance() {
        isAnimatingForward = true
        if let next = OnboardingStep(rawValue: currentStep.rawValue + 1) {
            currentStep = next
            UserDefaults.standard.set(currentStep.rawValue, forKey: Keys.lastStep)
        } else {
            complete()
        }
    }

    func goBack() {
        guard currentStep.rawValue > 0 else { return }
        isAnimatingForward = false
        currentStep = OnboardingStep(rawValue: currentStep.rawValue - 1) ?? .welcome
        UserDefaults.standard.set(currentStep.rawValue, forKey: Keys.lastStep)
    }

    func skip() {
        switch currentStep {
        case .permissions:
            permissionsSkipped = true
            UserDefaults.standard.set(true, forKey: Keys.skippedPermissions)
        case .email:
            emailSkipped = true
            UserDefaults.standard.set(true, forKey: Keys.skippedEmail)
        case .aiSetup:
            aiSetupSkipped = true
            UserDefaults.standard.set(true, forKey: Keys.skippedAI)
        default:
            break
        }
        advance()
        Self.logger.debug("Onboarding step '\(self.currentStep.title, privacy: .public)' skipped")
    }

    func complete() {
        UserDefaults.standard.set(true, forKey: Keys.completed)
        UserDefaults.standard.set(OnboardingStep.ready.rawValue, forKey: Keys.lastStep)
        NotificationCenter.default.post(name: .kerwanOnboardingCompleted, object: nil)
        Self.logger.info("Onboarding completed")
    }

    // MARK: - Permissions

    func refreshPermissions() {
        for i in permissions.indices {
            permissions[i].status = liveStatus(for: permissions[i].id)
        }
    }

    private func liveStatus(for permission: KerwanPermission) -> PermissionStatus {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:    return .granted
            case .denied:        return .denied
            case .notDetermined: return .notDetermined
            case .restricted:    return .restricted
            @unknown default:    return .unknown
            }
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .authorized, .fullAccess: return .granted
            case .denied:                  return .denied
            case .notDetermined:           return .notDetermined
            case .restricted:              return .restricted
            case .writeOnly:               return .granted
            @unknown default:              return .unknown
            }
        }
    }

    func requestPermission(_ item: OnboardingPermissionItem) async {
        guard item.status != .granted else { return }
        isRequestingPermission = true
        defer {
            isRequestingPermission = false
            refreshPermissions()
        }

        switch item.id {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)

        case .screenRecording:
            // CGRequestScreenCaptureAccess prompts the system dialog. If access
            // was previously denied the user is directed to System Settings.
            CGRequestScreenCaptureAccess()

        case .accessibility:
            // There is no runtime API to trigger the Accessibility prompt; the
            // user must grant it in System Settings.
            NSWorkspace.shared.open(item.id.settingsURL)

        case .calendar:
            let store = EKEventStore()
            if #available(macOS 14, *) {
                _ = try? await store.requestFullAccessToEvents()
            } else {
                await withCheckedContinuation { cont in
                    store.requestAccess(to: .event) { _, _ in cont.resume() }
                }
            }
        }
    }

    var allPermissionsGranted: Bool {
        permissions.allSatisfy { $0.status == .granted }
    }

    // MARK: - Gmail connection

    /// Initiates the real Gmail OAuth flow via `GmailOAuthManager.startOAuthFlow()`.
    /// Opens the system browser to Google's consent screen, waits for the callback,
    /// and persists the resulting `GmailAccount` to the Keychain.
    func connectGmail() {
        guard !isConnectingGmail else { return }
        isConnectingGmail = true
        Task {
            do {
                _ = try await gmailOAuth.startOAuthFlow()
                gmailConnected = true
                Self.logger.info("Gmail OAuth completed successfully")
            } catch {
                gmailConnected = false
                Self.logger.error("Gmail OAuth failed: \(error.localizedDescription, privacy: .public)")
            }
            isConnectingGmail = false
        }
    }

    // MARK: - AI model download

    /// Starts downloading the Whisper speech-recognition model via `ModelManager`
    /// and the Ollama language model via `OllamaManager`, reporting real
    /// `URLSession`-backed progress for each.
    func startModelDownload() {
        guard !isDownloading, !downloadComplete else { return }
        isDownloading = true
        downloadError = nil
        whisperProgress = 0
        ollamaProgress  = 0
        whisperComplete  = false
        ollamaComplete   = false

        // Observe real Whisper download progress via ModelManager's @Published state.
        whisperModel.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .downloading(let fraction):
                    self.whisperProgress = fraction
                case .ready:
                    self.whisperProgress = 1.0
                    self.whisperComplete  = true
                    // Begin Ollama pull once Whisper finishes.
                    self.pullOllamaModels()
                case .failed(let reason):
                    self.downloadError = "Whisper download failed: \(reason)"
                    self.isDownloading  = false
                case .notInstalled:
                    break
                }
            }
            .store(in: &cancellables)

        whisperModel.downloadModelIfNeeded()
    }

    /// Pulls required Ollama models, reporting fractional progress.
    ///
    /// Called automatically after the Whisper model download completes.
    /// On Ollama-not-installed errors the user is shown an appropriate
    /// message and the step can be retried or skipped.
    private func pullOllamaModels() {
        Task {
            do {
                // Ensure the Ollama daemon is running (launches it if installed).
                try await ollamaManager.ensureRunning()

                // Pull the primary language-model used for digests and briefs.
                // Progress is reported directly by OllamaClient's streaming pull API.
                try await ollamaManager.client.pullModel(
                    name: "llama3:8b-instruct-q4_K_M"
                ) { [weak self] fraction in
                    let s = self
                    Task { @MainActor in
                        s?.ollamaProgress = fraction
                    }
                }
                ollamaProgress = 1.0
                ollamaComplete  = true
                isDownloading   = false
                Self.logger.info("Ollama model pull completed")
            } catch {
                Self.logger.error("Ollama pull failed: \(error.localizedDescription, privacy: .public)")
                downloadError = "AI model download failed: \(error.localizedDescription)"
                isDownloading = false
            }
        }
    }

    var downloadComplete: Bool { whisperComplete && ollamaComplete }
}
