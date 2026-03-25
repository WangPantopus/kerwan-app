// VoiceActivityDetectorTests.swift
// KerwanTests — Capture layer
//
// Tests for VoiceActivityDetector using synthetic PCM signals:
//   • Silence (all zeros)
//   • Sine waves at multiple frequencies and amplitudes
//   • Constructed "speech" and "non-speech" signals
//
// Signal generation is deterministic so tests run offline, instantaneously,
// and without any audio hardware.

import XCTest
@testable import Kerwan

// MARK: - Signal generators

private func sineWave(
    frequency: Float,
    amplitude: Float,
    durationSeconds: Double,
    sampleRate: Int = 16_000
) -> [Float] {
    let count = Int(durationSeconds * Double(sampleRate))
    return (0 ..< count).map { i in
        amplitude * sinf(2 * .pi * frequency * Float(i) / Float(sampleRate))
    }
}

/// Generates silence (all zeros).
private func silence(durationSeconds: Double, sampleRate: Int = 16_000) -> [Float] {
    [Float](repeating: 0, count: Int(durationSeconds * Double(sampleRate)))
}

/// Constructs a signal where only the first `speechSeconds` of audio contains
/// a speech-like tone (80 Hz at amplitude `amp`) and the rest is silence.
private func partialSpeech(
    speechSeconds: Double,
    totalSeconds: Double,
    amplitude: Float = 0.3,
    sampleRate: Int = 16_000
) -> [Float] {
    let speech = sineWave(frequency: 80, amplitude: amplitude,
                          durationSeconds: speechSeconds, sampleRate: sampleRate)
    let quiet = silence(durationSeconds: totalSeconds - speechSeconds, sampleRate: sampleRate)
    return speech + quiet
}

// MARK: - VoiceActivityDetectorTests

final class VoiceActivityDetectorTests: XCTestCase {

    // Default VAD under test (all configurable values at spec defaults)
    private let vad = VoiceActivityDetector()
    private let sampleRate = 16_000
    private let windowSeconds = 0.5

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// Expected ZCR per 500 ms window for a pure sine at `frequency` Hz.
    private func expectedZCR(frequency: Float) -> Int {
        Int((2.0 * Double(frequency) * windowSeconds).rounded())
    }

    // MARK: - Silence tests

    func testSilenceHasNoSpeech() {
        let samples = silence(durationSeconds: 30)
        let result = vad.analyze(samples)
        XCTAssertFalse(result.containsSpeech)
        XCTAssertEqual(result.speechWindowCount, 0)
        XCTAssertLessThanOrEqual(result.maxEnergyDB, -100,
            "All-zero signal must have extremely low measured energy")
    }

    func testSilenceHasCorrectWindowCount() {
        let samples = silence(durationSeconds: 30)
        let result = vad.analyze(samples)
        // 30 s / 0.5 s per window = 60 windows
        XCTAssertEqual(result.windowCount, 60)
    }

    func testEmptyInputReturnsFalse() {
        let result = vad.analyze([])
        XCTAssertFalse(result.containsSpeech)
        XCTAssertEqual(result.windowCount, 0)
    }

    func testSubWindowInputReturnsFalse() {
        // Fewer samples than one window (8 000 samples)
        let samples = sineWave(frequency: 80, amplitude: 0.3, durationSeconds: 0.4)
        let result = vad.analyze(samples)
        XCTAssertFalse(result.containsSpeech, "Less than one full window cannot qualify")
    }

    // MARK: - Low-amplitude signal (energy below threshold)

    func testVeryLowAmplitudeIsNotSpeech() {
        // 80 Hz at -80 dBFS (amplitude ≈ 0.0001): well below -40 dBFS threshold
        let samples = sineWave(frequency: 80, amplitude: 0.0001, durationSeconds: 30)
        let result = vad.analyze(samples)
        XCTAssertFalse(result.containsSpeech)
        XCTAssertEqual(result.speechWindowCount, 0, "Sub-threshold energy must not count as speech")
    }

    func testBorderlineAmplitudeIsNotSpeech() {
        // -40 dBFS = amplitude ≈ 0.01. Use 0.008 to sit just below the threshold.
        // 20 × log10(0.008) ≈ -41.9 dBFS
        let samples = sineWave(frequency: 80, amplitude: 0.008, durationSeconds: 30)
        let result = vad.analyze(samples)
        XCTAssertFalse(result.containsSpeech,
            "Amplitude just below -40 dBFS must not qualify as speech")
    }

