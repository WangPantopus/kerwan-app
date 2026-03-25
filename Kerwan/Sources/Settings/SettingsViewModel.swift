import SwiftUI
import AVFoundation
import CoreGraphics
import EventKit
import ServiceManagement
import os

// MARK: - Storage service protocol

/// The subset of storage operations required by the Settings UI.
/// Concrete implementation lives in `KerwanStorage.StorageActor`.
protocol SettingsStorageService: Actor {
    func fetchUserSettings() async throws -> UserSettings
    func updateUserSetting(key: String, value: Any) async throws
    func fetchExclusionRules() async throws -> [ExclusionRule]
    func insertExclusionRule(_ rule: ExclusionRule) async throws
    func deleteExclusionRule(id: String) async throws
    func databaseFileSizeBytes() async throws -> Int64
    func exportDatabase(to url: URL) async throws
    func deleteAllData() async throws
    func deleteDataBefore(_ date: Date) async throws
}

// MARK: - Permission types

/// A system permission that Kerwan may request.
enum KerwanPermission: CaseIterable {
    case microphone
    case screenRecording
    case accessibility
    case calendar

    var title: String {
        switch self {
        case .microphone:     return "Microphone"
        case .screenRecording: return "Screen Recording"
        case .accessibility:  return "Accessibility"
        case .calendar:       return "Calendar"
        }
    }

    var permissionDescription: String {
        switch self {
        case .microphone:
            return "Required to transcribe meetings and calls into billable session notes."
        case .screenRecording:
            return "Required to detect active applications and window titles for session attribution."
        case .accessibility:
            return "Required to track app focus changes and keyboard-level activity signals."
        case .calendar:
            return "Required to correlate calendar events with captured work sessions."
        }
    }

    /// Deep-link that opens the relevant pane in System Settings.
    var settingsURL: URL {
        switch self {
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .calendar:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        }
    }

    var systemImage: String {
        switch self {
        case .microphone:     return "mic"
        case .screenRecording: return "rectangle.on.rectangle"
        case .accessibility:  return "accessibility"
        case .calendar:       return "calendar"
        }
    }
}

/// Normalised permission status independent of the underlying API.
enum PermissionStatus {
    case granted
    case denied
    case notDetermined
    case restricted
    case unknown

    var label: String {
        switch self {
        case .granted:       return "Granted"
        case .denied:        return "Denied"
        case .notDetermined: return "Not requested"
        case .restricted:    return "Restricted"
        case .unknown:       return "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .granted:       return .green
        case .denied:        return .red
        case .notDetermined: return .orange
        case .restricted:    return .secondary
        case .unknown:       return .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .granted:       return "checkmark.circle.fill"
        case .denied:        return "xmark.circle.fill"
        case .notDetermined: return "questionmark.circle.fill"
        case .restricted, .unknown: return "minus.circle.fill"
        }
    }
}

// MARK: - Email account model

enum EmailSyncStatus: String, Codable, Sendable {
    case connected
    case syncing
    case error
    case disconnected
}

struct EmailAccount: Identifiable, Hashable {
    let id: String
    let address: String
    var lastSyncAt: Date?
    var status: EmailSyncStatus
}

// MARK: - SettingsViewModel

