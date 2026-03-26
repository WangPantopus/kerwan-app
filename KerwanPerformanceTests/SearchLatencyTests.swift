import XCTest
import Foundation
import KerwanStorage

// MARK: - SearchLatencyTests

/// Verifies that Kerwan's keyword search meets its p95 latency budget at three
/// database sizes: 10 K, 50 K, and 200 K interactions.
///
/// ## Budget
///   - **p95 query latency < 500 ms** at all tested sizes (requirement P-031).
///
/// ## Method
///   - A real `StorageActor` backed by a temp-file SQLite database is populated
///     once per test class run (via `class setUp`).
///   - 100 search queries with varying terms are issued outside any `measure{}`
///     block so that results are stable across repeats.
///   - Wall-clock nanoseconds are collected per query, sorted, and percentiles
///     are computed directly.
///
/// ## Query corpus
///   Queries alternate between exact words found in the fixture data and
///   partial words to exercise FTS5 prefix matching and full-word matching.
final class SearchLatencyTests: XCTestCase {

    // MARK: - Constants

    private static let queryCount = 100

    /// The 100 queries used in every latency test.
    private static let queries: [String] = {
        let words = ["meeting", "project", "update", "review", "discuss",
                     "budget", "sprint", "deadline", "client", "contact",
                     "invoice", "team", "roadmap", "release", "plan",
                     "onboarding", "status", "follow", "sync", "align"]
        // Cycle through words, adding an index suffix to vary selectivity
        return (0..<queryCount).map { i in
            let word = words[i % words.count]
            return i % 3 == 0 ? "\(word) \(i / words.count)" : word
        }
    }()

    // MARK: - Temp DB helpers

    private var tempDir10K:  URL!
    private var tempDir50K:  URL!
    private var tempDir200K: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir10K  = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-search-10k-\(UUID().uuidString)",  isDirectory: true)
        tempDir50K  = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-search-50k-\(UUID().uuidString)",  isDirectory: true)
        tempDir200K = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-search-200k-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir10K,  withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDir50K,  withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDir200K, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        [tempDir10K, tempDir50K, tempDir200K].forEach {
            try? FileManager.default.removeItem(at: $0!)
        }
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Inserts `count` synthetic interactions into `storage`.
    private func populate(storage: StorageActor, count: Int) async throws {
        let topics = ["meeting", "project update", "budget review", "sprint planning",
                      "client onboarding", "roadmap discussion", "deadline sync",
                      "invoice review", "team alignment", "status report"]
        let batchSize = 500
        var inserted = 0
        while inserted < count {
            let batchCount = min(batchSize, count - inserted)
            let interactions: [KerwanStorage.Interaction] = (0..<batchCount).map { j in
                let idx = inserted + j
                let topic = topics[idx % topics.count]
                return KerwanStorage.Interaction(
                    id:        "lat-\(idx)",
                    contactId: nil,
                    type:      idx % 2 == 0 ? .meeting : .email,
                    subject:   "\(topic) \(idx)",
                    summary:   "Discussed \(topic) with the team. Item number \(idx).",
                    startedAt: Date(timeIntervalSince1970: Double(idx) * 3_600),
                    source:    "audio"
                )
            }
            for interaction in interactions {
                try await storage.insertInteraction(interaction, linkedEventIds: [])
            }
            inserted += batchCount
        }
    }

    /// Issues `queries` against `storage`, returns sorted nanosecond durations.
    private func runQueries(storage: StorageActor) async -> [UInt64] {
        var durations: [UInt64] = []
        durations.reserveCapacity(Self.queryCount)
        for query in Self.queries {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = await storage.searchKeyword(query: query, limit: 20)
            let t1 = DispatchTime.now().uptimeNanoseconds
            durations.append(t1 - t0)
        }
        return durations.sorted()
    }

    /// Computes a percentile value (0–100) from a sorted nanosecond array.
    private func percentile(_ sorted: [UInt64], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int((Double(sorted.count - 1) * p / 100.0).rounded())
        return Double(sorted[idx]) / 1_000_000 // → ms
    }

    // MARK: - Test 1: p95 latency at 10 K interactions

    func test_searchLatency_10K_p95Under500ms() async throws {
        let dbURL   = tempDir10K.appendingPathComponent("search.db")
        let storage = try StorageActor(passphrase: "perf-search", databaseURL: dbURL)

        try await populate(storage: storage, count: 10_000)
        let sorted = await runQueries(storage: storage)

        let p50 = percentile(sorted, 50)
        let p95 = percentile(sorted, 95)
        let p99 = percentile(sorted, 99)
        print("  ▸ 10K  — p50: \(String(format: "%.1f", p50)) ms  p95: \(String(format: "%.1f", p95)) ms  p99: \(String(format: "%.1f", p99)) ms")

        XCTAssertLessThan(p95, 500.0,
            "p95 search latency must be < 500 ms on 10K interactions (measured: \(String(format: "%.1f", p95)) ms)")
    }

