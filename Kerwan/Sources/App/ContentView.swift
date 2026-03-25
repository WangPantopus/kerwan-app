import SwiftUI
import os

/// The main application window.
///
/// Renders a `NavigationSplitView` with a fixed sidebar column and a detail
/// column that hosts a `NavigationStack` for each section. The stack is reset
/// when the sidebar selection changes so sections never "remember" deep
/// navigation from a previous visit.
///
/// Sidebar selection is persisted via `@SceneStorage` (survives window
/// close/reopen within the same session and across restarts). Window frame
/// persistence is handled automatically by macOS `NSWindow`.
///
/// Programmatic navigation from outside this view (e.g. from a menu bar button)
/// is achieved by writing to `AppState.selectedSidebarItem`; this view observes
/// that property via `onChange` and syncs it to `@SceneStorage`.
struct ContentView: View {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "ContentView"
    )

    @Environment(AppState.self) private var appState

    // MARK: - Persisted state

    /// Raw string representation of the selected `SidebarItem`, persisted per
    /// scene so the same section is visible the next time the window is opened.
    @SceneStorage("mainWindow.sidebar") private var selectedItemRaw: String =
        SidebarItem.today.rawValue

    // MARK: - Ephemeral view state

    /// The detail-column navigation stack. Reset to empty when the sidebar
    /// selection changes so each section always starts at its root.
    @State private var detailNavPath = NavigationPath()

    /// Live search text bound to the native toolbar search field.
    @State private var searchText: String = ""

    /// Whether to present the New Client sheet.
    @State private var isPresentingNewClient: Bool = false

    // MARK: - Derived

    private var selectedItem: SidebarItem {
        SidebarItem(rawValue: selectedItemRaw) ?? .today
    }

    // MARK: - Body

    var body: some View {
        NavigationSplitView {
            sidebarColumn
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detailColumn
        }
        // Native toolbar search field. On submit, open the search window.
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: "Search Kerwan…"
        )
        .onSubmit(of: .search) {
            appState.searchQuery = searchText
            NotificationCenter.default.post(name: .kerwanShowSearch, object: nil)
        }
        .onChange(of: searchText) { _, text in
            appState.searchQuery = text
        }
        // Sync AppState → SceneStorage for programmatic navigation.
        .onChange(of: appState.selectedSidebarItem) { _, item in
            guard let item, item.rawValue != selectedItemRaw else { return }
            selectedItemRaw = item.rawValue
            Self.logger.debug("Sidebar selection driven by AppState: \(item.rawValue, privacy: .public)")
        }
        // Reset the detail navigation stack whenever the section changes.
        .onChange(of: selectedItemRaw) { _, _ in
            detailNavPath = NavigationPath()
        }
        .toolbar { toolbarContent }
        // Minimum window dimensions enforced here; defaultSize is set in KerwanApp.
        .frame(minWidth: 900, minHeight: 600)
        // Handle notification-driven navigation.
        .onReceive(NotificationCenter.default.publisher(for: .kerwanShowToday)) { _ in
            selectedItemRaw = SidebarItem.today.rawValue
        }
        .onReceive(NotificationCenter.default.publisher(for: .kerwanShowReviewQueue)) { _ in
            selectedItemRaw = SidebarItem.reviewQueue.rawValue
        }
        // Hidden keyboard-shortcut buttons (⌘1 – ⌘6) for sidebar sections.
        .background(keyboardShortcutLayer)
        .sheet(isPresented: $isPresentingNewClient) {
            NewClientSheet(isPresented: $isPresentingNewClient)
                .environment(appState)
        }
    }

    // MARK: - Sidebar column

    private var sidebarColumn: some View {
        List(selection: sidebarBinding) {
            ForEach(SidebarItem.allCases) { item in
                sidebarRow(for: item)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Kerwan")
        // Capture status footer — shown below the list, pinned to the bottom.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            captureStatusFooter
        }
    }

    /// A single sidebar row with label, optional badge, and correct accessibility label.
    @ViewBuilder
    private func sidebarRow(for item: SidebarItem) -> some View {
        switch item {
        case .reviewQueue:
            Label(item.title, systemImage: item.systemImage)
                .badge(appState.pendingReviewCount)
                .accessibilityLabel(
                    appState.pendingReviewCount > 0
                        ? "\(item.title), \(appState.pendingReviewCount) pending"
                        : item.title
                )
        case .billing:
            Label(item.title, systemImage: item.systemImage)
                .badge(billingBadgeText)
                .accessibilityLabel(billingAccessibilityLabel)
        default:
            Label(item.title, systemImage: item.systemImage)
        }
    }

    // MARK: - Detail column

    private var detailColumn: some View {
        NavigationStack(path: $detailNavPath) {
            // Root content switches per selected section.
            Group {
                switch selectedItem {
                case .today:       TodayView()
                case .clients:     ClientListView()
                case .reviewQueue: ReviewQueueView()
                case .billing:     BillingView()
                case .timeline:    TimelineView()
                case .settings:    SidebarSettingsView()
                }
            }
            // Navigation destinations registered once at the stack root so
            // they are reachable from any depth within the current section.
            .navigationDestination(for: Client.self) { client in
                ClientDetailView(client: client)
            }
            .navigationDestination(for: Contact.self) { contact in
                ContactProfileView(contact: contact)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Capture-status dot — leftmost, quick visual pulse.
        ToolbarItem(placement: .automatic) {
            CaptureStatusToolbarDot()
                .environment(appState)
        }

        // New Client — rightmost primary action.
        ToolbarItem(placement: .primaryAction) {
            Button {
                isPresentingNewClient = true
            } label: {
                Label("New Client", systemImage: "plus")
            }
            .help("Add a new client (⌘N)")
            .keyboardShortcut("n", modifiers: .command)
        }
    }

    // MARK: - Sidebar footer

    private var captureStatusFooter: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(captureStatusColor)
                .frame(width: 7, height: 7)
            Text(appState.captureStatus.description)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if appState.activeTranscription {
                Image(systemName: "waveform")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Transcribing")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Keyboard shortcuts (⌘1 – ⌘6)

    /// Invisible buttons layered behind the split view to capture global
    /// keyboard shortcuts regardless of which column has keyboard focus.
    private var keyboardShortcutLayer: some View {
        Group {
            ForEach(SidebarItem.allCases) { item in
                Button(item.title) {
                    selectedItemRaw = item.rawValue
                    Self.logger.debug(
                        "⌘\(item.keyEquivalent) → \(item.rawValue, privacy: .public)"
                    )
                }
                .keyboardShortcut(
                    KeyEquivalent(item.keyEquivalent),
                    modifiers: .command
                )
            }
        }
        .frame(width: 0, height: 0)
        .hidden()
    }

    // MARK: - Helpers

    /// A `Binding<SidebarItem?>` wired to `@SceneStorage` so the standard
    /// `List(selection:)` API drives both persistence and `AppState` sync.
    private var sidebarBinding: Binding<SidebarItem?> {
        Binding(
            get: { SidebarItem(rawValue: selectedItemRaw) },
            set: { newValue in
                guard let item = newValue else { return }
                selectedItemRaw = item.rawValue
                appState.selectedSidebarItem = item
            }
        )
    }

    private var captureStatusColor: Color {
        switch appState.captureStatus {
        case .capturing:   return .green
        case .paused:      return .yellow
        case .privateMode: return .red
        case .idle:        return Color(nsColor: .tertiaryLabelColor)
        case .error:       return .orange
        }
    }

    private var billingBadgeText: String? {
        guard appState.unbilledHours > 0 else { return nil }
        let h = appState.unbilledHours
        return h < 10 ? String(format: "%.1fh", h) : "\(Int(h))h"
    }

    private var billingAccessibilityLabel: String {
        if let badge = billingBadgeText {
            return "Billing, \(badge) unbilled"
        }
        return "Billing"
    }
}

// MARK: - CaptureStatusToolbarDot

/// A compact status indicator for the main window toolbar.
/// Shows a colored dot matching the menu bar icon, without any label text.
private struct CaptureStatusToolbarDot: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(appState.captureStatus.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .help("Capture: \(appState.captureStatus.description)")
    }

    private var dotColor: Color {
        switch appState.captureStatus {
        case .capturing:   return .green
        case .paused:      return .yellow
        case .privateMode: return .red
        case .idle:        return Color(nsColor: .tertiaryLabelColor)
        case .error:       return .orange
        }
    }
}

// MARK: - NewClientSheet

/// Minimal sheet for creating a new client record.
/// Full implementation will be provided by the Clients workstream.
private struct NewClientSheet: View {
    @Binding var isPresented: Bool
    @Environment(AppState.self) private var appState
    @State private var clientName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Client")
                .font(.headline)

            TextField("Client name", text: $clientName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    // Full implementation: persist via StorageActor.
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .fixedSize()
    }
}

// MARK: - PlaceholderDetailView (kept for backwards-compat with KerwanSettingsView)

/// Legacy placeholder view. New code should use `EmptyStateView` instead.
struct PlaceholderDetailView: View {
    let title: String
    let description: String
    let systemImage: String

    var body: some View {
        EmptyStateView(
            icon: systemImage,
            title: title,
            subtitle: description
        )
    }
}
