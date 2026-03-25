import XCTest
import Foundation
import KerwanStorage

// MARK: - SQLiteWriteThroughputTests

/// Verifies that Kerwan's `StorageActor` meets its write-throughput budget across
/// multiple batch sizes, and that concurrent reads do not degrade write speed.
///
/// ## Budget
///   - **Sustained write throughput > 1 000 events/second** for all batch sizes.
///   - WAL-mode concurrent reads must not reduce write throughput below budget.
///
/// ## Method
///   - Raw events are batched and passed to `StorageActor.insertRawEvents(_:)`.
///   - Throughput = total events ÷ wall-clock elapsed seconds.
///   - Interaction-insert throughput is also measured for the classification path.
///   - `XCTClockMetric()` inside `measure{}` provides XCTest regression baselines.
///
/// ## Batch sizes tested
///   100, 500, 1 000 (three separate tests matching the requirement spec).
final class SQLiteWriteThroughputTests: XCTestCase {

    // MARK: - Temp DB helpers

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeStorage(suffix: String = "") throws -> StorageActor {
        let url = tempDir.appendingPathComponent("write\(suffix).db")
        return try StorageActor(passphrase: "write-test", databaseURL: url)
    }

    private func makeRawEventBatch(size: Int, offset: Int = 0) -> [KerwanStorage.RawEvent] {
        let sources: [KerwanStorage.RawEvent.Source] = [.windowFocus, .screenCapture, .emailCapture]
        return (0..<size).map { i in
            let idx = offset + i
            return KerwanStorage.RawEvent(
                id:          "evt-\(idx)",
                timestamp:   Date(timeIntervalSince1970: Double(idx)),
                source:      sources[idx % sources.count],
                sourceApp:   "App\(idx % 10)",
                windowTitle: "Window \(idx % 50)",
                duration:    30
            )
        }
    }

    private func makeInteractionBatch(size: Int, offset: Int = 0) -> [KerwanStorage.Interaction] {
        (0..<size).map { i in
            let idx = offset + i
            return KerwanStorage.Interaction(
                id:        "int-\(idx)",
                contactId: nil,
                type:      .meeting,
                subject:   "Meeting \(idx)",
                summary:   "Summary for interaction \(idx)",
                startedAt: Date(timeIntervalSince1970: Double(idx) * 3_600),
                source:    "audio"
            )
        }
    }

    /// Returns events-per-second for inserting `totalEvents` in batches of `batchSize`.
    private func measureRawEventThroughput(
        storage: StorageActor,
        batchSize: Int,
        totalEvents: Int
    ) async throws -> Double {
        var inserted = 0
        let t0 = Date()
        while inserted < totalEvents {
            let count = min(batchSize, totalEvents - inserted)
            let batch = makeRawEventBatch(size: count, offset: inserted)
            try await storage.insertRawEvents(batch)
            inserted += count
        }
        let elapsed = Date().timeIntervalSince(t0)
        return Double(totalEvents) / elapsed
    }

    // MARK: - Test 1: Batch size 100 — raw events

    func test_writeThroughput_rawEvents_batch100_over1000eps() async throws {
        let storage   = try makeStorage(suffix: "-b100")
        let totalEvents = 10_000   // 100 batches × 100

        let eps = try await measureRawEventThroughput(
            storage: storage, batchSize: 100, totalEvents: totalEvents)
        print("  ▸ batch=100  throughput: \(String(format: "%.0f", eps)) events/sec")

        XCTAssertGreaterThan(eps, 1_000.0,
            "Raw event write throughput (batch=100) must exceed 1 000 events/sec (measured: \(String(format: "%.0f", eps)))")
    }

    // MARK: - Test 2: Batch size 500 — raw events

