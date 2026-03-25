import SwiftUI
import os

/// The native Settings window content (⌘,).
///
/// Hosts six tabbed preference panels. Each tab delegates to a dedicated
/// view in `Kerwan/Sources/Settings/`. All persistent changes are funnelled
/// through `SettingsViewModel`, which writes to the storage layer via the
/// `SettingsStorageService` protocol.
struct KerwanSettingsView: View {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "KerwanSettingsView"
    )

    @Environment(AppState.self) private var appState

    /// Shared view model. Injected with a nil storage service until the app
    /// provides a concrete `StorageActor` adapter; tabs gracefully no-op when
    /// storage is absent.
    @State private var vm = SettingsViewModel()

    var body: some View {
        TabView {
            GeneralSettingsTab(vm: vm)
                .tabItem { Label("General", systemImage: "gear") }

            PermissionsSettingsTab(vm: vm)
                .tabItem { Label("Permissions", systemImage: "checkmark.shield") }

            EmailSettingsTab(vm: vm)
                .tabItem { Label("Email", systemImage: "envelope") }

            ExclusionsSettingsTab(vm: vm)
                .tabItem { Label("Exclusions", systemImage: "hand.raised") }

            DataSettingsTab(vm: vm)
                .tabItem { Label("Data", systemImage: "externaldrive") }

            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 480)
        .task {
            await vm.onAppear()
        }
        // Surface any storage errors to the user as an overlay alert.
        .alert(
            "Settings Error",
            isPresented: Binding(
                get: { vm.lastError != nil },
                set: { if !$0 { vm.lastError = nil } }
            )
        ) {
            Button("OK") { vm.lastError = nil }
        } message: {
            Text(vm.lastError ?? "")
        }
    }
}

// MARK: - ConnectionStatusBadge (retained for backwards compat)

/// A small coloured badge showing connection status.
/// Used by the retained Capture/Services display inside the main window's
/// `SidebarSettingsView` and anywhere else that needs a quick status dot.
struct ConnectionStatusBadge: View {
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
