import Foundation
import Security
import os.log
import CryptoKit

// MARK: - KeychainError

/// Typed errors from Keychain operations.
public enum KeychainError: Error, Sendable {
    case itemNotFound
    case duplicateItem
    case authenticationFailed
    case unexpectedData
    case unhandledStatus(OSStatus)
    case encodingFailed
}

extension KeychainError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .itemNotFound:          return "Keychain item not found."
        case .duplicateItem:         return "A duplicate Keychain item already exists."
        case .authenticationFailed:  return "Keychain authentication failed (biometrics or password)."
        case .unexpectedData:        return "Keychain returned unexpected data format."
        case .unhandledStatus(let s): return "Keychain error: OSStatus \(s)."
        case .encodingFailed:        return "Failed to encode/decode Keychain value."
        }
    }
}

// MARK: - KeychainItem

/// The fixed set of items managed by Kerwan's KeychainManager.
public enum KeychainItem: String, Sendable, CaseIterable {
    /// AES-256 database passphrase. Generated once; user never sees it.
    case dbPassphrase       = "db-passphrase"
    /// Gmail OAuth 2.0 refresh token.
    case gmailOAuthToken    = "gmail-oauth-token"
    /// License key entered by the user.
    case licenseKey         = "license-key"
    /// Cached JSON blob from the last license validation response.
    case licenseCache       = "license-cache"
}

// MARK: - KeychainManager

/// Manages secure storage of Kerwan secrets in the system Keychain.
///
/// Uses Security.framework directly (SecItemAdd / SecItemCopyMatching /
/// SecItemUpdate / SecItemDelete). All methods are synchronous internally
/// and exposed as async wrappers that hop off the calling task's executor.
public final class KeychainManager: Sendable {

    // MARK: - Configuration

    private let service: String
    /// When non-nil, restricts Keychain items to this access group.
    /// Used by tests to prevent polluting the real Keychain.
    private let accessGroup: String?
    private let log = Logger(subsystem: "com.kerwan.app", category: "KeychainManager")

    public init(service: String = "com.kerwan.app", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    // MARK: - Async wrappers

    /// Retrieves a string value; returns `nil` if the item does not exist.
    public func read(_ item: KeychainItem) async throws -> String? {
        try syncRead(item)
    }

    /// Stores a string value, creating or updating as needed.
    public func write(_ item: KeychainItem, value: String) async throws {
        try syncWrite(item, value: value)
    }

    /// Removes an item. Silently succeeds if the item does not exist.
    public func delete(_ item: KeychainItem) async throws {
        try syncDelete(item)
    }

    /// Removes all Kerwan items from the Keychain. Used for app reset.
    public func deleteAll() async throws {
        for item in KeychainItem.allCases {
            try syncDelete(item)
        }
        log.info("All Keychain items deleted.")
    }

    // MARK: - Database passphrase management

    /// Returns the database passphrase. If none exists, generates a
    /// cryptographically random 32-byte value, base64-encodes it, stores
    /// it in the Keychain, and returns it.
    ///
    /// - Parameter requireBiometrics: When true, the item is protected by
    ///   `kSecAccessControlBiometryCurrentSet`, requiring Touch ID (or the
    ///   enrolled biometric set) on every access.
    public func databasePassphrase(requireBiometrics: Bool = false) async throws -> String {
        if let existing = try syncRead(.dbPassphrase) {
            return existing
        }

        // Generate 32 cryptographically random bytes.
        var bytes = [UInt8](repeating: 0, count: 32)
        let rc = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        guard rc == errSecSuccess else {
            throw KeychainError.unhandledStatus(rc)
        }
        let passphrase = Data(bytes).base64EncodedString()

        if requireBiometrics {
            try syncWriteWithBiometrics(.dbPassphrase, value: passphrase)
        } else {
            try syncWrite(.dbPassphrase, value: passphrase)
        }
        log.info("Generated and stored new database passphrase.")
        return passphrase
    }

    // MARK: - Synchronous Core (internal)

    func syncRead(_ item: KeychainItem) throws -> String? {
        var query = baseQuery(for: item)
        query[kSecMatchLimit as String]       = kSecMatchLimitOne
        query[kSecReturnData as String]       = true

        var raw: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &raw)

        switch status {
        case errSecSuccess:
            guard let data = raw as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedData
            }
            return string
        case errSecItemNotFound:
            return nil
        case errSecAuthFailed, errSecUserCanceled, -25308: // -25308 = errSecInteractionNotAllowed
            throw KeychainError.authenticationFailed
        default:
            throw KeychainError.unhandledStatus(status)
        }
    }

    func syncWrite(_ item: KeychainItem, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // Attempt update first; if item doesn't exist, add it.
        let existing = try syncRead(item)
        if existing != nil {
            let query = baseQuery(for: item)
            let attrs: [String: Any] = [
                kSecValueData as String: data,
            ]
            let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            guard status == errSecSuccess else {
                throw KeychainError.unhandledStatus(status)
            }
        } else {
            var addQuery = baseQuery(for: item)
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            guard status == errSecSuccess else {
                if status == errSecDuplicateItem {
                    throw KeychainError.duplicateItem
                }
                throw KeychainError.unhandledStatus(status)
            }
        }
    }

    func syncDelete(_ item: KeychainItem) throws {
        let query = baseQuery(for: item)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }
    }

    // MARK: - Biometric-protected write

    private func syncWriteWithBiometrics(_ item: KeychainItem, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // Delete any existing item first to avoid conflict.
        let _ = try? syncDelete(item)

        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet,
            &error
        ) else {
            let underlying = error?.takeRetainedValue()
            throw KeychainError.unhandledStatus(underlying.map {
                OSStatus(CFErrorGetCode($0))
            } ?? errSecParam)
        }

        var addQuery = baseQuery(for: item)
        addQuery[kSecValueData as String]        = data
        addQuery[kSecAttrAccessControl as String] = access
        // kSecAttrAccessible must not be set when using kSecAttrAccessControl
        addQuery.removeValue(forKey: kSecAttrAccessible as String)

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandledStatus(status)
        }
        log.info("Stored \(item.rawValue) with biometric access control.")
    }

    // MARK: - Query Builder

    private func baseQuery(for item: KeychainItem) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }
}