    // MARK: - Speech-like signal (80 Hz, high amplitude)

    /// 80 Hz: ZCR = 80 per 500 ms window (160/sec) — within [50, 200]/sec range.
    /// amplitude 0.3: energy ≈ -10.4 dBFS — well above -40 dBFS.
    func testSpeechLikeTonePassesVAD() {
        let samples = sineWave(frequency: 80, amplitude: 0.3, durationSeconds: 30)
        let result = vad.analyze(samples)
        XCTAssertTrue(result.containsSpeech)
        XCTAssertGreaterThanOrEqual(result.speechSeconds, 3.0,
            "30 s of speech-like audio must exceed the 3 s minimum")
        XCTAssertGreaterThan(result.maxEnergyDB, -40)
    }

    func testSpeechLikeToneWindowCount() {
        let samples = sineWave(frequency: 80, amplitude: 0.3, durationSeconds: 30)
        let result = vad.analyze(samples)
        // Each speech window = 0.5 s; 30 s / 0.5 s = 60 windows; all should be speech
        XCTAssertEqual(result.windowCount, 60)
        XCTAssertEqual(result.speechWindowCount, 60)
    }

    func testSpeechLikeToneAtMinThresholdPasses() {
        // Amplitude just above -40 dBFS: 20 × log10(0.011) ≈ -39.2 dBFS
        let samples = sineWave(frequency: 80, amplitude: 0.011, durationSeconds: 30)
        let result = vad.analyze(samples)
        XCTAssertTrue(result.containsSpeech,
            "Amplitude just above threshold with in-range ZCR must qualify")
    }

    // MARK: - ZCR: frequency too high (noise-like signal)

    /// 440 Hz: ZCR = 440 per 500 ms window (880/sec) — above the 200/sec maximum.
    func testHighFrequencyToneFailsZCR() {
        let samples = sineWave(frequency: 440, amplitude: 0.3, durationSeconds: 30)
        let result = vad.analyze(samples)

        // Verify energy is above threshold (so only ZCR is the gate)
        XCTAssertGreaterThan(result.maxEnergyDB, -40,
            "440 Hz sine at 0.3 amplitude must exceed energy threshold")
        // ZCR should cause rejection
        XCTAssertFalse(result.containsSpeech,
            "440 Hz (880 ZCR/sec) exceeds the 200/sec maximum speech ZCR")
        XCTAssertEqual(result.speechWindowCount, 0)
    }

    func test1kHzToneFailsZCR() {
        let samples = sineWave(frequency: 1000, amplitude: 0.5, durationSeconds: 30)
        let result = vad.analyze(samples)
        XCTAssertFalse(result.containsSpeech, "1 kHz tone is far above the ZCR speech range")
    }

    // MARK: - ZCR: frequency too low (sub-bass / DC-like signal)

    /// 1 Hz: ZCR = 1 per 500 ms window (2/sec) — below the 50/sec minimum.
    func testVeryLowFrequencyFailsZCR() {
        let samples = sineWave(frequency: 1, amplitude: 0.3, durationSeconds: 30)
        let result = vad.analyze(samples)
        XCTAssertFalse(result.containsSpeech,
            "1 Hz signal (2 ZCR/sec) is below the 50/sec minimum speech ZCR")
    }

    func test10HzToneFailsZCR() {
        let samples = sineWave(frequency: 10, amplitude: 0.3, durationSeconds: 30)
        let result = vad.analyze(samples)
        XCTAssertFalse(result.containsSpeech, "10 Hz tone (20 ZCR/sec) is below minimum speech ZCR")
    }

    // MARK: - Minimum speech duration gate

    func testExactlyThreeSecondsPassesMinimum() {
        // Build a signal where exactly 6 windows (3 s) contain speech-like audio
        // and the remaining 54 windows are silence.
        let speech = sineWave(frequency: 80, amplitude: 0.3, durationSeconds: 3.0)
        let quiet = silence(durationSeconds: 27.0)
        let samples = speech + quiet

        let result = vad.analyze(samples)
        XCTAssertTrue(result.containsSpeech,
            "Exactly 3 s of speech should meet the 3 s minimum")
        XCTAssertEqual(result.speechWindowCount, 6)
    }

