import XCTest
@testable import Kerwan

// MARK: - Test helpers

private let engine = SessionClusteringEngine()

/// Fixed base time (2023-11-14 22:00:00 UTC) used so all date arithmetic in tests
/// is deterministic and independent of the wall clock.
private let base = Date(timeIntervalSince1970: 1_700_000_000)

/// Shorthand for a `Date` offset by `minutes` from `base`.
private func t(_ minutes: Double) -> Date {
    base.addingTimeInterval(minutes * 60)
}

/// Builds a ``ClassifiedEvent`` for testing with sensible defaults.
private func makeEvent(
    id:            String    = UUID().uuidString,
    clientId:      String?   = "client-A",
    projectId:     String?   = nil,
    start:         Date,
    end:           Date?     = nil,
    durationSecs:  Int       = 600,
    billable:      String    = "yes",
    confidence:    Double    = 1.0,
    source:        EventSource = .audio
) -> ClassifiedEvent {
    ClassifiedEvent(
        rawEventId:    id,
        clientId:      clientId,
        projectId:     projectId,
        startedAt:     start,
        endedAt:       end,
        durationSecs:  durationSecs,
        billableGuess: billable,
        confidence:    confidence,
        source:        source
    )
}

// MARK: - Mock BillingEngineStorage

actor MockBillingStorage: BillingEngineStorage {
    private(set) var insertedSessions: [WorkSession] = []
    private(set) var updatedNarratives: [(id: EntityID, description: String?, invoiceText: String?)] = []
    var classifiedEvents: [ClassifiedEvent] = []

    func seed(events: [ClassifiedEvent]) { classifiedEvents = events }

    func listClassifiedEvents(since: Date) async throws -> [ClassifiedEvent] {
        // Unit tests seed events at a fixed base date (Nov 2023) that predates any
        // real `since` window. Return all seeded events unconditionally so BillingEngine
        // tests can focus on clustering behaviour without fighting the time filter.
        classifiedEvents
    }
    func insertWorkSession(_ session: WorkSession) async throws {
        insertedSessions.append(session)
    }
    func updateWorkSession(id: EntityID, description: String?, invoiceText: String?) async throws {
        updatedNarratives.append((id, description, invoiceText))
    }
}

// MARK: - SessionClusteringEngineTests

final class SessionClusteringEngineTests: XCTestCase {

    // MARK: Empty / trivial

    func test_cluster_emptyInput_returnsEmpty() {
        XCTAssertTrue(engine.cluster(events: []).isEmpty)
    }

    // MARK: Consecutive events → one session

    func test_cluster_consecutiveEvents_formOneSession() {
        // Three events with 5-minute gaps — all under the 15-min threshold.
        let events = [
            makeEvent(id: "e1", start: t(0),  end: t(10)),
            makeEvent(id: "e2", start: t(5),  end: t(15)),
            makeEvent(id: "e3", start: t(12), end: t(22))
        ]
        let sessions = engine.cluster(events: events)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(Set(sessions[0].eventIds), ["e1", "e2", "e3"])
        XCTAssertEqual(sessions[0].eventCount, 3)
    }

    func test_cluster_consecutiveEvents_tracksEventIds() {
        let events = [
            makeEvent(id: "alpha", start: t(0),  end: t(10)),
            makeEvent(id: "beta",  start: t(8),  end: t(18))
        ]
        let sessions = engine.cluster(events: events)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(sessions[0].eventIds.contains("alpha"))
        XCTAssertTrue(sessions[0].eventIds.contains("beta"))
    }

    // MARK: Gap > 15 min → two sessions

