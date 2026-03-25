import SwiftUI
import os

// MARK: - Supporting data types

/// A client record enriched with pre-computed stats for list-row display.
/// The storage layer computes these with a single JOIN query.
struct ClientSummary: Identifiable, Sendable {
    var id: EntityID { client.id }
    let client: Client
    /// Number of contacts attributed to this client.
    let contactCount: Int
    /// Confirmed + suggested billable hours in the current calendar month.
    let billedHoursThisMonth: Double
    /// The most recent interaction date across all contacts for this client.
    let lastInteractionDate: Date?
}

/// Hours worked for a single ISO calendar week, split by billability.
struct WeeklyHours: Identifiable, Sendable {
    let id: UUID = UUID()
    /// Monday of the week (start of ISO week).
    let weekStart: Date
    /// All work-session hours in this week.
    let totalHours: Double
    /// Confirmed billable hours in this week.
    let billableHours: Double
}

// MARK: - Storage protocol

/// All storage operations required by the Client management screens.
/// Implemented by `StorageActor` in the KerwanStorage workstream.
protocol ClientStorageService: Actor {
    // List-level
    func fetchClientSummaries() async throws -> [ClientSummary]
    func createClient(_ client: Client) async throws
    func deleteClient(id: EntityID) async throws
    func updateClient(_ client: Client) async throws

    // Detail-level
    func fetchContacts(for clientId: EntityID) async throws -> [Contact]
    func fetchProjects(for clientId: EntityID) async throws -> [Project]
    func fetchWorkSessions(for clientId: EntityID) async throws -> [WorkSession]
    func fetchRecentInteractions(for clientId: EntityID, limit: Int) async throws -> [Interaction]
    func fetchWeeklyHours(for clientId: EntityID, weeks: Int) async throws -> [WeeklyHours]
    func createProject(_ project: Project) async throws
    func fetchUnlinkedContacts(for clientId: EntityID) async throws -> [Contact]
    func linkContact(_ contactId: EntityID, to clientId: EntityID) async throws
}

// MARK: - ClientListViewModel

