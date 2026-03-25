import XCTest
import Foundation
@testable import Kerwan

// MARK: - PerfMockOllamaURLProtocol

/// A `URLProtocol` subclass that simulates Ollama responses with a configurable
/// per-request latency. Used exclusively by `ClassificationThroughputTests`.
///
/// This is a local copy of the `MockOllamaURLProtocol` pattern from `KerwanTests`
/// (that target is not accessible from `KerwanPerformanceTests`).
final class PerfMockOllamaURLProtocol: URLProtocol, @unchecked Sendable {

    typealias Handler = @Sendable (URLRequest) -> (Int, Data)

    private static let lock = NSLock()
    private static var _handlers: [String: Handler] = [:]

    static var handlers: [String: Handler] {
        get { lock.withLock { _handlers } }
        set { lock.withLock { _handlers = newValue } }
    }

    static func register(path: String, handler: @escaping Handler) {
        lock.withLock { _handlers[path] = handler }
    }

    static func reset() {
        lock.withLock { _handlers = [:] }
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PerfMockOllamaURLProtocol.self]
        config.timeoutIntervalForRequest = 300
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let handler = Self.handlers[path]
            ?? Self.handlers[String(path.split(separator: "/").last ?? Substring(path))]
            ?? { _ in (404, Data(#"{"error":"no handler"}"#.utf8)) }

        let (statusCode, data) = handler(request)
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

// MARK: - PerfMockClassificationStorage

/// Lightweight in-memory implementation of `ClassificationStorage` for throughput tests.
actor PerfMockClassificationStorage: ClassificationStorage {
    private(set) var classifiedCount = 0

    func findContact(byEmail _: String) async throws -> Contact? { nil }
    func findContact(byName _:  String) async throws -> Contact? { nil }
    func upsertContact(_ c: Contact) async throws {}
    func listClients() async throws -> [Client] { [] }
    func insertInteraction(_ i: Interaction) async throws { classifiedCount += 1 }
    func insertPromise(_ p: Promise) async throws {}
    func storeInteractionEmbedding(interactionId _: EntityID, vector _: [Float]) async throws {}
}

// MARK: - Helpers

/// Builds a streaming NDJSON classification response for `eventIds`.
/// Format matches what `ClassificationJSONParser` expects.
private func classificationStreamNDJSON(for eventIds: [String], latencySeconds: Double) -> Data {
    // We introduce latency at the protocol level by sleeping in a detached task —
    // URLProtocol's `startLoading` must return promptly, so we offload the sleep
    // to an async context and deliver data after the delay.
    // (This helper just builds the data payload; sleep is handled at registration.)
    let items = eventIds.map { id -> String in
        """
        {"id":"\(id)","contact_names":["Alice Perf"],\
        "contact_emails":["alice@perf.test"],\
        "client_guess":"PerfClient","project_guess":null,\
        "content_types":["meeting"],"direction":"inbound",\
        "promises":[],"topics":["throughput"],"billable":"yes",\
        "importance":"normal","sentiment":"neutral",\
        "summary":"Throughput test interaction for event \(id)."}
        """
    }.joined(separator: ",")
    let json    = "[\(items)]"
    let escaped = json
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    let ndjson  = #"{"model":"llama3","response":"\#(escaped)","done":true}"# + "\n"
    return Data(ndjson.utf8)
}

/// Builds a 768-element mock embedding NDJSON response.
private func embeddingNDJSON() -> Data {
    let vector = Array(repeating: Float(0.1), count: 768)
    let floats  = vector.map { String($0) }.joined(separator: ",")
    let json    = #"{"embedding":[\#(floats)]}"#
    return Data(json.utf8)
}

/// Builds an Ollama `/api/tags` health response.
private func tagsResponse() -> Data {
    Data(#"{"models":[{"name":"llama3:8b-instruct-q4_K_M"}]}"#.utf8)
}

// MARK: - ClassificationThroughputTests

/// Verifies that the `ClassificationActor` pipeline meets its throughput budget
/// when Ollama introduces a realistic 3-second per-batch latency.
///
/// ## Budget
///   - **> 100 events classified per minute** at 3 s/batch Ollama latency.
///
/// ## Method
///   - Ollama is mocked via `PerfMockOllamaURLProtocol`.
///   - Mock responses are delivered after a configurable `simulatedLatency`.
///   - Multiple classification cycles are executed back-to-back; total events
///     classified divided by elapsed time gives the projected rate.
///   - The test is designed to complete in < 30 seconds by limiting the number
///     of cycles while still producing a statistically valid throughput estimate.
final class ClassificationThroughputTests: XCTestCase {

    // MARK: - Constants

    /// Simulated Ollama response latency per batch call (3 seconds per requirement).
    private static let simulatedLatencySeconds: Double = 3.0

    /// Number of events to enqueue per test cycle group.
    private static let eventsPerCycle = 50  // matches ClassificationActor's per-cycle cap

    /// How many back-to-back cycles to run for the measurement.
    private static let cycleCount = 5

    // MARK: - setUp / tearDown

    override func setUp() {
        super.setUp()
        PerfMockOllamaURLProtocol.reset()
    }

    override func tearDown() {
        PerfMockOllamaURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    /// Configures `PerfMockOllamaURLProtocol` for a complete classification run.
    ///
    /// - `api/tags` returns a healthy model list (no simulated delay — health check is fast).
    /// - `api/generate` sleeps for `simulatedLatencySeconds` then returns a valid classification.
    /// - `api/embeddings` returns a 768-dim mock vector (no simulated delay).
    private func setupMockOllama(latency: Double, eventIds: @escaping @Sendable () -> [String]) {
        PerfMockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, tagsResponse())
        }
        PerfMockOllamaURLProtocol.register(path: "api/generate") { _ in
            Thread.sleep(forTimeInterval: latency)
            let ids = eventIds()
            return (200, classificationStreamNDJSON(for: ids, latencySeconds: latency))
        }
        PerfMockOllamaURLProtocol.register(path: "api/embeddings") { _ in
            (200, embeddingNDJSON())
        }
    }

    /// Creates a batch of `count` synthetic `RawEvent` values.
    private func makeEvents(count: Int, offset: Int = 0) -> [RawEvent] {
        (0..<count).map { i in
            RawEvent(
                id:           "perf-\(offset + i)",
                source:       .email,
                sourceApp:    "Mail",
                startedAt:    Date(timeIntervalSince1970: Double(offset + i) * 60),
                rawText:      "Performance test email body \(offset + i).",
                isExcluded:   false
            )
        }
    }

    // MARK: - Test 1: Throughput at 3 s/batch Ollama latency exceeds 100 events/min

    func test_classificationThroughput_3sLatency_over100EventsPerMinute() async throws {
        let storage = PerfMockClassificationStorage()
        var capturedEventIds: [String] = []
        let lock = NSLock()

        // Register mock. The generate handler captures event IDs from the current batch.
        PerfMockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, tagsResponse())
        }
        PerfMockOllamaURLProtocol.register(path: "api/generate") { req in
            Thread.sleep(forTimeInterval: Self.simulatedLatencySeconds)
            let ids = lock.withLock { capturedEventIds }
            return (200, classificationStreamNDJSON(for: ids, latencySeconds: Self.simulatedLatencySeconds))
        }
        PerfMockOllamaURLProtocol.register(path: "api/embeddings") { _ in
            (200, embeddingNDJSON())
        }

        let session = PerfMockOllamaURLProtocol.makeSession()
        let client  = OllamaClient(session: session)
        let actor   = ClassificationActor(
            client: client,
            storage: storage,
            cycleInterval: .seconds(9999)   // disable auto-timer; we drive cycles manually
        )

        let totalEvents = Self.eventsPerCycle * Self.cycleCount
        let events = makeEvents(count: totalEvents)

        // Enqueue all events up front.
        await actor.enqueue(events)

        // Update captured IDs before each cycle so the mock returns matching event IDs.
        let t0 = Date()
        for c in 0..<Self.cycleCount {
            let batchStart = c * Self.eventsPerCycle
            let batchEnd   = min(batchStart + Self.eventsPerCycle, totalEvents)
            let batchIDs   = events[batchStart..<batchEnd].map(\.id)
            lock.withLock { capturedEventIds = batchIDs }
            await actor.runClassificationCycle()
        }
        let elapsedSeconds = Date().timeIntervalSince(t0)

        let classified     = await storage.classifiedCount
        let eventsPerMin   = Double(classified) / elapsedSeconds * 60.0

        print("  ▸ Classification throughput: \(String(format: "%.1f", eventsPerMin)) events/min")
        print("  ▸ Classified \(classified)/\(totalEvents) in \(String(format: "%.1f", elapsedSeconds))s")

        XCTAssertGreaterThan(eventsPerMin, 100.0,
            "Classification throughput must exceed 100 events/min at 3s Ollama latency " +
            "(measured: \(String(format: "%.1f", eventsPerMin)) events/min)")
    }

    // MARK: - Test 2: Throughput with 0 ms latency establishes upper bound

    /// With instant Ollama responses the pipeline should process > 1 000 events/min,
    /// demonstrating that overhead outside the LLM call is negligible.
    func test_classificationThroughput_zeroLatency_over1000EventsPerMinute() async throws {
        PerfMockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, tagsResponse())
        }
        PerfMockOllamaURLProtocol.register(path: "api/generate") { _ in
            let ids = (0..<Self.eventsPerCycle).map { "fast-\($0)" }
            return (200, classificationStreamNDJSON(for: ids, latencySeconds: 0))
        }
        PerfMockOllamaURLProtocol.register(path: "api/embeddings") { _ in
            (200, embeddingNDJSON())
        }

        let session = PerfMockOllamaURLProtocol.makeSession()
        let client  = OllamaClient(session: session)
        let storage = PerfMockClassificationStorage()
        let actor   = ClassificationActor(
            client: client,
            storage: storage,
            cycleInterval: .seconds(9999)
        )

        let events = makeEvents(count: Self.eventsPerCycle * Self.cycleCount)
        await actor.enqueue(events)

        let t0 = Date()
        for _ in 0..<Self.cycleCount {
            await actor.runClassificationCycle()
        }
        let elapsed = Date().timeIntervalSince(t0)

        let classified   = await storage.classifiedCount
        let eventsPerMin = Double(classified) / elapsed * 60.0

        print("  ▸ Zero-latency throughput: \(String(format: "%.1f", eventsPerMin)) events/min")

        XCTAssertGreaterThan(eventsPerMin, 1_000.0,
            "Zero-latency throughput must exceed 1 000 events/min (measured: \(String(format: "%.1f", eventsPerMin)))")
    }

