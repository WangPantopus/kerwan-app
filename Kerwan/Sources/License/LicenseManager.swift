import AppKit
import Foundation
import os
import KerwanKeychain

// MARK: - LicenseFeatureProvider

/// An actor that exposes the current license feature set.
///
/// Conform to this protocol rather than referencing ``LicenseManager`` directly
/// so that downstream components (e.g. ``ClassificationActor``) can be tested
/// with lightweight fakes.
protocol LicenseFeatureProvider: Actor {
    /// The features granted by the currently resolved license.
    ///
    /// Defaults to ``LicenseFeatures/free`` until a validation completes.
    var currentFeatures: LicenseFeatures { get }
}

// MARK: - LicenseManager

/// Manages license validation, Keychain persistence, cache, and feature gating.
///
/// ## Startup
///
/// Call ``validate()`` once from `AppLifecycle.start(...)`. The method
/// follows this fallback chain:
///
/// 1. Read license key from Keychain. If absent → apply free tier.
/// 2. `POST /api/license/validate`. If success → cache for 7 days and return features.
/// 3. Network / certificate-pinning error → use cached validation if < 7 days old.
/// 4. Cache expired or absent → apply free tier (capture continues unaffected).
///
/// ## Feature gating
///
/// Read ``currentFeatures`` from any actor:
/// ```swift
/// let features = await licenseManager.currentFeatures
/// guard features.llm else { return }
/// ```
///
/// ## Certificate pinning
///
/// All network requests use a ``LicensePinningDelegate`` URLSessionDelegate.
/// A pin mismatch results in `URLError.cancelled`, which is caught and
/// treated identically to a network outage.
///
/// ## Machine binding
///
/// Each validation request includes the machine's hardware UUID obtained via
/// ``MachineIdentifier/hardwareUUID()``. The backend enforces one active seat
/// per machine per license key.
public actor LicenseManager: LicenseFeatureProvider {

    // MARK: - Configuration

    /// Duration a cached validation result is trusted after it was written.
    static let cacheExpiryInterval: TimeInterval = 7 * 24 * 60 * 60   // 7 days

    /// Base URL of the Kerwan licensing backend.
    static let backendBaseURL = URL(string: "https://api.kerwan.app")!

    /// URL opened by ``openPurchasePage()``.
    static let purchaseURL = URL(string: "https://kerwan.app/pricing")!

    // MARK: - Logging

    private static let logger = Logger(subsystem: "com.kerwan.app", category: "LicenseManager")

    // MARK: - Dependencies

    private let keychain: KeychainManager
    private let session: URLSession
    private let machineId: String
    private let jsonDecoder: JSONDecoder
    private let jsonEncoder: JSONEncoder

    // MARK: - Public State

    /// The features enabled by the currently resolved license.
    ///
    /// ``ClassificationActor`` and the UI read this via the
    /// ``LicenseFeatureProvider`` protocol to gate paid behaviour.
    public private(set) var currentFeatures: LicenseFeatures = .free

    /// Whether the most recent validation (network or cache) succeeded.
    public private(set) var isValid: Bool = false

    /// The plan identifier from the last successful validation
    /// (e.g. `"free"`, `"pro"`, `"team"`).
    public private(set) var plan: String = "free"

    /// The backend-reported expiry of the license key itself, or `nil` for
    /// perpetual licences and active subscriptions.
    public private(set) var expiresAt: Date? = nil

    // MARK: - Init

    /// Creates a `LicenseManager`.
    ///
    /// - Parameters:
    ///   - keychain: Shared keychain manager used to persist the key and cache.
    ///   - urlSession: Override the URLSession. Inject a mock session (with a
    ///     registered `URLProtocol` subclass) in unit tests to avoid real
    ///     network calls and TLS. When `nil`, a production session with
    ///     ``LicensePinningDelegate`` is created automatically.
    public init(keychain: KeychainManager, urlSession: URLSession? = nil) {
        self.keychain = keychain
        self.machineId = MachineIdentifier.hardwareUUID()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.jsonDecoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.jsonEncoder = encoder

        if let urlSession {
            // Test / override path — no pinning delegate needed.
            self.session = urlSession
        } else {
            // Production path — attach the pinning delegate.
            let pinDelegate = LicensePinningDelegate()
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest  = 15
            config.timeoutIntervalForResource = 30
            self.session = URLSession(
                configuration: config,
                delegate: pinDelegate,
                delegateQueue: nil
            )
        }
    }

    // MARK: - Public API

    /// Resolves the stored license key and updates ``currentFeatures``.
    ///
    /// Safe to call multiple times; each call performs a fresh network attempt.
    ///
    /// - Returns: The resolved ``LicenseFeatures``.
    /// - Throws: ``LicenseError/invalidKey`` or ``LicenseError/backendError``
    ///   when the backend explicitly rejects the key. Network errors fall back
    ///   to the cache and never throw from this method.
    @discardableResult
    public func validate() async throws -> LicenseFeatures {
        // 1. Read the stored license key.
        guard let key = try await keychain.read(.licenseKey), !key.isEmpty else {
            Self.logger.info("No license key in Keychain — applying free tier")
            applyFreeTier()
            return .free
        }

        // 2. Attempt a live backend validation.
        do {
            let features = try await validateWithBackend(key: key)
            try await persistCache(features: features, key: key)
            applyFeatures(features, valid: true)
            Self.logger.info("License validated: plan=\(features.plan, privacy: .public)")
            return features
        } catch LicenseError.networkUnavailable {
            Self.logger.warning("Network unavailable — checking cache")
            return await resolveFromCache(key: key)
        } catch LicenseError.certificatePinningFailed {
            Self.logger.warning("Certificate pin failed — checking cache")
            return await resolveFromCache(key: key)
        }
        // LicenseError.invalidKey / .backendError / others propagate to the caller.
    }

    /// Activates a new license key.
    ///
    /// The key is validated with the backend **before** being stored in the
    /// Keychain. Throws if the key is rejected or the network is unavailable.
    ///
    /// - Parameter key: The raw license key string entered by the user.
    /// - Returns: The ``LicenseFeatures`` granted by the new license.
    @discardableResult
    public func activate(key: String) async throws -> LicenseFeatures {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LicenseError.invalidKey }

        // Validate first; only persist on success.
        let features = try await validateWithBackend(key: trimmed)

        try await keychain.write(.licenseKey, value: trimmed)
        try await persistCache(features: features, key: trimmed)
        applyFeatures(features, valid: true)

        Self.logger.info("License activated: plan=\(features.plan, privacy: .public)")
        return features
    }

    /// Deactivates the current license, clearing the stored key and cache.
    ///
    /// ``currentFeatures`` reverts to ``LicenseFeatures/free`` immediately.
    public func deactivate() async throws {
        try await keychain.delete(.licenseKey)
        try await keychain.delete(.licenseCache)
        applyFreeTier()
        Self.logger.info("License deactivated")
    }

    /// Opens the Kerwan pricing page in the system default browser.
    public func openPurchasePage() {
        let url = Self.purchaseURL
        Task { @MainActor in
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Private: Backend

    /// POSTs to `/api/license/validate` and returns the granted feature set.
    ///
    /// - Throws: ``LicenseError/networkUnavailable`` on connectivity failures.
    /// - Throws: ``LicenseError/certificatePinningFailed`` when the challenge
    ///   is cancelled by ``LicensePinningDelegate``.
    /// - Throws: ``LicenseError/invalidKey`` on 401 / 402 / 403 / 404.
    /// - Throws: ``LicenseError/invalidResponse`` for any other HTTP status.
    private func validateWithBackend(key: String) async throws -> LicenseFeatures {
        let url = Self.backendBaseURL.appendingPathComponent("api/license/validate")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let appVersion = Bundle.main
            .infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let body = LicenseValidationRequest(
            licenseKey: key,
            machineId: machineId,
            appVersion: appVersion
        )
        do {
            request.httpBody = try jsonEncoder.encode(body)
        } catch {
            throw LicenseError.decodingFailed("Failed to encode request: \(error)")
        }

        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            let (d, r) = try await session.data(for: request)
            guard let h = r as? HTTPURLResponse else {
                throw LicenseError.networkUnavailable
            }
            data = d
            httpResponse = h
        } catch let licenseErr as LicenseError {
            throw licenseErr
        } catch let urlErr as URLError {
            // URLError.cancelled is the signal from LicensePinningDelegate when
            // the server's certificate hash does not match.
            if urlErr.code == .cancelled {
                Self.logger.warning(
                    "URLSession cancelled — treating as certificate pin failure"
                )
                throw LicenseError.certificatePinningFailed
            }
            Self.logger.warning(
                "Network error (\(urlErr.code.rawValue)): \(urlErr.localizedDescription, privacy: .public)"
            )
            throw LicenseError.networkUnavailable
        } catch {
            Self.logger.warning(
                "Unexpected session error: \(error.localizedDescription, privacy: .public)"
            )
            throw LicenseError.networkUnavailable
        }

        switch httpResponse.statusCode {
        case 200:
            let response: LicenseValidationResponse
            do {
                response = try jsonDecoder.decode(LicenseValidationResponse.self, from: data)
            } catch {
                throw LicenseError.decodingFailed(error.localizedDescription)
            }
            guard response.valid, let features = response.features else {
                let reason = response.message ?? "License rejected by server"
                Self.logger.warning("Backend rejected key: \(reason, privacy: .public)")
                throw LicenseError.invalidKey
            }
            // Carry the backend-reported license expiry into the actor state.
            expiresAt = response.expiresAt
            return features

        case 401, 402, 403, 404:
            throw LicenseError.invalidKey

        case 429:
            // Rate-limited — treat as transient network unavailability.
            Self.logger.warning("Rate limited by license server (429)")
            throw LicenseError.networkUnavailable

        default:
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            Self.logger.error(
                "Backend error HTTP \(httpResponse.statusCode): \(body.prefix(200), privacy: .public)"
            )
            throw LicenseError.invalidResponse(httpResponse.statusCode)
        }
    }

    // MARK: - Private: Cache

    /// Reads the Keychain cache and applies the result, falling back to free tier.
    ///
    /// Never throws — all failures degrade to the free tier.
    private func resolveFromCache(key: String) async -> LicenseFeatures {
        guard
            let json = try? await keychain.read(.licenseCache),
            let data = json.data(using: .utf8)
        else {
            Self.logger.info("No license cache found — applying free tier")
            applyFreeTier()
            return .free
        }

        let entry: LicenseCacheEntry
        do {
            entry = try jsonDecoder.decode(LicenseCacheEntry.self, from: data)
        } catch {
            Self.logger.warning("Cache decode failed (\(error.localizedDescription)) — applying free tier")
            applyFreeTier()
            return .free
        }

        // Reject cache entries from a different key (e.g. after key change).
        guard entry.licenseKey == key else {
            Self.logger.info("Cache key mismatch — applying free tier")
            applyFreeTier()
            return .free
        }

        if Date() < entry.expiresAt {
            Self.logger.info(
                "Using cached license — plan=\(entry.features.plan, privacy: .public) expires=\(entry.expiresAt, privacy: .public)"
            )
            applyFeatures(entry.features, valid: true)
            expiresAt = entry.licenseExpiresAt
            return entry.features
        } else {
            // Cache is older than 7 days: disable paid features but keep running.
            Self.logger.warning(
                "License cache expired at \(entry.expiresAt, privacy: .public) — applying free tier (capture continues)"
            )
            applyFreeTier()
            return .free
        }
    }

    /// Serialises and writes a validation result to the Keychain cache.
    private func persistCache(features: LicenseFeatures, key: String) async throws {
        let entry = LicenseCacheEntry(
            features: features,
            validatedAt: Date(),
            expiresAt: Date(timeIntervalSinceNow: Self.cacheExpiryInterval),
            licenseKey: key,
            licenseExpiresAt: expiresAt
        )
        let data: Data
        do {
            data = try jsonEncoder.encode(entry)
        } catch {
            throw LicenseError.decodingFailed("Cannot encode cache entry: \(error)")
        }
        guard let json = String(data: data, encoding: .utf8) else {
            throw LicenseError.decodingFailed("Cache entry produced non-UTF-8 JSON")
        }
        try await keychain.write(.licenseCache, value: json)
        Self.logger.debug("License cache persisted (valid for 7 days)")
    }

    // MARK: - Private: State helpers

    private func applyFreeTier() {
        currentFeatures = .free
        isValid         = false
        plan            = "free"
        expiresAt       = nil
    }

    private func applyFeatures(_ features: LicenseFeatures, valid: Bool) {
        currentFeatures = features
        isValid         = valid
        plan            = features.plan
    }
}
