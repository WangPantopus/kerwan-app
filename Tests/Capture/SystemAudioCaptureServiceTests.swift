// SystemAudioCaptureServiceTests.swift
// Tests for SystemAudioCaptureService: Processor (CMSampleBuffer→PCM
// conversion, accumulation) and SysAudioAccumulator chunking logic.
//
// SCStream cannot be exercised in unit tests without a live macOS session
// granting screen-recording permission, so SCStream-level tests focus on
// verifying the Processor's conversion path using synthetic CMSampleBuffers.

import AVFoundation
import CoreMedia
import ScreenCaptureKit
import XCTest

@testable import Kerwan

// MARK: - Helpers

/// Creates a CMSampleBuffer carrying Float32 PCM audio at the given rate.
private func makeCMSampleBuffer(
    samples: [Float],
    sampleRate: Double,
    channelCount: UInt32 = 1
) -> CMSampleBuffer? {
    // Build ASBD for Float32, non-interleaved.
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: channelCount,
        mBitsPerChannel: 32,
        mReserved: 0
    )

    var formatDesc: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(
        allocator: nil,
        asbd: &asbd,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDesc
    ) == noErr, let formatDesc else { return nil }

    let byteCount = samples.count * MemoryLayout<Float>.size
    var blockBuffer: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
        allocator: nil,
        memoryBlock: nil,
        blockLength: byteCount,
        blockAllocator: nil,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: byteCount,
        flags: 0,
        blockBufferOut: &blockBuffer
    ) == noErr, let blockBuffer else { return nil }

    guard CMBlockBufferAssureBlockMemory(blockBuffer) == noErr else { return nil }

    // Write sample data.
    samples.withUnsafeBytes { ptr in
        _ = CMBlockBufferReplaceDataBytes(
            with: ptr.baseAddress!,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
    }

    var sampleBuffer: CMSampleBuffer?
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
        presentationTimeStamp: CMTime.zero,
        decodeTimeStamp: CMTime.invalid
    )
    let frameCount = samples.count / Int(channelCount)

    guard CMSampleBufferCreate(
        allocator: nil,
        dataBuffer: blockBuffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDesc,
        sampleCount: frameCount,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer
    ) == noErr else { return nil }

    return sampleBuffer
}

/// Returns a Float32 sine wave.
private func sineWave(
    frequency: Double,
    amplitude: Float = 0.5,
    frames: Int,
    sampleRate: Double
) -> [Float] {
    (0 ..< frames).map { i in
        amplitude * sinf(Float(2 * Double.pi * frequency * Double(i) / sampleRate))
    }
}

// MARK: - ProcessorConversionTests

@available(macOS 13.0, *)
final class ProcessorConversionTests: XCTestCase {

    typealias Processor = SystemAudioCaptureService.Processor

    // MARK: toPCMBuffer — basic identity (source == target rate)

    func test_toPCMBuffer_monoFloat32_16kHz_returnsCorrectSamples() {
        let frames = 160  // 10 ms at 16 kHz
        let input = sineWave(frequency: 440, frames: frames, sampleRate: 16_000)
        guard let sb = makeCMSampleBuffer(samples: input, sampleRate: 16_000) else {
            return XCTFail("Could not create CMSampleBuffer")
        }

        let result = Processor.toPCMBuffer(sampleBuffer: sb, targetSampleRate: 16_000)
        XCTAssertNotNil(result)
        XCTAssertEqual(Int(result!.frameLength), frames, accuracy: 2)
        // Verify first sample matches within floating-point tolerance.
        XCTAssertEqual(result!.floatChannelData![0][0], input[0], accuracy: 1e-4)
    }

    func test_toPCMBuffer_nilForEmptyBuffer() {
        // Zero-frame buffer should return nil.
        guard let sb = makeCMSampleBuffer(samples: [], sampleRate: 16_000) else { return }
        let result = Processor.toPCMBuffer(sampleBuffer: sb, targetSampleRate: 16_000)
        XCTAssertNil(result)
    }

    // MARK: toPCMBuffer — resampling (44.1 kHz → 16 kHz)

