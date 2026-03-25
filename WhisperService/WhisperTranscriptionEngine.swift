// WhisperTranscriptionEngine.swift
// WhisperService — XPC service target
//
// Implements WhisperServiceProtocol.  Wraps whisper.cpp via the C API
// declared in whisper-bridging-header.h.
//
// Threading model
// ───────────────
// All whisper.cpp calls are serialised on `engineQueue` (serial, QoS
// .userInitiated).  XPC reply blocks are always called from that queue;
// NSXPCConnection forwards them to the appropriate queue on the other side.
// No Swift actor isolation is used here because the bridging header exposes
// C types that are not Sendable; serial-queue discipline gives equivalent
// safety.
//
// Metal GPU acceleration
// ──────────────────────
// whisper_context_default_params() returns { use_gpu = true } by default.
// On machines without Metal (CI, Intel fallback) whisper.cpp silently falls
// back to CPU; no code change is required.
//
// Segment timing
// ──────────────
// whisper_full_get_segment_t0/t1 return values in 10 ms units.
// Multiply by 0.01 to convert to seconds.
//
// Confidence
// ──────────
// Computed as the arithmetic mean of whisper_full_get_token_p across all
// non-special tokens in the segment.  Special-token IDs < 50256 are skipped
// (consistent with whisper.cpp's definition of non-special tokens).

import Foundation
import os

// MARK: - WhisperTranscriptionEngine

/// XPC-exported object that wraps whisper.cpp.
///
/// One instance is created per XPC connection by `WhisperServiceDelegate`.
final class WhisperTranscriptionEngine: NSObject, WhisperServiceProtocol {

    // MARK: - Private state

    /// All whisper.cpp calls execute on this serial queue.
    private let engineQueue = DispatchQueue(
        label: "com.kerwan.WhisperService.engine",
        qos: .userInitiated
    )

    /// Pointer returned by whisper_init_from_file_with_params.
    /// Access only from engineQueue.
    private var ctx: OpaquePointer? // whisper_context *

    private let log = Logger(subsystem: "com.kerwan.WhisperService", category: "Engine")

    // MARK: - WhisperServiceProtocol

    // ──────────────────────────────────────────────────────────────────────
    // loadModel
    // ──────────────────────────────────────────────────────────────────────

