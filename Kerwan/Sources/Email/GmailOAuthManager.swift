// GmailOAuthManager.swift
// Kerwan — Email capture layer
//
// Drives the full Google OAuth 2.0 authorization-code flow for Gmail access.
//
// Flow summary
// ────────────
//   startOAuthFlow()
//     1. Build authorization URL (PKCE not required for installed apps using
//        client_secret; use state for CSRF protection).
//     2. Open the URL in the default browser via NSWorkspace / Environment.openURL.
//     3. Wait for OAuthCallbackServer to receive the redirect on port 8089.
//     4. Verify state; exchange code for tokens via POST to token endpoint.
//     5. Fetch the user's email address from the userinfo endpoint.
//     6. Store refresh token in Keychain; return a GmailAccount.
//
//   getValidAccessToken(for:)
//     • Returns the cached token if it is still valid (> 60 s margin).
//     • Otherwise calls refreshAccessToken(for:) with up to 3 retries and
//       exponential back-off (1 s, 2 s, 4 s).
//     • On `invalid_grant`: revokes the account, deletes from Keychain, throws .tokenRevoked.
//
//   disconnect(account:)
//     • Calls the Google revocation endpoint, deletes the Keychain item.
//
// Configuration
// ─────────────
// Client credentials are read once from `GoogleOAuth.plist` (in the app
// bundle) under keys:
//     "client_id"     — OAuth client ID
//     "client_secret" — OAuth client secret
//     "redirect_uri"  — must be "http://localhost:8089/callback"
//
// Testability
// ───────────
// `Environment` replaces every external side-effect (URL opening, HTTP,
// Keychain, server creation, date, state generation) so all paths can be
// exercised in-process without a live Google API.

import AppKit
import Foundation
import os

// MARK: - GoogleOAuthConfig

/// Loaded from `GoogleOAuth.plist` in the main bundle.
struct GoogleOAuthConfig: Sendable {
    let clientID:     String
    let clientSecret: String
    let redirectURI:  String

    static let tokenEndpoint   = URL(string: "https://oauth2.googleapis.com/token")!
    static let authEndpoint    = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let userInfoEndpoint = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!
    static let revokeEndpoint  = URL(string: "https://oauth2.googleapis.com/revoke")!

    static let scopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "openid",
        "email"
    ]

    /// Loads from the named plist in `bundle` (default: main bundle).
    static func load(from bundle: Bundle = .main) throws -> GoogleOAuthConfig {
        guard let url = bundle.url(forResource: "GoogleOAuth", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: String]
        else {
            throw GmailOAuthError.missingConfiguration("GoogleOAuth.plist not found in bundle")
        }
        guard let clientID     = dict["client_id"], !clientID.isEmpty else {
            throw GmailOAuthError.missingConfiguration("client_id missing in GoogleOAuth.plist")
        }
        guard let clientSecret = dict["client_secret"], !clientSecret.isEmpty else {
            throw GmailOAuthError.missingConfiguration("client_secret missing in GoogleOAuth.plist")
        }
        guard let redirectURI  = dict["redirect_uri"], !redirectURI.isEmpty else {
            throw GmailOAuthError.missingConfiguration("redirect_uri missing in GoogleOAuth.plist")
        }
        return GoogleOAuthConfig(clientID: clientID, clientSecret: clientSecret, redirectURI: redirectURI)
    }
}

// MARK: - TokenResponse

/// Decoded body from the Google token endpoint.
private struct TokenResponse: Decodable {
    let access_token:  String
    let expires_in:    Int
    let refresh_token: String?
    let token_type:    String
}

// MARK: - UserInfoResponse

private struct UserInfoResponse: Decodable {
    let email: String
}

// MARK: - GmailOAuthManager

/// `@MainActor` class that manages the complete Gmail OAuth lifecycle.
///
/// Create one shared instance and inject it via `EnvironmentObject` or pass
/// it to capture services that need a valid access token.
@MainActor
public final class GmailOAuthManager: ObservableObject {

    // MARK: - Environment (injectable)

    public struct Environment: @unchecked Sendable {
        /// Opens a URL in the default browser.
        var openURL: @Sendable (URL) -> Void

        /// Creates a new callback server instance.
        var makeCallbackServer: @Sendable () -> any OAuthCallbackServing

        /// Performs an HTTP request and returns (Data, HTTPURLResponse).
        var dataTask: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

        /// Keychain operations.
        var keychainSave:   @Sendable (String, String) throws -> Void   // (token, email)
        var keychainLoad:   @Sendable (String) throws -> String          // (email) -> token
        var keychainDelete: @Sendable (String) throws -> Void            // (email)

        /// Returns persisted accounts (e.g. from UserDefaults).
        var loadPersistedEmails:  @Sendable () -> [String]
        /// Persists the list of connected account email addresses.
        var persistEmails:        @Sendable ([String]) -> Void

        /// CSRF state generation (injectable for deterministic testing).
        var generateState: @Sendable () -> String

