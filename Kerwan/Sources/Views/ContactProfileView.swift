import SwiftUI
import os

/// Full profile view for a single contact.
///
/// Shown when a user taps a contact row from `ClientDetailView` or any other
/// list. The `Contact` value is pushed onto the detail `NavigationStack` in
/// `ContentView` via `NavigationLink(value:)`.
///
/// Back navigation to the previous list is provided automatically by
/// `NavigationStack`'s toolbar back button and two-finger swipe gesture.
struct ContactProfileView: View {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "ContactProfileView"
    )

    let contact: Contact

    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                profileHeader
                relationshipSection
                interactionsSection
                promisesSection
            }
            .padding(24)
        }
        .navigationTitle(contact.displayName)
        .navigationSubtitle(contact.company ?? contact.emailPrimary ?? "")
    }

    // MARK: - Header

    private var profileHeader: some View {
        HStack(spacing: 16) {
            ContactAvatarView(contact: contact, size: 60)

            VStack(alignment: .leading, spacing: 4) {
                Text(contact.displayName)
                    .font(.title2)
                    .fontWeight(.semibold)

                if let company = contact.company {
                    Text(company)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let email = contact.emailPrimary {
                    Link(email, destination: URL(string: "mailto:\(email)")!)
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }

            Spacer()

            // Relationship score badge
            VStack(spacing: 4) {
                Text(String(format: "%.0f%%", contact.relationshipScore * 100))
                    .font(.title3)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text("Relationship")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - AI Summary

    private var relationshipSection: some View {
        Group {
            if let summary = contact.aiSummary {
                VStack(alignment: .leading, spacing: 8) {
                    Label("AI Summary", systemImage: "sparkles")
                        .font(.headline)
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: - Interactions

    private var interactionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Interactions")
                .font(.headline)

            EmptyStateView(
                icon: "bubble.left.and.bubble.right",
                title: "Getting started",
                subtitle: "Interactions with \(contact.displayName) will appear here " +
                          "once capture begins and the classification pipeline runs."
            )
            .frame(height: 140)
        }
    }

    // MARK: - Promises

    private var promisesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Promises")
                .font(.headline)

            EmptyStateView(
                icon: "seal",
                title: "No open promises",
                subtitle: "Commitments made to or by \(contact.displayName) will be " +
                          "tracked here automatically."
            )
            .frame(height: 120)
        }
    }
}
