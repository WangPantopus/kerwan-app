import SwiftUI
import os

/// The menu bar dropdown view providing quick status and controls.
struct MenuBarView: View {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "MenuBarView"
    )

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status section
            statusItem(
                "Capture",
                isActive: appState.isCaptureActive,
                detail: appState.isCaptureActive ? "Recording" : "Paused"
            )

            statusItem(
                "Whisper",
                isActive: appState.isWhisperServiceConnected,
                detail: appState.isModelLoaded ? "Model loaded" : "No model"
            )

            statusItem(
                "Ollama",
                isActive: appState.isOllamaRunning,
                detail: appState.isOllamaRunning ? "Running" : "Stopped"
            )

            Divider()

            // Today's stats
            if appState.todaySessionCount > 0 {
                Text("\(appState.todaySessionCount) sessions today (\(formattedMinutes))")
                    .font(.caption)

                Divider()
            }

            // Actions
            Button(appState.isCaptureActive ? "Pause Capture" : "Resume Capture") {
                appState.isCaptureActive.toggle()
                Self.logger.info("Capture toggled to \(appState.isCaptureActive)")
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Divider()

            Button("Open Kerwan") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                if let window = NSApplication.shared.windows.first {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            .keyboardShortcut("o", modifiers: [.command])

            Divider()

            Button("Quit Kerwan") {
                Self.logger.info("User initiated quit from menu bar")
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
    }

    private func statusItem(_ name: String, isActive: Bool, detail: String) -> some View {
        HStack {
            Image(systemName: isActive ? "circle.fill" : "circle")
                .foregroundStyle(isActive ? .green : .secondary)
                .font(.caption2)
            Text(name)
            Spacer()
            Text(detail)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var formattedMinutes: String {
        let minutes = Int(appState.todayCapturedMinutes)
        if minutes < 60 {
            return "\(minutes) min"
        }
        let hours = minutes / 60
        let remaining = minutes % 60
        return "\(hours)h \(remaining)m"
    }
}
