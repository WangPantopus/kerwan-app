import SwiftUI
import os

/// The dropdown menu presented by the Kerwan menu bar extra.
///
/// Rendered with `.menuBarExtraStyle(.menu)` so every top-level element maps to
/// a native macOS menu item — no custom chrome needed. The view drives all
/// quick-access controls: capture toggle, private mode, quick note, and
/// navigation shortcuts to the main window, global search, and settings.
struct MenuBarView: View {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "MenuBarView"
    )

    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    /// The `AppLifecycle` actor used to dispatch capture-control actions.
    let lifecycle: AppLifecycle

    var body: some View {
        // MARK: Status line
        statusRow

        Divider()

        // MARK: Stats
        Text(eventCountLabel)
            .foregroundStyle(.secondary)

        Divider()

        // MARK: Capture controls
        captureToggle
        privateModeToggle

        Divider()

        // MARK: Quick actions
        Button("Quick Note…") {
            openWindow(id: "quick-note")
            Self.logger.info("Quick note window opened")
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])

        Divider()

        // MARK: Navigation
        Button("Open Kerwan") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
            Self.logger.info("Main window opened from menu bar")
        }
        .keyboardShortcut("0", modifiers: .command)

        Button("Search…") {
            openWindow(id: "search")
            Self.logger.info("Global search opened from menu bar")
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])

        Divider()

        // MARK: App
        Button("Settings…") {
            openSettings()
            Self.logger.info("Settings window opened from menu bar")
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Quit Kerwan") {
            Self.logger.info("Quit initiated from menu bar")
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Status Row

    /// A non-interactive status indicator showing the current capture mode with a
    /// coloured dot. Not a `Button` so it appears greyed-out / non-clickable like
    /// native macOS status menu headers.
    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(appState.captureStatus.description)
                .fontWeight(.medium)
            if let error = appState.lastError {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(error)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Capture Toggle

    private var captureToggle: some View {
        Button(captureToggleLabel) {
            let lifecycle = lifecycle
            let appState = appState
            Task {
                await lifecycle.toggleCapture(appState: appState)
            }
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(appState.captureStatus == .privateMode)
    }

    // MARK: - Private Mode Toggle

    private var privateModeToggle: some View {
        Button(appState.captureStatus == .privateMode
               ? "Disable Private Mode"
               : "Enable Private Mode") {
            let lifecycle = lifecycle
            let appState = appState
            if appState.captureStatus == .privateMode {
                Task { await lifecycle.disablePrivateMode(appState: appState) }
            } else {
                Task { await lifecycle.enablePrivateMode(appState: appState) }
            }
        }
    }

    // MARK: - Helpers

    /// The coloured dot next to the status label.
    private var statusColor: Color {
        switch appState.captureStatus {
        case .capturing:   return .green
        case .paused:      return .yellow
        case .privateMode: return .red
        case .idle:        return .secondary
        case .error:       return .orange
        }
    }

    /// The capture toggle button label.
    private var captureToggleLabel: String {
        switch appState.captureStatus {
        case .capturing:            return "Pause Capture"
        case .paused, .idle:        return "Resume Capture"
        case .privateMode:          return "Pause Capture"   // disabled; see above
        case .error:                return "Retry Capture"
        }
    }

    /// Formatted events-today count, e.g. "1,247 events today".
    private var eventCountLabel: String {
        let formatted = NumberFormatter.localizedString(
            from: NSNumber(value: appState.eventsToday),
            number: .decimal
        )
        return "\(formatted) events today"
    }
}
