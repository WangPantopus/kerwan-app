import SwiftUI

// MARK: - InteractionRow

/// A single row in the Timeline list.
///
/// Collapsed: type icon · contact/client · summary · source badge · time.
/// Expanded: adds `InteractionDetailView` below the row body.
struct InteractionRow: View {

    let item:       TimelineItem
    let isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Collapsed row ──────────────────────────────────────────
            HStack(alignment: .top, spacing: 12) {
                typeIcon
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 3) {
                    headerLine
                    summaryLine
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    timeLabel
                    sourceBadge
                }

                chevron
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // ── Expanded detail ────────────────────────────────────────
            if isExpanded {
                InteractionDetailView(item: item)
                    .padding(.leading, 60)
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
        .background(isExpanded ? Color.accentColor.opacity(0.04) : Color.clear)
    }

    // MARK: - Type icon

    private var typeIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(item.interaction.interactionType.iconColor.opacity(0.12))
                .frame(width: 32, height: 32)
            Image(systemName: item.interaction.interactionType.systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(item.interaction.interactionType.iconColor)
        }
    }

    // MARK: - Header line (contact · client)

    private var headerLine: some View {
        HStack(spacing: 0) {
            if let contact = item.contactName {
                Text(contact)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            if let client = item.clientName {
                if item.contactName != nil {
                    Text(" · ")
                        .foregroundStyle(.tertiary)
                        .font(.subheadline)
                }
                Text(client)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if item.contactName == nil && item.clientName == nil {
                Text(item.interaction.interactionType.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if !item.interaction.isReviewed {
                Circle()
                    .fill(.orange)
                    .frame(width: 6, height: 6)
                    .padding(.leading, 6)
                    .help("Awaiting your review")
            }
        }
    }

    // MARK: - Summary line

    private var summaryLine: some View {
        Text(item.interaction.summary ?? item.interaction.interactionType.displayName)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(isExpanded ? 3 : 2)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Time label

    private var timeLabel: some View {
        Text(item.interaction.startedAt, format: .dateTime.hour().minute())
            .font(.caption)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
    }

    // MARK: - Source badge

    private var sourceBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: item.interaction.source.systemImage)
                .imageScale(.small)
            Text(item.interaction.source.shortLabel)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(item.interaction.source.badgeColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(item.interaction.source.badgeColor.opacity(0.1))
        )
    }

    // MARK: - Expand chevron

    private var chevron: some View {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 16)
    }
}

// MARK: - InteractionType display helpers

extension InteractionType {
    /// Coloured background tint used in the timeline row icon bubble.
    /// Distinct from `tintColor` (ContactProfileViewModel) which uses different hues.
    var iconColor: Color {
        switch self {
        case .meeting:       return .purple
        case .emailSent:     return .blue
        case .emailReceived: return .teal
        case .slackDM:       return .green
        case .phoneCalled:   return .orange
        case .appActivity:   return .secondary
        }
    }
}

// MARK: - EventSource display helpers

extension EventSource {
    var systemImage: String {
        switch self {
        case .audio:      return "mic.fill"
        case .appFocus:   return "app.badge.fill"
        case .email:      return "envelope.fill"
        case .slack:      return "bubble.left.fill"
        case .calendar:   return "calendar"
        case .browser:    return "globe"
        case .manualNote: return "pencil"
        }
    }

    var badgeColor: Color {
        switch self {
        case .audio:      return .purple
        case .appFocus:   return .gray
        case .email:      return .blue
        case .slack:      return .green
        case .calendar:   return .orange
        case .browser:    return .teal
        case .manualNote: return .secondary
        }
    }
}
