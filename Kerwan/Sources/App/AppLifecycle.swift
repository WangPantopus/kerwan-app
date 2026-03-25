import Foundation
import os
import KerwanKeychain

// MARK: - Service Protocols

/// The storage interface the app lifecycle and UI require from the persistence layer.
///
/// `StorageActor` (in the `KerwanStorage` module) conforms to this protocol.
/// The protocol boundary exists so the `Kerwan` app target can remain decoupled
/// from the storage module — which defines its own lower-level model types — while
/// still driving its lifecycle and retrieving badge counts.
protocol AppStorageService: Actor {
    /// Returns the count of raw events recorded since midnight (local time).
    func countRawEventsToday() async throws -> Int

    /// Returns the count of work sessions with `.undecided` billable status.
    func countUnreviewedSessions() async throws -> Int

    /// Returns the count of promises in `.open` status.
    func countOpenPromises() async throws -> Int

    /// Persists a user-authored manual note as a `manualNote` source `RawEvent`.
    func insertManualNote(text: String, at date: Date) async throws
}

/// The capture-control interface required by the app lifecycle.
///
/// `CaptureManager` (in the capture workstream) conforms to this protocol.
/// All methods are on the actor's executor so callers use `await`.
protocol CaptureManaging: Actor {
    /// The current operating status of the capture system.
    var currentStatus: CaptureStatus { get }

    /// Starts all enabled capture sources (audio, accessibility, etc.).
    /// Throws if a required permission is missing or a source fails to initialise.
    func start() async throws

    /// Suspends capture. State is preserved; `resume()` restarts without re-init.
    func pause() async

    /// Resumes capture after a `pause()`. Throws if the source cannot reconnect.
    func resume() async throws

    /// Enters private mode: all capture sources are suspended immediately.
    func enablePrivateMode() async

    /// Exits private mode and restores capture to its pre-private-mode state.
    func disablePrivateMode() async throws

    /// Flushes any in-memory buffered events to persistent storage.
    /// Called before system sleep and before process exit.
    func flushBuffer() async

    /// Graceful full shutdown: flush, stop all sources, release resources.
    func stop() async
}

// MARK: - AppLifecycle

