import Foundation
import SQLite3
import os.log

// MARK: - StorageActor + Backup / Restore

extension StorageActor {

    private static let backupLog = Logger(
        subsystem: "com.kerwan.app",
        category: "StorageActor.Backup"
    )

    // MARK: - Manual Export

    /// Exports the live database to `destination` using the SQLite Online Backup API.
    ///
    /// Safe to call during active writes. The backup API acquires a shared lock per
    /// page-step, so writers are not blocked and the destination receives a
    /// consistent snapshot.
    ///
    /// - Parameters:
    ///   - destination: The output file URL. Its parent directory is created if needed.
    ///   - passphrase:  The current database passphrase (used when `decrypt` is `true`).
    ///   - decrypt:     If `true`, strip the SQLCipher key from the copy so it is
    ///                  readable as a plain SQLite file. No-op on stock SQLite builds.
    public func exportDatabase(
        to destination: URL,
        passphrase: String,
        decrypt: Bool = false
    ) throws {
        // Ensure parent directory exists and has enough free space.
        let destDir = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: destDir.path) {
            try FileManager.default.createDirectory(
                at: destDir, withIntermediateDirectories: true
            )
        }
        let dbSize = currentDatabaseFileSize()
        try BackupManager.checkDiskSpace(for: destDir, neededBytes: dbSize)

        // Remove any stale file at the destination before writing.
        try? FileManager.default.removeItem(at: destination)

        // Perform the online backup from within actor isolation, using the raw handle.
        try withDatabaseHandle { handle in
            try DatabaseBackupEngine.backup(from: handle, to: destination.path)
        }

        // If the caller asked for a decrypted copy, re-key the destination with an empty
        // passphrase (SQLCipher PRAGMA rekey). On stock SQLite this is a silent no-op.
        if decrypt {
            Self.stripEncryption(at: destination, passphrase: passphrase)
        }

