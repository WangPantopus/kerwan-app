import SwiftUI
import AppKit
import os

// MARK: - Storage protocol

/// Storage operations required by the contact profile screen.
/// Implemented by `StorageActor` in the KerwanStorage workstream.
protocol ContactProfileStorageService: Actor {
    func fetchPromises(for contactId: EntityID) async throws -> [Promise]
    func fetchInteractions(for contactId: EntityID, page: Int, pageSize: Int) async throws -> [Interaction]
    func fetchContactNote(for contactId: EntityID) async throws -> String
    func updateContact(_ contact: Contact) async throws
    func deleteContact(id: EntityID) async throws
    func saveContactNote(contactId: EntityID, text: String) async throws
    func updatePromiseStatus(_ id: EntityID, status: PromiseStatus) async throws
    func fetchContactsForMerge(excluding id: EntityID) async throws -> [Contact]
    func mergeContacts(keep: EntityID, discard: EntityID) async throws -> Contact
}

// MARK: - Timeline filter

enum InteractionFilter: String, CaseIterable, Identifiable {
    case all         = "All"
    case meetings    = "Meetings"
    case emails      = "Emails"
    case messages    = "Messages"
    case appActivity = "App Activity"

    var id: String { rawValue }

    var matchedTypes: [InteractionType]? {
        switch self {
        case .all:         return nil
        case .meetings:    return [.meeting, .phoneCalled]
        case .emails:      return [.emailSent, .emailReceived]
        case .messages:    return [.slackDM]
        case .appActivity: return [.appActivity]
        }
    }
}

// MARK: - ContactProfileViewModel

