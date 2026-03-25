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

        // Persistent menu bar presence
        MenuBarExtra("Kerwan", systemImage: "clock.badge.checkmark") {
            MenuBarView()
                .environment(appState)
        }
        .menuBarExtraStyle(.menu)
    }
}
