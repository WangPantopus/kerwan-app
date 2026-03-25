import XCTest
@testable import KerwanXPCProtocol

final class WhisperServiceErrorTests: XCTestCase {

    func testModelNotFoundDescription() {
        let error = WhisperServiceError.modelNotFound(path: "/path/to/model.bin")
        XCTAssertTrue(error.localizedDescription.contains("/path/to/model.bin"))
    }

    func testModelLoadFailedDescription() {
        let error = WhisperServiceError.modelLoadFailed(reason: "corrupt header")
        XCTAssertTrue(error.localizedDescription.contains("corrupt header"))
    }

    func testModelNotLoadedDescription() {
        let error = WhisperServiceError.modelNotLoaded
        XCTAssertTrue(error.localizedDescription.contains("loadModel"))
    }

    func testInvalidAudioDataDescription() {
        let error = WhisperServiceError.invalidAudioData(reason: "empty buffer")
        XCTAssertTrue(error.localizedDescription.contains("empty buffer"))
    }

    func testUnsupportedSampleRateDescription() {
        let error = WhisperServiceError.unsupportedSampleRate(12345)
        XCTAssertTrue(error.localizedDescription.contains("12345"))
    }

    func testTranscriptionFailedDescription() {
        let error = WhisperServiceError.transcriptionFailed(reason: "timeout")
        XCTAssertTrue(error.localizedDescription.contains("timeout"))
    }

    func testConnectionLostDescription() {
        let error = WhisperServiceError.connectionLost
        XCTAssertFalse(error.localizedDescription.isEmpty)
    }
}
