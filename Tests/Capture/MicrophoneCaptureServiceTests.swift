// MicrophoneCaptureServiceTests.swift
// KerwanTests — Capture layer
//
// Tests for MicrophoneCaptureService, AudioAccumulator, and their interaction.
//
// Test strategy
// ─────────────
// • AVAudioEngine cannot be meaningfully mocked. Tests that exercise the full
//   capture pipeline (real engine + hardware) are integration tests and are NOT
//   included here — they require an audio input device.
//
// • The service's public lifecycle (start / pause / resume / stop) is tested
//   through injected Environment closures that control permission responses.
//
// • AudioAccumulator is tested directly with synthetic sample arrays, verifying
//   chunking, overlap, and flush semantics without involving the engine at all.
//
// • AudioChunk model properties are verified for correctness.
//
// • VAD integration is tested via VoiceActivityDetectorTests (separate file).

import XCTest
import AVFoundation
@testable import Kerwan

// MARK: - Mock delegate

actor MockAudioChunkDelegate: AudioChunkDelegate {
    private(set) var receivedChunks: [AudioChunk] = []

    func didCaptureAudioChunk(_ chunk: AudioChunk) async {
        receivedChunks.append(chunk)
    }

    func reset() {
        receivedChunks = []
    }
}

// MARK: - AudioAccumulatorTests

/// Tests chunking, overlap, and flush logic using synthetic sample arrays.
/// No AVAudioEngine involved — all samples are injected via UnsafeBufferPointer.
final class AudioAccumulatorTests: XCTestCase {

    private typealias Acc = MicrophoneCaptureService.AudioAccumulator

    // Standard test parameters
    private let sampleRate = 16_000
    private let chunkDuration = 30.0  // 480 000 samples
    private let overlapDuration = 2.0  // 32 000 samples
    // stepSamples = 480 000 − 32 000 = 448 000

    private func makeAccumulator() -> Acc {
        Acc(sampleRate: sampleRate, chunkDuration: chunkDuration, overlapDuration: overlapDuration)
    }

    // MARK: - Fundamental constants

    func testChunkAndStepSamplesAreCorrect() {
        let acc = makeAccumulator()
        XCTAssertEqual(acc.chunkSamples, 480_000, "30 s × 16 000 Hz = 480 000")
        XCTAssertEqual(acc.stepSamples, 448_000, "(30 − 2) s × 16 000 Hz = 448 000")
    }

    // MARK: - No chunk until full

