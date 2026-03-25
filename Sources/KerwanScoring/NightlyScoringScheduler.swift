import Foundation
import os.log

// MARK: - NightlyScoringScheduler

/// Runs `RelationshipScoreEngine.runNightlyScoring()` every night at a configurable
/// time (default 02:00 local time).
///
/// ## Lifecycle
///
/// Call `start()` once at app launch. The scheduler sleeps until the next scheduled
/// run, executes the scoring pass, then sleeps until the following night. Call
/// `stop()` to cancel the background task (e.g. during app termination or test teardown).
///
/// ```swift
/// let scheduler = NightlyScoringScheduler(engine: scoringEngine)
/// await scheduler.start()
/// // … later …
/// await scheduler.stop()
/// ```
///
/// ## Concurrency
///
/// `NightlyScoringScheduler` is an `actor`. Its internal `Task` crosses the
/// isolation boundary safely: `start()` captures `self` as an isolated reference,
/// and `Task.sleep` does not hold the actor lock while waiting.
public actor NightlyScoringScheduler {

    // MARK: - State

    private let engine: RelationshipScoreEngine
    private let log = Logger(subsystem: "com.kerwan.app", category: "NightlyScoringScheduler")

    /// Hour of day (local time) at which the nightly pass runs. Default: 2 (02:00).
    public let scheduledHour: Int

    /// Minute within `scheduledHour` at which the nightly pass runs. Default: 0.
    public let scheduledMinute: Int

    private var schedulerTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates a scheduler that will run scoring nightly at `hour`:`minute` local time.
    ///
    /// - Parameters:
    ///   - engine: The scoring engine to invoke each night.
    ///   - hour:   Local hour (0–23) for the nightly run. Default: 2.
    ///   - minute: Local minute (0–59) for the nightly run. Default: 0.
    public init(engine: RelationshipScoreEngine, hour: Int = 2, minute: Int = 0) {
        self.engine          = engine
        self.scheduledHour   = max(0, min(23, hour))
        self.scheduledMinute = max(0, min(59, minute))
    }

    // MARK: - Lifecycle

    /// Starts the background scheduling loop.
    ///
    /// Safe to call multiple times — a second call cancels any existing loop and
    /// starts a fresh one, which is useful after a settings change.
    public func start() {
        schedulerTask?.cancel()
        log.info("Nightly scoring scheduler starting (target: \(self.scheduledHour, privacy: .public):\(String(format: "%02d", self.scheduledMinute), privacy: .public) local time).")

        schedulerTask = Task { [self] in
            while !Task.isCancelled {
                let delay = NightlyScoringScheduler.secondsUntilNextRun(
                    hour:   scheduledHour,
                    minute: scheduledMinute
                )
                log.info("Next nightly scoring in \(String(format: "%.0f", delay))s.")

                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    // Task was cancelled during sleep — exit cleanly.
                    break
                }

                guard !Task.isCancelled else { break }

                do {
                    let report = try await engine.runNightlyScoring()
                    log.info("""
                        Nightly scoring finished: \
                        \(report.contactsScored) scored, \
                        \(report.failedContactIds.count) failed, \
                        \(String(format: "%.2f", report.duration))s elapsed.
                        """)
                } catch {
                    log.error("Nightly scoring pass failed: \(error)")
                    // Continue the loop — retry next night.
                }
            }
            log.info("Nightly scoring scheduler stopped.")
        }
    }

    /// Cancels the scheduling loop. Safe to call when no loop is running.
    public func stop() {
        schedulerTask?.cancel()
        schedulerTask = nil
        log.info("Nightly scoring scheduler stop requested.")
    }

    /// `true` while the scheduling loop is active (task exists and not yet cancelled).
    public var isRunning: Bool {
        schedulerTask.map { !$0.isCancelled } ?? false
    }

    // MARK: - Time calculation

    /// Returns the number of seconds until the next occurrence of `hour`:`minute`
    /// in the local calendar, counting from `from`.
    ///
    /// If `hour`:`minute` is in the past today, returns the delay to tomorrow's
    /// occurrence.  The minimum returned value is 60 seconds to avoid a busy-loop
    /// if the clock is exactly at the target time.
    static func secondsUntilNextRun(
        hour:     Int,
        minute:   Int,
        calendar: Calendar = .current,
        from now: Date = Date()
    ) -> TimeInterval {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour   = hour
        components.minute = minute
        components.second = 0
        components.nanosecond = 0

        guard let todayTarget = calendar.date(from: components) else {
            return 86400 // fallback: try again in 24 hours
        }

        let candidate: Date
        if todayTarget > now {
            candidate = todayTarget
        } else {
            candidate = calendar.date(byAdding: .day, value: 1, to: todayTarget) ?? todayTarget
        }

        return max(60, candidate.timeIntervalSince(now))
    }
}
