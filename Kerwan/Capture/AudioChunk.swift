// AudioChunk.swift
// Kerwan — Capture layer
//
// Data model for a processed audio chunk delivered by MicrophoneCaptureService.
// Downstream consumers (WhisperKit XPC service) receive AudioChunks and
// produce transcription RawEvents.

import Foundation

// MARK: - AudioChunk

/// A 30-second (±) window of captured microphone audio, ready for transcription.
///
/// Audio is raw PCM: Float32, 16 kHz, mono, non-interleaved.
/// Construct via `MicrophoneCaptureService`; do not create directly.
public struct AudioChunk: Sendable, Identifiable, Hashable {

    /// Stable identifier for deduplication.
    public let id: UUID

    /// Raw PCM payload — Float32 samples, 16 kHz, mono, host byte order.
    ///
    /// Total byte count = `sampleCount × 4`. Each sample is in [-1.0, 1.0].
    public let data: Data

    /// Sample rate of the audio in `data`. Always 16 000 Hz.
    public let sampleRate: Int

    /// Wall-clock time of the first sample in this chunk.
    public let startTime: Date

    /// Duration in seconds, derived from the sample count and rate.
    public let durationSeconds: Double

    /// Whether the VAD determined this chunk contains speech.
    ///
    /// Chunks with `containsSpeech == false` are still delivered when the
    /// service is stopped (partial flush) but should be skipped by the
    /// transcription pipeline.
    public let containsSpeech: Bool

    // MARK: Derived

    /// Number of Float32 samples in `data`.
    public var sampleCount: Int { data.count / MemoryLayout<Float>.size }

    public init(
        id: UUID = UUID(),
        data: Data,
        sampleRate: Int,
        startTime: Date,
        durationSeconds: Double,
        containsSpeech: Bool
    ) {
        self.id = id
        self.data = data
        self.sampleRate = sampleRate
        self.startTime = startTime
        self.durationSeconds = durationSeconds
        self.containsSpeech = containsSpeech
    }
}

// MARK: - AudioChunkDelegate

/// Receives audio chunks from `MicrophoneCaptureService`.
///
/// Conformance is restricted to actors (via `AnyActor`) so callers can safely
/// `await` the delivery. The concrete implementation is `WhisperSessionActor`
/// (or `RawEventBuffer` if transcription is inlined).
public protocol AudioChunkDelegate: AnyActor {
    /// Called on the delegate's actor executor when a chunk is ready.
    ///
    /// - Parameter chunk: A finalized audio chunk with VAD metadata.
    ///   The chunk's `data` is safe to retain and use asynchronously.
    func didCaptureAudioChunk(_ chunk: AudioChunk) async
}
