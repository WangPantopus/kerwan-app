// GmailOAuthManagerTests.swift
// Kerwan — Email tests
//
// Full coverage of the Gmail OAuth flow using entirely in-process mocks.
// No network calls, no Keychain access, no browser opening, no NWListener.
//
// Test groups
// ───────────
//  GmailAccountTests            — model encoding/decoding
//  GmailOAuthErrorTests          — error equatability
//  KeychainManagerUnitTests      — save / load / delete via MockKeychain
//  OAuthCallbackServerTests      — success, timeout, denial, stop counter
//  GmailOAuthManagerFlowTests    — happy path, state mismatch, timeout,
//                                   denial, network errors, retry, revoked
//                                   token, cached token, disconnect, persistence

import XCTest
@testable import Kerwan

// MARK: - Shared reference-type recorders

/// Thread-safe list for observing side-effecting calls (URL opens, etc.)
final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [T] = []

    var values: [T] { lock.withLock { _values } }

    func record(_ value: T) { lock.withLock { _values.append(value) } }
}

// MARK: - MockCallbackServer

/// An actor that immediately resolves `waitForCallback` with a pre-canned result.
actor MockCallbackServer: OAuthCallbackServing {
    enum Behaviour {
        case success(code: String, state: String)
        case failure(GmailOAuthError)
    }

    var behaviour: Behaviour
    private(set) var stopCallCount = 0

    init(_ behaviour: Behaviour) { self.behaviour = behaviour }

    func waitForCallback(timeout: TimeInterval) async throws -> OAuthCallbackResult {
        switch behaviour {
        case .success(let code, let state):
            return OAuthCallbackResult(code: code, state: state)
        case .failure(let err):
            throw err
        }
    }

    func stop() async { stopCallCount += 1 }
}

// MARK: - MockKeychain

/// In-memory Keychain replacement.
final class MockKeychain: KeychainManaging, @unchecked Sendable {
    private var store: [String: String] = [:]
    private let lock = NSLock()

    private(set) var saveCallCount   = 0
    private(set) var loadCallCount   = 0
    private(set) var deleteCallCount = 0

    func save(refreshToken: String, for email: String) throws {
        lock.withLock {
            saveCallCount += 1
            store[email] = refreshToken
        }
    }

    func load(for email: String) throws -> String {
        lock.withLock { loadCallCount += 1 }
        guard let token = lock.withLock({ store[email] }) else {
            throw GmailOAuthError.keychainError(errSecItemNotFound)
        }
        return token
    }

    func delete(for email: String) throws {
        lock.withLock {
            deleteCallCount += 1
            store.removeValue(forKey: email)
        }
    }
}

// MARK: - MockHTTPClient

/// Records requests and returns pre-canned responses.
final class MockHTTPClient: @unchecked Sendable {
    struct Response {
        let data:       Data
        let statusCode: Int
    }

    private var responses: [Response] = []
    private(set) var requestedURLs: [URL] = []
    private let lock = NSLock()

    func enqueue(_ response: Response) {
        lock.withLock { responses.append(response) }
    }

    func enqueueJSON(_ dict: [String: Any], statusCode: Int = 200) {
        let data = try! JSONSerialization.data(withJSONObject: dict)
        enqueue(Response(data: data, statusCode: statusCode))
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { if let url = request.url { requestedURLs.append(url) } }
        let resp: Response = try lock.withLock {
            guard !responses.isEmpty else { throw URLError(.networkConnectionLost) }
            return responses.removeFirst()
        }
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: resp.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (resp.data, http)
    }
}

// MARK: - Environment factory

