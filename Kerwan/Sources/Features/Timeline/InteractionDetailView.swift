import SwiftUI

// MARK: - InteractionDetailView

/// Expanded detail panel rendered below an `InteractionRow` when it is tapped.
///
/// Shows: duration · sentiment · importance · full summary · linked promises ·
/// raw transcript placeholder · session link.
struct InteractionDetailView: View {

    let item: TimelineItem

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            Divider()

            // ── Meta row ──────────────────────────────────────────────
            metaRow

            // ── Full summary ──────────────────────────────────────────
            if let summary = item.interaction.summary {
                VStack(alignment: .leading, spacing: 4) {
                    detailSectionLabel("Summary")
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            }

            // ── Raw transcript placeholder ────────────────────────────
            rawContentSection

            // ── Content tags ──────────────────────────────────────────
            if !item.interaction.contentTags.isEmpty {
                tagsSection
            }

            // ── Linked promises ───────────────────────────────────────
            if !item.promises.isEmpty {
                promisesSection
            }

            // ── Session link ──────────────────────────────────────────
            sessionLinkRow
        }
        .padding(.top, 2)
    }

    // MARK: - Meta row

    private var metaRow: some View {
        HStack(spacing: 16) {

            // Interaction type
            Label(
                item.interaction.interactionType.displayName,
                systemImage: item.interaction.interactionType.systemImage
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(item.interaction.interactionType.iconColor)

            // Duration
            if let ended = item.interaction.endedAt {
                let mins = Int(ended.timeIntervalSince(item.interaction.startedAt) / 60)
                Label("\(mins) min", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Sentiment badge
            sentimentBadge

            // Importance
            importanceMeter

            Spacer(minLength: 0)

            // Review indicator
            if !item.interaction.isReviewed {
                Label("Needs review", systemImage: "exclamationmark.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Sentiment badge

    private var sentimentBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: item.interaction.sentiment.systemImage)
                .imageScale(.small)
            Text(item.interaction.sentiment.displayLabel)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(item.interaction.sentiment.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(item.interaction.sentiment.color.opacity(0.1))
        )
    }

    // MARK: - Importance meter (5 dots)

    private var importanceMeter: some View {
        HStack(spacing: 2) {
            Text("Priority")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack(spacing: 2) {
                ForEach(0..<5) { i in
                    Circle()
                        .fill(
                            Double(i) < item.interaction.importance * 5
                                ? importanceColor : Color.secondary.opacity(0.2)
                        )
                        .frame(width: 6, height: 6)
                }
            }
        }
    }

    private var importanceColor: Color {
        item.interaction.importance > 0.7 ? .red :
        item.interaction.importance > 0.4 ? .orange : .secondary
    }

    // MARK: - Raw content section

    private var rawContentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            detailSectionLabel("Raw Content")
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.07))
                Text("Transcript or raw event data will appear here once the capture pipeline is connected.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
        }
    }

    // MARK: - Tags section

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailSectionLabel("Topics")
            FlowLayout(spacing: 6) {
                ForEach(item.interaction.contentTags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.1)))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    // MARK: - Promises section

    private var promisesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            detailSectionLabel("Commitments (\(item.promises.count))")
            ForEach(item.promises) { promise in
                PromiseRow(promise: promise)
            }
        }
    }

    // MARK: - Session link

    private var sessionLinkRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Text("Billable session")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("View Session") {
                // Navigate to the Review Queue where associated work sessions are listed.
                // Full interaction→session linking will be added when the billing engine
                // exposes session IDs on the interaction record.
                Task { @MainActor in
                    appState.selectedSidebarItem = .reviewQueue
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help("Open the Review Queue to find the billable session for this interaction")
        }
        .padding(.top, 2)
    }

    // MARK: - Label helper

    private func detailSectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .tracking(0.5)
    }
}

// MARK: - PromiseRow

private struct PromiseRow: View {
    let promise: Promise

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: promise.status.systemImage)
                .foregroundStyle(promise.status.color)
                .imageScale(.small)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(promise.description)
                    .font(.callout)
                    .strikethrough(promise.status == .done)
                    .foregroundStyle(promise.status == .dismissed ? .tertiary : .primary)

                HStack(spacing: 8) {
                    // Direction badge
                    Text(promise.direction == .userPromised ? "You promised" : "They promised")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)

                    // Due date
                    if let due = promise.dueDate {
                        HStack(spacing: 2) {
                            Image(systemName: "calendar")
                            Text(due, style: .date)
                        }
                        .font(.caption2)
                        .foregroundStyle(promise.isOverdue ? Color.red : Color.secondary)
                    }
                }

                // Source quote (collapsible)
                if let quote = promise.sourceQuote {
                    Text("\u{201C}\(quote)\u{201D}")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .italic()
                        .lineLimit(2)
                        .padding(.top, 1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(promise.status.color.opacity(0.05))
                .strokeBorder(promise.status.color.opacity(0.15), lineWidth: 0.5)
        )
    }
}

// MARK: - Sentiment helpers

extension Sentiment {
    var displayLabel: String {
        switch self {
        case .positive: return "Positive"
        case .neutral:  return "Neutral"
        case .negative: return "Negative"
        case .mixed:    return "Mixed"
        }
    }

    var systemImage: String {
        switch self {
        case .positive: return "face.smiling"
        case .neutral:  return "minus.circle"
        case .negative: return "face.dashed"
        case .mixed:    return "arrow.left.arrow.right.circle"
        }
    }

    var color: Color {
        switch self {
        case .positive: return .green
        case .neutral:  return .secondary
        case .negative: return .red
        case .mixed:    return .orange
        }
    }
}

// MARK: - PromiseStatus helpers

extension PromiseStatus {
    var systemImage: String {
        switch self {
        case .open:      return "circle"
        case .done:      return "checkmark.circle.fill"
        case .snoozed:   return "clock.arrow.circlepath"
        case .dismissed: return "xmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .open:      return .orange
        case .done:      return .green
        case .snoozed:   return .blue
        case .dismissed: return .secondary
        }
    }
}

// MARK: - FlowLayout

/// A simple horizontal-wrapping layout for tag chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return layout(in: width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func layout(in width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x  = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), frames)
    }
}
