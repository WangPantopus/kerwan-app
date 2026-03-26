import XCTest
@testable import Kerwan
import KerwanKeychain

// MARK: - MockURLProtocol

/// A URLProtocol subclass that intercepts all requests and returns synthetic
/// responses. Registered on an ephemeral URLSessionConfiguration so it
/// intercepts only sessions created with that configuration.
///
/// Set ``MockURLProtocol/handler`` before each test and nil it out in tearDown.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {

    /// The handler closure. Set this to return the desired (response, body) pair,
    /// or throw to simulate a network error.
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.notConnectedToInternet)
            )
            return
        }
        do {
            // URLSession converts httpBody → httpBodyStream when routing
            // through URLProtocol. Reconstruct httpBody so handlers can read it.
            var req = request
            if req.httpBody == nil, let stream = req.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bodyData = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    if n > 0 { bodyData.append(buffer, count: n) }
                }
                req.httpBody = bodyData
            }
            let (response, data) = try handler(req)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - LicenseManagerTests

final class LicenseManagerTests: XCTestCase {

    // MARK: - Helpers

    /// A unique Keychain service name per test run prevents pollution between runs.
    private let keychainService = "com.kerwan.test.license.\(UUID().uuidString)"
    private var keychain: KeychainManager!
    private var session: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        keychain = KeychainManager(service: keychainService)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
        try? await keychain.deleteAll()
        session.invalidateAndCancel()
        try await super.tearDown()
    }

    private func makeManager() -> LicenseManager {
        LicenseManager(keychain: keychain, urlSession: session)
    }

    // MARK: - Helpers: Synthetic responses

    /// Builds an `HTTPURLResponse` for the mock URL.
    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.kerwan.app/api/license/validate")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    /// Encodes a ``LicenseValidationResponse`` to JSON using the same ISO-8601
    /// date strategy as ``LicenseManager``.
    private func encode(_ response: LicenseValidationResponse) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(response)
    }

    // MARK: - Tests: No key stored

    func testValidate_noKey_returnsFreeTier() async throws {
        let manager = makeManager()
        let features = try await manager.validate()

        XCTAssertEqual(features, .free)
        let isValid = await manager.isValid
        XCTAssertFalse(isValid)
        let plan = await manager.plan
        XCTAssertEqual(plan, "free")
    }

    // MARK: - Tests: Successful network validation

    func testValidate_successResponse_returnsProFeatures() async throws {
        let proFeatures = LicenseFeatures(
            llm: true, unlimitedHistory: true, crmExport: true, teamSharing: false, plan: "pro"
        )
        let serverResponse = LicenseValidationResponse(
            valid: true, message: nil, features: proFeatures, expiresAt: nil
        )
        MockURLProtocol.handler = { [self] _ in
            (self.httpResponse(status: 200), try self.encode(serverResponse))
        }

        try await keychain.write(.licenseKey, value: "PRO-KEY-123")
        let manager = makeManager()
        let features = try await manager.validate()

        XCTAssertEqual(features, proFeatures)
        let isValid = await manager.isValid
        XCTAssertTrue(isValid)
        let plan = await manager.plan
        XCTAssertEqual(plan, "pro")
    }

    func testValidate_successResponse_writesCache() async throws {
        let proFeatures = LicenseFeatures(
            llm: true, unlimitedHistory: false, crmExport: false, teamSharing: false, plan: "pro"
        )
        let serverResponse = LicenseValidationResponse(
            valid: true, message: nil, features: proFeatures, expiresAt: nil
        )
        MockURLProtocol.handler = { [self] _ in
            (self.httpResponse(status: 200), try self.encode(serverResponse))
        }

        try await keychain.write(.licenseKey, value: "CACHE-KEY")
        let manager = makeManager()
        _ = try await manager.validate()

        // Cache should now be present in the Keychain.
        let cached = try await keychain.read(.licenseCache)
        XCTAssertNotNil(cached, "Cache should be written after a successful validation")
    }

    // MARK: - Tests: Network unavailable → use cache

    func testValidate_networkUnavailable_validCache_returnsCachedFeatures() async throws {
        // Pre-populate the cache with a pro entry that expires 6 days from now.
        let proFeatures = LicenseFeatures(
            llm: true, unlimitedHistory: true, crmExport: false, teamSharing: false, plan: "pro"
        )
        let cacheEntry = LicenseCacheEntry(
            features: proFeatures,
            validatedAt: Date(),
            expiresAt: Date(timeIntervalSinceNow: 6 * 24 * 60 * 60),
            licenseKey: "MY-KEY",
            licenseExpiresAt: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let cacheJSON = String(data: try encoder.encode(cacheEntry), encoding: .utf8)!
        try await keychain.write(.licenseKey, value: "MY-KEY")
        try await keychain.write(.licenseCache, value: cacheJSON)

        // Network fails.
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        let manager = makeManager()
        let features = try await manager.validate()

        XCTAssertEqual(features, proFeatures)
        let isValid = await manager.isValid
        XCTAssertTrue(isValid)
    }

    func testValidate_networkUnavailable_expiredCache_returnsFreeTier() async throws {
        let proFeatures = LicenseFeatures(
            llm: true, unlimitedHistory: true, crmExport: false, teamSharing: false, plan: "pro"
        )
        // Cache expired 1 second ago.
        let cacheEntry = LicenseCacheEntry(
            features: proFeatures,
            validatedAt: Date(timeIntervalSinceNow: -8 * 24 * 60 * 60),
            expiresAt: Date(timeIntervalSinceNow: -1),
            licenseKey: "MY-KEY",
            licenseExpiresAt: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let cacheJSON = String(data: try encoder.encode(cacheEntry), encoding: .utf8)!
        try await keychain.write(.licenseKey, value: "MY-KEY")
        try await keychain.write(.licenseCache, value: cacheJSON)

        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        let manager = makeManager()
        let features = try await manager.validate()

        XCTAssertEqual(features, .free)
        let isValid = await manager.isValid
        XCTAssertFalse(isValid)
    }

    func testValidate_networkUnavailable_noCache_returnsFreeTier() async throws {
        try await keychain.write(.licenseKey, value: "SOME-KEY")
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }

        let manager = makeManager()
        let features = try await manager.validate()

        XCTAssertEqual(features, .free)
        let isValid = await manager.isValid
        XCTAssertFalse(isValid)
    }

    // MARK: - Tests: Backend rejects key

    func testValidate_invalidKeyResponse_throws() async throws {
        MockURLProtocol.handler = { [self] _ in
            (self.httpResponse(status: 401), Data())
        }
        try await keychain.write(.licenseKey, value: "BAD-KEY")

        let manager = makeManager()
        do {
            _ = try await manager.validate()
            XCTFail("Expected LicenseError.invalidKey to be thrown")
        } catch LicenseError.invalidKey {
            // Expected.
        }
    }

    func testValidate_validFalseInBody_throws() async throws {
        let serverResponse = LicenseValidationResponse(
            valid: false, message: "Key used on another machine", features: nil, expiresAt: nil
        )
        MockURLProtocol.handler = { [self] _ in
            (self.httpResponse(status: 200), try self.encode(serverResponse))
        }
        try await keychain.write(.licenseKey, value: "BOUND-TO-OTHER")

        let manager = makeManager()
        do {
            _ = try await manager.validate()
            XCTFail("Expected LicenseError.invalidKey to be thrown")
        } catch LicenseError.invalidKey {
            // Expected.
        }
    }

    // MARK: - Tests: activate(key:)

    func testActivate_validKey_storesKeyAndCache() async throws {
        let proFeatures = LicenseFeatures(
            llm: true, unlimitedHistory: true, crmExport: true, teamSharing: true, plan: "team"
        )
        let serverResponse = LicenseValidationResponse(
            valid: true, message: nil, features: proFeatures, expiresAt: nil
        )
        MockURLProtocol.handler = { [self] _ in
            (self.httpResponse(status: 200), try self.encode(serverResponse))
        }

        let manager = makeManager()
        let features = try await manager.activate(key: "TEAM-VALID-KEY")

        XCTAssertEqual(features, proFeatures)

        // Key must be stored in the Keychain.
        let storedKey = try await keychain.read(.licenseKey)
        XCTAssertEqual(storedKey, "TEAM-VALID-KEY")

        // Cache must be present.
        let cachedJSON = try await keychain.read(.licenseCache)
        XCTAssertNotNil(cachedJSON)

        // Actor state must reflect the new plan.
        let plan = await manager.plan
        XCTAssertEqual(plan, "team")
        let isValid = await manager.isValid
        XCTAssertTrue(isValid)
    }

    func testActivate_invalidKey_doesNotStoreKey() async throws {
        MockURLProtocol.handler = { [self] _ in
            (self.httpResponse(status: 403), Data())
        }

        let manager = makeManager()
        do {
            _ = try await manager.activate(key: "BAD-KEY")
            XCTFail("Expected LicenseError.invalidKey")
        } catch LicenseError.invalidKey {
            // Expected.
        }

        // Key must NOT be stored.
        let storedKey = try await keychain.read(.licenseKey)
        XCTAssertNil(storedKey)
    }

    func testActivate_networkUnavailable_throws() async throws {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        let manager = makeManager()
        do {
            _ = try await manager.activate(key: "OFFLINE-KEY")
            XCTFail("Expected LicenseError.networkUnavailable")
        } catch LicenseError.networkUnavailable {
            // Expected — network errors during activation always throw.
        }
    }

    func testActivate_emptyKey_throws() async throws {
        let manager = makeManager()
        do {
            _ = try await manager.activate(key: "   ")
            XCTFail("Expected LicenseError.invalidKey for blank key")
        } catch LicenseError.invalidKey {
            // Expected.
        }
    }

    // MARK: - Tests: deactivate()

    func testDeactivate_clearsKeyAndCacheAndRevertsToPlan() async throws {
        let proFeatures = LicenseFeatures(
            llm: true, unlimitedHistory: true, crmExport: false, teamSharing: false, plan: "pro"
        )
        let serverResponse = LicenseValidationResponse(
            valid: true, message: nil, features: proFeatures, expiresAt: nil
        )
        MockURLProtocol.handler = { [self] _ in
            (self.httpResponse(status: 200), try self.encode(serverResponse))
        }

        let manager = makeManager()
        _ = try await manager.activate(key: "PRO-KEY")

        // Now deactivate.
        try await manager.deactivate()

        let storedKey = try await keychain.read(.licenseKey)
        XCTAssertNil(storedKey, "License key should be removed from Keychain after deactivation")

        let cachedJSON = try await keychain.read(.licenseCache)
        XCTAssertNil(cachedJSON, "License cache should be removed from Keychain after deactivation")

        let features = await manager.currentFeatures
        XCTAssertEqual(features, .free)
        let isValid = await manager.isValid
        XCTAssertFalse(isValid)
    }

    // MARK: - Tests: Certificate-pinning failure → cache fallback

    func testValidate_pinFailure_fallsBackToCache() async throws {
        let proFeatures = LicenseFeatures(
            llm: true, unlimitedHistory: false, crmExport: false, teamSharing: false, plan: "pro"
        )
        let cacheEntry = LicenseCacheEntry(
            features: proFeatures,
            validatedAt: Date(),
            expiresAt: Date(timeIntervalSinceNow: 5 * 24 * 60 * 60),
            licenseKey: "PIN-KEY",
            licenseExpiresAt: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let cacheJSON = String(data: try encoder.encode(cacheEntry), encoding: .utf8)!
        try await keychain.write(.licenseKey, value: "PIN-KEY")
        try await keychain.write(.licenseCache, value: cacheJSON)

        // Simulate a pin failure: URLSession cancelled (same code LicensePinningDelegate uses).
        MockURLProtocol.handler = { _ in throw URLError(.cancelled) }

        let manager = makeManager()
        let features = try await manager.validate()

        // Should fall back to cache, not free tier.
        XCTAssertEqual(features, proFeatures)
        let isValid = await manager.isValid
        XCTAssertTrue(isValid)
    }

    // MARK: - Tests: Cache key mismatch

    func testValidate_cacheKeyMismatch_returnsFreeTierOnNetworkError() async throws {
        let proFeatures = LicenseFeatures(
            llm: true, unlimitedHistory: false, crmExport: false, teamSharing: false, plan: "pro"
        )
        // Cache was written for a different key.
        let cacheEntry = LicenseCacheEntry(
            features: proFeatures,
            validatedAt: Date(),
            expiresAt: Date(timeIntervalSinceNow: 6 * 24 * 60 * 60),
            licenseKey: "OLD-KEY",
            licenseExpiresAt: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let cacheJSON = String(data: try encoder.encode(cacheEntry), encoding: .utf8)!
        try await keychain.write(.licenseKey, value: "NEW-KEY")   // ← different
        try await keychain.write(.licenseCache, value: cacheJSON)

        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        let manager = makeManager()
        let features = try await manager.validate()

        XCTAssertEqual(features, .free, "Cache with mismatched key should not be trusted")
    }

    // MARK: - Tests: Rate-limiting (429)

    func testValidate_rateLimited_fallsBackToCache() async throws {
        let proFeatures = LicenseFeatures(
            llm: true, unlimitedHistory: false, crmExport: false, teamSharing: false, plan: "pro"
        )
        let cacheEntry = LicenseCacheEntry(
            features: proFeatures,
            validatedAt: Date(),
            expiresAt: Date(timeIntervalSinceNow: 3 * 24 * 60 * 60),
            licenseKey: "RL-KEY",
            licenseExpiresAt: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let cacheJSON = String(data: try encoder.encode(cacheEntry), encoding: .utf8)!
        try await keychain.write(.licenseKey, value: "RL-KEY")
        try await keychain.write(.licenseCache, value: cacheJSON)

        // Backend returns 429 — LicenseManager treats this as network unavailable.
        MockURLProtocol.handler = { [self] _ in
            (self.httpResponse(status: 429), Data())
        }

        let manager = makeManager()
        let features = try await manager.validate()

        XCTAssertEqual(features, proFeatures)
    }

    // MARK: - Tests: LicenseFeatureProvider (ClassificationActor gate)

    func testCurrentFeatures_defaultFreeTier() async {
        let manager = makeManager()
        let features = await manager.currentFeatures
        XCTAssertFalse(features.llm)
        XCTAssertFalse(features.unlimitedHistory)
        XCTAssertEqual(features.plan, "free")
    }

    func testLicenseFeatureProvider_conformance() async throws {
        let proFeatures = LicenseFeatures(
            llm: true, unlimitedHistory: true, crmExport: true, teamSharing: false, plan: "pro"
        )
        let serverResponse = LicenseValidationResponse(
            valid: true, message: nil, features: proFeatures, expiresAt: nil
        )
        MockURLProtocol.handler = { [self] _ in
            (self.httpResponse(status: 200), try self.encode(serverResponse))
        }
        try await keychain.write(.licenseKey, value: "PROTO-KEY")

        let manager = makeManager()
        _ = try await manager.validate()

        // Access via the protocol existential (as ClassificationActor would).
        let provider: any LicenseFeatureProvider = manager
        let features = await provider.currentFeatures
        XCTAssertTrue(features.llm)
        XCTAssertTrue(features.unlimitedHistory)
    }

    // MARK: - Tests: Request payload shape

    func testValidate_requestContainsMachineIdAndAppVersion() async throws {
        let proFeatures = LicenseFeatures(
            llm: true, unlimitedHistory: false, crmExport: false, teamSharing: false, plan: "pro"
        )
        let serverResponse = LicenseValidationResponse(
            valid: true, message: nil, features: proFeatures, expiresAt: nil
        )

        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { [self] request in
            capturedRequest = request
            return (self.httpResponse(status: 200), try self.encode(serverResponse))
        }
        try await keychain.write(.licenseKey, value: "PAYLOAD-KEY")

        let manager = makeManager()
        _ = try await manager.validate()

        guard let body = capturedRequest?.httpBody else {
            XCTFail("No request body captured")
            return
        }
        let payload = try JSONDecoder().decode(LicenseValidationRequest.self, from: body)
        XCTAssertFalse(payload.machineId.isEmpty, "machine_id must not be empty")
        XCTAssertFalse(payload.appVersion.isEmpty, "app_version must not be empty")
        XCTAssertEqual(payload.licenseKey, "PAYLOAD-KEY")
    }

    func testValidate_requestMethod_isPOST() async throws {
        let proFeatures = LicenseFeatures(
            llm: true, unlimitedHistory: false, crmExport: false, teamSharing: false, plan: "pro"
        )
        let serverResponse = LicenseValidationResponse(
            valid: true, message: nil, features: proFeatures, expiresAt: nil
        )
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { [self] request in
            capturedRequest = request
            return (self.httpResponse(status: 200), try self.encode(serverResponse))
        }
        try await keychain.write(.licenseKey, value: "METHOD-KEY")

        let manager = makeManager()
        _ = try await manager.validate()

        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(
            capturedRequest?.value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
    }
}
