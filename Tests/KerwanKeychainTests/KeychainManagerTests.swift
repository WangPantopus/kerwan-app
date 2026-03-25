import XCTest
@testable import KerwanKeychain

// MARK: - KeychainManagerTests
//
// These tests use a unique service name per test run so they are isolated
// from production Keychain items and from each other.

final class KeychainManagerTests: XCTestCase {

    private var manager: KeychainManager!
    private let testService = "com.kerwan.tests.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        // Use a unique service name so items don't collide across test runs.
        manager = KeychainManager(service: testService)
    }

    override func tearDown() async throws {
        // Clean up all test items regardless of test outcome.
        try await manager.deleteAll()
        try await super.tearDown()
    }

    // MARK: - Basic read/write/delete

    func test_write_thenRead_returnsValue() async throws {
        try await manager.write(.licenseKey, value: "KERWAN-XXXX-YYYY-ZZZZ")
        let value = try await manager.read(.licenseKey)
        XCTAssertEqual(value, "KERWAN-XXXX-YYYY-ZZZZ")
    }

    func test_read_missingItem_returnsNil() async throws {
        let value = try await manager.read(.gmailOAuthToken)
        XCTAssertNil(value)
    }

    func test_write_overwritesExistingValue() async throws {
        try await manager.write(.licenseCache, value: #"{"valid":true}"#)
        try await manager.write(.licenseCache, value: #"{"valid":false}"#)
        let value = try await manager.read(.licenseCache)
        XCTAssertEqual(value, #"{"valid":false}"#)
    }

    func test_delete_removesItem() async throws {
        try await manager.write(.licenseKey, value: "KEY-123")
        try await manager.delete(.licenseKey)
        let value = try await manager.read(.licenseKey)
        XCTAssertNil(value)
    }

    func test_delete_missingItem_doesNotThrow() async throws {
        // Should complete without throwing even if item was never stored.
        try await manager.delete(.gmailOAuthToken)
    }

    // MARK: - deleteAll

    func test_deleteAll_removesAllItems() async throws {
        try await manager.write(.licenseKey,      value: "K")
        try await manager.write(.gmailOAuthToken, value: "T")
        try await manager.write(.licenseCache,    value: "C")
        try await manager.deleteAll()
        for item in KeychainItem.allCases {
            let value = try await manager.read(item)
            XCTAssertNil(value, "\(item.rawValue) should be nil after deleteAll()")
        }
    }

    // MARK: - Database passphrase

    func test_databasePassphrase_generatesOnFirstCall() async throws {
        let passphrase = try await manager.databasePassphrase()
        XCTAssertFalse(passphrase.isEmpty)
        // Must be valid base64 (32 bytes → 44-char base64 string)
        XCTAssertEqual(passphrase.count, 44)
        let decoded = Data(base64Encoded: passphrase)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.count, 32)
    }

    func test_databasePassphrase_returnsSameValueOnSubsequentCalls() async throws {
        let first  = try await manager.databasePassphrase()
        let second = try await manager.databasePassphrase()
        XCTAssertEqual(first, second)
    }

    func test_databasePassphrase_isStoredInKeychain() async throws {
        let passphrase = try await manager.databasePassphrase()
        let stored = try await manager.read(.dbPassphrase)
        XCTAssertEqual(stored, passphrase)
    }

    func test_databasePassphrase_uniquePerInstall() async throws {
        // Two different service names → two different generated passphrases
        let m1 = KeychainManager(service: testService + ".a")
        let m2 = KeychainManager(service: testService + ".b")
        defer {
            Task { try? await m1.deleteAll() }
            Task { try? await m2.deleteAll() }
        }
        let p1 = try await m1.databasePassphrase()
        let p2 = try await m2.databasePassphrase()
        XCTAssertNotEqual(p1, p2)
    }

    // MARK: - Unicode / special characters

    func test_write_unicodeValue_roundTrips() async throws {
        let emoji = "🔑🗝️ ключ پاسفراز"
        try await manager.write(.licenseKey, value: emoji)
        let back = try await manager.read(.licenseKey)
        XCTAssertEqual(back, emoji)
    }

    func test_write_longValue_roundTrips() async throws {
        let long = String(repeating: "A", count: 4096)
        try await manager.write(.licenseCache, value: long)
        let back = try await manager.read(.licenseCache)
        XCTAssertEqual(back, long)
    }

    // MARK: - Distinct account names

    func test_differentItems_storedSeparately() async throws {
        try await manager.write(.licenseKey,      value: "LK-VALUE")
        try await manager.write(.gmailOAuthToken, value: "TOKEN-VALUE")
        let lk    = try await manager.read(.licenseKey)
        let gmail = try await manager.read(.gmailOAuthToken)
        XCTAssertEqual(lk,    "LK-VALUE")
        XCTAssertEqual(gmail, "TOKEN-VALUE")
    }
}
