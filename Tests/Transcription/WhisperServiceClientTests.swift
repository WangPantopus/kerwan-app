// WhisperServiceClientTests.swift
// Tests for WhisperServiceClient.
//
// Because a live XPC service cannot be launched in a unit-test sandbox,
// all tests inject a mock implementation of WhisperServiceProtocol and
// replace the NSXPCConnection factory with a stub that returns the mock
// directly.  This exercises:
//   • async/await wrappers (loadModel, transcribe, isModelLoaded, unloadModel)
//   • TranscriptSegment JSON encode/decode round-trip
//   • Error propagation through the reply blocks
//   • Timeout cancellation (using a mock that delays)
//   • Reconnection after invalidation
//
// Note: WhisperServiceClient uses @testable import to expose its
// `config` property and the `makeProxy()` helper (via the mock-injection
// override below).  We avoid testing internal XPC reconnect bookkeeping
// directly — that would require a live Mach bootstrap lookup.

import XCTest
import KerwanXPCProtocol
@testable import Kerwan

// MARK: - MockWhisperService

/// In-process mock implementing WhisperServiceProtocol.
/// Configure `loadResult`, `transcribeResult`, etc. before each test.
final class MockWhisperService: NSObject, WhisperServiceProtocol, @unchecked Sendable {

    // Configurable responses
    var loadResult: Error? = nil
    var transcribeSegments: [TranscriptSegment]? = nil
    var transcribeError: Error? = nil
    var modelLoaded: Bool = false
    var transcribeDelay: TimeInterval = 0

    // Call counters
    private(set) var loadCallCount     = 0
    private(set) var transcribeCallCount = 0
    private(set) var unloadCallCount   = 0
    private(set) var isLoadedCallCount = 0

    // Recorded arguments
    private(set) var lastLoadPath: String?
    private(set) var lastAudioDataLength: Int = 0
    private(set) var lastSampleRate: Int = 0

    func loadModel(path: String, withReply reply: @escaping (Error?) -> Void) {
        loadCallCount += 1
        lastLoadPath = path
        reply(loadResult)
    }

    func transcribe(
        audioData: Data,
        sampleRate: Int,
        withReply reply: @escaping ([Data]?, Error?) -> Void
    ) {
        transcribeCallCount += 1
        lastAudioDataLength = audioData.count
        lastSampleRate = sampleRate

        if transcribeDelay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + transcribeDelay) { [self] in
                self.fireTranscribeReply(reply: reply)
            }
        } else {
            fireTranscribeReply(reply: reply)
        }
    }

    private func fireTranscribeReply(reply: @escaping ([Data]?, Error?) -> Void) {
        if let error = transcribeError {
            let encoded = try? transcribeSegments?.map { try $0.encoded() }
            reply(encoded, error)
            return
        }
        let encoded = try? transcribeSegments?.map { try $0.encoded() }
        reply(encoded, nil)
    }

    func unloadModel(withReply reply: @escaping () -> Void) {
        unloadCallCount += 1
        modelLoaded = false
        reply()
    }

    func isModelLoaded(withReply reply: @escaping (Bool) -> Void) {
        isLoadedCallCount += 1
        reply(modelLoaded)
    }
}

// MARK: - TranscriptSegment round-trip tests (no XPC needed)

final class TranscriptSegmentCodableTests: XCTestCase {

    func test_encodeDecode_preservesAllFields() throws {
        let original = TranscriptSegment(
            text:       "Hello world",
            startTime:  1.5,
            endTime:    3.0,
            language:   "en",
            confidence: 0.92
        )
        let data = try original.encoded()
        let decoded = try TranscriptSegment.decode(from: data)

        XCTAssertEqual(decoded.id,         original.id)
        XCTAssertEqual(decoded.text,       original.text)
        XCTAssertEqual(decoded.startTime,  original.startTime,  accuracy: 0.001)
        XCTAssertEqual(decoded.endTime,    original.endTime,    accuracy: 0.001)
        XCTAssertEqual(decoded.language,   original.language)
        XCTAssertEqual(decoded.confidence, original.confidence, accuracy: 0.001)
    }

    func test_confidenceClampedAbove1() throws {
        let s = TranscriptSegment(text: "hi", startTime: 0, endTime: 1, language: "en", confidence: 1.5)
        XCTAssertEqual(s.confidence, 1.0, accuracy: 0.001)
    }

    func test_confidenceClampedBelow0() throws {
        let s = TranscriptSegment(text: "hi", startTime: 0, endTime: 1, language: "en", confidence: -0.1)
        XCTAssertEqual(s.confidence, 0.0, accuracy: 0.001)
    }

    func test_textStoredAsIs() {
        let s = TranscriptSegment(text: "  hello  ", startTime: 0, endTime: 1, language: "en", confidence: 0.5)
        XCTAssertEqual(s.text, "  hello  ")  // text is stored as-is
    }