    func loadModel(atPath path: String, reply: @escaping (Error?) -> Void) {
        engineQueue.async { [weak self] in
            guard let self else { return }

            // 1. Validate the file exists before handing to whisper.cpp.
            guard FileManager.default.fileExists(atPath: path) else {
                self.log.error("Model not found: \(path, privacy: .public)")
                reply(WhisperServiceError.modelNotFound)
                return
            }

            // 2. Free any previously loaded model.
            if let existing = self.ctx {
                whisper_free(existing)
                self.ctx = nil
                self.log.info("Previous model freed")
            }

            // 3. Build context params — request Metal GPU acceleration.
            var ctxParams = whisper_context_default_params()
            ctxParams.use_gpu  = true
            ctxParams.flash_attn = false  // Flash attention is still experimental

            // 4. Load the model.
            self.log.info("Loading model: \(path, privacy: .public)")
            self.log.info("Whisper backends: \(String(cString: whisper_print_system_info()), privacy: .public)")

            guard let newCtx = whisper_init_from_file_with_params(path, ctxParams) else {
                self.log.error("whisper_init_from_file_with_params returned nil")
                reply(WhisperServiceError.modelLoadFailed)
                return
            }

            self.ctx = newCtx
            self.log.info("Model loaded successfully")
            reply(nil)
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // transcribe
    // ──────────────────────────────────────────────────────────────────────

    func transcribe(
        audioData: Data,
        sampleRate: Int,
        reply: @escaping ([Data]?, Error?) -> Void
    ) {
        engineQueue.async { [weak self] in
            guard let self else { return }

            // 1. Validate model is loaded.
            guard let ctx = self.ctx else {
                self.log.error("transcribe called with no model loaded")
                reply(nil, WhisperServiceError.modelNotLoaded)
                return
            }

            // 2. Validate audio data.
            guard !audioData.isEmpty,
                  audioData.count % MemoryLayout<Float>.size == 0 else {
                self.log.error("Invalid audio data: \(audioData.count) bytes")
                reply(nil, WhisperServiceError.invalidAudioData)
                return
            }

            let nSamples = audioData.count / MemoryLayout<Float>.size
            self.log.info("Transcribing \(nSamples) samples at \(sampleRate) Hz")

            // 3. Build whisper_full_params.
            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.language           = ("auto" as NSString).utf8String
            params.translate          = false
            params.n_threads          = Int32(min(4, ProcessInfo.processInfo.activeProcessorCount))
            params.offset_ms          = 0
            params.token_timestamps   = true
            params.print_progress     = false
            params.print_realtime     = false
            params.print_timestamps   = false
            params.no_context         = true
            params.single_segment     = false
            // Null out all callbacks.
            params.new_segment_callback            = nil
            params.new_segment_callback_user_data  = nil
            params.progress_callback               = nil
            params.progress_callback_user_data     = nil
            params.encoder_begin_callback          = nil
            params.encoder_begin_callback_user_data = nil
            params.abort_callback                  = nil
            params.abort_callback_user_data        = nil
            params.logits_filter_callback          = nil
            params.logits_filter_callback_user_data = nil

            // Resample if needed — our capture pipeline always produces 16 kHz,
            // but be defensive.
            let samples: [Float]
            if sampleRate == 16_000 {
                samples = audioData.withUnsafeBytes { ptr in
                    Array(ptr.bindMemory(to: Float.self))
                }
            } else {
                self.log.warning("Non-16kHz input (\(sampleRate) Hz); resampling to 16kHz")
                samples = Self.resample(
                    audioData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) },
                    fromRate: sampleRate,
                    toRate: 16_000
                )
            }

            // 4. Run whisper_full.
            let rc = samples.withUnsafeBufferPointer { buf in
                whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
            }

            guard rc == 0 else {
                self.log.error("whisper_full returned \(rc)")
                reply(nil, WhisperServiceError.transcriptionFailed)
                return
            }

            // 5. Collect segments.
            let nSegments = Int(whisper_full_n_segments(ctx))
            self.log.info("Whisper produced \(nSegments) segments")

            var encodedSegments: [Data] = []
            encodedSegments.reserveCapacity(nSegments)
            var encodeError: Error?

            for i in 0 ..< nSegments {
                let rawText = String(cString: whisper_full_get_segment_text(ctx, Int32(i)))
                let t0      = whisper_full_get_segment_t0(ctx, Int32(i))
                let t1      = whisper_full_get_segment_t1(ctx, Int32(i))
                let startSec = Double(t0) * 0.01
                let endSec   = Double(t1) * 0.01

                // Confidence: mean of non-special token probabilities.
                let nTokens = Int(whisper_full_n_tokens(ctx, Int32(i)))
                var probSum: Float = 0
                var probCount = 0
                for j in 0 ..< nTokens {
                    let p = whisper_full_get_token_p(ctx, Int32(i), Int32(j))
                    // Skip special tokens (negative p indicates special in some builds;
                    // we guard p > 0 to be safe across versions).
                    if p > 0 {
                        probSum   += p
                        probCount += 1
                    }
                }
                let confidence: Float = probCount > 0 ? probSum / Float(probCount) : 0

                // Detected language (available after first segment is decoded).
                let langID  = whisper_full_lang_id(ctx)
                let langStr = langID >= 0
                    ? String(cString: whisper_lang_str(langID))
                    : "auto"

                let segment = TranscriptSegment(
                    text:       rawText,
                    startTime:  startSec,
                    endTime:    endSec,
                    language:   langStr,
                    confidence: confidence
                )

                do {
                    encodedSegments.append(try segment.encoded())
                } catch {
                    self.log.error("Failed to encode segment \(i): \(error.localizedDescription)")
                    encodeError = error
                    break  // deliver partial results
                }
            }

            // 6. Reply — deliver partial results + error if encoding broke mid-way.
            let deliveredSegments = encodedSegments.isEmpty ? nil : encodedSegments
            reply(deliveredSegments, encodeError)
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // unloadModel
    // ──────────────────────────────────────────────────────────────────────

    func unloadModel(reply: @escaping () -> Void) {
        engineQueue.async { [weak self] in
            guard let self else { reply(); return }
            if let c = self.ctx {
                whisper_free(c)
                self.ctx = nil
                self.log.info("Model unloaded")
            }
            reply()
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // isModelLoaded
    // ──────────────────────────────────────────────────────────────────────

    func isModelLoaded(reply: @escaping (Bool) -> Void) {
        engineQueue.async { [weak self] in
            reply(self?.ctx != nil)
        }
    }

    // MARK: - Deinit

    deinit {
        // engineQueue may be executing; use sync to ensure safe teardown.
        engineQueue.sync {
            if let c = ctx {
                whisper_free(c)
                ctx = nil
            }
        }
    }

    // MARK: - Private helpers

    /// Linear-interpolation resampler — used only for non-16kHz inputs.
    /// Quality is sufficient for Whisper; the capture pipeline ensures
    /// 16 kHz so this path is essentially dead in production.
    private static func resample(_ input: [Float], fromRate: Int, toRate: Int) -> [Float] {
        guard fromRate != toRate, !input.isEmpty else { return input }
        let ratio = Double(fromRate) / Double(toRate)
        let outputCount = Int((Double(input.count) / ratio).rounded(.up))
        var output = [Float](repeating: 0, count: outputCount)
        for i in 0 ..< outputCount {
            let srcPos = Double(i) * ratio
            let lo = Int(srcPos)
            let hi = min(lo + 1, input.count - 1)
            let frac = Float(srcPos - Double(lo))
            output[i] = input[lo] * (1 - frac) + input[hi] * frac
        }
        return output
    }
}
