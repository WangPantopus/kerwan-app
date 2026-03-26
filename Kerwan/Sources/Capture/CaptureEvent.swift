// CaptureEvent.swift
// Kerwan — Capture layer
//
// Core data model for unprocessed capture events. All capture sources
// (accessibility, audio, screen, email, calendar) produce CaptureEvents that
// flow through the capture pipeline before AI classification.

import Foundation

// MARK: - CaptureSource

/// Identifies the system that generated a raw capture event.
public enum CaptureSource: String, Codable, Sendable, Hashable, CaseIterable {
    /// App/window focus change detected via the macOS Accessibility API.
    case appFocus
    /// Slack messages scraped via the Accessibility tree.
    case slack
    /// Visual frame captured via ScreenCaptureKit (OCR input).
    case screenCapture
    /// Transcribed audio from microphone or system audio.
    case audio
    /// Email metadata read via IMAP / Gmail API.
    case email
    /// Calendar event read via EventKit.
    case calendar
    /// Context injected from the Chrome browser extension.
    case browserExtension
}

// MARK: - CaptureEvent

/// An unprocessed capture event produced by any capture source.
///
/// CaptureEvents are value types created by capture services and enqueued in
/// the capture pipeline. They carry enough raw context for the AI classification
/// pipeline to extract contacts, topics, promises, and billing signals.
///
/// - Important: `endedAt` is nil for in-progress (open) events. Call `closed(at:)`
///   to obtain a finalized copy before persisting.
public struct CaptureEvent: Identifiable, Sendable, Hashable {

    // MARK: Core identity

    /// Stable identifier for deduplication and storage.
    public let id: UUID

    /// The subsystem that produced this event.
    public let source: CaptureSource

    // MARK: Timing

    /// Wall-clock time when this event began.
    public let startedAt: Date

    /// Wall-clock time when this event ended. `nil` for in-progress events.
    public var endedAt: Date?

    /// Duration in seconds, computed from start/end. `nil` for open events.
    public var durationSeconds: Double? {
        guard let end = endedAt else { return nil }
        return end.timeIntervalSince(startedAt)
    }

    // MARK: Application context

    /// Localized name of the app that produced this event (e.g. "Safari").
    public let sourceApp: String?

    // MARK: Payload

    /// JSON-encoded metadata whose schema varies by `source`.
    ///
    /// - `.appFocus`:      `AppFocusMetadata`
    /// - `.slack`:         `SlackCaptureMetadata`
    /// - `.audio`:         `AudioCaptureMetadata`
    /// - `.screenCapture`: `ScreenCaptureMetadata`
    public var metadataJSON: String?

    // MARK: Init

    public init(
        id: UUID = UUID(),
        source: CaptureSource,
        sourceApp: String? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        metadataJSON: String? = nil
    ) {
        self.id = id
        self.source = source
        self.sourceApp = sourceApp
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.metadataJSON = metadataJSON
    }

    // MARK: Mutation helpers

    /// Returns a copy of this event with `endedAt` set to `date`.
    public func closed(at date: Date = Date()) -> CaptureEvent {
        var copy = self
        copy.endedAt = date
        return copy
    }

    /// Returns a copy with `metadataJSON` replaced.
    public func withMetadata(_ json: String?) -> CaptureEvent {
        var copy = self
        copy.metadataJSON = json
        return copy
    }
}

// MARK: - AppFocusMetadata

/// JSON payload for `.appFocus` events.
public struct AppFocusMetadata: Codable, Sendable {
    /// The app's bundle identifier (e.g. "com.apple.safari"). Empty string when unavailable.
    public let bundleIdentifier: String
    /// The focused window's title. `nil` when the app does not expose it.
    public let windowTitle: String?
    /// The app's Unix process identifier.
    public let pid: Int32

    public init(bundleIdentifier: String, windowTitle: String?, pid: Int32) {
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.pid = pid
    }

    /// Encodes to a compact JSON string, returning `nil` on encoding failure.
    public var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decodes from a JSON string, returning `nil` on failure.
    public static func decode(from json: String) -> AppFocusMetadata? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AppFocusMetadata.self, from: data)
    }
}

// MARK: - SlackCaptureMetadata

/// A single Slack message scraped from the accessibility tree.
public struct SlackMessage: Codable, Sendable, Hashable {
    /// Sender display name, or `nil` when the AX tree does not expose it.
    public let sender: String?
    /// Message body text.
    public let text: String

    public init(sender: String?, text: String) {
        self.sender = sender
        self.text = text
    }
}

/// JSON payload for `.slack` events.
public struct SlackCaptureMetadata: Codable, Sendable {
    /// The channel name or conversation title if detectable.
    public let channel: String?
    /// Scraped messages (up to 10 most recent visible).
    public let messages: [SlackMessage]

    public init(channel: String?, messages: [SlackMessage]) {
        self.channel = channel
        self.messages = messages
    }

    public var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
