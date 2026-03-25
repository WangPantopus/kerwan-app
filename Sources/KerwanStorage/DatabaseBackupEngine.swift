import Foundation
import SQLite3
import os.log

// MARK: - BackupError

/// Detailed errors originating from backup/restore operations.
public enum BackupError: Error, LocalizedError, Sendable {
    /// The destination path could not be opened for writing.
    case cannotOpenDestination(String)
    /// `PRAGMA integrity_check` returned a non-"ok" result.
    case integrityCheckFailed(String)
    /// No backup file exists at the expected location.
    case noBackupFound

    public var errorDescription: String? {
        switch self {
        case .cannotOpenDestination(let path):
            return "Cannot open backup destination: \(path)"
        case .integrityCheckFailed(let detail):
            return "Backup integrity check failed: \(detail)"
        case .noBackupFound:
            return "No backup file found at the specified location."
        }
    }
}

// MARK: - DatabaseBackupEngine

/// Wraps the SQLite Online Backup API and integrity validation.
///
/// All functions are synchronous and accept raw `sqlite3*` pointers or file paths.
/// Thread safety is the caller's responsibility — call only from actor-isolated context.
enum DatabaseBackupEngine {

    private static let log = Logger(subsystem: "com.kerwan.app", category: "DatabaseBackupEngine")

    // MARK: - Online Backup API

    /// Copies the live database to `destinationPath` using `sqlite3_backup_*`.
    ///
    /// Uses the SQLite Online Backup API, which:
    /// - Acquires a shared lock per step, so concurrent WAL writers are not blocked.
    /// - Produces a consistent snapshot even if writes occur during the copy.
    /// - Handles WAL checkpointing internally; the destination is a clean non-WAL file.
    ///
    /// - Parameters:
    ///   - source:          Open `sqlite3*` handle of the live database (write connection).
    ///   - destinationPath: Path for the output file. Created if absent, overwritten if present.
    static func backup(from source: OpaquePointer, to destinationPath: String) throws {
        // Open (or create) the destination database.
        var destDb: OpaquePointer?
        let openRc = sqlite3_open_v2(
            destinationPath,
            &destDb,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openRc == SQLITE_OK, let destDb else {
            throw StorageError.backupFailed(BackupError.cannotOpenDestination(destinationPath))
        }
        defer { sqlite3_close_v2(destDb) }

        // Initialise the backup handle: copy "main" schema from source → dest.
        guard let backupHandle = sqlite3_backup_init(destDb, "main", source, "main") else {
            let code = sqlite3_errcode(destDb)
            let msg  = String(cString: sqlite3_errmsg(destDb))
            throw StorageError.backupFailed(SQLiteError(code: code, message: msg))
        }

        // Step(-1) copies all pages in one shot — appropriate for Kerwan's typical DB size
        // (< 500 MB). For very large databases, loop step(N) with a short sleep between
        // batches to allow concurrent writers to proceed between steps.
        let stepRc   = sqlite3_backup_step(backupHandle, -1)
        let finishRc = sqlite3_backup_finish(backupHandle)

        if stepRc != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(destDb))
            throw StorageError.backupFailed(SQLiteError(code: stepRc, message: msg))
        }
        if finishRc != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(destDb))
            throw StorageError.backupFailed(SQLiteError(code: finishRc, message: msg))
        }

        log.info("Backup written to \(destinationPath)")
    }

    // MARK: - Integrity Validation

    /// Opens the database at `path`, optionally applies `passphrase`, and runs
    /// `PRAGMA integrity_check(1)`. Throws `StorageError.backupCorrupted` on failure.
    ///
    /// This is called before any restore to ensure the backup is usable.
    /// Passing an empty `passphrase` skips the `PRAGMA key` call (plain SQLite file).
    ///
    /// - Parameters:
    ///   - path:       Filesystem path to the database file.
    ///   - passphrase: SQLCipher passphrase, or `""` for an unencrypted file.
    static func validate(at path: String, passphrase: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw StorageError.backupCorrupted
        }

        var db: OpaquePointer?
        // Open READWRITE so WAL coordination files (.db-wal / .db-shm) can be written
        // even on a backup that was created from a WAL-mode source.
        let rc = sqlite3_open_v2(
            path, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK, let db else {
            throw StorageError.backupCorrupted
        }
        defer { sqlite3_close_v2(db) }

        if !passphrase.isEmpty {
            // No-op on stock SQLite; decrypts with SQLCipher.
            sqlite3_exec(db, "PRAGMA key = '\(passphrase)'", nil, nil, nil)
        }

        // integrity_check(1) — return "ok" for a healthy database, else the first problem.
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check(1)", -1, &stmt, nil) == SQLITE_OK,
              let stmt else {
            throw StorageError.backupCorrupted
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw StorageError.backupCorrupted
        }

        let result = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        guard result == "ok" else {
            log.error("Integrity check failed for \(path): \(result)")
            throw StorageError.backupFailed(BackupError.integrityCheckFailed(result))
        }

        log.info("Integrity check passed for \(path)")
    }
}
