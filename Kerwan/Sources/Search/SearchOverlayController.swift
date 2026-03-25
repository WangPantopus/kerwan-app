import AppKit
import SwiftUI
import os

// MARK: - SearchOverlayState

/// Shared observable state between `SearchOverlayController` and
/// `SearchOverlayView`. Owned by the controller; passed to the hosted view.
@Observable
@MainActor
final class SearchOverlayState {
    /// Live query text — drives the 300 ms debounce in the view.
    var query: String = ""
    /// Whether the animated-in scale / opacity transition is active.
    var isAnimatedIn: Bool = false
    /// Currently keyboard-highlighted result index, or nil for none.
    var selectedIndex: Int? = nil

    // MARK: - Keyboard navigation helpers

    func moveUp(resultCount: Int) {
        guard resultCount > 0 else { return }
        switch selectedIndex {
        case .none:          selectedIndex = resultCount - 1
        case .some(let i):   selectedIndex = max(0, i - 1)
        }
    }

    func moveDown(resultCount: Int) {
        guard resultCount > 0 else { return }
        switch selectedIndex {
        case .none:          selectedIndex = 0
        case .some(let i):   selectedIndex = min(resultCount - 1, i + 1)
        }
    }

    func reset() {
        query = ""
        selectedIndex = nil
        isAnimatedIn = false
    }
}

// MARK: - SearchOverlayController

