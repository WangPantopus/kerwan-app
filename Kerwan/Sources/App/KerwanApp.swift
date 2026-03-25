import SwiftUI
import os

/// The main entry point for the Kerwan application.
///
/// Kerwan uses a dual-interface pattern:
/// - A **menu bar extra** that is always visible for quick status and controls.
/// - A **main window** for timeline, session review, and client management.
///   The main window is hidden on launch; the user opens it via the menu bar
///   or ⌘0.
///
/// All service ownership and startup logic lives in `KerwanAppDelegate` (via
/// `@NSApplicationDelegateAdaptor`) so that `AppState`, `AppLifecycle`, and
/// `KeychainManager` are initialised in `applicationDidFinishLaunching` —
/// a single, stable location that is not tied to any view lifecycle.
///
/// Scene graph:
/// ```
/// KerwanApp
/// ├── WindowGroup("main")        — timeline / session / client window
/// ├── WindowGroup("quick-note")  — floating note-entry panel
/// ├── WindowGroup("search")      — global search overlay
/// ├── Settings                   — native settings window (⌘,)
/// └── MenuBarExtra               — status icon + dropdown menu
/// ```
@main
struct KerwanApp: App {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "KerwanApp"
    )

    @NSApplicationDelegateAdaptor(KerwanAppDelegate.self) private var appDelegate

    // MARK: - Scene graph

    var body: some Scene {

        // MARK: Main Timeline Window

        WindowGroup(id: "main") {
            ContentView()
                .environment(appDelegate.appState)
                .frame(minWidth: 820, minHeight: 560)
                .onReceive(
                    NotificationCenter.default.publisher(for: .kerwanOpenMainWindow)
                ) { _ in
                    // Delegate posted this after switching activation policy.
                    // Bring all visible windows to front.
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onDisappear {
                    // Revert to accessory (no Dock icon) when the main window closes.
                    appDelegate.mainWindowDidClose()
                }
        }
        .defaultSize(width: 1100, height: 750)
        .commands {
            // Remove File > New (⌘N) — Kerwan has no document model.
            CommandGroup(replacing: .newItem) {}

            // ⌘0 — open / focus the main window from anywhere.
            CommandGroup(after: .windowList) {
                Button("Open Kerwan") {
                    appDelegate.openMainWindow()
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        // MARK: Quick Note Window
        // Opens via "Quick Note…" in the menu bar (⌘⇧N).
        // Uses .hiddenTitleBar for a compact, focused feel.

        WindowGroup(id: "quick-note") {
            QuickNoteView(lifecycle: appDelegate.lifecycle)
                .environment(appDelegate.appState)
                .fixedSize()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 440, height: 144)
        .windowStyle(.hiddenTitleBar)

        // MARK: Global Search Window
        // Opens via "Search…" in the menu bar (⌘⇧R).

        WindowGroup(id: "search") {
            GlobalSearchView()
                .environment(appDelegate.appState)
                .frame(minWidth: 600, minHeight: 420)
        }
        .defaultSize(width: 700, height: 480)

        // MARK: Settings Window
        // Standard macOS Settings scene; opened via ⌘, or "Settings…" button.

        Settings {
            KerwanSettingsView()
                .environment(appDelegate.appState)
        }

        // MARK: Menu Bar Extra
        // Always present. Startup is driven from KerwanAppDelegate, not here,
        // because .menu-style MenuBarExtra content is ephemeral (recreated on
        // every open) and cannot safely host a one-shot .task.

        MenuBarExtra {
            MenuBarView(lifecycle: appDelegate.lifecycle)
                .environment(appDelegate.appState)
        } label: {
            MenuBarIconLabel()
                .environment(appDelegate.appState)
        }
    }
}