@Observable
@MainActor
final class ContactProfileViewModel {
    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "ContactProfileViewModel"
    )

    static let pageSize = 50

    // MARK: Injected

    private var storage: (any ContactProfileStorageService)?
    private weak var appState: AppState?

    // MARK: Contact state

    /// Live contact — updated after edits are saved.
    private(set) var contact: Contact
    /// Draft fields for inline edit mode.
    var draftName: String = ""
    var draftCompany: String = ""
    var draftEmail: String = ""

    // MARK: Section data

    var promises: [Promise] = []
    var interactions: [Interaction] = []
    var mergeableContacts: [Contact] = []
    var notesText: String = ""

    // MARK: Pagination

    private(set) var currentPage: Int = 0
    private(set) var hasMoreInteractions: Bool = false

    // MARK: Timeline filter

    var timelineFilter: InteractionFilter = .all

    var filteredInteractions: [Interaction] {
        guard let types = timelineFilter.matchedTypes else { return interactions }
        return interactions.filter { types.contains($0.interactionType) }
    }

    // MARK: Derived facts

    /// Aggregated, deduplicated content tags from all interactions.
    var keyFacts: [String] {
        let all = interactions.flatMap { $0.contentTags }
        var seen = Set<String>()
        return all.filter { seen.insert($0).inserted }
    }

    /// Open promises only (not done / dismissed / snoozed).
    var openPromises: [Promise] { promises.filter { $0.status == .open } }

    /// Stats for the header bar.
    var totalInteractionCount: Int { interactions.count }
    var totalMeetingMinutes: Int {
        interactions
            .filter { [.meeting, .phoneCalled].contains($0.interactionType) }
            .compactMap { i -> Int? in
                guard let end = i.endedAt else { return nil }
                return Int(end.timeIntervalSince(i.startedAt) / 60)
            }
            .reduce(0, +)
    }
    var promiseCompletionRate: Double {
        let resolved = promises.filter { $0.status == .done }.count
        guard !promises.isEmpty else { return 0 }
        return Double(resolved) / Double(promises.count)
    }

    // MARK: UI mode flags

    var isLoadingInitial: Bool = true
    var isLoadingMoreInteractions: Bool = false
    var isRegeneratingAISummary: Bool = false
    var isEditing: Bool = false
    var isPresentingMergeSheet: Bool = false
    var isConfirmingDelete: Bool = false
    var isSavingNote: Bool = false
    var lastNoteSavedAt: Date? = nil
    var error: String? = nil

    // MARK: Private

    private var noteSaveTask: Task<Void, Never>? = nil

    // MARK: - Init

    init(contact: Contact, storage: (any ContactProfileStorageService)? = nil, appState: AppState? = nil) {
        self.contact = contact
        self.storage = storage
        self.appState = appState
    }

    // MARK: - Data loading

    func load() async {
        isLoadingInitial = true
        defer { isLoadingInitial = false }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadPromises() }
            group.addTask { await self.loadInteractionsFirstPage() }
            group.addTask { await self.loadNotes() }
        }
    }

    private func loadPromises() async {
        guard let storage else { return }
        do {
            promises = try await storage.fetchPromises(for: contact.id)
        } catch {
            Self.logger.error("Failed to load promises: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    private func loadInteractionsFirstPage() async {
        guard let storage else { return }
        do {
            let page = try await storage.fetchInteractions(for: contact.id, page: 0, pageSize: Self.pageSize)
            interactions = page
            currentPage = 0
            hasMoreInteractions = page.count == Self.pageSize
        } catch {
            Self.logger.error("Failed to load interactions: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    func loadMoreInteractions() async {
        guard let storage, hasMoreInteractions, !isLoadingMoreInteractions else { return }
        isLoadingMoreInteractions = true
        defer { isLoadingMoreInteractions = false }
        do {
            let nextPage = currentPage + 1
            let page = try await storage.fetchInteractions(for: contact.id, page: nextPage, pageSize: Self.pageSize)
            interactions.append(contentsOf: page)
            currentPage = nextPage
            hasMoreInteractions = page.count == Self.pageSize
        } catch {
            Self.logger.error("Failed to load more interactions: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    private func loadNotes() async {
        guard let storage else { return }
        do {
            notesText = try await storage.fetchContactNote(for: contact.id)
        } catch {
            // Notes are optional — missing is not an error state.
            Self.logger.debug("No notes found for contact \(self.contact.id, privacy: .public)")
        }
    }

    // MARK: - AI Summary

    func regenerateAISummary() async {
        isRegeneratingAISummary = true
        defer { isRegeneratingAISummary = false }
        // Full implementation: AI intelligence workstream calls the Ollama
        // classification pipeline to rebuild the summary from all interactions.
        // For now, simulate latency and leave the existing summary in place.
        try? await Task.sleep(for: .milliseconds(1500))
        Self.logger.debug("AI summary regeneration requested for \(self.contact.id, privacy: .public)")
    }

    // MARK: - Promise actions

    func markPromiseDone(_ promise: Promise) async {
        await updatePromise(promise, status: .done)
        if let appState { appState.updateOpenPromiseCount(max(0, appState.openPromiseCount - 1)) }
    }

    func snoozePromise(_ promise: Promise) async {
        await updatePromise(promise, status: .snoozed)
    }

    func dismissPromise(_ promise: Promise) async {
        await updatePromise(promise, status: .dismissed)
    }

    private func updatePromise(_ promise: Promise, status: PromiseStatus) async {
        guard let storage else {
            applyPromiseStatusLocally(promise.id, status: status)
            return
        }
        do {
            try await storage.updatePromiseStatus(promise.id, status: status)
            applyPromiseStatusLocally(promise.id, status: status)
        } catch {
            Self.logger.error("Failed to update promise \(promise.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    private func applyPromiseStatusLocally(_ id: EntityID, status: PromiseStatus) {
        if let idx = promises.firstIndex(where: { $0.id == id }) {
            promises[idx].status = status
        }
    }

    // MARK: - Inline editing

    func beginEditing() {
        draftName = contact.displayName
        draftCompany = contact.company ?? ""
        draftEmail = contact.emailPrimary ?? ""
        isEditing = true
    }

    func cancelEditing() {
        isEditing = false
    }

    func saveEditing() async {
        var updated = contact
        updated.displayName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.company = draftCompany.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        updated.emailPrimary = draftEmail.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        updated.updatedAt = Date()

        guard let storage else {
            contact = updated
            isEditing = false
            return
        }
        do {
            try await storage.updateContact(updated)
            contact = updated
            isEditing = false
        } catch {
            Self.logger.error("Failed to save contact edit: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    // MARK: - Delete

    func deleteContact() async {
        guard let storage else { return }
        do {
            try await storage.deleteContact(id: contact.id)
            Self.logger.info("Contact \(self.contact.id, privacy: .public) deleted")
            // The view will dismiss via .navigationDestination removal.
        } catch {
            Self.logger.error("Failed to delete contact: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    // MARK: - Merge

    func loadMergeableContacts() async {
        guard let storage else { return }
        do {
            mergeableContacts = try await storage.fetchContactsForMerge(excluding: contact.id)
        } catch {
            Self.logger.error("Failed to load contacts for merge: \(error.localizedDescription, privacy: .public)")
        }
    }

    func mergeWith(_ other: Contact) async {
        guard let storage else { return }
        do {
            let merged = try await storage.mergeContacts(keep: contact.id, discard: other.id)
            contact = merged
            isPresentingMergeSheet = false
            // Reload data for the merged contact.
            await load()
        } catch {
            Self.logger.error("Merge failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    // MARK: - Notes auto-save

    func scheduleNoteSave() {
        noteSaveTask?.cancel()
        noteSaveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch { return } // cancelled
            await self.persistNote()
        }
    }

    private func persistNote() async {
        guard let storage else { return }
        isSavingNote = true
        do {
            try await storage.saveContactNote(contactId: contact.id, text: notesText)
            lastNoteSavedAt = Date()
        } catch {
            Self.logger.error("Failed to save note: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
        isSavingNote = false
    }

    // MARK: - Export

    /// Runs the native macOS Print dialog (user chooses Save as PDF) for the
    /// contact's full interaction timeline.
    @MainActor
    func exportTimeline() {
        let printInfo = NSPrintInfo()
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 54
        printInfo.rightMargin = 54
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false

        let printView = ContactTimelinePrintView(contact: contact, interactions: filteredInteractions, promises: openPromises)
        let hostingView = NSHostingView(rootView: printView)
        // Size to content then let the print engine paginate.
        hostingView.frame = NSRect(x: 0, y: 0, width: 504, height: 2)
        hostingView.layout()
        let intrinsic = hostingView.fittingSize
        hostingView.frame = NSRect(x: 0, y: 0, width: 504, height: max(intrinsic.height, 792))

        let op = NSPrintOperation(view: hostingView, printInfo: printInfo)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.jobTitle = "\(contact.displayName) — Kerwan Timeline"
        op.run()

        Self.logger.info("Timeline export initiated for \(self.contact.id, privacy: .public)")
    }
}

// MARK: - InteractionType display helpers

extension InteractionType {
    var systemImage: String {
        switch self {
        case .meeting:       return "person.3.fill"
        case .emailSent:     return "envelope.fill"
        case .emailReceived: return "envelope.badge.fill"
        case .slackDM:       return "message.fill"
        case .phoneCalled:   return "phone.fill"
        case .appActivity:   return "app.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .meeting:       return .blue
        case .emailSent:     return .indigo
        case .emailReceived: return .purple
        case .slackDM:       return .teal
        case .phoneCalled:   return .green
        case .appActivity:   return .orange
        }
    }

    var displayName: String {
        switch self {
        case .meeting:       return "Meeting"
        case .emailSent:     return "Email sent"
        case .emailReceived: return "Email received"
        case .slackDM:       return "Slack DM"
        case .phoneCalled:   return "Phone call"
        case .appActivity:   return "App activity"
        }
    }
}

extension Interaction {
    /// Human-readable duration string for meetings ("45 min", "1h 30m", etc.).
    var durationFormatted: String? {
        guard let end = endedAt else { return nil }
        let minutes = Int(end.timeIntervalSince(startedAt) / 60)
        guard minutes > 0 else { return nil }
        guard minutes >= 60 else { return "\(minutes) min" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

// MARK: - Print view

/// A SwiftUI view rendered into an NSView for the native Print/PDF export flow.
private struct ContactTimelinePrintView: View {
    let contact: Contact
    let interactions: [Interaction]
    let promises: [Promise]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Title block
            VStack(alignment: .leading, spacing: 4) {
                Text(contact.displayName)
                    .font(.system(size: 22, weight: .bold))
                if let company = contact.company {
                    Text(company).font(.subheadline).foregroundStyle(.secondary)
                }
                Text("Exported \(Date().formatted(date: .long, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            // AI Summary
            if let summary = contact.aiSummary {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Summary").font(.headline)
                    Text(summary).font(.subheadline)
                }
            }

            // Open promises
            if !promises.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Open Items (\(promises.count))").font(.headline)
                    ForEach(promises) { p in
                        HStack(alignment: .top, spacing: 8) {
                            Text(p.direction == .userPromised ? "→" : "←")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(p.description).font(.subheadline)
                            Spacer()
                            if let due = p.dueDate {
                                Text(due.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            // Interaction timeline
            VStack(alignment: .leading, spacing: 8) {
                Text("Timeline (\(interactions.count) interactions)").font(.headline)
                ForEach(interactions) { i in
                    HStack(alignment: .top, spacing: 12) {
                        Text(i.startedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption).foregroundStyle(.secondary).frame(width: 80)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(i.summary ?? i.interactionType.displayName)
                                .font(.subheadline).fontWeight(.medium)
                            if let dur = i.durationFormatted {
                                Text(dur).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 504)
    }
}
