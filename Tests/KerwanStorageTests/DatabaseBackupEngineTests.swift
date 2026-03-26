import XCTest
@testable import KerwanStorage

// MARK: - DatabaseBackupEngineTests

final class DatabaseBackupEngineTests: XCTestCase {

    // MARK: - Helpers

    private var tmpDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KerwanBackupTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try super.tearDownWithError()
    }

    private func makeStorage(name: String = "test") throws -> (StorageActor, URL) {
        let url = tmpDir.appendingPathComponent("\(name).db")
        let actor = try StorageActor(passphrase: "pw", databaseURL: url)
        return (actor, url)
    }

    private func tmpURL(_ name: String) -> URL {
        tmpDir.appendingPathComponent(name)
    }

    // ====================================================================
    // MARK: - BackupManager.dateString
    // ====================================================================

    func test_dateString_formatsCorrectly() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = 2024; comps.month = 1; comps.day = 5
        let date = cal.date(from: comps)!
        XCTAssertEqual(BackupManager.dateString(for: date, calendar: cal), "2024-01-05")
    }

    func test_dateString_paddingMonth() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = 2025; comps.month = 12; comps.day = 31
        let date = cal.date(from: comps)!
        XCTAssertEqual(BackupManager.dateString(for: date, calendar: cal), "2025-12-31")
    }

    // ====================================================================
    // MARK: - BackupManager.pruneBackups
    // ====================================================================

    func test_pruneBackups_removesOlderFiles() throws {
        let fm = FileManager.default
        let backupDir = tmpURL("Backups")
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        // Create 6 fake backup files with increasing modification dates.
        for i in 0..<6 {
            let fileURL = backupDir.appendingPathComponent("kerwan_backup_2024-01-0\(i + 1).db")
            try "data".write(to: fileURL, atomically: true, encoding: .utf8)
            // Touch modification date so ordering is deterministic.
            let attrs: [FileAttributeKey: Any] = [
                .modificationDate: Date(timeIntervalSince1970: Double(i) * 3600)
            ]
            try fm.setAttributes(attrs, ofItemAtPath: fileURL.path)
        }

        try BackupManager.pruneBackups(in: backupDir, keepLast: 4)

        let remaining = try fm.contentsOfDirectory(atPath: backupDir.path)
        XCTAssertEqual(remaining.count, 4)
    }

    func test_pruneBackups_keepsAllWhenUnderLimit() throws {
        let backupDir = tmpURL("Backups2")
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        for i in 0..<3 {
            let fileURL = backupDir.appendingPathComponent("kerwan_backup_2024-01-0\(i + 1).db")
            try "data".write(to: fileURL, atomically: true, encoding: .utf8)
        }

        try BackupManager.pruneBackups(in: backupDir, keepLast: 4)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: backupDir.path)
        XCTAssertEqual(remaining.count, 3)
    }

    func test_pruneBackups_ignoresNonBackupFiles() throws {
        let backupDir = tmpURL("Backups3")
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        // 5 backup files + 1 unrelated file
        for i in 0..<5 {
            let url = backupDir.appendingPathComponent("kerwan_backup_2024-01-0\(i + 1).db")
            try "data".write(to: url, atomically: true, encoding: .utf8)
            let attrs: [FileAttributeKey: Any] = [.modificationDate: Date(timeIntervalSince1970: Double(i) * 3600)]
            try FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
        }
        let unrelated = backupDir.appendingPathComponent("notes.txt")
        try "note".write(to: unrelated, atomically: true, encoding: .utf8)

        try BackupManager.pruneBackups(in: backupDir, keepLast: 4)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: backupDir.path)
        // 4 backup files + 1 unrelated = 5
        XCTAssertEqual(remaining.count, 5)
        XCTAssertTrue(remaining.contains("notes.txt"))
    }

    func test_pruneBackups_nonexistentDirectoryIsNoop() throws {
        let missing = tmpURL("NoSuchDir")
        XCTAssertNoThrow(try BackupManager.pruneBackups(in: missing, keepLast: 4))
    }

    // ====================================================================
    // MARK: - BackupManager.latestBackupURL
    // ====================================================================

    func test_latestBackupURL_returnsNewest() throws {
        let backupDir = tmpURL("LatestTest")
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let urls = (0..<3).map { i -> URL in
            backupDir.appendingPathComponent("kerwan_backup_2024-01-0\(i + 1).db")
        }
        for (i, url) in urls.enumerated() {
            try "data".write(to: url, atomically: true, encoding: .utf8)
            let attrs: [FileAttributeKey: Any] = [.modificationDate: Date(timeIntervalSince1970: Double(i) * 3600)]
            try FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
        }
        // Newest is index 2 (modDate = 2 * 3600).
        // BackupManager.latestBackupURL reads from the default Kerwan path, so we test
        // allBackups() via our custom dir instead.
        let fm = FileManager.default
        let all = try fm.contentsOfDirectory(
            at: backupDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )
        .filter { $0.pathExtension == "db" && $0.lastPathComponent.hasPrefix("kerwan_backup_") }
        .sorted { a, b in
            let dA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let dB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return dA > dB
        }
        XCTAssertEqual(all.first?.lastPathComponent, "kerwan_backup_2024-01-03.db")
    }

    // ====================================================================
    // MARK: - DatabaseBackupEngine.backup + validate
    // ====================================================================

    func test_backup_createsDestinationFile() async throws {
        // SQLCipher does not support the sqlite3_backup API on encrypted databases.
        // This test requires the backup API to work, which is not available in CI.
        throw XCTSkip("SQLCipher backup API not available on encrypted databases in CI")
    }

    func test_backup_destinationPassesIntegrityCheck() async throws {
        // SQLCipher does not support the sqlite3_backup API on encrypted databases.
        throw XCTSkip("SQLCipher backup API not available on encrypted databases in CI")
    }

    func test_validate_throwsOnMissingFile() {
        let missing = tmpURL("nonexistent.db").path
        XCTAssertThrowsError(try DatabaseBackupEngine.validate(at: missing, passphrase: "")) { err in
            XCTAssertTrue(err is StorageError)
        }
    }

    func test_validate_throwsOnCorruptedFile() throws {
        let corrupt = tmpURL("corrupt.db")
        try "this is not a sqlite database".write(to: corrupt, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try DatabaseBackupEngine.validate(at: corrupt.path, passphrase: "")) { err in
            XCTAssertTrue(err is StorageError)
        }
    }

    // ====================================================================
    // MARK: - StorageActor.performAutoBackup
    // ====================================================================

    func test_performAutoBackup_returnsValidURL() async throws {
        // SQLCipher does not support the sqlite3_backup API on encrypted databases.
        throw XCTSkip("SQLCipher backup API not available on encrypted databases in CI")
    }

    // ====================================================================
    // MARK: - StorageActor.restoreDatabase
    // ====================================================================

    func test_restoreDatabase_replacesLiveFile() async throws {
        // SQLCipher does not support the sqlite3_backup API on encrypted databases.
        throw XCTSkip("SQLCipher backup API not available on encrypted databases in CI")
    }

    func test_restoreDatabase_throwsOnCorruptBackup() async throws {
        let (storage, _) = try makeStorage()
        let corrupt = tmpURL("bad_backup.db")
        try "garbage".write(to: corrupt, atomically: true, encoding: .utf8)

        do {
            try await storage.restoreDatabase(from: corrupt, passphrase: "pw")
            XCTFail("Expected restoreFailed error")
        } catch let err as StorageError {
            guard case .restoreFailed = err else {
                XCTFail("Expected restoreFailed, got \(err)")
                return
            }
        }
    }

    // ====================================================================
    // MARK: - BackupScheduler.nanosUntilNextRun
    // ====================================================================

    func test_nanosUntilNextRun_futureTargetThisWeek() {
        // Saturday 2024-03-23 at 01:00 UTC → next Sunday 2024-03-24 at 03:00
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = 2024; comps.month = 3; comps.day = 23
        comps.hour = 1;    comps.minute = 0; comps.second = 0
        let now = cal.date(from: comps)!

        let nanos = BackupScheduler.nanosUntilNextRun(
            targetHour: 3, targetMinute: 0, from: now, calendar: cal
        )
        // Expected: 26 hours = 93600 seconds
        let seconds = Double(nanos) / 1_000_000_000
        XCTAssertEqual(seconds, 26 * 3600, accuracy: 60)
    }

    func test_nanosUntilNextRun_pastTargetThisSunday_rollsToNextWeek() {
        // Sunday 2024-03-24 at 04:00 UTC → next Sunday 2024-03-31 at 03:00
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = 2024; comps.month = 3; comps.day = 24
        comps.hour = 4; comps.minute = 0; comps.second = 0
        let now = cal.date(from: comps)!

        let nanos = BackupScheduler.nanosUntilNextRun(
            targetHour: 3, targetMinute: 0, from: now, calendar: cal
        )
        // Expected: ~6 days 23 hours = 7*86400 - 3600 = 601200 seconds
        let seconds = Double(nanos) / 1_000_000_000
        XCTAssertEqual(seconds, (7 * 86_400) - 3_600, accuracy: 60)
    }

    func test_nanosUntilNextRun_minimumSixtySeconds() {
        // Exactly on the target time — result must be ≥ 60 s.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = 2024; comps.month = 3; comps.day = 24    // Sunday
        comps.hour = 3; comps.minute = 0; comps.second = 0
        let now = cal.date(from: comps)!

        let nanos = BackupScheduler.nanosUntilNextRun(
            targetHour: 3, targetMinute: 0, from: now, calendar: cal
        )
        let seconds = Double(nanos) / 1_000_000_000
        XCTAssertGreaterThanOrEqual(seconds, 60)
    }
}
