import Foundation
import os
import KerwanXPCProtocol

/// Handles transcription requests from the main Kerwan app via XPC.
///
/// Each XPC connection receives its own `WhisperServiceHandler` instance
/// (created in ``WhisperServiceDelegate``). The handler manages the
/// whisper.cpp model lifecycle and processes requests sequentially to
/// avoid GPU memory contention.
///
/// ## whisper.cpp integration note
/// The methods below contain the complete scaffolding for whisper.cpp.
/// When the whisper.cpp C API is linked:
/// - Replace `loadModel` body with `whisper_init_from_file(path)`
/// - Replace `transcribe` body with `whisper_full(ctx, params, samples, n)`
/// - Replace `performModelUnload` body with `whisper_free(ctx)`
final class WhisperServiceHandler: NSObject, WhisperServiceProtocol {
    private static let logger = Logger(
        subsystem: "com.kerwan.app.whisper-service",
        category: "ServiceHandler"
    )

    /// Supported audio sample rates in Hz.
    private static let supportedSampleRates: Set<Int> = [8_000, 16_000, 22_050, 44_100, 48_000]

    // MARK: - Private state

    /// Absolute path to the currently loaded model, or `nil` if none.
    private var loadedModelPath: String?

    // MARK: - WhisperServiceProtocol

    /// Loads a whisper.cpp GGML model from the specified path.
    ///
    /// Validates that the file exists and is non-empty. In production this
    /// will call `whisper_init_from_file`; currently the file is validated
    /// and the loaded flag is set to true.
    func loadModel(path: String, withReply reply: @escaping (Error?) -> Void) {
        Self.logger.info("Loading model from: \(path, privacy: .public)")

        guard FileManager.default.fileExists(atPath: path) else {
            Self.logger.error("Model file not found: \(path, privacy: .public)")
            reply(WhisperServiceError.modelNotFound(path: path))
            return
        }

        // Unload any previously loaded model before loading the new one.
        if loadedModelPath != nil {
            Self.logger.info("Unloading previous model before loading new one")
            performModelUnload()
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard let fileSize = attributes[.size] as? UInt64, fileSize > 0 else {
                reply(WhisperServiceError.modelLoadFailed(reason: "Model file is empty"))
                return
            }
            Self.logger.info("Model file validated: \(fileSize) bytes")
            loadedModelPath = path
            Self.logger.info("Model loaded successfully from \(path, privacy: .public)")
            reply(nil)
        } catch {
            Self.logger.error("Failed to read model attributes: \(error.localizedDescription)")
            reply(WhisperServiceError.modelLoadFailed(reason: error.localizedDescription))
        }
    }

    /// Transcribes raw PCM audio data into JSON-encoded ``TranscriptSegment`` blobs.
    ///
    /// Validates the model state, sample rate, and audio data before
    /// dispatching to the whisper.cpp engine. Returns each segment as a
    /// separate JSON-encoded `Data` blob in the reply array.
    func transcribe(
        audioData: Data,
        sampleRate: Int,
        withReply reply: @escaping (_ segments: [Data]?, _ error: Error?) -> Void
    ) {
        Self.logger.info("Transcription request: \(audioData.count) bytes at \(sampleRate) Hz")

        guard loadedModelPath != nil else {
            Self.logger.error("Transcription requested but no model is loaded")
            reply(nil, WhisperServiceError.modelNotLoaded)
            return
        }

        guard Self.supportedSampleRates.contains(sampleRate) else {
            Self.logger.error("Unsupported sample rate: \(sampleRate)")
            reply(nil, WhisperServiceError.unsupportedSampleRate(sampleRate))
            return
        }

        // 16-bit PCM: byte count must be even and at least 2 bytes (1 sample).
        guard audioData.count >= 2, audioData.count.isMultiple(of: 2) else {
            reply(nil, WhisperServiceError.invalidAudioData(
                reason: "Audio data must be 16-bit PCM (even byte count ≥ 2), got \(audioData.count) bytes"
            ))
            return
        }

        let sampleCount = audioData.count / 2
        let durationSeconds = Double(sampleCount) / Double(sampleRate)
        Self.logger.info(
            "Audio: \(sampleCount) samples, \(durationSeconds, format: .fixed(precision: 2))s"
        )

        // Stub: returns empty segments until whisper.cpp C API is linked.
        // Production: call whisper_full(ctx, params, float32Samples, sampleCount),
        // then extract segments with whisper_full_n_segments / whisper_full_get_segment_*.
        let segments: [TranscriptSegment] = []

        do {
            let encoder = JSONEncoder()
            let encoded: [Data] = try segments.map { try encoder.encode($0) }
            Self.logger.info("Transcription complete: \(encoded.count) segments")
            reply(encoded, nil)
        } catch {
            Self.logger.error("Failed to encode segments: \(error.localizedDescription)")
            reply(nil, WhisperServiceError.transcriptionFailed(
                reason: "Segment encoding failed: \(error.localizedDescription)"
            ))
        }
    }

    /// Unloads the current model and releases associated GPU/CPU memory.
    ///
    /// Safe to call when no model is loaded.
    func unloadModel(withReply reply: @escaping () -> Void) {
        Self.logger.info("Unload model requested")
        performModelUnload()
        reply()
    }

    /// Returns whether a model is currently loaded and ready for transcription.
    func isModelLoaded(withReply reply: @escaping (_ loaded: Bool) -> Void) {
        reply(loadedModelPath != nil)
    }

    // MARK: - Private

    /// Releases model resources without a reply handler.
    ///
    /// Production: call `whisper_free(ctx)` here before clearing the pointer.
    private func performModelUnload() {
        loadedModelPath = nil
        Self.logger.info("Model unloaded")
    }
}
