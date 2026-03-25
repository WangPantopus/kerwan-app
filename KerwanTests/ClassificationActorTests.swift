import XCTest
@testable import Kerwan

// MARK: - Mock Storage

/// In-memory implementation of ``ClassificationStorage`` for unit tests.
actor MockClassificationStorage: ClassificationStorage {

    // Captured writes — inspected by tests after a cycle.
    private(set) var insertedInteractions: [Interaction]  = []
    private(set) var insertedPromises:     [Promise]       = []
    private(set) var storedEmbeddings:     [(id: EntityID, vector: [Float])] = []
    private(set) var upsertedContacts:     [Contact]       = []

    // Seed data for lookups.
    var contacts: [Contact] = []
    var clients:  [Client]  = []

    func reset() {
        insertedInteractions = []
        insertedPromises     = []
        storedEmbeddings     = []
        upsertedContacts     = []
    }

    // MARK: ClassificationStorage

    func findContact(byEmail email: String) async throws -> Contact? {
        contacts.first { ($0.emailPrimary ?? "").lowercased() == email.lowercased() }
    }

    func findContact(byName name: String) async throws -> Contact? {
        contacts.first {
            $0.displayName.lowercased().trimmingCharacters(in: .whitespaces)
                == name.lowercased().trimmingCharacters(in: .whitespaces)
        }
    }

    func upsertContact(_ contact: Contact) async throws {
        upsertedContacts.append(contact)
        // Also add to the lookup pool.
        if let idx = contacts.firstIndex(where: { $0.id == contact.id }) {
            contacts[idx] = contact
        } else {
            contacts.append(contact)
        }
    }

    func listClients() async throws -> [Client] { clients }

    func insertInteraction(_ interaction: Interaction) async throws {
        insertedInteractions.append(interaction)
    }

    func insertPromise(_ promise: Promise) async throws {
        insertedPromises.append(promise)
    }

    func storeInteractionEmbedding(interactionId: EntityID, vector: [Float]) async throws {
        storedEmbeddings.append((id: interactionId, vector: vector))
    }

    func seedClient(_ client: Client) {
        clients.append(client)
    }
}

// MARK: - Helpers

private func makeEvent(
    id: String = UUID().uuidString,
    source: EventSource = .email,
    sourceApp: String? = nil,
    rawText: String? = nil,
    metadataJSON: String? = nil,
    startedAt: Date = Date(),
    endedAt: Date? = nil,
    durationSecs: Int? = nil
) -> RawEvent {
    RawEvent(
        id: id,
        source: source,
        sourceApp: sourceApp,
        startedAt: startedAt,
        endedAt: endedAt,
        durationSecs: durationSecs,
        rawText: rawText,
        metadataJSON: metadataJSON,
        isExcluded: false
    )
}

/// Builds an Ollama-style NDJSON streaming response that streams `json` as a single token.
private func ollamaStreamResponse(_ json: String) -> Data {
    let line1 = #"{"model":"llama3:8b","response":\#(escapeJSON(json)),"done":false}"# + "\n"
    let line2 = #"{"model":"llama3:8b","response":"","done":true}"# + "\n"
    return Data((line1 + line2).utf8)
}

private func escapeJSON(_ s: String) -> String {
    let escaped = s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
    return "\"\(escaped)\""
}

// MARK: - JSON Parser Tests

final class ClassificationJSONParserTests: XCTestCase {

