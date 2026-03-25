import SwiftUI
import os

// MARK: - ClientListView

/// The client roster — a searchable, sortable list of all billing clients.
///
/// Rows show: avatar, name, domain, contact count, billed hours this month,
/// and last-interaction date. Rows are sorted newest-interaction-first.
/// The `ClientListViewModel` owns all state and storage calls.
@MainActor
struct ClientListView: View {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "ClientListView"
    )

    @Environment(AppState.self) private var appState
    @State private var vm = ClientListViewModel()

    var body: some View {
        Group {
            if vm.isLoading && vm.summaries.isEmpty {
                ProgressView("Loading clients…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.summaries.isEmpty && !vm.isLoading {
                emptyState
            } else {
                clientList
            }
        }
        .navigationTitle("Clients")
        .searchable(text: $vm.filterText, placement: .sidebar, prompt: "Filter clients…")
        .toolbar { toolbarContent }
        .task { await vm.load() }
        .sheet(isPresented: $vm.isPresentingNewClient) {
            NewClientSheet { name, domain, notes in
                Task { await vm.createClient(name: name, domain: domain, notes: notes) }
            }
        }
        .confirmationDialog(
            "Delete \(vm.pendingDeleteClient?.name ?? "Client")?",
            isPresented: Binding(
                get: { vm.pendingDeleteClient != nil },
                set: { if !$0 { vm.pendingDeleteClient = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let client = vm.pendingDeleteClient {
                Button("Delete Client", role: .destructive) {
                    Task { await vm.deleteClient(client) }
                }
            }
            Button("Cancel", role: .cancel) { vm.pendingDeleteClient = nil }
        } message: {
            Text("All interactions, projects, and work sessions linked to this client will also be deleted. This cannot be undone.")
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

    // MARK: - Empty state

    private var emptyState: some View {
        EmptyStateView(
            icon: "person.2",
            title: "No clients yet",
            subtitle: "Add your first client to start tracking billable work.",
            actionLabel: "Add Client"
        ) {
            vm.isPresentingNewClient = true
        }
    }

    // MARK: - Client list

    private var clientList: some View {
        List {
            ForEach(vm.filtered) { summary in
                NavigationLink(value: summary.client) {
                    ClientSummaryRow(summary: summary)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        vm.pendingDeleteClient = summary.client
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .animation(.default, value: vm.filtered.map(\.id))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                vm.isPresentingNewClient = true
            } label: {
                Label("New Client", systemImage: "plus")
            }
            .help("Add a new client (⌘N)")
            .keyboardShortcut("n", modifiers: .command)
        }
    }
}

// MARK: - ClientSummaryRow

/// A rich list row showing key stats for a client.
private struct ClientSummaryRow: View {
    let summary: ClientSummary

    var body: some View {
        HStack(spacing: 12) {
            ClientAvatarView(name: summary.client.name, size: 38)

            // Name + domain
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.client.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let domain = summary.client.domain {
                    Text(domain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            // Stats cluster
            HStack(spacing: 16) {
                // Contact count
                StatBadge(
                    value: "\(summary.contactCount)",
                    label: summary.contactCount == 1 ? "contact" : "contacts",
                    systemImage: "person.2"
                )

                // Billed hours this month
                if summary.billedHoursThisMonth > 0 {
                    StatBadge(
                        value: String(format: "%.1fh", summary.billedHoursThisMonth),
                        label: "this month",
                        systemImage: "clock.fill"
                    )
                }

                // Last interaction
                if let last = summary.lastInteractionDate {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(last, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text("ago")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("No activity")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct StatBadge: View {
    let value: String
    let label: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - NewClientSheet

/// Sheet for creating a new client record.
struct NewClientSheet: View {
    let onCreate: (String, String?, String?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var domain: String = ""
    @State private var notes: String = ""
    @FocusState private var nameFocused: Bool

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Client")
                        .font(.headline)
                    Text("Add a client to track billable work and interactions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            // Form
            Form {
                Section {
                    LabeledContent("Name") {
                        TextField("Acme Corp", text: $name)
                            .focused($nameFocused)
                    }
                    LabeledContent("Domain") {
                        TextField("acme.com (optional)", text: $domain)
                            .textContentType(.URL)
                    }
                } footer: {
                    Text("The domain is used to automatically attribute emails and interactions to this client.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 72, maxHeight: 120)
                        .font(.subheadline)
                        .scrollContentBackground(.hidden)
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Create Client") {
                    onCreate(
                        name,
                        domain.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                        notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { nameFocused = true }
    }
}

// MARK: - ClientAvatarView

/// A circular avatar showing the first letter of a client's name.
/// The background color is deterministically derived from the name.
struct ClientAvatarView: View {
    let name: String
    let size: CGFloat

    private var initial: String { String(name.prefix(1).uppercased()) }

    private var backgroundColor: Color {
        let colors: [Color] = [.blue, .purple, .indigo, .teal, .green, .orange]
        return colors[abs(name.hashValue) % colors.count]
    }

    var body: some View {
        ZStack {
            Circle().fill(backgroundColor.opacity(0.16))
            Text(initial)
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(backgroundColor)
        }
        .frame(width: size, height: size)
    }
}
