// MicrophoneCaptureService.swift
// Kerwan — Capture layer
//
// Captures microphone audio via AVAudioEngine, converts to 16 kHz mono
// Float32 PCM, segments into 30-second overlapping chunks, applies VAD,
// and delivers qualifying chunks to an AudioChunkDelegate.
//
// Threading model
// ───────────────
// • Public API is @MainActor — safe to call from SwiftUI / AppState.
// • The AVAudioEngine tap fires on AVAudioEngine's private audio thread.
//   It enqueues work onto `processingQueue` (a serial DispatchQueue) with
//   ZERO main-actor captures — only Sendable values cross the boundary.
// • All audio math (conversion, accumulation, VAD) runs on processingQueue.
//   The `Processor` and `AudioAccumulator` classes are @unchecked Sendable
//   and are never touched from any thread other than processingQueue.
// • Completed chunks are delivered to the delegate by creating an
//   unstructured `Task { @MainActor in ... }` from processingQueue — this
//   hops to the MainActor without blocking the audio thread.
//
// macOS route change handling
// ───────────────────────────
// macOS does not expose AVAudioSession. AVAudioEngineConfigurationChange is
// posted by the engine when the hardware topology changes (AirPods, USB mic,
// built-in fallback). The engine is automatically stopped at that point;
// we recreate the converter and restart.

import AVFoundation
import Accelerate
import os

// MARK: - MicrophoneCaptureError

/// Errors specific to the microphone capture subsystem.
public enum MicrophoneCaptureError: Error, LocalizedError, Sendable {
    /// Microphone access was denied by the user.
    case permissionDenied
    /// No audio input device is currently connected.
    case noInputDevice
    /// `AVAudioEngine.start()` threw an error.
    case engineStartFailed(String)
    /// `AVAudioConverter` could not be created for the current hardware format.
    case converterSetupFailed(String)
    /// The operation is not valid in the current lifecycle state.
    case invalidState(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access denied — enable it in System Settings › Privacy & Security"
        case .noInputDevice:
            return "No audio input device is available"
        case .engineStartFailed(let reason):
            return "AVAudioEngine could not start: \(reason)"
        case .converterSetupFailed(let reason):
            return "Audio converter setup failed: \(reason)"
        case .invalidState(let reason):
            return "Invalid operation for current state: \(reason)"
        }
    }
}

// MARK: - MicrophoneCaptureService

/// Captures microphone audio and delivers 30-second VAD-filtered chunks.
///
/// ## Minimum setup
/// ```swift
/// let service = MicrophoneCaptureService(delegate: whisperActor)
/// try await service.start()
/// ```
///
/// ## Info.plist
/// The host app must include `NSMicrophoneUsageDescription`.
/// The sandbox entitlement `com.apple.security.device.audio-input` is also
/// required for Mac App Store distribution.
@MainActor
public final class MicrophoneCaptureService {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Sample rate for chunks delivered to the delegate. Default: 16 000 Hz.
        public var targetSampleRate: Double
        /// Duration of each audio chunk delivered to the delegate. Default: 30.0 s.
        public var chunkDurationSeconds: Double
        /// Overlap between consecutive chunks. Default: 2.0 s.
        /// Must be strictly less than `chunkDurationSeconds`.
        public var overlapSeconds: Double
        /// Requested tap buffer size in frames. Default: 4 096 (~93 ms at 44.1 kHz).
        public var tapBufferFrames: AVAudioFrameCount
        /// VAD settings applied to every chunk. Default: -40 dBFS, 3 s min speech.
        public var vadConfig: VoiceActivityDetector.Configuration

        public static let `default` = Configuration()

