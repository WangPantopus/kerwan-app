import SwiftUI
import os

/// Settings tab for the Chrome Browser Extension integration.
///
/// Lets the user:
/// 1. Enter their Chrome extension ID (needed to install the NMH manifest).
/// 2. Install / uninstall the Native Messaging Host manifest.
/// 3. See live connection status and toggle browser capture on/off.
struct BrowserSettingsTab: View {

    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "BrowserSettingsTab"
    )

    @Environment(AppState.self) private var appState

    @State private var extensionID: String =
        UserDefaults.standard.string(forKey: "browserExtensionID") ?? ""
    @State private var isInstalled: Bool = NativeMessagingInstaller.isInstalled
    @State private var installError: String? = nil
    @State private var showError: Bool = false

    var body: some View {
        Form {
            statusSection
            extensionIDSection
            installSection
            captureSection
        }
        .formStyle(.grouped)
        .alert("Installation Error", isPresented: $showError) {
            Button("OK") { installError = nil }
        } message: {
            Text(installError ?? "")
        }
        .onAppear {
            isInstalled = NativeMessagingInstaller.isInstalled
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            HStack {
                Text("Extension status")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.isBrowserExtensionConnected ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(appState.isBrowserExtensionConnected ? "Connected" : "Disconnected")
                        .foregroundStyle(
                            appState.isBrowserExtensionConnected ? .primary : .secondary
                        )
                }
            }
        } header: {
            Text("Status")
        } footer: {
            Text(
                appState.isBrowserExtensionConnected
                    ? "Kerwan is receiving browser context from Chrome."
                    : "Install the Chrome extension and configure the NMH to connect."
            )
            .font(.caption)
        }
    }

    // MARK: - Extension ID

    private var extensionIDSection: some View {
        Section {
            HStack {
                Text("Extension ID")
                    .frame(width: 110, alignment: .leading)
                TextField(
                    "e.g. abcdefghijklmnopqrstuvwxyzabcdef",
                    text: $extensionID
                )
                .font(.system(.body, design: .monospaced))
                .onChange(of: extensionID) { _, id in
                    let trimmed = id.trimmingCharacters(in: .whitespaces)
                    UserDefaults.standard.set(trimmed, forKey: "browserExtensionID")
                }
            }
        } header: {
            Text("Chrome Extension")
        } footer: {
            Text(
                "Open chrome://extensions, enable Developer mode, and copy the extension ID. " +
                "This is required before installing the Native Messaging Host."
            )
            .font(.caption)
        }
    }

    // MARK: - Install / Uninstall

    private var installSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Native Messaging Host")
                    Text(isInstalled ? "Manifest installed" : "Not installed")
                        .font(.caption)
                        .foregroundStyle(isInstalled ? .green : .secondary)
                }
                Spacer()
                if isInstalled {
                    Button("Uninstall", role: .destructive) {
                        NativeMessagingInstaller.uninstall()
                        isInstalled = false
                        Self.logger.info("NMH manifest uninstalled by user")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                } else {
                    Button("Install") {
                        installNMH()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(extensionID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } footer: {
            Text(
                "Installing writes com.kerwan.app.json to ~/Library/Application Support/Google/Chrome/NativeMessagingHosts/. " +
                "You must reinstall if you change the extension ID."
            )
            .font(.caption)
        }
    }

    // MARK: - Capture toggle

    @MainActor
    private var captureSection: some View {
        Section {
            @Bindable var appState = appState
            Toggle("Capture browser context", isOn: $appState.browserCaptureEnabled)
        } header: {
            Text("Capture")
        } footer: {
            Text("When enabled, LinkedIn profiles and Gmail threads you view are sent to Kerwan for relationship intelligence.")
                .font(.caption)
        }
    }

    // MARK: - Helpers

    private func installNMH() {
        let id = extensionID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        do {
            try NativeMessagingInstaller.install(extensionID: id)
            isInstalled = true
            Self.logger.info("NMH manifest installed for extension \(id, privacy: .public)")
        } catch {
            installError = error.localizedDescription
            showError = true
            Self.logger.error("NMH install failed: \(error, privacy: .public)")
        }
    }
}
