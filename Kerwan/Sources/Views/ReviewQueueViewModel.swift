import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os

// MARK: - ExportFormat

enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf  = "PDF"
    case csv  = "CSV"
    case json = "JSON"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .pdf:  return "pdf"
        case .csv:  return "csv"
        case .json: return "json"
        }
    }

    var utType: UTType {
        switch self {
        case .pdf:  return .pdf
        case .csv:  return UTType(filenameExtension: "csv") ?? .data
        case .json: return .json
        }
    }
}

// MARK: - ClientSessionGroup

/// Sessions for a single client, pre-sorted by date descending.
struct ClientSessionGroup: Identifiable {
    var id: EntityID { client.id }
    let client: Client
    var sessions: [WorkSession]

    var totalHours: Double {
        sessions.map(\.durationHours).reduce(0, +)
    }

    var pendingCount: Int {
        sessions.filter { $0.billableStatus == .suggested }.count
    }

    var confirmedHours: Double {
        sessions
            .filter { $0.billableStatus == .confirmed }
            .map(\.durationHours)
            .reduce(0, +)
    }
}

// MARK: - ReviewQueueStorageService

/// All storage operations required by the billing review screen.
/// Implemented by `StorageActor` in the KerwanStorage workstream.
protocol ReviewQueueStorageService: Actor {
    /// Returns all work sessions whose `startedAt` falls in [weekStart, weekStart+7d).
    func fetchWorkSessionsForWeek(weekStart: Date) async throws -> [WorkSession]

    /// Returns clients for the given IDs (preserves order).
    func fetchClients(ids: [EntityID]) async throws -> [Client]

    /// Returns projects for the given IDs.
    func fetchProjects(ids: [EntityID]) async throws -> [Project]

    /// Returns all clients so the reassign sheet can show a full picker.
    func fetchAllClients() async throws -> [Client]

    /// Returns all projects for a given client (for reassign project picker).
    func fetchProjects(for clientId: EntityID) async throws -> [Project]

    /// Lightweight query: returns, per session ID, which EventSources contributed.
    /// Used to render source badges without loading full raw-event payloads.
    func fetchSourceSummaries(for sessionIds: [EntityID]) async throws -> [EntityID: [EventSource]]

    /// Full raw events for a single session (loaded on demand for the evidence panel).
    func fetchRawEvents(for sessionId: EntityID) async throws -> [RawEvent]

    /// Persists an updated work session record.
    func updateWorkSession(_ session: WorkSession) async throws

    /// Merges two sessions: keeps `keep`, deletes `discard`, returns the merged record.
    func mergeWorkSessions(keep: EntityID, discard: EntityID) async throws -> WorkSession

    /// Generates an export payload (PDF/CSV/JSON bytes) for the given parameters.
    func exportBillingData(
        clientIds: [EntityID],
        from: Date,
        to: Date,
        format: ExportFormat,
        includeRejected: Bool,
        includeNonBillable: Bool
    ) async throws -> Data
}

// MARK: - ReviewQueueViewModel

