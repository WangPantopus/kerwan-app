import XCTest
@testable import KerwanXPCProtocol

final class TranscriptSegmentTests: XCTestCase {

    // MARK: - Initialization

    func testInitializationStoresValues() {
        let segment = TranscriptSegment(
            text: "Hello world",
            startTime: 1.5,
            endTime: 3.0,
            language: "en",
            confidence: 0.95
        )

        XCTAssertEqual(segment.text, "Hello world")
        XCTAssertEqual(segment.startTime, 1.5)
        XCTAssertEqual(segment.endTime, 3.0)
        XCTAssertEqual(segment.language, "en")
        XCTAssertEqual(segment.confidence, 0.95, accuracy: 0.001)
    }

    func testConfidenceClampedToUpperBound() {
        let segment = TranscriptSegment(
            text: "test",
            startTime: 0,
            endTime: 1,
            language: "en",
            confidence: 1.5
        )
        XCTAssertEqual(segment.confidence, 1.0, accuracy: 0.001)
    }

    func testConfidenceClampedToLowerBound() {
        let segment = TranscriptSegment(
            text: "test",
            startTime: 0,
            endTime: 1,
            language: "en",
            confidence: -0.5
        )
        XCTAssertEqual(segment.confidence, 0.0, accuracy: 0.001)
    }

    // MARK: - Computed Properties

    func testDurationCalculation() {
        let segment = TranscriptSegment(
            text: "test",
            startTime: 2.0,
            endTime: 5.5,
            language: "en",
            confidence: 0.9
        )
        XCTAssertEqual(segment.duration, 3.5, accuracy: 0.001)
    }

    func testIdIsDeterministic() {
        let segment1 = TranscriptSegment(
            text: "same text",
            startTime: 1.0,
            endTime: 2.0,
            language: "en",
            confidence: 0.8
        )
        let segment2 = TranscriptSegment(
            text: "same text",
            startTime: 1.0,
            endTime: 2.0,
            language: "en",
            confidence: 0.8
        )
        XCTAssertEqual(segment1.id, segment2.id)
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let original = TranscriptSegment(
            text: "Bonjour le monde",
            startTime: 10.0,
            endTime: 12.5,
            language: "fr",
            confidence: 0.87
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: data)

        XCTAssertEqual(decoded.text, original.text)
        XCTAssertEqual(decoded.startTime, original.startTime)
        XCTAssertEqual(decoded.endTime, original.endTime)
        XCTAssertEqual(decoded.language, original.language)
        XCTAssertEqual(decoded.confidence, original.confidence, accuracy: 0.001)
    }

    func testCodableArrayRoundTrip() throws {
        let segments = [
            TranscriptSegment(text: "First", startTime: 0, endTime: 1, language: "en", confidence: 0.9),
            TranscriptSegment(text: "Second", startTime: 1, endTime: 2, language: "en", confidence: 0.85),
            TranscriptSegment(text: "Third", startTime: 2, endTime: 3, language: "en", confidence: 0.92),
        ]

        let data = try JSONEncoder().encode(segments)
        let decoded = try JSONDecoder().decode([TranscriptSegment].self, from: data)

        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0].text, "First")
        XCTAssertEqual(decoded[2].text, "Third")
    }

    // MARK: - Hashable / Equatable

    func testEqualSegmentsAreEqual() {
        let a = TranscriptSegment(text: "hello", startTime: 0, endTime: 1, language: "en", confidence: 0.9)
        let b = TranscriptSegment(text: "hello", startTime: 0, endTime: 1, language: "en", confidence: 0.9)
        XCTAssertEqual(a, b)
    }

    func testDifferentSegmentsAreNotEqual() {
        let a = TranscriptSegment(text: "hello", startTime: 0, endTime: 1, language: "en", confidence: 0.9)
        let b = TranscriptSegment(text: "world", startTime: 0, endTime: 1, language: "en", confidence: 0.9)
        XCTAssertNotEqual(a, b)
    }

    func testSegmentsCanBeUsedInSet() {
        let a = TranscriptSegment(text: "hello", startTime: 0, endTime: 1, language: "en", confidence: 0.9)
        let b = TranscriptSegment(text: "hello", startTime: 0, endTime: 1, language: "en", confidence: 0.9)
        let c = TranscriptSegment(text: "world", startTime: 1, endTime: 2, language: "en", confidence: 0.8)

        let set: Set<TranscriptSegment> = [a, b, c]
        XCTAssertEqual(set.count, 2)
    }
}
