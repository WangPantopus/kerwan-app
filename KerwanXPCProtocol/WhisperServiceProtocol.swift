import Foundation

// MARK: - WhisperServiceError

/// Errors that can occur during Whisper transcription service operations.
///
/// These cross the XPC boundary inside reply-block `Error` parameters.
/// All cases are `Sendable` because the enum carries no non-sendable state.
public enum WhisperServiceError: Error, Sendable {
    /// The specified model file was not found at the given path.
    case modelNotFound(path: String)
    /// The model file exists but could not be loaded (corrupt, incompatible, or out of memory).
    case modelLoadFailed(reason: String)
    /// No model is currently loaded; call `loadModel` first.
    case modelNotLoaded
    /// The provided audio data is invalid or in an unsupported format.
    case invalidAudioData(reason: String)
    /// The sample rate is outside the supported range.
    case unsupportedSampleRate(Int)
    /// Transcription was interrupted or the engine returned an error.
    case transcriptionFailed(reason: String)
    /// The XPC connection to the service was interrupted or invalidated.
    case connectionLost
    /// The XPC connection could not be established or the proxy cast failed.
    case connectionFailed
    /// The transcription did not complete within the allowed timeout window.
    case timeout
}

extension WhisperServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return "Whisper model not found at path: \(path)"
        case .modelLoadFailed(let reason):
            return "Failed to load Whisper model: \(reason)"
        case .modelNotLoaded:
            return "No Whisper model is loaded — call loadModel first."
        case .invalidAudioData(let reason):
            return "Invalid audio data: \(reason)"
        case .unsupportedSampleRate(let rate):
            return "Unsupported sample rate: \(rate) Hz"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .connectionLost:
            return "Connection to WhisperService was lost."
        case .connectionFailed:
            return "Could not establish connection to WhisperService."
        case .timeout:
            return "Transcription timed out."
        }
    }
}

// MARK: - WhisperServiceProtocol

/// Protocol defining the interface for the Whisper transcription XPC service.
///
/// The WhisperService runs as a separate XPC process (bundle ID
/// `com.kerwan.app.whisper-service`) to crash-isolate heavy inference from
/// the main app. Communication uses `NSXPCConnection` with reply blocks;
/// async callers should use ``WhisperServiceAsyncProxy``.
///
/// ## Lifecycle
/// 1. Call ``loadModel(path:withReply:)`` with the absolute path to a GGML model file.
/// 2. Call ``transcribe(audioData:sampleRate:withReply:)`` one or more times.
/// 3. Call ``unloadModel(withReply:)`` when transcription is no longer needed.
///
/// ## XPC Interface
/// Always configure the connection with ``makeWhisperXPCInterface()`` on both
/// the client (``remoteObjectInterface``) and service (``exportedInterface``)
/// so that the `[Data]` array in the `transcribe` reply is allowlisted.
@objc public protocol WhisperServiceProtocol {

    /// Loads a whisper.cpp GGML model from disk into GPU/CPU memory.
    ///
    /// This must be called before any transcription requests. Loading a new
    /// model automatically unloads any previously loaded model.
    ///
    /// - Parameters:
    ///   - path: Absolute file system path to the GGML model file.
    ///   - reply: Called on an arbitrary queue. `error` is `nil` on success.
    func loadModel(path: String, withReply reply: @escaping (Error?) -> Void)

    /// Transcribes raw PCM audio data into JSON-encoded ``TranscriptSegment`` blobs.
    ///
    /// The audio must be mono, 16-bit signed integer PCM. Supported sample
    /// rates: 8 000, 16 000, 22 050, 44 100, 48 000 Hz. The engine resamples
    /// to 16 kHz internally.
    ///
    /// - Parameters:
    ///   - audioData: Raw PCM bytes (mono, 16-bit signed integer).
    ///   - sampleRate: The sample rate of the audio in Hz.
    ///   - reply: Called on an arbitrary queue. Each element of `segments` is a
    ///     JSON-encoded ``TranscriptSegment``. On partial failure, both
    ///     `segments` and `error` may be non-nil.
    func transcribe(
        audioData: Data,
        sampleRate: Int,
        withReply reply: @escaping (_ segments: [Data]?, _ error: Error?) -> Void
    )

    /// Unloads the current model and releases associated GPU/CPU memory.
    ///
    /// Safe to call even if no model is loaded.
    ///
    /// - Parameter reply: Called on an arbitrary queue when unload is complete.
    func unloadModel(withReply reply: @escaping () -> Void)

    /// Returns whether a model is currently loaded and ready for transcription.
    ///
    /// - Parameter reply: Called on an arbitrary queue with the loaded state.
    func isModelLoaded(withReply reply: @escaping (_ loaded: Bool) -> Void)
}

// MARK: - NSXPCInterface factory

/// Returns a correctly configured `NSXPCInterface` for ``WhisperServiceProtocol``.
///
/// Must be called on **both** sides of the connection:
/// - Client: `connection.remoteObjectInterface = makeWhisperXPCInterface()`
/// - Service: `newConnection.exportedInterface = makeWhisperXPCInterface()`
///
/// Registers `NSArray` of `NSData` as an allowed class for the `segments`
/// parameter in the `transcribe` reply block, satisfying the XPC sandbox.
public func makeWhisperXPCInterface() -> NSXPCInterface {
    let iface = NSXPCInterface(with: WhisperServiceProtocol.self)

    // The `transcribe` reply delivers segments as [Data] — an NSArray of NSData.
    // Without this registration the XPC sandbox rejects the message at runtime.
    iface.setClasses(
        NSSet(array: [NSArray.self, NSData.self]) as! Set<AnyHashable>,
        for: #selector(
            WhisperServiceProtocol.transcribe(audioData:sampleRate:withReply:)
        ),
        argumentIndex: 0,
        ofReply: true
    )

    return iface
}

public extension WhisperServiceProtocol {
    /// Convenience alias — returns a correctly configured `NSXPCInterface`.
    static func xpcInterface() -> NSXPCInterface { makeWhisperXPCInterface() }
}