    func testParse_wellFormedArray() {
        let json = """
        [
          {
            "id": "evt1",
            "contact_names": ["Jane Smith"],
            "contact_emails": ["jane@acme.com"],
            "client_guess": "Acme Corp",
            "project_guess": null,
            "content_types": ["promise"],
            "direction": "other",
            "promises": [{"description": "Send contract by Friday", "who": "other", "due_date": "2026-03-27"}],
            "topics": ["contract", "deadline"],
            "billable": "yes",
            "importance": 0.9,
            "sentiment": "positive",
            "summary": "Jane asked for the final contract by Friday."
          }
        ]
        """
        let results = ClassificationJSONParser.parse(json)
        XCTAssertNotNil(results)
        XCTAssertEqual(results?.count, 1)
        XCTAssertEqual(results?[0].id, "evt1")
        XCTAssertEqual(results?[0].contactNames, ["Jane Smith"])
        XCTAssertEqual(results?[0].contactEmails, ["jane@acme.com"])
        XCTAssertEqual(results?[0].clientGuess, "Acme Corp")
        XCTAssertNil(results?[0].projectGuess)
        XCTAssertEqual(results?[0].promises.count, 1)
        XCTAssertEqual(results?[0].promises[0].description, "Send contract by Friday")
        XCTAssertEqual(results?[0].promises[0].who, "other")
        XCTAssertEqual(results?[0].importance ?? 0, 0.9, accuracy: 1e-6)
        XCTAssertEqual(results?[0].sentiment, "positive")
        XCTAssertEqual(results?[0].billable, "yes")
    }

    func testParse_jsonWithPreambleText() {
        let raw = """
        Here is the extracted classification JSON as requested:
        [{"id":"e1","contact_names":[],"contact_emails":[],"client_guess":null,\
        "project_guess":null,"content_types":["factual"],"direction":"unknown",\
        "promises":[],"topics":[],"billable":"uncertain","importance":0.3,\
        "sentiment":"neutral","summary":"App activity in Figma."}]
        """
        let results = ClassificationJSONParser.parse(raw)
        XCTAssertNotNil(results)
        XCTAssertEqual(results?.count, 1)
        XCTAssertEqual(results?[0].id, "e1")
    }

    func testParse_jsonWithMarkdownFence() {
        let raw = """
        ```json
        [{"id":"e2","contact_names":["Bob"],"contact_emails":[],"client_guess":null,\
        "project_guess":null,"content_types":["small_talk"],"direction":"user",\
        "promises":[],"topics":["standup"],"billable":"no","importance":0.1,\
        "sentiment":"neutral","summary":"Standup checkin with Bob."}]
        ```
        """
        let results = ClassificationJSONParser.parse(raw)
        XCTAssertNotNil(results)
        XCTAssertEqual(results?[0].contactNames, ["Bob"])
    }

    func testParse_arrayWithOneMalformedItem() {
        // Item 0 is valid, item 1 is missing required structure but parseable with defaults,
        // and item 2 is a raw string (truly malformed as an object).
        let json = """
        [
          {"id":"good","contact_names":["Alice"],"contact_emails":[],"client_guess":null,
           "project_guess":null,"content_types":[],"direction":"user","promises":[],
           "topics":[],"billable":"uncertain","importance":0.5,"sentiment":"neutral",
           "summary":"A valid item."},
          "this is not an object at all"
        ]
        """
        let results = ClassificationJSONParser.parse(json)
        // The first item should be decoded; the string item will be skipped.
        XCTAssertNotNil(results)
        XCTAssertGreaterThanOrEqual(results?.count ?? 0, 1)
        XCTAssertEqual(results?.first?.id, "good")
    }

    func testParse_importanceClamping() {
        // LLM sometimes returns values outside [0, 1].
        let json = """
        [{"id":"x","contact_names":[],"contact_emails":[],"client_guess":null,
          "project_guess":null,"content_types":[],"direction":"unknown","promises":[],
          "topics":[],"billable":"uncertain","importance":3.5,"sentiment":"neutral",
          "summary":"Overimportant event."}]
        """
        let results = ClassificationJSONParser.parse(json)
        XCTAssertEqual(results?[0].importance, 1.0)
    }

    func testParse_returnsNilForCompleteGarbage() {
        XCTAssertNil(ClassificationJSONParser.parse("not json at all"))
        XCTAssertNil(ClassificationJSONParser.parse(""))
        XCTAssertNil(ClassificationJSONParser.parse("null"))
    }

