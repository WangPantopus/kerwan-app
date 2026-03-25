// WhisperTranscribing.swift
// Kerwan — Transcription layer
//
// Protocol that TranscriptionActor depends on for transcription.
// Decouples TranscriptionActor from the concrete WhisperServiceClient so
// unit tests can inject a mock without touching XPC.
//
// WhisperServiceClient already implements all four methods with matching
// signatures; the empty conformance extension below satisfies the compiler.

import Foundation

// MARK: - WhisperTranscribing

/// Async transcription interface satisfied by WhisperServiceClient in
/// production and by MockWhisperTranscribing in tests.
///
/// All methods are actor-isolated (the `: Actor` refinement ensures callers
/// always await cross-actor calls).
public protocol WhisperTranscribing: Actor {

    /// Loads the Whisper model at `path` into the transcription process.
    /// - Throws: `WhisperServiceError.modelNotFound` / `.modelLoadFailed`.
    func loadModel(atPath path: String) async throws

    /// Transcribes raw Float32 PCM audio.
    /// - Returns: Decoded, chronologically-sorted `TranscriptSegment`s.
    /// - Throws: `WhisperServiceError.transcriptionFailed` / `.timeout`.
    func transcribe(audioData: Data, sampleRate: Int) async throws -> [TranscriptSegment]

    /// Returns `true` when a model is loaded and the service is ready.
    func isModelLoaded() async throws -> Bool

    /// Unloads the model and frees GPU/CPU memory.
    func unloadModel() async throws
}

// MARK: - WhisperServiceClient conformance

/// `WhisperServiceClient` already declares all four methods; this empty
/// extension makes the conformance explicit so the compiler verifies it.
extension WhisperServiceClient: WhisperTranscribing {}
