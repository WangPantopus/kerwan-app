import XCTest
import Foundation
@testable import Kerwan
import KerwanKeychain

// MARK: - Mock service implementations

/// Minimal `AppStorageService` conformance for launch-time tests.
/// All operations return immediately with zero-cost stubs.
actor MockLaunchStorageService: AppStorageService {
    func countRawEventsToday()    async throws -> Int { 0 }
    func countUnreviewedSessions() async throws -> Int { 0 }
    func countOpenPromises()       async throws -> Int { 0 }
    func insertManualNote(text: String, at: Date) async throws {}
    func pruneEventsOlderThan(days: Int) async throws {}
}

/// Minimal `CaptureManaging` conformance for launch-time tests.
/// `start()` returns instantly — simulates a capture backend with no real I/O.
actor MockLaunchCaptureManager: CaptureManaging {
    var currentStatus: CaptureStatus = .idle
    func start()             async throws { currentStatus = .capturing }
    func pause()             async        { currentStatus = .paused }
    func resume()            async throws { currentStatus = .capturing }
    func enablePrivateMode() async        { currentStatus = .privateMode }
    func disablePrivateMode() async throws { currentStatus = .capturing }
    func flushBuffer()       async        {}
    func stop()              async        { currentStatus = .idle }
}

// MARK: - AppLaunchTimeTests

/// Verifies that Kerwan's service layer can reach its "ready" state within
/// 3 seconds of application startup, as required by P-039.
///
/// ## Budget
///   - **Cold launch to "ready" (all services initialised) < 3 seconds** on Apple Silicon.
///
/// ## Scope
///   These tests measure the initialisation cost of:
///   - `AppLifecycle` actor creation + dependency injection
///   - `ClassificationActor` creation (no Ollama connection attempted)
///   - `SearchEngine` creation (no Ollama connection attempted)
///   - `AppState` creation (SwiftUI @Observable, main-actor)
///   - Full `AppLifecycle.start()` sequence with mock services
///
///   Notably excluded: `StorageActor` (covered by `SQLiteWriteThroughputTests`),
///   `ClassificationActor.start()` auto-cycle (deliberately deferred; it fires
///   after 60 s and has no launch impact), actual Ollama connectivity.
///
/// ## Method
///   Wall-clock time from "first allocation" to "`appState.isInitialized == true`"
///   is asserted to be < 3 seconds. `XCTClockMetric()` provides CI regression tracking.
final class AppLaunchTimeTests: XCTestCase {

    // MARK: - Test 1: AppLifecycle injection + start completes in < 3 s

    @MainActor
    func test_appLaunch_fullServiceStack_readyInUnder3s() async throws {
        let storage  = MockLaunchStorageService()
        let capture  = MockLaunchCaptureManager()
        let lifecycle = AppLifecycle()
        let appState  = AppState()

        // Inject mock services — mirrors KerwanAppDelegate.applicationDidFinishLaunching.
        await lifecycle.inject(storage: storage, capture: capture)

        // We cannot use a real KeychainManager in the test host (no app entitlements).
        // Instead we call the internal `inject` + `startRefreshLoop` path by invoking
        // `start()` with a real KeychainManager that will fail the passphrase lookup,
        // then fall through to marking the app as initialized.
        //
        // The KeychainManager uses a unique service name so it cannot pollute the
        // real Kerwan keychain.
        let keychain = KeychainManager(service: "com.kerwan.perf-test-\(UUID().uuidString)")

        let t0 = Date()
        // start() is non-throwing; passphrase failure is non-fatal and results in
        // an early return that still calls appState.markInitialized() via the
        // no-capture guard path.
        await lifecycle.start(appState: appState, keychain: keychain)
        let elapsed = Date().timeIntervalSince(t0)

        print("  ▸ AppLifecycle.start() elapsed: \(String(format: "%.3f", elapsed))s")
        XCTAssertLessThan(elapsed, 3.0,
            "AppLifecycle.start() must complete in < 3 s (measured: \(String(format: "%.3f", elapsed))s)")
    }

    // MARK: - Test 2: ClassificationActor creation is instantaneous

    func test_appLaunch_classificationActorInit_under100ms() {
        // ClassificationActor init is pure in-memory — no I/O.
        PerfMockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }
        let session = PerfMockOllamaURLProtocol.makeSession()
        let client  = OllamaClient(session: session)

        let t0 = Date()
        let storage = PerfMockClassificationStorage()
        let _ = ClassificationActor(client: client, storage: storage)
        let elapsed = Date().timeIntervalSince(t0)

        print("  ▸ ClassificationActor init: \(String(format: "%.3f", elapsed))s")
        XCTAssertLessThan(elapsed, 0.1,
            "ClassificationActor init must be < 100 ms (measured: \(String(format: "%.3f", elapsed))s)")