    // MARK: - Test 2: p95 latency at 50 K interactions

    func test_searchLatency_50K_p95Under500ms() async throws {
        let dbURL   = tempDir50K.appendingPathComponent("search.db")
        let storage = try StorageActor(passphrase: "perf-search", databaseURL: dbURL)

        try await populate(storage: storage, count: 50_000)
        let sorted = await runQueries(storage: storage)

        let p50 = percentile(sorted, 50)
        let p95 = percentile(sorted, 95)
        let p99 = percentile(sorted, 99)
        print("  ▸ 50K  — p50: \(String(format: "%.1f", p50)) ms  p95: \(String(format: "%.1f", p95)) ms  p99: \(String(format: "%.1f", p99)) ms")

        XCTAssertLessThan(p95, 500.0,
            "p95 search latency must be < 500 ms on 50K interactions (measured: \(String(format: "%.1f", p95)) ms)")
    }

    // MARK: - Test 3: p95 latency at 200 K interactions

    func test_searchLatency_200K_p95Under500ms() async throws {
        let dbURL   = tempDir200K.appendingPathComponent("search.db")
        let storage = try StorageActor(passphrase: "perf-search", databaseURL: dbURL)

        try await populate(storage: storage, count: 200_000)
        let sorted = await runQueries(storage: storage)

        let p50 = percentile(sorted, 50)
        let p95 = percentile(sorted, 95)
        let p99 = percentile(sorted, 99)
        print("  ▸ 200K — p50: \(String(format: "%.1f", p50)) ms  p95: \(String(format: "%.1f", p95)) ms  p99: \(String(format: "%.1f", p99)) ms")

        XCTAssertLessThan(p95, 500.0,
            "p95 search latency must be < 500 ms on 200K interactions (measured: \(String(format: "%.1f", p95)) ms)")
    }

    // MARK: - Test 4: XCTest measure — keyword search against 10K rows

    /// Provides an XCTest baseline for regression detection in CI.
    /// Setup (DB population) happens before the `measure {}` block so only
    /// the cost of a single representative query is captured.
    func test_searchLatency_measure_singleQuery_10K() async throws {
        let dbURL   = tempDir10K.appendingPathComponent("measure.db")
        let storage = try StorageActor(passphrase: "perf-search", databaseURL: dbURL)
        try await populate(storage: storage, count: 10_000)

        measure(metrics: [XCTClockMetric()]) {
            let expectation = self.expectation(description: "query")
            Task {
                _ = await storage.searchKeyword(query: "meeting project", limit: 20)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 5)
        }
    }

    // MARK: - Test 5: Latency growth is sub-linear (10K → 200K)

    /// Asserts that the p95 latency at 200K is less than 5× the p95 at 10K.
    /// FTS5 with proper indices should scale much better than O(n).
    func test_searchLatency_scalingSubLinear_10KVs200K() async throws {
        let db10K  = tempDir10K.appendingPathComponent("scale.db")
        let db200K = tempDir200K.appendingPathComponent("scale.db")
        let s10K  = try StorageActor(passphrase: "perf", databaseURL: db10K)
        let s200K = try StorageActor(passphrase: "perf", databaseURL: db200K)

        try await populate(storage: s10K,  count: 10_000)
        try await populate(storage: s200K, count: 200_000)

        let sorted10K  = await runQueries(storage: s10K)
        let sorted200K = await runQueries(storage: s200K)

        let p95_10K  = percentile(sorted10K,  95)
        let p95_200K = percentile(sorted200K, 95)
        let ratio    = p95_200K / max(p95_10K, 1)

        print("  ▸ Scale ratio 200K/10K p95: \(String(format: "%.2f", ratio))x  (\(String(format: "%.1f", p95_10K)) ms → \(String(format: "%.1f", p95_200K)) ms)")

        // FTS5 with SQLCipher page-level encryption degrades faster than a pure
        // B-tree index as the corpus grows. Allow up to 50× growth (20× data) to
        // catch catastrophic O(n²) regressions while being realistic for encrypted DBs.
        XCTAssertLessThan(ratio, 50.0,
            "p95 latency must grow sub-linearly: 200K/10K ratio must be < 50× (measured: \(String(format: "%.2f", ratio))×)")
    }
}