        public init(
            targetSampleRate: Double = 16_000,
            chunkDurationSeconds: Double = 30.0,
            overlapSeconds: Double = 2.0,
            tapBufferFrames: AVAudioFrameCount = 4_096,
            vadConfig: VoiceActivityDetector.Configuration = .default
        ) {
            precondition(overlapSeconds < chunkDurationSeconds,
                         "overlapSeconds must be less than chunkDurationSeconds")
            self.targetSampleRate = targetSampleRate
            self.chunkDurationSeconds = chunkDurationSeconds
            self.overlapSeconds = overlapSeconds
            self.tapBufferFrames = tapBufferFrames
            self.vadConfig = vadConfig
        }
    }

    // MARK: - Lifecycle state

    public enum State: Equatable, Sendable {
        case idle, running, paused, stopped
    }

    public private(set) var state: State = .idle

    // MARK: - Injectable environment

    /// Externally-observable side effects, replaceable for unit testing.
    public struct Environment: @unchecked Sendable {
        var requestPermission: @Sendable () async -> Bool
        var authorizationStatus: @Sendable () -> AVAuthorizationStatus

        public static let live = Environment(
            requestPermission: {
                await withCheckedContinuation { continuation in
                    AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
                }
            },
            authorizationStatus: {
                AVCaptureDevice.authorizationStatus(for: .audio)
            }
        )
    }

    // MARK: - Private: dependencies

    private let config: Configuration
    private let env: Environment
    private weak var delegate: (any AudioChunkDelegate)?
    private let log = Logger(subsystem: "com.kerwan.app", category: "MicrophoneCaptureService")

    // MARK: - Private: audio engine

    private let engine = AVAudioEngine()
    private var configChangeToken: NSObjectProtocol?

    // MARK: - Private: processing pipeline
    //
    // `processor` is a reference-type container whose sole purpose is to hold
    // all mutable audio-processing state.  It is @unchecked Sendable because
    // thread-safety is enforced by the serial `processingQueue`.
    // Never access any Processor property from any thread other than processingQueue.
    // Declared `internal` (not private) so @testable tests can inject synthetic samples.

    internal let processor: Processor
    private let processingQueue = DispatchQueue(
        label: "com.kerwan.app.audio.processing",
        qos: .userInitiated
    )

    // MARK: - Init / deinit

    /// Creates a `MicrophoneCaptureService`.
    ///
    /// - Parameters:
    ///   - delegate:    Actor that receives completed audio chunks.
    ///   - config:      Capture settings. Use `.default` for standard 30 s / 16 kHz.
    ///   - environment: Injectable side-effects. Use `.live` in production.
    public init(
        delegate: some AudioChunkDelegate,
        config: Configuration = .default,
        environment: Environment = .live
    ) {
        self.delegate = delegate
        self.config = config
        self.env = environment
        self.processor = Processor(
            targetSampleRate: Int(config.targetSampleRate),
            chunkDurationSeconds: config.chunkDurationSeconds,
            overlapSeconds: config.overlapSeconds,
            vadConfig: config.vadConfig
        )
    }

    deinit {
        if let token = configChangeToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Public API

    /// Requests microphone permission (if not yet granted) and begins capture.
    ///
    /// - Throws: `MicrophoneCaptureError.permissionDenied` when the user denies
    ///   access or has previously denied it in System Settings.
    /// - Throws: `MicrophoneCaptureError.noInputDevice` when no microphone is
    ///   connected.
    /// - Throws: `MicrophoneCaptureError.engineStartFailed` on AVAudioEngine failure.
    public func start() async throws {
        guard state == .idle || state == .stopped else {
            throw MicrophoneCaptureError.invalidState(
                "start() called from '\(state)'; must be .idle or .stopped")
        }

        try await ensurePermission()
        try setupConverterAndTap()
        do {
            try engine.start()
        } catch {
            throw MicrophoneCaptureError.engineStartFailed(error.localizedDescription)
        }

        state = .running
        observeEngineConfigChanges()
        log.info("Started — \(Int(config.targetSampleRate)) Hz mono Float32")
    }

    /// Pauses capture, preserving the current accumulation buffer.
    ///
    /// Call `resume()` to continue without losing buffered audio.
    /// Useful for device-sleep and private-mode transitions.
    public func pause() {
        guard state == .running else { return }
        engine.pause()
        state = .paused
        log.info("Paused")
    }

    /// Resumes a paused capture session.
    ///
    /// - Throws: `MicrophoneCaptureError.engineStartFailed` if the engine
    ///   cannot restart (e.g. the input device was removed while paused).
    public func resume() throws {
        guard state == .paused else { return }
        do {
            try engine.start()
        } catch {
            throw MicrophoneCaptureError.engineStartFailed(error.localizedDescription)
        }
        state = .running
        log.info("Resumed")
    }

    /// Stops capture and delivers any buffered audio as a partial chunk.
    ///
    /// The flushed chunk is always delivered regardless of VAD result.
    /// Callers should check `AudioChunk.containsSpeech` before transcribing.
    public func stop() async {
        guard state == .running || state == .paused else { return }
        state = .stopped

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        if let token = configChangeToken {
            NotificationCenter.default.removeObserver(token)
            configChangeToken = nil
        }

        // Drain the processing queue, then flush the accumulation buffer.
        let partial: AudioAccumulator.RawChunk? = await withCheckedContinuation { cont in
            processingQueue.async { [processor] in
                cont.resume(returning: processor.accumulator.flush())
            }
        }

        if let raw = partial {
            await finalize(raw, isFlush: true)
        }

        log.info("Stopped")
    }

    // MARK: - Private: permission

    private func ensurePermission() async throws {
        switch env.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            let granted = await env.requestPermission()
            guard granted else { throw MicrophoneCaptureError.permissionDenied }
        case .denied, .restricted:
            throw MicrophoneCaptureError.permissionDenied
        @unknown default:
            throw MicrophoneCaptureError.permissionDenied
        }
    }

    // MARK: - Private: converter + tap

    private func setupConverterAndTap() throws {
        let inputNode = engine.inputNode

        guard inputNode.inputFormat(forBus: 0).channelCount > 0 else {
            throw MicrophoneCaptureError.noInputDevice
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: config.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw MicrophoneCaptureError.converterSetupFailed("Cannot construct AVAudioFormat")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw MicrophoneCaptureError.converterSetupFailed(
                "AVAudioConverter rejected '\(inputFormat)' → '\(targetFormat)'")
        }

        // Pre-allocate the reusable output buffer (2× headroom for jitter).
        let ratio = config.targetSampleRate / max(inputFormat.sampleRate, 1)
        let capacity = AVAudioFrameCount((Double(config.tapBufferFrames) * ratio * 2).rounded(.up) + 512)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw MicrophoneCaptureError.converterSetupFailed("Cannot pre-allocate output PCM buffer")
        }

        // Install converter and reset accumulator before the tap starts firing.
        processingQueue.sync { [processor] in
            processor.setConverter(converter, outputBuffer: outputBuffer)
            processor.accumulator.reset()
        }

        installTap()
    }

    private func installTap() {
        // Build a @Sendable delivery closure that captures nothing from self
        // except a weak reference, accessed only on the MainActor via Task.
        //
        // The tap closure and the processingQueue.async closure below must NOT
        // close over `self` (a @MainActor type) from a non-isolated context.
        // Only Sendable values (proc, queue, deliverChunk) cross this boundary.
        let proc = processor       // Sendable (@unchecked)
        let queue = processingQueue  // DispatchQueue (Sendable)
        let deliverChunk = makeDeliveryCallback()  // @Sendable closure

        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: config.tapBufferFrames,
            format: nil  // native hardware format; we convert in Processor
        ) { buffer, _ in
            // ── Audio thread ─────────────────────────────────────────────────
            // Do the minimum here: capture wall time and dispatch.
            // All DSP happens on processingQueue.
            let wallTime = Date()
            queue.async {
                for raw in proc.process(buffer: buffer, wallTime: wallTime) {
                    deliverChunk(raw)
                }
            }
        }
    }

    /// Returns a @Sendable closure that dispatches a RawChunk to the delegate.
    /// The closure captures `self` weakly; access is mediated by MainActor.
    private func makeDeliveryCallback() -> @Sendable (AudioAccumulator.RawChunk) -> Void {
        // `self` is @MainActor and is implicitly Sendable; [weak self] in a
        // @Sendable closure is valid.
        return { [weak self] raw in
            Task { @MainActor [weak self] in
                await self?.finalize(raw, isFlush: false)
            }
        }
    }

    // MARK: - Private: chunk finalisation

    /// Applies VAD, builds an `AudioChunk`, and forwards to the delegate.
    private func finalize(_ raw: AudioAccumulator.RawChunk, isFlush: Bool) async {
        guard let delegate else { return }

        let vadResult = processor.vad.analyze(raw.samples)

        // Regular chunks are discarded when VAD finds no speech.
        // Flushed partial chunks are always delivered (delegate inspects containsSpeech).
        if !isFlush && !vadResult.containsSpeech {
            log.debug(
                "VAD discarded chunk: speechSecs=\(String(format: "%.1f", vadResult.speechSeconds))"
                + " maxDB=\(String(format: "%.1f", vadResult.maxEnergyDB))")
            return
        }

        let data = raw.samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let duration = Double(raw.samples.count) / config.targetSampleRate

        let chunk = AudioChunk(
            data: data,
            sampleRate: Int(config.targetSampleRate),
            startTime: raw.startTime,
            durationSeconds: duration,
            containsSpeech: vadResult.containsSpeech
        )

        await delegate.didCaptureAudioChunk(chunk)

        log.info(
            "Chunk delivered: duration=\(String(format: "%.1f", duration))s"
            + " speech=\(vadResult.containsSpeech)"
            + " speechSecs=\(String(format: "%.1f", vadResult.speechSeconds))"
            + " flush=\(isFlush)")
    }

    // MARK: - Private: route change (macOS)

    private func observeEngineConfigChanges() {
        // On macOS, AVAudioEngineConfigurationChange fires when the audio
        // hardware topology changes (route change equivalent on iOS).
        // The engine is automatically stopped before this notification fires.
        configChangeToken = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleEngineConfigChange()
            }
        }
    }

    private func handleEngineConfigChange() async {
        guard state == .running else { return }
        log.info("Engine configuration changed — restarting with new format")

        engine.inputNode.removeTap(onBus: 0)
        // Engine is already stopped by the time this notification fires.

        do {
            try setupConverterAndTap()
            try engine.start()
            log.info("Engine restarted after configuration change")
        } catch {
            log.error("Engine restart failed after configuration change: \(error.localizedDescription)")
            state = .stopped
        }
    }
}

