// AudioCaptureMetadata.swift
// Kerwan — Transcription layer
//
// JSON payload for RawEvents with source == .audio.
// Referenced in RawEvent.swift's comment block; defined here so it lives
// alongside the transcription pipeline that produces it.

import Foundation

// MARK: - AudioCaptureMetadata

/// Metadata embedded in a `.audio` RawEvent's `metadataJSON` field.
///
/// Keys use snake_case to match the ClassificationActor's expectations
/// and the eventual SQLite schema.
public struct AudioCaptureMetadata: Codable, Sendable, Equatable {

    // MARK: Fields

    /// The full assembled transcript for this speaking session.
    public let transcript: String

    /// Arithmetic mean of per-segment confidences, in [0, 1].
    public let averageConfidence: Float

    /// BCP-47 language code detected by Whisper (e.g. "en", "fr").
    /// Taken from the first segment of the session.
    public let detectedLanguage: String

    /// Total time classified as speech (sum of segment durations), seconds.
    public let durationSeconds: Double

    /// Number of 30-second AudioChunks that contributed to this session.
    public let chunkCount: Int

    // MARK: CodingKeys — use snake_case for downstream consistency

    enum CodingKeys: String, CodingKey {
        case transcript
        case averageConfidence = "average_confidence"
        case detectedLanguage  = "detected_language"
        case durationSeconds   = "duration_seconds"
        case chunkCount        = "chunk_count"
    }

    // MARK: Init

    public init(
        transcript: String,
        averageConfidence: Float,
        detectedLanguage: String,
        durationSeconds: Double,
        chunkCount: Int
    ) {
        self.transcript       = transcript
        self.averageConfidence = averageConfidence
        self.detectedLanguage = detectedLanguage
        self.durationSeconds  = durationSeconds
        self.chunkCount       = chunkCount
    }

    // MARK: JSON helpers

    /// Encodes to a compact JSON string; returns `nil` on failure.
    public var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decodes from a JSON string; returns `nil` on failure.
    public static func decode(from json: String) -> AudioCaptureMetadata? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AudioCaptureMetadata.self, from: data)
    }
}
