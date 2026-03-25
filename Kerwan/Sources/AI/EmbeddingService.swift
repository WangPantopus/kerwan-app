import Foundation
import os

/// Generates and stores vector embeddings for all content types in Kerwan.
///
/// ## Embedding sources
///
/// Each 5-minute incremental cycle processes three content families:
///
/// 1. **Interaction summaries** — ``Interaction/summary`` for every record that has no
///    entry in `vec_interactions`. This is the primary path: after classification creates
///    an `Interaction`, the next cycle embeds it.
///
/// 2. **Raw event content** — emails (subject + first 500 chars of body), meeting
///    transcripts (chunked into ≈500-token windows with 50-token overlap), and manual
///    notes. Each raw event that has no entry in `vec_raw_events` is embedded and stored.
///
/// 3. **Promise descriptions** — every ``Promise`` without an entry in `vec_promises`
///    is embedded so it becomes retrievable by semantic search.
///
/// ## Public API
///
/// ```swift
/// // Called immediately after classification saves new interactions:
/// try await embeddingService.embedInteractions(newInteractions)
///
/// // Called at query time (synchronous path, low latency):
/// let queryVector = try await embeddingService.embedQuery("pricing discussion with Acme")
/// ```
///
/// ## Design notes
///
/// - The 5-minute timer task runs at `.background` QoS via `Task.detached`.
/// - `embedInteractions` is safe to call from the classification pipeline because it
///   runs as an `async throws` function on the actor's serial executor.
/// - All storage failures within a batch are non-fatal: the error is logged and the
///   next item continues. A failed interaction is picked up again in the next cycle
///   because it remains absent from `vec_interactions`.
/// - Throughput is logged at `.info` after every non-empty cycle so you can verify
///   nomic-embed-text performance on the target machine.
public actor EmbeddingService {

    // MARK: - Constants

    /// Ollama model name used for all embeddings.
    public static let embeddingModel = "nomic-embed-text"

    /// Number of texts sent to `POST /api/embed` per request.
    public static let batchSize = 20

    /// How often the incremental embedding cycle runs.
    public static let timerInterval: Duration = .seconds(5 * 60)

    // MARK: - Logging

    private static let logger = Logger(subsystem: "com.kerwan.app", category: "EmbeddingService")

    // MARK: - Dependencies

    private let client:  OllamaClient
    private let storage: any EmbeddingServiceStorage

    // MARK: - State

    private var timerTask: Task<Void, Never>?
    private var isStopped  = false
    private var metrics    = EmbeddingMetrics()

    // MARK: - Init

    /// Creates an `EmbeddingService`.
    ///
    /// - Parameters:
    ///   - client: A configured ``OllamaClient`` connected to `127.0.0.1:11434`.
    ///   - storage: A ``EmbeddingServiceStorage``-conforming actor for persisting vectors.
    public init(client: OllamaClient, storage: any EmbeddingServiceStorage) {
        self.client  = client
        self.storage = storage
    }

    // MARK: - Lifecycle

    /// Starts the 5-minute incremental embedding cycle.
    ///
    /// Subsequent calls are no-ops. The timer task runs at `.background` priority
    /// to avoid competing with the UI or classification pipeline.
    public func start() {
        guard timerTask == nil, !isStopped else { return }
        Self.logger.info("EmbeddingService started (interval: \(Self.timerInterval))")
        timerTask = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: EmbeddingService.timerInterval)
                } catch {
                    break  // Task cancelled
                }
                await self?.runIncrementalCycle()
            }
        }
    }

    /// Cancels the incremental cycle. In-flight batches complete normally.
    public func shutdown() async {
        isStopped = true
        timerTask?.cancel()
        timerTask = nil
        Self.logger.info("EmbeddingService stopped")
    }

    // MARK: - Public: Batch embedding (called after classification)

    /// Embeds the summaries of the given interactions and stores each vector in
    /// `vec_interactions`.
    ///
    /// Interactions without a ``Interaction/summary`` are silently skipped.
    /// Processing happens in batches of ``batchSize`` (20). Storage failures per item
    /// are logged and skipped — the interaction stays absent from `vec_interactions`
    /// and is retried in the next incremental cycle.
    ///
    /// Throughput is logged at `.info` on every call that embeds at least one text.
    ///
    /// - Parameter interactions: Newly-classified interactions to embed.
    public func embedInteractions(_ interactions: [Interaction]) async throws {
        let pairs: [(id: EntityID, text: String)] = interactions.compactMap { interaction in
            guard let summary = interaction.summary, !summary.isEmpty else { return nil }
            return (interaction.id, TextPreparation.prepareForStorage(summary))
        }
        guard !pairs.isEmpty else { return }

        let cycleStart = Date()
        var count = 0

        for batch in pairs.chunked(into: Self.batchSize) {
            let vectors = try await client.embedBatch(
                texts: batch.map(\.text),
                model: Self.embeddingModel
            )
            for (index, vector) in vectors.enumerated() {
                do {
                    try await storage.insertVectorEmbedding(
                        interactionId: batch[index].id,
                        embedding: vector
                    )
                    count += 1
                } catch {
                    Self.logger.error(
                        "Failed to store interaction embedding \(batch[index].id, privacy: .public): \(error, privacy: .public)"
                    )
                }
            }
        }

        updateMetricsAndLog(count: count, elapsed: Date().timeIntervalSince(cycleStart), label: "interaction")
    }

    /// Embeds a search query and returns the raw vector.
    ///
    /// Prepends `"search_query: "` before calling `POST /api/embeddings`.
    ///
    /// - Parameter query: The user's natural-language search query.
    /// - Returns: 768-dimensional embedding vector.
    public func embedQuery(_ query: String) async throws -> [Float] {
        let prepared = TextPreparation.prepareForQuery(query)
        return try await client.embed(text: prepared, model: Self.embeddingModel)
    }

    /// Returns a point-in-time snapshot of embedding pipeline metrics.
    public var currentMetrics: EmbeddingMetrics { metrics }

    // MARK: - Internal: Incremental cycle (internal for testing)

    /// Runs one full incremental cycle: interactions → raw events → promises.
    ///
    /// Internal visibility allows direct invocation from tests without waiting for
    /// the timer.
    func runIncrementalCycle() async {
        // Gate on Ollama health.
        guard await client.isHealthy() else {
            Self.logger.warning("Ollama unavailable — skipping embedding cycle")
            return
        }

        let cycleStart = Date()
        var totalEmbedded = 0

        // 1. Interaction summaries.
        do {
            let interactions = try await storage.listUnembeddedInteractions()
            metrics.pendingInteractionCount = interactions.count
            if !interactions.isEmpty {
                try await embedInteractions(interactions)
                totalEmbedded += interactions.filter { $0.summary != nil }.count
            }
        } catch {
            Self.logger.error("Interaction embedding cycle failed: \(error, privacy: .public)")
        }

        // 2. Raw event content (emails, audio transcripts, manual notes).
        do {
            let count = try await embedRawEventContent()
            totalEmbedded += count
        } catch {
            Self.logger.error("Raw event embedding cycle failed: \(error, privacy: .public)")
        }

        // 3. Promise descriptions.
        do {
            let count = try await embedPromiseDescriptions()
            totalEmbedded += count
        } catch {
            Self.logger.error("Promise embedding cycle failed: \(error, privacy: .public)")
        }

        if totalEmbedded > 0 {
            let elapsed = Date().timeIntervalSince(cycleStart)
            updateMetricsAndLog(count: totalEmbedded, elapsed: elapsed, label: "cycle")
        }

        metrics.lastCycleAt = Date()
    }

    // MARK: - Private: Raw event content embedding

    /// Embeds emails, audio transcripts (chunked), and manual notes from raw events.
    ///
    /// - Returns: Total number of chunk embeddings stored.
    private func embedRawEventContent() async throws -> Int {
        let rawEvents = try await storage.listUnembeddedRawEvents(
            sources: [.email, .audio, .manualNote]
        )
        guard !rawEvents.isEmpty else { return 0 }

        // Build (rawEventId, chunkIndex, text) triples.
        struct Chunk { let rawEventId: EntityID; let chunkIndex: Int; let text: String }
        var pending: [Chunk] = []

        for event in rawEvents {
            switch event.source {
            case .email:
                let subject = extractEmailSubject(from: event.metadataJSON)
                let text = TextPreparation.prepareEmail(subject: subject, body: event.rawText)
                if !text.isEmpty {
                    pending.append(Chunk(rawEventId: event.id, chunkIndex: 0, text: text))
                }
            case .audio:
                let rawText = event.rawText ?? ""
                let chunks = TextPreparation.chunkForStorage(rawText)
                for (i, chunk) in chunks.enumerated() {
                    pending.append(Chunk(rawEventId: event.id, chunkIndex: i, text: chunk))
                }
            case .manualNote:
                let rawText = event.rawText ?? ""
                if !rawText.isEmpty {
                    let text = TextPreparation.prepareForStorage(rawText)
                    pending.append(Chunk(rawEventId: event.id, chunkIndex: 0, text: text))
                }
            default:
                break
            }
        }

        guard !pending.isEmpty else { return 0 }

        let cycleStart = Date()
        var count = 0

        // Batch by groups of batchSize — each batch is a flat slice of pending.
        let textBatches = pending.chunked(into: Self.batchSize)
        for batch in textBatches {
            let vectors = try await client.embedBatch(
                texts: batch.map(\.text),
                model: Self.embeddingModel
            )
            for (index, vector) in vectors.enumerated() {
                let chunk = batch[index]
                do {
                    try await storage.insertRawEventEmbedding(
                        rawEventId: chunk.rawEventId,
                        chunkIndex: chunk.chunkIndex,
                        embedding: vector
                    )
                    count += 1
                } catch {
                    Self.logger.error(
                        "Failed to store raw-event embedding \(chunk.rawEventId, privacy: .public) chunk \(chunk.chunkIndex): \(error, privacy: .public)"
                    )
                }
            }
        }

        updateMetricsAndLog(count: count, elapsed: Date().timeIntervalSince(cycleStart), label: "raw-event")
        return count
    }

    // MARK: - Private: Promise embedding

    /// Embeds all promise descriptions that have not yet been stored in `vec_promises`.
    ///
    /// - Returns: Total number of promise embeddings stored.
    private func embedPromiseDescriptions() async throws -> Int {
        let promises = try await storage.listUnembeddedPromises()
        guard !promises.isEmpty else { return 0 }

        let pairs: [(id: EntityID, text: String)] = promises.map { promise in
            (promise.id, TextPreparation.preparePromise(promise.description))
        }

        let cycleStart = Date()
        var count = 0

        for batch in pairs.chunked(into: Self.batchSize) {
            let vectors = try await client.embedBatch(
                texts: batch.map(\.text),
                model: Self.embeddingModel
            )
            for (index, vector) in vectors.enumerated() {
                do {
                    try await storage.insertPromiseEmbedding(
                        promiseId: batch[index].id,
                        embedding: vector
                    )
                    count += 1
                } catch {
                    Self.logger.error(
                        "Failed to store promise embedding \(batch[index].id, privacy: .public): \(error, privacy: .public)"
                    )
                }
            }
        }

        updateMetricsAndLog(count: count, elapsed: Date().timeIntervalSince(cycleStart), label: "promise")
        return count
    }

    // MARK: - Private: Helpers

    /// Extracts the `"subject"` field from a raw-event `metadataJSON` blob.
    private func extractEmailSubject(from metadataJSON: String?) -> String? {
        guard let json = metadataJSON,
              let data = json.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["subject"] as? String
    }

    /// Updates actor-isolated metrics and logs throughput.
    private func updateMetricsAndLog(count: Int, elapsed: TimeInterval, label: String) {
        guard count > 0 else { return }
        let safeElapsed = max(0.001, elapsed)
        let throughput = Double(count) / safeElapsed
        metrics.totalEmbedded += count
        metrics.lastCycleThroughput = throughput
        Self.logger.info(
            "[\(label, privacy: .public)] Embedded \(count) text(s) in \(safeElapsed, format: .fixed(precision: 1))s (\(throughput, format: .fixed(precision: 0)) emb/s)"
        )
    }
}

// MARK: - EmbeddingMetrics

/// Point-in-time snapshot of embedding pipeline performance.
public struct EmbeddingMetrics: Sendable {
    /// Cumulative count of embedding vectors stored since service start.
    public var totalEmbedded: Int = 0

    /// When the last incremental cycle completed. `nil` if no cycle has run yet.
    public var lastCycleAt: Date?

    /// Embeddings per second measured in the most recent logged batch.
    public var lastCycleThroughput: Double = 0

    /// How many interactions were waiting to be embedded at the last cycle start.
    public var pendingInteractionCount: Int = 0

    /// Cumulative count of per-item storage failures since service start.
    public var totalFailures: Int = 0
}

// MARK: - Array.chunked helper

private extension Array {
    /// Splits the array into consecutive sub-arrays of at most `size` elements.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