// MARK: - Processor

extension MicrophoneCaptureService {

    /// Owns all mutable audio-processing state.
    ///
    /// All methods must be called from `processingQueue`.
    /// `@unchecked Sendable`: safety is guaranteed by serial-queue discipline.
    final class Processor: @unchecked Sendable {

        // MARK: Processing state

        private var converter: AVAudioConverter?
        /// Pre-allocated reusable output PCM buffer.
        private var outputBuffer: AVAudioPCMBuffer?

        let vad: VoiceActivityDetector
        let accumulator: AudioAccumulator

        // MARK: Init

        init(
            targetSampleRate: Int,
            chunkDurationSeconds: Double,
            overlapSeconds: Double,
            vadConfig: VoiceActivityDetector.Configuration
        ) {
            vad = VoiceActivityDetector(config: vadConfig, sampleRate: targetSampleRate)
            accumulator = AudioAccumulator(
                sampleRate: targetSampleRate,
                chunkDuration: chunkDurationSeconds,
                overlapDuration: overlapSeconds
            )
        }

        // MARK: Configuration

        /// Called once from the main actor before the processing queue is used.
        func setConverter(_ conv: AVAudioConverter, outputBuffer buf: AVAudioPCMBuffer) {
            converter = conv
            outputBuffer = buf
        }

