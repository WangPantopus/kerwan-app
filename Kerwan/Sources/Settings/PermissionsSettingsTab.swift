import SwiftUI

/// Permissions tab — shows the status of each required system permission and
/// provides deep-link buttons to the relevant System Settings pane.
///
/// Statuses are refreshed once on appear and then every 5 seconds while the
/// tab is visible, so the user sees an update as soon as they return from
/// granting permission in System Settings.
struct PermissionsSettingsTab: View {
    @Bindable var vm: SettingsViewModel

    var body: some View {
        Form {
            Section {
                ForEach(KerwanPermission.allCases, id: \.self) { permission in
                    PermissionRow(
                        permission: permission,
                        status: vm.permissionStatuses[permission] ?? .unknown
                    )
                }
            } footer: {
                Text("Kerwan only requests permissions that are enabled in General settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            vm.refreshPermissions()
        }
        // Poll every 5 seconds while this tab is visible.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                vm.refreshPermissions()
            }
        }
    }
}

// MARK: - PermissionRow

private struct PermissionRow: View {
    let permission: KerwanPermission
    let status: PermissionStatus

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                // Status badge
                Label(status.label, systemImage: status.systemImage)
                    .foregroundStyle(status.color)
                    .font(.subheadline)
                    .labelStyle(.titleAndIcon)

                // Open System Settings button — only useful when not granted.
                if status != .granted {
                    Button("Open Settings…") {
                        NSWorkspace.shared.open(permission.settingsURL)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
            }
        } label: {
            Label(permission.title, systemImage: permission.systemImage)
        }
        .help(permission.permissionDescription)
    }
}

// MARK: - PermissionStatus Equatable (needed for != .granted check)

extension PermissionStatus: Equatable {}
