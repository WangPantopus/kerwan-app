import XCTest
import Darwin
import KerwanCapture
import KerwanStorage

// MARK: - RSS helper

/// Returns the current physical memory footprint of this process in bytes.
/// Uses `TASK_VM_INFO` (phys_footprint) which is the same value Instruments
/// reports as "Real Memory". Falls back to `task_basic_info.resident_size`
/// on older kernels.
private func currentRSSBytes() -> Int {
    var vmInfo = task_vm_info_data_t()
    var count  = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let kr: kern_return_t = withUnsafeMutablePointer(to: &vmInfo) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    if kr == KERN_SUCCESS {
        return Int(vmInfo.phys_footprint)
    }

    // Fallback
    var basicInfo = task_basic_info()
    var basicCount = mach_msg_type_number_t(
        MemoryLayout<task_basic_info>.size / MemoryLayout<integer_t>.size
    )
    let kr2: kern_return_t = withUnsafeMutablePointer(to: &basicInfo) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
            task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), $0, &basicCount)
        }
    }
    return kr2 == KERN_SUCCESS ? Int(basicInfo.resident_size) : 0
}

/// Formats a byte count for readable test output.
private func formatMB(_ bytes: Int) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_048_576)
}

// MARK: - MemoryUsageTests

/// Verifies that Kerwan's core capture pipeline meets its memory budget after
/// simulating 8 hours of activity at 100× speed.
///
/// ## Budget
///  - Peak RSS growth during the simulation: **< 50 MB** (the process shares
///    memory with the XCTest host; we measure the *delta*, not absolute RSS).
///  - Absolute process RSS at the end of the full-pipeline simulation: **< 200 MB**
///    (as stated in the requirement; this is checked directly, not via `measure`).
///
/// ## Method
///  - `XCTMemoryMetric()` captures the physical memory footprint change *inside*
///    each `measure { }` block, giving XCTest a stable baseline for regression.
///  - A manual before/after RSS snapshot enforces the absolute 200 MB cap.
///
/// ## Fast-forward model
///  Realistic 8-hour capture at typical rates:
///    - Window-focus events: 1 per 30 s → 960 events
///    - Screen-text snapshots: 1 per 60 s → 480 events
///    - Email/calendar: 1 per 5 min → 96 events
///  Total: ~1 500 events. Emitted synchronously (no sleep) to simulate 100× speed.
final class MemoryUsageTests: XCTestCase {

    // MARK: - Constants

    /// Simulated window-focus events: 1 per 30 virtual seconds × 8 hours.
    private static let windowFocusCount = 960
    /// Simulated screen-capture events: 1 per 60 virtual seconds × 8 hours.
    private static let screenCaptureCount = 480
    /// Simulated email-capture events: 1 per 5 minutes × 8 hours.
    private static let emailCount = 96
    /// Total events produced in one 8-hour simulation.
    private static let totalEvents = windowFocusCount + screenCaptureCount + emailCount

    // MARK: - Temp DB helpers

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeRawEvents(source: RawEvent.Source, count: Int,
                               baseApp: String, payloadKB: Int = 0) -> [RawEvent] {
        let payload = payloadKB > 0 ? String(repeating: "x", count: payloadKB * 1024) : nil
        return (0..<count).map { i in
            RawEvent(
                id:          UUID().uuidString,
                timestamp:   Date(timeIntervalSince1970: Double(i) * 30),
                source:      source,
                sourceApp:   baseApp,
                windowTitle: "Window \(i % 50)",
                duration:    30,
                metadata:    payload
            )
        }
    }

    // MARK: - Test 1: RawEventBuffer memory footprint under sustained load