    func test_cluster_gapBeyond15min_createsTwoSessions() {
        // Gap between event 1 end and event 2 start = 20 min (extended gap range).
        // But extendedGapThreshold default is 45 min, so 20 min is extended → merge.
        // Use a gap > 45 min to force a split.
        let events = [
            makeEvent(id: "e1", start: t(0),  end: t(10)),
            makeEvent(id: "e2", start: t(60), end: t(70))   // 50-min gap > 45-min threshold
        ]
        let sessions = engine.cluster(events: events)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].eventIds, ["e1"])
        XCTAssertEqual(sessions[1].eventIds, ["e2"])
    }

    func test_cluster_gapExactlyAtExtendedThreshold_splits() {
        // Gap = exactly extendedGapThreshold (45 min) → should split (gap >= threshold).
        let events = [
            makeEvent(id: "e1", start: t(0),  end: t(10)),
            makeEvent(id: "e2", start: t(55), end: t(65))   // gap from t(10) = 45 min
        ]
        let sessions = engine.cluster(events: events, gapThreshold: 900, extendedGapThreshold: 2700)
        XCTAssertEqual(sessions.count, 2, "Gap equal to extendedGapThreshold must split")
    }

    func test_cluster_gapExactlyAtGapThreshold_extendsWithPenalty() {
        // Gap = exactly gapThreshold (15 min) → falls into extended range (15 ≤ gap < 45).
        let events = [
            makeEvent(id: "e1", start: t(0),  end: t(10)),
            makeEvent(id: "e2", start: t(25), end: t(35))   // gap from t(10) = 15 min
        ]
        let sessions = engine.cluster(events: events, gapThreshold: 900, extendedGapThreshold: 2700)
        XCTAssertEqual(sessions.count, 1, "Gap equal to gapThreshold should merge (extended)")
        XCTAssertLessThan(sessions[0].confidence, 1.0, "Extended-gap merge should reduce confidence")
    }

    // MARK: Extended gap (15–45 min) → merge with lower confidence

    func test_cluster_extendedGap_mergesWithReducedConfidence() {
        // Events separated by 20 min (> 15 min threshold, < 45 min extended threshold).
        // Each event has confidence = 1.0 and durationSecs = 600.
        // Expected session confidence = 1.0 × 0.7 (extended-gap multiplier) = 0.7.
        let events = [
            makeEvent(id: "e1", start: t(0),  end: t(10), durationSecs: 600, confidence: 1.0),
            makeEvent(id: "e2", start: t(30), end: t(40), durationSecs: 600, confidence: 1.0)
        ]
        let sessions = engine.cluster(events: events)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].confidence, 0.7, accuracy: 0.001)
    }

    func test_cluster_twoExtendedGaps_multipliersAreCumulative() {
        // Two consecutive extended-gap merges → 0.7 × 0.7 = 0.49.
        let events = [
            makeEvent(id: "e1", start: t(0),  end: t(10), durationSecs: 600, confidence: 1.0),
            makeEvent(id: "e2", start: t(30), end: t(40), durationSecs: 600, confidence: 1.0),
            makeEvent(id: "e3", start: t(60), end: t(70), durationSecs: 600, confidence: 1.0)
        ]
        let sessions = engine.cluster(events: events)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].confidence, 0.49, accuracy: 0.001)
    }

    // MARK: Multi-client

    func test_cluster_multiClient_separateSessionsPerClient() {
        // Events for client-A and client-B interleaved in time — must produce
        // one session per client (they share no time clustering).
        let events = [
            makeEvent(id: "a1", clientId: "client-A", start: t(0),  end: t(10)),
            makeEvent(id: "b1", clientId: "client-B", start: t(5),  end: t(15)),
            makeEvent(id: "a2", clientId: "client-A", start: t(8),  end: t(18)),
            makeEvent(id: "b2", clientId: "client-B", start: t(13), end: t(23))
        ]
        let sessions = engine.cluster(events: events)
        XCTAssertEqual(sessions.count, 2)

        let aSession = sessions.first { $0.clientId == "client-A" }
        let bSession = sessions.first { $0.clientId == "client-B" }
        XCTAssertNotNil(aSession)
        XCTAssertNotNil(bSession)
        XCTAssertEqual(Set(aSession!.eventIds), ["a1", "a2"])
        XCTAssertEqual(Set(bSession!.eventIds), ["b1", "b2"])
    }

    func test_cluster_multiClientInterleaved_eachClientIndependentGapCheck() {
        // client-A has two events with a 60-min gap (> 45 min) → split into 2 sessions.
        // client-B has two events with a 5-min gap → stay as 1 session.
        let events = [
            makeEvent(id: "a1", clientId: "client-A", start: t(0),  end: t(10)),
            makeEvent(id: "b1", clientId: "client-B", start: t(2),  end: t(12)),
            makeEvent(id: "b2", clientId: "client-B", start: t(10), end: t(20)),
            makeEvent(id: "a2", clientId: "client-A", start: t(80), end: t(90))
        ]
        let sessions = engine.cluster(events: events)

        let aSessions = sessions.filter { $0.clientId == "client-A" }
        let bSessions = sessions.filter { $0.clientId == "client-B" }
        XCTAssertEqual(aSessions.count, 2, "client-A 60-min gap should split into 2 sessions")
        XCTAssertEqual(bSessions.count, 1, "client-B tight gap should stay as 1 session")
    }

    // MARK: Overnight boundary

    func test_cluster_overnightBoundary_crossesMidnightCorrectly() {
        // Event 1 ends at midnight; event 2 starts 5 minutes later.
        // The 5-min gap is under the threshold → one session.
        // Verifies that Date arithmetic across midnight doesn't corrupt durations.
        let midnight = base.addingTimeInterval(2 * 3600)   // arbitrary "midnight" anchor

        let event1 = makeEvent(
            id: "night",
            start: midnight.addingTimeInterval(-10 * 60),  // 10 min before midnight
            end:   midnight,
            durationSecs: 600
        )
        let event2 = makeEvent(
            id: "morning",
            start: midnight.addingTimeInterval(5 * 60),    // 5 min after midnight
            end:   midnight.addingTimeInterval(15 * 60),
            durationSecs: 600
        )

        let sessions = engine.cluster(events: [event1, event2])
        XCTAssertEqual(sessions.count, 1, "5-minute gap across midnight should produce one session")

        let session = sessions[0]
        // Wall-clock span = 10 min before midnight to 15 min after = 25 min = 1500 s
        XCTAssertEqual(session.totalDurationSecs, 1500, accuracy: 1)
        // Active time = two non-overlapping 10-min events = 1200 s
        XCTAssertEqual(session.activeDurationSecs, 1200, accuracy: 1)
    }

    func test_cluster_overnightBoundary_largeGapSplits() {
        // Event at 11:50 PM, next at 1:00 AM next day — 70-min gap > 45-min threshold.
        let midnight = base.addingTimeInterval(3600)
        let event1   = makeEvent(id: "late",  start: midnight.addingTimeInterval(-10 * 60), end: midnight.addingTimeInterval(-5 * 60))
        let event2   = makeEvent(id: "early", start: midnight.addingTimeInterval(65 * 60),  end: midnight.addingTimeInterval(75 * 60))

        let sessions = engine.cluster(events: [event1, event2])
        XCTAssertEqual(sessions.count, 2, "70-min overnight gap should produce two sessions")
    }

    // MARK: Single-event sessions

    func test_cluster_singleEvent_isValid() {
        let events = [makeEvent(id: "solo", start: t(0), end: t(20))]
        let sessions = engine.cluster(events: events)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].eventCount, 1)
    }

    func test_cluster_singleEvent_hasReducedConfidence() {
        // A single event with confidence = 1.0 should produce session confidence = 0.8.
        let events = [makeEvent(id: "solo", start: t(0), end: t(20), confidence: 1.0)]
        let sessions = engine.cluster(events: events)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].confidence, 0.8, accuracy: 0.001,
                       "Single-event session should apply 0.8× penalty")
    }

    // MARK: Missing endedAt → 300-second estimate

    func test_cluster_missingEndedAt_usesEstimated300sEnd() {
        // Two events: event 1 has no endedAt (estimated end = start + 5 min).
        // Event 2 starts 4 minutes after event 1's estimated end → gap < 15 min → merge.
        let event1 = makeEvent(id: "e1", start: t(0),  end: nil, durationSecs: 600)
        let event2 = makeEvent(id: "e2", start: t(9),  end: t(19))  // 9 - 5 = 4 min gap
        let sessions = engine.cluster(events: [event1, event2])
        XCTAssertEqual(sessions.count, 1, "Gap calculated from estimated 300s end should merge")
    }

    func test_cluster_missingEndedAt_activeDurationUsesEstimate() {
        // Single event: no endedAt, durationSecs = 0.
        // activeDurationSecs should be 300 (the estimated duration).
        let event = makeEvent(id: "e1", start: t(0), end: nil, durationSecs: 0)
        let sessions = engine.cluster(events: [event])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].activeDurationSecs, 300)
    }

    // MARK: Overlapping events — deduplication

    func test_cluster_simultaneousSourcesDontDoubleCounts() {
        // Email + app-focus event that overlap completely in time.
        // Active duration should equal the union (10 min), not the sum (20 min).
        let events = [
            makeEvent(id: "email",    start: t(0), end: t(10), durationSecs: 600, source: .email),
            makeEvent(id: "appfocus", start: t(0), end: t(10), durationSecs: 600, source: .appFocus)
        ]
        let sessions = engine.cluster(events: events)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].activeDurationSecs, 600,
                       "Fully overlapping events should not double-count active time")
    }

    func test_cluster_partiallyOverlappingEvents_deduplicatesCorrectly() {
        // Event 1: t(0)–t(10), Event 2: t(5)–t(20). Union = t(0)–t(20) = 20 min = 1200 s.
        let events = [
            makeEvent(id: "e1", start: t(0),  end: t(10), durationSecs: 600),
            makeEvent(id: "e2", start: t(5),  end: t(20), durationSecs: 900)
        ]
        let sessions = engine.cluster(events: events)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].activeDurationSecs, 1200, accuracy: 1)
    }

    // MARK: Short session filtering

    func test_cluster_shortSession_filteredAsNoise() {
        // A 4-minute session (below the 5-minute threshold) must be discarded.
        let events = [
            makeEvent(id: "brief", start: t(0), end: t(4), durationSecs: 240)
        ]
        XCTAssertTrue(engine.cluster(events: events).isEmpty,
                      "Sessions shorter than 5 min should be filtered out")
    }

    func test_cluster_sessionExactly5Minutes_isKept() {
        let events = [
            makeEvent(id: "five", start: t(0), end: t(5), durationSecs: 300)
        ]
        XCTAssertEqual(engine.cluster(events: events).count, 1,
                       "Sessions of exactly 5 min should be kept")
    }

    // MARK: Unknown client group

    func test_cluster_unknownClient_sessionStillCreated() {
        let events = [
            makeEvent(id: "e1", clientId: nil, start: t(0), end: t(20)),
            makeEvent(id: "e2", clientId: nil, start: t(5), end: t(25))
        ]
        let sessions = engine.cluster(events: events)
        XCTAssertEqual(sessions.count, 1, "Events with nil clientId should still cluster")
        XCTAssertNil(sessions[0].clientId, "Unknown-client session should have nil clientId")
    }

    func test_cluster_unknownAndKnownClients_separateSessions() {
        let events = [
            makeEvent(id: "known",   clientId: "client-A", start: t(0),  end: t(10)),
            makeEvent(id: "unknown", clientId: nil,         start: t(2),  end: t(12))
        ]
        let sessions = engine.cluster(events: events)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(sessions.contains { $0.clientId == "client-A" })
        XCTAssertTrue(sessions.contains { $0.clientId == nil })
    }

    // MARK: Billable status derivation

    func test_cluster_allBillableYes_producesStatusSuggested() {
        let events = [
            makeEvent(id: "e1", start: t(0), end: t(10), billable: "yes"),
            makeEvent(id: "e2", start: t(5), end: t(15), billable: "yes")
        ]
        let sessions = engine.cluster(events: events)
        XCTAssertEqual(sessions[0].billableStatus, .suggested)
    }

    func test_cluster_allBillableNo_producesStatusNonBillable() {
        let events = [
            makeEvent(id: "e1", start: t(0), end: t(10), billable: "no"),
            makeEvent(id: "e2", start: t(5), end: t(15), billable: "no")
        ]
        let sessions = engine.cluster(events: events)
        XCTAssertEqual(sessions[0].billableStatus, .nonBillable)
    }

    func test_cluster_mixedBillable_suggestedWithReducedConfidence() {
        // One "yes" + one "no" → mixed → .suggested with 0.9× confidence penalty.
        // Both events have confidence = 1.0 and equal weight.
        let events = [
            makeEvent(id: "e1", start: t(0), end: t(10), durationSecs: 600, billable: "yes",  confidence: 1.0),
            makeEvent(id: "e2", start: t(5), end: t(15), durationSecs: 600, billable: "no",   confidence: 1.0)
        ]
        let sessions = engine.cluster(events: events)
        XCTAssertEqual(sessions[0].billableStatus, .suggested)
        XCTAssertEqual(sessions[0].confidence, 0.9, accuracy: 0.001,
                       "Mixed billable should apply 0.9× confidence penalty")
    }

    func test_cluster_uncertainBillable_reducesConfidence() {
        let events = [
            makeEvent(id: "e1", start: t(0), end: t(10), durationSecs: 600, billable: "uncertain", confidence: 1.0),
            makeEvent(id: "e2", start: t(5), end: t(15), durationSecs: 600, billable: "uncertain", confidence: 1.0)
        ]
        let sessions = engine.cluster(events: events)
        XCTAssertEqual(sessions[0].billableStatus, .suggested)
        // Neither all-yes nor all-no → 0.9× penalty on confidence.
        XCTAssertEqual(sessions[0].confidence, 0.9, accuracy: 0.001)
    }

    // MARK: Total vs active duration

    func test_cluster_totalAndActiveDuration_differ() {
        // Two non-overlapping events with a 5-minute gap between them.
        // wall-clock span = 25 min = 1500 s; active = 10 + 10 = 20 min = 1200 s.
        let events = [
            makeEvent(id: "e1", start: t(0),  end: t(10), durationSecs: 600),
            makeEvent(id: "e2", start: t(15), end: t(25), durationSecs: 600)
        ]
        let sessions = engine.cluster(events: events)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].totalDurationSecs,  1500, accuracy: 1)
        XCTAssertEqual(sessions[0].activeDurationSecs, 1200, accuracy: 1)
    }

    // MARK: Project ID selection

    func test_cluster_singleProjectId_preserved() {
        let events = [
            makeEvent(id: "e1", projectId: "proj-1", start: t(0), end: t(10)),
            makeEvent(id: "e2", projectId: "proj-1", start: t(5), end: t(15))
        ]
        let sessions = engine.cluster(events: events)
        XCTAssertEqual(sessions[0].projectId, "proj-1")
    }

    func test_cluster_dominantProjectId_usedWhenMixed() {
        // 2 events for proj-X, 1 for proj-Y → session should pick proj-X.
        let events = [
            makeEvent(id: "e1", projectId: "proj-X", start: t(0),  end: t(10)),
            makeEvent(id: "e2", projectId: "proj-X", start: t(5),  end: t(15)),
            makeEvent(id: "e3", projectId: "proj-Y", start: t(10), end: t(20))
        ]
        let sessions = engine.cluster(events: events)
        XCTAssertEqual(sessions[0].projectId, "proj-X")
    }

    // MARK: Output ordering

    func test_cluster_outputSortedByStartedAt() {
        // Provide events in reverse order; output must be chronological.
        let events = [
            makeEvent(id: "e3", clientId: "c1", start: t(120), end: t(130)),
            makeEvent(id: "e1", clientId: "c2", start: t(0),   end: t(10)),
            makeEvent(id: "e2", clientId: "c1", start: t(200), end: t(210))   // new session for c1
        ]
        let sessions = engine.cluster(events: events)
        for i in 0..<(sessions.count - 1) {
            XCTAssertLessThanOrEqual(sessions[i].startedAt, sessions[i + 1].startedAt)
        }
    }

    // MARK: Confidence weighted average

    func test_cluster_confidenceIsWeightedByDuration() {
        // Event 1: confidence = 1.0, duration = 900 s (weight 3×)
        // Event 2: confidence = 0.0, duration = 300 s (weight 1×)
        // Weighted mean = (1.0 × 900 + 0.0 × 300) / 1200 = 0.75
        let events = [
            makeEvent(id: "e1", start: t(0), end: t(15), durationSecs: 900, confidence: 1.0),
            makeEvent(id: "e2", start: t(12), end: t(17), durationSecs: 300, confidence: 0.0)
        ]
        let sessions = engine.cluster(events: events)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].confidence, 0.75, accuracy: 0.01)
    }

    // MARK: Performance

    func test_cluster_performance_5000events_under100ms() {
        // 5 000 events spread across 10 clients.
        // Within each client, consecutive events are 30 minutes apart
        // (extended-gap range) → all merge into one large session per client.
        let allEvents: [ClassifiedEvent] = (0..<5_000).map { i in
            let clientId  = "client-\(i % 10)"
            // Each client's i-th event starts at offset = (i / 10) × 1800 s
            let startedAt = base.addingTimeInterval(Double(i / 10) * 1_800)
            return ClassifiedEvent(
                rawEventId:    "e-\(i)",
                clientId:      clientId,
                projectId:     nil,
                startedAt:     startedAt,
                endedAt:       startedAt.addingTimeInterval(600),
                durationSecs:  600,
                billableGuess: "yes",
                confidence:    0.8,
                source:        .audio
            )
        }

        let wallStart = Date()
        let results   = engine.cluster(events: allEvents)
        let elapsed   = Date().timeIntervalSince(wallStart)

        XCTAssertLessThan(elapsed, 0.1,
            "5 000 events should cluster in under 100 ms (took \(Int(elapsed * 1000)) ms)")
        XCTAssertFalse(results.isEmpty, "Clustering 5 000 events should produce at least one session")
    }
}

// MARK: - Async assertion helper

/// `XCTAssertNoThrow` wrapper for async throwing expressions.
private func XCTAssertNoThrowAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #file,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
    } catch {
        XCTFail("Unexpected throw: \(error)", file: file, line: line)
    }
}
