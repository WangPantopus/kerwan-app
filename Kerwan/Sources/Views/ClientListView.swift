import SwiftUI
import os

/// The client roster — a searchable list of all billing clients.
///
/// Tapping a row pushes `ClientDetailView` onto the `NavigationStack` owned by
/// `ContentView`. Contacts discovered via any client are accessible from within
/// the client's detail view.
///
/// Full data loading from `StorageActor` will be wired in by the storage
/// integration workstream. Until then, the view renders an empty state with an
/// invitation to add the first client.
struct ClientListView: View {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "ClientListView"
    )

    @Environment(AppState.self) private var appState

    /// All clients — populated by the storage integration layer.
    /// Placeholder: empty until wired to `StorageActor`.
    @State private var clients: [Client] = []

    /// Local filter text, scoped to this list (not the global search bar).
    @State private var filterText: String = ""

    private var filteredClients: [Client] {
        guard !filterText.isEmpty else { return clients }
        return clients.filter {
            $0.name.localizedCaseInsensitiveContains(filterText) ||
            ($0.domain?.localizedCaseInsensitiveContains(filterText) ?? false)
        }
    }

    var body: some View {
        Group {
            if clients.isEmpty {
                emptyState
            } else {
                clientList
            }
        }
        .navigationTitle("Clients")
        .searchable(text: $filterText, placement: .sidebar, prompt: "Filter clients…")
    }

    // MARK: - Empty state

    private var emptyState: some View {
        EmptyStateView(
            icon: "person.2",
            title: "Getting started",
            subtitle: "Clients will appear here once capture begins. " +
                      "Kerwan automatically suggests clients from your interactions, " +
                      "or you can add them manually."
        )
    }

    // MARK: - Client list

    private var clientList: some View {
        List {
            ForEach(filteredClients) { client in
                NavigationLink(value: client) {
                    ClientRowView(client: client)
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - ClientRowView

/// A single row in the client list showing name, domain, and a relationship
/// indicator derived from recent interaction frequency.
struct ClientRowView: View {
    let client: Client

    var body: some View {
        HStack(spacing: 10) {
            // Client avatar — initials in a colored circle.
            ClientAvatarView(name: client.name, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(client.name)
                    .fontWeight(.medium)
                if let domain = client.domain {
                    Text(domain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - ClientAvatarView

/// A circular avatar showing the first letter of a client's name.
/// The background color is deterministically derived from the name.
struct ClientAvatarView: View {
    let name: String
    let size: CGFloat

    private var initial: String {
        String(name.prefix(1).uppercased())
    }

    private var backgroundColor: Color {
        // Stable color derived from name hash — same name always same color.
        let colors: [Color] = [.blue, .purple, .indigo, .teal, .green, .orange]
        let index = abs(name.hashValue) % colors.count
        return colors[index]
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor.opacity(0.18))
            Text(initial)
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(backgroundColor)
        }
        .frame(width: size, height: size)
    }
}
