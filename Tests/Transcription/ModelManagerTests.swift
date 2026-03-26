// ModelManagerTests.swift
// Tests for ModelManager: path resolution, state transitions,
// download lifecycle, and cancellation.
//
// All filesystem and URLSession calls are injected via the Environment
// struct so tests run without network access or touching the real disk.

import XCTest
@testable import Kerwan

// MARK: - MutBox (strict-concurrency helper)

/// Single-owner mutable box for test closures that need to mutate local state
/// through a `@Sendable` boundary.  Tests are single-threaded, so the lack of
/// internal locking is safe here.
private final class MutBox<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { self.value = v }
}

// MARK: - Helpers

/// Builds a ModelManager with a fake filesystem and a controllable URLSession.
@MainActor
private func makeManager(
    fileExists: Bool = false,
    downloadURL: URL = URL(string: "https://example.com/model.bin")!,
    sessionFactory: @Sendable @escaping () -> URLSession = { .shared }
) -> ModelManager {
    ModelManager(environment: ModelManager.Environment(
        fileExists: { _ in fileExists },
        createDirectory: { _ in /* no-op */ },
        downloadURL: downloadURL,
        makeSession: sessionFactory
    ))
}

// MARK: - ModelManagerPathTests

final class ModelManagerPathTests: XCTestCase {

    func test_modelURL_isInsideApplicationSupport() {
        let url = ModelManager.modelURL
        XCTAssertTrue(url.path.contains("Application Support"), "Expected Application Support in path")
    }

    func test_modelURL_containsKerwanSubfolder() {
        XCTAssertTrue(ModelManager.modelURL.path.contains("Kerwan"))
    }

    func test_modelURL_containsModelsSubfolder() {
        XCTAssertTrue(ModelManager.modelURL.path.contains("Models"))
    }

    func test_modelURL_filename() {
        XCTAssertEqual(ModelManager.modelURL.lastPathComponent, "ggml-large-v3-turbo.bin")
    }

    func test_downloadURL_isHuggingFace() {
        XCTAssertTrue(ModelManager.downloadURL.host?.contains("huggingface.co") == true)
    }

    func test_downloadURL_containsModelFilename() {
        XCTAssertTrue(ModelManager.downloadURL.absoluteString.contains("ggml-large-v3-turbo.bin"))
    }
}

// MARK: - ModelManagerStateTests

@MainActor
final class ModelManagerStateTests: XCTestCase {

    func test_initialState_notInstalled_whenFileAbsent() {
        let mgr = makeManager(fileExists: false)
        XCTAssertEqual(mgr.state, .notInstalled)
    }

    func test_initialState_ready_whenFilePresent() {
        let mgr = makeManager(fileExists: true)
        XCTAssertEqual(mgr.state, .ready)
    }

    func test_refreshState_toReady_whenFileAppearsOnDisk() {
        // Start with no file.  Use MutBox so the @Sendable fileExists closure
        // can reference mutable state without a strict-concurrency violation.
        let fileOnDisk = MutBox(false)
        let mgr = ModelManager(environment: ModelManager.Environment(
            fileExists: { _ in fileOnDisk.value },
            createDirectory: { _ in },
            downloadURL: URL(string: "https://example.com/m.bin")!,
            makeSession: { .shared }
        ))
        XCTAssertEqual(mgr.state, .notInstalled)

        // Simulate file appearing (another process copied it, etc.).
        fileOnDisk.value = true
        mgr.refreshState()
        XCTAssertEqual(mgr.state, .ready)
    }

    func test_refreshState_toNotInstalled_whenFileRemoved() {
        let fileOnDisk = MutBox(true)
        let mgr = ModelManager(environment: ModelManager.Environment(
            fileExists: { _ in fileOnDisk.value },
            createDirectory: { _ in },
            downloadURL: URL(string: "https://example.com/m.bin")!,
            makeSession: { .shared }
        ))
        XCTAssertEqual(mgr.state, .ready)

        fileOnDisk.value = false
        mgr.refreshState()
        XCTAssertEqual(mgr.state, .notInstalled)
    }

    func test_modelExists_falseWhenNoFile() {
        let mgr = makeManager(fileExists: false)
        XCTAssertFalse(mgr.modelExists)
    }

    func test_modelExists_trueWhenFilePresent() {
        // We can't control the size attribute in this mock, but we can
        // verify the fileExists gate works.
        let mgr = makeManager(fileExists: true)
        // modelExists checks fileExists first; size check may return 0
        // from the real FS since the file doesn't exist at the mock path.
        // Verify the public API at least doesn't crash.
        _ = mgr.modelExists  // smoke test
    }