        // MARK: Core processing (processingQueue only)

        /// Converts `buffer` to 16 kHz mono Float32, accumulates, and returns
        /// any completed chunks. The converter's internal filter state is
        /// preserved between calls — never recreate per buffer.
        func process(buffer: AVAudioPCMBuffer, wallTime: Date) -> [AudioAccumulator.RawChunk] {
            guard let converter, let outputBuffer else { return [] }

            // ── Sample-rate + channel conversion (AVAudioConverter) ───────────
            // Provide the input buffer once; signal noDataNow on subsequent calls.
            var inputConsumed = false
            var convError: NSError?

            let status = converter.convert(to: outputBuffer, error: &convError) { _, inputStatus in
                if inputConsumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                inputStatus.pointee = .haveData
                return buffer
            }

            // .haveData: conversion complete; .inputRanDry: input fully consumed
            // but output may be partially filled — both are valid.
            guard (status == .haveData || status == .inputRanDry), convError == nil else { return [] }

            let frameCount = Int(outputBuffer.frameLength)
            guard frameCount > 0,
                  let channelData = outputBuffer.floatChannelData
            else { return [] }

            let samples = UnsafeBufferPointer(start: channelData[0], count: frameCount)
            return accumulator.append(samples: samples, wallTime: wallTime)
        }
    }
}

