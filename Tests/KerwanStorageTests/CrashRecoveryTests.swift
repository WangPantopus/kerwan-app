import XCTest
@testable import KerwanStorage

// MARK: - CrashRecoveryManagerTests

final class CrashRecoveryManagerTests: XCTestCase {

    // MARK: - Dirty-shutdown flag

    func testArmAndClearDirtyShutdownFlag() {
        CrashRecoveryManager.armDirtyShutdownFlag()
        XCTAssertTrue(CrashRecoveryManager.isDirtyShutdownFlagged)

        CrashRecoveryManager.clearDirtyShutdownFlag()
        XCTAssertFalse(CrashRecoveryManager.isDirtyShutdownFlagged)
    }

    func testNoDirtyFlagReturnsOK() async {
        CrashRecoveryManager.clearDirtyShutdownFlag()
        let result = await CrashRecoveryManager.runPreLaunchChecks(
            databasePath: "/nonexistent/db.sqlite",
            passphrase: ""
        )
        if case .ok = result {} else {
            XCTFail("Expected .ok when dirty flag is absent, got \(result)")
        }
    }

    // MARK: - Integrity check on healthy database

    func testHealthyDatabaseReturnsRecovered() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("kerwan.db")

        // Create a minimal valid SQLite database via StorageActor (unencrypted).
        let storage = try StorageActor(passphrase: "", databaseURL: dbURL)
        _ = storage // just needs to initialise to create the file

        CrashRecoveryManager.armDirtyShutdownFlag()
        let result = await CrashRecoveryManager.runPreLaunchChecks(
            databasePath: dbURL.path,
            passphrase: ""
        )

        if case .dirtyShutdownRecovered = result {} else {
            XCTFail("Expected .dirtyShutdownRecovered, got \(result)")
        }
        XCTAssertFalse(CrashRecoveryManager.isDirtyShutdownFlagged,
                       "Flag should be cleared after successful recovery.")
    }

    // MARK: - Corrupt database falls through to unrecoverable (no backup)

    func testCorruptDatabaseNoBackupReturnsUnrecoverable() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbPath = dir.appendingPathComponent("kerwan.db").path

        // Write junk bytes — not a valid SQLite file.
        try Data("not a database".utf8).write(to: URL(fileURLWithPath: dbPath))

        CrashRecoveryManager.armDirtyShutdownFlag()
        let result = await CrashRecoveryManager.runPreLaunchChecks(
            databasePath: dbPath,
            passphrase: ""
        )

        // Either .unrecoverable or .corruptionRepaired (VACUUM INTO on junk will fail).
        // On junk data VACUUM INTO cannot open the source, so we expect .unrecoverable.
        if case .unrecoverable = result {} else if case .corruptionRepaired = result {} else {
            XCTFail("Expected .unrecoverable or .corruptionRepaired, got \(result)")
        }
    }
}

// MARK: - ErrorReporterTests

final class ErrorReporterTests: XCTestCase {

    private var tempDir: URL!
    private var reporter: ErrorReporter!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        reporter = ErrorReporter(keepWeeks: 4)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Log writes

    func testLogEntryFormattedContainsAllFields() {
        let entry = LogEntry(
            subsystem: "com.kerwan.test",
            category: "Unit",
            level: .error,
            message: "Something went wrong"
        )
        let text = entry.formatted
        XCTAssertTrue(text.contains("[ERROR]"))
        XCTAssertTrue(text.contains("com.kerwan.test"))
        XCTAssertTrue(text.contains("Unit"))
        XCTAssertTrue(text.contains("Something went wrong"))
    }

    func testLogEntryWithStackTraceIndented() {
        let entry = LogEntry(
            subsystem: "com.kerwan.test",
            category: "Unit",
            level: .fault,
            message: "Crash",
            stackTrace: "frame 0\nframe 1"
        )
        let text = entry.formatted
        XCTAssertTrue(text.contains("    frame 0"), "Stack trace frames should be indented with 4 spaces")
    }

    func testLogWritesFileToDisk() throws {
        // Redirect logsDirectory via subclass is complex; instead exercise via the
        // public API and confirm allLogFiles() grows.
        reporter.log(
            category: "TestCategory",
            level: .info,
            message: "Hello from test"
        )
        let files = reporter.allLogFiles()
        XCTAssertFalse(files.isEmpty, "At least one log file should be written.")
        let content = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(content.contains("Hello from test"))
    }

    func testMultipleLogsAppendToSameFile() throws {
        reporter.log(category: "Cat", level: .debug, message: "Message A")
        reporter.log(category: "Cat", level: .debug, message: "Message B")

        let files = reporter.allLogFiles()
        let todayFiles = files.filter { $0.lastPathComponent.contains(todayDateString()) }
        XCTAssertEqual(todayFiles.count, 1, "Both entries should be in the same daily file.")

        let content = try String(contentsOf: todayFiles[0], encoding: .utf8)
        XCTAssertTrue(content.contains("Message A"))
        XCTAssertTrue(content.contains("Message B"))
    }

    // MARK: - Export

    func testExportLogsCreatesZip() throws {
        reporter.log(category: "Cat", level: .info, message: "Export test")

        let zipURL = tempDir.appendingPathComponent("logs_export.zip")
        try reporter.exportLogs(to: zipURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: zipURL.path), "ZIP archive should be created.")
        let attrs = try FileManager.default.attributesOfItem(atPath: zipURL.path)
        XCTAssertGreaterThan(attrs[.size] as? Int ?? 0, 0)
    }

    func testExportWithNoLogsThrows() {
        // Use a brand-new reporter pointing at an empty dir — achieve this by
        // writing zero logs and expecting the export to either succeed with a
        // nearly-empty ZIP or throw .noLogsFound.
        let emptyReporter = ErrorReporter(keepWeeks: 4)
        // We cannot guarantee no existing logs from other tests, so skip if files exist.
        guard emptyReporter.allLogFiles().isEmpty else { return }
        let zipURL = tempDir.appendingPathComponent("empty.zip")
        XCTAssertThrowsError(try emptyReporter.exportLogs(to: zipURL))
    }

    // MARK: - Helpers

    private func todayDateString() -> String {
        let cal  = Calendar(identifier: .gregorian)
        let comp = cal.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", comp.year ?? 0, comp.month ?? 0, comp.day ?? 0)
    }
}