@Observable
@MainActor
final class ReviewQueueViewModel {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "ReviewQueueViewModel"
    )

    // MARK: Injected

    private var storage: (any ReviewQueueStorageService)?
    private weak var appState: AppState?

    // MARK: Data

    private(set) var sessions: [WorkSession] = []
    private(set) var clients: [EntityID: Client] = [:]
    private(set) var projects: [EntityID: Project] = [:]
    private(set) var sessionSources: [EntityID: [EventSource]] = [:]
    private(set) var evidence: [EntityID: [RawEvent]] = [:]

    /// All clients from storage — used by the reassign sheet.
    private(set) var allClients: [Client] = []
    /// Projects per client for reassign sheet (loaded lazily).
    private(set) var projectsForClient: [EntityID: [Project]] = [:]

    // MARK: Week selection

    var selectedWeek: Date = ReviewQueueViewModel.currentWeekStart()

    // MARK: UI mode flags

    var expandedEvidenceIds: Set<EntityID> = []
    var loadingEvidenceIds: Set<EntityID> = []

    var editingSessionId: EntityID? = nil
    var draftDescription: String = ""
    var draftDurationText: String = ""

    var isMergeMode: Bool = false
    var mergeSelection: [EntityID] = []  // ordered; max 2
    var isMerging: Bool = false

    var isPresentingExport: Bool = false
    var isPresentingApproveAll: Bool = false
    var reassigningSession: WorkSession? = nil

    var isLoading: Bool = false
    var error: String? = nil

    // MARK: Init

    init(storage: (any ReviewQueueStorageService)? = nil, appState: AppState? = nil) {
        self.storage = storage
        self.appState = appState
    }

    // MARK: - Computed: week display

    var weekLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return "Week of \(f.string(from: selectedWeek))"
    }

    var weekRangeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        let end = Calendar.current.date(byAdding: .day, value: 6, to: selectedWeek)!
        return "\(f.string(from: selectedWeek)) – \(f.string(from: end))"
    }

    var isCurrentWeek: Bool {
        Calendar.current.isDate(
            selectedWeek,
            equalTo: ReviewQueueViewModel.currentWeekStart(),
            toGranularity: .weekOfYear
        )
    }

    // MARK: - Computed: session groups

    var sessionGroups: [ClientSessionGroup] {
        var groups: [EntityID: ClientSessionGroup] = [:]

        for session in sessions {
            let key = session.clientId ?? "__unassigned__"
            let client = clients[key] ?? Client(id: key, name: "Unassigned")
            if groups[key] != nil {
                groups[key]!.sessions.append(session)
            } else {
                groups[key] = ClientSessionGroup(client: client, sessions: [session])
            }
        }

        for key in groups.keys {
            groups[key]!.sessions.sort { $0.startedAt > $1.startedAt }
        }

        return groups.values.sorted { $0.client.name < $1.client.name }
    }

    // MARK: - Computed: summary stats

    var summarySessionCount: Int { sessions.count }

    var summaryTotalHours: Double {
        sessions.map(\.durationHours).reduce(0, +)
    }

    var summaryEstimatedValue: Double {
        sessions
            .filter { $0.billableStatus == .confirmed || $0.billableStatus == .suggested }
            .reduce(0.0) { total, session in
                let rate = projects[session.projectId ?? ""]?.hourlyRate ?? 0
                return total + session.durationHours * rate
            }
    }

    var pendingSessions: [WorkSession] {
        sessions.filter { $0.billableStatus == .suggested }
    }

    var lowConfidencePendingSessions: [WorkSession] {
        pendingSessions.filter { $0.confidence < 0.4 }
    }

    // MARK: - Load

    func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let storage else { return }
        do {
            let loaded = try await storage.fetchWorkSessionsForWeek(weekStart: selectedWeek)
            sessions = loaded.sorted { $0.startedAt > $1.startedAt }

            let clientIds  = Array(Set(loaded.compactMap(\.clientId)))
            let projectIds = Array(Set(loaded.compactMap(\.projectId)))
            let sessionIds = loaded.map(\.id)

            async let clientsTask  = storage.fetchClients(ids: clientIds)
            async let projectsTask = storage.fetchProjects(ids: projectIds)
            async let sourcesTask  = storage.fetchSourceSummaries(for: sessionIds)
            async let allClientsTask = storage.fetchAllClients()

            let (fc, fp, fs, fac) = try await (clientsTask, projectsTask, sourcesTask, allClientsTask)

            clients        = Dictionary(uniqueKeysWithValues: fc.map  { ($0.id, $0) })
            projects       = Dictionary(uniqueKeysWithValues: fp.map  { ($0.id, $0) })
            sessionSources = fs
            allClients     = fac.sorted { $0.name < $1.name }

            syncBadge()
        } catch {
            Self.logger.error("Load failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    // MARK: - Week navigation

    func previousWeek() {
        selectedWeek = Calendar.current.date(byAdding: .weekOfYear, value: -1, to: selectedWeek)!
        Task { await load() }
    }

    func nextWeek() {
        selectedWeek = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: selectedWeek)!
        Task { await load() }
    }

    // MARK: - Session status actions

    func confirm(_ session: WorkSession) async {
        await setStatus(session, to: .confirmed)
    }

    func reject(_ session: WorkSession) async {
        await setStatus(session, to: .rejected)
    }

    private func setStatus(_ session: WorkSession, to status: BillableStatus) async {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let previous = sessions[idx].billableStatus
        sessions[idx].billableStatus = status
        syncBadge()

        guard let storage else { return }
        var updated = sessions[idx]
        updated.reviewedAt = Date()
        do {
            try await storage.updateWorkSession(updated)
            sessions[idx] = updated
            Self.logger.info("Session \(session.id, privacy: .public) → \(status.rawValue, privacy: .public)")
        } catch {
            sessions[idx].billableStatus = previous   // roll back
            syncBadge()
            Self.logger.error("Status update failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    func approveAll() async {
        let toApprove = pendingSessions
        for session in toApprove {
            await confirm(session)
        }
    }

    // MARK: - Inline editing

    func beginEdit(_ session: WorkSession) {
        editingSessionId = session.id
        draftDescription = session.description ?? ""
        draftDurationText = String(format: "%.2f", session.durationHours)
    }

    func cancelEdit() {
        editingSessionId = nil
    }

    func saveEdit(_ session: WorkSession) async {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let hours = max(0.01, Double(draftDurationText.replacingOccurrences(of: ",", with: ".")) ?? session.durationHours)
        let newSecs = Int(hours * 3600)
        let newDesc = draftDescription.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let newEnd  = session.startedAt.addingTimeInterval(Double(newSecs))

        let updated = WorkSession(
            id: session.id,
            clientId: session.clientId,
            projectId: session.projectId,
            startedAt: session.startedAt,
            endedAt: newEnd,
            durationSecs: newSecs,
            billableStatus: session.billableStatus,
            confidence: session.confidence,
            description: newDesc,
            invoiceText: session.invoiceText,
            reviewedAt: session.reviewedAt
        )
        sessions[idx] = updated
        editingSessionId = nil

        guard let storage else { return }
        do {
            try await storage.updateWorkSession(updated)
        } catch {
            sessions[idx] = session
            Self.logger.error("Edit save failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    // MARK: - Evidence

    func toggleEvidence(for sessionId: EntityID) async {
        if expandedEvidenceIds.contains(sessionId) {
            expandedEvidenceIds.remove(sessionId)
            return
        }
        expandedEvidenceIds.insert(sessionId)
        guard evidence[sessionId] == nil, !loadingEvidenceIds.contains(sessionId) else { return }
        loadingEvidenceIds.insert(sessionId)
        guard let storage else {
            loadingEvidenceIds.remove(sessionId)
            return
        }
        do {
            let events = try await storage.fetchRawEvents(for: sessionId)
            evidence[sessionId] = events.sorted { $0.startedAt < $1.startedAt }
        } catch {
            Self.logger.error("Evidence load failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
        loadingEvidenceIds.remove(sessionId)
    }

    // MARK: - Merge

    func startMerge(with sessionId: EntityID) {
        isMergeMode = true
        mergeSelection = [sessionId]
    }

    func toggleMergeSelection(_ sessionId: EntityID) {
        if let pos = mergeSelection.firstIndex(of: sessionId) {
            mergeSelection.remove(at: pos)
        } else if mergeSelection.count < 2 {
            mergeSelection.append(sessionId)
        }
    }

    func executeMerge() async {
        guard mergeSelection.count == 2, let storage else { return }
        isMerging = true
        let keep = mergeSelection[0]
        let discard = mergeSelection[1]
        do {
            let merged = try await storage.mergeWorkSessions(keep: keep, discard: discard)
            sessions.removeAll { $0.id == discard }
            if let idx = sessions.firstIndex(where: { $0.id == keep }) {
                sessions[idx] = merged
            }
            mergeSelection = []
            isMergeMode = false
            syncBadge()
            Self.logger.info("Merged \(keep, privacy: .public) ← \(discard, privacy: .public)")
        } catch {
            Self.logger.error("Merge failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
        isMerging = false
    }

    func cancelMerge() {
        isMergeMode = false
        mergeSelection = []
    }

    // MARK: - Reassign

    func loadProjectsForReassign(clientId: EntityID) async {
        guard projectsForClient[clientId] == nil, let storage else { return }
        do {
            let projs = try await storage.fetchProjects(for: clientId)
            projectsForClient[clientId] = projs
        } catch {
            Self.logger.error("Projects load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reassign(_ session: WorkSession, clientId: EntityID?, projectId: EntityID?) async {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let updated = WorkSession(
            id: session.id,
            clientId: clientId,
            projectId: projectId,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            durationSecs: session.durationSecs,
            billableStatus: session.billableStatus,
            confidence: session.confidence,
            description: session.description,
            invoiceText: session.invoiceText,
            reviewedAt: session.reviewedAt
        )
        sessions[idx] = updated
        reassigningSession = nil

        guard let storage else { return }
        do {
            try await storage.updateWorkSession(updated)
            // Refresh client/project lookups if new IDs appeared.
            let allIds = Array(Set(sessions.compactMap(\.clientId)))
            let allProjIds = Array(Set(sessions.compactMap(\.projectId)))
            let fc = try await storage.fetchClients(ids: allIds)
            let fp = try await storage.fetchProjects(ids: allProjIds)
            clients  = Dictionary(uniqueKeysWithValues: fc.map { ($0.id, $0) })
            projects = Dictionary(uniqueKeysWithValues: fp.map { ($0.id, $0) })
        } catch {
            sessions[idx] = session
            Self.logger.error("Reassign failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    // MARK: - Export

    func exportBillingData(
        clientIds: [EntityID],
        format: ExportFormat,
        includeRejected: Bool,
        includeNonBillable: Bool
    ) async {
        guard let storage else { return }
        let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: selectedWeek)!
        do {
            let data = try await storage.exportBillingData(
                clientIds: clientIds,
                from: selectedWeek,
                to: weekEnd,
                format: format,
                includeRejected: includeRejected,
                includeNonBillable: includeNonBillable
            )
            await saveFile(data, format: format)
        } catch {
            Self.logger.error("Export failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func saveFile(_ data: Data, format: ExportFormat) async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.canCreateDirectories = true
        let safe = weekRangeLabel.replacingOccurrences(of: " ", with: "-")
        panel.nameFieldStringValue = "kerwan-invoice-\(safe).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            Self.logger.info("Invoice exported to \(url.path, privacy: .public)")
        } catch {
            Self.logger.error("Write failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func syncBadge() {
        let count = sessions.filter { $0.billableStatus == .suggested }.count
        appState?.updatePendingReviewCount(count)
    }

    static func currentWeekStart() -> Date {
        var cal = Calendar.current
        cal.firstWeekday = 2  // ISO: Monday
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        return cal.date(from: comps) ?? Date()
    }
}

// MARK: - EventSource display helpers

extension EventSource {
    var reviewSystemImage: String {
        switch self {
        case .audio:      return "waveform"
        case .appFocus:   return "app.fill"
        case .email:      return "envelope.fill"
        case .slack:      return "message.fill"
        case .calendar:   return "calendar"
        case .browser:    return "globe"
        case .manualNote: return "note.text"
        }
    }

    var reviewTintColor: Color {
        switch self {
        case .audio:      return .purple
        case .appFocus:   return .orange
        case .email:      return .indigo
        case .slack:      return .teal
        case .calendar:   return .blue
        case .browser:    return .green
        case .manualNote: return Color(nsColor: .secondaryLabelColor)
        }
    }

    var shortLabel: String {
        switch self {
        case .audio:      return "Audio"
        case .appFocus:   return "App"
        case .email:      return "Email"
        case .slack:      return "Slack"
        case .calendar:   return "Calendar"
        case .browser:    return "Browser"
        case .manualNote: return "Note"
        }
    }
}

