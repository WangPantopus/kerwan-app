import SwiftUI
import os

/// The billing view — shows unbilled time, ready-to-invoice sessions, and
/// invoice history grouped by client.
///
/// The sidebar badge (`AppState.unbilledHours`) reflects total uninvoiced hours
/// across all confirmed and suggested sessions. Full implementation is provided
/// by the billing workstream; this view renders the empty state until sessions
/// are available.
struct BillingView: View {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "BillingView"
    )

    @Environment(AppState.self) private var appState

    /// Confirmed / suggested sessions not yet invoiced — from the billing engine.
    @State private var unbilledSessions: [WorkSession] = []

    var body: some View {
        Group {
            if unbilledSessions.isEmpty && appState.unbilledHours == 0 {
                emptyState
            } else {
                billingDashboard
            }
        }
        .navigationTitle("Billing")
    }

    // MARK: - Empty state

    private var emptyState: some View {
        EmptyStateView(
            icon: "dollarsign.circle",
            title: "Getting started",
            subtitle: "Billing will appear here once capture begins. " +
                      "Kerwan tracks your billable time automatically and groups it " +
                      "into ready-to-invoice sessions."
        )
    }

    // MARK: - Billing dashboard

    private var billingDashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                billingSummaryCard

                if !unbilledSessions.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Ready to Invoice")
                            .font(.headline)
                        ForEach(unbilledSessions) { session in
                            SessionReviewRow(session: session)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    .quaternary,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var billingSummaryCard: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Unbilled Hours")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f h", appState.unbilledHours))
                    .font(.title2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }

            Divider()
                .frame(height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text("Sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(unbilledSessions.count)")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }

            Spacer()

            Button("Export Invoice") {
                // Full implementation: billing workstream.
            }
            .buttonStyle(.borderedProminent)
            .disabled(unbilledSessions.isEmpty)
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
