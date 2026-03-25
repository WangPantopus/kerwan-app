// AudioMixer.swift
// Kerwan — Capture layer
//
// Aligns AudioChunks from MicrophoneCaptureService and
// SystemAudioCaptureService by start timestamp (±100 ms tolerance),
// mixes them with 0.5 gain on each source, and delivers the result to
// a downstream AudioChunkDelegate (typically TranscriptionActor).
//
// Passthrough rules
// ─────────────────
// • If only one source is available, the chunk is forwarded as-is
//   (no gain reduction) without waiting for a pair.
// • A pending unpaired chunk is held for up to `alignmentTolerance`
//   seconds. If no matching chunk arrives in time (via the next call),
//   it is passed through directly.
//
// Threading model
// ───────────────
// AudioMixer is an actor — all state mutation is serialised by the
// actor executor.  Callers await `receive(mic:)` / `receive(system:)`
// from their respective actors; the mixer coalesces on its own executor.

import Foundation
import os

// MARK: - AudioMixer

/// Mixes aligned microphone and system audio chunks.
///
/// ```swift
/// let mixer = AudioMixer(delegate: transcriptionActor)
/// // wire up as delegate for both capture services' output:
/// await mixer.receive(mic: micChunk)
/// await mixer.receive(system: sysChunk)
/// ```
public actor AudioMixer {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Window within which two chunks are considered temporally aligned.
        /// Default: 0.1 s (100 ms).
        public var alignmentTolerance: TimeInterval
        /// Gain applied to each source when mixing. Default: 0.5.
        public var mixGain: Float

        public static let `default` = Configuration()

        public init(
            alignmentTolerance: TimeInterval = 0.1,
            mixGain: Float = 0.5
        ) {
            self.alignmentTolerance = alignmentTolerance
            self.mixGain = mixGain
        }
    }

    // MARK: - Private state

    private let config: Configuration
    private weak var delegate: (any AudioChunkDelegate)?
    private let log = Logger(subsystem: "com.kerwan.app", category: "AudioMixer")

    /// Pending mic chunk waiting for a system-audio match.
    private var pendingMic: AudioChunk?
    /// Pending system chunk waiting for a mic match.
    private var pendingSystem: AudioChunk?

    // MARK: - Init

    public init(
        delegate: some AudioChunkDelegate,
        config: Configuration = .default
    ) {
        self.delegate = delegate
        self.config = config
    }

    // MARK: - Public API

    /// Called when a microphone chunk is ready.
    public func receive(mic chunk: AudioChunk) async {
        await handleIncoming(chunk, source: .mic)
    }

    /// Called when a system audio chunk is ready.
    public func receive(system chunk: AudioChunk) async {
        await handleIncoming(chunk, source: .system)
    }

    // MARK: - Internal routing

    private enum Source { case mic, system }

    private func handleIncoming(_ chunk: AudioChunk, source: Source) async {
        switch source {
        case .mic:
            if let sys = pendingSystem, aligned(chunk, sys) {
                pendingSystem = nil
                await deliver(mix(chunk, sys))
            } else {
                // Flush stale pending system chunk as passthrough.
                if let stale = pendingSystem {
                    pendingSystem = nil
                    await deliver(stale)
                }
                // Flush stale pending mic chunk as passthrough.
                if let stale = pendingMic {
                    pendingMic = nil
                    await deliver(stale)
                }
                pendingMic = chunk
            }
        case .system:
            if let mic = pendingMic, aligned(mic, chunk) {
                pendingMic = nil
                await deliver(mix(mic, chunk))
            } else {
                // Flush stale pending system chunk as passthrough.
                if let stale = pendingSystem {
                    pendingSystem = nil
                    await deliver(stale)
                }
                // Flush stale pending mic chunk as passthrough.
                if let stale = pendingMic {
                    pendingMic = nil
                    await deliver(stale)
                }
                pendingSystem = chunk
            }
        }
    }

    // MARK: - Alignment check

    private func aligned(_ a: AudioChunk, _ b: AudioChunk) -> Bool {
        abs(a.startTime.timeIntervalSince(b.startTime)) <= config.alignmentTolerance
    }

    // MARK: - Mixing

    /// Returns a new `AudioChunk` whose samples are `gain×mic + gain×system`.
    ///
    /// The output length matches the shorter of the two inputs. Both sources
    /// are expected to be Float32 PCM at the same sample rate — callers
    /// (MicrophoneCaptureService + SystemAudioCaptureService) both output
    /// 16 kHz mono Float32, so no resampling is performed here.
    private func mix(_ mic: AudioChunk, _ system: AudioChunk) -> AudioChunk {
        let gain = config.mixGain
        let micSamples    = toFloatArray(mic.data)
        let systemSamples = toFloatArray(system.data)
        let count = min(micSamples.count, systemSamples.count)

        var out = [Float](repeating: 0, count: count)
        for i in 0 ..< count {
            out[i] = gain * micSamples[i] + gain * systemSamples[i]
        }

        let outData = out.withUnsafeBufferPointer { Data(buffer: $0) }
        let duration = Double(count) / Double(max(mic.sampleRate, 1))

        let containsSpeech = mic.containsSpeech || system.containsSpeech

        log.debug("Mixed chunk: mic=\(mic.id) sys=\(system.id) samples=\(count)")

        return AudioChunk(
            data: outData,
            sampleRate: mic.sampleRate,
            startTime: mic.startTime,
            durationSeconds: duration,
            containsSpeech: containsSpeech
        )
    }

    // MARK: - Delivery

    private func deliver(_ chunk: AudioChunk) async {
        guard let delegate else { return }
        await delegate.didCaptureAudioChunk(chunk)
    }

    // MARK: - Helpers

    private func toFloatArray(_ data: Data) -> [Float] {
        data.withUnsafeBytes { ptr -> [Float] in
            guard let base = ptr.baseAddress else { return [] }
            let count = ptr.count / MemoryLayout<Float>.size
            return Array(UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: Float.self),
                count: count
            ))
        }
    }
}

// MARK: - AudioMixerDelegate convenience wrappers

/// Thin `AudioChunkDelegate` adapters so capture services can send chunks
/// directly to an `AudioMixer` without needing actor-hop boilerplate at the
/// call site.
///
/// Usage:
/// ```swift
/// let mixer = AudioMixer(delegate: transcriptionActor)
/// let micAdapter  = MicAudioMixerAdapter(mixer: mixer)
/// let sysAdapter  = SysAudioMixerAdapter(mixer: mixer)
///
/// let mic = MicrophoneCaptureService(delegate: micAdapter)
/// let sys = SystemAudioCaptureService(delegate: sysAdapter)
/// ```

public actor MicAudioMixerAdapter: AudioChunkDelegate {
    private let mixer: AudioMixer
    public init(mixer: AudioMixer) { self.mixer = mixer }

    public func didCaptureAudioChunk(_ chunk: AudioChunk) async {
        await mixer.receive(mic: chunk)
    }
}

public actor SysAudioMixerAdapter: AudioChunkDelegate {
    private let mixer: AudioMixer
    public init(mixer: AudioMixer) { self.mixer = mixer }

    public func didCaptureAudioChunk(_ chunk: AudioChunk) async {
        await mixer.receive(system: chunk)
    }
}
