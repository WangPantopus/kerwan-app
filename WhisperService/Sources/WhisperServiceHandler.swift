import Foundation
import os
import KerwanXPCProtocol

/// Handles transcription requests from the main app via XPC.
///
/// Each XPC connection gets its own handler instance. The handler manages
/// the whisper.cpp model lifecycle and processes transcription requests
/// sequentially to avoid memory contention.
final class WhisperServiceHandler: NSObject, WhisperServiceProtocol {
    private static let logger = Logger(
        subsystem: "com.kerwan.app.whisper-service",
        category: "ServiceHandler"
    )

    /// The path to the currently loaded model, if any.
    private var loadedModelPath: String?

    /// Whether a model is currently loaded and ready for transcription.
    private var isModelLoaded: Bool = false

    /// Supported audio sample rates in Hz.
    private static let supportedSampleRates: Set<Int> = [8000, 16000, 22050, 44100, 48000]

    // MARK: - WhisperServiceProtocol

    /// Loads a whisper.cpp GGML model from the specified path.
    func loadModel(path: String, withReply reply: @escaping (Error?) -> Void) {
        Self.logger.info("Loading model from: \(path, privacy: .public)")

        guard FileManager.default.fileExists(atPath: path) else {
            Self.logger.error("Model file not found: \(path, privacy: .public)")
            reply(WhisperServiceError.modelNotFound(path: path))
            return
        }

        // Unload previous model if any
        if isModelLoaded {
            Self.logger.info("Unloading previous model before loading new one")
            performModelUnload()
        }

        // TODO: Replace with actual whisper.cpp model initialization
        // This will call whisper_init_from_file() from the whisper.cpp C API
        // For now, we validate the file and mark as loaded
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard let fileSize = attributes[.size] as? UInt64, fileSize > 0 else {
                reply(WhisperServiceError.modelLoadFailed(reason: "Model file is empty"))
                return
            }

            Self.logger.info("Model file size: \(fileSize) bytes")
            loadedModelPath = path
            isModelLoaded = true
            Self.logger.info("Model loaded successfully")
            reply(nil)
        } catch {
            Self.logger.error("Failed to read model file attributes: \(error.localizedDescription)")
            reply(WhisperServiceError.modelLoadFailed(reason: error.localizedDescription))
        }
    }

    /// Transcribes raw PCM audio data using the loaded whisper model.
    func transcribe(audioData: Data, sampleRate: Int, withReply reply: @escaping (Data?, Error?) -> Void) {
        Self.logger.info("Transcription request: \(audioData.count) bytes at \(sampleRate) Hz")

        guard isModelLoaded else {
            Self.logger.error("Transcription requested but no model is loaded")
            reply(nil, WhisperServiceError.modelNotLoaded)
            return
        }

        guard Self.supportedSampleRates.contains(sampleRate) else {
            Self.logger.error("Unsupported sample rate: \(sampleRate)")
            reply(nil, WhisperServiceError.unsupportedSampleRate(sampleRate))
            return
        }

        // Validate PCM data: must be 16-bit samples, so byte count must be even
        guard audioData.count >= 2, audioData.count.isMultiple(of: 2) else {
            reply(nil, WhisperServiceError.invalidAudioData(
                reason: "Audio data must contain at least one 16-bit sample (2 bytes), got \(audioData.count) bytes"
            ))
            return
        }

        let sampleCount = audioData.count / 2
        let durationSeconds = Double(sampleCount) / Double(sampleRate)
        Self.logger.info("Audio duration: \(durationSeconds, format: .fixed(precision: 2))s (\(sampleCount) samples)")

        // TODO: Replace with actual whisper.cpp transcription
        // This will call whisper_full() from the whisper.cpp C API,
        // converting 16-bit PCM to float32, resampling to 16 kHz if needed,
        // and extracting segments from the result.
        //
        // For now, return an empty segments array to validate the pipeline.
        let segments: [TranscriptSegment] = []

        do {
            let data = try JSONEncoder().encode(segments)
            Self.logger.info("Transcription complete: \(segments.count) segments")
            reply(data, nil)
        } catch {
            Self.logger.error("Failed to encode segments: \(error.localizedDescription)")
            reply(nil, WhisperServiceError.transcriptionFailed(
                reason: "Failed to encode result: \(error.localizedDescription)"
            ))
        }
    }

    /// Unloads the current model and frees associated memory.
    func unloadModel(withReply reply: @escaping () -> Void) {
        Self.logger.info("Unload model requested")
        performModelUnload()
        reply()
    }

    // MARK: - Private

    /// Internal model unload without reply handler.
    private func performModelUnload() {
        // TODO: Call whisper_free() to release the whisper.cpp context
        loadedModelPath = nil
        isModelLoaded = false
        Self.logger.info("Model unloaded")
    }
}