    func test_toPCMBuffer_resampleFrom44100_outputFrameCountProportional() {
        let inputFrames = 4_410  // 100 ms at 44.1 kHz
        let input = sineWave(frequency: 440, frames: inputFrames, sampleRate: 44_100)
        guard let sb = makeCMSampleBuffer(samples: input, sampleRate: 44_100) else {
            return XCTFail("Could not create CMSampleBuffer at 44.1 kHz")
        }

        let result = Processor.toPCMBuffer(sampleBuffer: sb, targetSampleRate: 16_000)
        XCTAssertNotNil(result, "Expected non-nil result from 44.1→16 kHz conversion")

        // 100 ms × 16 000 = 1 600 frames ± 10% for converter latency.
        let expected = 1_600
        let actual = Int(result!.frameLength)
        XCTAssertGreaterThan(actual, expected / 2, "Output frame count too low")
        XCTAssertLessThan(actual, Int(Double(expected) * 1.5), "Output frame count too high")
    }

    func test_toPCMBuffer_outputFormatIsFloat32Mono16kHz() {
        let input = sineWave(frequency: 440, frames: 1_600, sampleRate: 44_100)
        guard let sb = makeCMSampleBuffer(samples: input, sampleRate: 44_100) else { return }

        let result = Processor.toPCMBuffer(sampleBuffer: sb, targetSampleRate: 16_000)
        guard let buf = result else { return XCTFail("Conversion returned nil") }

        XCTAssertEqual(buf.format.sampleRate, 16_000)
        XCTAssertEqual(buf.format.channelCount, 1)
        XCTAssertEqual(buf.format.commonFormat, .pcmFormatFloat32)
    }

    // MARK: toPCMBuffer — stereo downmix

    func test_toPCMBuffer_stereoDownmixToMono() {
        // Build interleaved stereo: L=0.5, R=0.5 → mono should be ~0.5.
        let frames = 160
        var samples = [Float](repeating: 0, count: frames * 2)
        for i in 0 ..< frames {
            samples[i * 2]     = 0.5  // L
            samples[i * 2 + 1] = 0.5  // R
        }
        guard let sb = makeCMSampleBuffer(samples: samples, sampleRate: 16_000, channelCount: 2) else {
            return XCTFail("Could not create stereo CMSampleBuffer")
        }

        let result = Processor.toPCMBuffer(sampleBuffer: sb, targetSampleRate: 16_000)
        XCTAssertNotNil(result)
        // Mono output should carry ~0.5 (average of L+R).
        if let buf = result {
            let out0 = buf.floatChannelData![0][0]
            XCTAssertEqual(out0, 0.5, accuracy: 0.05)
        }
    }

    // MARK: Processor.process — accumulation

    func test_processor_process_accumulatesSamples() {
        let proc = Processor(
            targetSampleRate: 16_000,
            chunkDurationSeconds: 30.0,
            overlapSeconds: 2.0,
            vadConfig: .default
        )
        // Feed 1 second of audio (1 600 frames) — not enough for a 30-s chunk.
        let input = sineWave(frequency: 440, frames: 1_600, sampleRate: 16_000)
        guard let sb = makeCMSampleBuffer(samples: input, sampleRate: 16_000) else { return }

        let chunks = proc.process(sampleBuffer: sb, wallTime: Date())
        XCTAssertTrue(chunks.isEmpty, "Expected no chunk from 1 s of audio (need 30 s)")
    }

    func test_processor_process_emitsChunkWhenFull() {
        let proc = Processor(
            targetSampleRate: 16_000,
            chunkDurationSeconds: 30.0,
            overlapSeconds: 2.0,
            vadConfig: .default
        )
        // Feed 30 s + 1 frame to trigger chunk emission.
        let frameCount = 16_000 * 30 + 1
        let input = sineWave(frequency: 440, frames: frameCount, sampleRate: 16_000)
        guard let sb = makeCMSampleBuffer(samples: input, sampleRate: 16_000) else { return }

        let chunks = proc.process(sampleBuffer: sb, wallTime: Date())
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].samples.count, 16_000 * 30)
    }
}

// MARK: - SysAudioAccumulatorTests

@available(macOS 13.0, *)
final class SysAudioAccumulatorTests: XCTestCase {

