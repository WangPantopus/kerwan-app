import SwiftUI
import os

/// The review queue — work sessions awaiting billability decisions.
///
/// The classification pipeline creates sessions with `.suggested` billable
/// status. This view presents them for the user to confirm, reject, or edit
/// the AI-generated invoice text before export.
///
/// The sidebar badge (`AppState.pendingReviewCount`) reflects the number of
/// unreviewed (`.suggested`) sessions. Full implementation is provided by the
/// billing workstream; this view renders the empty state until sessions exist.
struct ReviewQueueView: View {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "ReviewQueueView"
    )

    @Environment(AppState.self) private var appState

    /// Suggested sessions — populated by the billing engine / storage layer.
    @State private var sessions: [WorkSession] = []

    var body: some View {
        Group {
            if sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .navigationTitle("Review Queue")
        .toolbar {
            if !sessions.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Review All") {
                        // Batch-review action — implemented by the billing workstream.
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        EmptyStateView(
            icon: "checkmark.circle",
            title: "Getting started",
            subtitle: "Review Queue will appear here once capture begins. " +
                      "Kerwan automatically groups your work into billable sessions " +
                      "and queues them here for your review."
        )
    }

    // MARK: - Session list

    private var sessionList: some View {
        List {
            ForEach(sessions) { session in
                SessionReviewRow(session: session)
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - SessionReviewRow

/// A single session row used in both `ReviewQueueView` and `BillingView`.
/// `internal` (not `private`) so both views can reference it.
struct SessionReviewRow: View {
    let session: WorkSession

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.description ?? "Untitled Session")
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(session.startedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(session.durationFormatted)
                    .font(.subheadline)
                    .monospacedDigit()
                billableIndicator
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var billableIndicator: some View {
        switch session.billableStatus {
        case .confirmed:
            Label("Billable", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .rejected, .nonBillable:
            Label("Non-billable", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .suggested:
            Label("Review", systemImage: "questionmark.circle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        }
    }
}

// MARK: - WorkSession display helpers

extension WorkSession {
    /// Human-readable duration string, e.g. "45 min", "2h", "1h 30m".
    var durationFormatted: String {
        let minutes = durationSecs / 60
        guard minutes >= 60 else { return "\(minutes) min" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}
