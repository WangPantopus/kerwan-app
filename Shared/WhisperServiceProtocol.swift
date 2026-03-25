// WhisperServiceProtocol.swift
// Kerwan — Shared (Kerwan app target + WhisperService XPC target)
//
// The @objc protocol that is exported by the XPC service and imported by
// the main app.  Both sides reference this file.
//
// XPC transport notes
// ───────────────────
// • All parameter and return types must be NSXPCConnection-compatible:
//   NSString, NSData, NSNumber, NSError, BOOL, int — or NSSecureCoding
//   types registered on the NSXPCInterface.
// • `audioData` carries raw Float32 PCM at `sampleRate` Hz, mono.
// • Transcription results are returned as `[Data]` — each element is a
//   JSON-encoded `TranscriptSegment`.  This avoids NSSecureCoding
//   boilerplate while keeping the protocol boundary explicit.
// • All replies are required (non-nil block).  Never call a proxy method
//   without providing a reply block — XPC will assert.
//
// Error domain
// ────────────
// Errors returned in reply blocks use domain `WhisperServiceErrorDomain`.
// Codes are defined in `WhisperServiceError`.

import Foundation

// MARK: - Error domain + codes

/// Unified error type returned through XPC reply blocks.
public enum WhisperServiceError: Int, Error {
    /// The requested model file does not exist at the given path.
    case modelNotFound       = 1
    /// `whisper_init_from_file` returned nil (out of memory / corrupt model).
    case modelLoadFailed     = 2
    /// No model has been loaded; call `loadModel` first.
    case modelNotLoaded      = 3
    /// `whisper_full` returned a non-zero status code.
    case transcriptionFailed = 4
    /// The audio data is empty or malformed.
    case invalidAudioData    = 5
    /// The XPC connection was interrupted or invalidated.
    case connectionFailed    = 6
    /// The transcription did not complete within the allowed time.
    case timeout             = 7
}

public let WhisperServiceErrorDomain = "com.kerwan.WhisperService"

extension WhisperServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .modelNotFound:       return "Whisper model file not found"
        case .modelLoadFailed:     return "Failed to load Whisper model (out of memory or corrupt file)"
        case .modelNotLoaded:      return "No model is loaded — call loadModel first"
        case .transcriptionFailed: return "whisper_full returned a non-zero error code"
        case .invalidAudioData:    return "Audio data is empty or not valid Float32 PCM"
        case .connectionFailed:    return "XPC connection to WhisperService failed"
        case .timeout:             return "Transcription timed out"
        }
    }
}

// MARK: - WhisperServiceProtocol

/// XPC protocol implemented by `WhisperTranscriptionEngine` in the service
/// process and called via `NSXPCConnection.remoteObjectProxy` in the app.
///
/// All methods are non-throwing; errors are delivered in the reply block so
/// that failures never propagate across the XPC boundary as exceptions.
@objc public protocol WhisperServiceProtocol {

    /// Loads the Whisper model at `path` into GPU/CPU memory.
    ///
    /// - Parameter path:  Absolute path to a `ggml-*.bin` model file.
    /// - Parameter reply: Called on an arbitrary queue.  `error` is nil on success.
    func loadModel(atPath path: String, reply: @escaping (Error?) -> Void)

    /// Transcribes raw PCM audio.
    ///
    /// - Parameter audioData:  Raw Float32 samples in host byte-order.
    ///   Length must be a multiple of 4 (sizeof Float32).
    /// - Parameter sampleRate: Sample rate of `audioData` in Hz (typically 16 000).
    /// - Parameter reply:      Called on an arbitrary queue.
    ///   `segments` is an array of JSON-encoded `TranscriptSegment` values.
    ///   On partial failure (some segments transcribed before an error),
    ///   both `segments` and `error` may be non-nil.
    func transcribe(
        audioData: Data,
        sampleRate: Int,
        reply: @escaping (_ segments: [Data]?, _ error: Error?) -> Void
    )

    /// Releases the loaded model and frees GPU/CPU memory.
    ///
    /// Safe to call even when no model is loaded.
    func unloadModel(reply: @escaping () -> Void)

    /// Returns whether a model is currently loaded and ready.
    func isModelLoaded(reply: @escaping (_ loaded: Bool) -> Void)
}

// MARK: - NSXPCInterface factory

/// Returns a correctly configured `NSXPCInterface` for `WhisperServiceProtocol`.
///
/// Must be set on **both** the connection's `remoteObjectInterface` (client)
/// and the listener connection's `exportedInterface` (service).
public func makeWhisperXPCInterface() -> NSXPCInterface {
    let iface = NSXPCInterface(with: WhisperServiceProtocol.self)

    // `transcribe` reply: the first parameter is an NSArray of NSData.
    // Register NSData as an allowed class for argument index 0 of the reply.
    iface.setClasses(
        NSSet(array: [NSArray.self, NSData.self]) as! Set<AnyHashable>,
        for: #selector(
            WhisperServiceProtocol.transcribe(audioData:sampleRate:reply:)
        ),
        argumentIndex: 0,
        ofReply: true
    )

    return iface
}

public extension WhisperServiceProtocol {

    /// Returns a correctly configured `NSXPCInterface` for this protocol.
    ///
    /// Must be set on **both** the connection's `remoteObjectInterface` (client)
    /// and the listener connection's `exportedInterface` (service).
    static func xpcInterface() -> NSXPCInterface { makeWhisperXPCInterface() }
}
