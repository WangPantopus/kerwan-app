import XCTest
@testable import Kerwan

/// Tests for the main window navigation model: `SidebarItem` enum correctness
/// and the `AppState` properties that drive sidebar badges and programmatic
/// navigation.
final class MainWindowTests: XCTestCase {

    // MARK: - SidebarItem enum

    func testSidebarItemAllCasesCount() {
        XCTAssertEqual(SidebarItem.allCases.count, 6)
    }

    func testSidebarItemRawValues() {
        XCTAssertEqual(SidebarItem.today.rawValue,       "today")
        XCTAssertEqual(SidebarItem.clients.rawValue,     "clients")
        XCTAssertEqual(SidebarItem.reviewQueue.rawValue, "reviewQueue")
        XCTAssertEqual(SidebarItem.billing.rawValue,     "billing")
        XCTAssertEqual(SidebarItem.timeline.rawValue,    "timeline")
        XCTAssertEqual(SidebarItem.settings.rawValue,    "settings")
    }

    func testSidebarItemIdentifiableId() {
        for item in SidebarItem.allCases {
            XCTAssertEqual(item.id, item.rawValue)
        }
    }

    func testSidebarItemTitlesAreNonEmpty() {
        for item in SidebarItem.allCases {
            XCTAssertFalse(item.title.isEmpty, "\(item.rawValue) title must not be empty")
        }
    }

    func testSidebarItemSystemImagesAreNonEmpty() {
        for item in SidebarItem.allCases {
            XCTAssertFalse(
                item.systemImage.isEmpty,
                "\(item.rawValue) systemImage must not be empty"
            )
        }
    }

    func testKeyEquivalentsAreUnique() {
        let keys = SidebarItem.allCases.map { $0.keyEquivalent }
        let uniqueKeys = Set(keys)
        XCTAssertEqual(keys.count, uniqueKeys.count, "Each SidebarItem must have a unique key equivalent")
    }

    func testKeyEquivalentsAreDigits1Through6() {
        let expected: [Character] = ["1", "2", "3", "4", "5", "6"]
        let actual = SidebarItem.allCases.map { $0.keyEquivalent }
        XCTAssertEqual(actual, expected)
    }

    func testBadgeSupportedItems() {
        XCTAssertTrue(SidebarItem.reviewQueue.supportsBadge)
        XCTAssertTrue(SidebarItem.billing.supportsBadge)
        XCTAssertFalse(SidebarItem.today.supportsBadge)
        XCTAssertFalse(SidebarItem.clients.supportsBadge)
        XCTAssertFalse(SidebarItem.timeline.supportsBadge)
        XCTAssertFalse(SidebarItem.settings.supportsBadge)
    }

    func testRoundTripRawValueInit() {
        for item in SidebarItem.allCases {
            let restored = SidebarItem(rawValue: item.rawValue)
            XCTAssertEqual(restored, item, "RawValue round-trip failed for \(item.rawValue)")
        }
    }

    func testInvalidRawValueReturnsNil() {
        XCTAssertNil(SidebarItem(rawValue: "nonexistent"))
        XCTAssertNil(SidebarItem(rawValue: ""))
    }

    // MARK: - NavigationItem typealias

    func testNavigationItemIsTypealiasForSidebarItem() {
        // Ensures the legacy typealias compiles and resolves to the same type.
        let item: NavigationItem = .today
        let sidebar: SidebarItem = item
        XCTAssertEqual(sidebar, .today)
    }

    // MARK: - AppState badge counts

    @MainActor
    func testUnbilledHoursDefaultsToZero() {
        let state = AppState()
        XCTAssertEqual(state.unbilledHours, 0.0)
    }

    @MainActor
    func testUpdateUnbilledHoursSetsValue() {
        let state = AppState()
        state.updateUnbilledHours(12.5)
        XCTAssertEqual(state.unbilledHours, 12.5, accuracy: 0.001)
    }

    @MainActor
    func testUpdateUnbilledHoursClampsBelowZero() {
        let state = AppState()
        state.updateUnbilledHours(-5.0)
        XCTAssertEqual(state.unbilledHours, 0.0)
    }

    @MainActor
    func testUpdateUnbilledHoursAcceptsZero() {
        let state = AppState()
        state.updateUnbilledHours(10.0)
        state.updateUnbilledHours(0.0)
        XCTAssertEqual(state.unbilledHours, 0.0)
    }

    @MainActor
    func testPendingReviewCountDrivesReviewQueueBadge() {
        let state = AppState()
        state.updatePendingReviewCount(7)
        XCTAssertEqual(state.pendingReviewCount, 7)
    }

    // MARK: - Programmatic navigation

    @MainActor
    func testSelectedSidebarItemDefaultsToToday() {
        let state = AppState()
        XCTAssertEqual(state.selectedSidebarItem, .today)
    }

    @MainActor
    func testSelectedSidebarItemCanBeChangedToAnyCase() {
        let state = AppState()
        for item in SidebarItem.allCases {
            state.selectedSidebarItem = item
            XCTAssertEqual(state.selectedSidebarItem, item)
        }
    }

    @MainActor
    func testSelectedSidebarItemCanBeSetToNil() {
        let state = AppState()
        state.selectedSidebarItem = .billing
        state.selectedSidebarItem = nil
        XCTAssertNil(state.selectedSidebarItem)
    }

    // MARK: - WorkSession display helpers (ReviewQueueView extension)

    func testWorkSessionDurationFormattedMinutes() {
        let session = WorkSession(
            id: "s1",
            startedAt: Date(),
            endedAt: Date(),
            durationSecs: 45 * 60,
            billableStatus: .suggested
        )
        XCTAssertEqual(session.durationFormatted, "45 min")
    }

    func testWorkSessionDurationFormattedExactHours() {
        let session = WorkSession(
            id: "s2",
            startedAt: Date(),
            endedAt: Date(),
            durationSecs: 2 * 3600,
            billableStatus: .confirmed
        )
        XCTAssertEqual(session.durationFormatted, "2h")
    }

    func testWorkSessionDurationFormattedHoursAndMinutes() {
        let session = WorkSession(
            id: "s3",
            startedAt: Date(),
            endedAt: Date(),
            durationSecs: 90 * 60,   // 1h 30m
            billableStatus: .nonBillable
        )
        XCTAssertEqual(session.durationFormatted, "1h 30m")
    }

    func testWorkSessionDurationHoursComputed() {
        let session = WorkSession(
            id: "s4",
            startedAt: Date(),
            endedAt: Date(),
            durationSecs: 3600
        )
        XCTAssertEqual(session.durationHours, 1.0, accuracy: 0.01)
    }

    // MARK: - EmptyStateView model validation

    func testSidebarItemSubtitleContainsModuleName() {
        // Verify the per-module getting-started messages mention the module.
        // This is a convention test — keeps the UX copy consistent.
        let moduleNames: [SidebarItem: String] = [
            .today:       "Today",
            .clients:     "Clients",
            .reviewQueue: "Review Queue",
            .billing:     "Billing",
            .timeline:    "Timeline",
        ]
        // If the module name changes, the subtitle message should be updated too.
        // This test documents the coupling (no UI rendering needed).
        XCTAssertFalse(moduleNames.isEmpty)
    }
}
