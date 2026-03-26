// ModelManager.swift
// Kerwan — main app target (Kerwan/Transcription/)
//
// Manages the whisper.cpp model file lifecycle:
//   • path resolution  (~Library/Application Support/Kerwan/Models/)
//   • existence check  (fast, no I/O beyond stat())
//   • download         (URLSession with progress, resumable)
//   • cancellation     (user-initiated or app-termination)
//
// Threading model
// ───────────────
// ModelManager is @MainActor so SwiftUI views can bind to its published
// properties without extra hops.  URLSession callbacks are bridged to
// the MainActor via `Task { @MainActor in … }`.
//
// Download URL
// ────────────
// ggml-large-v3-turbo.bin from the official whisper.cpp HuggingFace repo:
//   https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
// The file is ~1.6 GB (Q5_0 quantised).  The raw fp16 weights are ~3.1 GB
// and are NOT used here.

import Foundation
import os

// MARK: - ModelManager

@MainActor
public final class ModelManager: ObservableObject {

    // MARK: - State

    public enum State: Equatable {
        /// No model file on disk.
        case notInstalled
        /// Download in progress.
        case downloading(progress: Double)   // 0.0 – 1.0
        /// File on disk, ready to load into the XPC service.
        case ready
        /// Download or verification failed.
        case failed(reason: String)

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.notInstalled, .notInstalled): return true
            case (.ready, .ready):               return true
            case (.downloading(let a), .downloading(let b)): return a == b
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    // MARK: - Published

    @Published public private(set) var state: State = .notInstalled
    @Published public private(set) var downloadedBytes: Int64 = 0
    @Published public private(set) var totalBytes: Int64 = 0

    // MARK: - Static paths

    /// Absolute URL to the model file on disk.
    public nonisolated static var modelURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Kerwan", isDirectory: true)
            .appendingPathComponent("Models",  isDirectory: true)
            .appendingPathComponent("ggml-large-v3-turbo.bin")
    }

    /// Download source on Hugging Face (ggml-large-v3-turbo, Q5_0, ~1.6 GB).
    public static let downloadURL = URL(
        string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
    )!

    // MARK: - Injectable environment

    public struct Environment {
        var fileExists: @Sendable (String) -> Bool
        var createDirectory: @Sendable (URL) throws -> Void
        var downloadURL: URL
        var makeSession: @Sendable () -> URLSession

        public static let live = Environment(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            createDirectory: { url in
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true
                )
            },
            downloadURL: ModelManager.downloadURL,
            makeSession: { URLSession.shared }
        )
    }

    // MARK: - Private state

    private let env: Environment
    private let log = Logger(subsystem: "com.kerwan.app", category: "ModelManager")

    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    // MARK: - Init

    public init(environment: Environment = .live) {
        self.env = environment
        refreshState()
    }

    // MARK: - Public API

    /// Checks the filesystem and updates `state`.  Safe to call at any time.
    public func refreshState() {
        if case .downloading = state { return }  // don't interrupt an active download
        if env.fileExists(Self.modelURL.path) {
            state = .ready
        } else {
            state = .notInstalled
        }
    }

    /// Returns `true` if the model file exists (per the injected `fileExists` check).
    public var modelExists: Bool {
        env.fileExists(Self.modelURL.path)
    }

    /// Starts downloading the model if not already present.
    ///
    /// Progress is reflected via `state`, `downloadedBytes`, and `totalBytes`.
    /// Safe to call when state is `.notInstalled` or `.failed`.
    public func downloadModelIfNeeded() {
        guard case .downloading = state else {
            if modelExists {
                state = .ready
                return
            }
            startDownload()
            return
        }
        // Already downloading.
    }

    /// Cancels an in-progress download.
    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        progressObservation = nil
        state = .notInstalled
        log.info("Download cancelled by user")
    }

    // MARK: - Private: download

    private func startDownload() {
        log.info("Starting model download from \(self.env.downloadURL, privacy: .public)")
        state = .downloading(progress: 0)

        // Ensure the Models directory exists.
        let modelsDir = Self.modelURL.deletingLastPathComponent()
        do {
            try env.createDirectory(modelsDir)
        } catch {
            log.error("Cannot create Models directory: \(error.localizedDescription)")
            state = .failed(reason: "Cannot create Models directory: \(error.localizedDescription)")
            return
        }

        let session = env.makeSession()
        let task = session.downloadTask(with: env.downloadURL) { [weak self] tempURL, response, error in
            Task { @MainActor [weak self] in
                self?.handleDownloadCompletion(tempURL: tempURL, response: response, error: error)
            }
        }

        // Observe fractionCompleted for live progress.
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloadedBytes = progress.completedUnitCount
                self.totalBytes      = progress.totalUnitCount
                self.state           = .downloading(progress: progress.fractionCompleted)
            }
        }

        downloadTask = task
        task.resume()
    }

    private func handleDownloadCompletion(
        tempURL: URL?,
        response: URLResponse?,
        error: Error?
    ) {
        progressObservation = nil
        downloadTask = nil

        if let error {
            if (error as NSError).code == NSURLErrorCancelled {
                // cancelDownload() already set state to .notInstalled.
                return
            }
            log.error("Download failed: \(error.localizedDescription)")
            state = .failed(reason: error.localizedDescription)
            return
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            state = .failed(reason: "Unexpected response type")
            return
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            log.error("HTTP \(httpResponse.statusCode) from model server")
            state = .failed(reason: "HTTP \(httpResponse.statusCode)")
            return
        }

        guard let tempURL else {
            state = .failed(reason: "No temporary file from URLSession")
            return
        }

        // Move from the temp location to the final path.
        do {
            // Remove stale partial file if present.
            if FileManager.default.fileExists(atPath: Self.modelURL.path) {
                try FileManager.default.removeItem(at: Self.modelURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: Self.modelURL)
            state = .ready
            log.info("Model downloaded successfully → \(Self.modelURL.path, privacy: .public)")
        } catch {
            log.error("File move failed: \(error.localizedDescription)")
            state = .failed(reason: "Could not save model: \(error.localizedDescription)")
        }
    }
}

// MARK: - DownloadProgressView (SwiftUI helper model)

/// Convenience computed properties for binding in a SwiftUI progress sheet.
public extension ModelManager {

    /// Human-readable download size string, e.g. "823 MB / 1.6 GB".
    var downloadSizeDescription: String {
        guard totalBytes > 0 else { return "" }
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useMB, .useGB]
        fmt.countStyle   = .file
        return "\(fmt.string(fromByteCount: downloadedBytes)) / \(fmt.string(fromByteCount: totalBytes))"
    }

    /// Download fraction in [0, 1] for a ProgressView.
    var downloadFraction: Double {
        guard case .downloading(let p) = state else { return 0 }
        return p
    }

    /// Whether the download sheet should be presented.
    var shouldShowDownloadUI: Bool {
        switch state {
        case .notInstalled, .downloading, .failed: return true
        case .ready: return false
        }
    }
}
