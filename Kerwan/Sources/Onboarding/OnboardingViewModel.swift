import SwiftUI
import AVFoundation
import CoreGraphics
import EventKit
import AppKit
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

    // MARK: - Init

    init() {
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

    func connectGmail() {
        guard !isConnectingGmail else { return }
        isConnectingGmail = true
        // Full OAuth implementation provided by the email workstream.
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            gmailConnected = true
            isConnectingGmail = false
            Self.logger.debug("Gmail connection stub completed")
        }
    }

    // MARK: - AI model download

    func startModelDownload() {
        guard !isDownloading, !downloadComplete else { return }
        isDownloading = true
        downloadError = nil
        whisperProgress = 0
        ollamaProgress = 0
        whisperComplete = false
        ollamaComplete = false
        Task { await runSimulatedDownload() }
    }

    /// Placeholder progress simulation until the WhisperKit / Ollama download
    /// workstream provides real `URLSession` progress tracking.
    private func runSimulatedDownload() async {
        // Whisper model (≈150 MB): 20 ticks × 120 ms ≈ 2.4 s
        for tick in 1...20 {
            try? await Task.sleep(for: .milliseconds(120))
            whisperProgress = Double(tick) / 20.0
        }
        whisperComplete = true

        // Ollama model (≈4 GB): 20 ticks × 250 ms ≈ 5 s
        for tick in 1...20 {
            try? await Task.sleep(for: .milliseconds(250))
            ollamaProgress = Double(tick) / 20.0
        }
        ollamaComplete = true
        isDownloading = false
        Self.logger.debug("AI model download simulation complete")
    }

    var downloadComplete: Bool { whisperComplete && ollamaComplete }
}
