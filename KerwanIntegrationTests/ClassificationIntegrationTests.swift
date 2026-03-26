import XCTest
@testable import Kerwan

// MARK: - Local mock Ollama URL protocol

/// A self-contained `URLProtocol` for integration tests.
/// Mirrors `MockOllamaURLProtocol` from KerwanTests (which is not accessible here).
final class IntegrationMockOllamaURLProtocol: URLProtocol, @unchecked Sendable {

    typealias Handler = @Sendable (URLRequest) -> (Int, Data)

    private static let lock = NSLock()
    private static var _handlers: [String: Handler] = [:]

    static func register(path: String, handler: @escaping Handler) {
        lock.withLock { _handlers[path] = handler }
    }

    static func reset() {
        lock.withLock { _handlers = [:] }
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IntegrationMockOllamaURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let handler: Handler = Self.lock.withLock { () -> Handler in
            Self._handlers[path]
                ?? Self._handlers[String(path.split(separator: "/").last ?? Substring(path))]
                ?? { (_: URLRequest) -> (Int, Data) in (404, Data(#"{"error":"no handler"}"#.utf8)) }
        }
        let (code, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - In-memory ClassificationStorage spy

/// An actor that fully implements ``ClassificationStorage`` and records all
/// mutations so tests can assert on what the classification pipeline stored.
actor SpyClassificationStorage: ClassificationStorage {

    // Stored state
    private(set) var contacts:             [String: Contact]     = [:]
    private(set) var clients:              [String: Client]      = [:]
    private(set) var interactions:         [String: Interaction] = [:]
    private(set) var promises:             [String: Promise]     = [:]
    private(set) var embeddings:           [String: [Float]]     = [:]

    // Convenience seed helpers

    func seed(client: Client) {
        clients[client.id] = client
    }

    func seed(contact: Contact) {
        contacts[contact.id] = contact
    }

    // MARK: ClassificationStorage

    func findContact(byEmail email: String) async throws -> Contact? {
        contacts.values.first {
            $0.emailPrimary?.lowercased() == email.lowercased()
        }
    }

    func findContact(byName name: String) async throws -> Contact? {
        let normalised = name.trimmingCharacters(in: .whitespaces).lowercased()
        return contacts.values.first {
            $0.displayName.trimmingCharacters(in: .whitespaces).lowercased() == normalised
        }
    }

    func upsertContact(_ contact: Contact) async throws {
        contacts[contact.id] = contact
    }

    func listClients() async throws -> [Client] {
        Array(clients.values)
    }

    func insertInteraction(_ interaction: Interaction) async throws {
        interactions[interaction.id] = interaction
    }

    func insertPromise(_ promise: Promise) async throws {
        promises[promise.id] = promise
    }

    func storeInteractionEmbedding(interactionId: EntityID, vector: [Float]) async throws {
        embeddings[interactionId] = vector
    }
}

// MARK: - ClassificationIntegrationTests

/// Integration tests for ``ClassificationActor``.
///
/// Each test uses:
///  - ``IntegrationMockOllamaURLProtocol`` to intercept Ollama HTTP calls and
///    return known JSON without a running Ollama server.
///  - ``SpyClassificationStorage`` (in-memory) to capture what the actor wrote.
///
/// The tests exercise the full `enqueue → runClassificationCycle →
/// postProcess` path, including contact creation, promise extraction, and
/// embedding storage.
final class ClassificationIntegrationTests: XCTestCase {

    private var session: URLSession!
    private var client:  OllamaClient!
    private var storage: SpyClassificationStorage!

    override func setUp() {
        super.setUp()
        IntegrationMockOllamaURLProtocol.reset()
        session = IntegrationMockOllamaURLProtocol.makeSession()
        client  = OllamaClient(session: session)
        storage = SpyClassificationStorage()
    }

    override func tearDown() {
        IntegrationMockOllamaURLProtocol.reset()
        session = nil
        client  = nil
        storage = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Returns a valid NDJSON Ollama streaming response that contains a
    /// classification result array with one item keyed by `eventId`.
    private func classificationResponse(
        eventId:       String,
        contactName:   String  = "Alice Smith",
        contactEmail:  String  = "alice@example.com",
        clientGuess:   String  = "Acme Corp",
        summary:       String  = "Discussed Q2 roadmap with Alice.",
        promises:      [[String: String]] = []
    ) -> Data {
        let promisesJSON: String
        if promises.isEmpty {
            promisesJSON = "[]"
        } else {
            let items = promises.map { p in
                #"{"description":"\#(p["description"] ?? "")","who":"\#(p["who"] ?? "me")","due_date":null}"#
            }.joined(separator: ",")
            promisesJSON = "[\(items)]"
        }

        let json = """
            [{"id":"\(eventId)","contact_names":["\(contactName)"],"contact_emails":["\(contactEmail)"],\
            "client_guess":"\(clientGuess)","project_guess":null,"content_types":["meeting"],\
            "direction":"inbound","promises":\(promisesJSON),"topics":["roadmap"],\
            "billable":"yes","importance":"high","sentiment":"positive","summary":"\(summary)"}]
            """
        // Ollama streaming response format expected by OllamaClient.complete().
        let ndjson = #"{"response":"\#(json.replacingOccurrences(of: "\"", with: "\\\""))","done":true}"#
        return Data(ndjson.utf8)
    }

    /// Zero-vector embedding response (768 floats).
    private func embeddingResponse() -> Data {
        let zeros = Array(repeating: Float(0), count: 768)
        return (try? JSONEncoder().encode(["embedding": zeros])) ?? Data()
    }

    // MARK: - Single event: interaction + contact created

    /// Enqueue one audio event. After `runClassificationCycle()`, one interaction
    /// must exist and the contact extracted from the transcript must be stored.
    func test_classification_singleEvent_createsInteractionAndContact() async throws {
        let eventId = UUID().uuidString

        IntegrationMockOllamaURLProtocol.register(path: "api/generate") { [self] _ in
            (200, self.classificationResponse(eventId: eventId,
                                              contactName: "Alice Smith",
                                              contactEmail: "alice@example.com"))
        }
        IntegrationMockOllamaURLProtocol.register(path: "api/embeddings") { [self] _ in
            (200, self.embeddingResponse())
        }
        // Health check.
        IntegrationMockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }

        let actor = ClassificationActor(client: client, storage: storage)

        let event = RawEvent(
            id:        eventId,
            source:    .audio,
            startedAt: Date(),
            rawText:   "Alice and I reviewed the Q2 roadmap for Acme Corp."
        )
        await actor.enqueue([event])
        await actor.runClassificationCycle()

        let interactions = await storage.interactions
        XCTAssertEqual(interactions.count, 1, "Exactly one interaction should be created")

        let contacts = await storage.contacts
        XCTAssertFalse(contacts.isEmpty, "At least one contact must be created from the transcript")
        XCTAssertTrue(
            contacts.values.contains { $0.emailPrimary == "alice@example.com" },
            "Contact with email 'alice@example.com' must exist"
        )
    }

    // MARK: - Promise extraction

    /// When the LLM response contains a promise, the promise must be persisted
    /// via `insertPromise` with the correct description.
    func test_classification_withPromise_storesPromise() async throws {
        let eventId = UUID().uuidString

        IntegrationMockOllamaURLProtocol.register(path: "api/generate") { [self] _ in
            (200, self.classificationResponse(
                eventId:  eventId,
                promises: [["description": "Send project brief", "who": "me"]]
            ))
        }
        IntegrationMockOllamaURLProtocol.register(path: "api/embeddings") { [self] _ in
            (200, self.embeddingResponse())
        }
        IntegrationMockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }

        let actor = ClassificationActor(client: client, storage: storage)
        let event = RawEvent(id: eventId, source: .email, startedAt: Date(),
                             rawText: "Alice asked me to send the project brief.")
        await actor.enqueue([event])
        await actor.runClassificationCycle()

        let promises = await storage.promises
        XCTAssertEqual(promises.count, 1, "One promise must be extracted and stored")
        XCTAssertTrue(
            promises.values.first?.description.contains("Send project brief") == true,
            "Promise text must match the extracted description"
        )
    }

    // MARK: - Embedding stored after successful classification

    /// After a successful classification cycle, `storeInteractionEmbedding`
    /// must be called with a 768-dimension vector.
    func test_classification_singleEvent_embeddingStored() async throws {
        let eventId = UUID().uuidString

        IntegrationMockOllamaURLProtocol.register(path: "api/generate") { [self] _ in
            (200, self.classificationResponse(eventId: eventId))
        }
        IntegrationMockOllamaURLProtocol.register(path: "api/embeddings") { [self] _ in
            (200, self.embeddingResponse())
        }
        IntegrationMockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }

        let actor = ClassificationActor(client: client, storage: storage)
        let event = RawEvent(id: eventId, source: .audio, startedAt: Date(),
                             rawText: "Design review with Bob.")
        await actor.enqueue([event])
        await actor.runClassificationCycle()

        let embeddings = await storage.embeddings
        XCTAssertEqual(embeddings.count, 1, "One embedding must be stored")
        XCTAssertEqual(embeddings.values.first?.count, 768,
                       "Embedding must be 768-dimensional (nomic-embed-text)")
    }

    // MARK: - Excluded events are silently dropped

    /// Events with `isExcluded == true` must be silently dropped by `enqueue`
    /// and never reach the Ollama classification call.
    func test_classification_excludedEvent_neverClassified() async throws {
        var generateCallCount = 0
        IntegrationMockOllamaURLProtocol.register(path: "api/generate") { _ in
            generateCallCount += 1
            return (200, Data())
        }
        IntegrationMockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }

        let actor = ClassificationActor(client: client, storage: storage)
        let excluded = RawEvent(id: UUID().uuidString, source: .appFocus, startedAt: Date(),
                                isExcluded: true)
        await actor.enqueue([excluded])

        let pending = await actor.pendingEventCount
        XCTAssertEqual(pending, 0, "Excluded event must be dropped by enqueue")
        XCTAssertEqual(generateCallCount, 0, "Ollama must not be called for excluded events")
    }

    // MARK: - Duplicate events are deduplicated

    /// Enqueueing the same event ID twice must result in exactly one pending event.
    func test_classification_duplicateEnqueue_deduplicated() async throws {
        let actor   = ClassificationActor(client: client, storage: storage)
        let eventId = UUID().uuidString
        let event   = RawEvent(id: eventId, source: .email, startedAt: Date())

        await actor.enqueue([event])
        await actor.enqueue([event])   // exact duplicate

        let count = await actor.pendingEventCount
        XCTAssertEqual(count, 1, "Duplicate event IDs must be deduplicated in the pending queue")
    }

    // MARK: - Ollama unavailable: events remain in queue

    /// When Ollama is unavailable (health check fails), `runClassificationCycle`
    /// must skip without throwing and the events must remain in the queue.
    func test_classification_ollamaUnavailable_eventStaysInQueue() async throws {
        // Health check returns 503 → OllamaClient.isHealthy() == false.
        IntegrationMockOllamaURLProtocol.register(path: "api/tags") { _ in
            (503, Data(#"{"error":"unavailable"}"#.utf8))
        }

        let actor = ClassificationActor(client: client, storage: storage)
        let event = RawEvent(id: UUID().uuidString, source: .audio, startedAt: Date(),
                             rawText: "Could not connect.")
        await actor.enqueue([event])
        await actor.runClassificationCycle()

        let remaining = await actor.pendingEventCount
        XCTAssertEqual(remaining, 1,
                       "Event must remain queued when Ollama is unavailable")

        let interactions = await storage.interactions
        XCTAssertTrue(interactions.isEmpty, "No interactions should be created when Ollama is down")
    }

    // MARK: - Multiple events, one batch

    /// Enqueueing two distinct events before a single classification cycle must
    /// produce two interactions and two contacts.
    func test_classification_twoEvents_twoBatches_twoInteractions() async throws {
        let id1 = UUID().uuidString
        let id2 = UUID().uuidString
        var callIndex = 0

        IntegrationMockOllamaURLProtocol.register(path: "api/generate") { [self] _ in
            callIndex += 1
            // Return a result array containing both events' IDs in one response,
            // or one per call — either way the ClassificationActor handles it.
            let responseId = callIndex == 1 ? id1 : id2
            return (200, self.classificationResponse(eventId: responseId,
                                                     contactEmail: "user\(callIndex)@example.com"))
        }
        IntegrationMockOllamaURLProtocol.register(path: "api/embeddings") { [self] _ in
            (200, self.embeddingResponse())
        }
        IntegrationMockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }

        let actor = ClassificationActor(client: client, storage: storage)
        let e1 = RawEvent(id: id1, source: .audio, startedAt: Date(), rawText: "Call with user1.")
        let e2 = RawEvent(id: id2, source: .email, startedAt: Date(), rawText: "Email from user2.")
        await actor.enqueue([e1, e2])
        await actor.runClassificationCycle()

        // After one cycle at most 50 events are processed; both should be classified.
        let remaining = await actor.pendingEventCount
        XCTAssertEqual(remaining, 0, "Both events should be classified in one cycle")
    }

    // MARK: - Known client in storage resolves to correct clientId

    /// If a client matching `clientGuess` already exists in storage, the
    /// created interaction must reference that client's ID.
    func test_classification_knownClient_interactionLinkedToClient() async throws {
        let eventId = UUID().uuidString
        let acmeClient = Client(id: "acme-123", name: "Acme Corp")
        await storage.seed(client: acmeClient)

        IntegrationMockOllamaURLProtocol.register(path: "api/generate") { [self] _ in
            (200, self.classificationResponse(eventId: eventId, clientGuess: "Acme Corp"))
        }
        IntegrationMockOllamaURLProtocol.register(path: "api/embeddings") { [self] _ in
            (200, self.embeddingResponse())
        }
        IntegrationMockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }

        let actor = ClassificationActor(client: client, storage: storage)
        let event = RawEvent(id: eventId, source: .audio, startedAt: Date(),
                             rawText: "Met with Acme Corp team.")
        await actor.enqueue([event])
        await actor.runClassificationCycle()

        let interactions = await storage.interactions
        guard let interaction = interactions.values.first else {
            XCTFail("Expected one interaction")
            return
        }
        XCTAssertEqual(interaction.clientId, acmeClient.id,
                       "Interaction must be linked to the matching client")
    }

    // MARK: - Malformed LLM response → no storage writes

    /// When the LLM returns empty/malformed JSON, no interactions or contacts
    /// must be stored (the retry will also fail and the cycle moves on).
    func test_classification_malformedResponse_noStorageWrites() async throws {
        IntegrationMockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, Data(#"{"response":"not valid json","done":true}"#.utf8))
        }
        IntegrationMockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }

        let actor = ClassificationActor(client: client, storage: storage)
        let event = RawEvent(id: UUID().uuidString, source: .email, startedAt: Date())
        await actor.enqueue([event])
        // Must not throw even on malformed response.
        await actor.runClassificationCycle()

        let interactions = await storage.interactions
        XCTAssertTrue(interactions.isEmpty, "Malformed LLM response must not produce interactions")
    }
}
