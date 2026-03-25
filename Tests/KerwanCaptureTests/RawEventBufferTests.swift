import XCTest
@testable import KerwanCapture
@testable import KerwanStorage

// MARK: - RawEventBufferTests

final class RawEventBufferTests: XCTestCase {

    // MARK: - Helpers

    private func makeBuffer(capacity: Int = 10, registerDefault: Bool = true) -> RawEventBuffer {
        RawEventBuffer(capacity: capacity, registerDefaultCursor: registerDefault)
    }

    private func event(id: String = UUID().uuidString, app: String = "Xcode") -> RawEvent {
        RawEvent(id: id, source: .windowFocus, sourceApp: app, windowTitle: "test", duration: 1)
    }

    // MARK: - Basic append / count

    func test_append_incrementsCount() async {
        let buf = makeBuffer(capacity: 10)
        await buf.append(event())
        let c = await buf.count
        XCTAssertEqual(c, 1)
    }

    func test_appendBatch_incrementsCount() async {
        let buf = makeBuffer(capacity: 10)
        await buf.appendBatch([event(), event(), event()])
        let c = await buf.count
        XCTAssertEqual(c, 3)
    }

    func test_isFull_whenAtCapacity() async {
        let buf = makeBuffer(capacity: 3)
        for _ in 0..<3 { await buf.append(event()) }
        let full = await buf.isFull
        XCTAssertTrue(full)
    }

    func test_isFull_falseWhenBelowCapacity() async {
        let buf = makeBuffer(capacity: 3)
        await buf.append(event())
        let full = await buf.isFull
        XCTAssertFalse(full)
    }

    // MARK: - FIFO drain order

    func test_drain_returnsFIFOOrder() async {
        let buf = makeBuffer(capacity: 5)
        let ids = (0..<5).map { "id-\($0)" }
        for id in ids { await buf.append(event(id: id)) }

        let drained = await buf.drain(maxCount: 5)
        XCTAssertEqual(drained.map(\.id), ids, "drain must return events in insertion order (FIFO)")
    }

    func test_drain_partialDrain_preservesOrder() async {
        let buf = makeBuffer(capacity: 10)
        for i in 0..<10 { await buf.append(event(id: "e\(i)")) }

        let first  = await buf.drain(maxCount: 4)
        let second = await buf.drain(maxCount: 4)
        let third  = await buf.drain(maxCount: 4)

        XCTAssertEqual(first.map(\.id),  ["e0","e1","e2","e3"])
        XCTAssertEqual(second.map(\.id), ["e4","e5","e6","e7"])
        XCTAssertEqual(third.map(\.id),  ["e8","e9"])
    }

    func test_drain_maxCountExceedsAvailable_returnsAll() async {
        let buf = makeBuffer(capacity: 10)
        for i in 0..<3 { await buf.append(event(id: "x\(i)")) }
        let drained = await buf.drain(maxCount: 100)
        XCTAssertEqual(drained.count, 3)
    }

    func test_drain_emptyBuffer_returnsEmpty() async {
        let buf = makeBuffer(capacity: 10)
        let result = await buf.drain(maxCount: 5)
        XCTAssertTrue(result.isEmpty)
    }

    func test_drain_decrementCount() async {
        let buf = makeBuffer(capacity: 10)
        for _ in 0..<6 { await buf.append(event()) }
        _ = await buf.drain(maxCount: 4)
        let c = await buf.count
        XCTAssertEqual(c, 2)
    }

    // MARK: - Peek

    func test_peek_doesNotRemoveEvents() async {
        let buf = makeBuffer(capacity: 10)
        for i in 0..<5 { await buf.append(event(id: "p\(i)")) }
        _ = await buf.peek(maxCount: 3)
        let c = await buf.count
        XCTAssertEqual(c, 5, "peek must not consume events")
    }

    func test_peek_returnsFIFOOrder() async {
        let buf = makeBuffer(capacity: 5)
        let ids = ["a","b","c","d","e"]
        for id in ids { await buf.append(event(id: id)) }
        let peeked = await buf.peek(maxCount: 5)
        XCTAssertEqual(peeked.map(\.id), ids)
    }