    func test_writeThroughput_rawEvents_batch500_over1000eps() async throws {
        let storage     = try makeStorage(suffix: "-b500")
        let totalEvents = 10_000   // 20 batches × 500

        let eps = try await measureRawEventThroughput(
            storage: storage, batchSize: 500, totalEvents: totalEvents)
        print("  ▸ batch=500  throughput: \(String(format: "%.0f", eps)) events/sec")

        XCTAssertGreaterThan(eps, 1_000.0,
            "Raw event write throughput (batch=500) must exceed 1 000 events/sec (measured: \(String(format: "%.0f", eps)))")
    }

    // MARK: - Test 3: Batch size 1000 — raw events

    func test_writeThroughput_rawEvents_batch1000_over1000eps() async throws {
        let storage     = try makeStorage(suffix: "-b1000")
        let totalEvents = 10_000   // 10 batches × 1 000

        let eps = try await measureRawEventThroughput(
            storage: storage, batchSize: 1_000, totalEvents: totalEvents)
        print("  ▸ batch=1000 throughput: \(String(format: "%.0f", eps)) events/sec")

        XCTAssertGreaterThan(eps, 1_000.0,
            "Raw event write throughput (batch=1000) must exceed 1 000 events/sec (measured: \(String(format: "%.0f", eps)))")
    }

    // MARK: - Test 4: Interaction insert throughput (classification path)

    /// Interactions go through the FTS5 trigger path and are more expensive to insert
    /// than raw events. Still targets > 200 interactions/second for the classification pipeline.
    func test_writeThroughput_interactions_over200ips() async throws {
        let storage = try makeStorage(suffix: "-int")
        let total   = 2_000

        let t0 = Date()
        let batch = makeInteractionBatch(size: total)
        for interaction in batch {
            try await storage.insertInteraction(interaction, linkedEventIds: [])
        }
        let elapsed = Date().timeIntervalSince(t0)
        let ips = Double(total) / elapsed
        print("  ▸ interaction insert: \(String(format: "%.0f", ips)) interactions/sec")

        XCTAssertGreaterThan(ips, 200.0,
            "Interaction insert throughput must exceed 200/sec (measured: \(String(format: "%.0f", ips)))")
    }

    // MARK: - Test 5: Concurrent reads do not degrade write throughput below budget

    /// While inserting events, 4 concurrent reader tasks issue `searchKeyword` queries.
    /// Write throughput must still exceed 500 events/sec (WAL should allow parallelism).
    func test_writeThroughput_concurrentReads_writeStaysAbove500eps() async throws {
        let storage     = try makeStorage(suffix: "-concurrent")
        let totalEvents = 5_000
        let batchSize   = 500

        // Pre-populate so search has something to find.
        let seed = makeRawEventBatch(size: 100, offset: 100_000)
        try await storage.insertRawEvents(seed)
        let seedInteractions = makeInteractionBatch(size: 50, offset: 100_000)
        for i in seedInteractions { try await storage.insertInteraction(i, linkedEventIds: []) }

        // Kick off 4 background reader tasks.
        let readers = (0..<4).map { _ in
            Task {
                for _ in 0..<200 {
                    _ = await storage.searchKeyword(query: "meeting", limit: 10)
                }
            }
        }

        let eps = try await measureRawEventThroughput(
            storage: storage, batchSize: batchSize, totalEvents: totalEvents)

        // Cancel readers (they may still be running).
        readers.forEach { $0.cancel() }
        print("  ▸ concurrent-read write throughput: \(String(format: "%.0f", eps)) events/sec")

        XCTAssertGreaterThan(eps, 500.0,
            "Write throughput under concurrent reads must exceed 500 events/sec (measured: \(String(format: "%.0f", eps)))")
    }

    // MARK: - Test 6: XCTest measure — 500-event batch insert

    /// Provides an XCTest regression baseline in CI.
    func test_writeThroughput_measure_batch500Insert() async throws {
        let storage = try makeStorage(suffix: "-measure")

        measure(metrics: [XCTClockMetric()]) {
            let expectation = self.expectation(description: "insert")
            Task {
                let batch = self.makeRawEventBatch(size: 500)
                try? await storage.insertRawEvents(batch)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 10)
        }
    }
}