extension GmailOAuthManager.Environment {
    /// Builds a fully-mocked environment for unit tests.
    ///
    /// Side-effect recorders (`openedURLRecorder`, `persistedEmailsRecorder`) are
    /// reference types — reads stay valid after the environment is passed around.
    static func mock(
        server:                any OAuthCallbackServing = MockCallbackServer(.success(code: "CODE", state: "TEST_STATE")),
        http:                  MockHTTPClient           = MockHTTPClient(),
        keychain:              MockKeychain             = MockKeychain(),
        state:                 String                   = "TEST_STATE",
        now:                   Date                     = Date(timeIntervalSince1970: 1_000_000),
        openedURLRecorder:     Recorder<URL>            = Recorder(),
        persistedEmailsRecorder: Recorder<[String]>    = Recorder(),
        initialEmails:         [String]                 = []
    ) -> GmailOAuthManager.Environment {

        let serverCapture = server
        let httpCapture   = http
        let keychainCapture = keychain
        var currentEmails = initialEmails

        return GmailOAuthManager.Environment(
            openURL: { url in openedURLRecorder.record(url) },
            makeCallbackServer: { serverCapture },
            dataTask: { request in try await httpCapture.perform(request) },
            keychainSave:   { token, email in try keychainCapture.save(refreshToken: token, for: email) },
            keychainLoad:   { email in try keychainCapture.load(for: email) },
            keychainDelete: { email in try keychainCapture.delete(for: email) },
            loadPersistedEmails: { currentEmails },
            persistEmails: { emails in
                currentEmails = emails
                persistedEmailsRecorder.record(emails)
            },
            generateState: { state },
            currentDate: { now },
            loadConfig: {
                GoogleOAuthConfig(
                    clientID:     "TEST_CLIENT_ID",
                    clientSecret: "TEST_CLIENT_SECRET",
                    redirectURI:  "http://localhost:8089/callback"
                )
            }
        )
    }
}

// MARK: - GmailAccountTests

final class GmailAccountTests: XCTestCase {

    func test_encodeDecode_roundTrip() throws {
        let now = Date(timeIntervalSince1970: 9000)
        let account = GmailAccount(
            email:          "user@gmail.com",
            refreshToken:   "rt_abc",
            accessToken:    "at_xyz",
            tokenExpiresAt: now
        )
        let data    = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(GmailAccount.self, from: data)

        XCTAssertEqual(decoded.email,          account.email)
        XCTAssertEqual(decoded.refreshToken,   account.refreshToken)
        XCTAssertEqual(decoded.accessToken,    account.accessToken)
        XCTAssertEqual(decoded.tokenExpiresAt?.timeIntervalSince1970 ?? 0,
                       account.tokenExpiresAt?.timeIntervalSince1970 ?? 0,
                       accuracy: 0.001)
    }

    func test_optionalFields_defaultNil() throws {
        let account = GmailAccount(email: "a@b.com", refreshToken: "rt")
        let data    = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(GmailAccount.self, from: data)
        XCTAssertNil(decoded.accessToken)
        XCTAssertNil(decoded.tokenExpiresAt)
    }

    func test_equatability() {
        let a = GmailAccount(email: "x@y.com", refreshToken: "r1")
        let b = GmailAccount(email: "x@y.com", refreshToken: "r1")
        let c = GmailAccount(email: "z@y.com", refreshToken: "r1")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}

// MARK: - GmailOAuthErrorTests

final class GmailOAuthErrorTests: XCTestCase {

    func test_errorEquatability() {
        XCTAssertEqual(GmailOAuthError.flowTimeout,       .flowTimeout)
        XCTAssertEqual(GmailOAuthError.stateMismatch,     .stateMismatch)
        XCTAssertEqual(GmailOAuthError.tokenRevoked,      .tokenRevoked)
        XCTAssertEqual(GmailOAuthError.maxRetriesExceeded, .maxRetriesExceeded)
        XCTAssertEqual(GmailOAuthError.keychainError(-25300), .keychainError(-25300))
        XCTAssertNotEqual(GmailOAuthError.keychainError(-25300), .keychainError(-25299))
        XCTAssertEqual(GmailOAuthError.authorizationDenied("access_denied"),
                       .authorizationDenied("access_denied"))
        XCTAssertNotEqual(GmailOAuthError.authorizationDenied("x"), .authorizationDenied("y"))
    }
}

// MARK: - KeychainManagerUnitTests

final class KeychainManagerUnitTests: XCTestCase {