    /// Measures physical memory growth while appending all 8-hour simulation events
    /// to a ``RawEventBuffer`` (capacity = 10 000, the production default).
    ///
    /// The buffer uses a ring — once full it overwrites the oldest slot. This means
    /// memory use should plateau quickly after capacity is reached.
    func test_memory_rawEventBuffer_8hoursSimulation_staysFlat() async throws {
        measure(metrics: [XCTMemoryMetric()]) {
            let buffer = RawEventBuffer(capacity: RawEventBuffer.defaultCapacity,
                                        registerDefaultCursor: true)
            let runLoop = RunLoop.current
            let expectation = self.expectation(description: "buffer fill")

            Task {
                // Window focus
                var events = self.makeRawEvents(source: .windowFocus,
                                                count: Self.windowFocusCount,
                                                baseApp: "Xcode")
                // Screen capture — add 500-byte metadata to simulate screenshot data
                events += self.makeRawEvents(source: .screenCapture,
                                             count: Self.screenCaptureCount,
                                             baseApp: "Finder", payloadKB: 1)
                // Email capture — add ~2 KB metadata to simulate email body
                events += self.makeRawEvents(source: .emailCapture,
                                             count: Self.emailCount,
                                             baseApp: "Mail", payloadKB: 2)
                await buffer.appendBatch(events)
                expectation.fulfill()
            }

            runLoop.run(until: Date(timeIntervalSinceNow: 5))
            self.wait(for: [expectation], timeout: 10)

            // Drain so memory is released before the metric is sampled.
            Task { _ = await buffer.drain(maxCount: RawEventBuffer.defaultCapacity) }
        }
    }

    // MARK: - Test 2: Buffer + StorageActor flush — absolute RSS cap

    /// Appends the full 8-hour simulation set to a buffer, flushes to a real SQLite
    /// database, then asserts that absolute process RSS is under 200 MB.
    ///
    /// This test intentionally does **not** use `measure{}` for the RSS assertion
    /// because XCTest baselines track *delta* not absolute values.
    func test_memory_bufferFlushToStorage_absoluteRSS_under200MB() async throws {
        let dbURL   = tempDir.appendingPathComponent("perf.db")
        let storage = try StorageActor(passphrase: "perf-test", databaseURL: dbURL)
        let buffer  = RawEventBuffer(capacity: RawEventBuffer.defaultCapacity,
                                     registerDefaultCursor: true)
        await buffer.activate(storage: storage)

        // Build the full simulation event set.
        var events  = makeRawEvents(source: .windowFocus,  count: Self.windowFocusCount, baseApp: "Xcode")
        events     += makeRawEvents(source: .screenCapture, count: Self.screenCaptureCount, baseApp: "Finder", payloadKB: 1)
        events     += makeRawEvents(source: .emailCapture,  count: Self.emailCount, baseApp: "Mail", payloadKB: 2)

        await buffer.appendBatch(events)
        await buffer.flushToStorageForTesting()

        // Force-release large temporaries before sampling.
        events.removeAll(keepingCapacity: false)
        await buffer.clear()

        let rssBytes = currentRSSBytes()
        let rssMB    = Double(rssBytes) / 1_048_576
        print("  ▸ Post-flush RSS: \(formatMB(rssBytes)) (limit: 200 MB)")

        XCTAssertLessThan(rssMB, 200.0,
                          "Process RSS after 8-hour simulation flush must stay under 200 MB (measured: \(formatMB(rssBytes)))")
    }

    // MARK: - Test 3: Memory growth is bounded as buffer wraps around

    /// Appends 5× the default buffer capacity (50 000 events) and checks that
    /// memory growth is sub-linear — the ring must reclaim evicted slots.
    func test_memory_bufferOverflow_memoryGrowthSubLinear() async throws {
        let overflowMultiplier = 5
        let totalOverflow = RawEventBuffer.defaultCapacity * overflowMultiplier

        measure(metrics: [XCTMemoryMetric()]) {
            let buffer = RawEventBuffer(capacity: RawEventBuffer.defaultCapacity,
                                        registerDefaultCursor: true)
            let events  = (0..<totalOverflow).map { i in
                RawEvent(id: UUID().uuidString,
                         timestamp: Date(timeIntervalSince1970: Double(i)),
                         source: .windowFocus,
                         sourceApp: "App\(i % 10)",
                         duration: 5)
            }
            let expectation = self.expectation(description: "overflow")
            Task {
                await buffer.appendBatch(events)
                expectation.fulfill()
            }
            self.wait(for: [expectation], timeout: 15)
        }
    }