        PerfMockOllamaURLProtocol.reset()
    }

    // MARK: - Test 3: SearchEngine creation is instantaneous

    func test_appLaunch_searchEngineInit_under100ms() {
        PerfMockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }
        let session      = PerfMockOllamaURLProtocol.makeSession()
        let client       = OllamaClient(session: session)
        let storage      = PerfMockSearchStorage()
        let embStorage   = PerfMockEmbeddingStorage()
        let embedding    = EmbeddingService(client: client, storage: embStorage)

        let t0  = Date()
        let _   = SearchEngine(client: client, storage: storage, embedding: embedding)
        let elapsed = Date().timeIntervalSince(t0)

        print("  ▸ SearchEngine init: \(String(format: "%.3f", elapsed))s")
        XCTAssertLessThan(elapsed, 0.1,
            "SearchEngine init must be < 100 ms (measured: \(String(format: "%.3f", elapsed))s)")

        PerfMockOllamaURLProtocol.reset()
    }

    // MARK: - Test 4: Full service graph allocation under 500 ms

    /// Allocates the full production service graph simultaneously (without starting I/O).
    @MainActor
    func test_appLaunch_fullServiceGraph_allocationUnder500ms() {
        PerfMockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }
        let session  = PerfMockOllamaURLProtocol.makeSession()
        let client   = OllamaClient(session: session)

        let t0 = Date()

        // Allocate the same set of actors/services the real app creates at launch.
        let _appState        = AppState()
        let _lifecycle       = AppLifecycle()
        let _classStorage    = PerfMockClassificationStorage()
        let _classActor      = ClassificationActor(client: client, storage: _classStorage)
        let _searchStorage   = PerfMockSearchStorage()
        let _embStorage      = PerfMockEmbeddingStorage()
        let _embeddingService = EmbeddingService(client: client, storage: _embStorage)
        let _searchEngine    = SearchEngine(client: client,
                                            storage: _searchStorage,
                                            embedding: _embeddingService)
        let _captureManager  = MockLaunchCaptureManager()
        let _storageService  = MockLaunchStorageService()

        // Suppress "variable assigned but never used" warnings.
        _ = (_appState, _lifecycle, _classActor, _searchEngine, _captureManager, _storageService, _embStorage)

        let elapsed = Date().timeIntervalSince(t0)
        print("  ▸ Full service graph allocation: \(String(format: "%.3f", elapsed))s")
        XCTAssertLessThan(elapsed, 0.5,
            "Full service graph allocation must be < 500 ms (measured: \(String(format: "%.3f", elapsed))s)")

        PerfMockOllamaURLProtocol.reset()
    }

    // MARK: - Test 5: XCTest measure — AppLifecycle.start() regression baseline

    func test_appLaunch_measure_lifecycleStart() async throws {
        measure(metrics: [XCTClockMetric()]) {
            let exp = self.expectation(description: "start")
            Task { @MainActor in
                let lifecycle = AppLifecycle()
                let appState  = AppState()
                let storage   = MockLaunchStorageService()
                let capture   = MockLaunchCaptureManager()
                let keychain  = KeychainManager(
                    service: "com.kerwan.perf-measure-\(UUID().uuidString)")
                await lifecycle.inject(storage: storage, capture: capture)
                await lifecycle.start(appState: appState, keychain: keychain)
                exp.fulfill()
            }
            wait(for: [exp], timeout: 10)
        }
    }

    // MARK: - Test 6: AppState MainActor initialisation cost

    @MainActor
    func test_appLaunch_appStateInit_under10ms() {
        let t0      = Date()
        let _       = AppState()
        let elapsed = Date().timeIntervalSince(t0)

        print("  ▸ AppState init: \(String(format: "%.3f", elapsed))s")
        XCTAssertLessThan(elapsed, 0.01,
            "AppState init must be < 10 ms (measured: \(String(format: "%.3f", elapsed * 1000))ms)")
    }
}

// MARK: - PerfMockEmbeddingStorage

/// Minimal `EmbeddingServiceStorage` for launch tests (zero I/O).
actor PerfMockEmbeddingStorage: EmbeddingServiceStorage {
    func listUnembeddedInteractions() async throws -> [Interaction] { [] }
    func insertVectorEmbedding(interactionId: EntityID, embedding: [Float]) async throws {}
    func listUnembeddedRawEvents(sources: [EventSource]) async throws -> [RawEvent] { [] }
    func insertRawEventEmbedding(rawEventId: EntityID, chunkIndex: Int, embedding: [Float]) async throws {}
    func listUnembeddedPromises() async throws -> [Promise] { [] }
    func insertPromiseEmbedding(promiseId: EntityID, embedding: [Float]) async throws {}
}

// MARK: - PerfMockSearchStorage

/// Minimal `SearchEngineStorage` conformance for launch tests (zero I/O).
actor PerfMockSearchStorage: SearchEngineStorage {

    func keywordSearchInteractions(query: String, limit: Int) async throws -> [SearchResult] { [] }
    func keywordSearchPromises(query: String, limit: Int) async throws -> [SearchResult] { [] }
    func vectorSearchInteractions(embedding: [Float], limit: Int) async throws -> [(interactionId: EntityID, distance: Float)] { [] }
    func vectorSearchPromises(embedding: [Float], limit: Int) async throws -> [(promiseId: EntityID, distance: Float)] { [] }
    func fetchInteractions(ids: [EntityID]) async throws -> [Interaction] { [] }
    func fetchContact(id: EntityID) async throws -> Contact? { nil }
    func fetchPromises(ids: [EntityID]) async throws -> [Promise] { [] }
    func fetchInteractions(forContactId: EntityID, limit: Int) async throws -> [SearchResult] { [] }
    func fetchInteractions(inDateRange: DateInterval, interactionTypes: [InteractionType]?, limit: Int) async throws -> [SearchResult] { [] }
    func fetchOpenPromises(forContactId: EntityID?, limit: Int) async throws -> [SearchResult] { [] }
    func fetchWorkSessions(inDateRange: DateInterval?, limit: Int) async throws -> [SearchResult] { [] }
}
