import AppKit
import Foundation
import os

/// Manages the lifecycle of the Ollama subprocess and ensures required models are available.
///
/// `OllamaManager` is the single point of authority for the Ollama process. It:
/// - Detects whether Ollama is already installed and running.
/// - Launches Ollama as a child ``Process`` when needed, bound exclusively to `127.0.0.1:11434`.
/// - Polls for readiness and waits up to 30 seconds for the server to become healthy.
/// - Pulls required models (`llama3:8b-instruct-q4_K_M`, `nomic-embed-text`) if absent.
/// - Monitors the subprocess and restarts it up to ``maxRestarts`` times on unexpected exit.
/// - Shuts down gracefully (SIGTERM → 5 s wait → SIGKILL) when the app quits.
///
/// The app should call ``ensureRunning()`` and ``ensureModels()`` during startup, then keep
/// a reference to ``client`` for all downstream AI operations.
///
/// ```swift
/// let manager = OllamaManager()
/// try await manager.ensureRunning()
/// try await manager.ensureModels()
/// let text = try await manager.client.complete(prompt: "Hello", system: nil, model: "llama3:8b-instruct-q4_K_M")
/// ```
public actor OllamaManager {

    // MARK: - Constants

    /// Models required for Kerwan's classification and embedding pipelines.
    private static let requiredModels: [String] = [
        "llama3:8b-instruct-q4_K_M",
        "nomic-embed-text"
    ]

    /// Candidate filesystem paths to check for the Ollama binary.
    private static let binarySearchPaths: [String] = [
        "/usr/local/bin/ollama",
        "/opt/homebrew/bin/ollama",
        "\(NSHomeDirectory())/.ollama/bin/ollama",
        "\(NSHomeDirectory())/.local/bin/ollama"
    ]

    /// Maximum wall-clock seconds to wait for Ollama to become healthy after launch.
    private static let healthCheckTimeoutSeconds: Double = 30
    /// Interval between health-check probes.
    private static let healthCheckIntervalMs: UInt64 = 500
    /// Seconds to wait before attempting a restart after an unexpected exit.
    private static let restartDelaySecs: UInt64 = 5
    /// Maximum consecutive restart attempts before giving up.
    private let maxRestarts: Int

    // MARK: - Logging

    private static let logger = Logger(subsystem: "com.kerwan.app", category: "OllamaManager")

    // MARK: - State

    private var process: Process?
    /// `true` when we launched and own the Ollama process; `false` when we adopted an external one.
    private var ownsProcess: Bool = false
    private var restartCount: Int = 0
    private var _isRunning: Bool = false
    private var _availableModels: [String] = []

    // MARK: - Dependencies

    private let _client: OllamaClient
    /// Optional override of the binary path, used in tests to skip filesystem detection.
    private let binaryPathOverride: String?

    // MARK: - Public Interface

    /// The Ollama HTTP client pre-configured for `127.0.0.1:11434`.
    public var client: OllamaClient { _client }

    /// Whether the Ollama server is currently reachable and responding to health checks.
    public var isRunning: Bool { _isRunning }

    /// Model names reported by the last successful `GET /api/tags` call.
    public var availableModels: [String] { _availableModels }

    // MARK: - Init

    /// Creates an `OllamaManager`.
    ///
    /// - Parameters:
    ///   - binaryPath: Override the Ollama binary path (skip auto-detection). Pass `nil` to
    ///     search standard locations and fall back to `which ollama`.
    ///   - session: `URLSession` used by the underlying ``OllamaClient``. Override in tests.
    ///   - maxRestarts: Maximum restart attempts on unexpected subprocess exit. Default: 3.
    public init(
        binaryPath: String? = nil,
        session: URLSession = .shared,
        maxRestarts: Int = 3
    ) {
        self.binaryPathOverride = binaryPath
        self._client = OllamaClient(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            session: session
        )
        self.maxRestarts = maxRestarts
    }

    // MARK: - Lifecycle

    /// Ensures the Ollama server is running and healthy.
    ///
    /// The method first checks whether Ollama is already serving on `127.0.0.1:11434` (e.g.
    /// started by the user externally). If so, it adopts that instance without launching a
    /// new process. Otherwise, it locates the binary, launches it, and waits up to 30 seconds
    /// for the health check to succeed.
    ///
    /// If the binary is not found, a modal dialog offers to open the Ollama download page.
    ///
    /// - Throws: ``OllamaError/notInstalled`` if the binary cannot be located,
    ///   ``OllamaError/healthCheckTimeout`` if Ollama doesn't become healthy in time.
    public func ensureRunning() async throws {
        guard !_isRunning else { return }

        // Fast path: Ollama is already serving externally.
        if await _client.isHealthy() {
            Self.logger.info("Adopted externally-running Ollama instance")
            _isRunning = true
            ownsProcess = false
            NotificationCenter.default.post(name: .ollamaDidBecomeReady, object: nil)
            return
        }

        // Resolve binary path.
        guard let binaryPath = binaryPathOverride ?? findOllamaBinary() else {
            Self.logger.error("Ollama binary not found")
            await presentInstallDialog()
            throw OllamaError.notInstalled
        }

        Self.logger.info("Launching Ollama from \(binaryPath, privacy: .public)")
        try launchProcess(binaryPath: binaryPath)
        try await waitUntilHealthy()

        _isRunning = true
        ownsProcess = true
        restartCount = 0
        NotificationCenter.default.post(name: .ollamaDidBecomeReady, object: nil)
        Self.logger.info("Ollama is running")
    }

    /// Checks which required models are available and pulls any that are missing.
    ///
    /// This should be called after ``ensureRunning()`` succeeds. Pull progress is written
    /// to `os_log`; the caller is not blocked between individual model downloads.
    ///
    /// - Throws: ``OllamaError`` if the model list cannot be fetched or a pull fails.
    public func ensureModels() async throws {
        let models = try await _client.listModels()
        let present = Set(models.map(\.name))
        _availableModels = Array(present)

        for name in Self.requiredModels where !present.contains(name) {
            Self.logger.info("Pulling required model: \(name, privacy: .public)")
            try await _client.pullModel(name: name) { fraction in
                let pct = Int(fraction * 100)
                Self.logger.info("Pulling \(name, privacy: .public): \(pct)%")
            }
            Self.logger.info("Model '\(name, privacy: .public)' is ready")
        }

        // Refresh the list after any pulls.
        let updated = try await _client.listModels()
        _availableModels = updated.map(\.name)
        let modelList = self._availableModels.joined(separator: ", ")
        Self.logger.info("Available models: \(modelList, privacy: .public)")
    }

    /// Gracefully shuts down the Ollama subprocess.
    ///
    /// If Kerwan launched Ollama, sends `SIGTERM` and waits up to 5 seconds. If the
    /// process is still alive after the grace period, sends `SIGKILL`. If Ollama was
    /// adopted from an external instance, this is a no-op for the process itself but
    /// resets the manager's state.
    public func shutdown() async {
        Self.logger.info("OllamaManager shutting down")
        defer {
            process = nil
            _isRunning = false
            ownsProcess = false
        }

        guard ownsProcess, let proc = process, proc.isRunning else { return }

        proc.terminate()  // SIGTERM

        // Wait up to 5 seconds for graceful exit.
        let deadline = Date(timeIntervalSinceNow: 5)
        while proc.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        }

        if proc.isRunning {
            Self.logger.warning("Ollama did not exit after SIGTERM; sending SIGKILL")
            kill(proc.processIdentifier, SIGKILL)
        }
    }

    // MARK: - Private: Launch

    /// Starts a new `Process` for the Ollama binary with the required environment.
    private func launchProcess(binaryPath: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["serve"]

        // Inherit the current environment and overlay Kerwan-specific overrides.
        var env = ProcessInfo.processInfo.environment
        env["OLLAMA_HOST"]    = "127.0.0.1:11434"
        env["OLLAMA_NOPRUNE"] = "1"
        proc.environment = env

        // Redirect stdout and stderr to os_log.
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError  = stderrPipe
        pipeToLog(stdoutPipe, label: "stdout")
        pipeToLog(stderrPipe, label: "stderr")

        // Register termination callback before launch to avoid a race.
        startMonitoring(proc)

        do {
            try proc.run()
        } catch {
            throw OllamaError.launchFailed(underlying: WrappedError(error))
        }

        process = proc
        Self.logger.info("Ollama process launched (pid \(proc.processIdentifier))")
    }

    // MARK: - Private: Health Check

    /// Polls `isHealthy()` every 500 ms until the server responds or the 30-second deadline passes.
    private func waitUntilHealthy() async throws {
        let deadline = Date(timeIntervalSinceNow: Self.healthCheckTimeoutSeconds)
        while Date() < deadline {
            if await _client.isHealthy() { return }
            try await Task.sleep(nanoseconds: Self.healthCheckIntervalMs * 1_000_000)
        }
        throw OllamaError.healthCheckTimeout
    }

    // MARK: - Private: Process Monitoring

    /// Sets up a non-blocking termination handler via `AsyncStream` so no thread is stalled.
    private func startMonitoring(_ proc: Process) {
        let (stream, continuation) = AsyncStream<Int32>.makeStream()
        proc.terminationHandler = { finished in
            continuation.yield(finished.terminationStatus)
            continuation.finish()
        }
        // The Task runs on this actor's executor. It suspends while waiting for the
        // stream to yield (which happens on the process's background thread), then
        // re-enters the actor to handle the exit.
        Task {
            for await status in stream {
                await handleProcessTermination(status: status)
            }
        }
    }

    /// Called when the monitored process exits. Initiates a restart if appropriate.
    private func handleProcessTermination(status: Int32) async {
        guard ownsProcess else { return }

        _isRunning = false
        process    = nil

        if status == 0 {
            Self.logger.info("Ollama exited normally (status 0)")
            return
        }

        Self.logger.error("Ollama exited unexpectedly with status \(status)")

        guard restartCount < maxRestarts else {
            Self.logger.error(
                "Ollama exceeded max restart attempts (\(self.maxRestarts, privacy: .public))"
            )
            await notifyMaxRestartsExceeded()
            return
        }

        restartCount += 1
        Self.logger.info(
            "Scheduling Ollama restart \(self.restartCount, privacy: .public)/\(self.maxRestarts, privacy: .public) in \(Self.restartDelaySecs)s"
        )

        try? await Task.sleep(nanoseconds: Self.restartDelaySecs * 1_000_000_000)

        do {
            try await ensureRunning()
            try await ensureModels()
        } catch {
            Self.logger.error("Ollama restart failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Private: Pipe Logging

    /// Reads lines from `pipe` asynchronously and forwards them to `os_log`.
    private func pipeToLog(_ pipe: Pipe, label: String) {
        let handle = pipe.fileHandleForReading
        Task {
            do {
                for try await line in handle.bytes.lines where !line.isEmpty {
                    Self.logger.debug("[ollama \(label, privacy: .public)] \(line, privacy: .public)")
                }
            } catch {
                // File handle closed after process exit — expected, not an error.
            }
        }
    }

    // MARK: - Private: Binary Detection

    /// Returns the path to the Ollama binary, or `nil` if not found.
    ///
    /// Checks a fixed list of well-known locations, then falls back to `which ollama`.
    private func findOllamaBinary() -> String? {
        let fm = FileManager.default
        for path in Self.binarySearchPaths {
            if fm.fileExists(atPath: path) && fm.isExecutableFile(atPath: path) {
                Self.logger.debug("Found Ollama at \(path, privacy: .public)")
                return path
            }
        }
        return resolveViaWhich()
    }

    /// Shells out to `/usr/bin/which ollama` to locate the binary via `$PATH`.
    private func resolveViaWhich() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["ollama"]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = Pipe()  // swallow stderr

        do {
            try proc.run()
        } catch {
            Self.logger.debug("`which ollama` failed to launch: \(error, privacy: .public)")
            return nil
        }

        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        let path = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }

        Self.logger.debug("`which` resolved Ollama to: \(path, privacy: .public)")
        return path
    }

    // MARK: - Private: UI

    /// Presents a modal dialog on the main thread prompting the user to install Ollama.
    @MainActor
    private func presentInstallDialog() {
        let alert = NSAlert()
        alert.alertStyle        = .informational
        alert.messageText       = "Kerwan requires Ollama for AI features"
        alert.informativeText   = "Ollama runs locally and processes your data on-device.\nWould you like to install it now?"
        alert.addButton(withTitle: "Install Ollama…")
        alert.addButton(withTitle: "Not Now")

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "https://ollama.com/download") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Posts the max-restarts notification on the main thread for the UI to observe.
    @MainActor
    private func notifyMaxRestartsExceeded() {
        NotificationCenter.default.post(name: .ollamaMaxRestartsExceeded, object: nil)
    }
}

// MARK: - WrappedError (Sendable bridge)

/// A `Sendable`-conforming wrapper for arbitrary `Error` values.
///
/// `Process.run()` throws a plain `Error`. Since `Error` is not unconditionally
/// `Sendable`, we wrap it to satisfy ``OllamaError/launchFailed(underlying:)``'s
/// `any Error & Sendable` constraint.
private struct WrappedError: Error, Sendable, CustomStringConvertible {
    private let message: String
    init(_ error: any Error) { self.message = error.localizedDescription }
    var description: String { message }
}
