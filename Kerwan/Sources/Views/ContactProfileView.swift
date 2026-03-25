import SwiftUI
import os

// MARK: - ContactProfileView

/// Full "dossier" view for a single contact — the most information-dense screen
/// in Kerwan.
///
/// Sections (top → bottom):
/// 1. Header: avatar, name, company, email, last-seen, relationship gauge, stats bar
/// 2. AI Summary card: LLM-generated narrative, Regenerate button
/// 3. Open Items: promises in both directions with swipe actions
/// 4. Key Facts: deduplicated content tags (preferences, objections, budget signals)
/// 5. Timeline: paginated reverse-chronological interactions with filter picker
/// 6. Notes: free-text editor that auto-saves after 1 s of no typing
///
/// Data flows:
/// - A `ContactProfileViewModel` is created on first load and reused across
///   toolbar actions (edit, merge, delete, export).
/// - All storage calls go through `ContactProfileStorageService`; stubs return
///   empty until the persistence workstream is injected.
@MainActor
struct ContactProfileView: View {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "ContactProfileView"
    )

    let contact: Contact

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var vm: ContactProfileViewModel

    init(contact: Contact) {
        self.contact = contact
        _vm = State(wrappedValue: ContactProfileViewModel(contact: contact))
    }

    var body: some View {
        Group {
            if vm.isLoadingInitial {
                ContactProfileSkeletonView()
            } else {
                profileContent
            }
        }
        .navigationTitle("")
        .toolbar { toolbarContent }
        .task { await vm.load() }
        .sheet(isPresented: $vm.isPresentingMergeSheet) {
            MergeContactSheet(vm: vm)
        }
        .confirmationDialog(
            "Delete \(vm.contact.displayName)?",
            isPresented: $vm.isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Contact", role: .destructive) {
                Task {
                    await vm.deleteContact()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all interactions, promises, and notes linked to \(vm.contact.displayName). This cannot be undone.")
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

    // MARK: - Main scroll content

    private var profileContent: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                // Header — full-width, no card frame.
                ContactProfileHeader(vm: vm)

                // Stats bar
                ContactStatsBar(vm: vm)

                Divider()
                    .padding(.bottom, 20)

                // Cards
                VStack(spacing: 16) {
                    AISummaryCard(vm: vm)
                    if !vm.openPromises.isEmpty || !vm.promises.isEmpty {
                        OpenItemsSection(vm: vm)
                    }
                    if !vm.keyFacts.isEmpty {
                        KeyFactsSection(vm: vm)
                    }
                    InteractionTimelineSection(vm: vm)
                    ContactNotesSection(vm: vm)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 36)
            }
        }
        .navigationSubtitle(vm.contact.company ?? vm.contact.emailPrimary ?? "")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Leading: Edit / Cancel
        ToolbarItem(placement: .cancellationAction) {
            if vm.isEditing {
                Button("Cancel") { vm.cancelEditing() }
            } else {
                Button("Edit") { vm.beginEditing() }
            }
        }

        // Trailing: Save (edit mode) or Actions menu
        ToolbarItem(placement: .confirmationAction) {
            if vm.isEditing {
                Button("Save") {
                    Task { await vm.saveEditing() }
                }
                .fontWeight(.semibold)
                .disabled(vm.draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Menu {
                    Button {
                        vm.exportTimeline()
                    } label: {
                        Label("Export Timeline…", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        Task {
                            await vm.loadMergeableContacts()
                            vm.isPresentingMergeSheet = true
                        }
                    } label: {
                        Label("Merge with…", systemImage: "person.2")
                    }

                    Divider()

                    Button(role: .destructive) {
                        vm.isConfirmingDelete = true
                    } label: {
                        Label("Delete Contact…", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }
}

// MARK: - ContactProfileHeader

private struct ContactProfileHeader: View {
    @Bindable var vm: ContactProfileViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ContactAvatarView(contact: vm.contact, size: 72)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                // Name — editable
                if vm.isEditing {
                    TextField("Name", text: $vm.draftName)
                        .textFieldStyle(.roundedBorder)
                        .font(.title2)
                        .frame(maxWidth: 260)
                } else {
                    Text(vm.contact.displayName)
                        .font(.system(size: 26, weight: .bold))
                        .lineLimit(1)
                }

                // Company — editable
                if vm.isEditing {
                    TextField("Company", text: $vm.draftCompany)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 220)
                } else if let company = vm.contact.company {
                    Text(company)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Email — editable
                if vm.isEditing {
                    TextField("Email", text: $vm.draftEmail)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(maxWidth: 220)
                } else if let email = vm.contact.emailPrimary,
                          let url = URL(string: "mailto:\(email)") {
                    Link(email, destination: url)
                        .font(.caption)
                }

                // Last seen
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("Last seen \(vm.contact.lastSeenAt, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Relationship score gauge
            RelationshipGaugeView(score: vm.contact.relationshipScore)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }
}

// MARK: - RelationshipGaugeView

private struct RelationshipGaugeView: View {
    let score: Double  // 0.0 – 1.0

    private var display: String { String(format: "%.1f", score * 10) }

    private var gaugeColor: Color {
        switch score {
        case 0.7...: return .green
        case 0.4...: return Color.yellow
        default:     return .red
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Gauge(value: score, in: 0...1) {
                EmptyView()
            } currentValueLabel: {
                Text(display)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(gaugeColor)
            }
            .gaugeStyle(.accessoryCircular)
            .tint(gaugeColor)
            .frame(width: 64, height: 64)

            Text("Relationship")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - ContactStatsBar

@MainActor
private struct ContactStatsBar: View {
    @Bindable var vm: ContactProfileViewModel

    var body: some View {
        HStack(spacing: 0) {
            StatPill(
                value: "\(vm.totalInteractionCount)",
                label: vm.totalInteractionCount == 1 ? "Interaction" : "Interactions"
            )
            statDivider
            StatPill(
                value: formattedMeetingTime,
                label: "Meeting time"
            )
            statDivider
            StatPill(
                value: "\(vm.openPromises.count)",
                label: "Open items"
            )
            statDivider
            StatPill(
                value: String(format: "%.0f%%", vm.promiseCompletionRate * 100),
                label: "Completed"
            )
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private var statDivider: some View {
        Divider().frame(height: 28)
    }

    private var formattedMeetingTime: String {
        let mins = vm.totalMeetingMinutes
        guard mins > 0 else { return "—" }
        if mins < 60 { return "\(mins)m" }
        let h = mins / 60
        let m = mins % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

private struct StatPill: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - AI Summary Card

private struct AISummaryCard: View {
    @Bindable var vm: ContactProfileViewModel

    var body: some View {
        ProfileSectionCard(title: "AI Summary", icon: "sparkles") {
            if vm.isRegeneratingAISummary {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Generating summary…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else if let summary = vm.contact.aiSummary, !summary.isEmpty {
                VStack(alignment: .trailing, spacing: 10) {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Button {
                        Task { await vm.regenerateAISummary() }
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Text("No summary yet")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        Task { await vm.regenerateAISummary() }
                    } label: {
                        Label("Generate", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Open Items Section

private struct OpenItemsSection: View {
    @Bindable var vm: ContactProfileViewModel

    var body: some View {
        ProfileSectionCard(title: "Open Items", icon: "checklist") {
            let outbound = vm.openPromises.filter { $0.direction == .userPromised }
            let inbound  = vm.openPromises.filter { $0.direction == .contactPromised }

            VStack(spacing: 0) {
                if !outbound.isEmpty {
                    sectionLabel("You promised", systemImage: "arrow.right.circle.fill", color: .orange)
                    ForEach(outbound) { promise in
                        PromiseRow(promise: promise, vm: vm)
                        if promise.id != outbound.last?.id { Divider().padding(.leading, 48) }
                    }
                }

                if !outbound.isEmpty && !inbound.isEmpty {
                    Divider().padding(.vertical, 4)
                }

                if !inbound.isEmpty {
                    sectionLabel("They promised", systemImage: "arrow.left.circle.fill", color: .blue)
                    ForEach(inbound) { promise in
                        PromiseRow(promise: promise, vm: vm)
                        if promise.id != inbound.last?.id { Divider().padding(.leading, 48) }
                    }
                }

                // Resolved items count
                let resolved = vm.promises.filter { $0.status == .done }.count
                if resolved > 0 {
                    Divider()
                    HStack {
                        Text("\(resolved) resolved item\(resolved == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionLabel(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .padding(.bottom, 4)
    }
}

// MARK: - PromiseRow

private struct PromiseRow: View {
    let promise: Promise
    @Bindable var vm: ContactProfileViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(promise.description)
                    .font(.subheadline)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if let quote = promise.sourceQuote {
                        Text("\u{201C}\(quote)\u{201D}")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .italic()
                    }
                    if let due = promise.dueDate {
                        Label(
                            due.formatted(date: .abbreviated, time: .omitted),
                            systemImage: promise.isOverdue ? "exclamationmark.triangle.fill" : "calendar"
                        )
                        .font(.caption2)
                        .foregroundStyle(promise.isOverdue ? .red : .secondary)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await vm.dismissPromise(promise) }
            } label: {
                Label("Dismiss", systemImage: "xmark.circle")
            }

            Button {
                Task { await vm.snoozePromise(promise) }
            } label: {
                Label("Snooze", systemImage: "clock.badge.questionmark")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .leading) {
            Button {
                Task { await vm.markPromiseDone(promise) }
            } label: {
                Label("Done", systemImage: "checkmark.circle.fill")
            }
            .tint(.green)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch promise.status {
        case .open where promise.isOverdue:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .open:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .snoozed:
            Image(systemName: "clock.fill")
                .foregroundStyle(.orange)
        case .dismissed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Key Facts Section

private struct KeyFactsSection: View {
    @Bindable var vm: ContactProfileViewModel

    var body: some View {
        ProfileSectionCard(title: "Key Facts", icon: "text.magnifyingglass") {
            // Tag cloud wrapping layout using FlowLayout
            TagCloudView(tags: vm.keyFacts)
        }
    }
}

// MARK: - TagCloudView

/// Wrapping tag cloud — lays out tags left-to-right, wrapping onto new lines.
private struct TagCloudView: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }
        }
    }
}

/// A simple left-to-right wrapping layout (no SwiftUI Layout protocol —
/// uses GeometryReader + fixed-width row approach for macOS 13 compatibility).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if currentX + size.width > width && currentX > 0 {
                totalHeight += rowHeight + spacing
                currentX = 0
                rowHeight = 0
            }
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight

        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentY += rowHeight + spacing
                currentX = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Timeline Section

private struct InteractionTimelineSection: View {
    @Bindable var vm: ContactProfileViewModel

    var body: some View {
        ProfileSectionCard(title: "Timeline", icon: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
            VStack(spacing: 0) {
                // Filter picker
                Picker("Filter", selection: $vm.timelineFilter) {
                    ForEach(InteractionFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 14)

                let items = vm.filteredInteractions

                if items.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: "clock.badge.xmark")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                            Text("No \(vm.timelineFilter == .all ? "" : vm.timelineFilter.rawValue.lowercased() + " ")interactions yet")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 20)
                        Spacer()
                    }
                } else {
                    // Timeline rows with vertical connector line.
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, interaction in
                            InteractionTimelineRow(
                                interaction: interaction,
                                isLast: idx == items.count - 1
                            )
                        }
                    }

                    // Load-more
                    if vm.hasMoreInteractions {
                        Button {
                            Task { await vm.loadMoreInteractions() }
                        } label: {
                            if vm.isLoadingMoreInteractions {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Loading…")
                                }
                            } else {
                                Text("Load more")
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                    }
                }
            }
        }
    }
}

// MARK: - InteractionTimelineRow

private struct InteractionTimelineRow: View {
    let interaction: Interaction
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Date column
            VStack(alignment: .trailing, spacing: 1) {
                Text(interaction.startedAt, format: .dateTime.month(.abbreviated).day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(interaction.startedAt, format: .dateTime.year())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 52)
            .padding(.top, 2)

            // Connector column: dot + vertical line
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(interaction.interactionType.tintColor)
                        .frame(width: 10, height: 10)
                }
                .padding(.top, 4)
                .frame(width: 28)

                if !isLast {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 28)

            // Content
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: interaction.interactionType.systemImage)
                        .font(.caption)
                        .foregroundStyle(interaction.interactionType.tintColor)

                    Text(interaction.summary ?? interaction.interactionType.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if let dur = interaction.durationFormatted {
                        Text(dur)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }

                if let summary = interaction.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Content tag pills (top 4)
                if !interaction.contentTags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(interaction.contentTags.prefix(4), id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 10))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(nsColor: .quaternaryLabelColor), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                        if interaction.contentTags.count > 4 {
                            Text("+\(interaction.contentTags.count - 4)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                // Importance dot for high-importance interactions
                if interaction.importance >= 0.75 {
                    Label("High importance", systemImage: "exclamationmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.leading, 8)
            .padding(.bottom, isLast ? 4 : 16)
        }
    }
}

// MARK: - Notes Section

private struct ContactNotesSection: View {
    @Bindable var vm: ContactProfileViewModel

    var body: some View {
        ProfileSectionCard(title: "Notes", icon: "note.text") {
            VStack(alignment: .trailing, spacing: 8) {
                TextEditor(text: $vm.notesText)
                    .font(.subheadline)
                    .scrollContentBackground(.hidden)
                    .background(.clear)
                    .frame(minHeight: 80, maxHeight: 200)
                    .onChange(of: vm.notesText) { _, _ in
                        vm.scheduleNoteSave()
                    }

                // Save status indicator
                HStack(spacing: 4) {
                    if vm.isSavingNote {
                        ProgressView().controlSize(.mini)
                        Text("Saving…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else if let saved = vm.lastNoteSavedAt {
                        Image(systemName: "checkmark")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        Text("Saved \(saved, style: .relative) ago")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else if !vm.notesText.isEmpty {
                        Text("Not yet saved")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

// MARK: - ProfileSectionCard

/// Reusable card container used by every section below the header.
struct ProfileSectionCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

// MARK: - Skeleton loading

private struct ContactProfileSkeletonView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header skeleton
            HStack(spacing: 20) {
                SkeletonCircle(size: 72)
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonRect(width: 200, height: 22)
                    SkeletonRect(width: 140, height: 15)
                    SkeletonRect(width: 170, height: 12)
                }
                Spacer()
                SkeletonCircle(size: 64)
            }

            // Stats bar skeleton
            HStack {
                ForEach(0..<4) { _ in
                    VStack(spacing: 4) {
                        SkeletonRect(width: 36, height: 18)
                        SkeletonRect(width: 52, height: 10)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Divider()

            // Cards skeleton
            VStack(spacing: 16) {
                SkeletonCardRect(height: 88)
                SkeletonCardRect(height: 120)
                SkeletonCardRect(height: 60)
                SkeletonCardRect(height: 240)
            }
        }
        .padding(24)
        .redacted(reason: .placeholder)
    }
}

private struct SkeletonRect: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color(nsColor: .quaternaryLabelColor))
            .frame(width: width, height: height)
            .shimmer()
    }
}

private struct SkeletonCircle: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(Color(nsColor: .quaternaryLabelColor))
            .frame(width: size, height: size)
            .shimmer()
    }
}

private struct SkeletonCardRect: View {
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(nsColor: .quaternaryLabelColor))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .shimmer()
    }
}

private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1.0

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white.opacity(0.25), location: 0.4),
                        .init(color: .white.opacity(0.35), location: 0.5),
                        .init(color: .white.opacity(0.25), location: 0.6),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: UnitPoint(x: phase, y: 0),
                    endPoint: UnitPoint(x: phase + 1, y: 0)
                )
                .blendMode(.lighten)
            )
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1.0
                }
            }
    }
}

private extension View {
    func shimmer() -> some View { modifier(ShimmerModifier()) }
}

// MARK: - Merge Contact Sheet

@MainActor
private struct MergeContactSheet: View {
    @Bindable var vm: ContactProfileViewModel
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    private var candidates: [Contact] {
        guard !searchText.isEmpty else { return vm.mergeableContacts }
        let q = searchText.lowercased()
        return vm.mergeableContacts.filter {
            $0.displayName.lowercased().contains(q) ||
            ($0.company?.lowercased().contains(q) ?? false) ||
            ($0.emailPrimary?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Merge Contact")
                        .font(.headline)
                    Text("Select a contact to merge into \(vm.contact.displayName). The selected contact will be removed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(16)

            Divider()

            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search contacts…", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Contact list
            if vm.mergeableContacts.isEmpty {
                ContentUnavailableView(
                    "No Other Contacts",
                    systemImage: "person.2.slash",
                    description: Text("There are no other contacts to merge with.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(candidates) { candidate in
                    Button {
                        Task { await vm.mergeWith(candidate) }
                    } label: {
                        HStack(spacing: 12) {
                            ContactAvatarView(contact: candidate, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.displayName).fontWeight(.medium)
                                if let company = candidate.company {
                                    Text(company).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 400, height: 480)
    }
}