    func testNoChunkUntilChunkSamplesReached() {
        let acc = makeAccumulator()
        let partial = [Float](repeating: 0.5, count: 479_999)  // one short
        let chunks = partial.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: Date()) }
        XCTAssertTrue(chunks.isEmpty, "479 999 samples must not produce a chunk")
    }

    func testExactlyOneChunkAtChunkBoundary() {
        let acc = makeAccumulator()
        let full = [Float](repeating: 0.5, count: 480_000)
        let chunks = full.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: Date()) }
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].samples.count, 480_000)
    }

    // MARK: - Overlap / step

    func testOverlapIsPreservedAfterChunk() {
        let acc = makeAccumulator()
        // Fill exactly one chunk
        let samples = [Float](repeating: 0.1, count: 480_000)
        _ = samples.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: Date()) }

        // Now add 1 more sample — still no second chunk (need stepSamples more to complete next)
        let one: [Float] = [0.9]
        let chunks = one.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: Date()) }
        XCTAssertTrue(chunks.isEmpty, "1 new sample after first chunk should not trigger a second chunk")
    }

    func testSecondChunkRequiresStepMoreSamples() {
        let acc = makeAccumulator()

        let first = [Float](repeating: 0.1, count: 480_000)
        _ = first.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: Date()) }

        // Add exactly stepSamples − 1: still no second chunk
        let almostStep = [Float](repeating: 0.2, count: 448_000 - 1)
        let noChunk = almostStep.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: Date()) }
        XCTAssertTrue(noChunk.isEmpty)

        // Add the last sample: now we have exactly chunkSamples again
        let lastOne: [Float] = [0.3]
        let chunks = lastOne.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: Date()) }
        XCTAssertEqual(chunks.count, 1, "Adding the final sample of the step must produce the second chunk")
    }

    // MARK: - Overlap content

    func testOverlapRegionMatchesEndOfFirstChunk() {
        // Fill with a ramp [0, 1, 2, ..., 479999] so we can identify which
        // samples end up in the second chunk's prefix.
        var acc = makeAccumulator()
        let ramp = (0 ..< 480_000).map { Float($0) }

        let firstChunks = ramp.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: Date()) }
        XCTAssertEqual(firstChunks.count, 1)

        // The overlap is the last overlapSamples (32 000) of the ramp.
        // After the step, the internal buffer should contain ramp[448000...479999].
        // Feed enough samples to complete the second chunk.
        let step = (480_000 ..< 928_000).map { Float($0) }  // 448 000 new samples
        let secondChunks = step.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: Date()) }
        XCTAssertEqual(secondChunks.count, 1)

        let second = secondChunks[0]
        XCTAssertEqual(second.samples.count, 480_000)

        // Verify the first 32 000 samples of the second chunk = last 32 000 of first chunk
        // i.e. second.samples[0..<32000] == ramp[448000..<480000]
        for i in 0 ..< 100 {
            XCTAssertEqual(second.samples[i], ramp[448_000 + i], accuracy: 0.001,
                "Overlap mismatch at index \(i)")
        }
        // Spot-check the end of the overlap
        XCTAssertEqual(second.samples[31_999], ramp[479_999], accuracy: 0.001)
        // Verify samples after the overlap region are the new step samples
        XCTAssertEqual(second.samples[32_000], ramp[480_000], accuracy: 0.001)
    }

    // MARK: - Timestamp progression

    func testChunkStartTimesAdvanceByStepDuration() throws {
        let acc = makeAccumulator()
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let expectedStep = Double(448_000) / Double(sampleRate)  // 28 s

        let first = [Float](repeating: 0, count: 480_000)
        let chunks1 = first.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: t0) }
        XCTAssertEqual(chunks1.count, 1)
        XCTAssertEqual(chunks1[0].startTime, t0)

        let second = [Float](repeating: 0, count: 448_000)
        let chunks2 = second.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: t0) }
        XCTAssertEqual(chunks2.count, 1)

        let delta = chunks2[0].startTime.timeIntervalSince(t0)
        XCTAssertEqual(delta, expectedStep, accuracy: 0.001,
            "Second chunk startTime must be exactly one step duration after the first")
    }

    func testFirstSampleSetsStartTime() {
        let acc = makeAccumulator()
        let t = Date(timeIntervalSinceReferenceDate: 999_999)
        let samples = [Float](repeating: 0, count: 480_000)
        let chunks = samples.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: t) }
        XCTAssertEqual(chunks[0].startTime, t)
    }

    // MARK: - Multi-chunk delivery per call

    func testMultipleChunksFromSingleAppend() {
        let acc = makeAccumulator()
        // 2 × chunkSamples in one append = 2 chunks
        // But second chunk requires stepSamples new samples after first, so
        // to get 2 chunks we need chunkSamples + stepSamples = 928 000 samples.
        let samples = [Float](repeating: 0.1, count: 928_000)
        let chunks = samples.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: Date()) }
        XCTAssertEqual(chunks.count, 2, "928 000 samples should produce exactly 2 chunks")
    }

    func testSmallIncrementalAppends() {
        let acc = makeAccumulator()
        let wallTime = Date()
        var totalChunks = 0

        // Feed 500 samples at a time, totalling 960 000 (= 2 × stepSamples + 2 × overlapSamples)
        let batchSize = 500
        let totalSamples = 928_000  // exactly enough for 2 chunks
        var fed = 0

        while fed < totalSamples {
            let batch = min(batchSize, totalSamples - fed)
            let samples = [Float](repeating: 0.1, count: batch)
            let chunks = samples.withUnsafeBufferPointer {
                acc.append(samples: $0, wallTime: wallTime)
            }
            totalChunks += chunks.count
            fed += batch
        }
        XCTAssertEqual(totalChunks, 2, "Small incremental feeds must eventually produce 2 chunks")
    }

    // MARK: - Flush

    func testFlushReturnsPartialBuffer() throws {
        let acc = makeAccumulator()
        let partial = [Float](repeating: 0.7, count: 1_000)
        _ = partial.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: Date()) }

        let flushed = try XCTUnwrap(acc.flush(), "flush() must return the partial buffer")
        XCTAssertEqual(flushed.samples.count, 1_000)
    }

    func testFlushReturnsNilWhenBufferIsEmpty() {
        let acc = makeAccumulator()
        XCTAssertNil(acc.flush(), "flush() on empty accumulator must return nil")
    }

    func testFlushClearsBuffer() throws {
        let acc = makeAccumulator()
        let samples = [Float](repeating: 0.5, count: 100)
        _ = samples.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: Date()) }

        _ = try XCTUnwrap(acc.flush())
        XCTAssertNil(acc.flush(), "Second flush must return nil (buffer was cleared)")
    }

    func testFlushPreservesStartTime() throws {
        let acc = makeAccumulator()
        let t = Date(timeIntervalSinceReferenceDate: 1_234_567)
        let samples = [Float](repeating: 0.1, count: 500)
        _ = samples.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: t) }

        let chunk = try XCTUnwrap(acc.flush())
        XCTAssertEqual(chunk.startTime, t)
    }

    // MARK: - Reset

    func testResetClearsBuffer() {
        let acc = makeAccumulator()
        let samples = [Float](repeating: 0.5, count: 100)
        _ = samples.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: Date()) }
        acc.reset()
        XCTAssertNil(acc.flush(), "After reset, flush must return nil")
    }

    func testResetAllowsNewStartTime() {
        let acc = makeAccumulator()
        let t1 = Date(timeIntervalSinceReferenceDate: 1_000)
        let t2 = Date(timeIntervalSinceReferenceDate: 2_000)

        let s1 = [Float](repeating: 0, count: 480_000)
        let chunks1 = s1.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: t1) }
        XCTAssertEqual(chunks1.first?.startTime, t1)

        acc.reset()

        let s2 = [Float](repeating: 0, count: 480_000)
        let chunks2 = s2.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: t2) }
        XCTAssertEqual(chunks2.first?.startTime, t2, "After reset, new startTime should be t2")
    }
}

