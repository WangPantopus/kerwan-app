// TranscriptSegment.swift
// Kerwan — Shared (Kerwan app target + WhisperService XPC target)
//
// Wire type for transcription results.  Crosses the XPC boundary as
// JSON-encoded Data (one element per array entry in the reply block).
//
// Design notes
// ─────────────
// • Must be Codable — JSON encode/decode is the XPC transport.
// • Must NOT require NSSecureCoding; we own the serialisation path.
// • Times are in seconds relative to the start of the AudioChunk that
//   produced this segment (not wall-clock time).
// • `confidence` is the arithmetic mean of per-token probabilities
//   returned by whisper_full_get_token_p.  Range: 0.0 – 1.0.
// • `language` is the BCP-47 code detected by Whisper ("en", "fr", …).
//   If detection was disabled it equals the requested language.

import Foundation

// MARK: - TranscriptSegment

/// A single transcribed segment (sentence / phrase) from a Whisper pass.
public struct TranscriptSegment: Codable, Sendable, Identifiable, Hashable {

    // MARK: Fields

    /// Stable UUID for deduplication and CoreData insertion.
    public let id: UUID

    /// Transcribed text, stripped of leading/trailing whitespace.
    public let text: String

    /// Start time in seconds relative to the AudioChunk start.
    public let startTime: TimeInterval

    /// End time in seconds relative to the AudioChunk start.
    public let endTime: TimeInterval

    /// BCP-47 language code detected by Whisper.
    public let language: String

    /// Mean token probability in [0, 1].  Higher = more confident.
    public let confidence: Float

    // MARK: Init

    public init(
        id: UUID = UUID(),
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        language: String,
        confidence: Float
    ) {
        self.id = id
        self.text = text.trimmingCharacters(in: .whitespaces)
        self.startTime = startTime
        self.endTime = endTime
        self.language = language
        self.confidence = confidence.clamped(to: 0...1)
    }

    // MARK: Derived

    /// Duration of this segment in seconds.
    public var duration: TimeInterval { endTime - startTime }
}

// MARK: - JSON helpers

public extension TranscriptSegment {

    /// Returns a JSON-encoded representation suitable for XPC transport.
    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Decodes a segment from an XPC-transported JSON blob.
    static func decode(from data: Data) throws -> TranscriptSegment {
        try JSONDecoder().decode(TranscriptSegment.self, from: data)
    }
}

// MARK: - Comparable (chronological ordering)

extension TranscriptSegment: Comparable {
    public static func < (lhs: TranscriptSegment, rhs: TranscriptSegment) -> Bool {
        lhs.startTime < rhs.startTime
    }
}

// MARK: - Comparable helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
