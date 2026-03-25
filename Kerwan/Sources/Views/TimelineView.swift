import SwiftUI
import os

/// The activity timeline — a reverse-chronological feed of all captured
/// interactions, grouped by day.
///
/// Full implementation is provided by the AI/capture workstreams. This view
/// renders the empty state until interactions are classified and stored.
struct TimelineView: View {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "TimelineView"
    )

    @Environment(AppState.self) private var appState

    /// Interactions loaded from storage — populated by the storage integration layer.
    @State private var interactions: [TimelineEntry] = []

    var body: some View {
        Group {
            if interactions.isEmpty {
                emptyState
            } else {
                timelineList
            }
        }
        .navigationTitle("Timeline")
    }

    // MARK: - Empty state

    private var emptyState: some View {
        EmptyStateView(
            icon: "clock",
            title: "Getting started",
            subtitle: "Timeline will appear here once capture begins. " +
                      "Meetings, emails, and documents are automatically classified " +
                      "and appear in your timeline in real time."
        )
    }

    // MARK: - Timeline list (shown once interactions exist)

    private var timelineList: some View {
        List {
            ForEach(groupedByDay.keys.sorted(by: >), id: \.self) { day in
                Section(header: Text(day, style: .date).font(.subheadline)) {
                    ForEach(groupedByDay[day] ?? []) { entry in
                        TimelineEntryRow(entry: entry)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var groupedByDay: [Date: [TimelineEntry]] {
        Dictionary(grouping: interactions) { entry in
            Calendar.current.startOfDay(for: entry.timestamp)
        }
    }
}

// MARK: - Placeholder timeline entry type

/// Lightweight timeline entry for the UI layer.
/// The full classified `Interaction` type will be provided by the AI workstream.
struct TimelineEntry: Identifiable, Hashable {
    let id: EntityID
    let title: String
    let snippet: String?
    let timestamp: Date
    let icon: String
    let tintColor: Color
    let contactName: String?
    let clientName: String?
}

// MARK: - TimelineEntryRow

private struct TimelineEntryRow: View {
    let entry: TimelineEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon column
            Image(systemName: entry.icon)
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(entry.tintColor)
                .frame(width: 20, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.title)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer()
                    Text(entry.timestamp, style: .time)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }

                if let snippet = entry.snippet {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let contact = entry.contactName {
                    HStack(spacing: 4) {
                        Image(systemName: "person")
                            .font(.caption2)
                        Text(contact)
                            .font(.caption2)
                    }
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
