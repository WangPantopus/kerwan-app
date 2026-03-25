import Foundation
import os

// MARK: - SubsystemHealth

/// Health state for a single tracked subsystem.
public enum SubsystemHealth: Equatable, Sendable {
    /// Operating normally.
    case healthy
    /// A transient failure; automatic recovery is being attempted.
    /// `retryCount` is the number of retries so far.
    case degraded(reason: String, retryCount: Int)
    /// The subsystem has failed permanently for this session.
    /// User action (e.g. granting permissions or restarting a service) is required.
    case failed(reason: String)
}

// MARK: - Subsystem

/// Identifiers for subsystems tracked by `GracefulDegradationManager`.
public enum Subsystem: String, CaseIterable, Sendable {
    case whisper    = "Whisper"
    case ollama     = "Ollama"
    case imap       = "IMAP"
    case axPermission = "Accessibility"
    case database   = "Database"
}

// MARK: - GracefulDegradationManager

/// Tracks the health of key Kerwan subsystems and exposes fallback actions.
///
/// ### Degradation table
///
/// | Subsystem       | Failure trigger                        | Fallback behaviour                          |
/// |-----------------|----------------------------------------|---------------------------------------------|
/// | Whisper         | XPC service crash / model not loaded   | Queue audio segments; transcribe when ready |
/// | Ollama          | Process not running / HTTP 5xx         | Pause AI classification; buffer events      |
/// | IMAP            | Network error / auth failure           | Exponential-backoff retry (max 5)           |
/// | AX Permission   | `kAXErrorAPIDisabled` or denied        | Stop app-tracking; notify user              |
/// | Database        | `SQLITE_FULL` / write error            | Alert user; pause all capture writes        |
///
/// Observations are `@Observable` so SwiftUI views can react to health changes.
@Observable
@MainActor
public final class GracefulDegradationManager {

    // MARK: - State

    /// Current health for each subsystem, keyed by `Subsystem`.
    public private(set) var health: [Subsystem: SubsystemHealth] = {
        var h: [Subsystem: SubsystemHealth] = [:]
        for s in Subsystem.allCases { h[s] = .healthy }
        return h
    }()

    /// `true` when at least one subsystem is not `.healthy`.
    public var hasAnyDegradation: Bool {
        health.values.contains { if case .healthy = $0 { return false }; return true }
    }

    private let log = Logger(subsystem: "com.kerwan.app", category: "GracefulDegradation")

    // MARK: - IMAP retry state (private)

    private var imapRetryTask: Task<Void, Never>?
    private var imapRetryCount: Int = 0
    private static let imapMaxRetries = 5
    /// Base delay in seconds for IMAP backoff (doubles each attempt).
    private static let imapBaseDelaySeconds: Double = 15.0

    // MARK: - Reporting failures

    /// Mark a subsystem as failed.
    ///
    /// Applies the subsystem-specific fallback strategy automatically:
    /// - **Whisper**: sets state to `.degraded` (queueing mode).
    /// - **Ollama**: sets state to `.degraded` (classification paused).
    /// - **IMAP**: starts exponential-backoff retry loop.
    /// - **AX permission**: sets state to `.failed` (requires user action).
    /// - **Database**: sets state to `.failed`; caller should stop writes.
    ///
    /// - Parameters:
    ///   - subsystem: The subsystem that encountered an error.
    ///   - reason:    Human-readable description of the failure.
    ///   - retryHandler: Optional async closure to invoke during IMAP retry.
    ///     Must return `true` on success. Ignored for non-IMAP subsystems.
    public func reportFailure(
        _ subsystem: Subsystem,
        reason: String,
        retryHandler: (@Sendable () async -> Bool)? = nil
    ) {
        log.error("[\(subsystem.rawValue)] failure: \(reason)")

        switch subsystem {
        case .whisper:
            health[.whisper] = .degraded(reason: reason, retryCount: 0)
            log.warning("Whisper degraded — audio segments will be queued.")

        case .ollama:
            health[.ollama] = .degraded(reason: reason, retryCount: 0)
            log.warning("Ollama degraded — AI classification paused.")

        case .imap:
            imapRetryCount = 0
            health[.imap] = .degraded(reason: reason, retryCount: 0)
            if let handler = retryHandler {
                startIMAPRetryLoop(reason: reason, handler: handler)
            }

        case .axPermission:
            health[.axPermission] = .failed(reason: reason)
            log.error("Accessibility permission denied — app tracking stopped.")

        case .database:
            health[.database] = .failed(reason: reason)
            log.fault("Database failed — capture writes paused. Reason: \(reason)")
        }
    }

    /// Mark a subsystem as recovered.
    public func reportRecovery(_ subsystem: Subsystem) {
        log.info("[\(subsystem.rawValue)] recovered.")
        health[subsystem] = .healthy
        if subsystem == .imap {
            imapRetryTask?.cancel()
            imapRetryTask = nil
            imapRetryCount = 0
        }
    }

    // MARK: - Whisper helpers

    /// Called by the capture pipeline to check whether transcription is available.
    /// When degraded, callers should enqueue audio data rather than send it.
    public var isWhisperAvailable: Bool {
        health[.whisper] == .healthy
    }

    // MARK: - Ollama helpers

    /// When `false`, AI classification should be skipped and events buffered.
    public var isOllamaAvailable: Bool {
        health[.ollama] == .healthy
    }

    // MARK: - Database helpers

    /// When `false`, all capture writes should halt to avoid data loss or
    /// compounding a full-disk situation.
    public var isDatabaseAvailable: Bool {
        health[.database] == .healthy
    }

    // MARK: - IMAP retry loop

    private func startIMAPRetryLoop(
        reason: String,
        handler: @escaping @Sendable () async -> Bool
    ) {
        imapRetryTask?.cancel()
        imapRetryTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let attempt = await self.currentImapRetryCount()
                if attempt >= GracefulDegradationManager.imapMaxRetries {
                    await self.markIMAPFailed(reason: "Max retries (\(GracefulDegradationManager.imapMaxRetries)) exhausted. Last error: \(reason)")
                    return
                }

                let delay = GracefulDegradationManager.imapBaseDelaySeconds * pow(2.0, Double(attempt))
                log.info("IMAP retry \(attempt + 1)/\(GracefulDegradationManager.imapMaxRetries) in \(Int(delay))s.")

                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return // Task cancelled
                }

                guard !Task.isCancelled else { return }

                await self.incrementImapRetryCount()

                let success = await handler()
                if success {
                    await self.reportRecovery(.imap)
                    return
                }
                await self.updateIMAPDegraded(reason: reason)
            }
        }
    }

    private func currentImapRetryCount() -> Int { imapRetryCount }
    private func incrementImapRetryCount() { imapRetryCount += 1 }
    private func markIMAPFailed(reason: String) {
        health[.imap] = .failed(reason: reason)
        log.error("IMAP permanently failed: \(reason)")
    }
    private func updateIMAPDegraded(reason: String) {
        health[.imap] = .degraded(reason: reason, retryCount: imapRetryCount)
    }
}

// MARK: - SubsystemHealth display helpers

extension SubsystemHealth {
    public var displayLabel: String {
        switch self {
        case .healthy:               return "Healthy"
        case .degraded(let r, _):    return "Degraded: \(r)"
        case .failed(let r):         return "Failed: \(r)"
        }
    }

    public var isHealthy: Bool {
        if case .healthy = self { return true }
        return false
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
