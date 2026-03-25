// SystemAudioCaptureService.swift
// Kerwan — Capture layer
//
// Captures system audio via ScreenCaptureKit (macOS 13+), converts to
// 16 kHz mono Float32 PCM, segments into 30-second overlapping chunks,
// applies VAD, and delivers qualifying chunks to an AudioChunkDelegate.
//
// Threading model
// ───────────────
// • Public API is @MainActor.
// • SCStreamOutput callbacks fire on an arbitrary background thread.
//   They enqueue work onto `processingQueue` (serial DispatchQueue).
//   Only Sendable values cross the boundary — NO self captures.
// • All DSP (CMSampleBuffer→PCM conversion, accumulation, VAD) runs on
//   processingQueue. The Processor is @unchecked Sendable; thread-safety
//   is enforced by the serial queue.
// • Completed chunks hop to the MainActor via Task { @MainActor in … }.
//
// macOS 13+ requirement
// ─────────────────────
// ScreenCaptureKit requires macOS 13. On earlier OS versions, `start()`
// logs a warning and returns immediately without throwing, so callers
// need not `#available`-guard every call site.

import AVFoundation
import CoreMedia
import os
import ScreenCaptureKit

// MARK: - SystemAudioCaptureError

public enum SystemAudioCaptureError: Error, LocalizedError, Sendable {
    /// The user denied screen-recording permission (which gates audio capture).
    case permissionDenied
    /// `SCShareableContent.current` found no audio-capable displays.
    case noCapturableContent
    /// `SCStream.startCapture()` threw an error.
    case streamStartFailed(String)
    /// `CMSampleBuffer` could not be converted to an `AVAudioPCMBuffer`.
    case conversionFailed(String)
    /// The operation is not valid in the current lifecycle state.
    case invalidState(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen-recording permission required for system audio — enable in System Settings › Privacy & Security"
        case .noCapturableContent:
            return "No capturable audio source found"
        case .streamStartFailed(let reason):
            return "SCStream could not start: \(reason)"
        case .conversionFailed(let reason):
            return "CMSampleBuffer conversion failed: \(reason)"
        case .invalidState(let reason):
            return "Invalid operation for current state: \(reason)"
        }
    }
}

// MARK: - SystemAudioCaptureService

/// Captures system audio and delivers 30-second VAD-filtered chunks.
///
/// ## Minimum setup
/// ```swift
/// let service = SystemAudioCaptureService(delegate: whisperActor)
/// try await service.start()
/// ```
///
/// ## Entitlements
/// `com.apple.security.screen-capture` is required for App Store distribution.
@available(macOS 13.0, *)
@MainActor
public final class SystemAudioCaptureService {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Sample rate for delivered chunks. Default: 16 000 Hz.
        public var targetSampleRate: Double
        /// Duration of each audio chunk. Default: 30.0 s.
        public var chunkDurationSeconds: Double
        /// Overlap between consecutive chunks. Default: 2.0 s.
        public var overlapSeconds: Double
        /// VAD settings applied to every chunk.
        public var vadConfig: VoiceActivityDetector.Configuration

        public static let `default` = Configuration()

