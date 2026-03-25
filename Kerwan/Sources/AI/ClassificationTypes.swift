import Foundation

// MARK: - LLM Result Types

/// The structured metadata extracted by the LLM for a single raw event.
///
/// `ClassificationResult` mirrors the JSON schema the model is instructed to produce.
/// Every field has a safe default to survive partial or lossy LLM output; the custom
/// `init(from:)` never throws so a partially-decodable item is always returned rather
/// than skipped at the top-level decode step.
struct ClassificationResult: Decodable, Sendable {

    /// The `id` echoed back from the input event — used to correlate results with source events.
    let id: String?

    /// Names of people mentioned or involved (empty array if none).
    let contactNames: [String]

    /// Email addresses found in the text (empty array if none).
    let contactEmails: [String]

    /// Best guess at the client/company this work relates to, or `nil`.
    let clientGuess: String?

    /// Best guess at the project name, or `nil`.
    let projectGuess: String?

    /// One or more content-type tags from the fixed vocabulary.
    let contentTypes: [String]

    /// Primary speaker/author direction: `"user"`, `"other"`, or `"unknown"`.
    let direction: String

    /// Specific commitments extracted from the text.
    let promises: [PromiseExtraction]

    /// 1–5 topic tags (e.g., `"pricing"`, `"timeline"`, `"deliverable"`).
    let topics: [String]

    /// Billing signal: `"yes"`, `"no"`, or `"uncertain"`.
    let billable: String

    /// Importance score from 0.0 (routine) to 1.0 (critical). Clamped on decode.
    let importance: Double

    /// Sentiment: `"positive"`, `"neutral"`, `"negative"`, or `"mixed"`.
    let sentiment: String

    /// One concise sentence summarising the event.
    let summary: String

    // MARK: - Coding keys

    private enum CodingKeys: String, CodingKey {
        case id
        case contactNames   = "contact_names"
        case contactEmails  = "contact_emails"
        case clientGuess    = "client_guess"
        case projectGuess   = "project_guess"
        case contentTypes   = "content_types"
        case direction
        case promises
        case topics
        case billable
        case importance
        case sentiment
        case summary
    }

    // MARK: - Custom decode (never throws — provides defaults for all fields)

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try? c.decodeIfPresent(String.self, forKey: .id)
        contactNames  = (try? c.decode([String].self, forKey: .contactNames))  ?? []
        contactEmails = (try? c.decode([String].self, forKey: .contactEmails)) ?? []
        clientGuess   = (try? c.decodeIfPresent(String.self, forKey: .clientGuess)) ?? nil
        projectGuess  = (try? c.decodeIfPresent(String.self, forKey: .projectGuess)) ?? nil
        contentTypes  = (try? c.decode([String].self, forKey: .contentTypes))  ?? []
        direction     = (try? c.decode(String.self,   forKey: .direction))     ?? "unknown"
        promises      = (try? c.decode([PromiseExtraction].self, forKey: .promises)) ?? []
        topics        = (try? c.decode([String].self, forKey: .topics))        ?? []
        billable      = (try? c.decode(String.self,   forKey: .billable))      ?? "uncertain"
        let rawImportance = (try? c.decode(Double.self, forKey: .importance)) ?? 0.5
        importance    = max(0.0, min(1.0, rawImportance))
        sentiment     = (try? c.decode(String.self,   forKey: .sentiment))    ?? "neutral"
        summary       = (try? c.decode(String.self,   forKey: .summary))      ?? ""
    }
}

// MARK: - Promise Extraction

/// A promise (commitment) extracted by the LLM from a raw event.
struct PromiseExtraction: Decodable, Sendable {
    /// Human-readable description of the commitment.
    let description: String

    /// Who made the commitment: `"user"` or `"other"`.
    let who: String

    /// ISO 8601 due date string, or `nil` if not mentioned.
    let dueDate: String?

    private enum CodingKeys: String, CodingKey {
        case description
        case who
        case dueDate = "due_date"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        who         = (try? c.decode(String.self, forKey: .who))         ?? "unknown"
        dueDate     = (try? c.decodeIfPresent(String.self, forKey: .dueDate)) ?? nil
    }
}

// MARK: - Batch Input

/// A single event formatted for inclusion in a classification prompt.
struct BatchInputItem: Encodable, Sendable {
    let id: String
    let source: String
    let timestamp: String
    let text: String

    /// Rough token estimate: 1 token ≈ 4 characters.
    var estimatedTokens: Int { max(1, text.count / 4) }
}

/// A resolved batch: prompt-ready items paired with their source ``RawEvent`` records.
struct ClassificationBatch: Sendable {
    let items: [BatchInputItem]
    let sourceEvents: [RawEvent]
    /// When `true` the assembler will use the simplified retry prompt.
    var isRetry: Bool = false

    var isEmpty: Bool { items.isEmpty }
    var estimatedTokens: Int { items.reduce(0) { $0 + $1.estimatedTokens } }
}

// MARK: - Metrics

/// A snapshot of the classification pipeline's performance counters.
///
/// Updated at the end of every classification cycle and delivered via the
/// `onMetricsUpdate` callback registered on ``ClassificationActor``.
public struct ClassificationMetrics: Sendable {
    /// Total events that have been successfully classified since process launch.
    public var eventsClassifiedTotal: Int = 0
    /// Total batches sent to Ollama since process launch.
    public var batchesProcessedTotal: Int = 0
    /// Running average of batch round-trip time in milliseconds.
    public var averageClassificationTimeMs: Double = 0.0
    /// Wall-clock duration of the most recent batch in milliseconds.
    public var lastBatchTimeMs: Double = 0.0
    /// Number of events waiting to be classified.
    public var pendingEventCount: Int = 0
    /// Timestamp of the last successful classification cycle.
    public var lastClassificationAt: Date?
    /// Cumulative count of JSON parse failures (partial or total).
    public var parseFailuresTotal: Int = 0
}

// MARK: - Errors

/// Errors specific to the classification pipeline. These do not propagate to the UI;
/// they are logged internally and trigger queue-retry behaviour.
enum ClassificationError: Error, LocalizedError {
    /// Ollama is not responding; events remain in the pending queue.
    case ollamaUnavailable
    /// The LLM returned an empty string.
    case emptyResponse
    /// Could not extract a JSON array from the LLM response.
    case jsonExtractionFailed(raw: String)
    /// Every item in the classification array was malformed.
    case allItemsMalformed
    /// The retry classification also failed to produce parseable JSON.
    case retryFailed

    var errorDescription: String? {
        switch self {
        case .ollamaUnavailable:
            return "Ollama unavailable — events will be retried when service resumes."
        case .emptyResponse:
            return "LLM returned an empty response."
        case .jsonExtractionFailed(let raw):
            return "Could not extract JSON array from response: \(raw.prefix(200))"
        case .allItemsMalformed:
            return "All items in the classification batch were malformed and have been skipped."
        case .retryFailed:
            return "Retry classification also failed to produce parseable JSON."
        }
    }
}
