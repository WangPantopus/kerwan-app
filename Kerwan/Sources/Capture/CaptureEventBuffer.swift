// CaptureEventBuffer.swift
// Kerwan — Capture layer
//
// Actor that sits between every capture service and the rest of the pipeline.
// It is the single concrete `CaptureEventDelegate` wired into all services.
//
// Responsibilities
// ────────────────
//   1. Run the ExclusionEngine: silently drop excluded events.
//   2. Notify AppState of the accepted event count so the UI can display
//      "N events captured today".

import Foundation
import os

// MARK: - AppStateManaging

/// Minimal interface to AppState that CaptureManager and CaptureEventBuffer need.
///
/// The real implementation lives in the App layer; tests inject a mock.
public protocol AppStateManaging: AnyActor {
    /// Called whenever the overall capture status changes.
    func setCaptureStatus(_ status: CaptureStatus) async
    /// Adds `count` to the running today-total shown in the menu bar.
    func incrementEventsToday(by count: Int) async
    /// Resets the today-total to zero (called at midnight).
    func resetEventsToday() async
}

// MARK: - StorageManaging

/// Minimal interface to StorageActor that the capture pipeline needs.
///
/// The real implementation persists events in SQLite via StorageActor;
/// tests inject an in-memory accumulator.
public protocol StorageManaging: AnyActor {
    /// Persist a single capture event. Called on a background task; failures are
    /// logged but not propagated back to the capture pipeline.
    func saveRawEvent(_ event: CaptureEvent) async throws
}

// MARK: - CaptureEventBuffer

/// The single `CaptureEventDelegate` that all capture services deliver events to.
///
/// Call sites:
/// ```swift
/// let buffer = CaptureEventBuffer(exclusionEngine: engine, storage: storage, appState: appState)
/// let axService = AccessibilityCaptureService(delegate: buffer, environment: .live(...))
/// let emailService = EmailCaptureService(eventDelegate: buffer, environment: .live(...))
/// ```
public actor CaptureEventBuffer: CaptureEventDelegate {

    // MARK: Dependencies

    private let exclusionEngine: any ExclusionChecking
    private let storage:         any StorageManaging
    private let appState:        any AppStateManaging
    private let log = Logger(subsystem: "com.kerwan.app", category: "CaptureEventBuffer")

    // MARK: Metrics (readable by CaptureManager)

    /// Total events accepted since the buffer was created (not reset at midnight).
    public private(set) var totalAcceptedCount: Int = 0
    /// Total events dropped by the exclusion engine since creation.
    public private(set) var totalExcludedCount: Int = 0

    // MARK: Init

    public init(
        exclusionEngine: any ExclusionChecking,
        storage:         any StorageManaging,
        appState:        any AppStateManaging
    ) {
        self.exclusionEngine = exclusionEngine
        self.storage         = storage
        self.appState        = appState
    }

    // MARK: CaptureEventDelegate

    public func didCapture(_ events: [CaptureEvent]) async {
        var accepted: [CaptureEvent] = []
        var excludedCount = 0

        for event in events {
            if exclusionEngine.shouldExclude(event) {
                excludedCount += 1
            } else {
                accepted.append(event)
            }
        }

        totalExcludedCount += excludedCount

        guard !accepted.isEmpty else { return }

        totalAcceptedCount += accepted.count
        await appState.incrementEventsToday(by: accepted.count)

        // Fire-and-forget: storage failures must not stall the capture pipeline.
        // Copy `accepted` into a `let` so `Task.detached` captures an immutable snapshot
        // — required by strict-concurrency (mutable vars cannot be captured in @Sendable closures).
        let eventsToSave = accepted
        let storageRef   = storage
        let logRef       = log
        Task.detached(priority: .background) {
            for event in eventsToSave {
                do {
                    try await storageRef.saveRawEvent(event)
                } catch {
                    logRef.error("Failed to persist CaptureEvent \(event.id): \(error.localizedDescription)")
                }
            }
        }
    }
}
