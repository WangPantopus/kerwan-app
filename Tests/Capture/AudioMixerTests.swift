// AudioMixerTests.swift
// Tests for AudioMixer: timestamp alignment, sample mixing (0.5 gain),
// passthrough for single-source chunks, and stale-chunk flushing.

import XCTest

@testable import Kerwan

// MARK: - MockMixerDelegate

actor MockMixerDelegate: AudioChunkDelegate {
    private(set) var received: [AudioChunk] = []

    func didCaptureAudioChunk(_ chunk: AudioChunk) async {
        received.append(chunk)
    }

    func reset() { received = [] }
}

// MARK: - Helpers

private func makeChunk(
    samples: [Float],
    startTime: Date,
    sampleRate: Int = 16_000,
    containsSpeech: Bool = true
) -> AudioChunk {
    let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    return AudioChunk(
        data: data,
        sampleRate: sampleRate,
        startTime: startTime,
        durationSeconds: Double(samples.count) / Double(sampleRate),
        containsSpeech: containsSpeech
    )
}

private func samples(from chunk: AudioChunk) -> [Float] {
    chunk.data.withUnsafeBytes { ptr -> [Float] in
        guard let base = ptr.baseAddress else { return [] }
        let count = ptr.count / MemoryLayout<Float>.size
        return Array(UnsafeBufferPointer(
            start: base.assumingMemoryBound(to: Float.self),
            count: count
        ))
    }
}

// MARK: - AudioMixerTests

final class AudioMixerTests: XCTestCase {

    private var delegate: MockMixerDelegate!
    private var mixer: AudioMixer!

    override func setUp() async throws {
        delegate = MockMixerDelegate()
        mixer = AudioMixer(delegate: delegate)
    }

    // MARK: - Mixing

    func test_aligned_mic_and_system_areHalfGainMixed() async {
        let t = Date(timeIntervalSinceReferenceDate: 1_000)
        let micSamples: [Float] = [1.0, 1.0, 1.0, 1.0]
        let sysSamples: [Float] = [1.0, 1.0, 1.0, 1.0]

        let mic = makeChunk(samples: micSamples, startTime: t)
        let sys = makeChunk(samples: sysSamples, startTime: t)

        await mixer.receive(mic: mic)
        await mixer.receive(system: sys)

        let received = await delegate.received
        XCTAssertEqual(received.count, 1)
        let out = samples(from: received[0])
        // 0.5 × 1.0 + 0.5 × 1.0 = 1.0
        XCTAssertEqual(out, [Float](repeating: 1.0, count: 4))
    }

