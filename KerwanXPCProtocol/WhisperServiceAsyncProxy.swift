import Foundation

/// Async/await wrapper around the Objective-C–compatible ``WhisperServiceProtocol``.
///
/// `NSXPCConnection` requires `@objc`-compatible reply-block methods on the
/// wire protocol. This proxy bridges them into Swift structured concurrency
/// for use throughout the main app and its tests.
///
/// Usage:
/// ```swift
/// let proxy = WhisperServiceAsyncProxy(proxy: connection.remoteObjectProxy
///                                          as! any WhisperServiceProtocol)
/// try await proxy.loadModel(path: modelPath)
/// let segments = try await proxy.transcribe(audioData: pcm, sampleRate: 16_000)
/// await proxy.unloadModel()
/// ```
/// - Note: Marked `@unchecked Sendable` because `NSXPCConnection` remote
///   object proxies are `@objc` protocols which cannot conform to `Sendable`.
///   The proxy itself is stateless and thread-safe.
public struct WhisperServiceAsyncProxy: @unchecked Sendable {
    private let proxy: any WhisperServiceProtocol

    /// Creates a new async proxy wrapping an XPC remote object proxy.
    /// - Parameter proxy: The remote proxy conforming to ``WhisperServiceProtocol``.
    public init(proxy: any WhisperServiceProtocol) {
        self.proxy = proxy
    }

    // MARK: - Async API

    /// Loads a whisper.cpp GGML model from disk.
    ///
    /// - Parameter path: Absolute path to the GGML model file.
    /// - Throws: ``WhisperServiceError`` describing the failure.
    public func loadModel(path: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proxy.loadModel(path: path) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Transcribes raw PCM audio data into ``TranscriptSegment`` values.
    ///
    /// - Parameters:
    ///   - audioData: Raw PCM bytes (mono, 16-bit signed integer).
    ///   - sampleRate: The sample rate in Hz.
    /// - Returns: Chronologically sorted array of ``TranscriptSegment`` values.
    /// - Throws: ``WhisperServiceError`` describing the failure.
    public func transcribe(audioData: Data, sampleRate: Int) async throws -> [TranscriptSegment] {
        try await withCheckedThrowingContinuation { continuation in
            proxy.transcribe(audioData: audioData, sampleRate: sampleRate) { segmentBlobs, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let blobs = segmentBlobs else {
                    continuation.resume(returning: [])
                    return
                }
                do {
                    let decoder = JSONDecoder()
                    let segments = try blobs.map { try decoder.decode(TranscriptSegment.self, from: $0) }
                    continuation.resume(returning: segments.sorted())
                } catch {
                    continuation.resume(throwing: WhisperServiceError.transcriptionFailed(
                        reason: "Segment decoding failed: \(error.localizedDescription)"
                    ))
                }
            }
        }
    }

    /// Unloads the current model and releases GPU/CPU memory.
    public func unloadModel() async {
        await withCheckedContinuation { continuation in
            proxy.unloadModel { continuation.resume() }
        }
    }

    /// Returns whether a model is currently loaded in the service process.
    public func isModelLoaded() async -> Bool {
        await withCheckedContinuation { continuation in
            proxy.isModelLoaded { loaded in continuation.resume(returning: loaded) }
        }
    }
}