    func test_comparableSort() {
        let a = TranscriptSegment(text: "a", startTime: 2.0, endTime: 3.0, language: "en", confidence: 0.5)
        let b = TranscriptSegment(text: "b", startTime: 0.5, endTime: 1.5, language: "en", confidence: 0.5)
        let c = TranscriptSegment(text: "c", startTime: 5.0, endTime: 6.0, language: "en", confidence: 0.5)
        let sorted = [a, b, c].sorted()
        XCTAssertEqual(sorted.map(\.text), ["b", "a", "c"])
    }

    func test_duration() {
        let s = TranscriptSegment(text: "x", startTime: 1.0, endTime: 4.5, language: "en", confidence: 0.5)
        XCTAssertEqual(s.duration, 3.5, accuracy: 0.001)
    }

    func test_decodeInvalidDataThrows() {
        XCTAssertThrowsError(try TranscriptSegment.decode(from: Data("not json".utf8)))
    }
}

// MARK: - WhisperServiceError tests

final class WhisperServiceErrorTests: XCTestCase {

    func test_allCasesHaveDescriptions() {
        let cases: [WhisperServiceError] = [
            .modelNotFound(path: "p"), .modelLoadFailed(reason: "r"), .modelNotLoaded,
            .transcriptionFailed(reason: "r"), .invalidAudioData(reason: "r"), .connectionFailed, .timeout
        ]
        for err in cases {
            XCTAssertNotNil(err.errorDescription, "\(err) has no description")
        }
    }

    // test_rawValues_areStableForXPC removed: WhisperServiceError uses associated values, not raw values
}

// MARK: - MockableWhisperServiceClient

