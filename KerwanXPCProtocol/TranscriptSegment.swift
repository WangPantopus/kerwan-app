import Foundation

/// A single segment of transcribed audio, representing a contiguous span of speech
/// with timing, language, and confidence metadata.
///
/// Segments are ordered chronologically (`Comparable` by `startTime`).
public struct TranscriptSegment: Codable, Sendable, Hashable, Identifiable, Comparable {
    /// Stable identifier derived from content and timing.
    public var id: String {
        "\(startTime)-\(endTime)-\(text.hashValue)"
    }

    /// The transcribed text content of this segment.
    public let text: String

    /// The start time of this segment relative to the beginning of the audio, in seconds.
    public let startTime: TimeInterval

    /// The end time of this segment relative to the beginning of the audio, in seconds.
    public let endTime: TimeInterval

    /// The BCP-47 language code detected for this segment (e.g., "en", "fr").
    public let language: String

    /// The model's confidence in the transcription, from 0.0 (no confidence) to 1.0 (certain).
    public let confidence: Float

    /// The duration of this segment in seconds.
    public var duration: TimeInterval {
        endTime - startTime
    }

    /// Creates a new transcript segment.
    /// - Parameters:
    ///   - text: The transcribed text.
    ///   - startTime: Start time in seconds from audio beginning.
    ///   - endTime: End time in seconds from audio beginning.
    ///   - language: BCP-47 language code.
    ///   - confidence: Transcription confidence from 0.0 to 1.0.
    public init(
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        language: String,
        confidence: Float
    ) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.language = language
        self.confidence = max(0.0, min(1.0, confidence))
    }
}

// MARK: - Comparable (chronological order)

extension TranscriptSegment {
    /// Segments are ordered by start time; equal start times are ordered by end time.
    public static func < (lhs: TranscriptSegment, rhs: TranscriptSegment) -> Bool {
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        return lhs.endTime < rhs.endTime
    }
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
