import SwiftUI
import Charts
import os

// MARK: - TodayView

/// The "Today" dashboard — a glanceable daily briefing.
///
/// Sections (each hidden when empty):
///  1. Digest card — today's AI-generated summary
///  2. Upcoming meetings — today's sessions with pre-call briefing indicator
///  3. Due soon — open promises expiring within 3 days
///  4. Quick review — 3 most recent unreviewed billing sessions
///  5. Yesterday's activity — hours by client bar chart
struct TodayView: View {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "TodayView"
    )

    @Environment(AppState.self) private var appState
    @State private var vm = TodayViewModel()

    var body: some View {
        Group {
            if vm.isLoading && vm.latestDigest == nil && vm.todaysMeetings.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        greetingHeader

                        DigestCard(digest: vm.latestDigest, appState: appState)

                        if !vm.upcomingMeetings.isEmpty {
                            UpcomingMeetingsSection(
                                meetings: vm.upcomingMeetings,
                                contacts: vm.meetingContacts
                            )
                        }

                        if !vm.dueSoonPromises.isEmpty {
                            DueSoonSection(
                                promises: vm.dueSoonPromises,
                                contacts: vm.promiseContacts,
                                onDone: { p in Task { await vm.markPromiseDone(p) } },
                                onSnooze: { p in Task { await vm.snoozePromise(p) } }
                            )
                        }

                        if !vm.quickReviewSessions.isEmpty {
                            QuickReviewSection(
                                sessions: vm.quickReviewSessions,
                                clients: vm.sessionClients,
                                onConfirm: { s in Task { await vm.confirmSession(s) } },
                                onReject: { s in Task { await vm.rejectSession(s) } }
                            )
                        }

                        if !vm.yesterdayHoursByClient.isEmpty {
                            YesterdayActivitySection(
                                hoursByClient: vm.yesterdayHoursByClient,
                                totalHours: vm.totalYesterdayHours
                            )
                        }

                        // Bottom padding so content clears the window chrome.
                        Color.clear.frame(height: 20)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                }
            }
        }
        .navigationTitle("Today")
        .task { await vm.load() }
        .onReceive(NotificationCenter.default.publisher(for: .kerwanNewDigestReady)) { _ in
            Task { await vm.refreshDigest() }
        }
        .alert("Error", isPresented: Binding(
            get: { vm.error != nil },
            set: { if !$0 { vm.error = nil } }
        )) {
            Button("OK") { vm.error = nil }
        } message: {
            Text(vm.error ?? "")
        }
    }

    // MARK: - Greeting header

    private var greetingHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(greetingText)
                .font(.system(size: 26, weight: .bold))
            Text(Date(), format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning" }
        if hour < 17 { return "Good afternoon" }
        return "Good evening"
    }
}

// MARK: - DigestCard

private struct DigestCard: View {
    let digest: Digest?
    let appState: AppState

    var body: some View {
        TodayCard {
            if let digest {
                loadedCard(digest)
            } else {
                placeholderCard
            }
        }
    }