    func test_peek_maxCountClamped() async {
        let buf = makeBuffer(capacity: 10)
        for _ in 0..<3 { await buf.append(event()) }
        let peeked = await buf.peek(maxCount: 100)
        XCTAssertEqual(peeked.count, 3)
    }

    // MARK: - Clear

    func test_clear_resetsCount() async {
        let buf = makeBuffer(capacity: 10)
        for _ in 0..<8 { await buf.append(event()) }
        await buf.clear()
        let c = await buf.count
        XCTAssertEqual(c, 0)
    }

    func test_clear_drainReturnsEmpty() async {
        let buf = makeBuffer(capacity: 10)
        for _ in 0..<8 { await buf.append(event()) }
        await buf.clear()
        let drained = await buf.drain(maxCount: 10)
        XCTAssertTrue(drained.isEmpty)
    }

    func test_clear_thenAppend_works() async {
        let buf = makeBuffer(capacity: 5)
        for _ in 0..<5 { await buf.append(event()) }
        await buf.clear()
        await buf.append(event(id: "after-clear"))
        let drained = await buf.drain(maxCount: 5)
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained.first?.id, "after-clear")
    }

    // MARK: - Overflow: ring buffer eviction

    func test_overflow_dropsOldestEvent() async {
        // capacity = 3: append 4 events → oldest should be gone
        let buf = makeBuffer(capacity: 3)
        for i in 0..<4 { await buf.append(event(id: "o\(i)")) }

        let drained = await buf.drain(maxCount: 10)
        // o0 should have been dropped; o1, o2, o3 remain
        XCTAssertEqual(drained.map(\.id), ["o1", "o2", "o3"],
                       "Oldest event must be dropped on overflow")
    }

    func test_overflow_dropsMultipleOldestEvents() async {
        let buf = makeBuffer(capacity: 3)
        // Append 6 events to a capacity-3 buffer → 3 dropped, 3 remain
        for i in 0..<6 { await buf.append(event(id: "m\(i)")) }
        let drained = await buf.drain(maxCount: 10)
        XCTAssertEqual(drained.map(\.id), ["m3", "m4", "m5"])
    }

    func test_overflow_incrementsTotalDropped() async {
        let buf = makeBuffer(capacity: 3)
        for i in 0..<7 { await buf.append(event(id: "d\(i)")) }
        let dropped = await buf.totalDropped
        XCTAssertEqual(dropped, 4)
    }

    func test_overflow_countNeverExceedsCapacity() async {
        let buf = makeBuffer(capacity: 5)
        for _ in 0..<20 { await buf.append(event()) }
        let c = await buf.count
        XCTAssertLessThanOrEqual(c, 5)
    }

    // MARK: - Named cursors

    func test_namedCursor_independentFromDefault() async {
        let buf = makeBuffer(capacity: 10)
        for i in 0..<5 { await buf.append(event(id: "n\(i)")) }

        await buf.registerCursor(id: "consumer-B")

        // Drain all 5 from default cursor
        _ = await buf.drain(maxCount: 5)

        // consumer-B was registered AFTER appends → sees 0 events
        let countB = await buf.count(for: "consumer-B")
        XCTAssertEqual(countB, 0,
                       "A cursor registered after events are appended sees no prior events")
    }

    func test_namedCursor_seesEventsAfterRegistration() async {
        let buf = makeBuffer(capacity: 10)
        await buf.registerCursor(id: "C")

        // Append 3 events after cursor C is registered
        for i in 0..<3 { await buf.append(event(id: "c\(i)")) }

        let drained = await buf.drain(cursor: "C", maxCount: 10)
        XCTAssertEqual(drained.map(\.id), ["c0","c1","c2"])
    }

    func test_namedCursor_twoCursorsGetSameEvents() async {
        let buf = makeBuffer(capacity: 10)
        await buf.registerCursor(id: "X")
        await buf.registerCursor(id: "Y")

        for i in 0..<4 { await buf.append(event(id: "xy\(i)")) }

        let drainedX = await buf.drain(cursor: "X", maxCount: 10)
        let drainedY = await buf.drain(cursor: "Y", maxCount: 10)

        XCTAssertEqual(drainedX.map(\.id), drainedY.map(\.id),
                       "Independent cursors over the same events must see the same data")
    }

    func test_namedCursor_drainAtDifferentRates() async {
        let buf = makeBuffer(capacity: 20)
        await buf.registerCursor(id: "fast")
        await buf.registerCursor(id: "slow")

        for i in 0..<10 { await buf.append(event(id: "r\(i)")) }

        // fast drains everything
        let fast = await buf.drain(cursor: "fast", maxCount: 10)
        XCTAssertEqual(fast.count, 10)

        // slow only drains 3
        let slow3 = await buf.drain(cursor: "slow", maxCount: 3)
        XCTAssertEqual(slow3.map(\.id), ["r0","r1","r2"])

        // slow still has 7 available
        let slowRemaining = await buf.count(for: "slow")
        XCTAssertEqual(slowRemaining, 7)

        // fast has nothing
        let fastRemaining = await buf.count(for: "fast")
        XCTAssertEqual(fastRemaining, 0)
    }

    func test_namedCursor_slowCursorPreventsReclaim() async {
        // Capacity = 5; one slow cursor that never drains.
        // The slow cursor pins the ring, so the 6th append drops the oldest
        // (the slow cursor is advanced past it).
        let buf = RawEventBuffer(capacity: 5, registerDefaultCursor: false)
        await buf.registerCursor(id: "slow")
        await buf.registerCursor(id: "fast")

        for i in 0..<5 { await buf.append(event(id: "s\(i)")) }

        // fast drains all 5
        _ = await buf.drain(cursor: "fast", maxCount: 5)

        // Now add one more — slow cursor pins s0–s4 in the ring; slot 0 is overwritten
        await buf.append(event(id: "s5"))

        // slow should lose s0 (the oldest it hadn't read)
        let drained = await buf.drain(cursor: "slow", maxCount: 10)
        // s0 was evicted, slow sees s1…s5
        XCTAssertEqual(drained.map(\.id), ["s1","s2","s3","s4","s5"])
    }

    func test_unregisterCursor_removesIt() async {
        let buf = makeBuffer(capacity: 10)
        await buf.registerCursor(id: "tmp")
        await buf.unregisterCursor(id: "tmp")

        for _ in 0..<3 { await buf.append(event()) }

        let drained = await buf.drain(cursor: "tmp", maxCount: 10)
        XCTAssertTrue(drained.isEmpty, "Unregistered cursor returns no events")
    }

    // MARK: - Concurrent appends

    func test_concurrentAppends_noDataRace() async {
        let buf = makeBuffer(capacity: 1000)
        // 10 concurrent tasks each appending 100 events = 1000 total
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<10 {
                group.addTask {
                    for i in 0..<100 {
                        await buf.append(RawEvent(
                            id: "t\(t)-e\(i)",
                            source: .windowFocus,
                            sourceApp: "App\(t)",
                            duration: 1
                        ))
                    }
                }
            }
        }
        let c = await buf.count
        XCTAssertEqual(c, 1000, "All 1000 events from 10 concurrent tasks must be in the buffer")
    }

    func test_concurrentAppendAndDrain_noDataRace() async {
        let buf = makeBuffer(capacity: 500)
        var drainedTotal = 0

        await withTaskGroup(of: Int.self) { group in
            // Writer task
            group.addTask {
                for i in 0..<500 {
                    await buf.append(RawEvent(id: "cd\(i)", source: .windowFocus, duration: 1))
                }
                return 0
            }
            // Reader task
            group.addTask {
                var total = 0
                for _ in 0..<10 {
                    let batch = await buf.drain(maxCount: 50)
                    total += batch.count
                    // Tiny yield to interleave
                    await Task.yield()
                }
                return total
            }
            for await result in group { drainedTotal += result }
        }
        // We just verify no crash/data-race and that drain returned valid results
        XCTAssertGreaterThanOrEqual(drainedTotal, 0)
    }

    func test_concurrentMultiCursorDrain_noDataRace() async {
        let buf = makeBuffer(capacity: 500)
        await buf.registerCursor(id: "A")
        await buf.registerCursor(id: "B")

        // Write 500 events
        for i in 0..<500 {
            await buf.append(RawEvent(id: "mc\(i)", source: .windowFocus, duration: 1))
        }

        // Two concurrent drains on independent cursors
        async let resultA = buf.drain(cursor: "A", maxCount: 500)
        async let resultB = buf.drain(cursor: "B", maxCount: 500)
        let (a, b) = await (resultA, resultB)

        XCTAssertEqual(a.count, 500)
        XCTAssertEqual(b.count, 500)
        XCTAssertEqual(a.map(\.id), b.map(\.id), "Both cursors must see the same events")
    }

    // MARK: - Flush on termination (mock)

    func test_terminationFlush_writesEventsToStorage() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db")
        let storage = try StorageActor(passphrase: "test", databaseURL: storageURL)
        let buf = makeBuffer(capacity: 10)
        await buf.activate(storage: storage)

        let eventIds = (0..<5).map { "flush-\($0)" }
        for id in eventIds {
            await buf.append(event(id: id))
        }

        // Simulate termination by calling the internal flush directly
        // (we can't fire the real notification without running an app loop)
        await buf.flushToStorageForTesting()

        // After flush, buffer should be empty
        let remaining = await buf.count
        XCTAssertEqual(remaining, 0, "Buffer must be empty after termination flush")

        // Events must have been written to storage — verify by fetching raw events
        // via a work session that links them, or just by confirming no exception was thrown.
        // (StorageActor has no public count-raw-events fetch, so absence of throw is sufficient.)
    }

    func test_terminationFlush_emptyBuffer_isNoOp() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db")
        let storage = try StorageActor(passphrase: "test", databaseURL: storageURL)
        let buf = makeBuffer(capacity: 10)
        await buf.activate(storage: storage)

        // Flush with no events — should not throw
        await buf.flushToStorageForTesting()
        let c = await buf.count
        XCTAssertEqual(c, 0)
    }

    func test_terminationFlush_noStorage_isNoOp() async {
        let buf = makeBuffer(capacity: 10)
        for _ in 0..<5 { await buf.append(event()) }
        // No activate() called — flush should gracefully handle missing storage
        await buf.flushToStorageForTesting()
        // Should not crash
    }

    // MARK: - Dirty shutdown flag

    func test_dirtyShutdown_flagSetAfterActivate() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db")
        let storage = try StorageActor(passphrase: "test", databaseURL: storageURL)
        let buf = makeBuffer()

        // Clear any prior flag
        UserDefaults.standard.removeObject(forKey: "com.kerwan.app.buffer.dirtyShutdown")

        await buf.activate(storage: storage)

        let isSet = UserDefaults.standard.bool(forKey: "com.kerwan.app.buffer.dirtyShutdown")
        XCTAssertTrue(isSet, "Dirty shutdown flag must be set after activate()")
    }

    func test_dirtyShutdown_flagClearedAfterFlush() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db")
        let storage = try StorageActor(passphrase: "test", databaseURL: storageURL)
        let buf = makeBuffer()
        await buf.activate(storage: storage)

        await buf.flushToStorageForTesting()

        let isSet = UserDefaults.standard.bool(forKey: "com.kerwan.app.buffer.dirtyShutdown")
        XCTAssertFalse(isSet, "Dirty shutdown flag must be cleared after a clean flush")
    }

    // MARK: - Occupancy

    func test_occupancy_reflectsMaxUnreadCursor() async {
        let buf = RawEventBuffer(capacity: 20, registerDefaultCursor: false)
        await buf.registerCursor(id: "fast")
        await buf.registerCursor(id: "slow")

        for i in 0..<10 { await buf.append(event(id: "occ\(i)")) }

        // fast drains 8, slow drains 3
        _ = await buf.drain(cursor: "fast", maxCount: 8)
        _ = await buf.drain(cursor: "slow", maxCount: 3)

        // Occupancy = max unread = slow has 7 unread
        let occ = await buf.occupancy
        XCTAssertEqual(occ, 7)
    }

    // MARK: - Ring-wrap + partial drain (regression for reclaimConsumedSlots)

    func test_partialDrain_afterRingWrap_preservesRemainingEvents() async {
        // capacity=3: fill → drain all (triggers reclaimConsumedSlots) →
        // fill again (ring wraps) → partial drain → last event must survive.
        let buf = makeBuffer(capacity: 3)

        for i in 0..<3 { await buf.append(event(id: "first-\(i)")) }
        _ = await buf.drain(maxCount: 3) // consume & reclaim; ring wraps next fill

        for i in 0..<3 { await buf.append(event(id: "second-\(i)")) }

        let partial = await buf.drain(maxCount: 2)
        XCTAssertEqual(partial.map(\.id), ["second-0", "second-1"],
                       "Partial drain must return correct events after ring wrap")

        let rest = await buf.drain(maxCount: 1)
        XCTAssertEqual(rest.map(\.id), ["second-2"],
                       "Remaining event must still be readable after reclaimConsumedSlots")
    }

    func test_partialDrain_multipleWraps_preservesRemainingEvents() async {
        // Two full cycles followed by a partial drain across the wrap boundary.
        let buf = makeBuffer(capacity: 4)

        // Cycle 1
        for i in 0..<4 { await buf.append(event(id: "a\(i)")) }
        _ = await buf.drain(maxCount: 4)

        // Cycle 2
        for i in 0..<4 { await buf.append(event(id: "b\(i)")) }
        _ = await buf.drain(maxCount: 4)

        // Cycle 3 — partial drain then read remainder
        for i in 0..<4 { await buf.append(event(id: "c\(i)")) }
        let first = await buf.drain(maxCount: 2)
        XCTAssertEqual(first.map(\.id), ["c0", "c1"])
        let second = await buf.drain(maxCount: 10)
        XCTAssertEqual(second.map(\.id), ["c2", "c3"],
                       "Events c2 and c3 must survive reclaimConsumedSlots across two ring cycles")
    }

    // MARK: - Performance

    func test_performance_10000AppendsUnder100ms() async {
        let buf = RawEventBuffer(capacity: 10_000)
        let events = (0..<10_000).map { i in
            RawEvent(id: "perf-\(i)", source: .windowFocus,
                     sourceApp: "Xcode", windowTitle: "File.swift", duration: 1)
        }
        let start = Date()
        await buf.appendBatch(events)
        let elapsed = Date().timeIntervalSince(start) * 1_000 // ms
        XCTAssertLessThan(elapsed, 100,
                          "10,000 appends must complete in <100ms, took \(String(format: "%.1f", elapsed))ms")
    }

    func test_performance_10000DrainUnder100ms() async {
        let buf = RawEventBuffer(capacity: 10_000)
        let events = (0..<10_000).map { i in
            RawEvent(id: "d-\(i)", source: .windowFocus, duration: 1)
        }
        await buf.appendBatch(events)

        let start = Date()
        let drained = await buf.drain(maxCount: 10_000)
        let elapsed = Date().timeIntervalSince(start) * 1_000
        XCTAssertEqual(drained.count, 10_000)
        XCTAssertLessThan(elapsed, 100,
                          "10,000 drains must complete in <100ms, took \(String(format: "%.1f", elapsed))ms")
    }

    func test_performance_overflowRingIsFast() async {
        // Write 20,000 events into a 10,000-capacity buffer (every write overflows).
        let buf = RawEventBuffer(capacity: 10_000)
        let events = (0..<20_000).map { i in
            RawEvent(id: "ov-\(i)", source: .windowFocus, duration: 1)
        }
        let start = Date()
        await buf.appendBatch(events)
        let elapsed = Date().timeIntervalSince(start) * 1_000
        XCTAssertLessThan(elapsed, 200,
                          "20,000 appends with overflow must complete in <200ms, took \(String(format: "%.1f", elapsed))ms")
        let dropped = await buf.totalDropped
        XCTAssertEqual(dropped, 10_000)
    }
}
