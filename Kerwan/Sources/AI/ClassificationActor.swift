import Foundation
import os

/// The core AI intelligence layer. Drains ``RawEvent`` records from the pending queue,
/// classifies them in batches via Ollama, and writes structured output (``Interaction``,
/// ``Promise``, embeddings) back to storage.
///
/// ## Lifecycle
///
/// ```swift
/// let actor = ClassificationActor(client: ollamaClient, storage: storageActor)
/// actor.start()                      // begins the 60-second drain cycle
/// actor.enqueue([event1, event2])    // feeds events into the queue
/// await actor.shutdown()             // drains and stops
/// ```
///
/// ## Design notes
///
/// - The drain cycle runs every ``cycleInterval`` (default 60 s). If Ollama is
///   unavailable the cycle skips silently and tries again next time.
/// - Crash-safe: events are only removed from `pendingEvents` after the Ollama
///   call succeeds. Storage failures are non-fatal — logged and skipped.
/// - Embeddings are generated per-interaction and stored in `vec_interactions`.
///   If embedding fails the interaction record is still saved.
/// - Metrics are delivered after every cycle via the `onMetricsUpdate` callback.
public actor ClassificationActor {

    // MARK: - Constants

    /// LLM model used for classification.
    static let classificationModel = "llama3:8b-instruct-q4_K_M"
    /// LLM model used for embeddings.
    static let embeddingModel      = "nomic-embed-text"
    /// Batch wall-clock threshold after which a `.warning` is emitted.
    static let slowBatchThresholdSecs: Double = 30

    // MARK: - Logging

    private static let logger = Logger(subsystem: "com.kerwan.app", category: "ClassificationActor")

    // MARK: - State

    private var pendingEvents: [RawEvent] = []
    private var metrics        = ClassificationMetrics()
    private var drainTask:  Task<Void, Never>?
    private var isStopped = false

    // MARK: - Dependencies

    private let client:  OllamaClient
    private let storage: any ClassificationStorage
    private let cycleInterval: Duration
    private let onMetricsUpdate: @Sendable (ClassificationMetrics) -> Void

    // MARK: - Init

    /// Creates a `ClassificationActor`.
    ///
    /// - Parameters:
    ///   - client: A configured ``OllamaClient`` connected to `127.0.0.1:11434`.
    ///   - storage: A ``ClassificationStorage``-conforming actor for persisting results.
    ///   - cycleInterval: How often to drain and classify pending events. Default: 60 s.
    ///   - onMetricsUpdate: Called after each cycle with a fresh ``ClassificationMetrics`` snapshot.
    public init(
        client: OllamaClient,
        storage: any ClassificationStorage,
        cycleInterval: Duration = .seconds(60),
        onMetricsUpdate: @escaping @Sendable (ClassificationMetrics) -> Void = { _ in }
    ) {
        self.client          = client
        self.storage         = storage
        self.cycleInterval   = cycleInterval
        self.onMetricsUpdate = onMetricsUpdate
    }

    // MARK: - Public Interface

    /// Starts the periodic drain cycle. Safe to call multiple times; subsequent calls are no-ops.
    public func start() {
        guard drainTask == nil, !isStopped else { return }
        Self.logger.info("ClassificationActor started (cycle: \(self.cycleInterval))")
        drainTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: cycleInterval)
                } catch {
                    break  // Cancelled
                }
                await runClassificationCycle()
            }
        }
    }

    /// Cancels the drain cycle and waits for any in-flight classification to finish.
    public func shutdown() async {
        isStopped = true
        drainTask?.cancel()
        drainTask = nil
        Self.logger.info("ClassificationActor stopped. Pending events: \(self.pendingEvents.count)")
    }

    /// Adds events to the pending queue.
    ///
    /// Events marked ``RawEvent/isExcluded`` are silently dropped.
    /// Duplicate IDs (already in queue) are deduplicated.
    public func enqueue(_ events: [RawEvent]) {
        let existingIDs = Set(pendingEvents.map(\.id))
        let incoming = events.filter { !$0.isExcluded && !existingIDs.contains($0.id) }
        pendingEvents.append(contentsOf: incoming)
        metrics.pendingEventCount = pendingEvents.count
        if !incoming.isEmpty {
            Self.logger.debug("Enqueued \(incoming.count) event(s). Total pending: \(self.pendingEvents.count)")
        }
    }

    /// Returns a point-in-time snapshot of the pipeline metrics.
    public var currentMetrics: ClassificationMetrics {
        var snap = metrics
        snap.pendingEventCount = pendingEvents.count
        return snap
    }

    /// The number of events currently waiting to be classified (for testing / monitoring).
    var pendingEventCount: Int { pendingEvents.count }

    // MARK: - Internal: Drain Cycle

    /// Runs one classification cycle: batches pending events → classifies → post-processes.
    ///
    /// Internal visibility allows direct invocation from tests without waiting for the timer.
    func runClassificationCycle() async {
        guard !pendingEvents.isEmpty else { return }

        // Gate on Ollama availability.
        guard await client.isHealthy() else {
            Self.logger.warning("Ollama unavailable — skipping classification cycle")
            return
        }

        let eventsToProcess = Array(pendingEvents.prefix(50))  // cap per cycle
        let batches = ClassificationPromptBuilder.assembleBatches(from: eventsToProcess)
        Self.logger.info("Classification cycle: \(eventsToProcess.count) event(s), \(batches.count) batch(es)")

        var processedIDs = Set<String>()

        for batch in batches {
            do {
                let classified = try await classifyBatch(batch)
                for pair in classified {
                    await postProcess(event: pair.event, result: pair.result)
                    processedIDs.insert(pair.event.id)
                }
            } catch ClassificationError.ollamaUnavailable {
                Self.logger.warning("Ollama became unavailable mid-cycle; stopping")
                break
            } catch {
                Self.logger.error("Batch classification failed: \(error, privacy: .public)")
                // Move on to the next batch; failed events stay in queue for retry.
            }
        }

        // Remove only successfully processed events.
        pendingEvents.removeAll { processedIDs.contains($0.id) }

        // Update metrics.
        metrics.pendingEventCount = pendingEvents.count
        metrics.lastClassificationAt = Date()
        onMetricsUpdate(currentMetrics)
    }

    // MARK: - Internal: Classification

    /// Sends one batch to Ollama, parses the response, and returns correlated pairs.
    ///
    /// On malformed JSON, retries once with the simplified prompt. If the retry also
    /// fails, throws ``ClassificationError/retryFailed``.
    func classifyBatch(_ batch: ClassificationBatch) async throws -> [(event: RawEvent, result: ClassificationResult)] {
        let startTime = Date()

        let system = batch.isRetry
            ? ClassificationPromptBuilder.retrySystemPrompt
            : ClassificationPromptBuilder.systemPrompt
        let user   = ClassificationPromptBuilder.buildUserPrompt(for: batch)

        let raw: String
        do {
            raw = try await client.complete(prompt: user, system: system, model: Self.classificationModel)
        } catch {
            let isOllamaDown = await !client.isHealthy()
            if isOllamaDown { throw ClassificationError.ollamaUnavailable }
            throw error
        }

        let elapsed = Date().timeIntervalSince(startTime)
        updateTimingMetrics(elapsed: elapsed, batchSize: batch.items.count)

        if elapsed > Self.slowBatchThresholdSecs {
            Self.logger.warning(
                "Slow batch: \(String(format: "%.1f", elapsed))s for \(batch.items.count) event(s)"
            )
        }

        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            metrics.parseFailuresTotal += 1
            throw ClassificationError.emptyResponse
        }

        // Try to parse.
        if let results = ClassificationJSONParser.parse(raw) {
            let pairs = ClassificationJSONParser.correlate(results: results, events: batch.sourceEvents)
            metrics.eventsClassifiedTotal += pairs.count
            metrics.batchesProcessedTotal += 1
            return pairs
        }

        // Parse failed — retry with simple prompt unless this is already the retry.
        metrics.parseFailuresTotal += 1
        if batch.isRetry {
            Self.logger.error(
                "Retry classification failed. Raw response: \(raw.prefix(400), privacy: .public)"
            )
            throw ClassificationError.retryFailed
        }

        Self.logger.warning("Primary parse failed; retrying with simplified prompt")
        var retryBatch = batch
        retryBatch.isRetry = true
        return try await classifyBatch(retryBatch)
    }

    // MARK: - Internal: Post-Processing

    /// Persists the classification result for one event: resolves contacts, matches client,
    /// writes ``Interaction`` and ``Promise`` records, generates and stores embedding.
    func postProcess(event: RawEvent, result: ClassificationResult) async {
        // 1. Identity resolution — match/create contact records.
        let primaryContactID = await resolveContacts(result: result)

        // 2. Client matching — fuzzy match against known clients.
        let clientID = await resolveClient(result: result, emailDomain: emailDomain(from: result))

        // 3. Create Interaction.
        let interaction = Interaction(
            id:              UUID().uuidString,
            contactId:       primaryContactID,
            clientId:        clientID,
            projectId:       nil,
            source:          event.source,
            interactionType: interactionType(source: event.source, direction: result.direction),
            startedAt:       event.startedAt,
            endedAt:         event.endedAt,
            summary:         result.summary.isEmpty ? nil : result.summary,
            sentiment:       sentiment(from: result.sentiment),
            importance:      result.importance,
            contentTags:     result.topics + billableTags(from: result.billable),
            isReviewed:      false
        )

        do {
            try await storage.insertInteraction(interaction)
        } catch {
            Self.logger.error("Failed to insert interaction \(interaction.id): \(error, privacy: .public)")
            return
        }

        // 4. Create Promise records.
        for extraction in result.promises where !extraction.description.isEmpty {
            let promise = Promise(
                id:            UUID().uuidString,
                interactionId: interaction.id,
                contactId:     primaryContactID,
                clientId:      clientID,
                direction:     promiseDirection(from: extraction.who),
                description:   extraction.description,
                dueDate:       parseDueDate(extraction.dueDate),
                status:        .open,
                sourceQuote:   nil
            )
            do {
                try await storage.insertPromise(promise)
            } catch {
                Self.logger.error("Failed to insert promise: \(error, privacy: .public)")
            }
        }

        // 5. Generate and store embedding for the summary.
        if !result.summary.isEmpty {
            await generateAndStoreEmbedding(for: interaction.id, text: result.summary)
        }
    }

    // MARK: - Private: Contact Resolution

    /// Resolves contact names and emails to existing ``Contact`` records, creating new ones
    /// for unknown identities. Returns the ID of the primary (first resolved) contact.
    private func resolveContacts(result: ClassificationResult) async -> EntityID? {
        var primaryID: EntityID?

        // Email-based matching first (higher confidence).
        for email in result.contactEmails {
            let normalized = email.lowercased().trimmingCharacters(in: .whitespaces)
            guard !normalized.isEmpty else { continue }
            let contactID = await findOrCreateContact(email: normalized, name: nil)
            if primaryID == nil { primaryID = contactID }
        }

        // Name-based matching for names without a matching email.
        for name in result.contactNames {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let contactID = await findOrCreateContact(email: nil, name: trimmed)
            if primaryID == nil { primaryID = contactID }
        }

        return primaryID
    }

    /// Looks up a contact by email, then by name; creates a new one if not found.
    private func findOrCreateContact(email: String?, name: String?) async -> EntityID? {
        do {
            // Try email lookup first.
            if let email {
                if let existing = try await storage.findContact(byEmail: email) {
                    return existing.id
                }
            }
            // Try name lookup.
            if let name {
                if let existing = try await storage.findContact(byName: name) {
                    return existing.id
                }
            }

            // Create a new contact from whatever we have.
            let displayName = name ?? email ?? "Unknown"
            let contact = Contact(
                displayName: displayName,
                emailPrimary: email,
                needsReview: true
            )
            try await storage.upsertContact(contact)
            return contact.id
        } catch {
            Self.logger.error("Contact resolution failed: \(error, privacy: .public)")
            return nil
        }
    }

    // MARK: - Private: Client Resolution

    /// Matches `result.clientGuess` and email domain against existing client records.
    private func resolveClient(result: ClassificationResult, emailDomain: String?) async -> EntityID? {
        do {
            let clients = try await storage.listClients()
            // 1. Domain match (highest confidence).
            if let domain = emailDomain {
                let normalized = domain.lowercased()
                if let match = clients.first(where: { ($0.domain ?? "").lowercased() == normalized }) {
                    return match.id
                }
            }
            // 2. Name match (case-insensitive, partial).
            if let guess = result.clientGuess?.lowercased().trimmingCharacters(in: .whitespaces),
               !guess.isEmpty {
                let match = clients.first {
                    let clientName = $0.name.lowercased()
                    return clientName == guess
                        || clientName.contains(guess)
                        || guess.contains(clientName)
                }
                if let match { return match.id }
            }
        } catch {
            Self.logger.error("Client resolution failed: \(error, privacy: .public)")
        }
        return nil
    }

    // MARK: - Private: Embedding

    private func generateAndStoreEmbedding(for interactionID: EntityID, text: String) async {
        do {
            let vector = try await client.embed(text: text, model: Self.embeddingModel)
            try await storage.storeInteractionEmbedding(interactionId: interactionID, vector: vector)
        } catch {
            Self.logger.error(
                "Embedding failed for interaction \(interactionID): \(error, privacy: .public)"
            )
        }
    }

    // MARK: - Private: Mapping Helpers

    private func interactionType(source: EventSource, direction: String) -> InteractionType {
        switch source {
        case .audio:     return .meeting
        case .email:     return direction.lowercased() == "user" ? .emailSent : .emailReceived
        case .slack:     return .slackDM
        case .appFocus:  return .appActivity
        default:         return .appActivity
        }
    }

    private func sentiment(from string: String) -> Sentiment {
        switch string.lowercased() {
        case "positive": return .positive
        case "negative": return .negative
        case "mixed":    return .mixed
        default:         return .neutral
        }
    }

    private func promiseDirection(from who: String) -> PromiseDirection {
        who.lowercased() == "user" ? .userPromised : .contactPromised
    }

    /// Tags added to `contentTags` to carry the billable signal forward.
    private func billableTags(from billable: String) -> [String] {
        switch billable.lowercased() {
        case "yes":       return ["billable"]
        case "no":        return ["non-billable"]
        default:          return []
        }
    }

    /// Extracts the email domain from the first contact email in the result.
    private func emailDomain(from result: ClassificationResult) -> String? {
        result.contactEmails
            .first
            .flatMap { $0.split(separator: "@").last.map(String.init) }
    }

    /// Parses a due-date string (ISO 8601 or freeform) into a `Date`.
    private func parseDueDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        // Try ISO 8601 first.
        if let date = Date.fromISO8601(string) { return date }
        // Fallback: common freeform strings (basic set).
        let lower = string.lowercased()
        let now   = Date()
        if lower.contains("today")     { return Calendar.current.startOfDay(for: now) }
        if lower.contains("tomorrow")  { return Calendar.current.date(byAdding: .day, value: 1, to: now) }
        if lower.contains("friday")    { return nextWeekday(.friday, from: now) }
        if lower.contains("monday")    { return nextWeekday(.monday, from: now) }
        if lower.contains("eow") || lower.contains("end of week") { return nextWeekday(.friday, from: now) }
        if lower.contains("eom") || lower.contains("end of month") {
            return Calendar.current.date(byAdding: .month, value: 1, to:
                Calendar.current.startOfDay(for: now).addingTimeInterval(-86400))
        }
        return nil
    }

    private func nextWeekday(_ weekday: Weekday, from date: Date) -> Date? {
        var components = DateComponents()
        components.weekday = weekday.rawValue
        return Calendar.current.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime
        )
    }

    // MARK: - Private: Metrics

    private func updateTimingMetrics(elapsed: TimeInterval, batchSize: Int) {
        let ms = elapsed * 1000
        metrics.lastBatchTimeMs = ms
        let total = metrics.batchesProcessedTotal
        if total == 0 {
            metrics.averageClassificationTimeMs = ms
        } else {
            // Rolling average.
            metrics.averageClassificationTimeMs =
                (metrics.averageClassificationTimeMs * Double(total) + ms) / Double(total + 1)
        }
    }
}

// MARK: - Weekday Helper

private enum Weekday: Int {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday
}