        public init(
            targetSampleRate: Double = 16_000,
            chunkDurationSeconds: Double = 30.0,
            overlapSeconds: Double = 2.0,
            vadConfig: VoiceActivityDetector.Configuration = .default
        ) {
            precondition(overlapSeconds < chunkDurationSeconds,
                         "overlapSeconds must be less than chunkDurationSeconds")
            self.targetSampleRate = targetSampleRate
            self.chunkDurationSeconds = chunkDurationSeconds
            self.overlapSeconds = overlapSeconds
            self.vadConfig = vadConfig
        }
    }

    // MARK: - Lifecycle state

    public enum State: Equatable, Sendable {
        case idle, running, paused, stopped
    }

    public private(set) var state: State = .idle

    // MARK: - Private: dependencies

    private let config: Configuration
    private weak var delegate: (any AudioChunkDelegate)?
    private let log = Logger(subsystem: "com.kerwan.app", category: "SystemAudioCaptureService")

    // MARK: - Private: SCStream

    private var stream: SCStream?

    // MARK: - Private: processing pipeline

    internal let processor: Processor
    private let processingQueue = DispatchQueue(
        label: "com.kerwan.app.sysaudio.processing",
        qos: .userInitiated
    )

    // MARK: - Init

    public init(
        delegate: some AudioChunkDelegate,
        config: Configuration = .default
    ) {
        self.delegate = delegate
        self.config = config
        self.processor = Processor(
            targetSampleRate: Int(config.targetSampleRate),
            chunkDurationSeconds: config.chunkDurationSeconds,
            overlapSeconds: config.overlapSeconds,
            vadConfig: config.vadConfig
        )
    }

    // MARK: - Public API

    /// Requests screen-recording permission, configures an audio-only SCStream,
    /// and begins system audio capture.
    public func start() async throws {
        guard state == .idle || state == .stopped else {
            throw SystemAudioCaptureError.invalidState(
                "start() called from '\(state)'; must be .idle or .stopped")
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            // SCShareableContent throws when permission is denied.
            if (error as NSError).domain == "com.apple.ScreenCaptureKit" {
                throw SystemAudioCaptureError.permissionDenied
            }
            throw SystemAudioCaptureError.permissionDenied
        }

        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noCapturableContent
        }

        // Audio-only filter: include the display but exclude all windows/apps
        // from the visual channel — SCStreamConfiguration will disable video.
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let streamConfig = SCStreamConfiguration()
        // Disable video entirely — we only need audio.
        streamConfig.capturesAudio = true
        streamConfig.excludesCurrentProcessAudio = true
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1) // irrelevant; video off
        streamConfig.width = 2   // minimum: SCKit requires non-zero dimensions
        streamConfig.height = 2
        // Note: SCStreamConfiguration does not expose sampleRate / channelCount
        // directly in public API through macOS 14. The SCStream delivers audio
        // at the system's native rate; we resample in the Processor.

        let scStream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)

        let outputHandler = StreamOutput(
            processor: processor,
            processingQueue: processingQueue,
            deliverChunk: makeDeliveryCallback()
        )

        do {
            try scStream.addStreamOutput(outputHandler, type: .audio, sampleHandlerQueue: processingQueue)
        } catch {
            throw SystemAudioCaptureError.streamStartFailed("addStreamOutput: \(error.localizedDescription)")
        }

        do {
            try await scStream.startCapture()
        } catch {
            throw SystemAudioCaptureError.streamStartFailed(error.localizedDescription)
        }

        stream = scStream
        state = .running
        processingQueue.sync { [processor] in processor.accumulator.reset() }
        log.info("Started system audio capture")
    }

    /// Pauses delivery without stopping the stream.
    public func pause() {
        guard state == .running else { return }
        state = .paused
        log.info("Paused")
    }

    /// Resumes a paused capture session.
    public func resume() {
        guard state == .paused else { return }
        state = .running
        log.info("Resumed")
    }

    /// Stops the SCStream and delivers any buffered audio as a partial chunk.
    public func stop() async {
        guard state == .running || state == .paused else { return }
        state = .stopped

        if let scStream = stream {
            try? await scStream.stopCapture()
            stream = nil
        }

        let partial: SysAudioAccumulator.RawChunk? = await withCheckedContinuation { cont in
            processingQueue.async { [processor] in
                cont.resume(returning: processor.accumulator.flush())
            }
        }

        if let raw = partial {
            await finalize(raw, isFlush: true)
        }

        log.info("Stopped")
    }

    // MARK: - Private: chunk finalisation

    private func finalize(_ raw: SysAudioAccumulator.RawChunk, isFlush: Bool) async {
        guard let delegate else { return }

        let vadResult = processor.vad.analyze(raw.samples)

        if !isFlush && !vadResult.containsSpeech {
            log.debug("VAD discarded chunk: speechSecs=\(String(format: "%.1f", vadResult.speechSeconds))")
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

        log.info("Chunk delivered: duration=\(String(format: "%.1f", duration))s speech=\(vadResult.containsSpeech) flush=\(isFlush)")
    }

    // MARK: - Private: delivery callback

    private func makeDeliveryCallback() -> @Sendable (SysAudioAccumulator.RawChunk) -> Void {
        return { [weak self] raw in
            Task { @MainActor [weak self] in
                await self?.finalize(raw, isFlush: false)
            }
        }
    }
}

// MARK: - StreamOutput (SCStreamOutput)

@available(macOS 13.0, *)
extension SystemAudioCaptureService {