/// Central view model for the Settings window.
///
/// Owns all mutable state shared across the six settings tabs. Each tab receives
/// a binding into this model rather than accessing storage directly, keeping
/// reads and writes funnelled through one place.
@Observable
@MainActor
final class SettingsViewModel {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "SettingsViewModel"
    )

    // MARK: Injected dependency

    /// Injected at creation time via ``init(storage:)``.
    /// Nil until the caller provides a concrete service (tests may leave it nil).
    private var storage: (any SettingsStorageService)?

    // MARK: General settings (mirrors UserSettings)

    var captureAudio: Bool = UserSettings.defaults.captureAudio
    var captureAccessibility: Bool = UserSettings.defaults.captureAccessibility
    var consentMode: Bool = UserSettings.defaults.consentMode
    var passphraseInKeychain: Bool = UserSettings.defaults.passphraseInKeychain
    var billableDefaultRate: Double = UserSettings.defaults.billableDefaultRate

    /// Digest time as a `Date` for `DatePicker` binding (only the time
    /// components are meaningful; the date portion is ignored).
    var digestTime: Date = {
        let parts = UserSettings.defaults.digestTime.split(separator: ":")
        let h = Int(parts.first ?? "9") ?? 9
        let m = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = h
        comps.minute = m
        return Calendar.current.date(from: comps) ?? Date()
    }()

    /// Whether the SMAppService launch-at-login helper is registered.
    var launchAtLogin: Bool = false

    // MARK: Permissions

    var permissionStatuses: [KerwanPermission: PermissionStatus] = {
        var d: [KerwanPermission: PermissionStatus] = [:]
        for p in KerwanPermission.allCases { d[p] = .unknown }
        return d
    }()

    // MARK: Email accounts

    var emailAccounts: [EmailAccount] = []

    // MARK: Exclusion rules

    var exclusionRules: [ExclusionRule] = []

    // MARK: Data tab

    var databaseFileSizeBytes: Int64 = 0
    var isExporting: Bool = false
    var isConfirmingDeleteAll: Bool = false
    var deleteBeforeDate: Date = Calendar.current.date(
        byAdding: .month, value: -3, to: Date()
    ) ?? Date()

    // MARK: Error feedback

    var lastError: String? = nil

    // MARK: Init

    init(storage: (any SettingsStorageService)? = nil) {
        self.storage = storage
    }

    // MARK: - Lifecycle

    func onAppear() async {
        await refreshAll()
    }

    private func refreshAll() async {
        await loadSettings()
        await loadExclusionRules()
        await loadDatabaseSize()
        refreshPermissions()
        refreshLaunchAtLogin()
    }

    // MARK: - General settings

    private func loadSettings() async {
        guard let storage else { return }
        do {
            let s = try await storage.fetchUserSettings()
            captureAudio = s.captureAudio
            captureAccessibility = s.captureAccessibility
            consentMode = s.consentMode
            passphraseInKeychain = s.passphraseInKeychain
            billableDefaultRate = s.billableDefaultRate
            digestTime = digestTimeDate(from: s.digestTime)
        } catch {
            Self.logger.error("Failed to load settings: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    func saveSetting(key: String, value: Any) {
        guard let storage else { return }
        Task {
            do {
                try await storage.updateUserSetting(key: key, value: value)
                Self.logger.debug("Saved setting \(key, privacy: .public)")
            } catch {
                Self.logger.error("Failed to save \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription
            }
        }
    }

    /// Converts the `digestTime` `Date` binding back to "HH:mm" and persists it.
    func saveDigestTime() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: digestTime)
        let h = comps.hour ?? 9
        let m = comps.minute ?? 0
        saveSetting(key: "digestTime", value: String(format: "%02d:%02d", h, m))
    }

    // MARK: - Launch at login

    func refreshLaunchAtLogin() {
        if #available(macOS 13, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func toggleLaunchAtLogin() {
        if #available(macOS 13, *) {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            } catch {
                Self.logger.error("Launch-at-login toggle failed: \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Permissions

    func refreshPermissions() {
        permissionStatuses[.microphone] = microphoneStatus()
        permissionStatuses[.screenRecording] = screenRecordingStatus()
        permissionStatuses[.accessibility] = accessibilityStatus()
        permissionStatuses[.calendar] = calendarStatus()
    }

    private func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:          return .granted
        case .denied:              return .denied
        case .notDetermined:       return .notDetermined
        case .restricted:          return .restricted
        @unknown default:          return .unknown
        }
    }

    private func screenRecordingStatus() -> PermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    private func accessibilityStatus() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    private func calendarStatus() -> PermissionStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess:  return .granted
        case .denied:                   return .denied
        case .notDetermined:            return .notDetermined
        case .restricted:               return .restricted
        case .writeOnly:                return .granted
        @unknown default:               return .unknown
        }
    }

    // MARK: - Email accounts

    func connectGmail() {
        // OAuth stub — full implementation by the email workstream.
        Self.logger.debug("Gmail OAuth flow initiated (stub)")
    }

    func disconnectAccount(_ account: EmailAccount) {
        emailAccounts.removeAll { $0.id == account.id }
        Self.logger.debug("Disconnected account \(account.address, privacy: .public)")
    }

    // MARK: - Exclusion rules

    private func loadExclusionRules() async {
        guard let storage else { return }
        do {
            exclusionRules = try await storage.fetchExclusionRules()
        } catch {
            Self.logger.error("Failed to load exclusion rules: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    func addExclusionRule(ruleType: ExclusionRuleType, pattern: String) {
        guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let rule = ExclusionRule(ruleType: ruleType, pattern: pattern)
        exclusionRules.append(rule)
        guard let storage else { return }
        Task {
            do {
                try await storage.insertExclusionRule(rule)
            } catch {
                Self.logger.error("Failed to insert exclusion rule: \(error.localizedDescription, privacy: .public)")
                exclusionRules.removeAll { $0.id == rule.id }
                lastError = error.localizedDescription
            }
        }
    }

    func deleteExclusionRules(ruleType: ExclusionRuleType, at offsets: IndexSet) {
        let rulesOfType = exclusionRules.filter { $0.ruleType == ruleType }
        let toDelete = offsets.map { rulesOfType[$0] }
        exclusionRules.removeAll { rule in toDelete.contains(where: { $0.id == rule.id }) }
        guard let storage else { return }
        Task {
            for rule in toDelete {
                do {
                    try await storage.deleteExclusionRule(id: rule.id)
                } catch {
                    Self.logger.error("Failed to delete exclusion rule \(rule.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    lastError = error.localizedDescription
                }
            }
        }
    }

    /// Returns whether a string is a valid `NSRegularExpression` pattern.
    func isValidRegex(_ pattern: String) -> Bool {
        guard !pattern.isEmpty else { return true }
        return (try? NSRegularExpression(pattern: pattern)) != nil
    }

    // MARK: - Data management

    private func loadDatabaseSize() async {
        guard let storage else { return }
        do {
            databaseFileSizeBytes = try await storage.databaseFileSizeBytes()
        } catch {
            Self.logger.error("Failed to read DB size: \(error.localizedDescription, privacy: .public)")
        }
    }

    func exportDatabase() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "kerwan-backup.db"
        panel.allowedContentTypes = [.init(filenameExtension: "db") ?? .data]
        panel.message = "Choose a location to save your Kerwan database backup."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let storage else { return }
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                try await storage.exportDatabase(to: url)
                Self.logger.debug("Database exported to \(url.path, privacy: .public)")
            } catch {
                Self.logger.error("Export failed: \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription
            }
        }
    }

    func deleteDataBefore() {
        guard let storage else { return }
        Task {
            do {
                try await storage.deleteDataBefore(deleteBeforeDate)
                await loadDatabaseSize()
                Self.logger.debug("Deleted data before \(self.deleteBeforeDate, privacy: .public)")
            } catch {
                Self.logger.error("Delete-before failed: \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription
            }
        }
    }

    func deleteAllData() {
        guard let storage else { return }
        isConfirmingDeleteAll = false
        Task {
            do {
                try await storage.deleteAllData()
                await loadDatabaseSize()
                Self.logger.debug("All data deleted")
            } catch {
                Self.logger.error("Delete-all failed: \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Helpers

    private func digestTimeDate(from string: String) -> Date {
        let parts = string.split(separator: ":")
        let h = Int(parts.first ?? "9") ?? 9
        let m = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = h
        comps.minute = m
        return Calendar.current.date(from: comps) ?? Date()
    }
}
