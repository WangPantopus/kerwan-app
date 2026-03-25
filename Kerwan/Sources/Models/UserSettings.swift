import Foundation

/// User-configurable application settings persisted to the database.
///
/// `UserSettings` is stored as a single row in the `user_settings` table.
/// The ``defaults`` static property provides sensible starting values for
/// a fresh installation.
///
/// Settings are loaded into memory at launch by the ``StorageActor`` and
/// cached in ``AppState``. Writes go through ``StorageActor`` and are
/// applied immediately.
public struct UserSettings: Codable, Sendable, Hashable {
    /// Whether microphone / system audio capture is enabled.
    public var captureAudio: Bool

    /// Whether accessibility-based app focus tracking is enabled.
    public var captureAccessibility: Bool

    /// The time of day for the daily digest notification, in "HH:mm" format
    /// (24-hour clock, e.g., "09:00" for 9 AM).
    public var digestTime: String

    /// Default hourly billing rate (in the user's currency) used when a
    /// ``Project`` does not specify its own rate.
    public var billableDefaultRate: Double

    /// Whether the user has completed the initial consent flow acknowledging
    /// what data Kerwan captures and how it is stored.
    public var consentMode: Bool

    /// Whether the SQLCipher database passphrase is stored in the macOS Keychain.
    /// If false, the user is prompted for the passphrase at each launch.
    public var passphraseInKeychain: Bool

    /// Sensible defaults for a fresh Kerwan installation.
    public static let defaults = UserSettings(
        captureAudio: true,
        captureAccessibility: true,
        digestTime: "09:00",
        billableDefaultRate: 150.0,
        consentMode: false,
        passphraseInKeychain: true
    )

    public init(
        captureAudio: Bool,
        captureAccessibility: Bool,
        digestTime: String,
        billableDefaultRate: Double,
        consentMode: Bool,
        passphraseInKeychain: Bool
    ) {
        self.captureAudio = captureAudio
        self.captureAccessibility = captureAccessibility
        self.digestTime = digestTime
        self.billableDefaultRate = billableDefaultRate
        self.consentMode = consentMode
        self.passphraseInKeychain = passphraseInKeychain
    }
}