    /// Receives SCStream audio callbacks and routes them to the Processor.
    ///
    /// This is a plain class (not an actor or @MainActor) because SCKit
    /// delivers callbacks on the sampleHandlerQueue we provide.
    /// All state access is mediated by the serial processingQueue.
    final class StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {

        private let processor: Processor
        private let processingQueue: DispatchQueue
        private let deliverChunk: @Sendable (SysAudioAccumulator.RawChunk) -> Void

        init(
            processor: Processor,
            processingQueue: DispatchQueue,
            deliverChunk: @escaping @Sendable (SysAudioAccumulator.RawChunk) -> Void
        ) {
            self.processor = processor
            self.processingQueue = processingQueue
            self.deliverChunk = deliverChunk
        }

        func stream(
            _ stream: SCStream,
            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of outputType: SCStreamOutputType
        ) {
            guard outputType == .audio else { return }
            let wallTime = Date()
            // processingQueue is our sampleHandlerQueue, so we're already on it.
            for raw in processor.process(sampleBuffer: sampleBuffer, wallTime: wallTime) {
                deliverChunk(raw)
            }
        }
    }
}

// MARK: - Processor

@available(macOS 13.0, *)
extension SystemAudioCaptureService {

    /// Owns all mutable audio-processing state for system audio.
    ///
    /// All methods must be called from `processingQueue`.
    final class Processor: @unchecked Sendable {

        let vad: VoiceActivityDetector
        let accumulator: SysAudioAccumulator

        private let targetSampleRate: Int

        init(
            targetSampleRate: Int,
            chunkDurationSeconds: Double,
            overlapSeconds: Double,
            vadConfig: VoiceActivityDetector.Configuration
        ) {
            self.targetSampleRate = targetSampleRate
            vad = VoiceActivityDetector(config: vadConfig, sampleRate: targetSampleRate)
            accumulator = SysAudioAccumulator(
                sampleRate: targetSampleRate,
                chunkDuration: chunkDurationSeconds,
                overlapDuration: overlapSeconds
            )
        }

        /// Converts `sampleBuffer` to Float32 mono at `targetSampleRate` and
        /// accumulates, returning any completed chunks.
        func process(sampleBuffer: CMSampleBuffer, wallTime: Date) -> [SysAudioAccumulator.RawChunk] {
            guard let pcmBuffer = Self.toPCMBuffer(sampleBuffer: sampleBuffer,
                                                   targetSampleRate: targetSampleRate) else {
                return []
            }

            let frameCount = Int(pcmBuffer.frameLength)
            guard frameCount > 0, let channelData = pcmBuffer.floatChannelData else { return [] }

            let samples = UnsafeBufferPointer(start: channelData[0], count: frameCount)
            return accumulator.append(samples: samples, wallTime: wallTime)
        }

        // MARK: CMSampleBuffer → AVAudioPCMBuffer

        /// Converts a `CMSampleBuffer` carrying audio data to a mono Float32
        /// `AVAudioPCMBuffer` at `targetSampleRate`.
        ///
        /// Returns `nil` if the buffer lacks audio, the format cannot be read,
        /// or the AVAudioConverter fails.
        static func toPCMBuffer(
            sampleBuffer: CMSampleBuffer,
            targetSampleRate: Int
        ) -> AVAudioPCMBuffer? {
            // 1. Extract the format description.
            guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
                  CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) != nil
            else { return nil }

            // 2. Wrap in AVAudioFormat.
            let sourceFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)

