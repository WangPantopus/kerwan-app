import XCTest
@testable import Kerwan

// MARK: - In-memory mock storage

/// Records every embedding write so tests can assert on the stored data.
actor MockEmbeddingStorage: EmbeddingServiceStorage {

    // Seeded input data
    var unembeddedInteractions: [Interaction]  = []
    var unembeddedRawEvents:    [RawEvent]     = []
    var unembeddedPromises:     [Promise]      = []

    // Captured writes
    private(set) var interactionEmbeddings: [(id: EntityID, vector: [Float])]                  = []
    private(set) var rawEventEmbeddings:    [(id: EntityID, chunk: Int, vector: [Float])]       = []
    private(set) var promiseEmbeddings:     [(id: EntityID, vector: [Float])]                   = []

    // EmbeddingServiceStorage

    func listUnembeddedInteractions() async throws -> [Interaction] { unembeddedInteractions }

    func insertVectorEmbedding(interactionId: EntityID, embedding: [Float]) async throws {
        interactionEmbeddings.append((interactionId, embedding))
    }

    func listUnembeddedRawEvents(sources: [EventSource]) async throws -> [RawEvent] {
        unembeddedRawEvents.filter { sources.contains($0.source) }
    }

    func insertRawEventEmbedding(rawEventId: EntityID, chunkIndex: Int, embedding: [Float]) async throws {
        rawEventEmbeddings.append((rawEventId, chunkIndex, embedding))
    }

    func listUnembeddedPromises() async throws -> [Promise] { unembeddedPromises }

    func insertPromiseEmbedding(promiseId: EntityID, embedding: [Float]) async throws {
        promiseEmbeddings.append((promiseId, embedding))
    }

    // Seed helpers (actor-isolated so they can be called with await from tests)

    func seed(interactions: [Interaction]) { unembeddedInteractions = interactions }
    func seed(rawEvents: [RawEvent])       { unembeddedRawEvents    = rawEvents }
    func seed(promises: [Promise])         { unembeddedPromises     = promises }

    // Convenience counts

    func interactionEmbeddingCount() -> Int { interactionEmbeddings.count }
    func rawEventEmbeddingCount()    -> Int { rawEventEmbeddings.count }
    func promiseEmbeddingCount()     -> Int { promiseEmbeddings.count }
}

// MARK: - HTTP mock helpers

/// Returns `{"embeddings": [[0.0, 0.1, 0.2], ...]}` with `count` rows of `dims` dimensions.
private func makeEmbedBatchResponse(count: Int, dims: Int = 3) -> Data {
    let vec  = (0..<dims).map { Double($0) * 0.1 }
    let rows = Array(repeating: vec, count: max(0, count))
    return (try? JSONSerialization.data(withJSONObject: ["embeddings": rows])) ?? Data()
}

/// Returns `{"embedding": [0.0, 0.1, …]}` with `dims` elements.
private func makeSingleEmbedResponse(dims: Int = 3) -> Data {
    let vec = (0..<dims).map { Double($0) * 0.1 }
    return (try? JSONSerialization.data(withJSONObject: ["embedding": vec])) ?? Data()
}

private func makeOllamaClient() -> OllamaClient {
    OllamaClient(session: MockOllamaURLProtocol.makeSession())
}

