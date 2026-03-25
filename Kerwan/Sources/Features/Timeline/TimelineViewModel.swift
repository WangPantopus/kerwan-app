import Foundation
import SwiftUI

// MARK: - TimelineViewModel

/// Observable view model for the Timeline feature.
///
/// Owns all pagination state, filter state, and date-grouping logic.
/// Data is fetched through a `TimelineDataSource`, making the ViewModel
/// testable and preview-friendly independent of real storage.
@Observable
@MainActor
final class TimelineViewModel {

    // MARK: - Displayed data

    private(set) var sections:       [TimelineDateSection] = []
    private(set) var isLoading       = false
    private(set) var isLoadingMore   = false
    private(set) var hasMore         = true
    private(set) var loadError:      String?

    // MARK: - Filter state (mutated by filter bar via @Bindable)

    var sourceFilter:     TimelineSourceFilter = .all
    var selectedClientId: EntityID?            = nil
    var dateStart:        Date?                = nil
    var dateEnd:          Date?                = nil

    // MARK: - Client picker data

    private(set) var availableClients: [Client] = []

    // MARK: - Row expansion

    var expandedInteractionId: EntityID? = nil

    // MARK: - Private

    private var loadedCount = 0
    private let pageSize    = 50
    private let dataSource: any TimelineDataSource

    private var currentFilter: TimelineFilter {
        TimelineFilter(
            source:    sourceFilter,
            clientId:  selectedClientId,
            dateStart: dateStart,
            dateEnd:   dateEnd
        )
    }

    // MARK: - Init

    init(dataSource: any TimelineDataSource = MockTimelineDataSource()) {
        self.dataSource = dataSource
    }

    // MARK: - Public API

    /// Clears all sections and loads the first page with the current filter.
    func loadInitial() async {
        guard !isLoading else { return }
        isLoading   = true
        loadError   = nil
        sections    = []
        loadedCount = 0
        hasMore     = true
        defer { isLoading = false }
        do {
            let items = try await dataSource.fetchPage(
                offset: 0, limit: pageSize, filter: currentFilter
            )
            appendItems(items)
            loadedCount = items.count
            hasMore     = items.count == pageSize
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Appends the next page. Called when the user scrolls to the bottom.
    func loadNextPage() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let items = try await dataSource.fetchPage(
                offset: loadedCount, limit: pageSize, filter: currentFilter
            )
            appendItems(items)
            loadedCount += items.count
            hasMore      = items.count == pageSize
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Re-fetches from page 0 — call after filter changes.
    func applyFilters() async {
        await loadInitial()
    }

    /// Resets all filters to defaults and reloads.
    func resetFilters() async {
        sourceFilter     = .all
        selectedClientId = nil
        dateStart        = nil
        dateEnd          = nil
        await loadInitial()
    }

    /// Fetches the client list for the filter picker.
    func loadAvailableClients() async {
        availableClients = (try? await dataSource.fetchClients()) ?? []
    }

    /// Toggles the expanded state of a single row.
    func toggleExpanded(_ id: EntityID) {
        expandedInteractionId = (expandedInteractionId == id) ? nil : id
    }

    // MARK: - Date utilities (static for testability)

    /// Human-readable date section label: "Today", "Yesterday", or full date.
    static func sectionLabel(for date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date)     { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.dateStyle = .long
        fmt.timeStyle = .none
        return fmt.string(from: date)
    }

    /// Stable "YYYY-MM-DD" string ID for ScrollViewReader anchoring.
    static func sectionID(for date: Date, calendar: Calendar = .current) -> String {
        let y = calendar.component(.year,  from: date)
        let m = calendar.component(.month, from: date)
        let d = calendar.component(.day,   from: date)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    // MARK: - Private: date-section grouping

    /// Merges `items` (reverse-chronological order) into `sections`,
    /// creating new date sections as needed.
    private func appendItems(_ items: [TimelineItem]) {
        let cal = Calendar.current
        for item in items {
            let dayStart = cal.startOfDay(for: item.interaction.startedAt)
            let sid      = Self.sectionID(for: dayStart)
            if let idx = sections.firstIndex(where: { $0.id == sid }) {
                sections[idx].items.append(item)
            } else {
                sections.append(
                    TimelineDateSection(
                        id:    sid,
                        date:  dayStart,
                        label: Self.sectionLabel(for: dayStart),
                        items: [item]
                    )
                )
            }
        }
    }
}
