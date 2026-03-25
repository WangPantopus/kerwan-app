import SwiftUI
import Charts
import os

// MARK: - ClientDetailView

/// Full detail screen for a single billing client.
///
/// Sections:
///  1. Header stats (avatar, name, domain, total hours, billed this month)
///  2. Billing chart — 12-week stacked bar (billable vs other)
///  3. Contacts — linked contacts with Add Contact action
///  4. Projects — project list with hourly rates, New Project action
///  5. Recent Interactions — timeline filtered to this client
///  6. Work Sessions — sessions grouped by ISO week
///
/// Navigated to via `NavigationLink(value: Client)` in `ClientListView`.
struct ClientDetailView: View {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "ClientDetailView"
    )

    let client: Client

    @Environment(AppState.self) private var appState
    @State private var vm: ClientDetailViewModel

    init(client: Client) {
        self.client = client
        _vm = State(wrappedValue: ClientDetailViewModel(client: client))
    }

    var body: some View {
        Group {
            if vm.isLoadingInitial {
                ClientDetailSkeletonView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        headerSection
                        billingChartSection
                        contactsSection
                        projectsSection
                        recentInteractionsSection
                        workSessionsSection
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle(vm.client.name)
        .navigationSubtitle(vm.client.domain ?? "")
        .toolbar { toolbarContent }
        .task { await vm.load() }
        .sheet(isPresented: $vm.isPresentingNewProject) {
            NewProjectSheet { name, rate in
                Task { await vm.createProject(name: name, hourlyRate: rate) }
            }
        }
        .sheet(isPresented: $vm.isPresentingAddContact) {
            AddContactSheet(contacts: vm.unlinkedContacts) { contact in
                Task { await vm.linkContact(contact) }
            }
            .task { await vm.loadUnlinkedContacts() }
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                vm.isPresentingAddContact = true
            } label: {
                Label("Add Contact", systemImage: "person.badge.plus")
            }
            .help("Link a contact to this client")

            Button {
                vm.isPresentingNewProject = true
            } label: {
                Label("New Project", systemImage: "folder.badge.plus")
            }
            .help("Create a new project for this client")
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 20) {
            ClientAvatarView(name: vm.client.name, size: 60)

            VStack(alignment: .leading, spacing: 6) {
                Text(vm.client.name)
                    .font(.title2.weight(.semibold))
                if let domain = vm.client.domain {
                    Text(domain)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let notes = vm.client.notes {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }

            Spacer()

            // Quick stats cluster
            HStack(spacing: 24) {
                ClientHeaderStat(
                    value: String(format: "%.1fh", vm.totalHoursAllTime),
                    label: "all time"
                )
                ClientHeaderStat(
                    value: String(format: "%.1fh", vm.billedHoursThisMonth),
                    label: "this month"
                )
                if vm.billedValueThisMonth > 0 {
                    ClientHeaderStat(
                        value: "$\(Int(vm.billedValueThisMonth))",
                        label: "billed value"
                    )
                }
                ClientHeaderStat(
                    value: "\(vm.contacts.count)",
                    label: vm.contacts.count == 1 ? "contact" : "contacts"
                )
            }
        }
        .padding(20)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    // MARK: - Billing chart

    private var billingChartSection: some View {
        DetailSectionCard(title: "Hours — Last 12 Weeks", systemImage: "chart.bar") {
            if vm.weeklyHours.isEmpty {
                Text("No work sessions recorded yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                Chart {
                    ForEach(vm.weeklyHours) { week in
                        BarMark(
                            x: .value("Week", week.weekStart, unit: .weekOfYear),
                            y: .value("Hours", week.billableHours)
                        )
                        .foregroundStyle(by: .value("Type", "Billable"))

                        BarMark(
                            x: .value("Week", week.weekStart, unit: .weekOfYear),
                            y: .value("Hours", max(0, week.totalHours - week.billableHours))
                        )
                        .foregroundStyle(by: .value("Type", "Other"))
                    }
                }
                .chartForegroundStyleScale([
                    "Billable": Color.accentColor,
                    "Other": Color.secondary.opacity(0.25)
                ])
                .chartXAxis {
                    AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { value in
                        if let date = value.as(Date.self) {
                            AxisValueLabel {
                                Text(date, format: .dateTime.month(.abbreviated).day())
                                    .font(.system(size: 9))
                            }
                        }
                        AxisGridLine()
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let h = value.as(Double.self) {
                                Text("\(Int(h))h").font(.system(size: 9))
                            }
                        }
                        AxisGridLine()
                    }
                }
                .frame(height: 180)
            }
        }
    }

    // MARK: - Contacts

    private var contactsSection: some View {
        DetailSectionCard(title: "Contacts", systemImage: "person.2") {
            if vm.contacts.isEmpty {
                EmptyStateView(
                    icon: "person.crop.circle",
                    title: "No contacts yet",
                    subtitle: "Link contacts to track interactions and relationship strength.",
                    actionLabel: "Add Contact"
                ) {
                    vm.isPresentingAddContact = true
                }
                .frame(minHeight: 120)
            } else {
                VStack(spacing: 0) {
                    ForEach(vm.contacts) { contact in
                        NavigationLink(value: contact) {
                            ContactRowView(contact: contact)
                        }
                        .buttonStyle(.plain)
                        if contact.id != vm.contacts.last?.id {
                            Divider().padding(.leading, 54)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )

                Button {
                    vm.isPresentingAddContact = true
                } label: {
                    Label("Add Contact", systemImage: "person.badge.plus")
                }
                .font(.subheadline)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Projects

    private var projectsSection: some View {
        DetailSectionCard(title: "Projects", systemImage: "folder") {
            if vm.projects.isEmpty {
                EmptyStateView(
                    icon: "folder",
                    title: "No projects yet",
                    subtitle: "Create a project to track billable work with hourly rates.",
                    actionLabel: "New Project"
                ) {
                    vm.isPresentingNewProject = true
                }
                .frame(minHeight: 120)
            } else {
                VStack(spacing: 0) {
                    ForEach(vm.projects) { project in
                        ProjectRowView(project: project)
                        if project.id != vm.projects.last?.id {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )

                Button {
                    vm.isPresentingNewProject = true
                } label: {
                    Label("New Project", systemImage: "folder.badge.plus")
                }
                .font(.subheadline)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Recent Interactions

    private var recentInteractionsSection: some View {
        DetailSectionCard(title: "Recent Interactions", systemImage: "clock") {
            if vm.recentInteractions.isEmpty {
                Text("No interactions recorded yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            } else {
                VStack(spacing: 0) {
                    ForEach(vm.recentInteractions) { interaction in
                        ClientInteractionRow(interaction: interaction)
                        if interaction.id != vm.recentInteractions.last?.id {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Work Sessions

    private var workSessionsSection: some View {
        DetailSectionCard(title: "Work Sessions", systemImage: "timer") {
            if vm.sessionsByWeek.isEmpty {
                Text("No work sessions recorded yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            } else {
                VStack(spacing: 16) {
                    ForEach(vm.sessionsByWeek, id: \.weekStart) { group in
                        WorkSessionWeekGroup(
                            label: group.label,
                            sessions: group.sessions,
                            projects: vm.projects
                        )
                    }
                }
            }
        }
    }
}

// MARK: - DetailSectionCard

private struct DetailSectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

// MARK: - ClientHeaderStat

private struct ClientHeaderStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - ProjectRowView

private struct ProjectRowView: View {
    let project: Project

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let rate = project.hourlyRate {
                    Text(String(format: "$%.0f / hr", rate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No hourly rate set")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }
}

// MARK: - ClientInteractionRow

private struct ClientInteractionRow: View {
    let interaction: Interaction

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(interaction.interactionType.tintColor.opacity(0.12))
                Image(systemName: interaction.interactionType.systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(interaction.interactionType.tintColor)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(interaction.summary ?? interaction.interactionType.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(interaction.startedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let dur = interaction.durationFormatted {
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
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }
}

// MARK: - WorkSessionWeekGroup

private struct WorkSessionWeekGroup: View {
    let label: String
    let sessions: [WorkSession]
    let projects: [Project]

    @State private var isExpanded: Bool = true

    private var weekTotal: Double {
        sessions.map(\.durationHours).reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Week header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(String(format: "%.1fh", weekTotal))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(sessions) { session in
                        WorkSessionRow(session: session, project: projects.first { $0.id == session.projectId })
                        if session.id != sessions.last?.id {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - WorkSessionRow

private struct WorkSessionRow: View {
    let session: WorkSession
    let project: Project?

    var body: some View {
        HStack(spacing: 10) {
            // Billability indicator dot
            Circle()
                .fill(billabilityColor)
                .frame(width: 7, height: 7)
                .padding(.leading, 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.description ?? project?.name ?? "Work session")
                    .fontWeight(.medium)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(session.startedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let projectName = project?.name {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(projectName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.1fh", session.durationHours))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(session.billableStatus.rowLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(billabilityColor)
            }
            .padding(.trailing, 12)
        }
        .padding(.vertical, 8)
    }

    private var billabilityColor: Color {
        switch session.billableStatus {
        case .confirmed:   return .green
        case .suggested:   return .blue
        case .rejected:    return .secondary
        case .nonBillable: return .secondary
        }
    }
}

// MARK: - ClientDetailSkeletonView

private struct ClientDetailSkeletonView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Header skeleton
                HStack(spacing: 20) {
                    SkeletonShape(.circle, width: 60, height: 60)
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonShape(.rounded(8), width: 160, height: 18)
                        SkeletonShape(.rounded(6), width: 100, height: 13)
                    }
                    Spacer()
                }
                .padding(20)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                // Chart skeleton
                SkeletonShape(.rounded(12), width: nil, height: 240)
                // Section skeletons
                SkeletonShape(.rounded(12), width: nil, height: 160)
                SkeletonShape(.rounded(12), width: nil, height: 140)
            }
            .padding(24)
        }
        .redacted(reason: .placeholder)
    }
}

private struct SkeletonShape: View {
    enum Shape { case circle; case rounded(CGFloat) }
    let shape: Shape
    let width: CGFloat?
    let height: CGFloat

    init(_ shape: Shape, width: CGFloat?, height: CGFloat) {
        self.shape = shape; self.width = width; self.height = height
    }

    var body: some View {
        let base = Color(nsColor: .quaternaryLabelColor)
        Group {
            switch shape {
            case .circle:
                Circle().fill(base)
            case .rounded(let r):
                RoundedRectangle(cornerRadius: r, style: .continuous).fill(base)
            }
        }
        .frame(width: width, height: height)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .shimmer()
    }
}

private extension View {
    func shimmer() -> some View { self.modifier(ShimmerModifier()) }
}

private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white.opacity(0.35), location: 0.5),
                            .init(color: .clear, location: 1)
                        ]),
                        startPoint: .init(x: phase, y: 0.5),
                        endPoint: .init(x: phase + 0.6, y: 0.5)
                    )
                    .frame(width: geo.size.width * 2)
                    .offset(x: -geo.size.width * 0.5)
                    .blendMode(.plusLighter)
                }
                .clipped()
            )
            .onAppear {
                withAnimation(
                    .linear(duration: 1.4).repeatForever(autoreverses: false)
                ) {
                    phase = 1.5
                }
            }
    }
}

// MARK: - NewProjectSheet

struct NewProjectSheet: View {
    let onCreate: (String, Double?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var rateText: String = ""
    @FocusState private var nameFocused: Bool

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var parsedRate: Double? {
        let cleaned = rateText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        return cleaned.isEmpty ? nil : Double(cleaned)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Project")
                        .font(.headline)
                    Text("Projects help you organise work sessions and apply hourly rates.")
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
                Section {
                    LabeledContent("Name") {
                        TextField("Website Redesign", text: $name)
                            .focused($nameFocused)
                    }
                    LabeledContent("Hourly Rate") {
                        TextField("$150 (optional)", text: $rateText)
                            .textContentType(.none)
                    }
                } footer: {
                    Text("The hourly rate is used to estimate billed value on the client detail screen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Create Project") {
                    onCreate(name, parsedRate)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { nameFocused = true }
    }
}

// MARK: - AddContactSheet

private struct AddContactSheet: View {
    let contacts: [Contact]
    let onLink: (Contact) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var filter: String = ""

    private var filtered: [Contact] {
        guard !filter.isEmpty else { return contacts }
        let q = filter.lowercased()
        return contacts.filter {
            $0.displayName.lowercased().contains(q) ||
            ($0.company?.lowercased().contains(q) ?? false) ||
            ($0.emailPrimary?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Contact")
                        .font(.headline)
                    Text("Link an existing contact to this client.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            if contacts.isEmpty {
                EmptyStateView(
                    icon: "person.crop.circle",
                    title: "No contacts to link",
                    subtitle: "All existing contacts are already linked to this client."
                )
                .frame(height: 200)
            } else {
                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter contacts…", text: $filter)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                List(filtered) { contact in
                    Button {
                        onLink(contact)
                        dismiss()
                    } label: {
                        ContactRowView(contact: contact)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                .frame(height: min(CGFloat(filtered.count) * 54 + 8, 320))
            }
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - BillableStatus display helper

private extension BillableStatus {
    var rowLabel: String {
        switch self {
        case .confirmed:   return "Billable"
        case .suggested:   return "Suggested"
        case .rejected:    return "Rejected"
        case .nonBillable: return "Non-billable"
        }
    }
}

// MARK: - ContactRowView

/// A single row showing a contact's avatar, name, email, and last-seen date.
/// Used in the Contacts section of `ClientDetailView` and the Add Contact sheet.
private struct ContactRowView: View {
    let contact: Contact

    var body: some View {
        HStack(spacing: 10) {
            // Avatar — first letter of display name
            ZStack {
                Circle()
                    .fill(avatarColor.opacity(0.16))
                Text(String(contact.displayName.prefix(1).uppercased()))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(avatarColor)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                if let email = contact.emailPrimary {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let company = contact.company {
                    Text(company)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(contact.lastSeenAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }

    private var avatarColor: Color {
        let colors: [Color] = [.blue, .purple, .indigo, .teal, .green, .orange, .pink]
        return colors[abs(contact.displayName.hashValue) % colors.count]
    }
}
