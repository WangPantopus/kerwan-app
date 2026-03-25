import Foundation

// MARK: - ClassifiedEvent

/// A raw event that has been classified by the AI pipeline with billing intent.
///
/// `ClassifiedEvent` is the primary input to ``SessionClusteringEngine``. It
/// carries the results of ``ClassificationActor`` together with a `billableGuess`
/// and `confidence` score so the clustering engine can decide grouping *and*
/// billing eligibility in a single pass.
public struct ClassifiedEvent: Sendable {
    /// The originating ``RawEvent/id``.
    public let rawEventId:    String
    /// The ``Client/id`` attributed to this event, or `nil` if unresolved.
    public let clientId:      String?
    /// The ``Project/id`` attributed to this event, or `nil` if unresolved.
    public let projectId:     String?
    /// When the event started.
    public let startedAt:     Date
    /// When the event ended, if known. `nil` is common for app-focus events.
    public let endedAt:       Date?
    /// Stated event duration in seconds (from source metadata or classifier estimate).
    public let durationSecs:  Int
    /// Classifier's billing intent: `"yes"`, `"no"`, or `"uncertain"`.
    public let billableGuess: String
    /// Classifier confidence in the billable guess, clamped to 0.0–1.0.
    public let confidence:    Double
    /// The capture source that produced the originating raw event.
    public let source:        EventSource

    public init(
        rawEventId:    String,
        clientId:      String?      = nil,
        projectId:     String?      = nil,
        startedAt:     Date,
        endedAt:       Date?        = nil,
        durationSecs:  Int          = 0,
        billableGuess: String       = "uncertain",
        confidence:    Double       = 0.5,
        source:        EventSource  = .audio
    ) {
        self.rawEventId    = rawEventId
        self.clientId      = clientId
        self.projectId     = projectId
        self.startedAt     = startedAt
        self.endedAt       = endedAt
        self.durationSecs  = durationSecs
        self.billableGuess = billableGuess
        self.confidence    = max(0.0, min(1.0, confidence))
        self.source        = source
    }
}

// MARK: - ClassifiedEvent + effective end

private extension ClassifiedEvent {
    /// The event's effective end time.
    ///
    /// Uses `endedAt` when present. When absent, falls back to
    /// `startedAt + 300 seconds` (a conservative 5-minute estimate).
    var effectiveEndedAt: Date {
        endedAt ?? startedAt.addingTimeInterval(300)
    }
}

// MARK: - WorkSessionCandidate

/// A candidate work session produced by ``SessionClusteringEngine``.
///
/// Candidates are ephemeral — they must be persisted as ``WorkSession`` records by
/// ``BillingEngine`` after optional user review. The separation keeps the pure
/// clustering logic free of storage concerns.
public struct WorkSessionCandidate: Sendable {
    /// The ``Client/id`` this session is attributed to, or `nil` for unknown.
    public let clientId:           String?
    /// The ``Project/id`` that dominated this session's events, or `nil`.
    public let projectId:          String?
    /// Session start time (earliest event start).
    public let startedAt:          Date
    /// Session end time (latest effective event end).
    public let endedAt:            Date
    /// Wall-clock span: `endedAt − startedAt` in seconds.
    public let totalDurationSecs:  Int
    /// Deduplicated active time: sum of non-overlapping event intervals.
    public let activeDurationSecs: Int
    /// IDs of every ``ClassifiedEvent`` that belongs to this session.
    public let eventIds:           [String]
    /// Suggested billing status derived from constituent events.
    public let billableStatus:     BillableStatus
    /// Combined confidence score, 0.0–1.0.
    public let confidence:         Double
    /// Number of events in this session.
    public let eventCount:         Int
}

// MARK: - SessionClusteringEngine

