import XCTest
@testable import Kerwan

/// Unit tests for `AppState` mutations and derived properties.
///
/// All tests run on the `@MainActor` since `AppState` is MainActor-isolated.
/// No services or views are involved — these tests exercise only the state
/// container logic.
@MainActor
final class AppStateTests: XCTestCase {

    private var state: AppState!

    override func setUp() {
        super.setUp()
        state = AppState()
    }

    override func tearDown() {
        state = nil
        super.tearDown()
    }

    // MARK: - Initial state

    func testInitialCaptureStatusIsIdle() {
        XCTAssertEqual(state.captureStatus, .idle)
    }

    func testInitialActiveTranscriptionIsFalse() {
        XCTAssertFalse(state.activeTranscription)
    }

    func testInitialCountsAreZero() {
        XCTAssertEqual(state.eventsToday, 0)
        XCTAssertEqual(state.pendingReviewCount, 0)
        XCTAssertEqual(state.openPromiseCount, 0)
    }

    func testInitialSearchStateIsEmpty() {
        XCTAssertTrue(state.searchQuery.isEmpty)
        XCTAssertTrue(state.searchResults.isEmpty)
        XCTAssertFalse(state.isSearching)
    }

    func testInitialServiceAvailabilityIsFalse() {
        XCTAssertFalse(state.isWhisperServiceConnected)
        XCTAssertFalse(state.isOllamaRunning)
        XCTAssertFalse(state.isModelLoaded)
    }

    func testIsNotInitializedOnCreate() {
        XCTAssertFalse(state.isInitialized)
    }

    func testLastErrorIsNilOnCreate() {
        XCTAssertNil(state.lastError)
    }

    // MARK: - Capture status

    func testUpdateCaptureStatus() {
        state.updateCaptureStatus(.capturing)
        XCTAssertEqual(state.captureStatus, .capturing)

        state.updateCaptureStatus(.paused)
        XCTAssertEqual(state.captureStatus, .paused)

        state.updateCaptureStatus(.privateMode)
        XCTAssertEqual(state.captureStatus, .privateMode)

        state.updateCaptureStatus(.idle)
        XCTAssertEqual(state.captureStatus, .idle)

        state.updateCaptureStatus(.error("mic denied"))
        if case .error(let msg) = state.captureStatus {
            XCTAssertEqual(msg, "mic denied")
        } else {
            XCTFail("Expected .error status")
        }
    }

    func testIsCaptureActiveReflectsCaptureStatus() {
        state.updateCaptureStatus(.idle)
        XCTAssertFalse(state.isCaptureActive)

        state.updateCaptureStatus(.capturing)
        XCTAssertTrue(state.isCaptureActive)

        state.updateCaptureStatus(.paused)
        XCTAssertFalse(state.isCaptureActive)

        state.updateCaptureStatus(.privateMode)
        XCTAssertFalse(state.isCaptureActive)
    }

    // MARK: - Transcription state

    func testUpdateTranscriptionStateToTrue() {
        state.updateTranscriptionState(true)
        XCTAssertTrue(state.activeTranscription)
    }

    func testUpdateTranscriptionStateToFalse() {
        state.updateTranscriptionState(true)
        state.updateTranscriptionState(false)
        XCTAssertFalse(state.activeTranscription)
    }

    // MARK: - Badge counts

    func testUpdateEventsTodayStoresValue() {
        state.updateEventsToday(1_247)
        XCTAssertEqual(state.eventsToday, 1_247)
    }

    func testUpdatePendingReviewCount() {
        state.updatePendingReviewCount(3)
        XCTAssertEqual(state.pendingReviewCount, 3)
    }

    func testUpdateOpenPromiseCount() {
        state.updateOpenPromiseCount(7)
        XCTAssertEqual(state.openPromiseCount, 7)
    }

    func testUpdateCountsAcceptZero() {
        state.updateEventsToday(100)
        state.updateEventsToday(0)
        XCTAssertEqual(state.eventsToday, 0)
    }

    // MARK: - Service availability

    func testUpdateWhisperServiceConnection() {
        state.updateWhisperServiceConnection(true)
        XCTAssertTrue(state.isWhisperServiceConnected)

        state.updateWhisperServiceConnection(false)
        XCTAssertFalse(state.isWhisperServiceConnected)
    }

    func testUpdateOllamaRunning() {
        state.updateOllamaRunning(true)
        XCTAssertTrue(state.isOllamaRunning)
    }

    func testUpdateModelLoaded() {
        state.updateModelLoaded(true)
        XCTAssertTrue(state.isModelLoaded)
    }

    // MARK: - Errors

    func testReportErrorSetsLastError() {
        state.reportError("Database locked")
        XCTAssertEqual(state.lastError, "Database locked")
    }

    func testClearErrorRemovesLastError() {
        state.reportError("Some error")
        state.clearError()
        XCTAssertNil(state.lastError)
    }

    func testClearErrorOnAlreadyClearStateIsNoOp() {
        XCTAssertNil(state.lastError)
        state.clearError()
        XCTAssertNil(state.lastError)
    }

    // MARK: - Initialization gate

    func testMarkInitializedSetsFlag() {
        XCTAssertFalse(state.isInitialized)
        state.markInitialized()
        XCTAssertTrue(state.isInitialized)
    }

    func testMarkInitializedIsIdempotent() {
        state.markInitialized()
        state.markInitialized()   // second call must not crash
        XCTAssertTrue(state.isInitialized)
    }

    // MARK: - Navigation state

    func testSelectedSidebarItemDefaultsToToday() {
        XCTAssertEqual(state.selectedSidebarItem, .today)
    }

    func testSelectedContactAndClientDefaultToNil() {
        XCTAssertNil(state.selectedContact)
        XCTAssertNil(state.selectedClient)
    }

    func testSelectedContactCanBeSet() {
        let contact = Contact(displayName: "Jane Smith")
        state.selectedContact = contact
        XCTAssertEqual(state.selectedContact?.displayName, "Jane Smith")
    }

    func testSelectedClientCanBeSet() {
        let client = Client(name: "Acme Corp")
        state.selectedClient = client
        XCTAssertEqual(state.selectedClient?.name, "Acme Corp")
    }

    // MARK: - Search state

    func testSearchQueryCanBeSet() {
        state.searchQuery = "invoice"
        XCTAssertEqual(state.searchQuery, "invoice")
    }

    func testIsSearchingCanBeToggled() {
        state.isSearching = true
        XCTAssertTrue(state.isSearching)
        state.isSearching = false
        XCTAssertFalse(state.isSearching)
    }

    func testSearchResultsCanBeSet() {
        let result = SearchResult(
            id: "r1",
            type: .interaction,
            title: "Meeting with Jane",
            snippet: "Discussed the Q2 proposal",
            timestamp: Date(),
            relevanceScore: 0.92
        )
        state.searchResults = [result]
        XCTAssertEqual(state.searchResults.count, 1)
        XCTAssertEqual(state.searchResults.first?.title, "Meeting with Jane")
    }
}