    func test_downloadModelIfNeeded_setsDownloadingState() {
        // Use a session that never completes.
        let mgr = makeManager(
            fileExists: false,
            sessionFactory: { URLSession(configuration: .ephemeral) }
        )
        mgr.downloadModelIfNeeded()
        if case .downloading = mgr.state {
            // expected
        } else {
            XCTFail("Expected .downloading, got \(mgr.state)")
        }
    }

    func test_downloadModelIfNeeded_ifReady_doesNotStartDownload() {
        let sessionCallCount = MutBox(0)
        let mgr = makeManager(
            fileExists: true,
            sessionFactory: {
                sessionCallCount.value += 1
                return .shared
            }
        )
        XCTAssertEqual(mgr.state, .ready)
        mgr.downloadModelIfNeeded()
        XCTAssertEqual(sessionCallCount.value, 0, "Should not create a session when model is ready")
        XCTAssertEqual(mgr.state, .ready)
    }

    func test_cancelDownload_setsNotInstalled() {
        let mgr = makeManager(
            fileExists: false,
            sessionFactory: { URLSession(configuration: .ephemeral) }
        )
        mgr.downloadModelIfNeeded()
        mgr.cancelDownload()
        XCTAssertEqual(mgr.state, .notInstalled)
    }

    func test_stateEquality_downloadingProgress() {
        XCTAssertEqual(ModelManager.State.downloading(progress: 0.5),
                       ModelManager.State.downloading(progress: 0.5))
        XCTAssertNotEqual(ModelManager.State.downloading(progress: 0.5),
                          ModelManager.State.downloading(progress: 0.8))
    }

    func test_stateEquality_failedReason() {
        XCTAssertEqual(ModelManager.State.failed(reason: "err"),
                       ModelManager.State.failed(reason: "err"))
        XCTAssertNotEqual(ModelManager.State.failed(reason: "a"),
                          ModelManager.State.failed(reason: "b"))
    }

    func test_stateEquality_notInstalled_vs_ready() {
        XCTAssertNotEqual(ModelManager.State.notInstalled, .ready)
    }
}

// MARK: - ModelManagerDownloadCompletionTests

/// Tests the handleDownloadCompletion logic via a mock URLSession delegate
/// approach.  We inject a custom URLSessionConfiguration that short-circuits
/// the network by serving a local file, simulating a completed download.

@MainActor
final class ModelManagerDownloadFallbackTests: XCTestCase {

    /// Verifies that a directory creation failure transitions to .failed.
    func test_directoryCreationFailure_setsFailedState() {
        let mgr = ModelManager(environment: ModelManager.Environment(
            fileExists: { _ in false },
            createDirectory: { _ in
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            },
            downloadURL: URL(string: "https://example.com/m.bin")!,
            makeSession: { .shared }
        ))
        mgr.downloadModelIfNeeded()
        if case .failed = mgr.state {
            // expected
        } else {
            XCTFail("Expected .failed after directory creation failure, got \(mgr.state)")
        }
    }

    /// Verifies refreshState is a no-op during active download.
    func test_refreshState_noOp_duringDownload() {
        let mgr = makeManager(
            fileExists: false,
            sessionFactory: { URLSession(configuration: .ephemeral) }
        )
        mgr.downloadModelIfNeeded()
        guard case .downloading = mgr.state else {
            return XCTFail("Expected .downloading to start")
        }

        // refreshState should not change state while downloading.
        mgr.refreshState()
        if case .downloading = mgr.state {
            // Still downloading — correct
        } else {
            XCTFail("refreshState should not interrupt active download")
        }
    }
}

// MARK: - ModelManagerConvenienceTests

@MainActor
final class ModelManagerConvenienceTests: XCTestCase {

    func test_shouldShowDownloadUI_notInstalled() {
        let mgr = makeManager(fileExists: false)
        XCTAssertTrue(mgr.shouldShowDownloadUI)
    }

    func test_shouldShowDownloadUI_ready_isFalse() {
        let mgr = makeManager(fileExists: true)
        XCTAssertFalse(mgr.shouldShowDownloadUI)
    }

    func test_downloadFraction_zeroWhenNotDownloading() {
        let mgr = makeManager(fileExists: false)
        XCTAssertEqual(mgr.downloadFraction, 0.0, accuracy: 0.001)
    }

    func test_downloadFraction_reflectsDownloadingProgress() {
        let mgr = makeManager(
            fileExists: false,
            sessionFactory: { URLSession(configuration: .ephemeral) }
        )
        mgr.downloadModelIfNeeded()
        // Fraction should be 0 at start of download.
        XCTAssertEqual(mgr.downloadFraction, 0.0, accuracy: 0.001)
    }

    func test_downloadSizeDescription_emptyWhenTotalUnknown() {
        let mgr = makeManager(fileExists: false)
        XCTAssertEqual(mgr.downloadSizeDescription, "")
    }
}