        /// Current date (injectable for token-expiry tests).
        var currentDate: @Sendable () -> Date

        /// Loads the OAuth config (injectable to avoid bundle in tests).
        var loadConfig: @Sendable () throws -> GoogleOAuthConfig

        // MARK: Live environment

        public static let live = Environment(
            openURL: { url in
                NSWorkspace.shared.open(url)
            },
            makeCallbackServer: { OAuthCallbackServer() },
            dataTask: { request in
                let (data, response) = try await URLSession.shared.data(for: request)
                return (data, response as! HTTPURLResponse)
            },
            keychainSave: { token, email in
                try GmailKeychainManager().save(refreshToken: token, for: email)
            },
            keychainLoad: { email in
                try GmailKeychainManager().load(for: email)
            },
            keychainDelete: { email in
                try GmailKeychainManager().delete(for: email)
            },
            loadPersistedEmails: {
                UserDefaults.standard.stringArray(forKey: "kerwan.gmail.connectedEmails") ?? []
            },
            persistEmails: { emails in
                UserDefaults.standard.set(emails, forKey: "kerwan.gmail.connectedEmails")
            },
            generateState: {
                UUID().uuidString.replacingOccurrences(of: "-", with: "")
            },
            currentDate: { Date() },
            loadConfig: { try GoogleOAuthConfig.load() }
        )
    }

    // MARK: - Published state

    /// All currently connected Gmail accounts (access tokens are memory-only).
    @Published public private(set) var connectedAccounts: [GmailAccount] = []

    // MARK: - Private

    private let env: Environment
    private let log = Logger(subsystem: "com.kerwan.app", category: "GmailOAuthManager")

    // MARK: - Init

    public init(environment: Environment = .live) {
        self.env = environment
        self.connectedAccounts = env.loadPersistedEmails().map { email in
            GmailAccount(email: email, refreshToken: "")   // token loaded from Keychain on demand
        }
    }

    // MARK: - Public API

    /// Runs the full browser-based OAuth flow and returns a connected account.
    ///
    /// - Throws: `GmailOAuthError` on any failure.
    public func startOAuthFlow() async throws -> GmailAccount {
        let config = try env.loadConfig()
        let state  = env.generateState()

        // Build authorization URL.
        let authURL = try buildAuthURL(config: config, state: state)

        // Start callback server before opening the browser to avoid a race.
        let server = env.makeCallbackServer()
        env.openURL(authURL)

        log.info("OAuth flow started — awaiting callback on port 8089")

        let callback = try await server.waitForCallback(timeout: 300)

        guard callback.state == state else {
            log.error("OAuth CSRF state mismatch — expected \(state, privacy: .private)")
            throw GmailOAuthError.stateMismatch
        }

        // Exchange code for tokens.
        let tokenResponse = try await exchangeCode(callback.code, config: config)

        guard let refreshToken = tokenResponse.refresh_token else {
            throw GmailOAuthError.invalidTokenResponse("Missing refresh_token in response")
        }

        // Fetch user email.
        let accessToken = tokenResponse.access_token
        let email = try await fetchUserEmail(accessToken: accessToken)

        let expiresAt = env.currentDate().addingTimeInterval(TimeInterval(tokenResponse.expires_in))

        var account = GmailAccount(
            email:          email,
            refreshToken:   refreshToken,
            accessToken:    accessToken,
            tokenExpiresAt: expiresAt
        )

        // Persist refresh token in Keychain.
        try env.keychainSave(refreshToken, email)
        persistAccount(account)

        log.info("OAuth flow complete for \(email, privacy: .private)")
        return account
    }

    /// Returns a valid access token for `account`, refreshing if necessary.
    ///
    /// Retries the refresh up to 3 times with exponential back-off.
    /// On `invalid_grant`, the account is revoked and `.tokenRevoked` is thrown.
    public func getValidAccessToken(for account: GmailAccount) async throws -> String {
        let margin: TimeInterval = 60

        // Return cached token if still fresh.
        if let token     = account.accessToken,
           let expiresAt = account.tokenExpiresAt,
           env.currentDate().addingTimeInterval(margin) < expiresAt {
            return token
        }

        return try await refreshWithRetry(account: account)
    }

    /// Revokes the Google token, removes the account from Keychain and memory.
    public func disconnect(account: GmailAccount) async throws {
        let config = try env.loadConfig()

        // Best-effort revocation — don't throw if it fails.
        let tokenToRevoke = account.accessToken ?? account.refreshToken
        try? await revokeToken(tokenToRevoke, config: config)

        try env.keychainDelete(account.email)
        removeAccount(email: account.email)
        log.info("Disconnected Gmail account \(account.email, privacy: .private)")
    }

    // MARK: - Private: OAuth helpers