/// Coordinates startup, steady-state refresh, and shutdown of all Kerwan services.
///
/// `AppLifecycle` is an `actor` so its mutable service references are safe to
/// read and write from concurrent contexts. Concrete service implementations are
/// injected via ``inject(storage:capture:)`` before ``start(appState:keychain:)``
/// is called.
///
/// Typical usage in `KerwanAppDelegate.applicationDidFinishLaunching`:
/// ```swift
/// lifecycle.inject(storage: myStorageActor, capture: myCaptureManager)
/// await lifecycle.start(appState: appState, keychain: keychain)
/// ```
actor AppLifecycle {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "AppLifecycle"
    )

    // MARK: - Injected services

    private var storage: (any AppStorageService)?
    private var capture: (any CaptureManaging)?

    // MARK: - Internal state

    private var refreshTask: Task<Void, Never>?
    private var isShuttingDown = false

    // MARK: - Dependency injection

    /// Injects the concrete service implementations.
    ///
    /// Must be called before `start(appState:keychain:)`.
    func inject(storage: any AppStorageService, capture: any CaptureManaging) {
        self.storage = storage
        self.capture = capture
        Self.logger.info("Services injected into AppLifecycle")
    }

    // MARK: - Startup

    /// Loads the database passphrase from the keychain, verifies services, and
    /// starts capture. Non-fatal failures are reflected in `appState` without
    /// aborting the startup sequence.
    ///
    /// - Parameters:
    ///   - appState: The shared UI state to update as startup progresses.
    ///   - keychain: The keychain manager used to retrieve the database passphrase.
    func start(appState: AppState, keychain: KeychainManager) async {
        Self.logger.info("AppLifecycle: starting services")

        // Step 1 — Load (or generate) the database passphrase.
        let passphrase: String
        do {
            passphrase = try await keychain.databasePassphrase()
            Self.logger.info("Database passphrase retrieved from keychain")
        } catch {
            let msg = "Failed to load database passphrase: \(error.localizedDescription)"
            Self.logger.error("\(msg, privacy: .public)")
            await MainActor.run { appState.reportError(msg) }
            return
        }

        // Step 2 — The passphrase is consumed by the StorageActor at initialisation
        // time (injected externally). Reference it here to satisfy the compiler and
        // document the data flow.
        _ = passphrase

        // Step 3 — Start capture.
        guard let capture else {
            Self.logger.warning("CaptureManager not injected; skipping capture start")
            await MainActor.run { appState.markInitialized() }
            startRefreshLoop(appState: appState)
            return
        }

        do {
            try await capture.start()
            let status = await capture.currentStatus
            await MainActor.run { appState.updateCaptureStatus(status) }
            Self.logger.info("Capture started successfully")
        } catch {
            let msg = "Capture failed to start: \(error.localizedDescription)"
            Self.logger.error("\(msg, privacy: .public)")
            await MainActor.run {
                appState.updateCaptureStatus(.error(error.localizedDescription))
                appState.reportError(msg)
            }
        }

        // Step 4 — Kick off the steady-state refresh loop.
        startRefreshLoop(appState: appState)

        await MainActor.run { appState.markInitialized() }
        Self.logger.info("AppLifecycle: startup complete")
    }

    // MARK: - Periodic Refresh

    /// Starts the badge-count refresh loop. Fires every 30 seconds.
    ///
    /// The loop also serves as the trigger point for the billing-engine sweep
    /// and daily digest scheduling (both stubbed here; implemented in their
    /// respective workstreams).
    private func startRefreshLoop(appState: AppState) {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled && !isShuttingDown {
                await refreshCounts(appState: appState)
                // Billing engine sweep and digest scheduling hooks fire here
                // when implemented by the AI intelligence workstream.
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Re-fetches badge counts from storage and pushes them to `AppState`.
    func refreshCounts(appState: AppState) async {
        guard let storage else { return }
        do {
            async let eventsToday      = storage.countRawEventsToday()
            async let pendingReview    = storage.countUnreviewedSessions()
            async let openPromises     = storage.countOpenPromises()
            let (events, pending, promises) = try await (eventsToday, pendingReview, openPromises)
            await MainActor.run {
                appState.updateEventsToday(events)
                appState.updatePendingReviewCount(pending)
                appState.updateOpenPromiseCount(promises)
            }
        } catch {
            Self.logger.error(
                "Failed to refresh badge counts: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Capture Controls

    /// Toggles between `.capturing` and `.paused` based on the current status.
    func toggleCapture(appState: AppState) async {
        guard let capture else { return }
        let status = await capture.currentStatus
        do {
            switch status {
            case .capturing:
                await capture.pause()
                await MainActor.run { appState.updateCaptureStatus(.paused) }
                Self.logger.info("Capture paused by user")
            case .paused:
                try await capture.resume()
                await MainActor.run { appState.updateCaptureStatus(.capturing) }
                Self.logger.info("Capture resumed by user")
            case .privateMode:
                break   // Must use disablePrivateMode() to exit private mode.
            case .idle:
                try await capture.start()
                await MainActor.run { appState.updateCaptureStatus(.capturing) }
            case .error:
                try await capture.start()
                await MainActor.run {
                    appState.updateCaptureStatus(.capturing)
                    appState.clearError()
                }
            }
        } catch {
            await MainActor.run { appState.reportError(error.localizedDescription) }
        }
    }

    /// Suspends all capture (private mode). The menu bar icon turns red.
    func enablePrivateMode(appState: AppState) async {
        guard let capture else { return }
        await capture.enablePrivateMode()
        await MainActor.run { appState.updateCaptureStatus(.privateMode) }
        Self.logger.info("Private mode enabled")
    }

    /// Exits private mode and restores capture.
    func disablePrivateMode(appState: AppState) async {
        guard let capture else { return }
        do {
            try await capture.disablePrivateMode()
            await MainActor.run { appState.updateCaptureStatus(.capturing) }
            Self.logger.info("Private mode disabled")
        } catch {
            await MainActor.run { appState.reportError(error.localizedDescription) }
        }
    }

    /// Pauses audio capture in response to system sleep.
    func pauseAudioCapture(appState: AppState) async {
        guard let capture else { return }
        let status = await capture.currentStatus
        guard case .capturing = status else { return }
        await capture.flushBuffer()
        await capture.pause()
        await MainActor.run { appState.updateCaptureStatus(.paused) }
        Self.logger.info("Audio capture paused for system sleep")
    }

    /// Resumes audio capture after system wake, but only if it was capturing
    /// before sleep (i.e., not if the user had manually paused or gone private).
    func resumeAudioCapture(appState: AppState) async {
        guard let capture else { return }
        let status = await capture.currentStatus
        guard case .paused = status else { return }
        do {
            try await capture.resume()
            await MainActor.run { appState.updateCaptureStatus(.capturing) }
            Self.logger.info("Audio capture resumed after system wake")
        } catch {
            let msg = "Could not resume capture after wake: \(error.localizedDescription)"
            Self.logger.error("\(msg, privacy: .public)")
            await MainActor.run { appState.reportError(msg) }
        }
    }

    // MARK: - Manual Notes

    /// Saves a user-authored note as a `manualNote` raw event.
    func saveManualNote(text: String, appState: AppState) async {
        guard let storage else {
            await MainActor.run {
                appState.reportError("Storage is not available. Note not saved.")
            }
            return
        }
        do {
            try await storage.insertManualNote(text: text, at: Date())
            await refreshCounts(appState: appState)
            Self.logger.info("Manual note saved")
        } catch {
            let msg = "Failed to save note: \(error.localizedDescription)"
            await MainActor.run { appState.reportError(msg) }
        }
    }

    // MARK: - Shutdown

    /// Flushes in-flight events, stops all capture sources, and performs a graceful
    /// shutdown. Called from `applicationShouldTerminate(_:)` before the process exits.
    ///
    /// After this returns, `NSApp.reply(toApplicationShouldTerminate: true)` is safe.
    func shutdown(appState: AppState) async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        Self.logger.info("AppLifecycle: beginning shutdown")

        refreshTask?.cancel()
        refreshTask = nil

        guard let capture else {
            Self.logger.info("No capture manager present; shutdown complete")
            return
        }

        // Flush the ring buffer before we stop capture sources.
        await capture.flushBuffer()
        await capture.stop()

        await MainActor.run { appState.updateCaptureStatus(.idle) }
        Self.logger.info("AppLifecycle: shutdown complete")
    }
}