    func testParse_handlesNullFieldsGracefully() {
        let json = """
        [{"id":"n1","contact_names":null,"contact_emails":null,"client_guess":null,
          "project_guess":null,"content_types":null,"direction":null,"promises":null,
          "topics":null,"billable":null,"importance":null,"sentiment":null,"summary":null}]
        """
        let results = ClassificationJSONParser.parse(json)
        XCTAssertNotNil(results)
        XCTAssertEqual(results?[0].contactNames, [])
        XCTAssertEqual(results?[0].direction, "unknown")
        XCTAssertEqual(results?[0].billable, "uncertain")
        XCTAssertEqual(results?[0].sentiment, "neutral")
        XCTAssertEqual(results?[0].summary, "")
    }

    func testExtractJSONArray_findsFirstAndLastBrackets() {
        let text = "Prefix text [1, 2, 3] suffix text"
        XCTAssertEqual(ClassificationJSONParser.extractJSONArray(from: text), "[1, 2, 3]")
    }

    func testExtractJSONArray_returnsNilWhenNoBrackets() {
        XCTAssertNil(ClassificationJSONParser.extractJSONArray(from: "no brackets here"))
    }

    func testExtractJSONArray_handlesNestedBrackets() {
        let text = #"prefix [{"a":[1,2]}] suffix"#
        let extracted = ClassificationJSONParser.extractJSONArray(from: text)
        XCTAssertEqual(extracted, #"[{"a":[1,2]}]"#)
    }

    // MARK: - Correlation Tests

    func testCorrelate_matchesByID() {
        let evt1 = makeEvent(id: "id-a", source: .email)
        let evt2 = makeEvent(id: "id-b", source: .audio)

        let r1 = makeResult(id: "id-b")
        let r2 = makeResult(id: "id-a")

        let pairs = ClassificationJSONParser.correlate(
            results: [r1, r2],
            events:  [evt1, evt2]
        )

        // r1 has id "id-b" → matched to evt2
        // r2 has id "id-a" → matched to evt1
        let pairedIDs = pairs.map { ($0.event.id, $0.result.id ?? "") }
        XCTAssertTrue(pairedIDs.contains(where: { $0 == ("id-a", "id-a") }))
        XCTAssertTrue(pairedIDs.contains(where: { $0 == ("id-b", "id-b") }))
    }

    func testCorrelate_fallsBackToPosition() {
        let evt1 = makeEvent(id: "id-1")
        let evt2 = makeEvent(id: "id-2")

        // Results have no id → position-based matching.
        let r1 = makeResult(id: nil)
        let r2 = makeResult(id: nil)

        let pairs = ClassificationJSONParser.correlate(
            results: [r1, r2],
            events:  [evt1, evt2]
        )
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].event.id, "id-1")
        XCTAssertEqual(pairs[1].event.id, "id-2")
    }

    private func makeResult(id: String?) -> ClassificationResult {
        let json = """
        {"id":\(id.map { "\"\($0)\"" } ?? "null"),"contact_names":[],"contact_emails":[],
         "client_guess":null,"project_guess":null,"content_types":[],"direction":"unknown",
         "promises":[],"topics":[],"billable":"uncertain","importance":0.5,
         "sentiment":"neutral","summary":"test"}
        """
        return try! JSONDecoder().decode(ClassificationResult.self, from: Data(json.utf8))
    }
}

// MARK: - Batch Assembler Tests

final class ClassificationBatchAssemblerTests: XCTestCase {

