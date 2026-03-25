import Foundation
import os.log

// MARK: - BackupManager

/// File-system helpers for managing Kerwan database backups.
///
/// All methods are static and `Sendable`-safe; they operate purely on the
/// file system and carry no mutable state.
public enum BackupManager {

    private static let log = Logger(subsystem: "com.kerwan.app", category: "BackupManager")

    // MARK: - Well-known Paths

    /// `~/Library/Application Support/Kerwan/Backups/`
    public static func backupsDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport
            .appendingPathComponent("Kerwan", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
    }

    /// `~/Library/Application Support/Kerwan/kerwan.db`
    public static func liveDatabaseURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport
            .appendingPathComponent("Kerwan", isDirectory: true)
            .appendingPathComponent("kerwan.db")
    }

    // MARK: - Pruning

    /// Deletes auto-backup files beyond the `keepLast` most-recent, sorted by
    /// modification date (newest first).
    ///
    /// Only files whose names match `kerwan_backup_*.db` are considered; other
    /// files in the directory (e.g., user-named manual exports) are left alone.
    ///
    /// - Parameters:
    ///   - directory: The backups directory to inspect.
    ///   - keepLast:  Number of most-recent backups to retain (default 4).
    public static func pruneBackups(in directory: URL, keepLast: Int = 4) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }

        let contents = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )

        // Only touch files matching the auto-backup naming scheme.
        let backups = contents
            .filter { $0.pathExtension == "db" &&
                      $0.lastPathComponent.hasPrefix("kerwan_backup_") }
            .sorted { a, b in
                modDate(a) > modDate(b)   // newest first
            }

        guard backups.count > keepLast else { return }

        for url in backups.dropFirst(keepLast) {
            log.info("Pruning old backup: \(url.lastPathComponent)")
            try fm.removeItem(at: url)
        }
    }

    // MARK: - Disk Space

    /// Throws `StorageError.insufficientDiskSpace` if `directory`'s volume has less
    /// free space than `neededBytes`.
    ///
    /// Uses `volumeAvailableCapacityForImportantUsageKey` (the "important usage" quota
    /// that macOS reserves for user-initiated actions — appropriate for backup files).
    ///
    /// - Parameters:
    ///   - directory:   A URL on the target volume (the backup destination directory).
    ///   - neededBytes: Minimum bytes required.
    public static func checkDiskSpace(for directory: URL, neededBytes: Int) throws {
        guard neededBytes > 0 else { return }
        var dir = directory
        // If directory doesn't exist yet, check its nearest existing ancestor.
        let fm = FileManager.default
        while !fm.fileExists(atPath: dir.path) {
            let parent = dir.deletingLastPathComponent()
            guard parent != dir else { break }
            dir = parent
        }
        let values = try dir.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        guard available > Int64(neededBytes) else {
            throw StorageError.insufficientDiskSpace(
                available: available,
                required: Int64(neededBytes)
            )
        }
    }

    // MARK: - Naming

    /// Returns a `"YYYY-MM-DD"` string for use in backup file names.
    public static func dateString(for date: Date, calendar: Calendar = .current) -> String {
        let y = calendar.component(.year,  from: date)
        let m = calendar.component(.month, from: date)
        let d = calendar.component(.day,   from: date)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    // MARK: - Discovery

    /// Returns all auto-backup files in the default backups directory, sorted
    /// newest-first, or an empty array if the directory doesn't exist.
    public static func allBackups() -> [URL] {
        guard let dir = try? backupsDirectory(),
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: dir,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: .skipsHiddenFiles
              ) else { return [] }

        return contents
            .filter { $0.pathExtension == "db" &&
                      $0.lastPathComponent.hasPrefix("kerwan_backup_") }
            .sorted { modDate($0) > modDate($1) }
    }

    /// Returns the most-recently-modified auto-backup, or `nil` if none exist.
    public static func latestBackupURL() -> URL? {
        allBackups().first
    }

    // MARK: - Private helpers

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
}