    func testBelowMinimumSpeechDurationFails() {
        // 2.5 s = 5 windows — one short of the 6-window (3 s) requirement
        let speech = sineWave(frequency: 80, amplitude: 0.3, durationSeconds: 2.5)
        let quiet = silence(durationSeconds: 27.5)
        let samples = speech + quiet

        let result = vad.analyze(samples)
        XCTAssertFalse(result.containsSpeech,
            "2.5 s of speech must fail the 3 s minimum duration gate")
        XCTAssertEqual(result.speechWindowCount, 5)
    }

    func testSpeechInMiddleOfChunk() {
        // Speech in the middle (seconds 10–15), silence on either side
        let lead = silence(durationSeconds: 10)
        let speech = sineWave(frequency: 80, amplitude: 0.3, durationSeconds: 5)
        let tail = silence(durationSeconds: 15)
        let samples = lead + speech + tail

        let result = vad.analyze(samples)
        XCTAssertTrue(result.containsSpeech,
            "5 s of speech embedded in silence should pass the 3 s gate")
        XCTAssertEqual(result.speechWindowCount, 10, "5 s / 0.5 s window = 10 speech windows")
    }

    func testIntermittentSpeechAccumulates() {
        // 10 × (500 ms speech + 500 ms silence) = 5 s speech in 10 s total
        var samples: [Float] = []
        for _ in 0 ..< 10 {
            samples += sineWave(frequency: 80, amplitude: 0.3, durationSeconds: 0.5)
            samples += silence(durationSeconds: 0.5)
        }
        // Fill to 30 s with silence
        samples += silence(durationSeconds: 20)

        let result = vad.analyze(samples)
        XCTAssertTrue(result.containsSpeech,
            "Intermittent speech totalling 5 s must exceed the 3 s minimum")
        XCTAssertEqual(result.speechWindowCount, 10)
        XCTAssertEqual(result.speechSeconds, 5.0, accuracy: 0.01)
    }

    func testOnlySilenceChunkFails() {
        let samples = silence(durationSeconds: 30)
        let result = vad.analyze(samples)
        XCTAssertFalse(result.containsSpeech)
        XCTAssertEqual(result.speechWindowCount, 0)
        XCTAssertEqual(result.speechSeconds, 0)
    }

    // MARK: - Energy measurement accuracy

    func testMaxEnergyDBIsReasonableForSineWave() {
        // 0 dBFS sine wave: RMS = 1/√2 ≈ 0.707 → 20 × log10(0.707) ≈ -3 dBFS
        let samples = sineWave(frequency: 80, amplitude: 1.0, durationSeconds: 30)
        let result = vad.analyze(samples)
        // Allow ±2 dB for floating-point and windowing effects
        XCTAssertEqual(result.maxEnergyDB, -3.0, accuracy: 2.0,
            "Full-scale sine should measure approximately -3 dBFS")
    }

    func testMaxEnergyDBIsCorrectForKnownAmplitude() {
        // amplitude 0.1: RMS = 0.1/√2 ≈ 0.0707 → 20 × log10(0.0707) ≈ -23 dBFS
        let samples = sineWave(frequency: 80, amplitude: 0.1, durationSeconds: 30)
        let result = vad.analyze(samples)
        XCTAssertEqual(result.maxEnergyDB, -23.0, accuracy: 2.0)
    }

    // MARK: - Configuration overrides

    func testLowerEnergyThresholdAllowsQuieterSpeech() {
        // A VAD with -60 dBFS threshold should classify very quiet speech as speech
        let quietVAD = VoiceActivityDetector(
            config: VoiceActivityDetector.Configuration(
                energyThresholdDB: -60,
                windowSeconds: 0.5,
                minSpeechSeconds: 3.0,
                minZCRPerSecond: 50,
                maxZCRPerSecond: 200
            )
        )
        // 80 Hz at amplitude 0.001 ≈ -60 dBFS — just above the relaxed threshold
        let samples = sineWave(frequency: 80, amplitude: 0.0015, durationSeconds: 30)
        let result = quietVAD.analyze(samples)
        XCTAssertTrue(result.containsSpeech,
            "With -60 dBFS threshold, near-threshold speech should qualify")
    }

