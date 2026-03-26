// VoiceActivityDetector.swift
// Kerwan — Capture layer
//
// Energy + ZCR-based Voice Activity Detection for 16 kHz PCM audio.
//
// Algorithm per 500 ms window:
//   1. RMS energy — computed via vDSP_measqv (Accelerate)
//   2. Zero-Crossing Rate — simple sample-pair comparison
//   A window is classified as "speech" when BOTH:
//     • RMS energy exceeds the configurable threshold (default -40 dBFS)
//     • ZCR falls within the speech range (default 50–200 crossings/sec)
//       capturing voiced speech (low ZCR) without passing wideband noise
//       (very high ZCR) or sub-audible rumble (ZCR near zero).
//
// Only chunks with ≥ minSpeechSeconds of detected speech are considered
// to contain speech (default 3.0 s).

import Accelerate
import Foundation

// MARK: - VoiceActivityDetector

/// Stateless, thread-safe energy + ZCR voice activity detector.
///
/// All state is captured in the `Configuration`; an instance can be shared
/// across concurrent queues without synchronisation.
///
/// ```swift
/// let vad = VoiceActivityDetector()
/// let result = vad.analyze(samples)
/// if result.containsSpeech { ... }
/// ```
public struct VoiceActivityDetector: Sendable {

    // MARK: - Configuration

    public struct Configuration: Sendable, Equatable {
        /// RMS energy floor in dBFS. Windows below this are silent.
        /// Default: -40.0 dBFS
        public var energyThresholdDB: Double

        /// Duration of each analysis window in seconds.
        /// Default: 0.5 s (8 000 samples at 16 kHz)
        public var windowSeconds: Double

        /// Minimum cumulative speech duration to classify a chunk as containing speech.
        /// Default: 3.0 s
        public var minSpeechSeconds: Double

        /// Lower bound of speech ZCR range, crossings per second.
        /// Default: 50 / sec (= 25 per 500 ms window)
        public var minZCRPerSecond: Int

        /// Upper bound of speech ZCR range, crossings per second.
        /// Default: 200 / sec (= 100 per 500 ms window)
        public var maxZCRPerSecond: Int

        public static let `default` = Configuration(
            energyThresholdDB: -40.0,
            windowSeconds: 0.5,
            minSpeechSeconds: 3.0,
            minZCRPerSecond: 50,
            maxZCRPerSecond: 200
        )

        public init(
            energyThresholdDB: Double = -40.0,
            windowSeconds: Double = 0.5,
            minSpeechSeconds: Double = 3.0,
            minZCRPerSecond: Int = 50,
            maxZCRPerSecond: Int = 200
        ) {
            self.energyThresholdDB = energyThresholdDB
            self.windowSeconds = windowSeconds
            self.minSpeechSeconds = minSpeechSeconds
            self.minZCRPerSecond = minZCRPerSecond
            self.maxZCRPerSecond = maxZCRPerSecond
        }
    }

    // MARK: - Result

    public struct Result: Sendable, Equatable {
        /// Whether the chunk meets the speech-duration threshold.
        public let containsSpeech: Bool

        /// Total seconds classified as speech (sum of qualifying windows).
        public let speechSeconds: Double

        /// Peak energy across all windows in dBFS.
        public let maxEnergyDB: Double

        /// Total number of complete windows analysed.
        public let windowCount: Int

        /// Number of windows that passed both energy and ZCR criteria.
        public let speechWindowCount: Int
    }

    // MARK: - Properties

    public let config: Configuration
    /// Input sample rate in Hz. Must match the audio delivered to `analyze`.
    public let sampleRate: Int

    // MARK: - Init

    public init(config: Configuration = .default, sampleRate: Int = 16_000) {
        self.config = config
        self.sampleRate = sampleRate
    }

    // MARK: - Analysis

    /// Analyses a buffer of Float32 PCM samples.
    ///
    /// - Parameter samples: Array of Float32 samples at `sampleRate` Hz.
    ///   Must match `sampleRate`; no resampling is performed.
    /// - Returns: A `Result` describing speech presence and energy statistics.
    public func analyze(_ samples: [Float]) -> Result {
        samples.withUnsafeBufferPointer { analyze($0) }
    }

    /// Analyses a raw buffer pointer.  Safe to call from any thread.
    ///
    /// The pointer must remain valid for the duration of this call.
    public func analyze(_ samples: UnsafeBufferPointer<Float>) -> Result {
        let windowSamples = Int(Double(sampleRate) * config.windowSeconds)

        guard windowSamples > 1, samples.count >= windowSamples else {
            return Result(
                containsSpeech: false,
                speechSeconds: 0,
                maxEnergyDB: -160,
                windowCount: 0,
                speechWindowCount: 0
            )
        }

        // Pre-compute per-window ZCR bounds from per-second config values
        let minZCRPerWindow = Int((Double(config.minZCRPerSecond) * config.windowSeconds).rounded(.down))
        let maxZCRPerWindow = Int((Double(config.maxZCRPerSecond) * config.windowSeconds).rounded(.up))
        let requiredSpeechWindows = Int(ceil(config.minSpeechSeconds / config.windowSeconds))

        var speechWindowCount = 0
        var maxEnergyDB: Double = -160
        var windowCount = 0
        var offset = 0

        guard let base = samples.baseAddress else {
            return Result(
                containsSpeech: false, speechSeconds: 0,
                maxEnergyDB: -160, windowCount: 0, speechWindowCount: 0
            )
        }

        while offset + windowSamples <= samples.count {
            let windowPtr = base.advanced(by: offset)

            // ── Energy: RMS via Accelerate (single vDSP call, no allocation) ──
            var meanSquare: Float = 0
            vDSP_measqv(windowPtr, 1, &meanSquare, vDSP_Length(windowSamples))
            let rms = sqrtf(meanSquare)
            // Guard against -∞ in log: clamp to a minimum below any real signal
            let energyDB = Double(20.0 * log10f(max(rms, 1e-7)))
            if energyDB > maxEnergyDB { maxEnergyDB = energyDB }

            // ── ZCR: count sign transitions ───────────────────────────────────
            // Each iteration compares adjacent sample signs; no allocation.
            var zcr = 0
            for i in 1 ..< windowSamples {
                // Treat exactly 0.0 as non-negative (same as >= 0 in IEEE 754)
                if (windowPtr[i] >= 0) != (windowPtr[i - 1] >= 0) { zcr &+= 1 }
            }

            // ── Speech classification ─────────────────────────────────────────
            let passesEnergy = energyDB > config.energyThresholdDB
            let passesZCR = zcr >= minZCRPerWindow && zcr <= maxZCRPerWindow
            if passesEnergy && passesZCR { speechWindowCount &+= 1 }

            windowCount &+= 1
            offset += windowSamples
        }

        let speechSeconds = Double(speechWindowCount) * config.windowSeconds

        return Result(
            containsSpeech: speechWindowCount >= requiredSpeechWindows,
            speechSeconds: speechSeconds,
            maxEnergyDB: maxEnergyDB,
            windowCount: windowCount,
            speechWindowCount: speechWindowCount
        )
    }
}

// MARK: - Convenience: ContiguousArray overload

extension VoiceActivityDetector {
    /// Analyses a `ContiguousArray<Float>` — avoids an extra copy vs `[Float]`.
    public func analyze(_ samples: ContiguousArray<Float>) -> Result {
        samples.withUnsafeBufferPointer { analyze($0) }
    }
}
