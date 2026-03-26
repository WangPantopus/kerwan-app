// CaptureEventDelegate.swift
// Kerwan — Capture layer
//
// Protocol glue between capture sources and the raw event buffer.
// All capture services hold a weak reference to a CaptureEventDelegate
// and call didCapture(_:) whenever one or more events are ready.

import Foundation

// MARK: - CaptureEventDelegate

/// Receives raw capture events from any capture source.
///
/// Conformance is restricted to actors so callers can safely `await` the
/// delegate without worrying about data races. The concrete implementation
/// is `RawEventBuffer`.
public protocol CaptureEventDelegate: AnyActor {
    /// Called when one or more finalized (or in-progress) events are ready.
    ///
    /// - Parameter events: One or more events produced by a single capture tick.
    ///   Open events (endedAt == nil) may be sent for streaming use-cases.
    func didCapture(_ events: [CaptureEvent]) async
}

// MARK: - ExclusionChecking

/// Determines whether a `CaptureEvent` should be suppressed before buffering.
///
/// The concrete implementation (`ExclusionEngine`) applies user-configured
/// rules: blocked apps, private-browsing detection, content filters, etc.
/// Inject a mock conformer in tests.
public protocol ExclusionChecking: Sendable {
    /// Returns `true` when the event should be silently discarded.
    func shouldExclude(_ event: CaptureEvent) -> Bool
}

// MARK: - PassthroughExclusionEngine

/// A no-op exclusion engine that allows every event through.
/// Used as the default until the real `ExclusionEngine` is wired up.
public struct PassthroughExclusionEngine: ExclusionChecking {
    public init() {}
    public func shouldExclude(_ event: CaptureEvent) -> Bool { false }
}
