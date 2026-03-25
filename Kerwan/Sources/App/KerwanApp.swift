import SwiftUI
import os

/// The main entry point for the Kerwan application.
///
/// Kerwan uses a dual-interface approach:
/// - A **menu bar extra** that is always visible for quick access and status display.
/// - A **main window** for timeline browsing, session review, and settings.
@main
struct KerwanApp: App {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "App"
    )

    @State private var appState = AppState()

    /// UserDefaults key managed by `CrashRecoveryManager` in `KerwanStorage`.
    /// Duplicated here so the app target can arm/clear the flag without importing KerwanStorage.
    private static let dirtyShutdownKey = "com.kerwan.app.dirtyShutdown"

    init() {
        // Arm the dirty-shutdown flag as early as possible so that if the
        // process is killed before the window appears we detect it next launch.
        UserDefaults.standard.set(true, forKey: Self.dirtyShutdownKey)
        Self.logger.info("Dirty-shutdown flag armed.")
    }

    var body: some Scene {
        // Main application window for timeline and settings
        WindowGroup("Kerwan") {
            ContentView()
                .environment(appState)
                .frame(minWidth: 800, minHeight: 600)
                .onAppear {
                    Self.logger.info("Main window appeared")
                }
        }
        .defaultSize(width: 1100, height: 750)
        .commands {
            // Clean-quit path: clear the dirty-shutdown flag before the process exits.
            CommandGroup(replacing: .appTermination) {
                Button("Quit Kerwan") {
                    UserDefaults.standard.removeObject(forKey: Self.dirtyShutdownKey)
                    Self.logger.info("Dirty-shutdown flag cleared on clean quit.")
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }

        // Persistent menu bar presence
        MenuBarExtra("Kerwan", systemImage: "clock.badge.checkmark") {
            MenuBarView()
                .environment(appState)
        }
        .menuBarExtraStyle(.menu)
    }
}
