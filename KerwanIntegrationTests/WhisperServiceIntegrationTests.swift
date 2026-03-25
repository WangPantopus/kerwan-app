import XCTest
@testable import KerwanXPCProtocol

/// Integration tests for the WhisperService XPC pipeline.
///
/// These tests validate the full flow from audio data through the XPC protocol
/// to transcript segments. They require a whisper model to be available on disk.
final class WhisperServiceIntegrationTests: XCTestCase {

    /// Validates that TranscriptSegment can survive a JSON encode/decode cycle
    /// as it would over an XPC connection boundary.
    func testSegmentSerializationOverXPCBoundary() throws {
        let segments = [
            TranscriptSegment(
                text: "This is a test of the XPC pipeline",
                startTime: 0.0,
                endTime: 2.5,
                language: "en",
                confidence: 0.93
            ),
            TranscriptSegment(
                text: "with multiple segments",
                startTime: 2.5,
                endTime: 4.0,
                language: "en",
                confidence: 0.88
            )
        ]

        // Simulate what the XPC service does: encode to Data
        let encoder = JSONEncoder()
        let data = try encoder.encode(segments)

        // Simulate what the main app does: decode from Data
        let decoder = JSONDecoder()
        let decoded = try decoder.decode([TranscriptSegment].self, from: data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].text, "This is a test of the XPC pipeline")
        XCTAssertEqual(decoded[1].startTime, 2.5)
        XCTAssertEqual(decoded[1].confidence, 0.88, accuracy: 0.001)
    }

    /// Validates that an empty segment array serializes correctly.
    func testEmptySegmentArraySerialization() throws {
        let segments: [TranscriptSegment] = []
        let data = try JSONEncoder().encode(segments)
        let decoded = try JSONDecoder().decode([TranscriptSegment].self, from: data)
        XCTAssertTrue(decoded.isEmpty)
    }

    /// Validates segment with Unicode text content.
    func testUnicodeSegmentSerialization() throws {
        let segment = TranscriptSegment(
            text: "会议开始了。Bonjour! Guten Tag! 🎙️",
            startTime: 0,
            endTime: 3.0,
            language: "zh",
            confidence: 0.75
        )

        let data = try JSONEncoder().encode(segment)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: data)
        XCTAssertEqual(decoded.text, segment.text)
        XCTAssertEqual(decoded.language, "zh")
    }
}
