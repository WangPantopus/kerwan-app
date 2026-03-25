import Foundation
import os

/// Resilient parser for the JSON array returned by the classification LLM.
///
/// The LLM occasionally wraps its output in markdown fences, prepends explanatory
/// text, or produces arrays where only some items are well-formed. This parser
/// applies a layered recovery strategy:
///
/// 1. **Direct decode**: try `JSONDecoder` on the raw string as-is.
/// 2. **Array extraction**: use regex to find the substring from the first `[`
///    to the last `]`, then retry decoding.
/// 3. **Item-by-item decode**: parse as `[[String: Any]]` via `JSONSerialization`
///    and decode each element individually, skipping malformed items.
///
/// If all three strategies fail the parser returns `nil` and logs the raw response.
enum ClassificationJSONParser {

    private static let logger = Logger(subsystem: "com.kerwan.app", category: "ClassificationJSONParser")

    // MARK: - Public API

    /// Attempts to parse `text` as a `[ClassificationResult]`.
    ///
    /// - Returns: The array of results (possibly a subset of the input batch if some
    ///   items were malformed), or `nil` if nothing could be recovered.
    static func parse(_ text: String) -> [ClassificationResult]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            logger.error("Classification response is empty")
            return nil
        }

        // Strategy 1: direct decode.
        if let results = directDecode(trimmed), !results.isEmpty {
            return results
        }

        // Strategy 2: extract JSON array substring.
        guard let extracted = extractJSONArray(from: trimmed) else {
            logger.error(
                "Could not find JSON array in classification response: \(trimmed.prefix(300), privacy: .public)"
            )
            return nil
        }

        // Strategy 2b: direct decode on extracted substring.
        if let results = directDecode(extracted), !results.isEmpty {
            return results
        }

        // Strategy 3: item-by-item decode (tolerates partially-malformed arrays).
        let results = decodeItemByItem(extracted)
        if results.isEmpty {
            logger.error(
                "All items malformed in classification response: \(trimmed.prefix(300), privacy: .public)"
            )
            return nil
        }

        let skipped = countItems(in: extracted) - results.count
        if skipped > 0 {
            logger.warning(
                "Skipped \(skipped) malformed item(s) in classification response"
            )
        }
        return results
    }

    // MARK: - Private: Strategy 1 — Direct decode

    private static func directDecode(_ text: String) -> [ClassificationResult]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([ClassificationResult].self, from: data)
    }

    // MARK: - Private: Strategy 2 — Array extraction

    /// Extracts the substring between the first `[` and the last `]` in `text`.
    ///
    /// Handles common LLM response artifacts:
    /// - Markdown fences: `` ```json\n[...]\n``` ``
    /// - Preamble: `"Here is the JSON: [...]"`
    /// - Trailing explanation after the closing bracket.
    static func extractJSONArray(from text: String) -> String? {
        guard let openIdx  = text.firstIndex(of: "["),
              let closeIdx = text.lastIndex(of: "]"),
              openIdx <= closeIdx
        else { return nil }
        return String(text[openIdx...closeIdx])
    }

    // MARK: - Private: Strategy 3 — Item-by-item decode

    /// Parses `jsonArrayText` as `[[String: Any]]` and decodes each element individually.
    ///
    /// Items that fail to decode as `ClassificationResult` are logged at `.error` and skipped.
    private static func decodeItemByItem(_ jsonArrayText: String) -> [ClassificationResult] {
        guard let data = jsonArrayText.data(using: .utf8),
              let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        var results: [ClassificationResult] = []
        for (index, rawItem) in rawArray.enumerated() {
            guard let itemData = try? JSONSerialization.data(withJSONObject: rawItem) else {
                logger.error("Item \(index): could not re-serialize raw dict")
                continue
            }
            do {
                let result = try JSONDecoder().decode(ClassificationResult.self, from: itemData)
                results.append(result)
            } catch {
                logger.error("Item \(index) malformed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return results
    }

    /// Estimates the number of top-level JSON objects in an array string without full decoding.
    ///
    /// Used for "items skipped" accounting in the warning log.
    private static func countItems(in jsonArrayText: String) -> Int {
        guard let data = jsonArrayText.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return 0 }
        return arr.count
    }

    // MARK: - Correlation

    /// Correlates decoded results with their source events.
    ///
    /// Results are matched by the `id` field when available; if `id` is absent or
    /// does not match any event, position-based correlation is used as a fallback
    /// (result[i] → events[i]).
    ///
    /// - Parameters:
    ///   - results: Decoded ``ClassificationResult`` array from the LLM.
    ///   - events: The source ``RawEvent`` array in the same order they were sent.
    /// - Returns: Paired `(event, result)` tuples for downstream processing.
    static func correlate(
        results: [ClassificationResult],
        events: [RawEvent]
    ) -> [(event: RawEvent, result: ClassificationResult)] {
        // Build an id → event lookup for O(1) matching.
        var eventByID: [String: RawEvent] = [:]
        for event in events { eventByID[event.id] = event }

        var pairs: [(event: RawEvent, result: ClassificationResult)] = []
        var usedPositions = IndexSet()

        // Pass 1: match by id.
        for result in results {
            if let id = result.id, let event = eventByID[id] {
                pairs.append((event: event, result: result))
                if let pos = events.firstIndex(where: { $0.id == id }) {
                    usedPositions.insert(pos)
                }
            }
        }

        // Pass 2: position-based fallback for results without matching ids.
        let unmatched = results.filter { r in
            guard let id = r.id else { return true }
            return eventByID[id] == nil
        }

        var fallbackPos = 0
        for result in unmatched {
            while fallbackPos < events.count && usedPositions.contains(fallbackPos) {
                fallbackPos += 1
            }
            if fallbackPos < events.count {
                pairs.append((event: events[fallbackPos], result: result))
                usedPositions.insert(fallbackPos)
                fallbackPos += 1
            }
        }

        return pairs
    }
}
