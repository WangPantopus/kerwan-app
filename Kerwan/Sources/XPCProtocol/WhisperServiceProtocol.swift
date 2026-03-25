import Foundation

/// Errors that can occur during whisper transcription service operations.
public enum WhisperServiceError: Error, Sendable {
    /// The specified model file was not found at the given path.
    case modelNotFound(path: String)
    /// The model file exists but could not be loaded (corrupt, incompatible, etc.).
    case modelLoadFailed(reason: String)
    /// No model is currently loaded; call `loadModel` first.
    case modelNotLoaded
    /// The provided audio data is invalid or in an unsupported format.
    case invalidAudioData(reason: String)
    /// The sample rate is outside the supported range.
    case unsupportedSampleRate(Int)
    /// Transcription was interrupted or failed.
    case transcriptionFailed(reason: String)
    /// The XPC connection to the service was interrupted or invalidated.
    case connectionLost
}

extension WhisperServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return "Whisper model not found at path: \(path)"
        case .modelLoadFailed(let reason):
            return "Failed to load whisper model: \(reason)"
        case .modelNotLoaded:
            return "No whisper model is loaded. Call loadModel first."
        case .invalidAudioData(let reason):
            return "Invalid audio data: \(reason)"
        case .unsupportedSampleRate(let rate):
            return "Unsupported sample rate: \(rate) Hz"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .connectionLost:
            return "Connection to WhisperService was lost."
        }
    }
}

/// Protocol defining the interface for the Whisper transcription XPC service.
///
/// The WhisperService runs as a separate XPC process to isolate the transcription
/// workload from the main application. Communication uses NSXPCConnection with
/// Codable types serialized via JSON.
///
/// ## Lifecycle
/// 1. Call ``loadModel(path:)`` with the path to a whisper.cpp GGML model file.
/// 2. Call ``transcribe(audioData:sampleRate:)`` one or more times with raw PCM audio.
/// 3. Call ``unloadModel()`` when transcription is no longer needed to free memory.
@objc public protocol WhisperServiceProtocol {
    /// Loads a whisper.cpp model from disk into memory.
    ///
    /// This must be called before any transcription requests. Loading a new model
    /// automatically unloads any previously loaded model.
    ///
    /// - Parameter path: Absolute file system path to the GGML model file.
    /// - Throws: ``WhisperServiceError/modelNotFound(path:)`` if the file doesn't exist.
    /// - Throws: ``WhisperServiceError/modelLoadFailed(reason:)`` if loading fails.
    func loadModel(path: String, withReply reply: @escaping (Error?) -> Void)

    /// Transcribes raw PCM audio data into text segments.
    ///
    /// The audio data must be single-channel (mono) 16-bit signed integer PCM.
    /// Supported sample rates are 8000, 16000, 22050, 44100, and 48000 Hz.
    /// The service will resample to 16 kHz internally if needed.
    ///
    /// - Parameters:
    ///   - audioData: Raw PCM audio bytes (mono, 16-bit signed integer).
    ///   - sampleRate: The sample rate of the audio in Hz.
    /// - Returns: JSON-encoded array of ``TranscriptSegment`` values via the reply handler.
    /// - Throws: ``WhisperServiceError/modelNotLoaded`` if no model is loaded.
    /// - Throws: ``WhisperServiceError/invalidAudioData(reason:)`` if the data is malformed.
    /// - Throws: ``WhisperServiceError/unsupportedSampleRate(_:)`` for unsupported rates.
    func transcribe(audioData: Data, sampleRate: Int, withReply reply: @escaping (Data?, Error?) -> Void)

    /// Unloads the current model and releases associated memory.
    ///
    /// This is safe to call even if no model is loaded.
    func unloadModel(withReply reply: @escaping () -> Void)
}