    func testAssembly_singleSmallEmailEvent() {
        let event = makeEvent(
            source: .email,
            rawText: "Hello world",
            metadataJSON: #"{"subject":"Test email"}"#
        )
        let batches = ClassificationPromptBuilder.assembleBatches(from: [event])
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].items.count, 1)
        XCTAssertTrue(batches[0].items[0].text.contains("Subject: Test email"))
        XCTAssertTrue(batches[0].items[0].text.contains("Hello world"))
    }

    func testAssembly_emailBodyTruncatedAt500Chars() {
        let longBody = String(repeating: "x", count: 1000)
        let event = makeEvent(source: .email, rawText: longBody)
        let batches = ClassificationPromptBuilder.assembleBatches(from: [event])
        XCTAssertEqual(batches[0].items[0].text.count, 500)
    }

    func testAssembly_oversizedAudioClassifiedAlone() {
        // 8001+ chars → classified alone even if other events exist.
        let bigTranscript = String(repeating: "word ", count: 2_500)  // ~12 500 chars > 8 000
        let bigEvent  = makeEvent(id: "big",   source: .audio, rawText: bigTranscript)
        let smallEvent = makeEvent(id: "small", source: .audio, rawText: "Short meeting notes.")
        let batches = ClassificationPromptBuilder.assembleBatches(from: [bigEvent, smallEvent])
        // bigEvent should be in its own batch.
        let bigBatch = batches.first { $0.sourceEvents.contains { $0.id == "big" } }
        XCTAssertNotNil(bigBatch)
        XCTAssertEqual(bigBatch?.items.count, 1)
    }

    func testAssembly_respectsMaxBatchEventCount() {
        let events = (0..<25).map { i in
            makeEvent(id: "e\(i)", source: .email, rawText: "Short email \(i)")
        }
        let batches = ClassificationPromptBuilder.assembleBatches(from: events)
        for batch in batches {
            XCTAssertLessThanOrEqual(batch.items.count, ClassificationPromptBuilder.maxBatchEventCount)
        }
        // All 25 events must appear in at least one batch.
        let allEventIDs = batches.flatMap { $0.sourceEvents.map(\.id) }
        XCTAssertEqual(Set(allEventIDs).count, 25)
    }

    func testAssembly_appFocusMergesConsecutiveSameApp() {
        let now = Date()
        let e1 = makeEvent(
            id: "f1", source: .appFocus, sourceApp: "Figma",
            startedAt: now,
            endedAt:   now.addingTimeInterval(900),
            durationSecs: 900
        )
        let e2 = makeEvent(
            id: "f2", source: .appFocus, sourceApp: "Figma",
            startedAt: now.addingTimeInterval(900),
            endedAt:   now.addingTimeInterval(2100),
            durationSecs: 1200
        )
        let e3 = makeEvent(
            id: "f3", source: .appFocus, sourceApp: "Slack",
            startedAt: now.addingTimeInterval(2100),
            endedAt:   now.addingTimeInterval(2400),
            durationSecs: 300
        )
        let merged = ClassificationPromptBuilder.mergeAppFocusRuns([e1, e2, e3])
        // e1+e2 should merge into one Figma run; e3 stays separate.
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].sourceApp, "Figma")
        XCTAssertTrue(merged[0].rawText?.contains("Figma") ?? false)
        XCTAssertEqual(merged[1].sourceApp, "Slack")
    }

    func testAssembly_appFocusDoesNotMergeAcrossGap() {
        let now = Date()
        let e1 = makeEvent(
            id: "f1", source: .appFocus, sourceApp: "Xcode",
            startedAt: now,
            endedAt:   now.addingTimeInterval(600),
            durationSecs: 600
        )
        // Gap of 10 minutes (600 s) > appFocusMergeGapSecs (300 s).
        let e2 = makeEvent(
            id: "f2", source: .appFocus, sourceApp: "Xcode",
            startedAt: now.addingTimeInterval(1200),
            endedAt:   now.addingTimeInterval(1800),
            durationSecs: 600
        )
        let merged = ClassificationPromptBuilder.mergeAppFocusRuns([e1, e2])
        XCTAssertEqual(merged.count, 2)
    }

    func testAssembly_groupsEventsBySourceType() {
        let audio  = makeEvent(id: "a1", source: .audio,    rawText: "Meeting transcript")
        let email  = makeEvent(id: "e1", source: .email,    rawText: "Email body")
        let focus  = makeEvent(id: "f1", source: .appFocus, sourceApp: "Figma", rawText: nil,
                               durationSecs: 300)
        let batches = ClassificationPromptBuilder.assembleBatches(from: [audio, email, focus])
        // Each source type should be in its own batch.
        let audioSources = batches.flatMap { $0.sourceEvents }.filter { $0.source == EventSource.audio }
        let emailSources = batches.flatMap { $0.sourceEvents }.filter { $0.source == EventSource.email }
        XCTAssertEqual(audioSources.count, 1)
        XCTAssertEqual(emailSources.count, 1)
    }

    func testBuildUserPrompt_containsEventIds() {
        let item = BatchInputItem(id: "test-id-42", source: "email",
                                  timestamp: "2026-01-01T00:00:00Z", text: "Hello")
        let batch = ClassificationBatch(items: [item], sourceEvents: [])
        let prompt = ClassificationPromptBuilder.buildUserPrompt(for: batch)
        XCTAssertTrue(prompt.contains("test-id-42"))
        XCTAssertTrue(prompt.contains("Hello"))
    }

    func testSystemPrompt_containsRequiredFields() {
        let prompt = ClassificationPromptBuilder.systemPrompt
        XCTAssertTrue(prompt.contains("contact_names"))
        XCTAssertTrue(prompt.contains("contact_emails"))
        XCTAssertTrue(prompt.contains("client_guess"))
        XCTAssertTrue(prompt.contains("promises"))
        XCTAssertTrue(prompt.contains("sentiment"))
        XCTAssertTrue(prompt.contains("JSON array"))
    }
}

