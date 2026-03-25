import AppKit
import os
import KerwanKeychain

/// Platform-level application delegate bridged into the SwiftUI lifecycle via
/// `@NSApplicationDelegateAdaptor` in `KerwanApp`.
///
/// Responsibilities:
/// - Owning `AppState`, `AppLifecycle`, and `KeychainManager` so they are
///   available before any scene or window is created.
/// - Driving the async startup sequence from `applicationDidFinishLaunching`.
/// - Setting the activation policy so Kerwan launches as a menu-bar-only app.
/// - Intercepting `applicationShouldTerminate` to flush buffers and stop capture
///   before allowing the process to exit.
/// - Forwarding system sleep / wake notifications to `AppLifecycle`.
@MainActor
final class KerwanAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "AppDelegate"
    )

    // MARK: - Owned services

    /// The observable root state consumed by all SwiftUI views.
    let appState = AppState()

    /// The service lifecycle coordinator.
    let lifecycle = AppLifecycle()

    /// Keychain manager for retrieving the database passphrase at startup.
    private let keychain = KeychainManager(service: "com.kerwan.app")

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Kerwan is a menu-bar-only app by default. The Dock icon and main
        // window are hidden until the user explicitly opens the main window
        // via the menu bar button or ⌘0.
        NSApp.setActivationPolicy(.accessory)

        // Register for system sleep / wake so we can pause audio capture.
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        wsCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // Kick off the async startup sequence. This is the authoritative
        // location for service init — using applicationDidFinishLaunching
        // avoids running startup logic in an ephemeral view .task, which
        // would re-fire every time a .menu-style MenuBarExtra is opened.
        let appState = appState
        let lifecycle = lifecycle
        let keychain = keychain
        Task {
            // Inject concrete storage / capture implementations here as
            // those workstreams land:
            //   await lifecycle.inject(storage: ..., capture: ...)
            await lifecycle.start(appState: appState, keychain: keychain)
        }

        Self.logger.info("Application did finish launching")
    }

    // MARK: - Quit

    /// Intercepts the quit request to perform async cleanup before the process exits.
    ///
    /// Returns `.terminateLater` and calls
    /// `NSApp.reply(toApplicationShouldTerminate: true)` once the async shutdown
    /// completes, ensuring the ring buffer is flushed and capture is stopped cleanly.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.logger.info("Application should terminate — beginning async shutdown")
        let appState = appState
        let lifecycle = lifecycle
        Task {
            await lifecycle.shutdown(appState: appState)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.logger.info("Application will terminate")
    }

    // MARK: - Window policy

    /// When the user clicks the (hidden) Dock icon, open the main window
    /// rather than doing nothing.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            openMainWindow()
        }
        return true
    }

    // MARK: - Sleep / Wake

    @objc private func systemWillSleep(_ notification: Notification) {
        Self.logger.info("System will sleep — pausing audio capture")
        let appState = appState
        let lifecycle = lifecycle
        Task {
            await lifecycle.pauseAudioCapture(appState: appState)
        }
    }

    @objc private func systemDidWake(_ notification: Notification) {
        Self.logger.info("System did wake — resuming audio capture")
        let appState = appState
        let lifecycle = lifecycle
        Task {
            await lifecycle.resumeAudioCapture(appState: appState)
        }
    }

    // MARK: - Window management

    /// Switches the activation policy to `.regular` and brings the main window
    /// to the front. Called by the "Open Kerwan" menu item and ⌘0.
    func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // The main window may not exist yet (lazy scene creation on first open).
        // Posting this notification lets the SwiftUI layer open it via openWindow.
        NotificationCenter.default.post(
            name: .kerwanOpenMainWindow,
            object: nil
        )
        Self.logger.info("Main window open requested")
    }

    /// Reverts to accessory policy when the main window is closed, hiding the
    /// Dock icon again.
    func mainWindowDidClose() {
        // Only hide the Dock icon if there are no other visible windows.
        let visibleWindows = NSApp.windows.filter {
            $0.isVisible && !$0.className.contains("MenuBar")
        }
        if visibleWindows.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted by `KerwanAppDelegate.openMainWindow()` when the SwiftUI layer
    /// must open (or focus) the main timeline window.
    static let kerwanOpenMainWindow = Notification.Name("com.kerwan.app.openMainWindow")
}
