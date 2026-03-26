import SwiftUI
import os

// MARK: - ReviewQueueView

/// The billing review screen — users approve or reject work sessions that the
/// AI pipeline has clustered and attributed to clients.
///
/// Session status lifecycle:
///   `.suggested` (unreviewed) → `.confirmed` (billable) or `.rejected`
///
/// The sidebar badge (`AppState.pendingReviewCount`) reflects `.suggested` count
/// and is updated in real time by `ReviewQueueViewModel.syncBadge()`.
@MainActor
struct ReviewQueueView: View {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "ReviewQueueView"
    )

    @Environment(AppState.self) private var appState
    @State private var vm = ReviewQueueViewModel()

    var body: some View {
        @Bindable var vm = vm

        VStack(spacing: 0) {
            weekNavigationHeader
            Divider()

            if !vm.sessions.isEmpty {
                weekSummaryBar
                Divider()
            }

            if vm.isMergeMode {
                mergeBanner
                Divider()
            }

            Group {
                if vm.isLoading && vm.sessions.isEmpty {
                    ProgressView("Loading sessions…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.sessions.isEmpty && !vm.isLoading {
                    emptyState
                } else {
                    sessionList
                }
            }
        }
        .navigationTitle("Review Queue")
        .navigationSubtitle(vm.weekLabel)
        .toolbar { toolbarContent }
        .task { await vm.load() }
        .sheet(isPresented: $vm.isPresentingExport) {
            ExportSheet(
                weekStart: vm.selectedWeek,
                weekEnd: Calendar.current.date(byAdding: .day, value: 7, to: vm.selectedWeek)!,
                availableClients: Array(vm.clients.values).sorted { $0.name < $1.name }
            ) { clientIds, format, includeRejected, includeNonBillable in
                Task {
                    await vm.exportBillingData(
                        clientIds: clientIds,
                        format: format,
                        includeRejected: includeRejected,
                        includeNonBillable: includeNonBillable
                    )
                }
            }
        }
        .sheet(item: $vm.reassigningSession) { session in
            ReassignSheet(
                session: session,
                currentClient: vm.clients[session.clientId ?? ""],
                currentProject: vm.projects[session.projectId ?? ""],
                allClients: vm.allClients,
                projectsForClient: vm.projectsForClient,
                onLoadProjects: { clientId in
                    Task { await vm.loadProjectsForReassign(clientId: clientId) }
                }
            ) { newClientId, newProjectId in
                Task { await vm.reassign(session, clientId: newClientId, projectId: newProjectId) }
            }
        }
        .confirmationDialog(
            "Approve All Sessions?",
            isPresented: $vm.isPresentingApproveAll,
            titleVisibility: .visible
        ) {
            Button("Approve All \(vm.pendingSessions.count) Sessions") {
                Task { await vm.approveAll() }
            }
            if !vm.lowConfidencePendingSessions.isEmpty {
                Button("Approve Only High-Confidence (\(vm.pendingSessions.count - vm.lowConfidencePendingSessions.count))")  {
                    let highConf = vm.pendingSessions.filter { $0.confidence >= 0.4 }
                    Task {
                        for s in highConf { await vm.confirm(s) }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if vm.lowConfidencePendingSessions.isEmpty {
                Text("This will confirm \(vm.pendingSessions.count) session\(vm.pendingSessions.count == 1 ? "" : "s") as billable.")
            } else {
                Text("\(vm.lowConfidencePendingSessions.count) session\(vm.lowConfidencePendingSessions.count == 1 ? " has" : "s have") low AI confidence. Review them individually for best accuracy.")
            }
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

    // MARK: - Week navigation header

    private var weekNavigationHeader: some View {
        HStack(spacing: 12) {
            Button {
                vm.previousWeek()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Previous week")

            Text(vm.weekRangeLabel)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()

            Button {
                vm.nextWeek()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(vm.isCurrentWeek)
            .help("Next week")

            if !vm.isCurrentWeek {
                Button("Today") {
                    vm.selectedWeek = ReviewQueueViewModel.currentWeekStart()
                    Task { await vm.load() }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            }

            Spacer()

            if vm.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Summary bar

    private var weekSummaryBar: some View {
        HStack(spacing: 20) {
            SummaryPill(
                value: "\(vm.summarySessionCount)",
                label: vm.summarySessionCount == 1 ? "session" : "sessions"
            )
            SummaryPill(
                value: String(format: "%.1fh", vm.summaryTotalHours),
                label: "total"
            )
            if vm.summaryEstimatedValue > 0 {
                SummaryPill(
                    value: "$\(Int(vm.summaryEstimatedValue))",
                    label: "estimated"
                )
            }

            Spacer()

            // Pending badge
            if vm.pendingSessions.count > 0 {
                Text("\(vm.pendingSessions.count) pending review")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                vm.isPresentingExport = true
            } label: {
                Label("Export Invoice", systemImage: "square.and.arrow.up")
            }
            .disabled(vm.sessions.isEmpty)
            .help("Export billing data")

            if !vm.pendingSessions.isEmpty {
                Button {
                    vm.isPresentingApproveAll = true
                } label: {
                    Label("Approve All", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(vm.lowConfidencePendingSessions.isEmpty ? .green : .orange)
                .help(vm.lowConfidencePendingSessions.isEmpty
                    ? "Approve all \(vm.pendingSessions.count) sessions"
                    : "\(vm.lowConfidencePendingSessions.count) low-confidence session\(vm.lowConfidencePendingSessions.count == 1 ? "" : "s") — review recommended")
            }
        }
    }

    // MARK: - Merge banner

    private var mergeBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Merge mode")
                    .font(.subheadline.weight(.semibold))
                Text(vm.mergeSelection.count == 0
                    ? "Select a session to merge"
                    : vm.mergeSelection.count == 1
                        ? "Now select a second session"
                        : "Ready to merge 2 sessions")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if vm.mergeSelection.count == 2 {
                Button("Merge") {
                    Task { await vm.executeMerge() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(vm.isMerging)
            }
            Button("Cancel") { vm.cancelMerge() }
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.06))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        EmptyStateView(
            icon: "checkmark.circle",
            title: "All caught up",
            subtitle: "No work sessions require review for this week. Navigate to a different week or check back after more activity is captured."
        )
    }

    // MARK: - Session list

    private var sessionList: some View {
        @Bindable var vm = vm

        return List {
            ForEach(vm.sessionGroups) { group in
                ClientGroupSection(
                    group: group,
                    vm: vm,
                    draftDescription: $vm.draftDescription,
                    draftDurationText: $vm.draftDurationText
                )
            }
        }
        .listStyle(.plain)
        .animation(.default, value: vm.sessions.map(\.billableStatus.rawValue).joined())
    }
}

// MARK: - SummaryPill

private struct SummaryPill: View {
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - ClientGroupSection

private struct ClientGroupSection: View {
    let group: ClientSessionGroup
    let vm: ReviewQueueViewModel
    @Binding var draftDescription: String
    @Binding var draftDurationText: String

    @State private var isExpanded: Bool = true

    var body: some View {
        Section {
            if isExpanded {
                ForEach(group.sessions) { session in
                    SessionCardView(
                        session: session,
                        client: group.client,
                        project: vm.projects[session.projectId ?? ""],
                        sources: vm.sessionSources[session.id] ?? [],
                        evidenceItems: vm.evidence[session.id] ?? [],
                        isEvidenceExpanded: vm.expandedEvidenceIds.contains(session.id),
                        isLoadingEvidence: vm.loadingEvidenceIds.contains(session.id),
                        isMergeMode: vm.isMergeMode,
                        isSelectedForMerge: vm.mergeSelection.contains(session.id),
                        isEditing: vm.editingSessionId == session.id,
                        draftDescription: $draftDescription,
                        draftDurationText: $draftDurationText,
                        onConfirm: { Task { await vm.confirm(session) } },
                        onReject: { Task { await vm.reject(session) } },
                        onBeginEdit: { vm.beginEdit(session) },
                        onSaveEdit: { Task { await vm.saveEdit(session) } },
                        onCancelEdit: { vm.cancelEdit() },
                        onToggleEvidence: { Task { await vm.toggleEvidence(for: session.id) } },
                        onMerge: {
                            if vm.isMergeMode {
                                vm.toggleMergeSelection(session.id)
                            } else {
                                vm.startMerge(with: session.id)
                            }
                        },
                        onReassign: { vm.reassigningSession = session }
                    )
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }
        } header: {
            ClientGroupHeader(
                group: group,
                isExpanded: $isExpanded
            )
        }
    }
}

// MARK: - ClientGroupHeader

private struct ClientGroupHeader: View {
    let group: ClientSessionGroup
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                ClientAvatarView(name: group.client.name, size: 24)

                Text(group.client.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                if group.pendingCount > 0 {
                    Text("\(group.pendingCount) pending")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange)
                        .clipShape(Capsule())
                }

                Spacer()

                Text(String(format: "%.1fh", group.totalHours))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Text("· \(group.sessions.count) session\(group.sessions.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }
}

// MARK: - SessionCardView

private struct SessionCardView: View {
    let session: WorkSession
    let client: Client?
    let project: Project?
    let sources: [EventSource]
    let evidenceItems: [RawEvent]
    let isEvidenceExpanded: Bool
    let isLoadingEvidence: Bool
    let isMergeMode: Bool
    let isSelectedForMerge: Bool
    let isEditing: Bool
    @Binding var draftDescription: String
    @Binding var draftDurationText: String

    var onConfirm: () -> Void
    var onReject: () -> Void
    var onBeginEdit: () -> Void
    var onSaveEdit: () -> Void
    var onCancelEdit: () -> Void
    var onToggleEvidence: () -> Void
    var onMerge: () -> Void
    var onReassign: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                // Status column
                SessionStatusIcon(status: session.billableStatus)
                    .padding(.top, 1)

                // Content column
                VStack(alignment: .leading, spacing: 6) {
                    metaRow
                    descriptionRow
                    badgeRow

                    if isMergeMode {
                        mergeSelectionRow
                    } else if isEditing {
                        editPanel
                    } else {
                        actionBar
                    }
                }
            }
            .padding(14)

            if isEvidenceExpanded {
                Divider()
                EvidencePanelView(
                    evidence: evidenceItems,
                    isLoading: isLoadingEvidence
                )
                .padding(14)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity
                ))
            }
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(cardBorderColor, lineWidth: isSelectedForMerge ? 2 : 0.5)
        )
        .opacity(session.billableStatus == .rejected ? 0.55 : 1.0)
        .animation(.easeInOut(duration: 0.18), value: isEvidenceExpanded)
        .animation(.easeInOut(duration: 0.15), value: isSelectedForMerge)
    }

    // MARK: - Row sub-views

    private var metaRow: some View {
        HStack(spacing: 6) {
            // Day + date
            Text(session.startedAt, format: .dateTime.weekday(.abbreviated))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(session.startedAt, format: .dateTime.month(.abbreviated).day())
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(session.durationFormatted)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()

            Spacer(minLength: 8)

            if let proj = project {
                Text(proj.name)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var descriptionRow: some View {
        Group {
            if isEditing {
                TextEditor(text: $draftDescription)
                    .font(.subheadline)
                    .frame(minHeight: 48, maxHeight: 96)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Text(session.description ?? "Work session")
                    .font(.subheadline)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var badgeRow: some View {
        HStack(spacing: 6) {
            ConfidenceBadge(confidence: session.confidence)

            if !sources.isEmpty {
                ForEach(sources, id: \.self) { source in
                    SourceBadgeView(source: source)
                }
            }

            Spacer()
        }
    }

    private var actionBar: some View {
        HStack(spacing: 2) {
            // Confirm
            ActionButton(
                label: session.billableStatus == .confirmed ? "Confirmed" : "Confirm",
                systemImage: session.billableStatus == .confirmed
                    ? "checkmark.circle.fill" : "checkmark.circle",
                tint: session.billableStatus == .confirmed ? .green : nil,
                isActive: session.billableStatus == .confirmed
            ) { onConfirm() }

            // Reject
            ActionButton(
                label: session.billableStatus == .rejected ? "Rejected" : "Reject",
                systemImage: session.billableStatus == .rejected
                    ? "xmark.circle.fill" : "xmark.circle",
                tint: session.billableStatus == .rejected ? .secondary : nil,
                isActive: session.billableStatus == .rejected
            ) { onReject() }

            Spacer()

            // Edit
            ActionButton(label: "Edit", systemImage: "pencil") { onBeginEdit() }

            // Reassign
            ActionButton(label: "Reassign", systemImage: "arrow.triangle.2.circlepath") { onReassign() }

            // Merge
            ActionButton(label: "Merge", systemImage: "arrow.triangle.merge") { onMerge() }

            // Evidence
            ActionButton(
                label: isEvidenceExpanded ? "Hide" : "Evidence",
                systemImage: isEvidenceExpanded ? "chevron.up.circle" : "doc.text.magnifyingglass"
            ) { onToggleEvidence() }
        }
        .padding(.top, 4)
    }

    private var editPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Duration (hours):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("2.5", text: $draftDurationText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .font(.system(.caption, design: .monospaced))
                Spacer()
                Button("Cancel") { onCancelEdit() }
                    .controlSize(.small)
                Button("Save") { onSaveEdit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.top, 4)
    }

    private var mergeSelectionRow: some View {
        HStack {
            if isSelectedForMerge {
                Label(
                    mergeSelectionOrdinal,
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)

                Button("Deselect") { onMerge() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    onMerge()
                } label: {
                    Label("Select for merge", systemImage: "circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    private var mergeSelectionOrdinal: String {
        // mergeSelection order is tracked in VM; we just show generic label here
        isSelectedForMerge ? "Selected" : ""
    }

    // MARK: - Computed colors

    private var cardBackground: Color {
        if isSelectedForMerge {
            return Color.accentColor.opacity(0.06)
        }
        switch session.billableStatus {
        case .confirmed: return Color.green.opacity(0.04)
        case .rejected:  return Color(nsColor: .controlBackgroundColor).opacity(0.3)
        default:         return Color(nsColor: .controlBackgroundColor).opacity(0.5)
        }
    }

    private var cardBorderColor: Color {
        if isSelectedForMerge { return .accentColor }
        switch session.billableStatus {
        case .confirmed: return Color.green.opacity(0.4)
        default:         return Color(nsColor: .separatorColor)
        }
    }
}

// MARK: - ActionButton

private struct ActionButton: View {
    let label: String
    let systemImage: String
    var tint: Color? = nil
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint ?? .primary)
                .labelStyle(.iconOnly)
                .frame(width: 26, height: 22)
                .background(isActive ? (tint ?? .accentColor).opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

// MARK: - SessionStatusIcon

private struct SessionStatusIcon: View {
    let status: BillableStatus

    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(iconColor)
            .frame(width: 20)
    }

    private var iconName: String {
        switch status {
        case .confirmed:   return "checkmark.circle.fill"
        case .rejected:    return "xmark.circle.fill"
        case .nonBillable: return "minus.circle.fill"
        case .suggested:   return "questionmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch status {
        case .confirmed:   return .green
        case .rejected:    return Color(nsColor: .quaternaryLabelColor)
        case .nonBillable: return Color(nsColor: .tertiaryLabelColor)
        case .suggested:   return .orange
        }
    }
}

// MARK: - ConfidenceBadge

private struct ConfidenceBadge: View {
    let confidence: Double

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
    }

    private var label: String {
        if confidence >= 0.75 { return "High" }
        if confidence >= 0.40 { return "Medium" }
        return "Low"
    }

    private var color: Color {
        if confidence >= 0.75 { return .green }
        if confidence >= 0.40 { return .orange }
        return .red
    }
}

// MARK: - SourceBadgeView

private struct SourceBadgeView: View {
    let source: EventSource

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: source.reviewSystemImage)
                .font(.system(size: 8))
                .foregroundStyle(source.reviewTintColor)
            Text(source.shortLabel)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(source.reviewTintColor.opacity(0.08))
        .clipShape(Capsule())
    }
}

// MARK: - EvidencePanelView

private struct EvidencePanelView: View {
    let evidence: [RawEvent]
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Contributing Evidence", systemImage: "doc.text.magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if isLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading evidence…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if evidence.isEmpty {
                Text("No raw events linked to this session.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .italic()
            } else {
                VStack(spacing: 0) {
                    ForEach(evidence) { event in
                        RawEventRowView(event: event)
                        if event.id != evidence.last?.id {
                            Divider().padding(.leading, 36)
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
            }
        }
    }
}

// MARK: - RawEventRowView

private struct RawEventRowView: View {
    let event: RawEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Source icon
            ZStack {
                Circle()
                    .fill(event.source.reviewTintColor.opacity(0.1))
                Image(systemName: event.source.reviewSystemImage)
                    .font(.system(size: 9))
                    .foregroundStyle(event.source.reviewTintColor)
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                // Timestamp + source label + app
                HStack(spacing: 5) {
                    Text(event.startedAt, format: .dateTime.hour().minute())
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(event.source.shortLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let app = event.sourceApp {
                        Text("· \(app)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    if let dur = event.durationSecs {
                        let mins = dur / 60
                        if mins > 0 {
                            Text("· \(mins) min")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                // Snippet
                if let text = snippetText {
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// Returns the best available snippet: rawText prefix or metadata subject/title.
    private var snippetText: String? {
        if let raw = event.rawText, !raw.isEmpty {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = trimmed.prefix(200)
            return preview.isEmpty ? nil : String(preview) + (trimmed.count > 200 ? "…" : "")
        }
        if let meta = event.metadataJSON, !meta.isEmpty {
            // Try to extract "subject" from JSON without a full decoder.
            if let range = meta.range(of: "\"subject\":\""),
               let endQ = meta[range.upperBound...].firstIndex(of: "\"") {
                let subject = String(meta[range.upperBound..<endQ])
                if !subject.isEmpty { return subject }
            }
        }
        return nil
    }
}

// MARK: - ReassignSheet

private struct ReassignSheet: View {
    let session: WorkSession
    let currentClient: Client?
    let currentProject: Project?
    let allClients: [Client]
    let projectsForClient: [EntityID: [Project]]
    let onLoadProjects: (EntityID) -> Void
    let onReassign: (EntityID?, EntityID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedClientId: EntityID?
    @State private var selectedProjectId: EntityID?

    init(
        session: WorkSession,
        currentClient: Client?,
        currentProject: Project?,
        allClients: [Client],
        projectsForClient: [EntityID: [Project]],
        onLoadProjects: @escaping (EntityID) -> Void,
        onReassign: @escaping (EntityID?, EntityID?) -> Void
    ) {
        self.session = session
        self.currentClient = currentClient
        self.currentProject = currentProject
        self.allClients = allClients
        self.projectsForClient = projectsForClient
        self.onLoadProjects = onLoadProjects
        self.onReassign = onReassign
        _selectedClientId = State(initialValue: currentClient?.id)
        _selectedProjectId = State(initialValue: currentProject?.id)
    }

    private var availableProjects: [Project] {
        guard let id = selectedClientId else { return [] }
        return projectsForClient[id] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reassign Session")
                        .font(.headline)
                    Text(session.description ?? "Work session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            Form {
                Section("Client") {
                    Picker("Client", selection: $selectedClientId) {
                        Text("Unassigned").tag(EntityID?.none)
                        ForEach(allClients) { client in
                            Text(client.name).tag(EntityID?.some(client.id))
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedClientId) { _, newId in
                        selectedProjectId = nil
                        if let id = newId {
                            onLoadProjects(id)
                        }
                    }
                }

                Section("Project") {
                    if selectedClientId == nil {
                        Text("Select a client first")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                    } else if availableProjects.isEmpty {
                        Text("No projects for this client")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                    } else {
                        Picker("Project", selection: $selectedProjectId) {
                            Text("None").tag(EntityID?.none)
                            ForEach(availableProjects) { project in
                                HStack {
                                    Text(project.name)
                                    if let rate = project.hourlyRate {
                                        Text(String(format: "$%.0f/hr", rate))
                                            .foregroundStyle(.secondary)
                                    }
                                }.tag(EntityID?.some(project.id))
                            }
                        }
                        .labelsHidden()
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 220)

            Divider()

            HStack {
                Spacer()
                Button("Reassign") {
                    onReassign(selectedClientId, selectedProjectId)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - ExportSheet

private struct ExportSheet: View {
    let weekStart: Date
    let weekEnd: Date
    let availableClients: [Client]
    let onExport: ([EntityID], ExportFormat, Bool, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedFormat: ExportFormat = .pdf
    @State private var exportAllClients: Bool = true
    @State private var selectedClientIds: Set<EntityID> = []
    @State private var fromDate: Date
    @State private var toDate: Date
    @State private var includeRejected: Bool = false
    @State private var includeNonBillable: Bool = false
    @State private var isExporting: Bool = false

    init(
        weekStart: Date,
        weekEnd: Date,
        availableClients: [Client],
        onExport: @escaping ([EntityID], ExportFormat, Bool, Bool) -> Void
    ) {
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.availableClients = availableClients
        self.onExport = onExport
        _fromDate = State(initialValue: weekStart)
        _toDate = State(initialValue: weekEnd)
    }

    private var exportClientIds: [EntityID] {
        exportAllClients ? availableClients.map(\.id) : Array(selectedClientIds)
    }

    private var canExport: Bool {
        exportAllClients || !selectedClientIds.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export Invoice")
                        .font(.headline)
                    Text("Generate a billing export for the selected period.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            Form {
                // Format
                Section("Format") {
                    Picker("Format", selection: $selectedFormat) {
                        ForEach(ExportFormat.allCases) { fmt in
                            Text(fmt.rawValue).tag(fmt)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // Clients
                Section("Clients") {
                    Toggle("All clients", isOn: $exportAllClients)
                    if !exportAllClients {
                        ForEach(availableClients) { client in
                            Toggle(client.name, isOn: Binding(
                                get: { selectedClientIds.contains(client.id) },
                                set: { on in
                                    if on { selectedClientIds.insert(client.id) }
                                    else  { selectedClientIds.remove(client.id) }
                                }
                            ))
                        }
                    }
                }

                // Date range
                Section("Date Range") {
                    DatePicker("From", selection: $fromDate, displayedComponents: .date)
                    DatePicker("To",   selection: $toDate,   displayedComponents: .date)
                }

                // Options
                Section("Include") {
                    Toggle("Rejected sessions", isOn: $includeRejected)
                    Toggle("Non-billable sessions", isOn: $includeNonBillable)
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                if selectedFormat == .pdf {
                    Label("Opens macOS Print / Save as PDF dialog", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Export") {
                    isExporting = true
                    onExport(exportClientIds, selectedFormat, includeRejected, includeNonBillable)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canExport || isExporting)
            }
            .padding(16)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - SessionReviewRow
// Kept internal (non-private) for use in BillingView.

/// A compact session row for use in `BillingView` and other contexts that
/// don't need the full `SessionCardView` affordances.
struct SessionReviewRow: View {
    let session: WorkSession

    var body: some View {
        HStack(spacing: 12) {
            SessionStatusIconCompact(status: session.billableStatus)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.description ?? "Work session")
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(session.startedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(session.durationFormatted)
                    .font(.subheadline)
                    .monospacedDigit()
                Text(session.billableStatus.displayLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(session.billableStatus.displayColor)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SessionStatusIconCompact: View {
    let status: BillableStatus
    var body: some View {
        Image(systemName: status.iconName)
            .font(.system(size: 14))
            .foregroundStyle(status.displayColor)
            .frame(width: 18)
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

// MARK: - BillableStatus display helpers

extension BillableStatus {
    fileprivate var iconName: String {
        switch self {
        case .confirmed:   return "checkmark.circle.fill"
        case .rejected:    return "xmark.circle.fill"
        case .nonBillable: return "minus.circle.fill"
        case .suggested:   return "questionmark.circle.fill"
        }
    }

    var displayLabel: String {
        switch self {
        case .confirmed:   return "Confirmed"
        case .rejected:    return "Rejected"
        case .nonBillable: return "Non-billable"
        case .suggested:   return "Pending review"
        }
    }

    var displayColor: Color {
        switch self {
        case .confirmed:   return .green
        case .rejected:    return Color(nsColor: .secondaryLabelColor)
        case .nonBillable: return Color(nsColor: .tertiaryLabelColor)
        case .suggested:   return .orange
        }
    }
}