    // MARK: - Test 3: Ollama unavailability does not block enqueue

    /// When Ollama is unhealthy (api/tags returns 503), `enqueue` must still complete
    /// instantly and the pending queue must reflect the correct count.
    func test_classificationThroughput_ollamaDown_enqueueNonBlocking() async {
        PerfMockOllamaURLProtocol.register(path: "api/tags") { _ in
            (503, Data())
        }

        let session = PerfMockOllamaURLProtocol.makeSession()
        let client  = OllamaClient(session: session)
        let storage = PerfMockClassificationStorage()
        let actor   = ClassificationActor(
            client: client,
            storage: storage,
            cycleInterval: .seconds(9999)
        )

        let events = makeEvents(count: 200)

        let t0 = Date()
        await actor.enqueue(events)
        let elapsed = Date().timeIntervalSince(t0)

        let pending = await actor.pendingEventCount
        XCTAssertEqual(pending, 200)
        XCTAssertLessThan(elapsed, 1.0,
            "enqueue() must complete in < 1 s regardless of Ollama health (elapsed: \(String(format: "%.3f", elapsed))s)")
    }

    // MARK: - Test 4: XCTest measure — one classification cycle

    /// Provides an XCTest regression baseline for a single cycle at 3 s simulated latency.
    func test_classificationThroughput_measure_oneCycleAt3sLatency() async throws {
        let storage = PerfMockClassificationStorage()
        let events  = makeEvents(count: Self.eventsPerCycle)
        let eventIds = events.map(\.id)

        PerfMockOllamaURLProtocol.register(path: "api/tags") { _ in (200, tagsResponse()) }
        PerfMockOllamaURLProtocol.register(path: "api/generate") { _ in
            Thread.sleep(forTimeInterval: Self.simulatedLatencySeconds)
            return (200, classificationStreamNDJSON(for: eventIds, latencySeconds: Self.simulatedLatencySeconds))
        }
        PerfMockOllamaURLProtocol.register(path: "api/embeddings") { _ in (200, embeddingNDJSON()) }

        let session = PerfMockOllamaURLProtocol.makeSession()
        let client  = OllamaClient(session: session)
        let actor   = ClassificationActor(
            client: client,
            storage: storage,
            cycleInterval: .seconds(9999)
        )

        measure(metrics: [XCTClockMetric()]) {
            let exp = self.expectation(description: "cycle")
            Task {
                await actor.enqueue(events)
                await actor.runClassificationCycle()
                exp.fulfill()
            }
            wait(for: [exp], timeout: 15)
        }
    }
}
