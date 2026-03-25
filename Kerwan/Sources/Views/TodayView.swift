import SwiftUI
import os

/// The "Today" section — a glanceable dashboard of today's capture activity.
///
/// Shows today's event count, capture status, open promises, and sessions
/// awaiting review. Full implementation will be provided by the UI detail
/// workstream; this view renders the empty state until capture data arrives.
struct TodayView: View {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "TodayView"
    )

    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.eventsToday == 0 && !appState.isCaptureActive {
                emptyState
            } else {
                dashboard
            }
        }
        .navigationTitle("Today")
    }

    // MARK: - Empty state

    private var emptyState: some View {
        EmptyStateView(
            icon: "sun.max",
            title: "Getting started",
            subtitle: "Today will appear here once capture begins. " +
                      "Enable capture from the menu bar to start tracking your day."
        )
    }

    // MARK: - Dashboard (shown once capture is active or events exist)

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Events today stat card
                StatCard(
                    title: "Events Today",
                    value: formattedEventsToday,
                    icon: "waveform.path",
                    tint: .blue
                )

                // Pending review card
                if appState.pendingReviewCount > 0 {
                    StatCard(
                        title: "Awaiting Review",
                        value: "\(appState.pendingReviewCount) sessions",
                        icon: "checkmark.circle",
                        tint: .orange
                    )
                }

                // Open promises card
                if appState.openPromiseCount > 0 {
                    StatCard(
                        title: "Open Promises",
                        value: "\(appState.openPromiseCount)",
                        icon: "seal",
                        tint: .purple
                    )
                }

                // Capture status card
                StatCard(
                    title: "Capture",
                    value: appState.captureStatus.description,
                    icon: captureIcon,
                    tint: captureColor
                )
            }
            .padding(20)
        }
    }

    // MARK: - Helpers

    private var formattedEventsToday: String {
        NumberFormatter.localizedString(
            from: NSNumber(value: appState.eventsToday),
            number: .decimal
        )
    }

    private var captureIcon: String {
        switch appState.captureStatus {
        case .capturing:   return "mic.fill"
        case .paused:      return "pause.circle"
        case .privateMode: return "eye.slash"
        case .idle:        return "mic.slash"
        case .error:       return "exclamationmark.triangle"
        }
    }

    private var captureColor: Color {
        switch appState.captureStatus {
        case .capturing:   return .green
        case .paused:      return .yellow
        case .privateMode: return .red
        case .idle:        return .secondary
        case .error:       return .orange
        }
    }
}

// MARK: - StatCard

/// A compact metric card for the Today dashboard.
private struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body)
                    .fontWeight(.medium)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
