import Foundation

// MARK: - StorageError

/// Typed errors emitted by StorageActor and its helpers.
public enum StorageError: Error, Sendable {
    /// The database file path could not be created or opened.
    case databaseNotFound
    /// SQLCipher failed to apply the passphrase or cipher configuration.
    case encryptionFailed
    /// A schema migration failed; the transaction was rolled back.
    case migrationFailed(version: Int, underlyingError: Error)
    /// A write operation (INSERT / UPDATE / DELETE) failed.
    case writeFailed(Error)
    /// A read operation (SELECT) failed.
    case readFailed(Error)
    /// SQLite integrity_check or other sanity check detected corruption.
    case corruptionDetected
    /// An export or copy operation failed.
    case exportFailed(Error)
}

extension StorageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .databaseNotFound:
            return "Could not open or create the Kerwan database."
        case .encryptionFailed:
            return "Database encryption setup failed. Verify the passphrase."
        case .migrationFailed(let version, let err):
            return "Schema migration v\(version) failed: \(err.localizedDescription)"
        case .writeFailed(let err):
            return "Database write failed: \(err.localizedDescription)"
        case .readFailed(let err):
            return "Database read failed: \(err.localizedDescription)"
        case .corruptionDetected:
            return "Database corruption detected. Please restore from backup."
        case .exportFailed(let err):
            return "Database export failed: \(err.localizedDescription)"
        }
    }
}

// MARK: - SQLiteError

/// A raw SQLite result-code error, used as the underlying error in StorageError.
public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String

    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "SQLite(\(code)): \(message)" }
}
