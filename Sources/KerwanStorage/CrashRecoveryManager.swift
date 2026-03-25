import Foundation
import SQLite3
import os.log

// MARK: - LaunchResult

/// Outcome of `CrashRecoveryManager.runPreLaunchChecks`.
public enum LaunchResult: Sendable {
    /// Database is healthy — proceed normally.
    case ok
    /// Dirty shutdown was detected but the database passed integrity_check.
    case dirtyShutdownRecovered
    /// Corruption found; VACUUM INTO repair succeeded — the recovered database
    /// has been swapped in and normal startup can proceed.
    case corruptionRepaired
    /// Corruption found; VACUUM INTO failed but the database was replaced from
    /// the latest backup. The restored URL is included for logging.
    case restoredFromBackup(URL)
    /// Corruption is unrecoverable — no repair and no backup exists.
    case unrecoverable
}

// MARK: - CrashRecoveryManager

/// Performs pre-launch database health checks.
///
/// Usage (call before `StorageActor.init`):
/// ```swift
/// let result = await CrashRecoveryManager.runPreLaunchChecks(
///     databasePath: dbPath, passphrase: key)
/// ```
///
/// ### Dirty-shutdown flag
/// The flag key `com.kerwan.app.dirtyShutdown` is set in `UserDefaults.standard`
/// at process launch and cleared when the app terminates cleanly.  If the key is
/// present on the *next* launch, a previous run crashed or was force-quit.
///
/// Note: `RawEventBuffer` manages a separate key (`com.kerwan.app.buffer.dirtyShutdown`);
/// the two flags are intentionally distinct.
public enum CrashRecoveryManager {

    // MARK: - Constants

    public static let dirtyShutdownKey = "com.kerwan.app.dirtyShutdown"

    private static let log = Logger(
        subsystem: "com.kerwan.app",
        category: "CrashRecoveryManager"
    )

    // MARK: - Lifecycle helpers

    /// Arm the dirty-shutdown flag.  Call as early as possible in `App.init` or
    /// before `StorageActor` is created.
    public static func armDirtyShutdownFlag() {
        UserDefaults.standard.set(true, forKey: dirtyShutdownKey)
        log.info("Dirty-shutdown flag armed.")
    }

    /// Clear the dirty-shutdown flag.  Call from `applicationWillTerminate` or
    /// a `SwiftUI.onChange(of: scenePhase)` clean-quit path.
    public static func clearDirtyShutdownFlag() {
        UserDefaults.standard.removeObject(forKey: dirtyShutdownKey)
        log.info("Dirty-shutdown flag cleared.")
    }

    public static var isDirtyShutdownFlagged: Bool {
        UserDefaults.standard.bool(forKey: dirtyShutdownKey)
    }

    // MARK: - Pre-launch checks

