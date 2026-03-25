import Foundation

/// Typed errors produced by ``LicenseManager`` and related license operations.
enum LicenseError: Error, Sendable {

    /// The license server could not be reached (offline, timeout, DNS failure).
    case networkUnavailable

    /// The server's TLS certificate did not match any pinned hash.
    ///
    /// Treated identically to ``networkUnavailable`` at the call-site:
    /// the 7-day cached validation is used instead.
    case certificatePinningFailed

    /// The server returned an HTTP status code that is not handled explicitly.
    case invalidResponse(Int)

    /// The license key was rejected by the backend as invalid, expired, or
    /// already bound to a different machine.
    case invalidKey

    /// No license key is present in the Keychain.
    case keyNotFound

    /// A serialised value (cache or response body) could not be decoded.
    case decodingFailed(String)

    /// The backend returned a structured error message.
    case backendError(String)
}

// MARK: - LocalizedError

extension LicenseError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            return "Could not reach the license server. Your cached license will be used if available."
        case .certificatePinningFailed:
            return "The license server's certificate did not match the expected fingerprint."
        case .invalidResponse(let code):
            return "License server returned an unexpected response (HTTP \(code))."
        case .invalidKey:
            return "This license key is invalid, expired, or already bound to a different machine."
        case .keyNotFound:
            return "No license key found. Activate Kerwan to unlock paid features."
        case .decodingFailed(let reason):
            return "Failed to decode license data: \(reason)"
        case .backendError(let message):
            return "License server error: \(message)"
        }
    }
}
