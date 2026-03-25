import SwiftUI
import os

/// Detail view for a single client — shows interactions, contacts, sessions,
/// and open promises associated with the client.
///
/// Navigated to by pushing a `Client` value onto the detail `NavigationStack`
/// in `ContentView`. Back navigation is provided by the automatic toolbar
/// back button rendered by `NavigationStack`.
struct ClientDetailView: View {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "ClientDetailView"
    )

    let client: Client

    @Environment(AppState.self) private var appState

    /// Contacts associated with this client — populated by the storage layer.
    @State private var contacts: [Contact] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                clientHeader
                contactsSection
                activitySection
            }
            .padding(24)
        }
        .navigationTitle(client.name)
        .navigationSubtitle(client.domain ?? "")
    }

    // MARK: - Header

    private var clientHeader: some View {
        HStack(spacing: 16) {
            ClientAvatarView(name: client.name, size: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(client.name)
                    .font(.title2)
                    .fontWeight(.semibold)

                if let domain = client.domain {
                    Text(domain)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
    }

    // MARK: - Contacts section

    private var contactsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Contacts")
                .font(.headline)

            if contacts.isEmpty {
                EmptyStateView(
                    icon: "person.crop.circle",
                    title: "No contacts yet",
                    subtitle: "Contacts from \(client.name) will appear here once " +
                              "the classification pipeline links interactions."
                )
                .frame(height: 140)
            } else {
                VStack(spacing: 0) {
                    ForEach(contacts) { contact in
                        NavigationLink(value: contact) {
                            ContactRowView(contact: contact)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
            }
        }
    }

    // MARK: - Activity section

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Activity")
                .font(.headline)

            EmptyStateView(
                icon: "clock",
                title: "Getting started",
                subtitle: "Activity for \(client.name) will appear here once capture begins."
            )
            .frame(height: 160)
        }
    }
}

// MARK: - ContactRowView

/// A compact contact row used in `ClientDetailView` and any other list that
/// shows contacts. Tapping pushes `ContactProfileView` via `NavigationLink(value:)`.
struct ContactRowView: View {
    let contact: Contact

    var body: some View {
        HStack(spacing: 10) {
            ContactAvatarView(contact: contact, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName)
                    .fontWeight(.medium)
                if let company = contact.company {
                    Text(company)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Relationship score indicator — a small horizontal bar.
            RelationshipBar(score: contact.relationshipScore)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - ContactAvatarView

/// Circular avatar for a contact: initials or first letter of display name.
struct ContactAvatarView: View {
    let contact: Contact
    let size: CGFloat

    private var initial: String {
        String(contact.displayName.prefix(1).uppercased())
    }

    private var backgroundColor: Color {
        let colors: [Color] = [.blue, .green, .purple, .orange, .teal, .pink]
        let index = abs(contact.displayName.hashValue) % colors.count
        return colors[index]
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor.opacity(0.18))
            Text(initial)
                .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
                .foregroundStyle(backgroundColor)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - RelationshipBar

/// A short horizontal bar (0–1 fill) representing a contact's relationship score.
private struct RelationshipBar: View {
    let score: Double  // 0.0 – 1.0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(nsColor: .quaternaryLabelColor))
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor)
                    .frame(width: geo.size.width * score)
            }
        }
        .frame(width: 36, height: 4)
    }

    private var barColor: Color {
        switch score {
        case 0..<0.33: return .secondary
        case 0.33..<0.66: return .yellow
        default: return .green
        }
    }
}