@Observable
@MainActor
final class ClientListViewModel {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "ClientListViewModel"
    )

    // MARK: State

    private(set) var summaries: [ClientSummary] = []
    var filterText: String = ""
    var isLoading: Bool = false
    var isPresentingNewClient: Bool = false
    /// Set to the client the user wants to delete; drives the confirmation dialog.
    var pendingDeleteClient: Client? = nil
    var error: String? = nil

    private var storage: (any ClientStorageService)?

    // MARK: Derived

    var filtered: [ClientSummary] {
        let sorted = summaries.sorted {
            switch ($0.lastInteractionDate, $1.lastInteractionDate) {
            case (.some(let a), .some(let b)): return a > b
            case (.some, .none):               return true
            case (.none, .some):               return false
            case (.none, .none):               return $0.client.name < $1.client.name
            }
        }
        guard !filterText.isEmpty else { return sorted }
        let q = filterText.lowercased()
        return sorted.filter {
            $0.client.name.lowercased().contains(q) ||
            ($0.client.domain?.lowercased().contains(q) ?? false)
        }
    }

    // MARK: Init

    init(storage: (any ClientStorageService)? = nil) {
        self.storage = storage
    }

    // MARK: Load

    func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let storage else { return }
        do {
            summaries = try await storage.fetchClientSummaries()
        } catch {
            Self.logger.error("Failed to load clients: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    // MARK: CRUD

    func createClient(name: String, domain: String?, notes: String?) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let client = Client(
            name: trimmedName,
            domain: domain?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            notes: notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        // Optimistic insert at top of list.
        let summary = ClientSummary(client: client, contactCount: 0, billedHoursThisMonth: 0, lastInteractionDate: nil)
        summaries.insert(summary, at: 0)

        guard let storage else { return }
        do {
            try await storage.createClient(client)
            Self.logger.info("Created client \(client.id, privacy: .public)")
        } catch {
            summaries.removeAll { $0.client.id == client.id }
            Self.logger.error("Failed to create client: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    func deleteClient(_ client: Client) async {
        summaries.removeAll { $0.client.id == client.id }
        guard let storage else { return }
        do {
            try await storage.deleteClient(id: client.id)
            Self.logger.info("Deleted client \(client.id, privacy: .public)")
        } catch {
            Self.logger.error("Failed to delete client: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
            // Reload to restore any incorrectly removed items.
            await load()
        }
    }
}

// MARK: - ClientDetailViewModel

@Observable
@MainActor
final class ClientDetailViewModel {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "ClientDetailViewModel"
    )

    // MARK: State

    private(set) var client: Client
    private(set) var contacts: [Contact] = []
    private(set) var projects: [Project] = []
    private(set) var workSessions: [WorkSession] = []
    private(set) var recentInteractions: [Interaction] = []
    private(set) var weeklyHours: [WeeklyHours] = []
    private(set) var unlinkedContacts: [Contact] = []

    var isLoadingInitial: Bool = true
    var isPresentingNewProject: Bool = false
    var isPresentingAddContact: Bool = false
    var error: String? = nil

    private var storage: (any ClientStorageService)?

    // MARK: Computed metrics

    var totalHoursAllTime: Double {
        workSessions.map(\.durationHours).reduce(0, +)
    }

    var billedHoursThisMonth: Double {
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        return workSessions
            .filter {
                let sc = Calendar.current.dateComponents([.year, .month], from: $0.startedAt)
                return sc.year == comps.year && sc.month == comps.month &&
                    ($0.billableStatus == .confirmed || $0.billableStatus == .suggested)
            }
            .map(\.durationHours)
            .reduce(0, +)
    }

    /// Estimated billed value this month using per-project rates.
    var billedValueThisMonth: Double {
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        return workSessions
            .filter {
                let sc = Calendar.current.dateComponents([.year, .month], from: $0.startedAt)
                return sc.year == comps.year && sc.month == comps.month &&
                    $0.billableStatus == .confirmed
            }
            .reduce(0.0) { total, session in
                let rate = projects.first(where: { $0.id == session.projectId })?.hourlyRate ?? 0
                return total + session.durationHours * rate
            }
    }

    /// Work sessions grouped by ISO-week start date, newest first.
    var sessionsByWeek: [(label: String, weekStart: Date, sessions: [WorkSession])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: workSessions) { session -> Date in
            var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: session.startedAt)
            comps.weekday = cal.firstWeekday   // Monday in most locales
            return cal.date(from: comps) ?? session.startedAt
        }
        return grouped
            .sorted { $0.key > $1.key }
            .map { (key, sessions) in
                (
                    label: Self.weekLabel(for: key),
                    weekStart: key,
                    sessions: sessions.sorted { $0.startedAt > $1.startedAt }
                )
            }
    }

    private static func weekLabel(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return "Week of \(f.string(from: date))"
    }

    // MARK: Init

    init(client: Client, storage: (any ClientStorageService)? = nil) {
        self.client = client
        self.storage = storage
    }

    // MARK: Load

    func load() async {
        isLoadingInitial = true
        defer { isLoadingInitial = false }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadContacts() }
            group.addTask { await self.loadProjects() }
            group.addTask { await self.loadWorkSessions() }
            group.addTask { await self.loadRecentInteractions() }
            group.addTask { await self.loadWeeklyHours() }
        }
    }

    private func loadContacts() async {
        guard let storage else { return }
        do { contacts = try await storage.fetchContacts(for: client.id) }
        catch { handleError(error, context: "contacts") }
    }

    private func loadProjects() async {
        guard let storage else { return }
        do { projects = try await storage.fetchProjects(for: client.id) }
        catch { handleError(error, context: "projects") }
    }

    private func loadWorkSessions() async {
        guard let storage else { return }
        do { workSessions = try await storage.fetchWorkSessions(for: client.id) }
        catch { handleError(error, context: "work sessions") }
    }

    private func loadRecentInteractions() async {
        guard let storage else { return }
        do { recentInteractions = try await storage.fetchRecentInteractions(for: client.id, limit: 20) }
        catch { handleError(error, context: "interactions") }
    }

    private func loadWeeklyHours() async {
        guard let storage else { return }
        do { weeklyHours = try await storage.fetchWeeklyHours(for: client.id, weeks: 12) }
        catch { handleError(error, context: "weekly hours") }
    }

    // MARK: Project CRUD

    func createProject(name: String, hourlyRate: Double?) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let project = Project(clientId: client.id, name: trimmed, hourlyRate: hourlyRate)
        projects.append(project)
        guard let storage else { return }
        do {
            try await storage.createProject(project)
            Self.logger.info("Created project \(project.id, privacy: .public)")
        } catch {
            projects.removeAll { $0.id == project.id }
            handleError(error, context: "project creation")
        }
    }

    // MARK: Contact linking

    func loadUnlinkedContacts() async {
        guard let storage else { return }
        do { unlinkedContacts = try await storage.fetchUnlinkedContacts(for: client.id) }
        catch { handleError(error, context: "unlinked contacts") }
    }

    func linkContact(_ contact: Contact) async {
        contacts.append(contact)
        unlinkedContacts.removeAll { $0.id == contact.id }
        isPresentingAddContact = false
        guard let storage else { return }
        do {
            try await storage.linkContact(contact.id, to: client.id)
        } catch {
            contacts.removeAll { $0.id == contact.id }
            handleError(error, context: "link contact")
        }
    }

    // MARK: Private

    private func handleError(_ error: Error, context: String) {
        Self.logger.error("Failed to load \(context, privacy: .public): \(error.localizedDescription, privacy: .public)")
        self.error = error.localizedDescription
    }
}

// MARK: - String helper

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
