import Foundation
import os.log

// MARK: - LogLevel

public enum LogLevel: String, Sendable, CaseIterable {
    case debug   = "DEBUG"
    case info    = "INFO"
    case warning = "WARNING"
    case error   = "ERROR"
    case fault   = "FAULT"
}

// MARK: - LogEntry

public struct LogEntry: Sendable {
    public let timestamp:  Date
    public let subsystem:  String
    public let category:   String
    public let level:      LogLevel
    public let message:    String
    public let stackTrace: String?

    public init(
        timestamp:  Date   = Date(),
        subsystem:  String,
        category:   String,
        level:      LogLevel,
        message:    String,
        stackTrace: String? = nil
    ) {
        self.timestamp  = timestamp
        self.subsystem  = subsystem
        self.category   = category
        self.level      = level
        self.message    = message
        self.stackTrace = stackTrace
    }

    // MARK: - Formatted line

    /// Single-line representation written to the log file.
    ///
    /// Format: `ISO8601 [LEVEL] subsystem/category: message\n`
    ///         (stack trace appended on subsequent lines if present)
    var formatted: String {
        let ts = ISO8601DateFormatter().string(from: timestamp)
        var line = "\(ts) [\(level.rawValue)] \(subsystem)/\(category): \(message)"
        if let stack = stackTrace {
            line += "\n" + stack
                .split(separator: "\n")
                .map { "    " + $0 }
                .joined(separator: "\n")
        }
        return line + "\n"
    }
}

// MARK: - ErrorReporter

/// Structured file logger for Kerwan diagnostics.
///
/// Writes to `~/Library/Application Support/Kerwan/Logs/kerwan-YYYY-MM-DD.log`.
/// Rotates weekly: logs older than `keepWeeks` (default 4) are deleted on every
/// `log(_:)` call.
///
/// Export all logs as a ZIP archive via `exportLogs(to:)`.
///
/// Thread-safe: protected by an `NSLock`.
public final class ErrorReporter: @unchecked Sendable {

    // MARK: - State

    private let lock = NSLock()
    private let keepWeeks: Int
    private let fileManager = FileManager.default
    private let systemLog = Logger(subsystem: "com.kerwan.app", category: "ErrorReporter")

    // MARK: - Init

    public init(keepWeeks: Int = 4) {
        self.keepWeeks = keepWeeks
    }

    // MARK: - Public API

    /// Write a structured log entry to the daily log file.
    public func log(_ entry: LogEntry) {
        lock.lock()
        defer { lock.unlock() }

        guard let logsDir = try? logsDirectory() else { return }
        let logFile = logsDir.appendingPathComponent(
            "kerwan-\(dateString(for: entry.timestamp)).log"
        )

        let text = entry.formatted
        if fileManager.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
            }
        } else {
            try? text.write(to: logFile, atomically: true, encoding: .utf8)
        }

        pruneOldLogs(in: logsDir)
    }

    /// Convenience overload for quick one-liners.
    public func log(
        subsystem: String = "com.kerwan.app",
        category: String,
        level: LogLevel,
        message: String,
        stackTrace: String? = nil
    ) {
        log(LogEntry(
            subsystem: subsystem,
            category: category,
            level: level,
            message: message,
            stackTrace: stackTrace
        ))
    }

    /// All log file URLs sorted newest-first.
    public func allLogFiles() -> [URL] {
        guard let logsDir = try? logsDirectory() else { return [] }
        let urls = (try? fileManager.contentsOfDirectory(
            at: logsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix("kerwan-") && $0.pathExtension == "log" }
            .sorted {
                let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d0 > d1
            }
    }

    /// Creates a ZIP archive containing all log files at `destination`.
    ///
    /// Uses `/usr/bin/zip` (always present on macOS).
    ///
    /// - Parameter destination: The output `.zip` URL (parent must exist).
    /// - Throws: If the `zip` process fails or the logs directory is missing.
    public func exportLogs(to destination: URL) throws {
        let logs = allLogFiles()
        guard !logs.isEmpty else {
            throw ExportError.noLogsFound
        }

        // Build the arg list: zip destination file1 file2 ...
        let args = [destination.path] + logs.map(\.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = args

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg  = String(data: errData, encoding: .utf8) ?? "unknown"
            throw ExportError.zipFailed(errMsg)
        }
        systemLog.info("Exported \(logs.count) log file(s) to \(destination.lastPathComponent).")
    }

    // MARK: - Private helpers

    func logsDirectory() throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport
            .appendingPathComponent("Kerwan", isDirectory: true)
            .appendingPathComponent("Logs",   isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func pruneOldLogs(in dir: URL) {
        guard let cutoff = Calendar.current.date(
            byAdding: .weekOfYear, value: -keepWeeks, to: Date()
        ) else { return }

        let urls = (try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []

        for url in urls where url.lastPathComponent.hasPrefix("kerwan-") && url.pathExtension == "log" {
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modDate < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func dateString(for date: Date) -> String {
        let cal  = Calendar(identifier: .gregorian)
        let comp = cal.dateComponents([.year, .month, .day], from: date)
        let y = comp.year  ?? 2000
        let m = comp.month ?? 1
        let d = comp.day   ?? 1
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}

// MARK: - ExportError

public enum ExportError: Error, LocalizedError {
    case noLogsFound
    case zipFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noLogsFound:
            return "No log files found to export."
        case .zipFailed(let detail):
            return "ZIP export failed: \(detail)"
        }
    }
}
