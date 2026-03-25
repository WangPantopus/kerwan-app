import Foundation

/// Async/await wrapper around the Objective-C–compatible ``WhisperServiceProtocol``.
///
/// Since NSXPCConnection requires `@objc`-compatible reply-block methods,
/// this proxy translates them into Swift structured concurrency for use
/// throughout the main app.
public struct WhisperServiceAsyncProxy: Sendable {
    private let proxy: any WhisperServiceProtocol

    /// Creates a new async proxy wrapping an XPC service proxy object.
    /// - Parameter proxy: The remote proxy conforming to ``WhisperServiceProtocol``.
    public init(proxy: any WhisperServiceProtocol) {
        self.proxy = proxy
    }

    /// Loads a whisper.cpp model from disk.
    /// - Parameter path: Absolute path to the GGML model file.
    /// - Throws: ``WhisperServiceError`` on failure.
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

    /// Transcribes raw PCM audio data into text segments.
    /// - Parameters:
    ///   - audioData: Raw PCM audio bytes (mono, 16-bit signed integer).
    ///   - sampleRate: The sample rate in Hz.
    /// - Returns: An array of ``TranscriptSegment`` values.
    /// - Throws: ``WhisperServiceError`` on failure.
    public func transcribe(audioData: Data, sampleRate: Int) async throws -> [TranscriptSegment] {
        try await withCheckedThrowingContinuation { continuation in
            proxy.transcribe(audioData: audioData, sampleRate: sampleRate) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data else {
                    continuation.resume(throwing: WhisperServiceError.transcriptionFailed(
                        reason: "No data returned from transcription"
                    ))
                    return
                }
                do {
                    let segments = try JSONDecoder().decode([TranscriptSegment].self, from: data)
                    continuation.resume(returning: segments)
                } catch {
                    continuation.resume(throwing: WhisperServiceError.transcriptionFailed(
                        reason: "Failed to decode segments: \(error.localizedDescription)"
                    ))
                }
            }
        }
    }

    /// Unloads the current model and frees memory.
    public func unloadModel() async {
        await withCheckedContinuation { continuation in
            proxy.unloadModel {
                continuation.resume()
            }
        }
    }
}
