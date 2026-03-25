import SwiftUI

/// Email Accounts tab — lists connected accounts with sync status and
/// provides a button to connect a Gmail account via OAuth.
@MainActor
struct EmailSettingsTab: View {
    @Bindable var vm: SettingsViewModel

    var body: some View {
        Form {
            if vm.emailAccounts.isEmpty {
                emptySection
            } else {
                accountsSection
            }

            connectSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Empty state

    private var emptySection: some View {
        Section {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "envelope.badge.shield.half.filled")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No accounts connected")
                        .foregroundStyle(.secondary)
                    Text("Connect an account to correlate emails with work sessions.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 16)
                Spacer()
            }
        }
    }

    // MARK: - Accounts list

    private var accountsSection: some View {
        Section("Connected Accounts") {
            ForEach(vm.emailAccounts) { account in
                AccountRow(account: account) {
                    vm.disconnectAccount(account)
                }
            }
        }
    }

    // MARK: - Connect

    private var connectSection: some View {
        Section {
            Button {
                vm.connectGmail()
            } label: {
                Label("Connect Gmail…", systemImage: "envelope")
            }
        } footer: {
            Text("Only metadata (subject, sender, timestamp) is indexed locally. Email body content is never stored.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - AccountRow

private struct AccountRow: View {
    let account: EmailAccount
    let onDisconnect: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                syncStatusBadge
                Button("Disconnect") {
                    onDisconnect()
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.address)
                if let lastSync = account.lastSyncAt {
                    Text("Last synced \(lastSync, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Never synced")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var syncStatusBadge: some View {
        switch account.status {
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .syncing:
            Label("Syncing…", systemImage: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill")
                .foregroundStyle(.blue)
                .font(.caption)
        case .error:
            Label("Error", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        case .disconnected:
            Label("Disconnected", systemImage: "minus.circle.fill")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}