// MARK: - AudioChunkTests

final class AudioChunkTests: XCTestCase {

    func testSampleCountDerivesFromDataLength() {
        let samples = [Float](repeating: 0, count: 16_000)
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let chunk = AudioChunk(
            data: data, sampleRate: 16_000, startTime: Date(),
            durationSeconds: 1.0, containsSpeech: true
        )
        XCTAssertEqual(chunk.sampleCount, 16_000)
    }

    func testDurationSecondsIsStored() {
        let chunk = AudioChunk(
            data: Data(), sampleRate: 16_000, startTime: Date(),
            durationSeconds: 29.97, containsSpeech: false
        )
        XCTAssertEqual(chunk.durationSeconds, 29.97, accuracy: 0.001)
    }

    func testChunksHaveUniqueIDs() {
        let ids = (0 ..< 100).map { _ in
            AudioChunk(data: Data(), sampleRate: 16_000, startTime: Date(),
                       durationSeconds: 1.0, containsSpeech: false).id
        }
        XCTAssertEqual(ids.count, Set(ids).count, "AudioChunk IDs must be unique")
    }

    func testContainsSpeechFlagIsPreserved() {
        let speechChunk = AudioChunk(data: Data(), sampleRate: 16_000, startTime: Date(),
                                     durationSeconds: 1.0, containsSpeech: true)
        let silentChunk = AudioChunk(data: Data(), sampleRate: 16_000, startTime: Date(),
                                     durationSeconds: 1.0, containsSpeech: false)
        XCTAssertTrue(speechChunk.containsSpeech)
        XCTAssertFalse(silentChunk.containsSpeech)
    }
}

// MARK: - MicrophoneCaptureServiceLifecycleTests

@MainActor
final class MicrophoneCaptureServiceLifecycleTests: XCTestCase {

    private var delegate: MockAudioChunkDelegate!

    override func setUp() async throws {
        try await super.setUp()
        delegate = MockAudioChunkDelegate()
    }

    override func tearDown() async throws {
        delegate = nil
        try await super.tearDown()
    }

    // MARK: - Permission-denied path

