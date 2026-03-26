// GmailKeychainManager.swift
// Kerwan — Email capture layer
//
// Thin wrapper around the Security framework for storing, loading, and
// deleting Gmail OAuth refresh tokens.
//
// Renamed from KeychainManager to GmailKeychainManager to avoid conflict
// with KerwanKeychain.KeychainManager in the Kerwan module.

import Foundation
import Security

// MARK: - GmailKeychainManaging

/// Injectable Keychain interface — production uses `GmailKeychainManager`.
public protocol GmailKeychainManaging: Sendable {
    func save(refreshToken: String, for email: String) throws
    func load(for email: String) throws -> String
    func delete(for email: String) throws
}

// MARK: - GmailKeychainManager

/// Concrete Keychain implementation using `SecItemAdd/Update/CopyMatching/Delete`.
public struct GmailKeychainManager: GmailKeychainManaging {

    static let service = "com.kerwan.app.gmail-refresh-token"

    public init() {}

    // MARK: - Save

    public func save(refreshToken: String, for email: String) throws {
        guard let data = refreshToken.data(using: .utf8) else {
            throw GmailOAuthError.keychainError(errSecInvalidData)
        }

        // Try to update an existing item first; add if not found.
        let query = baseQuery(for: email)
        let updateAttributes: [CFString: Any] = [kSecValueData: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw GmailOAuthError.keychainError(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw GmailOAuthError.keychainError(updateStatus)
        }
    }

    // MARK: - Load

    public func load(for email: String) throws -> String {
        var query = baseQuery(for: email)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)
        else {
            throw GmailOAuthError.keychainError(status == errSecSuccess ? errSecDecode : status)
        }

        return token
    }

    // MARK: - Delete

    public func delete(for email: String) throws {
        let query = baseQuery(for: email)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GmailOAuthError.keychainError(status)
        }
    }

    // MARK: - Private

    private func baseQuery(for email: String) -> [String: Any] {
        [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: GmailKeychainManager.service,
            kSecAttrAccount as String: email
        ]
    }
}