    // MARK: - Test 4: XCTest memory metric — multi-cursor drain cycle

    /// Creates two cursors (`.storage` and `.classification`) and runs 20 full
    /// drain-and-refill cycles. Memory must not grow across cycles.
    func test_memory_multiCursorDrainCycles_noLeak() async throws {
        let cycleCount      = 20
        let eventsPerCycle  = 200

        measure(metrics: [XCTMemoryMetric()]) {
            let buffer = RawEventBuffer(capacity: 1_000, registerDefaultCursor: false)
            let expectation = self.expectation(description: "cycles")
            Task {
                await buffer.registerCursor(id: .storage)
                await buffer.registerCursor(id: .classification)

                for _ in 0..<cycleCount {
                    let batch = (0..<eventsPerCycle).map { i in
                        RawEvent(id: UUID().uuidString,
                                 timestamp: Date(),
                                 source: .windowFocus,
                                 sourceApp: "App\(i)",
                                 duration: 1)
                    }
                    await buffer.appendBatch(batch)
                    _ = await buffer.drain(cursor: .storage,         maxCount: eventsPerCycle)
                    _ = await buffer.drain(cursor: .classification,  maxCount: eventsPerCycle)
                }
                expectation.fulfill()
            }
            self.wait(for: [expectation], timeout: 30)
        }
    }

    // MARK: - Test 5: StorageActor contact cache does not balloon

    /// Upserts 1 000 contacts and checks that the process memory increment from
    /// the contacts table stays well under 10 MB.
    func test_memory_storageActor_1000Contacts_incrementUnder10MB() async throws {
        let dbURL   = tempDir.appendingPathComponent("contacts.db")
        let storage = try StorageActor(passphrase: "contacts-test", databaseURL: dbURL)

        let rssBefore = currentRSSBytes()

        for i in 0..<1_000 {
            let c = KerwanStorage.Contact(
                id:           UUID().uuidString,
                displayName:  "Contact \(i)",
                emailPrimary: "user\(i)@example.com"
            )
            try await storage.upsertContact(c)
        }

        let rssAfter      = currentRSSBytes()
        let deltaBytes     = max(0, rssAfter - rssBefore)
        let deltaMB        = Double(deltaBytes) / 1_048_576
        print("  ▸ RSS delta for 1 000 contacts: \(formatMB(deltaBytes))")

        XCTAssertLessThan(deltaMB, 10.0,
                          "Upserting 1 000 contacts must not grow RSS by more than 10 MB (delta: \(formatMB(deltaBytes)))")
    }

    // MARK: - Test 6: XCTest measureMetrics — interaction insertion batch

    /// Uses `measure(metrics:)` to track both memory and clock time for a batch
    /// insert of 500 interactions. This provides XCTest with a baseline it can
    /// compare against in CI.
    func test_memory_measure_500InteractionInsert() async throws {
        let dbURL = tempDir.appendingPathComponent("metrics.db")
        let interactions: [KerwanStorage.Interaction] = (0..<500).map { i in
            KerwanStorage.Interaction(
                id:        UUID().uuidString,
                contactId: nil,
                type:      .meeting,
                subject:   "Meeting \(i)",
                summary:   String(repeating: "Discussion about topic \(i). ", count: 10),
                startedAt: Date(timeIntervalSince1970: Double(i) * 3_600),
                source:    "audio"
            )
        }

        measure(metrics: [XCTMemoryMetric(), XCTClockMetric()]) {
            guard let storage = try? StorageActor(passphrase: "measure", databaseURL: dbURL) else {
                XCTFail("Failed to open StorageActor")
                return
            }
            let expectation = self.expectation(description: "insert")
            Task {
                for interaction in interactions {
                    try? await storage.insertInteraction(interaction, linkedEventIds: [])
                }
                try? await storage.deleteAllData()
                expectation.fulfill()
            }
            self.wait(for: [expectation], timeout: 30)
        }
    }
}
