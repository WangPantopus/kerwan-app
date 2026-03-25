import SwiftUI

/// About tab — app version and build number, license status, update check,
/// and links to website, privacy policy, and support.
struct AboutSettingsTab: View {
    @State private var isCheckingForUpdates: Bool = false
    @State private var updateCheckResult: String? = nil

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        Form {
            appInfoSection
            updateSection
            linksSection
        }
        .formStyle(.grouped)
    }

    // MARK: - App info

    private var appInfoSection: some View {
        Section {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Kerwan")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Version \(appVersion) (\(buildNumber))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Local-first professional activity intelligence")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)

            LabeledContent("License") {
                Text("Personal License")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Update

    private var updateSection: some View {
        Section("Updates") {
            HStack {
                Button {
                    checkForUpdates()
                } label: {
                    if isCheckingForUpdates {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Checking…")
                        }
                    } else {
                        Text("Check for Updates")
                    }
                }
                .disabled(isCheckingForUpdates)

                if let result = updateCheckResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Links

    private var linksSection: some View {
        Section("Resources") {
            LinkRow(title: "Website", systemImage: "safari", urlString: "https://kerwan.app")
            LinkRow(title: "Privacy Policy", systemImage: "hand.raised", urlString: "https://kerwan.app/privacy")
            LinkRow(title: "Support", systemImage: "questionmark.circle", urlString: "https://kerwan.app/support")
        }
    }

    // MARK: - Actions

    private func checkForUpdates() {
        isCheckingForUpdates = true
        updateCheckResult = nil
        // Full implementation: Sparkle or custom update check.
        Task {
            try? await Task.sleep(for: .seconds(1))
            isCheckingForUpdates = false
            updateCheckResult = "Kerwan is up to date."
        }
    }
}

// MARK: - LinkRow

private struct LinkRow: View {
    let title: String
    let systemImage: String
    let urlString: String

    var body: some View {
        Button {
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.link)
    }
}