/// Owns the `SearchOverlayWindow`, manages the global / local ⌘⇧R hotkey
/// monitors, and drives the show / hide animation lifecycle.
///
/// **Hotkey behaviour:**
/// - A *global* `NSEvent` monitor fires ⌘⇧R from any app (requires the user to
///   have granted Input Monitoring permission; silently no-ops if denied).
/// - A *local* `NSEvent` monitor fires ⌘⇧R when Kerwan itself is focused.
///
/// **Dismiss triggers:**
/// - Pressing Escape inside the overlay.
/// - Pressing ⌘⇧R again (toggle).
/// - Clicking outside the overlay (`windowDidResignKey` delegate callback).
///
/// **Animation:**
/// The overlay fades + scales from 0.95 → 1.0 over ~220 ms on show, and
/// reverses on hide. The window is only ordered out *after* the hide animation
/// completes so there is no abrupt pop.
@MainActor
final class SearchOverlayController: NSObject {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "SearchOverlayController"
    )

    // MARK: - Owned objects

    let state = SearchOverlayState()
    private var window: SearchOverlayWindow?
    private weak var appState: AppState?

    // MARK: - Event monitors

    /// Global monitor — receives events from other apps (requires Input Monitoring).
    private var globalKeyMonitor: Any?
    /// Local monitor — receives events when Kerwan is focused (no special permission).
    private var localKeyMonitor: Any?

    // MARK: - Lifecycle

    /// Call once from `applicationDidFinishLaunching`.
    func start(appState: AppState) {
        self.appState = appState
        buildWindow(appState: appState)
        registerHotkeyMonitors()
        registerNotificationObservers()
        Self.logger.info("SearchOverlayController started")
    }

    func stop() {
        removeMonitors()
        window?.orderOut(nil)
        window = nil
    }

    // MARK: - Show / Hide

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        guard let window, let appState else { return }
        guard !isVisible else {
            // Already visible — just bring it to the front.
            window.makeKeyAndOrderFront(nil)
            return
        }

        centerOnActiveScreen(window: window)

        // Reset animation state before showing.
        state.isAnimatedIn = false
        state.selectedIndex = nil
        // Preserve query so repeated opens feel snappy.

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Trigger the scale-in animation on the next run-loop pass so SwiftUI
        // has completed its first layout before the transition begins.
        Task { @MainActor in
            state.isAnimatedIn = true
        }

        // Keep AppState in sync.
        appState.isSearching = false
        Self.logger.debug("Search overlay shown")
    }

    func hide() {
        guard isVisible else { return }

        // Trigger the scale-out animation.
        state.isAnimatedIn = false

        // Wait for the animation (≈220 ms) before removing the window.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(230))
            self?.window?.orderOut(nil)
            // Clear transient AppState that was set for this search session.
            self?.appState?.isSearching = false
            self?.appState?.searchResults = []
            self?.state.reset()
            Self.logger.debug("Search overlay hidden")
        }
    }

    // MARK: - Window construction

    private func buildWindow(appState: AppState) {
        let overlayWindow = SearchOverlayWindow()

        // Keyboard callbacks — NSWindow.keyDown is always on the main thread.
        // MainActor.assumeIsolated is safe here because AppKit guarantees it.
        overlayWindow.onEscape  = { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        overlayWindow.onMoveUp  = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.moveUp(resultCount: appState.searchResults.count)
            }
        }
        overlayWindow.onMoveDown = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.moveDown(resultCount: appState.searchResults.count)
            }
        }
        overlayWindow.onConfirm = { [weak self] in
            MainActor.assumeIsolated { self?.openSelected(appState: appState) }
        }

        overlayWindow.delegate = self

        let rootView = SearchOverlayView(state: state, appState: appState) { [weak self] result in
            self?.openResult(result, appState: appState)
        }
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = .intrinsicContentSize
        overlayWindow.contentView = hostingView

        self.window = overlayWindow
    }

    // MARK: - Result opening

    private func openSelected(appState: AppState) {
        guard let idx = state.selectedIndex,
              idx < appState.searchResults.count else {
            if let first = appState.searchResults.first {
                openResult(first, appState: appState)
            }
            return
        }
        openResult(appState.searchResults[idx], appState: appState)
    }

    private func openResult(_ result: SearchResult, appState: AppState) {
        hide()

        // Bring the main window to the front.
        NotificationCenter.default.post(name: .kerwanOpenMainWindow, object: nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Navigate to the appropriate sidebar section.
        switch result.type {
        case .interaction:  appState.selectedSidebarItem = .timeline
        case .workSession:  appState.selectedSidebarItem = .reviewQueue
        case .promise:      appState.selectedSidebarItem = .today
        case .contact:      appState.selectedSidebarItem = .clients
        }

        Self.logger.info("Opened search result: \(result.id, privacy: .public) type=\(result.type.rawValue, privacy: .public)")
    }

    // MARK: - Hotkey monitors

    private static let hotkeyCode: UInt16 = 15  // R key
    private static let hotkeyModifiers: NSEvent.ModifierFlags = [.command, .shift]

    private func registerHotkeyMonitors() {
        // Global monitor: fires when another application is front-most.
        // Requires Input Monitoring permission; silently delivers no events if
        // the permission is not granted.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.matchesHotkey(event) else { return }
            // NSEvent global monitors run on the main thread.
            MainActor.assumeIsolated { self.toggle() }
        }

        // Local monitor: fires when Kerwan itself is the front-most app.
        // Returns a modified copy of the event so we must return nil to
        // consume the event and prevent it reaching any focused text field.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.matchesHotkey(event) else { return event }
            MainActor.assumeIsolated { self.toggle() }
            return nil  // consume the event
        }
    }

    private func removeMonitors() {
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
        if let m = localKeyMonitor  { NSEvent.removeMonitor(m); localKeyMonitor  = nil }
    }

    private func matchesHotkey(_ event: NSEvent) -> Bool {
        guard event.keyCode == Self.hotkeyCode else { return false }
        // Strip capslock / function / numpad bits; require exactly ⌘⇧.
        let relevant = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        return relevant == Self.hotkeyModifiers
    }

    // MARK: - Notification observers

    private func registerNotificationObservers() {
        NotificationCenter.default.addObserver(
            forName: .kerwanShowSearch,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.show()
        }
    }

    // MARK: - Screen centering

    private func centerOnActiveScreen(window: NSWindow) {
        // Prefer the screen with the current keyboard focus / mouse cursor.
        let targetScreen = NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        }) ?? NSScreen.main ?? NSScreen.screens[0]

        let screenFrame = targetScreen.visibleFrame
        let windowFrame = window.frame

        let x = screenFrame.midX - windowFrame.width / 2
        // Position in the upper third of the screen (Spotlight-like placement).
        let y = screenFrame.maxY - screenFrame.height * 0.38 - windowFrame.height / 2

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - NSWindowDelegate

extension SearchOverlayController: NSWindowDelegate {
    /// Dismiss when the overlay loses key window status (user clicked elsewhere
    /// or switched apps via ⌘Tab).
    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { hide() }
    }
}

// MARK: - Notification name

extension Notification.Name {
    /// Post this notification to programmatically show the search overlay.
    /// Used by `MenuBarView`, `ContentView`, and other entry points so they
    /// do not need a direct reference to `SearchOverlayController`.
    static let kerwanShowSearch = Notification.Name("com.kerwan.app.showSearch")
}
