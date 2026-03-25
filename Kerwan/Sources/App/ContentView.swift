import SwiftUI
import os

/// The main content view of the Kerwan application.
///
/// Displays a sidebar navigation with sections for Timeline, Sessions,
/// Clients, and Settings. The detail area shows context-specific content.
struct ContentView: View {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "ContentView"
    )

    @Environment(AppState.self) private var appState

    /// The currently selected navigation item.
    @State private var selectedNavItem: NavigationItem? = .timeline

    var body: some View {
        NavigationSplitView {
            List(NavigationItem.allCases, selection: $selectedNavItem) { item in
                Label(item.title, systemImage: item.systemImage)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            detailView
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedNavItem {
        case .timeline:
            TimelineView()
        case .sessions:
            PlaceholderDetailView(
                title: "Sessions",
                description: "Billable session suggestions will appear here.",
                systemImage: "rectangle.stack"
            )
        case .clients:
            PlaceholderDetailView(
                title: "Clients",
                description: "Client profiles and relationship memory will appear here.",
                systemImage: "person.2"
            )
        case .settings:
            PlaceholderDetailView(
                title: "Settings",
                description: "Application preferences and configuration.",
                systemImage: "gear"
            )
        case nil:
            Text("Select an item from the sidebar")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Navigation

/// Sidebar navigation items for the main window.
enum NavigationItem: String, CaseIterable, Identifiable {
    case timeline
    case sessions
    case clients
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timeline: return "Timeline"
        case .sessions: return "Sessions"
        case .clients: return "Clients"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .timeline: return "clock"
        case .sessions: return "rectangle.stack"
        case .clients: return "person.2"
        case .settings: return "gear"
        }
    }
}

// MARK: - Placeholder

/// A placeholder view for sections not yet implemented.
struct PlaceholderDetailView: View {
    let title: String
    let description: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title)
            Text(description)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
