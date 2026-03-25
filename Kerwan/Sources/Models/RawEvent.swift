import Foundation

/// A raw, unprocessed event captured from any input source.
///
/// Raw events are the lowest-level records in Kerwan's data pipeline. They
/// represent exactly what was observed before any AI classification. The
/// classification pipeline reads raw events, extracts structure, and produces
/// ``Interaction``, ``Contact``, and ``Promise`` records.
///
/// Examples of raw events:
/// - An audio capture session yielding a transcript (source = `.audio`)
/// - A detected app focus change (source = `.appFocus`)
/// - An email fetched from Gmail IMAP (source = `.email`)
/// - A calendar event from EventKit (source = `.calendar`)
///
/// Raw events are retained for re-processing (e.g., when the classification
/// model improves) and for audit/debugging. Events marked ``isExcluded``
/// matched an ``ExclusionRule`` and are skipped by the classification pipeline.
public struct RawEvent: Codable, Sendable, Identifiable, Hashable {
    /// Unique identifier (UUID string).
    public let id: EntityID

    /// The capture source that produced this event.
    public let source: EventSource

    /// The application that was active or relevant when this event was captured
    /// (e.g., "Zoom", "Safari", "Mail"). Nil for non-app sources.
    public var sourceApp: String?

    /// When this event started (or occurred, for point-in-time events).
    public let startedAt: Date

    /// When this event ended. Nil for point-in-time events or ongoing captures.
    public var endedAt: Date?

    /// Duration in seconds, if known. Computed from startedAt/endedAt when
    /// both are available, or provided directly by the capture source.
    public var durationSecs: Int?

    /// The raw text content (transcript, email body, note text, etc.).
    /// May be large; only loaded on demand in some query paths.
    public var rawText: String?

    /// Arbitrary JSON metadata specific to the source type.
    /// For audio: sample rate, channel count, model used.
    /// For email: subject, from, to, message-id.
    /// For calendar: event UID, attendees, location.
    public var metadataJSON: String?

    /// Whether this event matched an exclusion rule and should be skipped
    /// by the classification pipeline.
    public var isExcluded: Bool

    public init(
        id: EntityID = UUID().uuidString,
        source: EventSource,
        sourceApp: String? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        durationSecs: Int? = nil,
        rawText: String? = nil,
        metadataJSON: String? = nil,
        isExcluded: Bool = false
    ) {
        self.id = id
        self.source = source
        self.sourceApp = sourceApp
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSecs = durationSecs
        self.rawText = rawText
        self.metadataJSON = metadataJSON
        self.isExcluded = isExcluded
    }
}

/// The capture source that produced a ``RawEvent``.
public enum EventSource: String, Codable, Sendable, CaseIterable {
    /// Microphone or system audio capture, transcribed via WhisperService.
    case audio
    /// Application focus change detected via the accessibility API.
    case appFocus
    /// Email message fetched from Gmail IMAP.
    case email
    /// Slack message or channel activity.
    case slack
    /// Calendar event from EventKit.
    case calendar
    /// Browser page visit captured by the Chrome extension.
    case browser
    /// A note entered manually by the user.
    case manualNote
}
