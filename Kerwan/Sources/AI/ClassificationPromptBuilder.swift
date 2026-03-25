import Foundation

/// Pure, stateless helpers for building Ollama prompts and assembling classification batches.
///
/// All methods are static; the type is never instantiated.
enum ClassificationPromptBuilder {

    // MARK: - Token Budget Constants

    /// Target maximum input tokens per batch (~3 000 tokens ≈ 12 000 chars at 4 chars/token).
    static let maxBatchTokens: Int = 3_000
    /// Maximum tokens for a single event before it is classified alone (2 000 tokens ≈ 8 000 chars).
    static let maxSingleEventTokens: Int = 2_000
    /// Maximum characters of email body included in a prompt (after subject line).
    static let maxEmailBodyChars: Int = 500
    /// Maximum events per batch regardless of token count.
    static let maxBatchEventCount: Int = 10
    /// Maximum gap between consecutive app-focus events (seconds) before a new run is started.
    static let appFocusMergeGapSecs: Double = 300  // 5 minutes

    // MARK: - System Prompt

    /// The full classification system prompt.
    ///
    /// This is the instruction set sent as the `system` role in every Ollama request.
    /// It describes the exact JSON schema the model must return.
    static let systemPrompt: String = """
    You are a classification engine for a professional's work activity log. You receive batches \
    of work events (app activity, emails, meeting transcripts, messages) and extract structured \
    metadata from each.

    For EACH event in the batch, return a JSON object with these exact fields:
    - id: string — the event id from the input (copy it exactly)
    - contact_names: string[] — names of people mentioned or involved (empty array if none)
    - contact_emails: string[] — email addresses found in the text (empty array if none)
    - client_guess: string|null — your best guess at the client/company this work relates to
    - project_guess: string|null — your best guess at the project name
    - content_types: string[] — one or more of: "factual", "preference", "objection", "promise", \
    "question", "decision", "follow_up", "status_update", "small_talk"
    - direction: "user"|"other"|"unknown" — who is the primary speaker/author
    - promises: array of {description: string, who: "user"|"other", due_date: string|null}
    - topics: string[] — 1-5 topic tags (e.g., "pricing", "timeline", "deliverable", "feedback")
    - billable: "yes"|"no"|"uncertain"
    - importance: number 0.0 to 1.0 (how likely this is to matter for billing or follow-up)
    - sentiment: "positive"|"neutral"|"negative"|"mixed"
    - summary: string — one concise sentence summarizing this event

    Rules:
    - If you cannot determine a field, use null or empty array. Do not guess wildly.
    - Client/project names should be inferred from email domains, company mentions, project keywords.
    - A "promise" is a specific commitment: "I'll send the proposal by Friday" → yes. \
    "We should catch up soon" → no.
    - Importance: meetings and emails about deadlines/money/decisions = high (0.7-1.0). \
    Casual chat = low (0.0-0.3).
    - Respond with ONLY a JSON array. No markdown, no explanation, no backticks.
    """

    /// A simplified system prompt used for the retry pass when the primary response was unparseable.
    ///
    /// Fewer constraints give the model a better chance of emitting clean JSON.
    static let retrySystemPrompt: String = """
    You are a JSON extraction assistant. Return ONLY a valid JSON array — no markdown, \
    no explanation, no backticks.

    For each event in the input, produce one JSON object with these fields:
    - id: string (copy the event id exactly)
    - contact_names: string[]
    - contact_emails: string[]
    - client_guess: string or null
    - promises: [{description: string, who: "user"|"other", due_date: string or null}]
    - topics: string[]
    - billable: "yes"|"no"|"uncertain"
    - importance: number 0.0–1.0
    - sentiment: "positive"|"neutral"|"negative"|"mixed"
    - summary: string (one sentence)

    Output ONLY the JSON array. Nothing else.
    """

    // MARK: - User Prompt

    /// Builds the user-facing prompt for a batch.
    ///
    /// - Parameters:
    ///   - batch: The assembled batch to classify.
    /// - Returns: The formatted user prompt string.
    static func buildUserPrompt(for batch: ClassificationBatch) -> String {
        guard let itemsJSON = try? JSONEncoder().encode(batch.items),
              let itemsString = String(data: itemsJSON, encoding: .utf8)
        else {
            // Fallback: build manually
            let lines = batch.items.map {
                #"{"id":"\#($0.id)","source":"\#($0.source)","timestamp":"\#($0.timestamp)","text":\#(jsonString($0.text))}"#
            }.joined(separator: ",\n  ")
            return "Events to classify:\n[\n  \(lines)\n]"
        }
        return "Events to classify:\n\(itemsString)"
    }

    // MARK: - Batch Assembly

    /// Assembles ``RawEvent`` records into classification batches, applying grouping,
    /// app-focus merging, email truncation, and token-budget enforcement.
    ///
    /// - Parameter events: Raw events to process. Must not be empty.
    /// - Returns: An ordered array of batches ready for classification.
    static func assembleBatches(from events: [RawEvent]) -> [ClassificationBatch] {
        guard !events.isEmpty else { return [] }

        // Separate events by processing strategy.
        let audioEvents  = events.filter { $0.source == .audio }.sorted { $0.startedAt < $1.startedAt }
        let emailEvents  = events.filter { $0.source == .email }.sorted { $0.startedAt < $1.startedAt }
        let focusEvents  = events.filter { $0.source == .appFocus }.sorted { $0.startedAt < $1.startedAt }
        let otherEvents  = events.filter { ![.audio, .email, .appFocus].contains($0.source) }
                                 .sorted { $0.startedAt < $1.startedAt }

        var batches: [ClassificationBatch] = []

        // Audio: full text; oversized events are classified alone.
        batches += buildBatches(
            from: audioEvents,
            textExtractor: audioText(from:)
        )

        // Email: subject line + up to 500 chars of body.
        batches += buildBatches(
            from: emailEvents,
            textExtractor: emailText(from:)
        )

        // App focus: merge consecutive same-app runs, then batch normally.
        let mergedFocusEvents = mergeAppFocusRuns(focusEvents)
        batches += buildBatches(
            from: mergedFocusEvents,
            textExtractor: audioText(from:)  // merged events have synthesized rawText
        )

        // Other sources: generic handling.
        batches += buildBatches(
            from: otherEvents,
            textExtractor: audioText(from:)
        )

        return batches
    }

