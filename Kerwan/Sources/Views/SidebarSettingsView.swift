import SwiftUI
import os

/// An in-window settings summary accessible from the sidebar "Settings" item.
///
/// Shows key service statuses and quick-access toggles inline in the main
/// window, with a button to open the full settings panel (⌘,). This view is
/// distinct from `KerwanSettingsView` which is the `Settings` scene content.
@MainActor
struct SidebarSettingsView: View {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "SidebarSettingsView"
    )

    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                serviceStatusSection
                quickActionsSection
            }
            .padding(24)
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Open Full Settings…") {
                    NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    // MARK: - Service status

    private var serviceStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Service Status")
                .font(.headline)

            VStack(spacing: 0) {
                ServiceStatusRow(
                    name: "Capture",
                    detail: appState.captureStatus.description,
                    isConnected: appState.captureStatus.isActive,
                    icon: "mic"
                )
                Divider().padding(.leading, 44)

                ServiceStatusRow(
                    name: "WhisperService",
                    detail: appState.isModelLoaded ? "Model loaded" : "No model",
                    isConnected: appState.isWhisperServiceConnected,
                    icon: "waveform"
                )
                Divider().padding(.leading, 44)

                ServiceStatusRow(
                    name: "Ollama",
                    detail: appState.isOllamaRunning ? "Running" : "Stopped",
                    isConnected: appState.isOllamaRunning,
                    icon: "server.rack"
                )
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
            )
        }
    }

    // MARK: - Quick actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Actions")
                .font(.headline)

            VStack(spacing: 8) {
                Button("Open Full Settings…") {
                    NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .buttonStyle(.borderless)
                .controlSize(.regular)
            }
        }
    }
}

// MARK: - ServiceStatusRow

private struct ServiceStatusRow: View {
    let name: String
    let detail: String
    let isConnected: Bool
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .padding(.leading, 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 4) {
                Circle()
                    .fill(isConnected ? Color.green : Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 7, height: 7)
                Text(isConnected ? "On" : "Off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.trailing, 12)
        }
        .padding(.vertical, 10)
    }
}