    func testHigherMinSpeechDurationMakesSignalFail() {
        // Require 10 s of speech — our 5 s signal should now fail
        let strictVAD = VoiceActivityDetector(
            config: VoiceActivityDetector.Configuration(
                energyThresholdDB: -40,
                windowSeconds: 0.5,
                minSpeechSeconds: 10.0,
                minZCRPerSecond: 50,
                maxZCRPerSecond: 200
            )
        )
        let samples = partialSpeech(speechSeconds: 5, totalSeconds: 30)
        let result = strictVAD.analyze(samples)
        XCTAssertFalse(result.containsSpeech,
            "5 s of speech must fail a 10 s minimum requirement")
    }

    func testWiderZCRRangeAllowsHigherFrequency() {
        // Extend max ZCR to 1000/sec: 440 Hz tone should now pass
        let wideVAD = VoiceActivityDetector(
            config: VoiceActivityDetector.Configuration(
                energyThresholdDB: -40,
                windowSeconds: 0.5,
                minSpeechSeconds: 3.0,
                minZCRPerSecond: 50,
                maxZCRPerSecond: 1000
            )
        )
        let samples = sineWave(frequency: 440, amplitude: 0.3, durationSeconds: 30)
        let result = wideVAD.analyze(samples)
        XCTAssertTrue(result.containsSpeech,
            "With ZCR max raised to 1000/sec, 440 Hz should pass")
    }

    // MARK: - ContiguousArray overload

    func testContiguousArrayOverloadMatchesArrayOverload() {
        let array = sineWave(frequency: 80, amplitude: 0.3, durationSeconds: 30)
        let contiguous = ContiguousArray(array)

        let r1 = vad.analyze(array)
        let r2 = vad.analyze(contiguous)

        XCTAssertEqual(r1.containsSpeech, r2.containsSpeech)
        XCTAssertEqual(r1.speechWindowCount, r2.speechWindowCount)
        XCTAssertEqual(r1.maxEnergyDB, r2.maxEnergyDB, accuracy: 0.001)
    }

    // MARK: - ZCR per-window calculation

    func testZCRBoundsCalculatedFromPerSecondConfig() {
        // With the default config (50–200/sec, 0.5 s window):
        // minZCRPerWindow = floor(50 × 0.5) = 25
        // maxZCRPerWindow = ceil(200 × 0.5) = 100
        let config = VoiceActivityDetector.Configuration.default
        let vad = VoiceActivityDetector(config: config)

        // 50 Hz tone: 50 ZCR/window = exactly minZCRPerWindow → should pass
        let at50Hz = sineWave(frequency: 50, amplitude: 0.3, durationSeconds: 30)
        let result50 = vad.analyze(at50Hz)
        XCTAssertTrue(result50.containsSpeech, "50 Hz (50 ZCR/window) should be at the lower bound and pass")

        // 100 Hz tone: 100 ZCR/window = exactly maxZCRPerWindow → should pass
        let at100Hz = sineWave(frequency: 100, amplitude: 0.3, durationSeconds: 30)
        let result100 = vad.analyze(at100Hz)
        XCTAssertTrue(result100.containsSpeech, "100 Hz (100 ZCR/window) should be at the upper bound and pass")
    }

    // MARK: - Different sample rates

    func testVADAt8kHz() {
        // Same signal, but at 8 kHz — use a 8 kHz VAD
        let vad8k = VoiceActivityDetector(
            config: .default,
            sampleRate: 8_000
        )
        // 80 Hz sine is still in the speech ZCR range at 8 kHz
        // ZCR = 2 × 80 × 0.5 = 80 per window at any sample rate
        let samples = sineWave(frequency: 80, amplitude: 0.3, durationSeconds: 30, sampleRate: 8_000)
        let result = vad8k.analyze(samples)
        XCTAssertTrue(result.containsSpeech)
    }

    // MARK: - Result properties

    func testResultPropertiesAreConsistent() {
        let speech = sineWave(frequency: 80, amplitude: 0.3, durationSeconds: 30)
        let result = vad.analyze(speech)
        XCTAssertEqual(result.speechSeconds,
                       Double(result.speechWindowCount) * 0.5, accuracy: 0.001)
        XCTAssertLessThanOrEqual(result.speechWindowCount, result.windowCount)
    }

    func testVADConfigurationEquality() {
        let c1 = VoiceActivityDetector.Configuration.default
        let c2 = VoiceActivityDetector.Configuration.default
        XCTAssertEqual(c1, c2)
    }
}
