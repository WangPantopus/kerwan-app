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
    /// A backup write operation failed (online backup API or file copy).
    case backupFailed(Error)
    /// A restore operation failed.
    case restoreFailed(Error)
    /// Not enough disk space to write the backup or restore.
    case insufficientDiskSpace(available: Int64, required: Int64)
    /// The backup file failed an integrity check or could not be opened.
    case backupCorrupted
    /// The database volume is full; writes cannot proceed.
    case databaseFull
    /// The crash-recovery process could not repair the database and no backup exists.
    case unrecoverableCorruption
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
        case .backupFailed(let err):
            return "Database backup failed: \(err.localizedDescription)"
        case .restoreFailed(let err):
            return "Database restore failed: \(err.localizedDescription)"
        case .insufficientDiskSpace(let available, let required):
            let avMB = available / 1_048_576
            let reqMB = required / 1_048_576
            return "Not enough disk space: \(avMB) MB available, \(reqMB) MB required."
        case .backupCorrupted:
            return "Backup file is corrupted or cannot be opened."
        case .databaseFull:
            return "Database volume is full. Free disk space and try again."
        case .unrecoverableCorruption:
            return "Database is corrupted and could not be recovered. No backup is available."
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