    func testStartThrowsWhenPermissionDenied() async {
        let service = makeService(authorized: false, alreadyDetermined: true)
        do {
            try await service.start()
            XCTFail("Expected MicrophoneCaptureError.permissionDenied to be thrown")
        } catch MicrophoneCaptureError.permissionDenied {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(service.state, .idle)
    }

    func testStartThrowsWhenUserDeniesDynamicPrompt() async {
        let service = makeService(authorized: false, alreadyDetermined: false)
        do {
            try await service.start()
            XCTFail("Expected permissionDenied")
        } catch MicrophoneCaptureError.permissionDenied {
            // Expected
        } catch {
            XCTFail("Unexpected: \(error)")
        }
        XCTAssertEqual(service.state, .idle)
    }

    // MARK: - State machine

    func testInitialStateIsIdle() {
        let service = makeService(authorized: true)
        XCTAssertEqual(service.state, .idle)
    }

    func testPauseFromIdleIsNoop() {
        let service = makeService(authorized: true)
        service.pause()  // must not crash
        XCTAssertEqual(service.state, .idle)
    }

    func testResumeFromIdleIsNoop() throws {
        let service = makeService(authorized: true)
        try service.resume()  // must not crash
        XCTAssertEqual(service.state, .idle)
    }

    func testStopFromIdleIsNoop() async {
        let service = makeService(authorized: true)
        await service.stop()  // must not crash
        XCTAssertEqual(service.state, .idle)
    }

    func testDoubleStopIsNoop() async {
        // Service in stopped state — a second stop must not crash
        let service = makeService(authorized: false, alreadyDetermined: true)
        await service.stop()
        await service.stop()
        XCTAssertEqual(service.state, .idle)
    }

    // MARK: - MicrophoneCaptureError

    func testErrorDescriptionsAreNonEmpty() {
        let errors: [MicrophoneCaptureError] = [
            .permissionDenied,
            .noInputDevice,
            .engineStartFailed("test"),
            .converterSetupFailed("test"),
            .invalidState("test")
        ]
        for error in errors {
            XCTAssertFalse(
                (error.errorDescription ?? "").isEmpty,
                "\(error) must have a non-empty error description"
            )
        }
    }

    // MARK: - Configuration validation

    func testDefaultConfigurationIsValid() {
        let config = MicrophoneCaptureService.Configuration.default
        XCTAssertEqual(config.targetSampleRate, 16_000)
        XCTAssertEqual(config.chunkDurationSeconds, 30.0)
        XCTAssertEqual(config.overlapSeconds, 2.0)
        XCTAssertLessThan(config.overlapSeconds, config.chunkDurationSeconds)
    }

    func testCustomConfigurationIsApplied() {
        let config = MicrophoneCaptureService.Configuration(
            targetSampleRate: 8_000,
            chunkDurationSeconds: 15.0,
            overlapSeconds: 1.0
        )
        XCTAssertEqual(config.targetSampleRate, 8_000)
        XCTAssertEqual(config.chunkDurationSeconds, 15.0)
        XCTAssertEqual(config.overlapSeconds, 1.0)
    }

    // MARK: - VAD integration through accumulator

    /// Drives the accumulator directly to verify the full VAD→chunk pipeline
    /// without an AVAudioEngine. This is the closest we can get to an end-to-end
    /// test without real hardware.
    func testAccumulatorProducesVADFiltered_SpeechChunk() async throws {
        let service = makeService(authorized: true)

        // Build 30 s of speech-like audio (80 Hz, amplitude 0.3)
        let speechSamples = sineWave(frequency: 80, amplitude: 0.3,
                                     durationSeconds: 30, sampleRate: 16_000)
        let contiguous = ContiguousArray(speechSamples)
        let startTime = Date()

        // Feed directly into the processor's accumulator (bypasses AVAudioEngine)
        let rawChunks: [MicrophoneCaptureService.AudioAccumulator.RawChunk] =
            contiguous.withUnsafeBufferPointer { ptr in
                service.processor.accumulator.append(samples: ptr, wallTime: startTime)
            }

        XCTAssertEqual(rawChunks.count, 1)
        let raw = try XCTUnwrap(rawChunks.first)
        XCTAssertEqual(raw.samples.count, 480_000)

        // VAD should classify this as speech
        let vad = service.processor.vad
        let result = vad.analyze(raw.samples)
        XCTAssertTrue(result.containsSpeech)
        XCTAssertGreaterThanOrEqual(result.speechSeconds, 3.0)
    }

    func testAccumulatorProducesVADFiltered_SilentChunk() throws {
        let service = makeService(authorized: true)

        let silentSamples = ContiguousArray([Float](repeating: 0, count: 480_000))
        let rawChunks: [MicrophoneCaptureService.AudioAccumulator.RawChunk] =
            silentSamples.withUnsafeBufferPointer { ptr in
                service.processor.accumulator.append(samples: ptr, wallTime: Date())
            }

        XCTAssertEqual(rawChunks.count, 1)
        let raw = try XCTUnwrap(rawChunks.first)

        let result = service.processor.vad.analyze(raw.samples)
        XCTAssertFalse(result.containsSpeech, "Silent chunk must not be classified as speech")
    }

    // MARK: - Helpers

    private func makeService(
        authorized: Bool,
        alreadyDetermined: Bool = true
    ) -> MicrophoneCaptureService {
        let env = MicrophoneCaptureService.Environment(
            requestPermission: { authorized },
            authorizationStatus: {
                if alreadyDetermined {
                    return authorized ? .authorized : .denied
                }
                return .notDetermined
            }
        )
        return MicrophoneCaptureService(
            delegate: delegate,
            config: .default,
            environment: env
        )
    }
}

// MARK: - Local signal generator (duplicated from VoiceActivityDetectorTests for isolation)

private func sineWave(
    frequency: Float,
    amplitude: Float,
    durationSeconds: Double,
    sampleRate: Int
) -> [Float] {
    let count = Int(durationSeconds * Double(sampleRate))
    return (0 ..< count).map { i in
        amplitude * sinf(2 * .pi * frequency * Float(i) / Float(sampleRate))
    }
}