    func test_saveLoadDelete_roundTrip() throws {
        let kc    = MockKeychain()
        let email = "kc_test@gmail.com"

        try kc.save(refreshToken: "tok123", for: email)
        XCTAssertEqual(try kc.load(for: email), "tok123")

        try kc.delete(for: email)
        XCTAssertThrowsError(try kc.load(for: email))
    }

    func test_saveOverwrite_returnsLatestValue() throws {
        let kc    = MockKeychain()
        let email = "overwrite@gmail.com"

        try kc.save(refreshToken: "first",  for: email)
        try kc.save(refreshToken: "second", for: email)
        XCTAssertEqual(try kc.load(for: email), "second")
    }

    func test_deleteNonExistent_doesNotThrow() {
        XCTAssertNoThrow(try MockKeychain().delete(for: "nobody@gmail.com"))
    }

    func test_loadMissing_throwsKeychainError() {
        XCTAssertThrowsError(try MockKeychain().load(for: "missing@gmail.com")) { error in
            guard case GmailOAuthError.keychainError = error else {
                XCTFail("Expected keychainError, got \(error)"); return
            }
        }
    }
}

// MARK: - OAuthCallbackServerTests (mock-only, no real NWListener)

final class OAuthCallbackServerTests: XCTestCase {

    func test_successCallback_returnsParsedResult() async throws {
        let server = MockCallbackServer(.success(code: "CODE_1", state: "ST_1"))
        let result = try await server.waitForCallback(timeout: 5)
        XCTAssertEqual(result.code,  "CODE_1")
        XCTAssertEqual(result.state, "ST_1")
    }

    func test_flowTimeout_throwsCorrectError() async throws {
        let server = MockCallbackServer(.failure(.flowTimeout))
        await XCTAssertThrowsErrorAsync(try await server.waitForCallback(timeout: 0.01)) { error in
            XCTAssertEqual(error as? GmailOAuthError, .flowTimeout)
        }
    }

    func test_authorizationDenied_throwsCorrectError() async throws {
        let server = MockCallbackServer(.failure(.authorizationDenied("access_denied")))
        await XCTAssertThrowsErrorAsync(try await server.waitForCallback(timeout: 5)) { error in
            XCTAssertEqual(error as? GmailOAuthError, .authorizationDenied("access_denied"))
        }
    }

    func test_stop_incrementsCounter() async {
        let server = MockCallbackServer(.success(code: "x", state: "y"))
        await server.stop()
        await server.stop()
        let count = await server.stopCallCount
        XCTAssertEqual(count, 2)
    }
}

// MARK: - XCTest async-throw helper

/// Async-capable `XCTAssertThrowsError`.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error to be thrown. \(message)", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

// MARK: - GmailOAuthManagerFlowTests

@MainActor
final class GmailOAuthManagerFlowTests: XCTestCase {

    // MARK: Helpers

    private func makeManager(
        server:   (any OAuthCallbackServing)? = nil,
        http:     MockHTTPClient              = MockHTTPClient(),
        keychain: MockKeychain                = MockKeychain(),
        state:    String                      = "TEST_STATE",
        now:      Date                        = Date(timeIntervalSince1970: 1_000_000)
    ) -> (GmailOAuthManager, MockHTTPClient, MockKeychain, Recorder<URL>) {

        let urlRecorder = Recorder<URL>()
        let effectiveServer: any OAuthCallbackServing = server ??
            MockCallbackServer(.success(code: "AUTH_CODE", state: state))

        let env = GmailOAuthManager.Environment.mock(
            server:            effectiveServer,
            http:              http,
            keychain:          keychain,
            state:             state,
            now:               now,
            openedURLRecorder: urlRecorder
        )
        return (GmailOAuthManager(environment: env), http, keychain, urlRecorder)
    }

    private func enqueueHappyPathResponses(_ http: MockHTTPClient, email: String = "alice@gmail.com") {
        http.enqueueJSON([
            "access_token":  "AT_NEW",
            "expires_in":    3600,
            "refresh_token": "RT_NEW",
            "token_type":    "Bearer"
        ])
        http.enqueueJSON(["email": email, "sub": "123"])
    }

