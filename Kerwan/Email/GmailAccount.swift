// GmailAccount.swift
// Kerwan — Email capture layer
//
// Data model for a connected Gmail account and the error types used
// throughout the OAuth 2.0 authorization flow.

import Foundation

// MARK: - GmailAccount

/// A connected Gmail account with its OAuth 2.0 credentials.
///
/// `refreshToken` is stored in the system Keychain; the struct itself is
/// safe to archive to UserDefaults (sans refresh token) for UI display.
public struct GmailAccount: Codable, Sendable, Equatable {

    /// The account's full email address (e.g. "alice@gmail.com").
    public let email: String

    /// Long-lived refresh token. Store in Keychain; never log.
    public let refreshToken: String

    /// Short-lived access token (nil until first successful refresh).
    public var accessToken: String?

    /// Wall-clock expiry of the current `accessToken` (nil until first refresh).
    public var tokenExpiresAt: Date?

    public init(
        email: String,
        refreshToken: String,
        accessToken: String? = nil,
        tokenExpiresAt: Date? = nil
    ) {
        self.email = email
        self.refreshToken = refreshToken
        self.accessToken = accessToken
        self.tokenExpiresAt = tokenExpiresAt
    }
}

// MARK: - GmailOAuthError

/// Errors produced by `GmailOAuthManager` and supporting types.
public enum GmailOAuthError: Error, Equatable, Sendable {

    /// The `GoogleOAuth.plist` file is absent or missing required keys.
    case missingConfiguration(String)

    /// The local HTTP server could not start on the callback port.
    case serverStartFailed(String)

    /// The user closed the browser or the OAuth flow timed out.
    case flowTimeout

    /// The authorization server returned a denial or an error parameter.
    case authorizationDenied(String)

    /// The CSRF `state` parameter in the callback does not match what we sent.
    case stateMismatch

    /// The token-exchange POST failed at the network layer.
    case networkError(String)

    /// The token-exchange response was not valid JSON or was missing fields.
    case invalidTokenResponse(String)

    /// The refresh token has been revoked (`invalid_grant` error from Google).
    case tokenRevoked

    /// A token-exchange or refresh request failed after all retry attempts.
    case maxRetriesExceeded

    /// The Keychain operation failed with the given OSStatus.
    case keychainError(Int32)
}
