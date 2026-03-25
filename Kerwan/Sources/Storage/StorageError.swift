import Foundation

/// Errors produced by the Kerwan storage engine.
///
/// `StorageError` covers every failure mode in database initialization,
/// migration, encryption, and CRUD operations. Each case carries enough
/// context for logging and user-facing error presentation.
public enum StorageError: Error, Sendable, LocalizedError {

    /// The database file could not be found or the parent directory
    /// could not be created.
    case databaseNotFound

    /// SQLCipher failed to set or verify the encryption key.
    /// The database may be corrupted or the passphrase is incorrect.
    case encryptionFailed

    /// A numbered schema migration failed. The transaction was rolled back
    /// and the database remains at the previous version.
    ///
    /// - Parameters:
    ///   - version: The migration number that failed (e.g., 1 for migration_001).
    ///   - message: A description of the underlying error.
    case migrationFailed(version: Int, message: String)

    /// A write operation (INSERT, UPDATE, DELETE) failed.
    ///
    /// - Parameter message: A description of the underlying SQLite error.
    case writeFailed(String)

    /// A read operation (SELECT) failed.
    ///
    /// - Parameter message: A description of the underlying SQLite error.
    case readFailed(String)

    /// An integrity check detected database corruption.
    case corruptionDetected

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .databaseNotFound:
            return "Database file not found or directory could not be created."
        case .encryptionFailed:
            return "Database encryption failed. The passphrase may be incorrect."
        case .migrationFailed(let version, let message):
            return "Schema migration \(version) failed: \(message)"
        case .writeFailed(let message):
            return "Database write failed: \(message)"
        case .readFailed(let message):
            return "Database read failed: \(message)"
        case .corruptionDetected:
            return "Database corruption detected. Please restore from backup."
        }
    }
}