/// Pure, stateless engine that groups ``ClassifiedEvent`` records into coherent
/// ``WorkSessionCandidate`` work blocks.
///
/// ## Algorithm
///
/// 1. Partition events by `clientId`. Events with `nil` clientId form an
///    "unknown" group (sessions are still created but confidence is reduced).
/// 2. Within each partition, sort by `startedAt` then scan left-to-right:
///    - **gap < `gapThreshold`** (default 15 min): merge into current session.
///    - **`gapThreshold` ≤ gap < `extendedGapThreshold`** (default 45 min):
///      merge with a cumulative 0.7× confidence penalty.
///    - **gap ≥ `extendedGapThreshold`**: close current session, start new.
/// 3. For each closed session:
///    - `totalDurationSecs` = wall-clock span (`endedAt − startedAt`).
///    - `activeDurationSecs` = sum of deduplicated, non-overlapping event intervals
///      (prevents double-counting when e.g. email + app-focus events overlap).
///    - `billableStatus`: all "yes" → `.suggested`; all "no" → `.nonBillable`;
///      mixed/uncertain → `.suggested` with an additional 0.9× confidence factor.
///    - `confidence` = duration-weighted mean of event confidences multiplied by
///      all accumulated gap and mix penalties. Single-event sessions apply an
///      additional 0.8× penalty.
/// 4. Sessions shorter than 5 minutes are discarded as noise.
/// 5. Output is sorted by `startedAt` ascending.
public struct SessionClusteringEngine {

    public init() {}

    /// Clusters `events` into candidate work sessions.
    ///
    /// - Parameters:
    ///   - events: Classified events in any order.
    ///   - gapThreshold: Maximum tight-merge gap (default 900 s / 15 min).
    ///   - extendedGapThreshold: Maximum extended-merge gap with confidence
    ///     penalty (default 2700 s / 45 min). Gaps at or beyond this split.
    /// - Returns: Candidate sessions sorted by `startedAt`.
    public func cluster(
        events:               [ClassifiedEvent],
        gapThreshold:         TimeInterval = 900,
        extendedGapThreshold: TimeInterval = 2700
    ) -> [WorkSessionCandidate] {
        guard !events.isEmpty else { return [] }

        // Step 1: Partition by clientId (nil → sentinel).
        var groups: [String: [ClassifiedEvent]] = [:]
        for event in events {
            groups[event.clientId ?? Self.unknownClientKey, default: []].append(event)
        }

        // Step 2: Build sessions within each partition, then filter + sort.
        return groups.values
            .flatMap { groupEvents in
                buildSessions(
                    events:               groupEvents,
                    gapThreshold:         gapThreshold,
                    extendedGapThreshold: extendedGapThreshold
                )
            }
            .filter { $0.totalDurationSecs >= 300 }         // Step 4: drop < 5 min
            .sorted { $0.startedAt < $1.startedAt }         // Step 5: chronological
    }

    // MARK: - Private

    /// Sentinel key for the "unknown client" partition.
    private static let unknownClientKey = "__unknown__"

    /// Builds sessions for one client partition using the sliding-gap algorithm.
    private func buildSessions(
        events:               [ClassifiedEvent],
        gapThreshold:         TimeInterval,
        extendedGapThreshold: TimeInterval
    ) -> [WorkSessionCandidate] {
        let sorted = events.sorted { $0.startedAt < $1.startedAt }

        var result:  [WorkSessionCandidate] = []
        var current = SessionBuilder(first: sorted[0])

        for event in sorted.dropFirst() {
            let gap = event.startedAt.timeIntervalSince(current.lastEventEnd)

            if gap < gapThreshold {
                // Tight gap: standard merge.
                current.append(event)
            } else if gap < extendedGapThreshold {
                // Extended gap: merge with cumulative 0.7× confidence penalty.
                current.confidenceMultiplier *= 0.7
                current.append(event)
            } else {
                // Large gap: close and start fresh.
                if let candidate = current.build() { result.append(candidate) }
                current = SessionBuilder(first: event)
            }
        }

        if let candidate = current.build() { result.append(candidate) }
        return result
    }
}