// MARK: - AudioAccumulator

extension MicrophoneCaptureService {

    /// Accumulates Float32 samples and emits 30-second overlapping windows.
    ///
    /// All methods must be called from `processingQueue`.
    /// `@unchecked Sendable`: enforced by serial-queue discipline.
    final class AudioAccumulator: @unchecked Sendable {

        // MARK: Chunk type

        struct RawChunk: Sendable {
            /// Float32 PCM samples at the target sample rate.
            let samples: ContiguousArray<Float>
            /// Wall-clock time of the first sample in this chunk.
            let startTime: Date
        }

        // MARK: Configuration (immutable)

        let sampleRate: Int
        /// Total samples in one complete chunk (e.g. 480 000 = 30 s × 16 kHz).
        let chunkSamples: Int
        /// Samples to advance after each chunk (= chunkSamples − overlapSamples).
        /// E.g. 448 000 = 28 s × 16 kHz when overlap is 2 s.
        let stepSamples: Int

        // MARK: Mutable state

        private var buffer: ContiguousArray<Float>
        private var chunkStartTime: Date = Date()
        private var isFirstSample: Bool = true

        // MARK: Init

        init(sampleRate: Int, chunkDuration: Double, overlapDuration: Double) {
            precondition(overlapDuration < chunkDuration)
            self.sampleRate = sampleRate
            let chunkN = Int((Double(sampleRate) * chunkDuration).rounded())
            let overlapN = Int((Double(sampleRate) * overlapDuration).rounded())
            chunkSamples = chunkN
            stepSamples = chunkN - overlapN
            buffer = ContiguousArray()
            buffer.reserveCapacity(chunkN + overlapN)  // pre-allocate; no realloc expected
        }

        // MARK: API

        /// Appends `samples` and returns any newly-completed chunks.
        func append(samples: UnsafeBufferPointer<Float>, wallTime: Date) -> [RawChunk] {
            if isFirstSample {
                chunkStartTime = wallTime
                isFirstSample = false
            }
            buffer.append(contentsOf: samples)

            var chunks: [RawChunk] = []
            while buffer.count >= chunkSamples {
                chunks.append(RawChunk(
                    samples: ContiguousArray(buffer.prefix(chunkSamples)),
                    startTime: chunkStartTime
                ))
                // Drop the step samples, keeping the overlap at the front.
                // removeFirst(k) is O(buffer.count − k) = O(overlapSamples):
                // ~128 KB moved at 16 kHz / 2 s overlap — negligible at 30-s intervals.
                buffer.removeFirst(stepSamples)
                chunkStartTime = chunkStartTime.addingTimeInterval(
                    Double(stepSamples) / Double(sampleRate)
                )
            }
            return chunks
        }

        /// Returns whatever is in the buffer (for stop-flush) and clears it.
        func flush() -> RawChunk? {
            guard !buffer.isEmpty else { return nil }
            let chunk = RawChunk(samples: ContiguousArray(buffer), startTime: chunkStartTime)
            buffer.removeAll(keepingCapacity: true)
            isFirstSample = true
            return chunk
        }

        /// Discards all buffered audio (used when reconfiguring the engine).
        func reset() {
            buffer.removeAll(keepingCapacity: true)
            isFirstSample = true
        }
    }
}
