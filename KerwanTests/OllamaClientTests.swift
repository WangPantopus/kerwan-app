import XCTest
@testable import Kerwan

// MARK: - Mock URLProtocol

/// A `URLProtocol` subclass that intercepts all requests and dispatches them to
/// registered handler closures keyed by URL path.
///
/// Usage:
/// ```swift
/// MockOllamaURLProtocol.register(path: "api/tags") { _ in
///     (200, Data(#"{"models":[]}"#.utf8))
/// }
/// let session = MockOllamaURLProtocol.makeSession()
/// let client  = OllamaClient(session: session)
/// ```
final class MockOllamaURLProtocol: URLProtocol, @unchecked Sendable {

    /// Handler type: receives the `URLRequest` and returns `(statusCode, responseData)`.
    typealias Handler = @Sendable (URLRequest) -> (Int, Data)

    /// Thread-safe handler registry.
    private static let lock = NSLock()
    private static var _handlers: [String: Handler] = [:]

    static var handlers: [String: Handler] {
        get { lock.withLock { _handlers } }
        set { lock.withLock { _handlers = newValue } }
    }

    /// Registers `handler` for all requests whose URL path ends with `path`.
    static func register(path: String, handler: @escaping Handler) {
        lock.withLock { _handlers[path] = handler }
    }

    /// Clears all registered handlers. Call in `tearDown`.
    static func reset() {
        lock.withLock { _handlers = [:] }
    }

    /// Returns a `URLSession` configured to intercept all requests with this protocol.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockOllamaURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""

        // Find matching handler: try full path first, then last path component.
        let handler = Self.handlers[path]
            ?? Self.handlers[String(path.split(separator: "/").last ?? Substring(path))]
            ?? { _ in (404, Data(#"{"error":"no handler registered for path: \#(path)"}"#.utf8)) }

        // URLSession moves httpBody to httpBodyStream when routing through URLProtocol.
        // Reconstruct a request with httpBody populated for handler convenience.
        var resolvedRequest = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var bodyData = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buffer, maxLength: 4096)
                if n > 0 { bodyData.append(buffer, count: n) }
            }
            stream.close()
            resolvedRequest.httpBody = bodyData
        }

        let (statusCode, data) = handler(resolvedRequest)

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Test Suite

final class OllamaClientTests: XCTestCase {

    private var session: URLSession!
    private var client: OllamaClient!

    override func setUp() {
        super.setUp()
        MockOllamaURLProtocol.reset()
        session = MockOllamaURLProtocol.makeSession()
        client  = OllamaClient(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            session: session
        )
    }

    override func tearDown() {
        MockOllamaURLProtocol.reset()
        session = nil
        client  = nil
        super.tearDown()
    }

    // MARK: - isHealthy

    func testIsHealthy_returnsTrue_whenServerResponds() async {
        MockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }
        let healthy = await client.isHealthy()
        XCTAssertTrue(healthy)
    }

    func testIsHealthy_returnsFalse_onNon200Status() async {
        MockOllamaURLProtocol.register(path: "api/tags") { _ in
            (503, Data())
        }
        let healthy = await client.isHealthy()
        XCTAssertFalse(healthy)
    }

    // MARK: - listModels