    func test_mixing_preserves_sample_count_of_shorter_input() async {
        let t = Date(timeIntervalSinceReferenceDate: 1_000)
        let mic = makeChunk(samples: [Float](repeating: 0.4, count: 100), startTime: t)
        let sys = makeChunk(samples: [Float](repeating: 0.6, count: 80),  startTime: t)

        await mixer.receive(mic: mic)
        await mixer.receive(system: sys)

        let received = await delegate.received
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].sampleCount, 80)
    }

    func test_mixing_gain_values() async {
        let t = Date(timeIntervalSinceReferenceDate: 1_000)
        let mic = makeChunk(samples: [0.8],  startTime: t)
        let sys = makeChunk(samples: [0.4],  startTime: t)

        await mixer.receive(mic: mic)
        await mixer.receive(system: sys)

        let received = await delegate.received
        let out = samples(from: received[0])
        // 0.5 × 0.8 + 0.5 × 0.4 = 0.6
        XCTAssertEqual(out[0], 0.6, accuracy: 1e-5)
    }

    // MARK: - containsSpeech propagation

    func test_mixedChunk_containsSpeech_isOr() async {
        let t = Date(timeIntervalSinceReferenceDate: 1_000)
        let mic = makeChunk(samples: [0.0], startTime: t, containsSpeech: false)
        let sys = makeChunk(samples: [0.0], startTime: t, containsSpeech: true)

        await mixer.receive(mic: mic)
        await mixer.receive(system: sys)

        let received = await delegate.received
        XCTAssertTrue(received[0].containsSpeech)
    }

    func test_mixedChunk_bothSilent_notSpeech() async {
        let t = Date(timeIntervalSinceReferenceDate: 1_000)
        let mic = makeChunk(samples: [0.0], startTime: t, containsSpeech: false)
        let sys = makeChunk(samples: [0.0], startTime: t, containsSpeech: false)

        await mixer.receive(mic: mic)
        await mixer.receive(system: sys)

        let received = await delegate.received
        XCTAssertFalse(received[0].containsSpeech)
    }

    // MARK: - Alignment tolerance

    func test_chunks_within_tolerance_are_mixed() async {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        let t1 = t0.addingTimeInterval(0.099)  // 99 ms < 100 ms tolerance

        let mic = makeChunk(samples: [Float](repeating: 1.0, count: 4), startTime: t0)
        let sys = makeChunk(samples: [Float](repeating: 1.0, count: 4), startTime: t1)

        await mixer.receive(mic: mic)
        await mixer.receive(system: sys)

        let received = await delegate.received
        XCTAssertEqual(received.count, 1)
    }

    func test_chunks_outside_tolerance_passThroughSeparately() async {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        let t1 = t0.addingTimeInterval(0.200)  // 200 ms > 100 ms tolerance

        let mic = makeChunk(samples: [Float](repeating: 1.0, count: 4), startTime: t0)
        let sys = makeChunk(samples: [Float](repeating: 0.5, count: 4), startTime: t1)

        // First: mic arrives, no match yet.
        await mixer.receive(mic: mic)
        // Then: system arrives 200 ms later → mic is stale, flushed as passthrough.
        // sys is then stored as pending.
        await mixer.receive(system: sys)

        let received = await delegate.received
        XCTAssertEqual(received.count, 1, "Stale mic chunk should be flushed")
        // Flushed chunk should be mic, passed through at full gain.
        let out = samples(from: received[0])
        XCTAssertEqual(out, [Float](repeating: 1.0, count: 4))
    }

    // MARK: - Passthrough (single source)

    func test_mic_only_passthrough_no_gain_reduction() async {
        let t = Date(timeIntervalSinceReferenceDate: 1_000)
        let micSamples: [Float] = [0.3, 0.6, 0.9, 0.1]
        let mic = makeChunk(samples: micSamples, startTime: t)

        // Send two consecutive mic chunks without any system audio.
        await mixer.receive(mic: mic)
        let t2 = t.addingTimeInterval(30)
        let mic2 = makeChunk(samples: micSamples, startTime: t2)
        // The second mic chunk is 30 s later — first pending mic is stale and flushed.
        await mixer.receive(mic: mic2)

        let received = await delegate.received
        XCTAssertGreaterThanOrEqual(received.count, 1)
        // First delivered chunk must be the passthrough mic (samples unchanged).
        let out = samples(from: received[0])
        XCTAssertEqual(out, micSamples)
    }

    func test_system_only_passthrough() async {
        let t = Date(timeIntervalSinceReferenceDate: 1_000)
        let sysSamples: [Float] = [0.1, 0.2, 0.3]
        let sys = makeChunk(samples: sysSamples, startTime: t)

        // Two system chunks 30 s apart — first is stale, flushed as passthrough.
        await mixer.receive(system: sys)
        let sys2 = makeChunk(samples: sysSamples, startTime: t.addingTimeInterval(30))
        await mixer.receive(system: sys2)

        let received = await delegate.received
        XCTAssertGreaterThanOrEqual(received.count, 1)
        let out = samples(from: received[0])
        XCTAssertEqual(out, sysSamples)
    }

    // MARK: - Order independence

    func test_system_before_mic_still_mixes() async {
        let t = Date(timeIntervalSinceReferenceDate: 2_000)
        let mic = makeChunk(samples: [1.0, 0.0], startTime: t)
        let sys = makeChunk(samples: [0.0, 1.0], startTime: t)

        await mixer.receive(system: sys)
        await mixer.receive(mic: mic)

        let received = await delegate.received
        XCTAssertEqual(received.count, 1)
        let out = samples(from: received[0])
        // 0.5×1.0 + 0.5×0.0 = 0.5 ; 0.5×0.0 + 0.5×1.0 = 0.5
        XCTAssertEqual(out[0], 0.5, accuracy: 1e-5)
        XCTAssertEqual(out[1], 0.5, accuracy: 1e-5)
    }

    // MARK: - startTime uses mic startTime

    func test_mixedChunk_usesFirstChunkStartTime() async {
        let t0 = Date(timeIntervalSinceReferenceDate: 3_000)
        let t1 = t0.addingTimeInterval(0.05)  // 50 ms offset, within tolerance

        let mic = makeChunk(samples: [0.5], startTime: t0)
        let sys = makeChunk(samples: [0.5], startTime: t1)

        await mixer.receive(mic: mic)
        await mixer.receive(system: sys)

        let received = await delegate.received
        XCTAssertEqual(received[0].startTime, t0)
    }

    // MARK: - Custom configuration

    func test_customGain_appliedCorrectly() async {
        let customConfig = AudioMixer.Configuration(alignmentTolerance: 0.1, mixGain: 0.25)
        let del = MockMixerDelegate()
        let customMixer = AudioMixer(delegate: del, config: customConfig)

        let t = Date(timeIntervalSinceReferenceDate: 4_000)
        let mic = makeChunk(samples: [1.0], startTime: t)
        let sys = makeChunk(samples: [1.0], startTime: t)

        await customMixer.receive(mic: mic)
        await customMixer.receive(system: sys)

        let received = await del.received
        let out = samples(from: received[0])
        // 0.25 × 1.0 + 0.25 × 1.0 = 0.5
        XCTAssertEqual(out[0], 0.5, accuracy: 1e-5)
    }

    func test_customAlignmentTolerance_rejectsAtEdge() async {
        let narrowConfig = AudioMixer.Configuration(alignmentTolerance: 0.05, mixGain: 0.5)
        let del = MockMixerDelegate()
        let narrowMixer = AudioMixer(delegate: del, config: narrowConfig)

        let t0 = Date(timeIntervalSinceReferenceDate: 5_000)
        let t1 = t0.addingTimeInterval(0.06)  // 60 ms > 50 ms → outside tolerance

        let mic = makeChunk(samples: [1.0, 1.0], startTime: t0)
        let sys = makeChunk(samples: [0.5, 0.5], startTime: t1)

        await narrowMixer.receive(mic: mic)
        await narrowMixer.receive(system: sys)

        let received = await del.received
        // mic flushed as passthrough, sys is still pending
        XCTAssertEqual(received.count, 1)
        let out = samples(from: received[0])
        XCTAssertEqual(out, [1.0, 1.0])
    }
}

