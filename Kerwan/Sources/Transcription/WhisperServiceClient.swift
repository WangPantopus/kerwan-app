// WhisperServiceClient.swift
// Kerwan — main app target (Kerwan/Transcription/)
//
// Async/await wrapper around the WhisperService XPC connection.
//
// Reconnection strategy
// ─────────────────────
// NSXPCConnection can be invalidated by the OS (service crash, resource
// pressure, explicit termination).  On invalidation `connectionLock` is
// acquired and the connection is nilled so the next API call recreates it.
// There is NO automatic retry loop — the caller decides whether to retry.
//
// Timeout
// ───────
// `transcribe` races a 60-second Task.sleep sentinel against the XPC reply.
// If the sentinel wins, the connection is invalidated (killing the service
// process) and `WhisperServiceError.timeout` is thrown.  Subsequent calls
// reconnect automatically.
//
// Thread safety
// ─────────────
// `WhisperServiceClient` is an actor, so all state mutations are serialised.
// The XPC reply callbacks are dispatched by NSXPCConnection onto an internal
// queue; `withCheckedThrowingContinuation` bridges them back to the actor.

import Foundation
import KerwanXPCProtocol
import os

// MARK: - WhisperServiceClient

/// Manages the NSXPCConnection to WhisperService and provides async API.
///
/// Typical usage:
/// ```swift
/// let client = WhisperServiceClient()
/// try await client.loadModel(atPath: ModelManager.modelPath.path)
/// let segments = try await client.transcribe(audioData: chunk.data,
///                                             sampleRate: chunk.sampleRate)
/// ```
public actor WhisperServiceClient {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Mach service name registered in WhisperService's Info.plist.
        public var serviceName: String
        /// Maximum time (seconds) allowed for a single transcription call.
        public var transcriptionTimeout: TimeInterval

        public static let `default` = Configuration()

        public init(
            serviceName: String = "com.kerwan.WhisperService",
            transcriptionTimeout: TimeInterval = 60
        ) {
            self.serviceName = serviceName
            self.transcriptionTimeout = transcriptionTimeout
        }
    }

    // MARK: - Private state

    private let config: Configuration
    private var connection: NSXPCConnection?
    private let log = Logger(subsystem: "com.kerwan.app", category: "WhisperServiceClient")

    // MARK: - Init

    public init(config: Configuration = .default) {
        self.config = config
    }

    // MARK: - Public async API

    /// Loads the model at `path` in the XPC service process.
    ///
    /// - Throws: `WhisperServiceError.modelNotFound` if the path doesn't exist.
    /// - Throws: `WhisperServiceError.modelLoadFailed` on whisper.cpp failure.
    /// - Throws: `WhisperServiceError.connectionFailed` on XPC error.
    public func loadModel(atPath path: String) async throws {
        let proxy = try makeProxy()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proxy.loadModel(path: path) { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
        log.info("loadModel succeeded: \(path, privacy: .public)")
    }

    /// Transcribes raw PCM audio, returning decoded `TranscriptSegment`s.
    ///
    /// - Parameters:
    ///   - audioData: Float32 PCM, host byte-order.
    ///   - sampleRate: Sample rate in Hz (typically 16 000).
    /// - Returns: Chronologically-sorted array of segments.
    /// - Throws: `WhisperServiceError.timeout` if no reply arrives within
    ///   `config.transcriptionTimeout` seconds.
    /// - Throws: `WhisperServiceError.transcriptionFailed` on engine error.
    public func transcribe(
        audioData: Data,
        sampleRate: Int
    ) async throws -> [TranscriptSegment] {
        let proxy = try makeProxy()

        return try await withTimeout(seconds: config.transcriptionTimeout) {
            try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<[TranscriptSegment], Error>) in
                proxy.transcribe(audioData: audioData, sampleRate: sampleRate) { [weak self] encodedSegments, error in
                    if let error {
                        // Deliver partial results if any segments were produced.
                        if let partial = encodedSegments, !partial.isEmpty {
                            // Log the partial result but surface the error to the caller.
                            Task { await self?.log.warning("Partial transcription with error: \(error.localizedDescription)") }
                        }
                        cont.resume(throwing: error)
                        return
                    }
                    guard let encoded = encodedSegments else {
                        cont.resume(returning: [])
                        return
                    }
                    do {
                        let segments = try encoded.map { try TranscriptSegment.decode(from: $0) }
                        cont.resume(returning: segments.sorted())
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        } onTimeout: { [weak self] in
            // Kill the connection so the service process is terminated.
            // The next API call will reconnect.
            Task { await self?.invalidateConnection() }
        }
    }

    /// Returns whether a model is currently loaded in the service.
    public func isModelLoaded() async throws -> Bool {
        let proxy = try makeProxy()
        return await withCheckedContinuation { cont in
            proxy.isModelLoaded { loaded in cont.resume(returning: loaded) }
        }
    }

    /// Unloads the model and frees GPU/CPU memory in the service process.
    public func unloadModel() async throws {
        let proxy = try makeProxy()
        await withCheckedContinuation { cont in
            proxy.unloadModel { cont.resume() }
        }
        log.info("unloadModel complete")
    }

    /// Invalidates the XPC connection (for testing and explicit teardown).
    public func disconnect() {
        invalidateConnection()
        log.info("Disconnected")
    }

    // MARK: - Private: connection management

    /// Returns the remote proxy, creating a new connection if needed.
    private func makeProxy() throws -> any WhisperServiceProtocol {
        let conn = existingOrNewConnection()
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ [weak self] error in
            Task { await self?.handleConnectionError(error) }
        }) as? any WhisperServiceProtocol else {
            throw WhisperServiceError.connectionFailed
        }
        return proxy
    }

    private func existingOrNewConnection() -> NSXPCConnection {
        if let existing = connection { return existing }
        let conn = NSXPCConnection(serviceName: config.serviceName)
        conn.remoteObjectInterface = makeWhisperXPCInterface()

        conn.invalidationHandler = { [weak self] in
            Task { await self?.handleInvalidation() }
        }
        conn.interruptionHandler = { [weak self] in
            Task { await self?.handleInterruption() }
        }
        conn.resume()

        connection = conn
        log.info("XPC connection established to '\(self.config.serviceName, privacy: .public)'")
        return conn
    }

    private func invalidateConnection() {
        connection?.invalidate()
        connection = nil
    }

    private func handleInvalidation() {
        log.warning("XPC connection invalidated — will reconnect on next call")
        connection = nil
    }

    private func handleInterruption() {
        // Interruption = service crashed or was killed.  Invalidate so we
        // reconnect cleanly rather than reusing a broken connection object.
        log.warning("XPC connection interrupted — invalidating")
        connection?.invalidate()
        connection = nil
    }

    private func handleConnectionError(_ error: Error) {
        log.error("XPC remote object error: \(error.localizedDescription)")
        connection?.invalidate()
        connection = nil
    }

    // MARK: - Private: timeout helper

    /// Races `work` against a `seconds`-long sleep.
    /// If the sleep wins, calls `onTimeout` and throws `.timeout`.
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        work: @Sendable @escaping () async throws -> T,
        onTimeout: @Sendable @escaping () -> Void
    ) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                onTimeout()
                throw WhisperServiceError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
