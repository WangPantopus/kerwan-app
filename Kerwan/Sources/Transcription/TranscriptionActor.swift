// TranscriptionActor.swift
// Kerwan — Transcription layer
//
// Central coordinator of the audio → transcript → RawEvent pipeline.
//
// Data flow
// ─────────
//   AudioMixer
//     └─► TranscriptionActor.didCaptureAudioChunk(_:)   [AudioChunkDelegate]
//           ├─ enqueue / spool to disk
//           └─ processLoop()
//                 ├─ WhisperTranscribing.transcribe(...)
//                 ├─ SpeakingSession.addChunkSegments(...)   (dedup, assembly)
//                 ├─ RawEvent emitted on session boundary / stop
//                 ├─ CaptureEventDelegate (RawEventBuffer)
//                 └─ CaptureEventDelegate? (ClassificationActor)
//
// Queue / backpressure
// ────────────────────
// • In-memory queue: up to `config.maxQueueDepth` (default 10) chunks.
// • Overflow: chunks are spooled to disk as IEEE-float WAV files in
//   ~/Library/Application Support/Kerwan/AudioQueue/.
// • When in-memory queue drops below `config.queueDrainThreshold` (default 5)
//   and spooled files exist, they are reloaded in chronological order.
//
// Processing loop
// ───────────────
// A single `processLoop()` Task runs while state == .running.
// `isProcessing` prevents concurrent loops.  New chunks arriving while the
// loop is suspended at `await whisperClient.transcribe(...)` are simply
// appended to `pendingChunks`; the loop picks them up on the next iteration.
//
// Session assembly and session boundary
// ──────────────────────────────────────
// `currentSession` accumulates segments until a gap of `silenceGapSeconds`
// (default 10 s) is detected between the wall-clock end of the last segment
// and the wall-clock start of the first segment in the incoming chunk.
// On boundary or stop(), the session is finalized → RawEvent.
//
// Performance monitoring
// ──────────────────────
// After each chunk, we compute:
//   realtimeFactor = chunk.durationSeconds / processingTimeSeconds
// Logged at .info; if < 1.0 (falling behind), logged at .error and
// `onBehindRealtime` callback is invoked with the factor value.

import Foundation
import KerwanXPCProtocol
import os

// MARK: - TranscriptionActor