// MARK: - MicAudioMixerAdapterTests

final class MicAudioMixerAdapterTests: XCTestCase {

    func test_adapter_forwardsMicChunkToMixer() async {
        let del = MockMixerDelegate()
        let mixer = AudioMixer(delegate: del)
        let adapter = MicAudioMixerAdapter(mixer: mixer)

        let t = Date(timeIntervalSinceReferenceDate: 6_000)
        let mic = makeChunk(samples: [Float](repeating: 0.5, count: 4), startTime: t)
        let sys = makeChunk(samples: [Float](repeating: 0.5, count: 4), startTime: t)

        // Deliver via adapter.
        await adapter.didCaptureAudioChunk(mic)
        // Deliver system directly.
        await mixer.receive(system: sys)

        let received = await del.received
        XCTAssertEqual(received.count, 1)
    }

    func test_sysAdapter_forwardsSystemChunkToMixer() async {
        let del = MockMixerDelegate()
        let mixer = AudioMixer(delegate: del)
        let adapter = SysAudioMixerAdapter(mixer: mixer)

        let t = Date(timeIntervalSinceReferenceDate: 7_000)
        let mic = makeChunk(samples: [Float](repeating: 0.5, count: 4), startTime: t)
        let sys = makeChunk(samples: [Float](repeating: 0.5, count: 4), startTime: t)

        await mixer.receive(mic: mic)
        await adapter.didCaptureAudioChunk(sys)

        let received = await del.received
        XCTAssertEqual(received.count, 1)
    }
}
