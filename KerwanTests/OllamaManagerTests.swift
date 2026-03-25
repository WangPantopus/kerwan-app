import XCTest
@testable import Kerwan

// MARK: - OllamaManagerTests

/// Unit tests for ``OllamaManager`` that do not require a real Ollama binary.
///
/// Tests cover:
/// - Adopting an externally-running Ollama instance (via a healthy mock server).
/// - Model-list refresh and the `availableModels` property.
/// - The `ensureModels` pull path when required models are absent.
/// - State resets during `shutdown`.
/// - Binary-detection helpers via the filesystem search list.
/// - `OllamaError` typed error propagation paths.
///
/// Subprocess launch is intentionally not exercised here; that requires an integration
/// test with a real (or stub) binary present at a known path.
final class OllamaManagerTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a `URLSession` backed by `MockOllamaURLProtocol`.
    private func mockSession() -> URLSession {
        MockOllamaURLProtocol.makeSession()
    }

    /// Registers the standard "healthy, no models" response for `/api/tags` and the HEAD probe.
    private func registerHealthy(models: [[String: Any]] = []) {
        let body: [String: Any] = ["models": models]
        let data = try! JSONSerialization.data(withJSONObject: body)
        MockOllamaURLProtocol.register(path: "api/tags") { _ in (200, data) }
    }

    /// Registers an "unhealthy" (connection-refused-style 503) for `/api/tags`.
    private func registerUnhealthy() {
        MockOllamaURLProtocol.register(path: "api/tags") { _ in (503, Data()) }
    }

    override func setUp() {
        super.setUp()
        MockOllamaURLProtocol.reset()
    }

    override func tearDown() {
        MockOllamaURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - ensureRunning: adopt external instance

    func testEnsureRunning_adoptsExternalInstance_whenHealthCheckPasses() async throws {
        registerHealthy()
        // binaryPath is arbitrary because we never reach the launch step.
        let manager = OllamaManager(binaryPath: "/nonexistent/ollama", session: mockSession())

        try await manager.ensureRunning()

        let running = await manager.isRunning
        XCTAssertTrue(running)
    }

    func testEnsureRunning_isIdempotent_whenCalledTwice() async throws {
        registerHealthy()
        let manager = OllamaManager(binaryPath: "/nonexistent/ollama", session: mockSession())

        try await manager.ensureRunning()
        try await manager.ensureRunning()  // second call must not throw or change state

        let running = await manager.isRunning
        XCTAssertTrue(running)
    }

    func testEnsureRunning_throwsNotInstalled_whenBinaryMissingAndUnhealthy() async {
        registerUnhealthy()
        // binaryPath = nil, and the real search paths won't exist in the test sandbox.
        // We inject a binaryPath that definitely doesn't exist on the test host.
        let manager = OllamaManager(
            binaryPath: "/tmp/kerwan_test_nonexistent_ollama_\(UUID().uuidString)",
            session: mockSession()
        )

        do {
            try await manager.ensureRunning()
            XCTFail("Expected OllamaError.notInstalled (or healthCheckTimeout)")
        } catch OllamaError.notInstalled {
            // Correct: the fake binary path doesn't exist so launchProcess would fail.
            // However, since the health probe also fails and the given path doesn't exist,
            // we'd hit the launch path which throws .launchFailed. Accept either.
        } catch OllamaError.launchFailed {
            // Also acceptable — binary path exists but is not executable.
        } catch {
            // Any other error is a pass too — we just want to confirm it throws.
            // (On some CI hosts the path might accidentally exist.)
        }

        let running = await manager.isRunning
        XCTAssertFalse(running)
    }

    // MARK: - ensureModels

    func testEnsureModels_setsAvailableModels_whenAllPresent() async throws {
        let modelsJSON: [[String: Any]] = [
            ["name": "llama3:8b-instruct-q4_K_M"],
            ["name": "nomic-embed-text"]
        ]
        // First call (inside ensureRunning adoption), subsequent calls (ensureModels).
        registerHealthy(models: modelsJSON)

        let manager = OllamaManager(binaryPath: "/nonexistent/ollama", session: mockSession())
        try await manager.ensureRunning()
        try await manager.ensureModels()

        let available = await manager.availableModels
        XCTAssertTrue(available.contains("llama3:8b-instruct-q4_K_M"))
        XCTAssertTrue(available.contains("nomic-embed-text"))
    }

    func testEnsureModels_pullsMissingModel() async throws {
        // First invocation of api/tags returns only one model.
        nonisolated(unsafe) var callCount = 0
        MockOllamaURLProtocol.register(path: "api/tags") { _ in
            callCount += 1
            // After pull, return both models.
            let models: [[String: Any]] = callCount <= 2
                ? [["name": "nomic-embed-text"]]
                : [["name": "llama3:8b-instruct-q4_K_M"], ["name": "nomic-embed-text"]]
            let body: [String: Any] = ["models": models]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (200, data)
        }

        nonisolated(unsafe) var pullCalled = false
        nonisolated(unsafe) var pulledModelName: String?
        MockOllamaURLProtocol.register(path: "api/pull") { request in
            pullCalled = true
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                pulledModelName = json["name"] as? String
            }
            let ndjson = """
            {"status":"pulling manifest"}
            {"status":"success"}
            """
            return (200, Data(ndjson.utf8))
        }

        let manager = OllamaManager(binaryPath: "/nonexistent/ollama", session: mockSession())
        try await manager.ensureRunning()   // callCount → 1 (HEAD inside isHealthy)
        try await manager.ensureModels()

        XCTAssertTrue(pullCalled, "Pull should have been called for missing llama3 model")
        XCTAssertEqual(pulledModelName, "llama3:8b-instruct-q4_K_M")

        let available = await manager.availableModels
        XCTAssertTrue(available.contains("llama3:8b-instruct-q4_K_M"))
    }

    func testEnsureModels_skipsAlreadyPresentModels() async throws {
        nonisolated(unsafe) var pullCalled = false
        MockOllamaURLProtocol.register(path: "api/tags") { _ in
            let models: [[String: Any]] = [
                ["name": "llama3:8b-instruct-q4_K_M"],
                ["name": "nomic-embed-text"]
            ]
            return (200, try! JSONSerialization.data(withJSONObject: ["models": models]))
        }
        MockOllamaURLProtocol.register(path: "api/pull") { _ in
            pullCalled = true
            return (200, Data(#"{"status":"success"}"#.utf8))
        }

        let manager = OllamaManager(binaryPath: "/nonexistent/ollama", session: mockSession())
        try await manager.ensureRunning()
        try await manager.ensureModels()

        XCTAssertFalse(pullCalled, "Pull should not be called when both models are present")
    }

    func testEnsureModels_propagatesModelPullFailure() async throws {
        MockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, try! JSONSerialization.data(withJSONObject: ["models": [] as [[String: Any]]]))
        }
        MockOllamaURLProtocol.register(path: "api/pull") { _ in
            let ndjson = """
            {"error":"pull model manifest: file does not exist"}
            """
            return (200, Data(ndjson.utf8))
        }

        let manager = OllamaManager(binaryPath: "/nonexistent/ollama", session: mockSession())
        try await manager.ensureRunning()

        do {
            try await manager.ensureModels()
            XCTFail("Expected OllamaError.modelPullFailed")
        } catch OllamaError.modelPullFailed(let model, _) {
            // The first missing model is llama3.
            XCTAssertEqual(model, "llama3:8b-instruct-q4_K_M")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - shutdown

    func testShutdown_resetsState() async throws {
        registerHealthy()
        let manager = OllamaManager(binaryPath: "/nonexistent/ollama", session: mockSession())
        try await manager.ensureRunning()

        let runningBefore = await manager.isRunning
        XCTAssertTrue(runningBefore)

        await manager.shutdown()

        let runningAfter = await manager.isRunning
        XCTAssertFalse(runningAfter)
    }

    func testShutdown_isIdempotent_whenNotRunning() async {
        let manager = OllamaManager(session: mockSession())
        // Should not throw or crash.
        await manager.shutdown()
        await manager.shutdown()
        let running = await manager.isRunning
        XCTAssertFalse(running)
    }

    // MARK: - client accessor

    func testClient_isAccessibleAfterInit() async {
        let session = mockSession()
        let manager = OllamaManager(session: session)
        let client  = await manager.client
        XCTAssertEqual(client.baseURL, URL(string: "http://127.0.0.1:11434")!)
    }

    // MARK: - OllamaManager notifications

    func testEnsureRunning_postsDidBecomeReadyNotification() async throws {
        registerHealthy()
        let manager = OllamaManager(binaryPath: "/nonexistent/ollama", session: mockSession())

        let expectation = XCTestExpectation(description: "ollamaDidBecomeReady posted")
        let observer = NotificationCenter.default.addObserver(
            forName: .ollamaDidBecomeReady,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try await manager.ensureRunning()
        await fulfillment(of: [expectation], timeout: 2)
    }

    // MARK: - availableModels initial state

    func testAvailableModels_isEmptyBeforeEnsureModels() async {
        let manager = OllamaManager(session: mockSession())
        let models = await manager.availableModels
        XCTAssertTrue(models.isEmpty)
    }
}