// MARK: - ClassificationActor Tests

final class ClassificationActorTests: XCTestCase {

    private var storage: MockClassificationStorage!
    private var actor: ClassificationActor!

    override func setUp() {
        super.setUp()
        MockOllamaURLProtocol.reset()
        storage = MockClassificationStorage()
    }

    override func tearDown() {
        MockOllamaURLProtocol.reset()
        storage = nil
        actor   = nil
        super.tearDown()
    }

    private func makeActor(
        handlers: [String: MockOllamaURLProtocol.Handler] = [:]
    ) -> ClassificationActor {
        for (path, handler) in handlers {
            MockOllamaURLProtocol.register(path: path, handler: handler)
        }
        let session = MockOllamaURLProtocol.makeSession()
        let client  = OllamaClient(session: session)
        return ClassificationActor(client: client, storage: storage)
    }

    // MARK: - Enqueue

    func testEnqueue_addsToPendingQueue() async {
        actor = makeActor()
        let events = [makeEvent(id: "e1"), makeEvent(id: "e2")]
        await actor.enqueue(events)
        let count = await actor.pendingEventCount
        XCTAssertEqual(count, 2)
    }

    func testEnqueue_deduplicatesById() async {
        actor = makeActor()
        let event = makeEvent(id: "dup")
        await actor.enqueue([event])
        await actor.enqueue([event])  // duplicate
        let count = await actor.pendingEventCount
        XCTAssertEqual(count, 1)
    }

    func testEnqueue_dropsExcludedEvents() async {
        actor = makeActor()
        var excluded = makeEvent(id: "exc")
        excluded = RawEvent(
            id: "exc", source: .email, startedAt: Date(), isExcluded: true
        )
        await actor.enqueue([excluded])
        let count = await actor.pendingEventCount
        XCTAssertEqual(count, 0)
    }

    // MARK: - Cycle: Ollama unavailable

    func testClassificationCycle_skipsWhenOllamaUnavailable() async {
        MockOllamaURLProtocol.register(path: "api/tags") { _ in (503, Data()) }
        let session = MockOllamaURLProtocol.makeSession()
        actor = ClassificationActor(client: OllamaClient(session: session), storage: storage)

        let event = makeEvent(id: "e1", source: .email, rawText: "Important email")
        await actor.enqueue([event])
        await actor.runClassificationCycle()

        // Event must remain in queue because Ollama was down.
        let count = await actor.pendingEventCount
        XCTAssertEqual(count, 1)
    }

    // MARK: - Cycle: Well-formed response