// MARK: - SessionBuilder

/// Mutable accumulator used while scanning events left-to-right.
private struct SessionBuilder {

    private(set) var events: [ClassifiedEvent]
    /// Accumulated confidence multiplier from gap and billability penalties.
    var confidenceMultiplier: Double = 1.0

    init(first: ClassifiedEvent) {
        self.events = [first]
    }

    mutating func append(_ event: ClassifiedEvent) {
        events.append(event)
    }

    /// The effective end time of the most-recently-added event.
    /// Used as the reference point for computing the next gap.
    var lastEventEnd: Date {
        events.last!.effectiveEndedAt
    }

    /// Finalises the accumulated events into a ``WorkSessionCandidate``.
    func build() -> WorkSessionCandidate? {
        guard !events.isEmpty else { return nil }

        let startedAt   = events[0].startedAt
        let endedAt     = events.map(\.effectiveEndedAt).max()!
        let totalSecs   = max(0, Int(endedAt.timeIntervalSince(startedAt)))
        let activeSecs  = computeActiveDuration()

        let (billable, confidence) = computeBillableAndConfidence()

        return WorkSessionCandidate(
            clientId:           events[0].clientId,
            projectId:          dominantProjectId(),
            startedAt:          startedAt,
            endedAt:            endedAt,
            totalDurationSecs:  totalSecs,
            activeDurationSecs: activeSecs,
            eventIds:           events.map(\.rawEventId),
            billableStatus:     billable,
            confidence:         confidence,
            eventCount:         events.count
        )
    }

    // MARK: Build helpers

    /// Merges overlapping event intervals and sums their durations.
    ///
    /// Handles simultaneous events from multiple sources (e.g. email + app focus)
    /// without double-counting time.
    private func computeActiveDuration() -> Int {
        // Build (start, end) pairs using effectiveEndedAt.
        let intervals = events
            .map { ($0.startedAt, $0.effectiveEndedAt) }
            .sorted { $0.0 < $1.0 }

        // Merge overlapping/adjacent intervals.
        var merged: [(Date, Date)] = []
        for (start, end) in intervals {
            if let (mStart, mEnd) = merged.last, start <= mEnd {
                merged[merged.count - 1] = (mStart, max(mEnd, end))
            } else {
                merged.append((start, end))
            }
        }

        return merged.reduce(0) { total, interval in
            total + max(0, Int(interval.1.timeIntervalSince(interval.0)))
        }
    }

    /// Returns `(billableStatus, finalConfidence)` for the accumulated events.
    private func computeBillableAndConfidence() -> (BillableStatus, Double) {
        let guesses = events.map(\.billableGuess)
        let allYes  = guesses.allSatisfy { $0 == "yes" }
        let allNo   = guesses.allSatisfy { $0 == "no" }

        let billable: BillableStatus
        var mult = confidenceMultiplier

        if allNo {
            billable = .nonBillable
        } else {
            billable = .suggested
            if !allYes { mult *= 0.9 }   // mixed or uncertain
        }

        // Duration-weighted mean confidence.
        let totalWeight   = events.reduce(0) { $0 + max(1, $1.durationSecs) }
        let weightedConf  = events.reduce(0.0) { sum, e in
            sum + e.confidence * Double(max(1, e.durationSecs))
        } / Double(totalWeight)

        // Single-event sessions are inherently less certain.
        if events.count == 1 { mult *= 0.8 }

        return (billable, max(0.0, min(1.0, weightedConf * mult)))
    }

    /// The `projectId` that appears in the most events (by count).
    /// Returns `nil` when all events have `nil` projectId.
    private func dominantProjectId() -> String? {
        var counts: [String: Int] = [:]
        for event in events {
            if let pid = event.projectId { counts[pid, default: 0] += 1 }
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }
}
