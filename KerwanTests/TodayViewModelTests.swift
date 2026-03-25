import XCTest
@testable import Kerwan

/// Unit tests for `TodayViewModel` computed properties.
///
/// Tests focus on pure logic (filtering, aggregation) that runs independently
/// of storage. The `storage` dependency is left nil (the ViewModel handles that
/// case gracefully — `load()` becomes a no-op).
@MainActor
final class TodayViewModelTests: XCTestCase {

    private var vm: TodayViewModel!

    override func setUp() {
        super.setUp()
        vm = TodayViewModel()
    }

    override func tearDown() {
        vm = nil
        super.tearDown()
    }

    // MARK: - upcomingMeetings

    func testUpcomingMeetingsFiltersOutOldMeetings() {
        // Meeting that started 2 hours ago is NOT upcoming.
        let old = Interaction(
            source: .audio,
            interactionType: .meeting,
            startedAt: Date(timeIntervalSinceNow: -7200)
        )
        // Meeting that started 10 minutes ago IS within the 30-min window.
        let recent = Interaction(
            source: .audio,
            interactionType: .meeting,
            startedAt: Date(timeIntervalSinceNow: -600)
        )
        // Future meeting is also upcoming.
        let future = Interaction(
            source: .audio,
            interactionType: .meeting,
            startedAt: Date(timeIntervalSinceNow: 1800)
        )

        vm.todaysMeetings = [old, recent, future]

        let upcoming = vm.upcomingMeetings
        XCTAssertFalse(upcoming.contains { $0.id == old.id },
                       "Meeting 2h ago should not be in upcoming")
        XCTAssertTrue(upcoming.contains { $0.id == recent.id },
                      "Meeting 10 min ago should be in upcoming (within 30-min window)")
        XCTAssertTrue(upcoming.contains { $0.id == future.id },
                      "Future meeting should be in upcoming")
    }

    func testUpcomingMeetingsEmptyWhenNoMeetings() {
        vm.todaysMeetings = []
        XCTAssertTrue(vm.upcomingMeetings.isEmpty)
    }

    // MARK: - overdueSoonPromises

    func testOverdueSoonPromisesFiltersOnlyOverdue() {
        let overduePromise = Promise(
            direction: .userPromised,
            description: "Send invoice",
            dueDate: Date(timeIntervalSinceNow: -86400),
            status: .open
        )
        let notOverdue = Promise(
            direction: .userPromised,
            description: "Follow up",
            dueDate: Date(timeIntervalSinceNow: 86400),
            status: .open
        )
        let noDueDate = Promise(
            direction: .contactPromised,
            description: "They'll send docs",
            status: .open
        )

        vm.dueSoonPromises = [overduePromise, notOverdue, noDueDate]

        let overdue = vm.overdueSoonPromises
        XCTAssertEqual(overdue.count, 1)
        XCTAssertEqual(overdue.first?.id, overduePromise.id)
    }

    func testOverdueSoonPromisesEmptyWhenNoneOverdue() {
        vm.dueSoonPromises = [
            Promise(direction: .userPromised, description: "Future", dueDate: Date(timeIntervalSinceNow: 86400), status: .open)
        ]
        XCTAssertTrue(vm.overdueSoonPromises.isEmpty)
    }

    // MARK: - totalYesterdayHours

    func testTotalYesterdayHoursSumsCorrectly() {
        let clientA = Client(name: "Acme")
        let clientB = Client(name: "Globex")
        vm.yesterdayHoursByClient = [(client: clientA, hours: 3.5), (client: clientB, hours: 2.0)]
        XCTAssertEqual(vm.totalYesterdayHours, 5.5, accuracy: 0.001)
    }

    func testTotalYesterdayHoursZeroWhenEmpty() {
        vm.yesterdayHoursByClient = []
        XCTAssertEqual(vm.totalYesterdayHours, 0.0)
    }

    // MARK: - Initial state

    func testInitialLoadingStateIsFalse() {
        XCTAssertFalse(vm.isLoading)
    }

    func testInitialErrorIsNil() {
        XCTAssertNil(vm.error)
    }

    func testInitialDigestIsNil() {
        XCTAssertNil(vm.latestDigest)
    }

    // MARK: - load() no-ops without storage

    func testLoadWithNilStorageDoesNotThrow() async {
        // With nil storage, load() should return immediately without crashing.
        await vm.load()
        XCTAssertFalse(vm.isLoading)
    }
}