    // MARK: - Private: Batch Construction

    /// Fills batches from a homogeneous, pre-sorted event list.
    ///
    /// Events exceeding ``maxSingleEventTokens`` get their own single-event batch.
    /// All others are grouped until the batch would exceed ``maxBatchTokens`` or
    /// ``maxBatchEventCount``.
    private static func buildBatches(
        from events: [RawEvent],
        textExtractor: (RawEvent) -> String
    ) -> [ClassificationBatch] {
        var batches: [ClassificationBatch] = []
        var currentItems: [BatchInputItem] = []
        var currentEvents: [RawEvent] = []
        var currentTokens: Int = 0

        for event in events {
            let text   = textExtractor(event)
            let tokens = max(1, text.count / 4)
            let item   = BatchInputItem(
                id:        event.id,
                source:    event.source.rawValue,
                timestamp: event.startedAt.iso8601String,
                text:      text
            )

            if tokens > maxSingleEventTokens {
                // Flush current accumulation first.
                if !currentItems.isEmpty {
                    batches.append(ClassificationBatch(items: currentItems, sourceEvents: currentEvents))
                    currentItems  = []
                    currentEvents = []
                    currentTokens = 0
                }
                // Solo batch.
                batches.append(ClassificationBatch(items: [item], sourceEvents: [event]))
                continue
            }

            let wouldExceedTokens = currentTokens + tokens > maxBatchTokens
            let wouldExceedCount  = currentItems.count >= maxBatchEventCount

            if !currentItems.isEmpty && (wouldExceedTokens || wouldExceedCount) {
                batches.append(ClassificationBatch(items: currentItems, sourceEvents: currentEvents))
                currentItems  = []
                currentEvents = []
                currentTokens = 0
            }

            currentItems.append(item)
            currentEvents.append(event)
            currentTokens += tokens
        }

        if !currentItems.isEmpty {
            batches.append(ClassificationBatch(items: currentItems, sourceEvents: currentEvents))
        }
        return batches
    }

    // MARK: - Private: Text Extractors

    /// Returns the full raw text of an audio (or generic) event.
    private static func audioText(from event: RawEvent) -> String {
        event.rawText ?? ""
    }

    /// Returns a formatted excerpt of an email event: subject + first 500 chars of body.
    ///
    /// Subject is extracted from `metadataJSON` under the key `"subject"`, if available.
    private static func emailText(from event: RawEvent) -> String {
        var parts: [String] = []

        // Extract subject from metadataJSON.
        if let metaString = event.metadataJSON,
           let metaData = metaString.data(using: .utf8),
           let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
           let subject = meta["subject"] as? String {
            parts.append("Subject: \(subject)")
        }

        // Append first 500 chars of body.
        if let body = event.rawText, !body.isEmpty {
            parts.append(String(body.prefix(maxEmailBodyChars)))
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Private: App Focus Merging

    /// Merges consecutive events from the same app (gap < ``appFocusMergeGapSecs``) into
    /// a single synthetic ``RawEvent`` with an aggregated description in ``rawText``.
    static func mergeAppFocusRuns(_ events: [RawEvent]) -> [RawEvent] {
        guard !events.isEmpty else { return [] }

        var merged: [RawEvent] = []
        var runEvents: [RawEvent] = [events[0]]

        for i in 1..<events.count {
            let previous = runEvents.last!
            let current  = events[i]
            let gap      = current.startedAt.timeIntervalSince(previous.endedAt ?? previous.startedAt)
            let sameApp  = current.sourceApp == previous.sourceApp

            if sameApp && gap < appFocusMergeGapSecs {
                runEvents.append(current)
            } else {
                merged.append(synthesizeFocusEvent(from: runEvents))
                runEvents = [current]
            }
        }
        merged.append(synthesizeFocusEvent(from: runEvents))
        return merged
    }

    /// Collapses a consecutive app-focus run into one synthetic event.
    private static func synthesizeFocusEvent(from run: [RawEvent]) -> RawEvent {
        guard let first = run.first, let last = run.last else {
            return run[0]
        }
        let app           = first.sourceApp ?? "unknown app"
        let totalSecs     = run.compactMap(\.durationSecs).reduce(0, +)
        let totalMins     = max(1, totalSecs / 60)
        let startFormatted = first.startedAt.iso8601String

        let event = RawEvent(
            id:          first.id,           // use the first event's id for correlation
            source:      .appFocus,
            sourceApp:   app,
            startedAt:   first.startedAt,
            endedAt:     last.endedAt,
            durationSecs: totalSecs > 0 ? totalSecs : nil,
            rawText:     "User worked in \(app) for \(totalMins) minutes starting at \(startFormatted).",
            metadataJSON: nil,
            isExcluded:  false
        )
        return event
    }

    // MARK: - Private: Utility

    /// JSON-encodes a string value (with escaping) for manual prompt construction fallback.
    private static func jsonString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
