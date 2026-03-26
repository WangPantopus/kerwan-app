// SpeakingSession.swift
// Kerwan — Transcription layer
//
// Accumulates TranscriptSegments from consecutive audio chunks into a
// single "speaking session" — a continuous stretch of speech.
//
// Responsibilities
// ────────────────
// 1. Accept segments from successive 30-second chunks.
// 2. Deduplicate the 2-second overlap region between consecutive chunks.
// 3. Expose a `isSessionBoundary` check used by TranscriptionActor to
//    decide when to emit the current session as a RawEvent.
// 4. Build the final RawEvent via `toCaptureEvent()`.
//
// Overlap deduplication algorithm
// ────────────────────────────────
// Adjacent 30-second chunks share a 2-second overlap window.  After
// transcription, segments at the START of chunk N+1 (startTime < overlap)
// may repeat text already in the TAIL of chunk N's entries (wall-clock
// end >= chunk N+1 start - overlap_margin).
//
// We use Jaccard word-set similarity on the two text regions.
// If similarity > 0.5 the head segments of chunk N+1 are dropped.
// The threshold is intentionally loose to avoid dropping genuine new speech
// that happens to share common words with the previous segment.

import Foundation
import KerwanXPCProtocol

// MARK: - SpeakingSession

/// Mutable value type that accumulates segments for one speaking session.
///
/// `TranscriptionActor` holds this as a `var`; all mutations are actor-isolated.
struct SpeakingSession: Sendable {

    // MARK: - Entry (wall-clock-anchored segment)

    struct Entry: Sendable {
        let segment:       TranscriptSegment
        let wallClockStart: Date   // chunk.startTime + segment.startTime
        let wallClockEnd:   Date   // chunk.startTime + segment.endTime
    }

    // MARK: - State

    private(set) var entries:         [Entry] = []
    private(set) var chunkCount:      Int     = 0
    let sessionStartTime:             Date
    private(set) var lastEntryEndTime: Date

    // MARK: - Init

    init(startTime: Date) {
        self.sessionStartTime = startTime
        self.lastEntryEndTime = startTime
    }

    // MARK: - Derived

    var isEmpty: Bool { entries.isEmpty }

    /// Full assembled transcript (segments joined with a single space).
    var assembledText: String {
        entries.map(\.segment.text).joined(separator: " ")
    }

    /// Mean confidence across all entries, in [0, 1].
    var averageConfidence: Float {
        guard !entries.isEmpty else { return 0 }
        let sum = entries.reduce(Float(0)) { $0 + $1.segment.confidence }
        return sum / Float(entries.count)
    }

    /// BCP-47 language code from the first entry.
    var detectedLanguage: String {
        entries.first?.segment.language ?? "auto"
    }

    /// Cumulative speech duration (sum of individual segment durations).
    var speakingDurationSeconds: Double {
        entries.reduce(0.0) { $0 + ($1.segment.endTime - $1.segment.startTime) }
    }

    // MARK: - Session boundary check

    /// Returns `true` when `firstWallStart` is more than `silenceGap` seconds
    /// after the end of the last accumulated entry — signalling a new session.
    ///
    /// Always returns `false` for an empty session (can't know a gap yet).
    func isSessionBoundary(firstWallStart: Date, silenceGap: TimeInterval) -> Bool {
        guard !entries.isEmpty else { return false }
        return firstWallStart.timeIntervalSince(lastEntryEndTime) > silenceGap
    }

    // MARK: - Segment accumulation

    /// Appends segments from a new chunk, deduplicating the overlap region.
    ///
    /// - Parameters:
    ///   - newSegments:    Segments returned by Whisper for `chunk`.
    ///   - chunkStart:     Wall-clock start of the audio chunk.
    ///   - overlapSeconds: Expected overlap between consecutive chunks (e.g. 2.0).
    mutating func addChunkSegments(
        _ newSegments: [TranscriptSegment],
        chunkStart: Date,
        overlapSeconds: Double
    ) {
        chunkCount += 1
        guard !newSegments.isEmpty else { return }

        let toAdd = deduplicated(newSegments, chunkStart: chunkStart, overlapSeconds: overlapSeconds)

        for seg in toAdd {
            let ws = chunkStart.addingTimeInterval(seg.startTime)
            let we = chunkStart.addingTimeInterval(seg.endTime)
            entries.append(Entry(segment: seg, wallClockStart: ws, wallClockEnd: we))
            if we > lastEntryEndTime { lastEntryEndTime = we }
        }
    }

    // MARK: - RawEvent emission

    /// Builds a closed `.audio` RawEvent from the accumulated session.
    func toCaptureEvent() -> CaptureEvent {
        let metadata = AudioCaptureMetadata(
            transcript:        assembledText,
            averageConfidence: averageConfidence,
            detectedLanguage:  detectedLanguage,
            durationSeconds:   speakingDurationSeconds,
            chunkCount:        chunkCount
        )
        return CaptureEvent(
            source:     .audio,
            startedAt:  sessionStartTime,
            endedAt:    lastEntryEndTime,
            metadataJSON: metadata.jsonString
        )
    }

    // MARK: - Private: overlap deduplication

    private func deduplicated(
        _ newSegments: [TranscriptSegment],
        chunkStart: Date,
        overlapSeconds: Double
    ) -> [TranscriptSegment] {
        guard !entries.isEmpty, overlapSeconds > 0 else { return newSegments }

        // ── Overlap candidates in the new chunk ──────────────────────────────
        // Segments whose chunk-relative start is within the overlap window.
        // Use a 1.5× margin so segments that straddle the boundary are included.
        let overlapMargin = overlapSeconds * 1.5
        let newOverlapSegs = newSegments.filter { $0.startTime < overlapMargin }
        guard !newOverlapSegs.isEmpty else { return newSegments }

        // ── Tail of existing entries ─────────────────────────────────────────
        // Entries whose wall-clock start is at or after `chunkStart - overlapMargin`.
        // These are the most-recent entries that might repeat in the new chunk.
        let tailThreshold = chunkStart.addingTimeInterval(-overlapMargin)
        let tailEntries   = entries.filter { $0.wallClockStart >= tailThreshold }
        guard !tailEntries.isEmpty else { return newSegments }

        // ── Jaccard similarity ───────────────────────────────────────────────
        let tailText    = tailEntries.map(\.segment.text).joined(separator: " ")
        let newHeadText = newOverlapSegs.map(\.text).joined(separator: " ")
        let similarity  = wordJaccard(tailText, newHeadText)

        // High overlap → the new chunk's head is a duplicate; skip it.
        if similarity > 0.5 {
            return newSegments.filter { $0.startTime >= overlapSeconds }
        }

        return newSegments
    }

    /// Jaccard similarity of the word sets of `a` and `b`.
    /// Returns 0.0 when both strings are empty.
    private func wordJaccard(_ a: String, _ b: String) -> Double {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty })
        }
        let wa = words(a)
        let wb = words(b)
        guard !wa.isEmpty || !wb.isEmpty else { return 0 }
        let intersection = Double(wa.intersection(wb).count)
        let union        = Double(wa.union(wb).count)
        return intersection / union
    }
}