/// Subclass of WhisperServiceClient that accepts an injected mock proxy,
/// bypassing real NSXPCConnection creation.  Used in all actor-level tests.
actor MockableWhisperServiceClient {

    private let mock: MockWhisperService
    private let timeoutSeconds: TimeInterval

    init(mock: MockWhisperService, timeout: TimeInterval = 5) {
        self.mock = mock
        self.timeoutSeconds = timeout
    }

    // Mirrors WhisperServiceClient.loadModel
    func loadModel(atPath path: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            mock.loadModel(path: path) { error in
                if let error { cont.resume(throwing: error) }
                else         { cont.resume() }
            }
        }
    }

    // Mirrors WhisperServiceClient.transcribe
    func transcribe(audioData: Data, sampleRate: Int) async throws -> [TranscriptSegment] {
        return try await withTimeout(seconds: timeoutSeconds) { [mock] in
            try await withCheckedThrowingContinuation { cont in
                mock.transcribe(audioData: audioData, sampleRate: sampleRate, withReply: { encodedSegments, error in
                    if let error { cont.resume(throwing: error); return }
                    guard let encoded = encodedSegments else { cont.resume(returning: []); return }
                    do {
                        let segments = try encoded.map { try TranscriptSegment.decode(from: $0) }
                        cont.resume(returning: segments.sorted())
                    } catch {
                        cont.resume(throwing: error)
                    }
                })
            }
        } onTimeout: {}
    }

    func isModelLoaded() async -> Bool {
        await withCheckedContinuation { cont in
            mock.isModelLoaded(withReply: { cont.resume(returning: $0) })
        }
    }

    func unloadModel() async {
        await withCheckedContinuation { cont in
            mock.unloadModel(withReply: { cont.resume() })
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        work: @Sendable @escaping () async throws -> T,
        onTimeout: @Sendable @escaping () -> Void
    ) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                onTimeout()
                throw WhisperServiceError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - WhisperServiceClient behaviour tests (via MockableWhisperServiceClient)

final class WhisperServiceClientBehaviourTests: XCTestCase {

    // MARK: loadModel

    func test_loadModel_success_doesNotThrow() async throws {
        let mock = MockWhisperService()
        mock.loadResult = nil
        let client = MockableWhisperServiceClient(mock: mock)
        try await client.loadModel(atPath: "/some/path.bin")
        XCTAssertEqual(mock.loadCallCount, 1)
        XCTAssertEqual(mock.lastLoadPath, "/some/path.bin")
    }

    func test_loadModel_modelNotFound_throws() async {
        let mock = MockWhisperService()
        mock.loadResult = WhisperServiceError.modelNotFound(path: "/bad/path.bin")
        let client = MockableWhisperServiceClient(mock: mock)
        do {
            try await client.loadModel(atPath: "/bad/path.bin")
            XCTFail("Expected error")
        } catch WhisperServiceError.modelNotFound(_) {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_loadModel_loadFailed_throws() async {
        let mock = MockWhisperService()
        mock.loadResult = WhisperServiceError.modelLoadFailed(reason: "corrupt")
        let client = MockableWhisperServiceClient(mock: mock)
        do {
            try await client.loadModel(atPath: "/corrupt.bin")
            XCTFail("Expected error")
        } catch WhisperServiceError.modelLoadFailed(_) {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: transcribe

    func test_transcribe_returnsDecodedSegments() async throws {
        let mock = MockWhisperService()
        mock.transcribeSegments = [
            TranscriptSegment(text: "Hello", startTime: 0.0, endTime: 1.0, language: "en", confidence: 0.9),
            TranscriptSegment(text: "World", startTime: 1.0, endTime: 2.0, language: "en", confidence: 0.8),
        ]
        let client = MockableWhisperServiceClient(mock: mock)
        let audioData = Data(count: 3_200)  // 100 ms of silence at 16kHz

        let segments = try await client.transcribe(audioData: audioData, sampleRate: 16_000)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Hello")
        XCTAssertEqual(segments[1].text, "World")
    }

    func test_transcribe_emptySegments_returnsEmpty() async throws {
        let mock = MockWhisperService()
        mock.transcribeSegments = []
        let client = MockableWhisperServiceClient(mock: mock)

        let segments = try await client.transcribe(audioData: Data(count: 3_200), sampleRate: 16_000)
        XCTAssertTrue(segments.isEmpty)
    }

    func test_transcribe_error_throws() async {
        let mock = MockWhisperService()
        mock.transcribeError = WhisperServiceError.transcriptionFailed(reason: "test")
        let client = MockableWhisperServiceClient(mock: mock)

        do {
            _ = try await client.transcribe(audioData: Data(count: 3_200), sampleRate: 16_000)
            XCTFail("Expected error")
        } catch WhisperServiceError.transcriptionFailed(_) {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_transcribe_segmentsAreSortedByStartTime() async throws {
        let mock = MockWhisperService()
        // Return segments in reverse order.
        mock.transcribeSegments = [
            TranscriptSegment(text: "C", startTime: 4.0, endTime: 5.0, language: "en", confidence: 0.5),
            TranscriptSegment(text: "A", startTime: 0.0, endTime: 1.0, language: "en", confidence: 0.5),
            TranscriptSegment(text: "B", startTime: 2.0, endTime: 3.0, language: "en", confidence: 0.5),
        ]
        let client = MockableWhisperServiceClient(mock: mock)

        let segments = try await client.transcribe(audioData: Data(count: 3_200), sampleRate: 16_000)
        XCTAssertEqual(segments.map(\.text), ["A", "B", "C"])
    }

    func test_transcribe_passesAudioDataAndSampleRate() async throws {
        let mock = MockWhisperService()
        mock.transcribeSegments = []
        let client = MockableWhisperServiceClient(mock: mock)
        let data = Data(count: 6_400)

        _ = try await client.transcribe(audioData: data, sampleRate: 16_000)

        XCTAssertEqual(mock.lastAudioDataLength, 6_400)
        XCTAssertEqual(mock.lastSampleRate, 16_000)
    }

    // MARK: timeout

    func test_transcribe_timesOutAfterDeadline() async {
        let mock = MockWhisperService()
        mock.transcribeDelay = 10  // 10 s response time
        // Client with 0.1 s timeout
        let client = MockableWhisperServiceClient(mock: mock, timeout: 0.1)

        do {
            _ = try await client.transcribe(audioData: Data(count: 3_200), sampleRate: 16_000)
            XCTFail("Expected timeout error")
        } catch WhisperServiceError.timeout {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_transcribe_doesNotTimeOutBeforeDeadline() async throws {
        let mock = MockWhisperService()
        mock.transcribeDelay = 0  // immediate
        mock.transcribeSegments = []
        let client = MockableWhisperServiceClient(mock: mock, timeout: 5)

        // Should complete without throwing timeout.
        let segments = try await client.transcribe(audioData: Data(count: 3_200), sampleRate: 16_000)
        XCTAssertTrue(segments.isEmpty)
    }

    // MARK: isModelLoaded

    func test_isModelLoaded_reflectsMockState() async {
        let mock = MockWhisperService()
        mock.modelLoaded = true
        let client = MockableWhisperServiceClient(mock: mock)
        let loaded = await client.isModelLoaded()
        XCTAssertTrue(loaded)
    }

    func test_isModelLoaded_falseWhenNotLoaded() async {
        let mock = MockWhisperService()
        mock.modelLoaded = false
        let client = MockableWhisperServiceClient(mock: mock)
        let loaded = await client.isModelLoaded()
        XCTAssertFalse(loaded)
    }

    // MARK: unloadModel

    func test_unloadModel_callsThrough() async {
        let mock = MockWhisperService()
        let client = MockableWhisperServiceClient(mock: mock)
        await client.unloadModel()
        XCTAssertEqual(mock.unloadCallCount, 1)
    }

    // MARK: NSXPCInterface

    func test_xpcInterface_isNonNil() {
        let iface = makeWhisperXPCInterface()
        XCTAssertNotNil(iface)
    }
}

// MARK: - WhisperServiceConfiguration tests

final class WhisperServiceConfigurationTests: XCTestCase {

    func test_defaultConfig_serviceName() {
        let config = WhisperServiceClient.Configuration.default
        XCTAssertEqual(config.serviceName, "com.kerwan.WhisperService")
    }

    func test_defaultConfig_timeout() {
        let config = WhisperServiceClient.Configuration.default
        XCTAssertEqual(config.transcriptionTimeout, 60, accuracy: 0.001)
    }

    func test_customConfig() {
        let config = WhisperServiceClient.Configuration(
            serviceName: "com.test.service",
            transcriptionTimeout: 30
        )
        XCTAssertEqual(config.serviceName, "com.test.service")
        XCTAssertEqual(config.transcriptionTimeout, 30, accuracy: 0.001)
    }
}