    func testListModels_parsesEmptyArray() async throws {
        MockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }
        let models = try await client.listModels()
        XCTAssertTrue(models.isEmpty)
    }

    func testListModels_parsesMultipleModels() async throws {
        let json = """
        {
          "models": [
            {
              "name": "llama3:8b-instruct-q4_K_M",
              "modified_at": "2024-06-01T00:00:00Z",
              "size": 4700000000,
              "digest": "sha256:abc123",
              "details": {
                "format": "gguf",
                "family": "llama",
                "parameter_size": "8B",
                "quantization_level": "Q4_K_M"
              }
            },
            {
              "name": "nomic-embed-text",
              "modified_at": "2024-05-15T00:00:00Z",
              "size": 274000000,
              "digest": "sha256:def456"
            }
          ]
        }
        """
        MockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(json.utf8))
        }
        let models = try await client.listModels()
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].name, "llama3:8b-instruct-q4_K_M")
        XCTAssertEqual(models[0].details?.family, "llama")
        XCTAssertEqual(models[0].details?.quantizationLevel, "Q4_K_M")
        XCTAssertEqual(models[1].name, "nomic-embed-text")
        XCTAssertNil(models[1].details)
    }

    func testListModels_throwsOnServerError() async {
        MockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"error":"database locked"}"#.utf8))
        }
        do {
            _ = try await client.listModels()
            XCTFail("Expected OllamaError.serverError")
        } catch OllamaError.serverError(let msg) {
            XCTAssertEqual(msg, "database locked")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testListModels_throwsOnHTTPError() async {
        MockOllamaURLProtocol.register(path: "api/tags") { _ in
            (500, Data(#"internal server error"#.utf8))
        }
        do {
            _ = try await client.listModels()
            XCTFail("Expected OllamaError.requestFailed")
        } catch OllamaError.requestFailed(let code, _) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - complete

    func testComplete_accumulatesStreamedTokens() async throws {
        // Simulate Ollama NDJSON streaming response.
        let ndjson = """
        {"model":"llama3:8b","created_at":"2024-01-01T00:00:00Z","response":"Hello","done":false}
        {"model":"llama3:8b","created_at":"2024-01-01T00:00:00Z","response":", ","done":false}
        {"model":"llama3:8b","created_at":"2024-01-01T00:00:00Z","response":"world","done":false}
        {"model":"llama3:8b","created_at":"2024-01-01T00:00:00Z","response":"","done":true,"context":[1,2,3],"total_duration":1000000}
        """
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, Data(ndjson.utf8))
        }
        let result = try await client.complete(
            prompt: "Say hello",
            system: "Be concise",
            model: "llama3:8b-instruct-q4_K_M"
        )
        XCTAssertEqual(result, "Hello, world")
    }

    func testComplete_throwsOnServerError() async {
        let ndjson = """
        {"error":"model not found"}
        """
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, Data(ndjson.utf8))
        }
        do {
            _ = try await client.complete(prompt: "x", system: nil, model: "bad-model")
            XCTFail("Expected OllamaError.serverError")
        } catch OllamaError.serverError(let msg) {
            XCTAssertEqual(msg, "model not found")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testComplete_includesSystemWhenProvided() async throws {
        nonisolated(unsafe) var capturedBody: [String: Any]?
        MockOllamaURLProtocol.register(path: "api/generate") { request in
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                capturedBody = json
            }
            let ndjson = """
            {"model":"m","response":"ok","done":true}
            """
            return (200, Data(ndjson.utf8))
        }
        _ = try await client.complete(
            prompt: "hello",
            system: "You are helpful",
            model: "llama3:8b-instruct-q4_K_M"
        )
        XCTAssertEqual(capturedBody?["system"] as? String, "You are helpful")
        XCTAssertEqual(capturedBody?["stream"] as? Bool, true)
    }

    func testComplete_omitsSystemWhenNil() async throws {
        nonisolated(unsafe) var capturedBody: [String: Any]?
        MockOllamaURLProtocol.register(path: "api/generate") { request in
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                capturedBody = json
            }
            return (200, Data(#"{"model":"m","response":"ok","done":true}"#.utf8))
        }
        _ = try await client.complete(prompt: "hello", system: nil, model: "m")
        XCTAssertNil(capturedBody?["system"])
    }

    // MARK: - completeJSON

    func testCompleteJSON_parsesAccumulatedJSON() async throws {
        // Ollama streams the JSON token-by-token.
        let ndjson = """
        {"model":"llama3:8b","response":"{","done":false}
        {"model":"llama3:8b","response":"\\"client\\":\\"Acme\\"","done":false}
        {"model":"llama3:8b","response":"}","done":true}
        """
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, Data(ndjson.utf8))
        }
        let result = try await client.completeJSON(
            prompt: "Extract client",
            system: nil,
            model: "llama3:8b-instruct-q4_K_M"
        )
        guard let dict = result as? [String: Any] else {
            XCTFail("Expected [String: Any]")
            return
        }
        XCTAssertEqual(dict["client"] as? String, "Acme")
    }

    func testCompleteJSON_throwsWhenResponseNotJSON() async {
        let ndjson = """
        {"model":"m","response":"not json at all","done":true}
        """
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, Data(ndjson.utf8))
        }
        do {
            _ = try await client.completeJSON(prompt: "x", system: nil, model: "m")
            XCTFail("Expected OllamaError.invalidResponse")
        } catch OllamaError.invalidResponse {
            // Pass
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCompleteJSON_requestIncludesFormatJSON() async throws {
        nonisolated(unsafe) var capturedBody: [String: Any]?
        MockOllamaURLProtocol.register(path: "api/generate") { request in
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                capturedBody = json
            }
            return (200, Data(#"{"model":"m","response":"{}","done":true}"#.utf8))
        }
        _ = try? await client.completeJSON(prompt: "x", system: nil, model: "m")
        XCTAssertEqual(capturedBody?["format"] as? String, "json")
    }

    // MARK: - embed

    func testEmbed_returnsFloatVector() async throws {
        let json = #"{"embedding":[0.1,0.2,0.3,0.4,0.5]}"#
        MockOllamaURLProtocol.register(path: "api/embeddings") { _ in
            (200, Data(json.utf8))
        }
        let vector = try await client.embed(
            text: "Hello world",
            model: "nomic-embed-text"
        )
        XCTAssertEqual(vector.count, 5)
        XCTAssertEqual(vector[0], 0.1, accuracy: 1e-6)
        XCTAssertEqual(vector[4], 0.5, accuracy: 1e-6)
    }

    func testEmbed_sendsCorrectRequestBody() async throws {
        nonisolated(unsafe) var capturedBody: [String: Any]?
        MockOllamaURLProtocol.register(path: "api/embeddings") { request in
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                capturedBody = json
            }
            return (200, Data(#"{"embedding":[0.5]}"#.utf8))
        }
        _ = try await client.embed(text: "test input", model: "nomic-embed-text")
        XCTAssertEqual(capturedBody?["model"] as? String, "nomic-embed-text")
        XCTAssertEqual(capturedBody?["prompt"] as? String, "test input")
    }

    func testEmbed_throwsOnServerError() async {
        MockOllamaURLProtocol.register(path: "api/embeddings") { _ in
            (200, Data(#"{"error":"model not loaded"}"#.utf8))
        }
        do {
            _ = try await client.embed(text: "x", model: "nomic-embed-text")
            XCTFail("Expected OllamaError.serverError")
        } catch OllamaError.serverError(let msg) {
            XCTAssertEqual(msg, "model not loaded")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - embedBatch

    func testEmbedBatch_returnsMultipleVectors() async throws {
        let json = #"{"embeddings":[[0.1,0.2],[0.3,0.4],[0.5,0.6]]}"#
        MockOllamaURLProtocol.register(path: "api/embed") { _ in
            (200, Data(json.utf8))
        }
        let vectors = try await client.embedBatch(
            texts: ["a", "b", "c"],
            model: "nomic-embed-text"
        )
        XCTAssertEqual(vectors.count, 3)
        XCTAssertEqual(vectors[0], [0.1, 0.2])
        XCTAssertEqual(vectors[2][1], 0.6, accuracy: 1e-6)
    }

    func testEmbedBatch_emptyInputReturnsEmptyOutput() async throws {
        // No handler needed — should short-circuit before network call.
        let vectors = try await client.embedBatch(texts: [], model: "nomic-embed-text")
        XCTAssertTrue(vectors.isEmpty)
    }

    func testEmbedBatch_sendsArrayInput() async throws {
        nonisolated(unsafe) var capturedBody: [String: Any]?
        MockOllamaURLProtocol.register(path: "api/embed") { request in
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                capturedBody = json
            }
            return (200, Data(#"{"embeddings":[[0.1],[0.2]]}"#.utf8))
        }
        _ = try await client.embedBatch(texts: ["foo", "bar"], model: "nomic-embed-text")
        XCTAssertEqual(capturedBody?["model"] as? String, "nomic-embed-text")
        let inputs = capturedBody?["input"] as? [String]
        XCTAssertEqual(inputs, ["foo", "bar"])
    }

    // MARK: - pullModel

    func testPullModel_reportsProgressAndCompletesOnSuccess() async throws {
        let ndjson = """
        {"status":"pulling manifest"}
        {"status":"downloading layer","completed":0,"total":1000}
        {"status":"downloading layer","completed":250,"total":1000}
        {"status":"downloading layer","completed":750,"total":1000}
        {"status":"downloading layer","completed":1000,"total":1000}
        {"status":"verifying sha256 digest"}
        {"status":"writing manifest"}
        {"status":"success"}
        """
        MockOllamaURLProtocol.register(path: "api/pull") { _ in
            (200, Data(ndjson.utf8))
        }

        var progressValues: [Double] = []
        try await client.pullModel(name: "llama3:8b-instruct-q4_K_M") { fraction in
            progressValues.append(fraction)
        }

        // Should have progress at 0/1000, 250/1000, 750/1000, 1000/1000, then 1.0 on success.
        XCTAssertFalse(progressValues.isEmpty)
        XCTAssertEqual(progressValues.last, 1.0)

        let fractions = progressValues.dropLast()  // remove the 1.0 "success" callback
        if let first = fractions.first { XCTAssertEqual(first, 0.0, accuracy: 1e-6) }
        if let midway = fractions.first(where: { $0 > 0.5 }) {
            XCTAssertEqual(midway, 0.75, accuracy: 1e-6)
        }
    }

    func testPullModel_throwsModelPullFailedOnError() async {
        let ndjson = """
        {"status":"pulling manifest"}
        {"error":"pull model manifest: file does not exist"}
        """
        MockOllamaURLProtocol.register(path: "api/pull") { _ in
            (200, Data(ndjson.utf8))
        }
        do {
            try await client.pullModel(name: "bad-model:latest") { _ in }
            XCTFail("Expected OllamaError.modelPullFailed")
        } catch OllamaError.modelPullFailed(let model, let msg) {
            XCTAssertEqual(model, "bad-model:latest")
            XCTAssertTrue(msg.contains("does not exist"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPullModel_sendsCorrectRequestBody() async throws {
        nonisolated(unsafe) var capturedBody: [String: Any]?
        MockOllamaURLProtocol.register(path: "api/pull") { request in
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                capturedBody = json
            }
            return (200, Data(#"{"status":"success"}"#.utf8))
        }
        try await client.pullModel(name: "nomic-embed-text") { _ in }
        XCTAssertEqual(capturedBody?["name"] as? String, "nomic-embed-text")
        XCTAssertEqual(capturedBody?["stream"] as? Bool, true)
    }

    // MARK: - OllamaModel Codable

    func testOllamaModel_roundTrip() throws {
        let json = """
        {
          "name": "llama3:8b-instruct-q4_K_M",
          "modified_at": "2024-06-01T00:00:00Z",
          "size": 4700000000,
          "digest": "sha256:abc123",
          "details": {
            "format": "gguf",
            "family": "llama",
            "parameter_size": "8B",
            "quantization_level": "Q4_K_M"
          }
        }
        """
        let model = try JSONDecoder().decode(OllamaModel.self, from: Data(json.utf8))
        XCTAssertEqual(model.id, "llama3:8b-instruct-q4_K_M")
        XCTAssertEqual(model.size, 4_700_000_000)
        XCTAssertEqual(model.details?.parameterSize, "8B")

        // Re-encode and re-decode to confirm round-trip.
        let reencoded = try JSONEncoder().encode(model)
        let redecoded = try JSONDecoder().decode(OllamaModel.self, from: reencoded)
        XCTAssertEqual(model, redecoded)
    }

    func testOllamaModel_missingOptionalFields() throws {
        let json = #"{"name":"nomic-embed-text"}"#
        let model = try JSONDecoder().decode(OllamaModel.self, from: Data(json.utf8))
        XCTAssertEqual(model.name, "nomic-embed-text")
        XCTAssertNil(model.size)
        XCTAssertNil(model.details)
    }

    // MARK: - OllamaError descriptions

    func testOllamaError_localizedDescriptions() {
        XCTAssertTrue(OllamaError.notInstalled.errorDescription!.contains("https://ollama.com"))
        XCTAssertTrue(OllamaError.healthCheckTimeout.errorDescription!.contains("30"))
        XCTAssertTrue(OllamaError.maxRestartsExceeded.errorDescription!.contains("unavailable"))
        XCTAssertTrue(
            OllamaError.modelPullFailed(model: "llama3", message: "timeout").errorDescription!
                .contains("llama3")
        )
        XCTAssertTrue(
            OllamaError.requestFailed(statusCode: 404, body: "not found").errorDescription!
                .contains("404")
        )
        XCTAssertTrue(
            OllamaError.serverError("OOM").errorDescription!.contains("OOM")
        )
    }
}