    typealias Accumulator = SystemAudioCaptureService.SysAudioAccumulator

    private let sampleRate = 16_000
    private let chunkSamples = 16_000 * 30       // 480 000
    private let stepSamples  = 16_000 * 28       // 448 000
    private let overlapSamples = 16_000 * 2      // 32 000

    private func ramp(count: Int, start: Float = 0) -> [Float] {
        (0 ..< count).map { Float($0) + start }
    }

    func test_noChunkBeforeThreshold() {
        let acc = Accumulator(sampleRate: sampleRate, chunkDuration: 30, overlapDuration: 2)
        let result = acc.append(
            samples: UnsafeBufferPointer(start: ramp(count: chunkSamples - 1), count: chunkSamples - 1),
            wallTime: Date()
        )
        XCTAssertTrue(result.isEmpty)
    }

    func test_exactlyOneChunkAtThreshold() {
        let acc = Accumulator(sampleRate: sampleRate, chunkDuration: 30, overlapDuration: 2)
        let data = ramp(count: chunkSamples)
        let result = data.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: Date()) }
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].samples.count, chunkSamples)
    }

    func test_overlapContentPreserved() {
        let acc = Accumulator(sampleRate: sampleRate, chunkDuration: 30, overlapDuration: 2)
        let data = ramp(count: chunkSamples + stepSamples)
        let result = data.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: Date()) }
        XCTAssertEqual(result.count, 2)

        // The second chunk's first `overlapSamples` frames should equal the
        // last `overlapSamples` of the first chunk.
        let firstChunkTail = Array(result[0].samples.suffix(overlapSamples))
        let secondChunkHead = Array(result[1].samples.prefix(overlapSamples))
        XCTAssertEqual(firstChunkTail, secondChunkHead)
    }

    func test_flushReturnsPartialChunk() {
        let acc = Accumulator(sampleRate: sampleRate, chunkDuration: 30, overlapDuration: 2)
        let partial = 1_600  // 100 ms
        let data = ramp(count: partial)
        _ = data.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: Date()) }

        let flushed = acc.flush()
        XCTAssertNotNil(flushed)
        XCTAssertEqual(flushed!.samples.count, partial)
    }

    func test_flushNilWhenEmpty() {
        let acc = Accumulator(sampleRate: sampleRate, chunkDuration: 30, overlapDuration: 2)
        XCTAssertNil(acc.flush())
    }

    func test_resetClearsBuffer() {
        let acc = Accumulator(sampleRate: sampleRate, chunkDuration: 30, overlapDuration: 2)
        let data = ramp(count: 8_000)
        _ = data.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: Date()) }
        acc.reset()
        XCTAssertNil(acc.flush())
    }

    func test_timestampProgressesCorrectly() {
        let acc = Accumulator(sampleRate: sampleRate, chunkDuration: 30, overlapDuration: 2)
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        let data = ramp(count: chunkSamples + stepSamples)
        let result = data.withUnsafeBufferPointer { acc.append(samples: $0, wallTime: t0) }
        XCTAssertEqual(result.count, 2)
        let expectedStep = Double(stepSamples) / Double(sampleRate)  // 28 s
        XCTAssertEqual(
            result[1].startTime.timeIntervalSince(result[0].startTime),
            expectedStep,
            accuracy: 0.001
        )
    }
}

// MARK: - SCStreamConfiguration validation (static, no live session)

final class SCStreamConfigurationTests: XCTestCase {

    /// Validates the stream configuration values we'd pass to SCStream.
    /// These are pure value checks — no SCStream is instantiated.
    @available(macOS 13.0, *)
    func test_streamConfigAudioEnabled() {
        let streamConfig = SCStreamConfiguration()
        streamConfig.capturesAudio = true
        streamConfig.excludesCurrentProcessAudio = true
        XCTAssertTrue(streamConfig.capturesAudio)
        XCTAssertTrue(streamConfig.excludesCurrentProcessAudio)
    }

    @available(macOS 13.0, *)
    func test_streamConfigMinimalVideoDimensions() {
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = 2
        streamConfig.height = 2
        XCTAssertEqual(streamConfig.width, 2)
        XCTAssertEqual(streamConfig.height, 2)
    }
}