    // MARK: Happy path

    func test_startOAuthFlow_happyPath_returnsAccount() async throws {
        let http = MockHTTPClient()
        enqueueHappyPathResponses(http)
        let (manager, _, keychain, _) = makeManager(http: http)

        let account = try await manager.startOAuthFlow()

        XCTAssertEqual(account.email,        "alice@gmail.com")
        XCTAssertEqual(account.accessToken,  "AT_NEW")
        XCTAssertEqual(account.refreshToken, "RT_NEW")
        XCTAssertNotNil(account.tokenExpiresAt)

        XCTAssertEqual(keychain.saveCallCount, 1)
        XCTAssertEqual(try keychain.load(for: "alice@gmail.com"), "RT_NEW")
        XCTAssertTrue(manager.connectedAccounts.contains { $0.email == "alice@gmail.com" })
    }

    func test_startOAuthFlow_browserOpened_withGoogleURL() async throws {
        let http        = MockHTTPClient()
        let urlRecorder = Recorder<URL>()
        enqueueHappyPathResponses(http)

        let server = MockCallbackServer(.success(code: "CODE", state: "S1"))
        let env = GmailOAuthManager.Environment.mock(
            server:            server,
            http:              http,
            state:             "S1",
            openedURLRecorder: urlRecorder
        )
        let manager = GmailOAuthManager(environment: env)
        _ = try await manager.startOAuthFlow()

        XCTAssertFalse(urlRecorder.values.isEmpty)
        XCTAssertTrue(urlRecorder.values[0].absoluteString.contains("accounts.google.com"))
    }

    // MARK: State mismatch

    func test_startOAuthFlow_stateMismatch_throwsStateMismatch() async throws {
        let wrongServer = MockCallbackServer(.success(code: "CODE", state: "WRONG"))
        let (manager, _, _, _) = makeManager(server: wrongServer, state: "CORRECT")

        await XCTAssertThrowsErrorAsync(try await manager.startOAuthFlow()) { error in
            XCTAssertEqual(error as? GmailOAuthError, .stateMismatch)
        }
    }

    // MARK: Flow timeout

    func test_startOAuthFlow_timeout_throwsFlowTimeout() async throws {
        let (manager, _, _, _) = makeManager(
            server: MockCallbackServer(.failure(.flowTimeout))
        )
        await XCTAssertThrowsErrorAsync(try await manager.startOAuthFlow()) { error in
            XCTAssertEqual(error as? GmailOAuthError, .flowTimeout)
        }
    }

    // MARK: Authorization denial

    func test_startOAuthFlow_denied_throwsAuthorizationDenied() async throws {
        let (manager, _, _, _) = makeManager(
            server: MockCallbackServer(.failure(.authorizationDenied("access_denied")))
        )
        await XCTAssertThrowsErrorAsync(try await manager.startOAuthFlow()) { error in
            XCTAssertEqual(error as? GmailOAuthError, .authorizationDenied("access_denied"))
        }
    }

    // MARK: Network error on token exchange

    func test_startOAuthFlow_networkError_throwsNetworkError() async throws {
        // No responses queued → URLError → wrapped as .networkError
        let (manager, _, _, _) = makeManager(http: MockHTTPClient())

        await XCTAssertThrowsErrorAsync(try await manager.startOAuthFlow()) { error in
            if case GmailOAuthError.networkError = error { /* expected */ }
            else { XCTFail("Expected networkError, got \(error)") }
        }
    }

    // MARK: Missing refresh token

    func test_startOAuthFlow_missingRefreshToken_throwsInvalidTokenResponse() async throws {
        let http = MockHTTPClient()
        http.enqueueJSON(["access_token": "AT", "expires_in": 3600, "token_type": "Bearer"])
        let (manager, _, _, _) = makeManager(http: http)

        await XCTAssertThrowsErrorAsync(try await manager.startOAuthFlow()) { error in
            if case GmailOAuthError.invalidTokenResponse = error { /* expected */ }
            else { XCTFail("Expected invalidTokenResponse, got \(error)") }
        }
    }

