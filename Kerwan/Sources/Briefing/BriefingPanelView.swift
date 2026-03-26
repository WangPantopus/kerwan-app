import SwiftUI

/// The contents of the floating pre-call briefing panel.
///
/// Hosted in an `NSPanel` by ``BriefingWindowController``. Displays the
/// meeting title, start time, LLM-generated bullet points, and a compact card
/// per attendee. Tapping an attendee card navigates to their `ContactProfileView`.
struct BriefingPanelView: View {

    let briefing: PreCallBriefing
    let onDismiss: () -> Void
    let onSelectContact: (Contact) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if !briefing.bulletPoints.isEmpty {
                        bulletsSection
                    }
                    if !briefing.attendees.isEmpty {
                        Divider()
                        attendeesSection
                    }
                }
                .padding(16)
            }
            Divider()
            footerSection
        }
        .frame(width: 400)
        .frame(minHeight: 260, maxHeight: 420)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(briefing.event.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(meetingSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var meetingSubtitle: String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        let durationMin = Int(briefing.event.endDate.timeIntervalSince(briefing.event.startDate) / 60)
        var s = f.string(from: briefing.event.startDate) + " · \(durationMin) min"
        if let location = briefing.event.location, !location.isEmpty {
            s += " · \(location)"
        }
        return s
    }

    // MARK: - Bullets

    private var bulletsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Preparation", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(Array(briefing.bulletPoints.enumerated()), id: \.offset) { _, bullet in
                Text(bullet)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Attendees

    private var attendeesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Attendees", systemImage: "person.2")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(briefing.attendees) { ctx in
                attendeeCard(ctx)
            }
        }
    }

    private func attendeeCard(_ ctx: AttendeeContext) -> some View {
        Button { onSelectContact(ctx.contact) } label: {
            HStack(alignment: .top, spacing: 10) {
                avatarView(for: ctx.contact)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(ctx.contact.displayName)
                            .font(.callout.weight(.medium))
                        if let company = ctx.contact.company {
                            Text("· \(company)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if ctx.openItemCount > 0 {
                            Text("\(ctx.openItemCount) open")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.12), in: Capsule())
                        }
                    }
                    if let lastDate = ctx.lastInteractionDate {
                        let rel = RelativeDateTimeFormatter()
                            .localizedString(for: lastDate, relativeTo: Date())
                        Text("Last seen \(rel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No prior interactions")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if let summary = ctx.lastInteractionSummary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func avatarView(for contact: Contact) -> some View {
        Circle()
            .fill(.quaternary)
            .frame(width: 32, height: 32)
            .overlay {
                Text(contact.displayName.prefix(1).uppercased())
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Text("Ready \(RelativeDateTimeFormatter().localizedString(for: briefing.generatedAt, relativeTo: Date()))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Dismiss") { onDismiss() }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("With context") {
    let now = Date()
    let event = CalendarEventBrief(
        id: "preview-1",
        title: "Q2 Strategy Review",
        startDate: now.addingTimeInterval(120),
        endDate: now.addingTimeInterval(3_720),
        attendeeEmails: ["alice@acme.com", "bob@acme.com"],
        attendeeNames: ["Alice Chen", "Bob Martin"],
        location: "Zoom"
    )
    let interaction = Interaction(
        source: .audio,
        interactionType: .meeting,
        startedAt: now.addingTimeInterval(-86_400 * 3),
        summary: "Discussed rebrand timeline and deliverables for Q2.",
        sentiment: .positive,
        importance: 0.8
    )
    let promise = Promise(
        direction: .userPromised,
        description: "Send revised proposal by Friday",
        dueDate: now.addingTimeInterval(86_400 * 2)
    )
    let attendees = [
        AttendeeContext(
            contact: Contact(displayName: "Alice Chen", company: "Acme Corp", emailPrimary: "alice@acme.com"),
            recentInteractions: [interaction],
            openPromises: [promise]
        ),
        AttendeeContext(
            contact: Contact(displayName: "Bob Martin", company: "Acme Corp"),
            recentInteractions: [],
            openPromises: []
        )
    ]
    let briefing = PreCallBriefing(
        event: event,
        attendees: attendees,
        bulletPoints: [
            "• Last discussed the Q2 rebrand timeline — Alice expecting revised proposal.",
            "• You owe Alice the revised proposal by Friday.",
            "• Bob has not responded to the last two messages — approach carefully.",
            "• Previous meeting ended on a positive note regarding design direction."
        ]
    )
    return BriefingPanelView(
        briefing: briefing,
        onDismiss: {},
        onSelectContact: { _ in }
    )
}

#Preview("No context") {
    let now = Date()
    let event = CalendarEventBrief(
        id: "preview-2",
        title: "Intro Call",
        startDate: now.addingTimeInterval(120),
        endDate: now.addingTimeInterval(1_800),
        attendeeEmails: ["new@prospect.io"],
        attendeeNames: ["Sam Taylor"],
        location: nil
    )
    let briefing = PreCallBriefing(
        event: event,
        attendees: [
            AttendeeContext(
                contact: Contact(displayName: "Sam Taylor", emailPrimary: "new@prospect.io"),
                recentInteractions: [],
                openPromises: []
            )
        ],
        bulletPoints: ["• No prior interaction history found for the invited attendees."]
    )
    return BriefingPanelView(briefing: briefing, onDismiss: {}, onSelectContact: { _ in })
}
#endif