/// Registers healthy mock responses for the common Ollama endpoints.
///
/// `batchHandler` is called with the number of input texts and should return the
/// response `Data`. Defaults to a matching-count 3-dim response.
private func registerEmbedMocks(
    batchHandler: (@Sendable (Int) -> Data)? = nil
) {
    MockOllamaURLProtocol.register(path: "api/tags") { _ in
        (200, Data(#"{"models":[]}"#.utf8))
    }
    MockOllamaURLProtocol.register(path: "api/embed") { request in
        let body = (try? JSONSerialization.jsonObject(
            with: request.httpBody ?? Data()
        ) as? [String: Any]) ?? [:]
        let count = (body["input"] as? [String])?.count ?? 0
        let data  = batchHandler?(count) ?? makeEmbedBatchResponse(count: count)
        return (200, data)
    }
    MockOllamaURLProtocol.register(path: "api/embeddings") { _ in
        (200, makeSingleEmbedResponse())
    }
}

// MARK: - TextPreparationTests

final class TextPreparationTests: XCTestCase {

    // MARK: HTML stripping

    func test_stripHTML_removesTagsPreservesText() {
        let out = TextPreparation.stripHTML(from: "<b>Hello</b> <em>World</em>")
        XCTAssertTrue(out.contains("Hello"))
        XCTAssertTrue(out.contains("World"))
        XCTAssertFalse(out.contains("<b>"))
        XCTAssertFalse(out.contains("</em>"))
    }

    func test_stripHTML_handlesNestedTags() {
        let out = TextPreparation.stripHTML(from: "<div><p>Content</p></div>")
        XCTAssertTrue(out.contains("Content"))
        XCTAssertFalse(out.contains("<"))
    }

    func test_stripHTML_emptyString_returnsEmpty() {
        XCTAssertEqual(TextPreparation.stripHTML(from: ""), "")
    }

    func test_stripHTML_noTags_returnsOriginal() {
        XCTAssertEqual(TextPreparation.stripHTML(from: "Hello world"), "Hello world")
    }

    // MARK: Whitespace normalisation

    func test_normalizeWhitespace_collapsesMultipleSpaces() {
        XCTAssertEqual(TextPreparation.normalizeWhitespace("Hello   World"), "Hello World")
    }

    func test_normalizeWhitespace_collapsesNewlines() {
        XCTAssertEqual(TextPreparation.normalizeWhitespace("Hello\n\nWorld\n"), "Hello World")
    }

    func test_normalizeWhitespace_collapsesTabs() {
        XCTAssertEqual(TextPreparation.normalizeWhitespace("Hello\t\tWorld"), "Hello World")
    }

    func test_normalizeWhitespace_trimsLeadingTrailing() {
        XCTAssertEqual(TextPreparation.normalizeWhitespace("  hello  "), "hello")
    }

    // MARK: Full clean pipeline

    func test_clean_truncatesLongText() {
        let long = String(repeating: "a", count: 3_000)
        XCTAssertLessThanOrEqual(TextPreparation.clean(long).count, TextPreparation.maxEmbedChars)
    }

    func test_clean_doesNotTruncateShortText() {
        let short = "Hello world"
        XCTAssertEqual(TextPreparation.clean(short), short)
    }

    func test_clean_stripsHTMLThenNormalizesWhitespace() {
        let input = "<b>Hello</b>  \n  <em>World</em>"
        let out = TextPreparation.clean(input)
        XCTAssertFalse(out.contains("<"))
        XCTAssertFalse(out.contains("  "))
        XCTAssertTrue(out.contains("Hello"))
        XCTAssertTrue(out.contains("World"))
    }

    // MARK: Prefixes

    func test_prepareForStorage_addsDocumentPrefix() {
        XCTAssertTrue(TextPreparation.prepareForStorage("Test").hasPrefix("search_document: "))
    }

    func test_prepareForQuery_addsQueryPrefix() {
        XCTAssertTrue(TextPreparation.prepareForQuery("Test").hasPrefix("search_query: "))
    }

    func test_prefixDifference_storageVsQuery() {
        let text = "Same text"
        let stored  = TextPreparation.prepareForStorage(text)
        let queried = TextPreparation.prepareForQuery(text)
        XCTAssertNotEqual(stored, queried)
        XCTAssertTrue(stored.hasPrefix("search_document: "))
        XCTAssertTrue(queried.hasPrefix("search_query: "))
    }

    // MARK: Email preparation

    func test_prepareEmail_combinesSubjectAndBody() {
        let out = TextPreparation.prepareEmail(subject: "Q2 Review", body: "Report is attached.")
        XCTAssertTrue(out.contains("Q2 Review"))
        XCTAssertTrue(out.contains("Report is attached"))
    }

    func test_prepareEmail_truncatesBodyTo500Chars() {
        let longBody = String(repeating: "x", count: 1_000)
        let out = TextPreparation.prepareEmail(subject: "S", body: longBody)
        let xCount = out.filter { $0 == "x" }.count
        XCTAssertLessThanOrEqual(xCount, 500)
    }

    func test_prepareEmail_noSubject_usesBodyOnly() {
        let out = TextPreparation.prepareEmail(subject: nil, body: "Just the body.")
        XCTAssertTrue(out.contains("Just the body"))
        XCTAssertFalse(out.contains("Subject:"))
    }

    func test_prepareEmail_addsDocumentPrefix() {
        let out = TextPreparation.prepareEmail(subject: "S", body: "B")
        XCTAssertTrue(out.hasPrefix("search_document: "))
    }

    // MARK: Promise preparation

    func test_preparePromise_addsDocumentPrefix() {
        let out = TextPreparation.preparePromise("Send proposal by Friday")
        XCTAssertTrue(out.hasPrefix("search_document: "))
        XCTAssertTrue(out.contains("Send proposal by Friday"))
    }

    // MARK: Transcript chunking

    func test_chunkForStorage_emptyText_returnsEmpty() {
        XCTAssertEqual(TextPreparation.chunkForStorage("").count, 0)
    }

    func test_chunkForStorage_whitespaceOnly_returnsEmpty() {
        XCTAssertEqual(TextPreparation.chunkForStorage("   \n\t  ").count, 0)
    }

    func test_chunkForStorage_shortText_returnsSingleChunk() {
        let short = String(repeating: "ab ", count: 50)
        let chunks = TextPreparation.chunkForStorage(short)
        XCTAssertEqual(chunks.count, 1)
    }

    func test_chunkForStorage_longText_returnsMultipleChunks() {
        let long = String(repeating: "word ", count: 1_000)   // ≈ 5 000 chars
        let chunks = TextPreparation.chunkForStorage(long)
        XCTAssertGreaterThan(chunks.count, 1)
    }

    func test_chunkForStorage_allChunksHaveDocumentPrefix() {
        let long = String(repeating: "word ", count: 1_000)
        for chunk in TextPreparation.chunkForStorage(long) {
            XCTAssertTrue(chunk.hasPrefix("search_document: "),
                          "Chunk missing prefix: \(chunk.prefix(40))")
        }
    }

    func test_chunkForStorage_hasOverlapBetweenConsecutiveChunks() {
        // 12 000 chars → multiple chunks; the last words of chunk N appear in chunk N+1
        let long = String(repeating: "alpha beta gamma delta epsilon ", count: 400)
        let raw = TextPreparation.rawChunks(long)
        guard raw.count >= 2 else {
            XCTFail("Expected multiple chunks for long text")
            return
        }
        // Any word from the tail of chunk 0 should appear somewhere in chunk 1
        let tailWords = raw[0].components(separatedBy: " ").suffix(30)
        let chunk1     = raw[1]
        let hasOverlap = tailWords.contains { !$0.isEmpty && chunk1.contains($0) }
        XCTAssertTrue(hasOverlap, "Expected word overlap between chunks 0 and 1")
    }

    func test_rawChunks_chunkCountMatchesExpected() {
        // 6 000 chars with stride 1 800 → ceil((6000 - 200) / 1800) + 1 ≈ 4 chunks
        let text = String(repeating: "ab ", count: 2_000)  // ≈ 6 000 chars
        let chunks = TextPreparation.rawChunks(text)
        // Exact count varies with word-boundary snapping; just assert range
        XCTAssertGreaterThanOrEqual(chunks.count, 2)
        XCTAssertLessThanOrEqual(chunks.count, 6)
    }
}

// MARK: - EmbeddingServiceTests

final class EmbeddingServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockOllamaURLProtocol.reset()
    }

    override func tearDown() {
        MockOllamaURLProtocol.reset()
        super.tearDown()
    }

    // MARK: embedQuery

    func test_embedQuery_prependsQueryPrefix() async throws {
        nonisolated(unsafe) var capturedPrompt = ""
        MockOllamaURLProtocol.register(path: "api/embeddings") { request in
            if let body = try? JSONSerialization.jsonObject(
                with: request.httpBody ?? Data()
            ) as? [String: Any] {
                capturedPrompt = (body["prompt"] as? String) ?? ""
            }
            return (200, makeSingleEmbedResponse())
        }

        let storage = MockEmbeddingStorage()
        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)
        _ = try await service.embedQuery("meeting with Acme")

        XCTAssertTrue(capturedPrompt.hasPrefix("search_query: "),
                      "Expected query prefix, got: \(capturedPrompt)")
        XCTAssertTrue(capturedPrompt.contains("meeting with Acme"))
    }

    func test_embedQuery_returnsVector() async throws {
        MockOllamaURLProtocol.register(path: "api/embeddings") { _ in
            (200, makeSingleEmbedResponse(dims: 768))
        }
        let storage = MockEmbeddingStorage()
        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)
        let vector  = try await service.embedQuery("any query")
        XCTAssertEqual(vector.count, 768)
    }

    // MARK: embedInteractions

    func test_embedInteractions_storesVectorForEachInteraction() async throws {
        registerEmbedMocks()
        let storage = MockEmbeddingStorage()
        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)

        try await service.embedInteractions([
            Interaction(id: "i1", source: .email, interactionType: .emailReceived,
                        summary: "Q2 budget discussion"),
            Interaction(id: "i2", source: .audio, interactionType: .meeting,
                        summary: "Kickoff meeting notes"),
        ])

        let count = await storage.interactionEmbeddingCount()
        XCTAssertEqual(count, 2)

        let ids = await storage.interactionEmbeddings.map(\.id)
        XCTAssertTrue(ids.contains("i1"))
        XCTAssertTrue(ids.contains("i2"))
    }

    func test_embedInteractions_skipsMissingSummary() async throws {
        registerEmbedMocks()
        let storage = MockEmbeddingStorage()
        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)

        try await service.embedInteractions([
            Interaction(id: "i1", source: .email, interactionType: .emailReceived, summary: nil),
            Interaction(id: "i2", source: .audio, interactionType: .meeting, summary: "Has summary"),
        ])

        let count = await storage.interactionEmbeddingCount()
        XCTAssertEqual(count, 1)
        let id = await storage.interactionEmbeddings.first?.id
        XCTAssertEqual(id, "i2")
    }

    func test_embedInteractions_skipsEmptySummary() async throws {
        registerEmbedMocks()
        let storage = MockEmbeddingStorage()
        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)

        try await service.embedInteractions([
            Interaction(id: "x", source: .email, interactionType: .emailReceived, summary: ""),
        ])

        let count = await storage.interactionEmbeddingCount()
        XCTAssertEqual(count, 0)
    }

    func test_embedInteractions_prependsDocumentPrefix() async throws {
        // Capture the texts sent to Ollama and verify the prefix.
        final class Capture: @unchecked Sendable { var texts: [String] = [] }
        let capture = Capture()

        MockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }
        MockOllamaURLProtocol.register(path: "api/embed") { request in
            if let body = try? JSONSerialization.jsonObject(
                with: request.httpBody ?? Data()
            ) as? [String: Any],
               let texts = body["input"] as? [String] {
                capture.texts = texts
            }
            return (200, makeEmbedBatchResponse(count: 1))
        }

        let storage = MockEmbeddingStorage()
        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)
        try await service.embedInteractions([
            Interaction(id: "i1", source: .email, interactionType: .emailReceived,
                        summary: "Budget talk"),
        ])

        XCTAssertFalse(capture.texts.isEmpty)
        XCTAssertTrue(capture.texts[0].hasPrefix("search_document: "),
                      "Text sent to Ollama: \(capture.texts[0])")
    }

    func test_embedInteractions_batchesIntoGroupsOf20() async throws {
        // 25 interactions → should send 2 requests: batch of 20 + batch of 5.
        final class Capture: @unchecked Sendable { var batchSizes: [Int] = [] }
        let capture = Capture()

        MockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }
        MockOllamaURLProtocol.register(path: "api/embed") { request in
            let bodyAny = (try? JSONSerialization.jsonObject(
                with: request.httpBody ?? Data()
            ) as? [String: Any]) ?? [:]
            let count = (bodyAny["input"] as? [String])?.count ?? 0
            capture.batchSizes.append(count)
            return (200, makeEmbedBatchResponse(count: count))
        }

        let storage = MockEmbeddingStorage()
        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)
        let interactions = (0..<25).map {
            Interaction(id: "i\($0)", source: .email, interactionType: .emailReceived,
                        summary: "Summary \($0)")
        }
        try await service.embedInteractions(interactions)

        XCTAssertEqual(capture.batchSizes.sorted(), [5, 20])
    }

    func test_embedInteractions_noOllamaCallWhenAllNil() async throws {
        final class Capture: @unchecked Sendable { var called = false }
        let capture = Capture()

        MockOllamaURLProtocol.register(path: "api/embed") { _ in
            capture.called = true
            return (200, makeEmbedBatchResponse(count: 1))
        }

        let storage = MockEmbeddingStorage()
        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)
        try await service.embedInteractions([
            Interaction(id: "x", source: .email, interactionType: .emailReceived, summary: nil),
        ])

        XCTAssertFalse(capture.called)
    }

    func test_embedInteractions_updatesMetrics() async throws {
        registerEmbedMocks()
        let storage = MockEmbeddingStorage()
        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)

        try await service.embedInteractions([
            Interaction(id: "m1", source: .audio, interactionType: .meeting,
                        summary: "Test summary"),
        ])

        let m = await service.currentMetrics
        XCTAssertGreaterThan(m.totalEmbedded, 0)
        XCTAssertGreaterThan(m.lastCycleThroughput, 0)
    }

    func test_embedInteractions_metricsAccumulate() async throws {
        registerEmbedMocks()
        let storage = MockEmbeddingStorage()
        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)

        try await service.embedInteractions([
            Interaction(id: "a", source: .email, interactionType: .emailReceived, summary: "First"),
        ])
        try await service.embedInteractions([
            Interaction(id: "b", source: .email, interactionType: .emailReceived, summary: "Second"),
        ])

        let m = await service.currentMetrics
        XCTAssertEqual(m.totalEmbedded, 2)
    }

    // MARK: Incremental cycle — interactions

    func test_incrementalCycle_picksUpUnembeddedInteractions() async throws {
        registerEmbedMocks()
        let storage = MockEmbeddingStorage()
        await storage.seed(interactions: [
            Interaction(id: "u1", source: .email, interactionType: .emailReceived, summary: "Unembedded A"),
            Interaction(id: "u2", source: .email, interactionType: .emailReceived, summary: "Unembedded B"),
        ])

        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)
        await service.runIncrementalCycle()

        let count = await storage.interactionEmbeddingCount()
        XCTAssertEqual(count, 2)
    }

    func test_incrementalCycle_skipsWhenOllamaUnavailable() async throws {
        MockOllamaURLProtocol.register(path: "api/tags") { _ in (503, Data()) }

        final class Capture: @unchecked Sendable { var called = false }
        let capture = Capture()
        MockOllamaURLProtocol.register(path: "api/embed") { _ in
            capture.called = true
            return (200, Data())
        }

        let storage = MockEmbeddingStorage()
        await storage.seed(interactions: [
            Interaction(id: "x", source: .email, interactionType: .emailReceived, summary: "Test"),
        ])

        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)
        await service.runIncrementalCycle()

        XCTAssertFalse(capture.called, "Embed should not be called when Ollama is down")
        let count = await storage.interactionEmbeddingCount()
        XCTAssertEqual(count, 0)
    }

    // MARK: Incremental cycle — promises

    func test_incrementalCycle_embedsPromises() async throws {
        registerEmbedMocks()
        let storage = MockEmbeddingStorage()
        await storage.seed(promises: [
            Promise(id: "p1", direction: .userPromised, description: "Send proposal by Friday"),
            Promise(id: "p2", direction: .contactPromised, description: "Review mockups by Monday"),
        ])

        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)
        await service.runIncrementalCycle()

        let promiseCount = await storage.promiseEmbeddingCount()
        XCTAssertEqual(promiseCount, 2)
        let ids = await storage.promiseEmbeddings.map(\.id)
        XCTAssertTrue(ids.contains("p1"))
        XCTAssertTrue(ids.contains("p2"))
    }

    // MARK: Incremental cycle — raw events

    func test_incrementalCycle_embedsManualNote() async throws {
        registerEmbedMocks()
        let storage = MockEmbeddingStorage()
        await storage.seed(rawEvents: [
            RawEvent(id: "note1", source: .manualNote,
                     rawText: "Client prefers Slack for async communication"),
        ])

        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)
        await service.runIncrementalCycle()

        let rawCount1 = await storage.rawEventEmbeddingCount()
        XCTAssertEqual(rawCount1, 1)
        let entry = await storage.rawEventEmbeddings.first
        XCTAssertEqual(entry?.id, "note1")
        XCTAssertEqual(entry?.chunk, 0)
    }

    func test_incrementalCycle_embedsEmail() async throws {
        registerEmbedMocks()
        let storage = MockEmbeddingStorage()
        let meta = #"{"subject":"Q2 budget review","from":"jane@acme.com"}"#
        await storage.seed(rawEvents: [
            RawEvent(id: "email1", source: .email,
                     rawText: "Please find the budget attached.",
                     metadataJSON: meta),
        ])

        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)
        await service.runIncrementalCycle()

        let rawCount2 = await storage.rawEventEmbeddingCount()
        XCTAssertEqual(rawCount2, 1)
        let firstEmailEntry = await storage.rawEventEmbeddings.first?.id
        XCTAssertEqual(firstEmailEntry, "email1")
    }

    func test_incrementalCycle_chunksLongAudioTranscript() async throws {
        registerEmbedMocks { n in makeEmbedBatchResponse(count: n) }
        let storage = MockEmbeddingStorage()
        // ≈ 6 000 chars → TextPreparation.chunkForStorage produces multiple chunks
        let transcript = String(repeating: "word ", count: 1_200)
        await storage.seed(rawEvents: [
            RawEvent(id: "audio1", source: .audio, rawText: transcript),
        ])

        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)
        await service.runIncrementalCycle()

        let entries = await storage.rawEventEmbeddings
        XCTAssertGreaterThanOrEqual(entries.count, 2,
                                    "Long transcript must produce multiple chunks")
        XCTAssertTrue(entries.allSatisfy { $0.id == "audio1" })
        XCTAssertTrue(Set(entries.map(\.chunk)).contains(0))
    }

    func test_incrementalCycle_skipsEmptyManualNote() async throws {
        registerEmbedMocks()
        let storage = MockEmbeddingStorage()
        await storage.seed(rawEvents: [
            RawEvent(id: "empty1", source: .manualNote, rawText: ""),
        ])

        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)
        await service.runIncrementalCycle()

        let rawCount3 = await storage.rawEventEmbeddingCount()
        XCTAssertEqual(rawCount3, 0)
    }

    // MARK: Incremental cycle — last cycle timestamp

    func test_incrementalCycle_updatesLastCycleAt() async throws {
        registerEmbedMocks()
        let storage = MockEmbeddingStorage()

        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)
        let metricsBefore = await service.currentMetrics
        XCTAssertNil(metricsBefore.lastCycleAt)

        await service.runIncrementalCycle()

        let metricsAfter = await service.currentMetrics
        XCTAssertNotNil(metricsAfter.lastCycleAt)
    }

    // MARK: Lifecycle

    func test_start_doesNotRunCycleImmediately() async throws {
        // start() queues a task that sleeps 5 minutes before the first cycle.
        // Within a short window, no embedding should occur.
        final class Capture: @unchecked Sendable { var called = false }
        let capture = Capture()
        MockOllamaURLProtocol.register(path: "api/tags") { _ in
            (200, Data(#"{"models":[]}"#.utf8))
        }
        MockOllamaURLProtocol.register(path: "api/embed") { _ in
            capture.called = true
            return (200, makeEmbedBatchResponse(count: 1))
        }

        let storage = MockEmbeddingStorage()
        await storage.seed(interactions: [
            Interaction(id: "s1", source: .email, interactionType: .emailReceived, summary: "Test"),
        ])

        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)
        await service.start()

        try await Task.sleep(for: .milliseconds(50))
        await service.shutdown()

        XCTAssertFalse(capture.called, "start() must not trigger an immediate cycle")
    }

    func test_start_isIdempotent() async {
        registerEmbedMocks()
        let storage = MockEmbeddingStorage()
        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)
        await service.start()
        await service.start()   // second call is a no-op
        await service.shutdown()
    }

    func test_shutdown_noLongerRunsCycles() async throws {
        registerEmbedMocks()
        let storage = MockEmbeddingStorage()
        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)
        await service.start()
        await service.shutdown()
        // After shutdown, start() should be a no-op (isStopped = true)
        await service.start()
        let m = await service.currentMetrics
        XCTAssertNil(m.lastCycleAt) // no cycle ran
    }

    // MARK: Initial metrics state

    func test_metrics_initiallyZero() async {
        let storage = MockEmbeddingStorage()
        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)
        let m = await service.currentMetrics
        XCTAssertEqual(m.totalEmbedded, 0)
        XCTAssertNil(m.lastCycleAt)
        XCTAssertEqual(m.lastCycleThroughput, 0.0, accuracy: 0.001)
        XCTAssertEqual(m.pendingInteractionCount, 0)
    }

    // MARK: Vector content

    func test_storedVector_matchesMockResponse() async throws {
        // The mock returns [0.0, 0.1, 0.2] — verify the stored vector matches.
        registerEmbedMocks()
        let storage = MockEmbeddingStorage()
        let service = EmbeddingService(client: makeOllamaClient(), storage: storage)
        try await service.embedInteractions([
            Interaction(id: "v1", source: .email, interactionType: .emailReceived,
                        summary: "Vector test"),
        ])

        let stored = await storage.interactionEmbeddings.first?.vector ?? []
        XCTAssertEqual(stored.count, 3)
        XCTAssertEqual(stored[0], 0.0, accuracy: 0.001)
        XCTAssertEqual(stored[1], 0.1, accuracy: 0.001)
        XCTAssertEqual(stored[2], 0.2, accuracy: 0.001)
    }
}