        Self.backupLog.info("Database exported to: \(destination.path)")
    }

    // MARK: - Auto-Backup

    /// Creates a dated backup in `~/Library/Application Support/Kerwan/Backups/`
    /// and prunes the directory to keep only the four most-recent files.
    ///
    /// Intended to be called from `BackupScheduler` every Sunday at 03:00.
    ///
    /// - Parameter passphrase: The current database passphrase.
    /// - Returns: The URL of the newly-created backup file.
    @discardableResult
    public func performAutoBackup(passphrase: String) throws -> URL {
        let backupsDir = try BackupManager.backupsDirectory()
        try FileManager.default.createDirectory(
            at: backupsDir, withIntermediateDirectories: true
        )

        let dateStr  = BackupManager.dateString(for: Date())
        let destURL  = backupsDir.appendingPathComponent("kerwan_backup_\(dateStr).db")

        try exportDatabase(to: destURL, passphrase: passphrase, decrypt: false)
        try BackupManager.pruneBackups(in: backupsDir, keepLast: 4)

        Self.backupLog.info("Auto-backup written: \(destURL.lastPathComponent)")
        return destURL
    }

    // MARK: - Validation

    /// Validates a backup file by running `PRAGMA integrity_check`.
    ///
    /// - Parameters:
    ///   - url:        URL of the backup `.db` file.
    ///   - passphrase: Passphrase for an encrypted backup, or `""` for plain SQLite.
    /// - Throws: `StorageError.backupCorrupted` if the file is absent or corrupt.
    public func validateBackup(at url: URL, passphrase: String) throws {
        try DatabaseBackupEngine.validate(at: url.path, passphrase: passphrase)
    }

    // MARK: - Restore

    /// Replaces the live database with the backup at `source`.
    ///
    /// Steps performed:
    /// 1. Validate `source` with `PRAGMA integrity_check`.
    /// 2. Check available disk space.
    /// 3. `PRAGMA wal_checkpoint(TRUNCATE)` to fold all WAL frames into the main file.
    /// 4. Copy `source` to a staging path (`kerwan.db.restore`) for atomicity.
    /// 5. Atomically replace `kerwan.db` with the staging file.
    /// 6. Remove stale WAL / SHM sidecar files.
    ///
    /// **The app must restart after this returns.** The `StorageActor`'s existing
    /// connections still point at the now-replaced file and are in an undefined state.
    /// The caller is responsible for initiating the restart (e.g., via `NSApp.relaunch`).
    ///
    /// - Parameters:
    ///   - source:     URL of the backup file to restore.
    ///   - passphrase: Passphrase for both the source backup and the live database.
    public func restoreDatabase(from source: URL, passphrase: String) async throws {
        // 1. Validate
        do {
            try DatabaseBackupEngine.validate(at: source.path, passphrase: passphrase)
        } catch {
            throw StorageError.restoreFailed(error)
        }

        // 2. Disk-space check — the restore copy will be roughly the same size as source.
        let srcSize = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let liveDir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        do {
            try BackupManager.checkDiskSpace(for: liveDir, neededBytes: srcSize)
        } catch {
            throw StorageError.restoreFailed(error)
        }

        // 3. Checkpoint WAL so the main file is fully up-to-date before we overwrite it.
        try? checkpointWAL()

        // 4. Copy to a staging file in the same directory (ensures same filesystem,
        //    so the subsequent replace is a metadata-only rename on APFS/HFS+).
        let stageURL = URL(fileURLWithPath: dbPath + ".restore")
        try? FileManager.default.removeItem(at: stageURL)
        do {
            try FileManager.default.copyItem(at: source, to: stageURL)
        } catch {
            throw StorageError.restoreFailed(error)
        }

        // 5. Atomic replace of the live database.
        let liveURL = URL(fileURLWithPath: dbPath)
        do {
            _ = try FileManager.default.replaceItem(
                at: liveURL,
                withItemAt: stageURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly,
                resultingItemURL: nil
            )
        } catch {
            // replaceItem failed — clean up the stage file and surface the error.
            try? FileManager.default.removeItem(at: stageURL)
            throw StorageError.restoreFailed(error)
        }

        // 6. Remove stale WAL / SHM files from the old database session.
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: dbPath + "-wal")
        )
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: dbPath + "-shm")
        )

        Self.backupLog.info("Database replaced from backup: \(source.lastPathComponent). Restart required.")
    }

    // MARK: - Fresh-Install Import Check

    /// Returns the URL of the most-recent auto-backup if:
    /// - A backup exists in `~/Library/Application Support/Kerwan/Backups/`, **and**
    /// - The live database (`kerwan.db`) does not yet exist.
    ///
    /// Call this during first-launch initialisation to offer a "Restore from Backup?"
    /// sheet before creating a fresh database.
    ///
    /// This is a `static` method because it must be callable before any `StorageActor`
    /// instance is created.
    public static func pendingRestoreURL() -> URL? {
        guard let liveURL = try? BackupManager.liveDatabaseURL(),
              !FileManager.default.fileExists(atPath: liveURL.path),
              let latest = BackupManager.latestBackupURL() else { return nil }
        return latest
    }

    // MARK: - Helpers

    /// Current size of the primary database file in bytes (0 if unreadable).
    func currentDatabaseFileSize() -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath) else { return 0 }
        return attrs[.size] as? Int ?? 0
    }

    /// Re-keys the database at `url` with an empty passphrase, effectively removing
    /// SQLCipher encryption. Silently does nothing on stock SQLite builds.
    private static func stripEncryption(at url: URL, passphrase: String) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let db else { return }
        defer { sqlite3_close_v2(db) }

        sqlite3_exec(db, "PRAGMA key = '\(passphrase)'",  nil, nil, nil)
        // PRAGMA rekey = '' removes the encryption key (SQLCipher only).
        sqlite3_exec(db, "PRAGMA rekey = ''", nil, nil, nil)
    }
}
