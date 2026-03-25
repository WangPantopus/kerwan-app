import Foundation
import os.log

// MARK: - BackupScheduler

/// Runs `StorageActor.performAutoBackup` once every Sunday at 03:00 local time.
///
/// The scheduler wakes from `Task.sleep` at the precise moment, performs the
/// backup, then immediately calculates the next Sunday's target and sleeps again.
/// It survives macOS sleep/wake cycles because the next-run calculation is always
/// relative to `Date()` at wake time.
///
/// Usage:
/// ```swift
/// let scheduler = BackupScheduler(storage: storageActor, passphrase: key)
/// await scheduler.start()
/// ```
public actor BackupScheduler {

    // MARK: - State

    private let storage: StorageActor
    private let passphrase: String
    /// Hour of day (0-23) at which the backup runs. Default: 3.
    private let targetHour: Int
    /// Minute within the hour. Default: 0.
    private let targetMinute: Int

    private var loopTask: Task<Void, Never>?

    private static let log = Logger(subsystem: "com.kerwan.app", category: "BackupScheduler")

    // MARK: - Init

    public init(
        storage: StorageActor,
        passphrase: String,
        targetHour: Int = 3,
        targetMinute: Int = 0
    ) {
        self.storage      = storage
        self.passphrase   = passphrase
        self.targetHour   = targetHour
        self.targetMinute = targetMinute
    }

    // MARK: - Lifecycle

    /// Starts the weekly backup loop. Safe to call multiple times — only one loop runs.
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
        Self.log.info("BackupScheduler started (target: Sunday \(self.targetHour):\(String(format: "%02d", self.targetMinute)))")
    }

    /// Cancels any pending sleep and stops the scheduler.
    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        Self.log.info("BackupScheduler stopped")
    }

    // MARK: - Loop

    private func runLoop() async {
        while !Task.isCancelled {
            let nanos = Self.nanosUntilNextRun(
                targetHour:   targetHour,
                targetMinute: targetMinute,
                from: Date()
            )
            Self.log.info("Next auto-backup in \(nanos / 1_000_000_000)s (~\(nanos / 3_600_000_000_000)h)")

            do {
                try await Task.sleep(nanoseconds: nanos)
            } catch {
                break   // Cancelled
            }

            guard !Task.isCancelled else { break }
            await triggerBackup()
        }
    }

    private func triggerBackup() async {
        do {
            let url = try await storage.performAutoBackup(passphrase: passphrase)
            Self.log.info("Auto-backup succeeded: \(url.lastPathComponent)")
        } catch {
            Self.log.error("Auto-backup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Next-Run Calculation

    /// Returns the number of nanoseconds until the next Sunday at
    /// `targetHour:targetMinute` local time.
    ///
    /// - If today is Sunday and the target time is still in the future, the result
    ///   points to that time today.
    /// - If today is Sunday but the target has already passed, or today is any
    ///   other day, the result points to next Sunday.
    /// - The result is always at least 60 seconds to avoid tight loops near
    ///   scheduling boundaries.
    ///
    /// - Parameters:
    ///   - targetHour:   Hour component (0-23) of the desired run time.
    ///   - targetMinute: Minute component (0-59) of the desired run time.
    ///   - from:         The reference "now" date. Injected for testability.
    ///   - calendar:     Calendar to use for date arithmetic. Injected for testability.
    public static func nanosUntilNextRun(
        targetHour:   Int,
        targetMinute: Int,
        from now:     Date,
        calendar:     Calendar = .current
    ) -> UInt64 {
        // Build a DateComponents for "this week's Sunday at targetHour:targetMinute".
        // weekday 1 = Sunday in Gregorian calendars.
        var comps = calendar.dateComponents(
            [.yearForWeekOfYear, .weekOfYear],
            from: now
        )
        comps.weekday = 1
        comps.hour    = targetHour
        comps.minute  = targetMinute
        comps.second  = 0

        var target = calendar.date(from: comps)
            ?? now.addingTimeInterval(7 * 86_400)

        // If this Sunday's target is already in the past, advance one week.
        if target <= now {
            target = calendar.date(byAdding: .weekOfYear, value: 1, to: target)
                ?? target.addingTimeInterval(7 * 86_400)
        }

        let seconds = max(60.0, target.timeIntervalSince(now))
        return UInt64(seconds * 1_000_000_000)
    }
}