/// Swift actor that drives the audio-to-text pipeline.
///
/// Conforms to `AudioChunkDelegate` so it can be used as the downstream
/// target for `AudioMixer`, `MicrophoneCaptureService`, or
/// `SystemAudioCaptureService`.
public actor TranscriptionActor: AudioChunkDelegate {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Absolute path to the ggml model file used by `WhisperServiceClient`.
        public var modelPath: String
        /// Expected overlap between consecutive AudioChunks, in seconds.
        /// Must match `MicrophoneCaptureService.Configuration.overlapSeconds`.
        public var chunkOverlapSeconds: Double
        /// Silence gap (seconds) that ends a speaking session. Default: 10.
        public var silenceGapSeconds: TimeInterval
        /// In-memory queue depth before spooling to disk. Default: 10.
        public var maxQueueDepth: Int
        /// Queue depth below which spooled files are reloaded. Default: 5.
        public var queueDrainThreshold: Int

        public static let `default` = Configuration()

        public init(
            modelPath:            String           = ModelManager.modelURL.path,
            chunkOverlapSeconds:  Double           = 2.0,
            silenceGapSeconds:    TimeInterval     = 10.0,
            maxQueueDepth:        Int              = 10,
            queueDrainThreshold:  Int              = 5
        ) {
            self.modelPath           = modelPath
            self.chunkOverlapSeconds = chunkOverlapSeconds
            self.silenceGapSeconds   = silenceGapSeconds
            self.maxQueueDepth       = maxQueueDepth
            self.queueDrainThreshold = queueDrainThreshold
        }
    }

    // MARK: - State

    public enum State: Equatable, Sendable {
        case idle
        case loading
        case running
        case paused
        case stopping   // waiting for in-flight transcription to complete
        case stopped
    }

    public private(set) var state: State = .idle

    // MARK: - Progress

    /// Snapshot of the queue and processing state, safe to read from any
    /// isolation context after `await actor.progress`.
    public struct Progress: Sendable, Equatable {
        public let queueDepth:          Int
        public let spooledChunkCount:   Int
        public let isProcessing:        Bool
        public let lastRealtimeFactor:  Double?
        public let isBehindRealtime:    Bool

        public static let idle = Progress(
            queueDepth: 0, spooledChunkCount: 0,
            isProcessing: false, lastRealtimeFactor: nil, isBehindRealtime: false
        )
    }

    public private(set) var progress: Progress = .idle

    // MARK: - Callbacks (set before `start()`)

    /// Called on an arbitrary executor whenever `progress` changes.
    /// Bridge to `@MainActor` / AppState with `Task { @MainActor in ... }`.
    public nonisolated(unsafe) var onProgressUpdate: (@Sendable (Progress) -> Void)?

    /// Called when the realtime factor drops below 1.0×.
    public nonisolated(unsafe) var onBehindRealtime: (@Sendable (Double) -> Void)?

    // MARK: - Dependencies

    private let whisperClient: any WhisperTranscribing
    private let eventDelegate: any CaptureEventDelegate
    private let classificationDelegate: (any CaptureEventDelegate)?
    private let config: Configuration
    private let wavSpool: WAVSpool
    private let log = Logger(subsystem: "com.kerwan.app", category: "TranscriptionActor")

    // MARK: - Queue state (actor-isolated)

    private var pendingChunks:    [AudioChunk] = []
    private var spooledFileURLs:  [URL]        = []
    private var isProcessing:     Bool         = false

    /// Continuation resumed when `stop()` is waiting for the loop to finish.
    private var stopContinuation: CheckedContinuation<Void, Never>?

    // MARK: - Session state (actor-isolated)

    private var currentSession: SpeakingSession?

    // MARK: - Init

    public init(
        whisperClient:           any WhisperTranscribing,
        eventDelegate:           any CaptureEventDelegate,
        classificationDelegate:  (any CaptureEventDelegate)? = nil,
        config:                  Configuration               = .default,
        wavSpool:                WAVSpool                    = WAVSpool()
    ) {
        self.whisperClient          = whisperClient
        self.eventDelegate          = eventDelegate
        self.classificationDelegate = classificationDelegate
        self.config                 = config
        self.wavSpool               = wavSpool
    }

    // MARK: - AudioChunkDelegate

    /// Called by AudioMixer (or a capture service) when a chunk is ready.
    ///
    /// Enqueues the chunk and starts the processing loop if idle.
    public func didCaptureAudioChunk(_ chunk: AudioChunk) async {
        guard state == .running || state == .paused else { return }
        enqueue(chunk)
        if state == .running { maybeStartProcessing() }
    }

    // MARK: - Lifecycle

    /// Loads the Whisper model and begins processing queued chunks.
    ///
    /// - Throws: `WhisperServiceError` on model-load failure.
    public func start() async throws {
        guard state == .idle || state == .stopped else { return }
        state = .loading
        log.info("Starting — loading model at \(self.config.modelPath, privacy: .public)")

        do {
            try await whisperClient.loadModel(atPath: config.modelPath)
        } catch {
            state = .idle
            log.error("Model load failed: \(error.localizedDescription)")
            throw error
        }

        state = .running

        // Recover spooled files from a previous session.
        if let files = try? wavSpool.listFiles(), !files.isEmpty {
            spooledFileURLs = files
            log.info("Recovered \(files.count) spooled chunks from disk")
        }

        updateProgress()
        maybeStartProcessing()
        log.info("Started")
    }

    /// Pauses processing.  The queue is preserved; call `resume()` to continue.
    public func pause() {
        guard state == .running else { return }
        state = .paused
        updateProgress()
        log.info("Paused")
    }

    /// Resumes a paused session.
    public func resume() {
        guard state == .paused else { return }
        state = .running
        updateProgress()
        maybeStartProcessing()
        log.info("Resumed")
    }

    /// Stops processing:
    ///   1. Waits for the in-flight transcription to finish.
    ///   2. Spools all remaining in-memory chunks to disk.
    ///   3. Emits the current speaking session as a RawEvent.
    ///   4. Unloads the Whisper model.
    public func stop() async {
        guard state == .running || state == .paused else { return }
        state = .stopping
        log.info("Stopping — waiting for in-flight transcription…")

        // Wait for processLoop to exit.
        if isProcessing {
            await withCheckedContinuation { cont in
                stopContinuation = cont
            }
        }

        // Spool remaining in-memory chunks so they survive the stop.
        for chunk in pendingChunks {
            if let url = try? wavSpool.write(chunk: chunk) {
                spooledFileURLs.append(url)
            }
        }
        pendingChunks.removeAll()

        // Emit the current session (partial flush).
        await finalizeCurrentSession()

        // Unload model.
        try? await whisperClient.unloadModel()

        state = .stopped
        updateProgress()
        log.info("Stopped")
    }

    // MARK: - Private: queue management

    private func enqueue(_ chunk: AudioChunk) {
        if pendingChunks.count >= config.maxQueueDepth {
            // Backpressure: spool to disk instead of unbounded memory growth.
            log.warning("Queue full (\(self.pendingChunks.count) chunks) — spooling to disk")
            if let url = try? wavSpool.write(chunk: chunk) {
                spooledFileURLs.append(url)
            }
        } else {
            pendingChunks.append(chunk)
        }
        updateProgress()
    }

    private func reloadFromDisk() {
        while pendingChunks.count < config.queueDrainThreshold,
              let url = spooledFileURLs.first {
            spooledFileURLs.removeFirst()
            if let chunk = try? wavSpool.read(url: url) {
                pendingChunks.append(chunk)
                log.debug("Reloaded spooled chunk \(chunk.id)")
            }
        }
    }

    // MARK: - Private: processing loop

    private func maybeStartProcessing() {
        guard !isProcessing,
              state == .running,
              !pendingChunks.isEmpty || !spooledFileURLs.isEmpty
        else { return }
        isProcessing = true
        Task { await processLoop() }
    }

    private func processLoop() async {
        defer {
            isProcessing = false
            stopContinuation?.resume()
            stopContinuation = nil
        }

        repeat {
            // Continue processing in-memory chunks even when stopping, so that
            // chunks enqueued just before stop() are not silently discarded.
            guard state == .running || state == .stopping else { break }

            // Only reload from disk when actively running (not draining on stop).
            if state == .running,
               pendingChunks.count < config.queueDrainThreshold,
               !spooledFileURLs.isEmpty {
                reloadFromDisk()
            }

            guard !pendingChunks.isEmpty else { break }
            let chunk = pendingChunks.removeFirst()
            updateProgress()

            await processChunk(chunk)

        } while !pendingChunks.isEmpty || (!spooledFileURLs.isEmpty && state == .running)
    }

    // MARK: - Private: single-chunk processing

    private func processChunk(_ chunk: AudioChunk) async {
        // Skip transcription for silent chunks, but still track time
        // for session-boundary detection (the gap accumulates naturally).
        guard chunk.containsSpeech else {
            log.debug("Skipping transcription for non-speech chunk \(chunk.id)")
            return
        }

        let processingStart = Date()

        let segments: [TranscriptSegment]
        do {
            segments = try await whisperClient.transcribe(
                audioData:  chunk.data,
                sampleRate: chunk.sampleRate
            )
        } catch {
            log.error("Transcription failed for chunk \(chunk.id): \(error.localizedDescription)")
            return
        }

        // ── Performance monitoring ──────────────────────────────────────────
        let processingTime = Date().timeIntervalSince(processingStart)
        let realtimeFactor = chunk.durationSeconds / max(processingTime, 0.001)
        let behind = realtimeFactor < 1.0

        let speedMsg = String(format: "Transcribed %.0fs chunk in %.1fs (%.1fx realtime)",
                              chunk.durationSeconds, processingTime, realtimeFactor)
        if behind {
            log.error("\(speedMsg, privacy: .public)")
            let factor = realtimeFactor
            onBehindRealtime?(factor)
        } else {
            log.info("\(speedMsg, privacy: .public)")
        }

        // ── Session assembly ────────────────────────────────────────────────
        if segments.isEmpty { return }

        // Compute wall-clock start of the first incoming segment.
        let firstSegWallStart = chunk.startTime.addingTimeInterval(segments[0].startTime)

        // Check for session boundary (>10 s silence since last entry).
        if let session = currentSession,
           session.isSessionBoundary(
               firstWallStart: firstSegWallStart,
               silenceGap: config.silenceGapSeconds
           ) {
            log.info("Session boundary detected — emitting current session")
            await emitSession(session)
            currentSession = nil
        }

        // Open a new session if needed.
        if currentSession == nil {
            currentSession = SpeakingSession(startTime: firstSegWallStart)
        }

        // Accumulate segments (with overlap deduplication).
        currentSession!.addChunkSegments(
            segments,
            chunkStart:     chunk.startTime,
            overlapSeconds: config.chunkOverlapSeconds
        )

        // Update progress with latest realtime factor.
        progress = Progress(
            queueDepth:         pendingChunks.count,
            spooledChunkCount:  spooledFileURLs.count,
            isProcessing:       isProcessing,
            lastRealtimeFactor: realtimeFactor,
            isBehindRealtime:   behind
        )
        onProgressUpdate?(progress)
    }

    // MARK: - Private: session emission

    private func finalizeCurrentSession() async {
        guard let session = currentSession, !session.isEmpty else { return }
        await emitSession(session)
        currentSession = nil
    }

    private func emitSession(_ session: SpeakingSession) async {
        let event = session.toCaptureEvent()
        log.info("Emitting session: chunks=\(session.chunkCount) duration=\(String(format: "%.1f", session.speakingDurationSeconds))s lang=\(session.detectedLanguage) confidence=\(String(format: "%.2f", session.averageConfidence))")
        await eventDelegate.didCapture([event])
        await classificationDelegate?.didCapture([event])
    }

    // MARK: - Private: progress update

    private func updateProgress() {
        progress = Progress(
            queueDepth:         pendingChunks.count,
            spooledChunkCount:  spooledFileURLs.count,
            isProcessing:       isProcessing,
            lastRealtimeFactor: progress.lastRealtimeFactor,
            isBehindRealtime:   progress.isBehindRealtime
        )
        onProgressUpdate?(progress)
    }
}
