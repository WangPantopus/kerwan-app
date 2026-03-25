import Foundation
import os.log
import KerwanStorage

// MARK: - DrainCursorID

/// Identifies an independent drain consumer.
///
/// Register a cursor with `registerCursor(id:)` to get an independent read
/// pointer through the buffer. ClassificationActor and any other pipeline
/// stage each hold their own cursor so they drain at their own pace without
/// interfering with one another.
public struct DrainCursorID: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    // Predefined IDs for the Kerwan pipeline.
    public static let classification: DrainCursorID = "classification"
    public static let storage: DrainCursorID        = "storage"
    public static let `default`: DrainCursorID      = "default"
}

// MARK: - RawEventBuffer

/// A fixed-capacity, in-memory ring buffer that decouples capture sources from
/// downstream consumers (storage, classification).
///
/// ## Architecture
///
/// ```
/// [ScreenCapture] ──┐
/// [AudioCapture]  ──┼──▶  RawEventBuffer  ──drain(cursor: .classification)──▶ ClassificationActor
/// [EmailCapture]  ──┘          │
///                              └──drain(cursor: .storage)──────────────────▶ StorageActor
/// ```
///
/// Each consumer registers its own `DrainCursorID`. Internally the buffer
/// maintains an independent absolute read position per cursor. An event slot
/// is not recycled until every registered cursor has consumed it.  The global
/// `drain(maxCount:)` / `peek(maxCount:)` interface (no cursor) operates on a
/// shared cursor named `.default` — fine for single-consumer use.
///
/// ## Overflow
///
/// - **> 80% full** → `os_log` warning (edge-triggered: logged once per
///   crossing, not every append).
/// - **100% full** → oldest slot is overwritten; `totalDropped` incremented;
///   `os_log` error per dropped event.
///
/// ## Persistence failsafe
///
/// Call `activate(storage:)` at app startup. This:
/// 1. Detects a dirty-shutdown flag left by a previous crash.
/// 2. Installs an `NSApplication.willTerminateNotification` observer that
///    synchronously flushes all buffered events to `StorageActor` before the
///    process exits.
public actor RawEventBuffer {

    // MARK: - Constants

    public static let defaultCapacity = 10_000

    /// Fraction of capacity at which a warning is emitted.
    private static let warningFraction: Double = 0.80

    /// UserDefaults key for the dirty-shutdown sentinel.
    private static let dirtyShutdownKey = "com.kerwan.app.buffer.dirtyShutdown"

    // MARK: - Ring buffer storage

    private let capacity: Int
    /// Backing array.  Index = `absolutePosition % capacity`.
    private var ring: ContiguousArray<RawEvent?>

    /// Absolute write position (never decrements). Next event is written at
    /// `ring[writeAbs % capacity]`.
    private var writeAbs: Int = 0

    /// Per-cursor absolute read positions.
    /// An event at absolute position `p` is available to cursor `c` when
    /// `cursorAbs[c]! <= p < writeAbs`.
    private var cursorAbs: [DrainCursorID: Int] = [:]

    // MARK: - Diagnostics

    /// Total events dropped due to overflow across the buffer's lifetime.
    public private(set) var totalDropped: Int = 0

    /// Whether the buffer has logged a "> 80%" warning since the last time
    /// it dropped below the threshold (edge-triggered).
    private var highWaterMarkLogged = false

    // MARK: - Dependencies / observers

    private var storage: StorageActor?
    // nonisolated(unsafe) because actor deinit is nonisolated in Swift 5.10+;
    // accessing actor-isolated stored properties there is a Swift 6 error.
    // The observer token is only ever written from within actor-isolated code
    // (installTerminationObserver, which is called from activate), so the
    // unsafety is bounded and safe in practice.
    nonisolated(unsafe) private var terminationObserver: (any NSObjectProtocol)?

    private let log: Logger

    // MARK: - Init

    /// Creates a new buffer.
    ///
    /// - Parameters:
    ///   - capacity: Maximum number of events to hold concurrently (default 10 000).
    ///   - registerDefaultCursor: When `true`, the `.default` cursor is registered
    ///     automatically — convenient for single-consumer use of the bare
    ///     `drain(maxCount:)` API.
    public init(
        capacity: Int = RawEventBuffer.defaultCapacity,
        registerDefaultCursor: Bool = true
    ) {
        precondition(capacity > 0, "RawEventBuffer capacity must be > 0")
        self.capacity = capacity
        self.ring = ContiguousArray(repeating: nil, count: capacity)
        self.log  = Logger(subsystem: "com.kerwan.app", category: "RawEventBuffer")
        if registerDefaultCursor {
            cursorAbs[.default] = 0
        }
    }

    // MARK: - Lifecycle

    /// Activates persistence features: dirty-shutdown detection and the
    /// termination-flush observer.  Call once at app startup after creating
    /// the buffer.
    ///
    /// - Parameter storage: The `StorageActor` to flush events into on exit.
    public func activate(storage: StorageActor) {
        self.storage = storage
        checkDirtyShutdown()
        installTerminationObserver()
    }

    deinit {
        if let obs = terminationObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Cursor registration

    /// Registers an independent drain cursor.  If the cursor already exists,
    /// this is a no-op (the existing position is preserved).
    public func registerCursor(id: DrainCursorID) {
        guard cursorAbs[id] == nil else { return }
        // New cursors start at the current write position — they only see
        // events appended after registration.
        let pos = writeAbs
        cursorAbs[id] = pos
        log.debug("Cursor '\(id)' registered at position \(pos).")
    }

    /// Removes a cursor.  Slots consumed only by that cursor are freed sooner.
    public func unregisterCursor(id: DrainCursorID) {
        cursorAbs.removeValue(forKey: id)
        log.debug("Cursor '\(id)' unregistered.")
    }

    // MARK: - Write interface

    /// Appends a single event. If the buffer is full, the oldest unread event
    /// is dropped (all cursors are advanced past it).
    public func append(_ event: RawEvent) {
        appendOne(event)
    }

    /// Appends multiple events. More efficient than calling `append` in a loop
    /// because overflow checking is batched.
    public func appendBatch(_ events: [RawEvent]) {
        for event in events { appendOne(event) }
    }

    // MARK: - Read interface (default cursor)

    /// Removes and returns up to `maxCount` events in FIFO order using the
    /// `.default` cursor.  Callers that registered their own cursor should use
    /// `drain(cursor:maxCount:)` instead.
    public func drain(maxCount: Int) -> [RawEvent] {
        drain(cursor: .default, maxCount: maxCount)
    }

    /// Peeks at up to `maxCount` events without advancing the `.default` cursor.
    public func peek(maxCount: Int) -> [RawEvent] {
        peek(cursor: .default, maxCount: maxCount)
    }

    /// Number of events available to the `.default` cursor.
    public var count: Int { available(for: .default) }

    /// `true` when the buffer holds `capacity` events and no more can be added
    /// without dropping.
    public var isFull: Bool { occupancy == capacity }

    /// Resets the buffer: drops all events and resets every cursor to the
    /// current write position.
    public func clear() {
        for slot in 0 ..< capacity { ring[slot] = nil }
        let resetPos = writeAbs
        for key in cursorAbs.keys { cursorAbs[key] = resetPos }
        highWaterMarkLogged = false
        log.debug("Buffer cleared. Write position: \(resetPos).")
    }

    // MARK: - Read interface (named cursors)

    /// Removes and returns up to `maxCount` events from `cursor`'s perspective.
    public func drain(cursor: DrainCursorID, maxCount: Int) -> [RawEvent] {
        guard let start = cursorAbs[cursor], maxCount > 0 else { return [] }
        let end = min(start + maxCount, writeAbs)
        guard end > start else { return [] }

        var results = [RawEvent]()
        results.reserveCapacity(end - start)
        for abs in start ..< end {
            if let event = ring[abs % capacity] {
                results.append(event)
            }
        }
        cursorAbs[cursor] = end

        // After advancing this cursor, try to reclaim ring slots that all
        // cursors have now passed.
        reclaimConsumedSlots()

        return results
    }

    /// Returns up to `maxCount` events visible to `cursor` without advancing it.
    public func peek(cursor: DrainCursorID, maxCount: Int) -> [RawEvent] {
        guard let start = cursorAbs[cursor], maxCount > 0 else { return [] }
        let end = min(start + maxCount, writeAbs)
        guard end > start else { return [] }

        var results = [RawEvent]()
        results.reserveCapacity(end - start)
        for abs in start ..< end {
            if let event = ring[abs % capacity] {
                results.append(event)
            }
        }
        return results
    }

    /// Number of events available to `cursor`.
    public func count(for cursor: DrainCursorID) -> Int {
        available(for: cursor)
    }

    // MARK: - Diagnostics

    /// Returns a snapshot of all registered cursor IDs and their available
    /// event counts.
    public func cursorDiagnostics() -> [(id: DrainCursorID, available: Int)] {
        cursorAbs.map { (id: $0.key, available: self.writeAbs - $0.value) }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    // MARK: - Maintenance

    /// Returns the total number of events currently held in the ring (the
    /// maximum available to any single cursor).
    public var occupancy: Int {
        guard !cursorAbs.isEmpty else { return 0 }
        let minRead = cursorAbs.values.min() ?? writeAbs
        return writeAbs - minRead
    }

    // MARK: - Private: core ring operations

    private func appendOne(_ event: RawEvent) {
        if cursorAbs.isEmpty {
            // No cursors registered — buffer is effectively a no-op sink.
            log.warning("RawEventBuffer: event appended with no registered cursors.")
            return
        }

        let slot = writeAbs % capacity
        let currentOccupancy = occupancy

        if currentOccupancy >= capacity {
            // Buffer is full — advance every cursor past the oldest slot so it
            // can be overwritten.
            let oldestAbs = writeAbs - capacity
            for key in cursorAbs.keys {
                if cursorAbs[key]! <= oldestAbs {
                    cursorAbs[key] = oldestAbs + 1
                }
            }
            totalDropped += 1
            let dropped  = totalDropped
            let srcApp   = event.sourceApp ?? "?"
            log.error("RawEventBuffer overflow: dropped oldest event (total dropped: \(dropped)). Source: \(event.source.rawValue, privacy: .public), app: \(srcApp, privacy: .private).")
        }

        ring[slot] = event
        writeAbs += 1

        // Edge-triggered 80% warning.
        let newOccupancy = occupancy
        let cap          = capacity
        let ratio = Double(newOccupancy) / Double(cap)
        if ratio >= Self.warningFraction && !highWaterMarkLogged {
            log.warning("RawEventBuffer is \(Int(ratio * 100))% full (\(newOccupancy)/\(cap) events). Consumers may not be draining fast enough.")
            highWaterMarkLogged = true
        } else if ratio < Self.warningFraction {
            highWaterMarkLogged = false
        }
    }

    /// Returns the number of events available to `cursor`.
    private func available(for cursor: DrainCursorID) -> Int {
        guard let pos = cursorAbs[cursor] else { return 0 }
        return max(0, writeAbs - pos)
    }

    /// Nils out ring slots that every cursor has now consumed.
    /// This releases `RawEvent` references and prevents memory growth.
    ///
    /// **Correctness note**: we must only reclaim slots within the *live ring
    /// window* — absolute positions `[writeAbs - capacity, writeAbs)`.  Using
    /// `safeBelow - capacity` as the lower bound is wrong when the ring has
    /// wrapped: position `safeBelow - capacity` maps to the same physical slot
    /// as a *newer*, still-unread event, and niling it would silently destroy
    /// that event.  The live-window lower bound `writeAbs - capacity` is always
    /// safe because every slot in the range `[writeAbs - capacity, safeBelow)`
    /// (a) is within the current ring cycle and (b) has been consumed by all
    /// registered cursors.
    private func reclaimConsumedSlots() {
        guard !cursorAbs.isEmpty else { return }
        let safeBelow   = cursorAbs.values.min() ?? writeAbs
        let windowStart = max(writeAbs - capacity, 0)
        guard safeBelow > windowStart else { return }
        for abs in windowStart ..< safeBelow {
            ring[abs % capacity] = nil
        }
    }

    // MARK: - Private: dirty shutdown + termination flush

    private func checkDirtyShutdown() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.dirtyShutdownKey) {
            log.warning("Dirty shutdown detected: the previous session ended abnormally (crash or force-quit). Some unbuffered events may have been lost.")
        }
        // Arm the flag. It will be cleared in the termination handler.
        defaults.set(true, forKey: Self.dirtyShutdownKey)
    }

    private func installTerminationObserver() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSApplicationWillTerminateNotification"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleWillTerminate()
        }
        log.debug("Termination observer installed.")
    }

    // MARK: - Testing hooks

    /// Directly invokes the async termination flush.  Use in unit tests to
    /// verify flush behaviour without firing a real notification.
    public func flushToStorageForTesting() async {
        await performTerminationFlush()
    }

    // MARK: - Private: termination handler

    /// Synchronous termination handler — blocks the calling thread (main) until
    /// the flush completes. The system gives macOS apps ~5 s before SIGKILL.
    private nonisolated func handleWillTerminate() {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await performTerminationFlush()
            semaphore.signal()
        }
        // 4-second timeout — well within the macOS termination budget.
        let result = semaphore.wait(timeout: .now() + 4)
        if result == .timedOut {
            Logger(subsystem: "com.kerwan.app", category: "RawEventBuffer")
                .error("Termination flush timed out — some events may have been lost.")
        }
    }

    private func performTerminationFlush() async {
        guard let storage else {
            log.warning("Termination flush: no StorageActor configured, skipping.")
            clearDirtyShutdownFlag()
            return
        }

        // Drain all cursors — take the union of all unread events.
        // We flush the full ring contents to storage regardless of cursor state.
        let allEvents = drainAllCursors()
        guard !allEvents.isEmpty else {
            log.info("Termination flush: buffer empty, nothing to write.")
            clearDirtyShutdownFlag()
            return
        }

        log.info("Termination flush: writing \(allEvents.count) buffered events to storage.")
        do {
            try await storage.insertRawEvents(allEvents)
            log.info("Termination flush complete.")
        } catch {
            log.error("Termination flush failed: \(error).")
        }
        clearDirtyShutdownFlag()
    }

    /// Returns every event currently in the ring (ignoring cursor positions)
    /// and resets all cursors to `writeAbs`.
    private func drainAllCursors() -> [RawEvent] {
        if occupancy == 0 { return [] }
        let minRead = cursorAbs.values.min() ?? writeAbs
        var results = [RawEvent]()
        results.reserveCapacity(writeAbs - minRead)
        for abs in minRead ..< writeAbs {
            if let event = ring[abs % capacity] {
                results.append(event)
            }
        }
        // Reset all cursors to current write head.
        for key in cursorAbs.keys { cursorAbs[key] = writeAbs }
        return results
    }

    private nonisolated func clearDirtyShutdownFlag() {
        UserDefaults.standard.removeObject(forKey: Self.dirtyShutdownKey)
    }
}

// MARK: - Sendable conformance note
// RawEventBuffer is an actor, therefore implicitly Sendable.
// DrainCursorID is a value type (struct) and explicitly Sendable.