    // MARK: getValidAccessToken — cached fresh token

    func test_getValidAccessToken_cachedFresh_returnsCachedToken() async throws {
        let now    = Date(timeIntervalSince1970: 1_000_000)
        let future = now.addingTimeInterval(300)
        let account = GmailAccount(email: "b@g.com", refreshToken: "RT",
                                    accessToken: "CACHED_AT", tokenExpiresAt: future)

        let http = MockHTTPClient()
        let (manager, _, _, _) = makeManager(http: http, now: now)
        let token = try await manager.getValidAccessToken(for: account)

        XCTAssertEqual(token, "CACHED_AT")
        XCTAssertEqual(http.requestedURLs.count, 0)
    }

    // MARK: getValidAccessToken — expired, refreshes

    func test_getValidAccessToken_expiredToken_performsRefresh() async throws {
        let now     = Date(timeIntervalSince1970: 1_000_000)
        let past    = now.addingTimeInterval(-10)
        let account = GmailAccount(email: "c@g.com", refreshToken: "RT_OLD",
                                    accessToken: "OLD_AT", tokenExpiresAt: past)

        let keychain = MockKeychain()
        try keychain.save(refreshToken: "RT_OLD", for: "c@g.com")

        let http = MockHTTPClient()
        http.enqueueJSON(["access_token": "NEW_AT", "expires_in": 3600, "token_type": "Bearer"])

        let (manager, _, _, _) = makeManager(http: http, keychain: keychain, now: now)
        let token = try await manager.getValidAccessToken(for: account)
        XCTAssertEqual(token, "NEW_AT")
    }

    // MARK: Retry with back-off

    func test_getValidAccessToken_retriesOnNetworkError_succeedsOnThirdAttempt() async throws {
        let now     = Date(timeIntervalSince1970: 1_000_000)
        let past    = now.addingTimeInterval(-10)
        let account = GmailAccount(email: "d@g.com", refreshToken: "RT",
                                    accessToken: nil, tokenExpiresAt: past)

        let keychain = MockKeychain()
        try keychain.save(refreshToken: "RT", for: "d@g.com")

        let http = MockHTTPClient()
        http.enqueueJSON(["error": "internal_error"], statusCode: 500)   // attempt 1
        http.enqueueJSON(["error": "internal_error"], statusCode: 500)   // attempt 2
        http.enqueueJSON(["access_token": "RETRY_AT", "expires_in": 3600, "token_type": "Bearer"]) // 3

        let (manager, _, _, _) = makeManager(http: http, keychain: keychain, now: now)
        let token = try await manager.getValidAccessToken(for: account)
        XCTAssertEqual(token, "RETRY_AT")
    }

    // MARK: Revoked token (invalid_grant)

    func test_getValidAccessToken_invalidGrant_throwsTokenRevoked_andCleansUp() async throws {
        let now     = Date(timeIntervalSince1970: 1_000_000)
        let past    = now.addingTimeInterval(-10)
        let account = GmailAccount(email: "e@g.com", refreshToken: "RT",
                                    accessToken: nil, tokenExpiresAt: past)

        let keychain = MockKeychain()
        try keychain.save(refreshToken: "RT", for: "e@g.com")

        let http = MockHTTPClient()
        http.enqueueJSON(
            ["error": "invalid_grant", "error_description": "Token has been revoked."],
            statusCode: 400
        )

        let (manager, _, _, _) = makeManager(http: http, keychain: keychain, now: now)

        await XCTAssertThrowsErrorAsync(try await manager.getValidAccessToken(for: account)) { error in
            XCTAssertEqual(error as? GmailOAuthError, .tokenRevoked)
        }
        XCTAssertEqual(keychain.deleteCallCount, 1)
        XCTAssertFalse(manager.connectedAccounts.contains { $0.email == "e@g.com" })
    }

    // MARK: maxRetriesExceeded

