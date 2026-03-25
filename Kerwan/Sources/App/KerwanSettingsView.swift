import SwiftUI
import os

/// The native Settings window content (⌘,).
///
/// Hosts tabbed preferences panels. Full implementation is in the settings
/// workstream; this file defines the tab scaffold and capture-related toggles
/// which interact directly with `AppState` and the capture controls.
struct KerwanSettingsView: View {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "KerwanSettingsView"
    )

    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            CaptureSettingsTab()
                .tabItem { Label("Capture", systemImage: "waveform") }
                .environment(appState)

            PrivacySettingsTab()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
                .environment(appState)

            BillingSettingsTab()
                .tabItem { Label("Billing", systemImage: "dollarsign.circle") }
                .environment(appState)

            ServicesSettingsTab()
                .tabItem { Label("Services", systemImage: "server.rack") }
                .environment(appState)
        }
        .frame(width: 540, height: 380)
    }
}

// MARK: - Capture tab

private struct CaptureSettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Audio") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appState.captureStatus.isActive ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(appState.captureStatus.description)
                    }
                }
                LabeledContent("Transcription Model") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appState.isModelLoaded ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(appState.isModelLoaded ? "Loaded" : "Not loaded")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Integrations") {
                LabeledContent("WhisperService XPC") {
                    ConnectionStatusBadge(connected: appState.isWhisperServiceConnected)
                }
                LabeledContent("Ollama") {
                    ConnectionStatusBadge(connected: appState.isOllamaRunning)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Privacy tab

private struct PrivacySettingsTab: View {
    var body: some View {
        PlaceholderDetailView(
            title: "Privacy",
            description: "Exclusion rules, data retention, and private mode settings.",
            systemImage: "hand.raised"
        )
    }
}

// MARK: - Billing tab

private struct BillingSettingsTab: View {
    var body: some View {
        PlaceholderDetailView(
            title: "Billing",
            description: "Default hourly rates, invoice prefixes, and currency preferences.",
            systemImage: "dollarsign.circle"
        )
    }
}

// MARK: - Services tab

private struct ServicesSettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("AI Services") {
                LabeledContent("Ollama") {
                    ConnectionStatusBadge(connected: appState.isOllamaRunning)
                }
                LabeledContent("WhisperService") {
                    ConnectionStatusBadge(connected: appState.isWhisperServiceConnected)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Shared components

/// A small coloured badge showing connection status.
private struct ConnectionStatusBadge: View {
    let connected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(connected ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(connected ? "Connected" : "Disconnected")
                .foregroundStyle(connected ? .primary : .secondary)
        }
    }
}
