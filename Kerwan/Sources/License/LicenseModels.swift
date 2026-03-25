import Foundation

// MARK: - LicenseFeatures

/// The set of capabilities the current license grants to the user.
///
/// ``LicenseFeatures/free`` is the baseline applied whenever no valid license
/// is present. All paid flags default to `false` on the free tier.
public struct LicenseFeatures: Codable, Sendable, Equatable {

    /// When `true`, Ollama LLM classification, promise extraction, and embedding
    /// generation are active. When `false`, ``ClassificationActor`` skips its
    /// drain cycle and events are stored as raw captures only.
    public let llm: Bool

    /// When `true`, interaction history and raw events are retained indefinitely.
    /// When `false`, ``StorageActor`` prunes records older than 30 days.
    public let unlimitedHistory: Bool

    /// When `true`, the CRM export feature (CSV / HubSpot push) is available.
    public let crmExport: Bool

    /// When `true`, multi-seat team sharing and shared client timelines are
    /// available.
    public let teamSharing: Bool

    /// The plan identifier returned by the backend (e.g. `"free"`, `"pro"`,
    /// `"team"`). Used for display and analytics only.
    public let plan: String

    // MARK: - Well-known instances

    /// Free-tier defaults: all paid flags `false`, plan = `"free"`.
    public static let free = LicenseFeatures(
        llm: false,
        unlimitedHistory: false,
        crmExport: false,
        teamSharing: false,
        plan: "free"
    )
}

// MARK: - LicenseCacheEntry

/// A snapshot of a successful license-validation response persisted in the Keychain
/// as a JSON-encoded string under ``KeychainItem/licenseCache``.
///
/// Valid for ``LicenseManager/cacheExpiryInterval`` (7 days) after ``validatedAt``.
/// Stale entries trigger a free-tier fallback without clearing the stored key.
struct LicenseCacheEntry: Codable, Sendable {

    /// Features granted by the backend on the last successful validation.
    let features: LicenseFeatures

    /// UTC timestamp of the network validation call that produced this entry.
    let validatedAt: Date

    /// UTC timestamp after which this entry must no longer be trusted.
    let expiresAt: Date

    /// The license key that was validated. Used to detect key changes between
    /// cache writes (e.g. after calling ``LicenseManager/activate(key:)``).
    let licenseKey: String

    /// Backend-reported expiry of the license itself.
    /// `nil` for perpetual licences or active subscriptions.
    let licenseExpiresAt: Date?
}

// MARK: - Network request / response

/// Request body for `POST /api/license/validate`.
struct LicenseValidationRequest: Encodable, Sendable {

    /// The license key to validate.
    let licenseKey: String

    /// Hardware UUID of the machine (stable across reinstalls; see
    /// ``MachineIdentifier/hardwareUUID()``).
    let machineId: String

    /// Short version string of the running app (e.g. `"1.0.0"`).
    let appVersion: String

    private enum CodingKeys: String, CodingKey {
        case licenseKey = "license_key"
        case machineId  = "machine_id"
        case appVersion = "app_version"
    }
}

/// Response body from `POST /api/license/validate`.
struct LicenseValidationResponse: Decodable, Sendable {

    /// Whether the supplied key is valid for this machine.
    let valid: Bool

    /// Human-readable message (e.g. error reason, plan label). May be `nil`.
    let message: String?

    /// Feature set to apply. Present only when `valid == true`.
    let features: LicenseFeatures?

    /// Backend-reported expiry of the license key itself. `nil` = perpetual /
    /// active subscription.
    let expiresAt: Date?

    private enum CodingKeys: String, CodingKey {
        case valid
        case message
        case features
        case expiresAt = "expires_at"
    }
}