    func test_getValidAccessToken_allRetriesFail_throwsError() async throws {
        let now     = Date(timeIntervalSince1970: 1_000_000)
        let past    = now.addingTimeInterval(-10)
        let account = GmailAccount(email: "f@g.com", refreshToken: "RT",
                                    accessToken: nil, tokenExpiresAt: past)

        let keychain = MockKeychain()
        try keychain.save(refreshToken: "RT", for: "f@g.com")

        let http = MockHTTPClient()
        // All 3 attempts fail with 500.
        for _ in 0..<3 {
            http.enqueueJSON(["error": "server_error"], statusCode: 500)
        }

        let (manager, _, _, _) = makeManager(http: http, keychain: keychain, now: now)

        await XCTAssertThrowsErrorAsync(try await manager.getValidAccessToken(for: account)) { error in
            // Any error (network or maxRetries) is acceptable — not .tokenRevoked.
            XCTAssertNotEqual(error as? GmailOAuthError, .tokenRevoked)
        }
    }

    // MARK: disconnect

    func test_disconnect_removesAccountAndDeletesKeychain() async throws {
        let keychain = MockKeychain()
        try keychain.save(refreshToken: "RT", for: "g@g.com")

        let http = MockHTTPClient()
        http.enqueue(MockHTTPClient.Response(data: Data(), statusCode: 200))

        let (manager, _, _, _) = makeManager(http: http, keychain: keychain)
        let account = GmailAccount(email: "g@g.com", refreshToken: "RT", accessToken: "AT")
        try await manager.disconnect(account: account)

        XCTAssertFalse(manager.connectedAccounts.contains { $0.email == "g@g.com" })
        XCTAssertEqual(keychain.deleteCallCount, 1)
    }

    func test_disconnect_revocationFailure_stillRemovesAccount() async throws {
        let keychain = MockKeychain()
        try keychain.save(refreshToken: "RT", for: "h@g.com")

        // No revocation response — network error is swallowed.
        let (manager, _, _, _) = makeManager(http: MockHTTPClient(), keychain: keychain)
        let account = GmailAccount(email: "h@g.com", refreshToken: "RT", accessToken: "AT")
        try await manager.disconnect(account: account)

        XCTAssertFalse(manager.connectedAccounts.contains { $0.email == "h@g.com" })
    }

    // MARK: Configuration error

    func test_missingConfig_throwsMissingConfiguration() async throws {
        var env = GmailOAuthManager.Environment.mock()
        env.loadConfig = { throw GmailOAuthError.missingConfiguration("plist not found") }

        let manager = GmailOAuthManager(environment: env)
        await XCTAssertThrowsErrorAsync(try await manager.startOAuthFlow()) { error in
            if case GmailOAuthError.missingConfiguration = error { /* expected */ }
            else { XCTFail("Expected missingConfiguration, got \(error)") }
        }
    }

    // MARK: Persistence

    func test_persistence_emailsPersistedOnConnect() async throws {
        let http            = MockHTTPClient()
        let emailsRecorder  = Recorder<[String]>()
        enqueueHappyPathResponses(http)

        let env = GmailOAuthManager.Environment.mock(
            http:                    http,
            persistedEmailsRecorder: emailsRecorder
        )
        let manager = GmailOAuthManager(environment: env)
        _ = try await manager.startOAuthFlow()

        XCTAssertTrue(emailsRecorder.values.last?.contains("alice@gmail.com") ?? false)
    }

    func test_persistence_emailsRemovedOnDisconnect() async throws {
        let keychain        = MockKeychain()
        let emailsRecorder  = Recorder<[String]>()
        try keychain.save(refreshToken: "RT", for: "i@g.com")

        let http = MockHTTPClient()
        http.enqueue(MockHTTPClient.Response(data: Data(), statusCode: 200))

        let env = GmailOAuthManager.Environment.mock(
            http:                    http,
            keychain:                keychain,
            persistedEmailsRecorder: emailsRecorder,
            initialEmails:           ["i@g.com"]
        )
        let manager = GmailOAuthManager(environment: env)
        let account = GmailAccount(email: "i@g.com", refreshToken: "RT", accessToken: "AT")
        try await manager.disconnect(account: account)

        XCTAssertFalse(emailsRecorder.values.last?.contains("i@g.com") ?? true)
    }
}