            // 3. Build the target format: Float32, mono, targetSampleRate.
            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(targetSampleRate),
                channels: 1,
                interleaved: false
            ) else { return nil }

            // 4. Build an AVAudioPCMBuffer from the CMSampleBuffer.
            let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frameCount > 0 else { return nil }

            guard let sourcePCM = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            ) else { return nil }

            sourcePCM.frameLength = AVAudioFrameCount(frameCount)

            // Copy audio data from CMSampleBuffer into the AVAudioPCMBuffer.
            // Allocate an AudioBufferList large enough to hold all source channels.
            let numChannels = Int(sourceFormat.channelCount)
            let ablAlloc = AudioBufferList.allocate(maximumBuffers: numChannels)
            defer { ablAlloc.unsafePointer.deallocate() }

            var blockBuffer: CMBlockBuffer?
            let copyStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: ablAlloc.unsafeMutablePointer,
                bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: numChannels),
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &blockBuffer
            )
            guard copyStatus == noErr else { return nil }

            // Copy the audio buffer list data into the PCM buffer.
            let ablPointer = ablAlloc
            guard let channelData = sourcePCM.floatChannelData else { return nil }

            // Handle interleaved vs non-interleaved source formats.
            if sourceFormat.isInterleaved {
                let channelCount = Int(sourceFormat.channelCount)
                if let srcBuffer = ablPointer.first,
                   let srcData = srcBuffer.mData {
                    let srcPtr = srcData.assumingMemoryBound(to: Float.self)
                    // Downmix to mono by averaging channels.
                    for frame in 0 ..< frameCount {
                        var sum: Float = 0
                        for ch in 0 ..< channelCount {
                            sum += srcPtr[frame * channelCount + ch]
                        }
                        channelData[0][frame] = sum / Float(channelCount)
                    }
                }
            } else {
                // Non-interleaved: each ABL buffer is one channel.
                let channelCount = min(Int(ablPointer.count), Int(sourceFormat.channelCount))
                if channelCount == 1 {
                    if let srcData = ablPointer[0].mData {
                        let srcPtr = srcData.assumingMemoryBound(to: Float.self)
                        channelData[0].update(from: srcPtr, count: frameCount)
                    }
                } else {
                    // Downmix to mono.
                    for frame in 0 ..< frameCount {
                        var sum: Float = 0
                        for ch in 0 ..< channelCount {
                            if let srcData = ablPointer[ch].mData {
                                sum += srcData.assumingMemoryBound(to: Float.self)[frame]
                            }
                        }
                        channelData[0][frame] = sum / Float(channelCount)
                    }
                }
            }

            // 5. If source and target rates differ, resample via AVAudioConverter.
            if sourceFormat.sampleRate == Double(targetSampleRate) && sourceFormat.channelCount == 1 {
                return sourcePCM
            }

            guard let converter = AVAudioConverter(from: sourcePCM.format, to: targetFormat) else {
                return nil
            }

            let outputFrameCapacity = AVAudioFrameCount(
                (Double(frameCount) * Double(targetSampleRate) / sourceFormat.sampleRate * 2).rounded(.up) + 512
            )
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputFrameCapacity
            ) else { return nil }

            var inputConsumed = false
            var convError: NSError?
            let status = converter.convert(to: outputBuffer, error: &convError) { _, inputStatus in
                if inputConsumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                inputStatus.pointee = .haveData
                return sourcePCM
            }

            guard (status == .haveData || status == .inputRanDry), convError == nil else { return nil }
            return outputBuffer
        }
    }
}

// MARK: - SysAudioAccumulator

@available(macOS 13.0, *)
extension SystemAudioCaptureService {

    /// Accumulates Float32 samples and emits 30-second overlapping windows.
    /// Identical semantics to `MicrophoneCaptureService.AudioAccumulator`.
    final class SysAudioAccumulator: @unchecked Sendable {

        struct RawChunk: Sendable {
            let samples: ContiguousArray<Float>
            let startTime: Date
        }

        let sampleRate: Int
        let chunkSamples: Int
        let stepSamples: Int

        private var buffer: ContiguousArray<Float>
        private var chunkStartTime: Date = Date()
        private var isFirstSample: Bool = true

        init(sampleRate: Int, chunkDuration: Double, overlapDuration: Double) {
            precondition(overlapDuration < chunkDuration)
            self.sampleRate = sampleRate
            let chunkN = Int((Double(sampleRate) * chunkDuration).rounded())
            let overlapN = Int((Double(sampleRate) * overlapDuration).rounded())
            chunkSamples = chunkN
            stepSamples = chunkN - overlapN
            buffer = ContiguousArray()
            buffer.reserveCapacity(chunkN + overlapN)
        }

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
                buffer.removeFirst(stepSamples)
                chunkStartTime = chunkStartTime.addingTimeInterval(
                    Double(stepSamples) / Double(sampleRate)
                )
            }
            return chunks
        }

        func flush() -> RawChunk? {
            guard !buffer.isEmpty else { return nil }
            let chunk = RawChunk(samples: ContiguousArray(buffer), startTime: chunkStartTime)
            buffer.removeAll(keepingCapacity: true)
            isFirstSample = true
            return chunk
        }

        func reset() {
            buffer.removeAll(keepingCapacity: true)
            isFirstSample = true
        }
    }
}