    @ViewBuilder
    private func loadedCard(_ digest: Digest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(digest.title)
                        .font(.headline)
                    Text("Generated \(digest.generatedAt, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: digest.kind == .daily ? "sun.max.fill" : "calendar.badge.clock")
                    .font(.system(size: 20))
                    .foregroundStyle(.yellow.gradient)
            }

            // AI body text
            Text(digest.bodyText)
                .font(.subheadline)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // Stats row
            HStack(spacing: 0) {
                DigestStatPill(value: "\(digest.meetingCount)", label: "meetings", systemImage: "person.3.fill", tint: .blue)
                Divider().frame(height: 28)
                DigestStatPill(value: "\(digest.emailCount)", label: "emails", systemImage: "envelope.fill", tint: .indigo)
                Divider().frame(height: 28)
                DigestStatPill(value: "\(digest.openPromiseCount)", label: "open items", systemImage: "seal.fill", tint: .purple)
                if digest.unreviewedSessionCount > 0 {
                    Divider().frame(height: 28)
                    DigestStatPill(value: "\(digest.unreviewedSessionCount)", label: "to review", systemImage: "questionmark.circle.fill", tint: .orange)
                }
            }

            // Quiet contacts
            if !digest.quietContactNames.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.minus")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Going quiet: \(digest.quietContactNames.prefix(3).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }

            // Weekly extras
            if digest.kind == .weekly, let total = digest.totalHoursTracked {
                Divider()
                HStack(spacing: 16) {
                    DigestWeeklyStat(
                        label: "Hours tracked",
                        value: String(format: "%.1fh", total)
                    )
                    if let billable = digest.estimatedBillableHours {
                        DigestWeeklyStat(
                            label: "Confirmed billable",
                            value: String(format: "%.1fh", billable),
                            delta: billable - (digest.priorWeekBillableHours ?? billable)
                        )
                    }
                    if let reviewed = digest.sessionsReviewedCount, let pending = digest.sessionsPendingCount {
                        DigestWeeklyStat(
                            label: "Sessions",
                            value: "\(reviewed) reviewed · \(pending) pending"
                        )
                    }
                }
            }
        }
    }

    private var placeholderCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "sun.max")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("No digest yet")
                    .font(.headline)
                Text("Your daily digest will appear here at your configured digest time. Kerwan generates it from yesterday's activity.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - DigestStatPill

private struct DigestStatPill: View {
    let value: String
    let label: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(tint)
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

// MARK: - DigestWeeklyStat

private struct DigestWeeklyStat: View {
    let label: String
    let value: String
    var delta: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                if let d = delta, abs(d) > 0.1 {
                    Label(String(format: "%+.1fh", d), systemImage: d >= 0 ? "arrow.up" : "arrow.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(d >= 0 ? .green : .orange)
                        .labelStyle(.titleAndIcon)
                }
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - UpcomingMeetingsSection

private struct UpcomingMeetingsSection: View {
    let meetings: [Interaction]
    let contacts: [EntityID: Contact]

    var body: some View {
        TodaySection(title: "Upcoming Today", systemImage: "calendar") {
            VStack(spacing: 0) {
                ForEach(meetings) { meeting in
                    MeetingRow(
                        meeting: meeting,
                        contact: contacts[meeting.contactId ?? ""]
                    )
                    if meeting.id != meetings.last?.id {
                        Divider().padding(.leading, 48)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
    }
}

// MARK: - MeetingRow

private struct MeetingRow: View {
    let meeting: Interaction
    let contact: Contact?

    var body: some View {
        HStack(spacing: 12) {
            // Time column
            VStack(alignment: .trailing, spacing: 1) {
                Text(meeting.startedAt, format: .dateTime.hour().minute())
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                if let end = meeting.endedAt {
                    Text(end, format: .dateTime.hour().minute())
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .frame(width: 36, alignment: .trailing)

            // Type indicator bar
            RoundedRectangle(cornerRadius: 2)
                .fill(meeting.interactionType.tintColor)
                .frame(width: 3, height: 34)

            // Content
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.summary ?? meeting.interactionType.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let contact {
                        Text(contact.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let dur = meeting.durationFormatted {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(dur)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Pre-call briefing indicator
            if contact?.aiSummary != nil {
                Label("Briefing ready", systemImage: "doc.text.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.blue)
                    .clipShape(Capsule())
            }

            // Live/upcoming indicator
            if isOngoing {
                Label("Live", systemImage: "waveform")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.green)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var isOngoing: Bool {
        let now = Date()
        if let end = meeting.endedAt {
            return meeting.startedAt <= now && end >= now
        }
        return meeting.startedAt <= now &&
               now.timeIntervalSince(meeting.startedAt) < 3600
    }
}

// MARK: - DueSoonSection

private struct DueSoonSection: View {
    let promises: [Promise]
    let contacts: [EntityID: Contact]
    let onDone: (Promise) -> Void
    let onSnooze: (Promise) -> Void

    var body: some View {
        TodaySection(title: "Due Soon", systemImage: "seal.fill") {
            VStack(spacing: 8) {
                ForEach(promises) { promise in
                    PromiseDueRow(
                        promise: promise,
                        contact: contacts[promise.contactId ?? ""],
                        onDone: { onDone(promise) },
                        onSnooze: { onSnooze(promise) }
                    )
                }
            }
        }
    }
}

// MARK: - PromiseDueRow

private struct PromiseDueRow: View {
    let promise: Promise
    let contact: Contact?
    let onDone: () -> Void
    let onSnooze: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            directionIcon
            contentStack
            Spacer()
            actionButtons
        }
        .padding(12)
        .background(rowBackground)
        .overlay(rowBorder)
    }

    private var directionIcon: some View {
        let isUser = promise.direction == .userPromised
        return Image(systemName: isUser ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
            .font(.system(size: 16))
            .foregroundStyle(isUser ? Color.blue : Color.purple)
    }

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(promise.description)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            metaLine
        }
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            if let contact {
                Label(contact.displayName, systemImage: "person.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
            if let dueDate = promise.dueDate {
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(dueDate, format: .dateTime.month(.abbreviated).day())
                    .font(.caption)
                    .foregroundStyle(promise.isOverdue ? Color.red : Color.secondary)
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            Button(action: onSnooze) {
                Image(systemName: "zzz")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("Snooze")

            Button(action: onDone) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.green)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("Mark done")
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(promise.isOverdue
                ? Color.red.opacity(0.06)
                : Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var rowBorder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(promise.isOverdue ? Color.red.opacity(0.3) : Color(nsColor: .separatorColor),
                    lineWidth: 0.5)
    }
}

// MARK: - QuickReviewSection

private struct QuickReviewSection: View {
    let sessions: [WorkSession]
    let clients: [EntityID: Client]
    let onConfirm: (WorkSession) -> Void
    let onReject: (WorkSession) -> Void

    var body: some View {
        TodaySection(
            title: "Quick Review",
            systemImage: "checkmark.circle",
            accessory: {
                Button("See all") {
                    NotificationCenter.default.post(name: .kerwanShowReviewQueue, object: nil)
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        ) {
            VStack(spacing: 6) {
                ForEach(sessions) { session in
                    QuickSessionRow(
                        session: session,
                        client: clients[session.clientId ?? ""],
                        onConfirm: { onConfirm(session) },
                        onReject: { onReject(session) }
                    )
                }
            }
        }
    }
}

// MARK: - QuickSessionRow

private struct QuickSessionRow: View {
    let session: WorkSession
    let client: Client?
    let onConfirm: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ConfidenceDot(confidence: session.confidence)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.description ?? "Work session")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(session.startedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(session.durationFormatted)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if let clientName = client?.name {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(clientName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            // Inline confirm / reject
            Button(action: onReject) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Reject")

            Button(action: onConfirm) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Color.green)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Confirm as billable")
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

// MARK: - ConfidenceDot

private struct ConfidenceDot: View {
    let confidence: Double

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        if confidence >= 0.75 { return .green }
        if confidence >= 0.40 { return .orange }
        return .red
    }
}

// MARK: - YesterdayActivitySection

private struct YesterdayActivitySection: View {
    let hoursByClient: [(client: Client, hours: Double)]
    let totalHours: Double

    var body: some View {
        TodaySection(title: "Yesterday's Activity", systemImage: "chart.bar.fill") {
            VStack(alignment: .leading, spacing: 12) {
                // Total
                HStack {
                    Text(String(format: "%.1fh tracked", totalHours))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Spacer()
                    Text("by client")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // Bar chart
                Chart {
                    ForEach(hoursByClient, id: \.client.id) { entry in
                        BarMark(
                            x: .value("Hours", entry.hours),
                            y: .value("Client", entry.client.name)
                        )
                        .foregroundStyle(clientColor(entry.client.name).gradient)
                        .annotation(position: .trailing, alignment: .leading) {
                            Text(String(format: "%.1fh", entry.hours))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let name = value.as(String.self) {
                                Text(name)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .frame(height: max(60, CGFloat(hoursByClient.count) * 36))
            }
        }
    }

    private func clientColor(_ name: String) -> Color {
        let colors: [Color] = [.blue, .indigo, .purple, .teal, .green, .orange]
        return colors[abs(name.hashValue) % colors.count]
    }
}

// MARK: - TodaySection (reusable card wrapper)

private struct TodaySection<Content: View>: View {
    let title: String
    let systemImage: String
    let accessoryView: AnyView
    let contentView: Content

    /// Without accessory view.
    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accessoryView = AnyView(EmptyView())
        self.contentView = content()
    }

    /// With an accessory view in the header (e.g. a "See all" button).
    init<A: View>(
        title: String,
        systemImage: String,
        @ViewBuilder accessory: () -> A,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accessoryView = AnyView(accessory())
        self.contentView = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                accessoryView
            }
            contentView
        }
    }
}

// MARK: - TodayCard (elevated card style)

private struct TodayCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
    }
}

// MARK: - Notification names

extension Notification.Name {
    /// Posted when the user taps "See all" in the Quick Review section.
    /// `ContentView` observes this and switches the sidebar to `.reviewQueue`.
    static let kerwanShowReviewQueue = Notification.Name("com.kerwan.app.showReviewQueue")
}

// MARK: - StatCard (kept for AppState-driven fallback)

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
                    .font(.body.weight(.medium))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