    func testClassificationCycle_processesEmailEvent() async throws {
        // Healthy server.
        MockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }
        // LLM response for generate.
        let result = """
        [{"id":"evt-email","contact_names":["Jane Doe"],"contact_emails":["jane@acme.com"],
          "client_guess":"Acme Corp","project_guess":null,"content_types":["promise"],
          "direction":"other","promises":[{"description":"Send contract by Friday",
          "who":"other","due_date":null}],"topics":["contract"],
          "billable":"yes","importance":0.85,"sentiment":"positive",
          "summary":"Jane requested the contract by Friday."}]
        """
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, ollamaStreamResponse(result))
        }
        // Embedding.
        MockOllamaURLProtocol.register(path: "api/embeddings") { _ in
            (200, Data(#"{"embedding":[0.1,0.2,0.3]}"#.utf8))
        }

        actor = makeActor()
        let event = makeEvent(
            id: "evt-email",
            source: .email,
            rawText: "Hi, can you send the contract by Friday?",
            metadataJSON: #"{"subject":"Contract request"}"#
        )
        await actor.enqueue([event])
        await actor.runClassificationCycle()

        // Event removed from queue after success.
        let pending = await actor.pendingEventCount
        XCTAssertEqual(pending, 0)

        // Interaction created.
        let interactions = await storage.insertedInteractions
        XCTAssertEqual(interactions.count, 1)
        XCTAssertEqual(interactions[0].source, .email)
        XCTAssertEqual(interactions[0].sentiment, .positive)
        XCTAssertEqual(interactions[0].importance, 0.85, accuracy: 1e-6)
        XCTAssertTrue(interactions[0].contentTags.contains("contract"))
        XCTAssertTrue(interactions[0].contentTags.contains("billable"))

        // Promise created.
        let promises = await storage.insertedPromises
        XCTAssertEqual(promises.count, 1)
        XCTAssertEqual(promises[0].description, "Send contract by Friday")
        XCTAssertEqual(promises[0].direction, .contactPromised)

        // Embedding stored.
        let embeddings = await storage.storedEmbeddings
        XCTAssertEqual(embeddings.count, 1)
        XCTAssertEqual(embeddings[0].vector.count, 3)
    }

    func testClassificationCycle_createsNewContact() async {
        MockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }
        let result = """
        [{"id":"e1","contact_names":["New Person"],"contact_emails":["new@domain.com"],
          "client_guess":null,"project_guess":null,"content_types":["factual"],
          "direction":"other","promises":[],"topics":[],"billable":"uncertain",
          "importance":0.4,"sentiment":"neutral","summary":"A new contact appeared."}]
        """
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, ollamaStreamResponse(result))
        }
        MockOllamaURLProtocol.register(path: "api/embeddings") { _ in
            (200, Data(#"{"embedding":[0.1]}"#.utf8))
        }
        actor = makeActor()
        await actor.enqueue([makeEvent(id: "e1", rawText: "A new contact appeared.")])
        await actor.runClassificationCycle()

        let upserted = await storage.upsertedContacts
        XCTAssertFalse(upserted.isEmpty)
        // The new contact should have needsReview = true.
        XCTAssertTrue(upserted.allSatisfy(\.needsReview))
    }

    func testClassificationCycle_matchesExistingClient() async {
        MockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }
        let result = """
        [{"id":"e1","contact_names":[],"contact_emails":["pm@bigcorp.com"],
          "client_guess":"Big Corp","project_guess":null,"content_types":["status_update"],
          "direction":"other","promises":[],"topics":["status"],"billable":"yes",
          "importance":0.6,"sentiment":"neutral","summary":"Status update from Big Corp."}]
        """
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, ollamaStreamResponse(result))
        }
        MockOllamaURLProtocol.register(path: "api/embeddings") { _ in
            (200, Data(#"{"embedding":[0.1]}"#.utf8))
        }

        // Seed an existing client with matching domain.
        let client = Client(id: "client-bc", name: "Big Corp", domain: "bigcorp.com")
        await storage.seedClient(client)

        actor = makeActor()
        await actor.enqueue([makeEvent(id: "e1", rawText: "Status update.")])
        await actor.runClassificationCycle()

        let interactions = await storage.insertedInteractions
        XCTAssertEqual(interactions[0].clientId, "client-bc")
    }

    // MARK: - Cycle: Malformed JSON → retry

    func testClassificationCycle_retriesOnMalformedJSON() async {
        MockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }

        nonisolated(unsafe) var callCount = 0
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            callCount += 1
            if callCount == 1 {
                // First response: garbage before JSON.
                let bad = "Sorry I couldn't do that properly. Here's my best attempt: {broken json"
                return (200, ollamaStreamResponse(bad))
            } else {
                // Retry response: valid JSON.
                let good = """
                [{"id":"e1","contact_names":[],"contact_emails":[],"client_guess":null,
                  "project_guess":null,"content_types":["factual"],"direction":"unknown",
                  "promises":[],"topics":[],"billable":"uncertain","importance":0.3,
                  "sentiment":"neutral","summary":"Some activity."}]
                """
                return (200, ollamaStreamResponse(good))
            }
        }
        MockOllamaURLProtocol.register(path: "api/embeddings") { _ in
            (200, Data(#"{"embedding":[0.1]}"#.utf8))
        }

        actor = makeActor()
        await actor.enqueue([makeEvent(id: "e1", rawText: "Some activity.")])
        await actor.runClassificationCycle()

        // Both calls were made.
        XCTAssertEqual(callCount, 2)
        // Event should be processed successfully on retry.
        let pending = await actor.pendingEventCount
        XCTAssertEqual(pending, 0)
        let interactions = await storage.insertedInteractions
        XCTAssertEqual(interactions.count, 1)
    }

    func testClassificationCycle_keepsEventsWhenBothTriesFail() async {
        MockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, ollamaStreamResponse("completely unparseable garbage!!!"))
        }

        actor = makeActor()
        await actor.enqueue([makeEvent(id: "e1", rawText: "Something.")])
        await actor.runClassificationCycle()

        // Event stays in queue — both parse attempts failed.
        let pending = await actor.pendingEventCount
        XCTAssertEqual(pending, 1)
        let interactions = await storage.insertedInteractions
        XCTAssertEqual(interactions.count, 0)
    }

    // MARK: - Metrics

    func testMetrics_updatedAfterSuccessfulCycle() async {
        MockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }
        let result = """
        [{"id":"m1","contact_names":[],"contact_emails":[],"client_guess":null,
          "project_guess":null,"content_types":[],"direction":"unknown","promises":[],
          "topics":[],"billable":"uncertain","importance":0.5,"sentiment":"neutral",
          "summary":"Test event."}]
        """
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, ollamaStreamResponse(result))
        }
        MockOllamaURLProtocol.register(path: "api/embeddings") { _ in
            (200, Data(#"{"embedding":[0.1]}"#.utf8))
        }

        nonisolated(unsafe) var receivedMetrics: ClassificationMetrics?
        let session = MockOllamaURLProtocol.makeSession()
        actor = ClassificationActor(
            client: OllamaClient(session: session),
            storage: storage,
            onMetricsUpdate: { metrics in receivedMetrics = metrics }
        )

        await actor.enqueue([makeEvent(id: "m1", rawText: "Test event.")])
        await actor.runClassificationCycle()

        XCTAssertNotNil(receivedMetrics)
        XCTAssertEqual(receivedMetrics?.eventsClassifiedTotal, 1)
        XCTAssertEqual(receivedMetrics?.batchesProcessedTotal, 1)
        XCTAssertNotNil(receivedMetrics?.lastClassificationAt)
        XCTAssertEqual(receivedMetrics?.pendingEventCount, 0)
    }

    func testMetrics_parseFailuresTracked() async {
        MockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }
        MockOllamaURLProtocol.register(path: "api/generate") { _ in
            (200, ollamaStreamResponse("not json at all"))
        }

        nonisolated(unsafe) var receivedMetrics: ClassificationMetrics?
        let session = MockOllamaURLProtocol.makeSession()
        actor = ClassificationActor(
            client: OllamaClient(session: session),
            storage: storage,
            onMetricsUpdate: { m in receivedMetrics = m }
        )
        await actor.enqueue([makeEvent(id: "pf1", rawText: "event.")])
        await actor.runClassificationCycle()

        XCTAssertGreaterThan(receivedMetrics?.parseFailuresTotal ?? 0, 0)
    }

    // MARK: - Shutdown

    func testShutdown_doesNotCrash() async {
        actor = makeActor()
        await actor.start()
        await actor.shutdown()
        // No assertion — just confirming no crash or hang.
    }
}