    /// Runs all pre-launch integrity checks synchronously on a background context.
    ///
    /// Steps:
    /// 1. If dirty-shutdown flag absent → return `.ok` immediately.
    /// 2. Run `PRAGMA integrity_check(1)` on the live database.
    ///    - If "ok" → clear flag, return `.dirtyShutdownRecovered`.
    /// 3. Attempt `VACUUM INTO` repair to a temp path, then atomically replace
    ///    the live database.
    ///    - If successful → return `.corruptionRepaired`.
    /// 4. Fall back to the latest auto-backup via `BackupManager.latestBackupURL()`.
    ///    - If a valid backup exists → replace live database, return `.restoredFromBackup`.
    /// 5. Return `.unrecoverable`.
    ///
    /// - Parameters:
    ///   - databasePath: Absolute path to the live `kerwan.db`.
    ///   - passphrase:   Database encryption key (used by integrity_check on SQLCipher builds).
    public static func runPreLaunchChecks(
        databasePath: String,
        passphrase: String
    ) async -> LaunchResult {
        guard isDirtyShutdownFlagged else {
            log.debug("No dirty-shutdown flag — skipping recovery checks.")
            return .ok
        }

        log.warning("Dirty-shutdown flag detected. Running integrity check on \(databasePath).")

        // ── Step 2: integrity_check ──────────────────────────────────────────
        let integrityOK = checkIntegrity(at: databasePath, passphrase: passphrase)
        if integrityOK {
            clearDirtyShutdownFlag()
            log.info("Integrity check passed after dirty shutdown.")
            return .dirtyShutdownRecovered
        }

        log.error("Integrity check FAILED — attempting VACUUM INTO repair.")

        // ── Step 3: VACUUM INTO ──────────────────────────────────────────────
        let tempPath = databasePath + ".recovery_\(Int(Date().timeIntervalSince1970)).db"
        if vacuumInto(source: databasePath, destination: tempPath, passphrase: passphrase) {
            do {
                let liveURL  = URL(fileURLWithPath: databasePath)
                let tempURL  = URL(fileURLWithPath: tempPath)
                try FileManager.default.replaceItem(
                    at: liveURL,
                    withItemAt: tempURL,
                    backupItemName: nil,
                    resultingItemURL: nil
                )
                removeWALFiles(databasePath: databasePath)
                clearDirtyShutdownFlag()
                log.info("VACUUM INTO repair succeeded.")
                return .corruptionRepaired
            } catch {
                log.error("Atomic replace after VACUUM INTO failed: \(error.localizedDescription)")
                try? FileManager.default.removeItem(atPath: tempPath)
            }
        }

        // ── Step 4: restore from latest backup ──────────────────────────────
        if let backupURL = BackupManager.latestBackupURL() {
            let isBackupValid = checkIntegrity(
                at: backupURL.path,
                passphrase: passphrase
            )
            if isBackupValid {
                do {
                    let liveURL = URL(fileURLWithPath: databasePath)
                    try FileManager.default.replaceItem(
                        at: liveURL,
                        withItemAt: backupURL,
                        backupItemName: nil,
                        resultingItemURL: nil
                    )
                    removeWALFiles(databasePath: databasePath)
                    clearDirtyShutdownFlag()
                    log.warning("Restored from backup: \(backupURL.lastPathComponent)")
                    return .restoredFromBackup(backupURL)
                } catch {
                    log.error("Restore from backup failed: \(error.localizedDescription)")
                }
            } else {
                log.error("Latest backup is also corrupt: \(backupURL.lastPathComponent)")
            }
        } else {
            log.error("No backup available for recovery.")
        }

        // ── Step 5: unrecoverable ────────────────────────────────────────────
        log.fault("Database is unrecoverable — no repair and no valid backup.")
        return .unrecoverable
    }

    // MARK: - Private helpers

    /// Returns `true` if `PRAGMA integrity_check(1)` reports "ok".
    private static func checkIntegrity(at path: String, passphrase: String) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle = db else {
            return false
        }
        defer { sqlite3_close(handle) }

        // Apply passphrase for SQLCipher builds (no-op on stock SQLite).
        if !passphrase.isEmpty {
            _ = passphrase.withCString { ptr in
                sqlite3_exec(handle, "PRAGMA key = '\(passphrase)'", nil, nil, nil)
            }
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA integrity_check(1)", -1, &stmt, nil) == SQLITE_OK,
              let statement = stmt else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        let result = sqlite3_column_text(statement, 0).flatMap { String(cString: $0) }
        return result == "ok"
    }

    /// Attempts `VACUUM INTO destination`. Returns `true` on success.
    private static func vacuumInto(
        source: String,
        destination: String,
        passphrase: String
    ) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(source, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle = db else {
            return false
        }
        defer { sqlite3_close(handle) }

        if !passphrase.isEmpty {
            sqlite3_exec(handle, "PRAGMA key = '\(passphrase)'", nil, nil, nil)
        }

        let sql = "VACUUM INTO '\(destination.replacingOccurrences(of: "'", with: "''"))'"
        let rc = sqlite3_exec(handle, sql, nil, nil, nil)
        if rc != SQLITE_OK {
            let msg = sqlite3_errmsg(handle).flatMap { String(cString: $0) } ?? "unknown"
            log.error("VACUUM INTO failed (\(rc)): \(msg)")
            return false
        }
        return true
    }

    /// Removes `.wal` and `.shm` sidecar files after a database replacement.
    private static func removeWALFiles(databasePath: String) {
        let fm = FileManager.default
        for suffix in ["-wal", "-shm"] {
            let sidecar = databasePath + suffix
            if fm.fileExists(atPath: sidecar) {
                try? fm.removeItem(atPath: sidecar)
            }
        }
    }
}