    private func buildAuthURL(config: GoogleOAuthConfig, state: String) throws -> URL {
        var components = URLComponents(url: GoogleOAuthConfig.authEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id",     value: config.clientID),
            URLQueryItem(name: "redirect_uri",  value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope",         value: GoogleOAuthConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type",   value: "offline"),
            URLQueryItem(name: "prompt",        value: "consent"),
            URLQueryItem(name: "state",         value: state)
        ]
        guard let url = components.url else {
            throw GmailOAuthError.missingConfiguration("Could not build authorization URL")
        }
        return url
    }

    private func exchangeCode(_ code: String, config: GoogleOAuthConfig) async throws -> TokenResponse {
        var request = URLRequest(url: GoogleOAuthConfig.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "code":          code,
            "client_id":     config.clientID,
            "client_secret": config.clientSecret,
            "redirect_uri":  config.redirectURI,
            "grant_type":    "authorization_code"
        ]
        request.httpBody = urlEncode(body)

        return try await performTokenRequest(request)
    }

    // MARK: - Private: token refresh with retry

    private func refreshWithRetry(account: GmailAccount) async throws -> String {
        let config = try env.loadConfig()

        // Load refresh token from Keychain (the struct field may be a placeholder).
        let storedRefreshToken: String
        do {
            storedRefreshToken = try env.keychainLoad(account.email)
        } catch {
            throw GmailOAuthError.tokenRevoked
        }

        let maxAttempts = 3
        var lastError: Error = GmailOAuthError.maxRetriesExceeded

        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                let delay = UInt64(pow(2.0, Double(attempt - 1)) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
            }

            do {
                let tokenResponse = try await performRefresh(
                    refreshToken: storedRefreshToken,
                    config: config
                )
                let expiresAt = env.currentDate().addingTimeInterval(TimeInterval(tokenResponse.expires_in))
                updateAccount(
                    email:       account.email,
                    accessToken: tokenResponse.access_token,
                    expiresAt:   expiresAt
                )
                return tokenResponse.access_token

            } catch GmailOAuthError.tokenRevoked {
                // Revoked tokens cannot be retried — clean up and surface the error.
                try? env.keychainDelete(account.email)
                removeAccount(email: account.email)
                throw GmailOAuthError.tokenRevoked

            } catch {
                lastError = error
                log.warning("Token refresh attempt \(attempt + 1) failed: \(error.localizedDescription)")
            }
        }

        throw lastError
    }

    private func performRefresh(refreshToken: String, config: GoogleOAuthConfig) async throws -> TokenResponse {
        var request = URLRequest(url: GoogleOAuthConfig.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "refresh_token": refreshToken,
            "client_id":     config.clientID,
            "client_secret": config.clientSecret,
            "grant_type":    "refresh_token"
        ]
        request.httpBody = urlEncode(body)

        return try await performTokenRequest(request)
    }

    private func performTokenRequest(_ request: URLRequest) async throws -> TokenResponse {
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await env.dataTask(request)
        } catch {
            throw GmailOAuthError.networkError(error.localizedDescription)
        }

        // Check for `invalid_grant` before attempting decode.
        if response.statusCode == 400,
           let body = try? JSONDecoder().decode([String: String].self, from: data),
           body["error"] == "invalid_grant" {
            throw GmailOAuthError.tokenRevoked
        }

        guard (200..<300).contains(response.statusCode) else {
            throw GmailOAuthError.networkError("HTTP \(response.statusCode)")
        }

        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw GmailOAuthError.invalidTokenResponse(error.localizedDescription)
        }
    }

    // MARK: - Private: userinfo

    private func fetchUserEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: GoogleOAuthConfig.userInfoEndpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await env.dataTask(request)
        } catch {
            throw GmailOAuthError.networkError(error.localizedDescription)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw GmailOAuthError.networkError("Userinfo HTTP \(response.statusCode)")
        }

        do {
            let userInfo = try JSONDecoder().decode(UserInfoResponse.self, from: data)
            return userInfo.email
        } catch {
            throw GmailOAuthError.invalidTokenResponse("Could not decode userinfo: \(error.localizedDescription)")
        }
    }

    // MARK: - Private: token revocation

    private func revokeToken(_ token: String, config: GoogleOAuthConfig) async throws {
        var components = URLComponents(url: GoogleOAuthConfig.revokeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try await env.dataTask(request)
    }

    // MARK: - Private: account list management

    private func persistAccount(_ account: GmailAccount) {
        if !connectedAccounts.contains(where: { $0.email == account.email }) {
            connectedAccounts.append(account)
        }
        env.persistEmails(connectedAccounts.map(\.email))
    }

    private func removeAccount(email: String) {
        connectedAccounts.removeAll { $0.email == email }
        env.persistEmails(connectedAccounts.map(\.email))
    }

    private func updateAccount(email: String, accessToken: String, expiresAt: Date) {
        guard let idx = connectedAccounts.firstIndex(where: { $0.email == email }) else { return }
        connectedAccounts[idx].accessToken    = accessToken
        connectedAccounts[idx].tokenExpiresAt = expiresAt
    }

    // MARK: - Private: URL encoding

    private func urlEncode(_ params: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }
}
