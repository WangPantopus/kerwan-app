import Foundation
import os

// MARK: - BillingEngineStorage

/// The storage interface required by ``BillingEngine``.
///
/// Conforming types must be `Actor`-isolated to preserve the single-writer
/// guarantee required by SQLite.
public protocol BillingEngineStorage: Actor {

    /// Returns all ``ClassifiedEvent`` records created after `since`.
    ///
    /// The look-back window is controlled by the caller so the storage layer
    /// does not need to know about the engine's scheduling policy.
    func listClassifiedEvents(since: Date) async throws -> [ClassifiedEvent]

    /// Persists a new ``WorkSession`` produced by the clustering engine.
    ///
    /// Implementations must handle duplicate `id` values gracefully (e.g., via
    /// `INSERT OR IGNORE`) so repeated clustering runs are idempotent.
    func insertWorkSession(_ session: WorkSession) async throws

    /// Updates the narrative fields of an existing work session.
    ///
    /// Called after ``BillingEngine/runNarrativeGeneration(for:)`` successfully
    /// generates a description and invoice text via the LLM.
    func updateWorkSession(
        id:          EntityID,
        description: String?,
        invoiceText: String?
    ) async throws
}

// MARK: - BillingEngine

/// Nightly billing pipeline: session clustering and AI narrative generation.
///
/// ## Lifecycle
///
/// ```swift
/// let engine = BillingEngine(client: ollamaClient, storage: storageActor)
///
/// // Step 1 — run nightly (via a cron task or on app launch):
/// try await engine.runDailyClustering()
///
/// // Step 2 — run after the user has reviewed the clustering output:
/// try await engine.runNarrativeGeneration(for: confirmedSessions)
/// ```
///
/// ## Design notes
///
/// - ``runDailyClustering`` looks back ``clusteringLookBack`` (48 h) to handle
///   edge cases at midnight and late-arriving events.
/// - Per-session storage failures in both methods are non-fatal: the error is
///   logged and the next session proceeds. The method-level `throws` fires only
///   if the initial storage fetch fails.
/// - Narrative generation is intentionally separate from clustering so users
///   can review and edit sessions before committing to LLM-generated text.
public actor BillingEngine {

    // MARK: - Constants

    /// Ollama model used for invoice narrative generation.
    public static let narrativeModel = "llama3:8b-instruct-q4_K_M"

    /// How far back ``runDailyClustering`` looks when fetching events.
    /// A 2× window prevents edge cases at the midnight boundary.
    public static let clusteringLookBack: TimeInterval = 48 * 3_600

    // MARK: - Logging

    private static let logger = Logger(subsystem: "com.kerwan.app", category: "BillingEngine")

    // MARK: - Dependencies

    private let client:     OllamaClient
    private let storage:    any BillingEngineStorage
    private let clustering: SessionClusteringEngine

    // MARK: - Init

    /// Creates a `BillingEngine`.
    ///
    /// - Parameters:
    ///   - client: A configured ``OllamaClient`` for narrative generation.
    ///   - storage: A ``BillingEngineStorage``-conforming actor.
    ///   - clustering: The clustering engine (default: ``SessionClusteringEngine()``).
    public init(
        client:     OllamaClient,
        storage:    any BillingEngineStorage,
        clustering: SessionClusteringEngine = SessionClusteringEngine()
    ) {
        self.client     = client
        self.storage    = storage
        self.clustering = clustering
    }

    // MARK: - Public: Clustering

    /// Fetches recent classified events, clusters them into work sessions, and
    /// persists new sessions to storage.
    ///
    /// - Throws: If the initial `listClassifiedEvents` call fails; per-session
    ///   insert failures are logged and silently skipped.
    public func runDailyClustering() async throws {
        let since  = Date(timeIntervalSinceNow: -Self.clusteringLookBack)
        let events = try await storage.listClassifiedEvents(since: since)

        guard !events.isEmpty else {
            Self.logger.info("No classified events in look-back window — skipping clustering")
            return
        }

        let candidates = clustering.cluster(events: events)
        Self.logger.info(
            "Clustering: \(candidates.count) session(s) from \(events.count) event(s)"
        )

        for candidate in candidates {
            let session = WorkSession(
                clientId:       candidate.clientId,
                projectId:      candidate.projectId,
                startedAt:      candidate.startedAt,
                endedAt:        candidate.endedAt,
                durationSecs:   candidate.activeDurationSecs,
                billableStatus: candidate.billableStatus,
                confidence:     candidate.confidence
            )
            do {
                try await storage.insertWorkSession(session)
            } catch {
                Self.logger.error(
                    "Failed to insert work session \(session.id, privacy: .public): \(error, privacy: .public)"
                )
            }
        }
    }

    // MARK: - Public: Narrative Generation

    /// Generates AI descriptions and invoice-ready text for each session
    /// and persists the results via storage.
    ///
    /// - Parameter sessions: The work sessions to annotate. Typically the
    ///   subset that the user has reviewed and confirmed.
    /// - Throws: Never at the per-session level; individual failures are logged.
    public func runNarrativeGeneration(for sessions: [WorkSession]) async throws {
        guard !sessions.isEmpty else { return }
        Self.logger.info("Generating narratives for \(sessions.count) session(s)")

        for session in sessions {
            do {
                let prompt = Self.narrativePrompt(for: session)
                let raw    = try await client.complete(
                    prompt: prompt,
                    system: Self.narrativeSystemPrompt,
                    model:  Self.narrativeModel
                )
                let (description, invoiceText) = Self.parseNarrative(raw)
                try await storage.updateWorkSession(
                    id:          session.id,
                    description: description,
                    invoiceText: invoiceText
                )
            } catch {
                Self.logger.error(
                    "Narrative generation failed for \(session.id, privacy: .public): \(error, privacy: .public)"
                )
            }
        }
    }

    // MARK: - Private: Prompt builders

    private static let narrativeSystemPrompt = """
        You produce concise work session descriptions for a freelancer's billing system. \
        Respond with exactly two lines and nothing else:
        Line 1: A 1-sentence description of what was done (≤120 chars).
        Line 2: Invoice-ready text suitable for a client invoice (≤80 chars).
        """

    private static func narrativePrompt(for session: WorkSession) -> String {
        let hours  = String(format: "%.2f", session.durationHours)
        let status = session.billableStatus.rawValue
        let client = session.clientId ?? "unknown client"
        return """
        Work session: \(hours) hours, billing status: \(status), client: \(client).
        Generate a short work log description (line 1) and a matching invoice line item (line 2).
        """
    }

    /// Splits the two-line LLM response into `(description, invoiceText)`.
    ///
    /// Falls back gracefully when the model returns only one line.
    private static func parseNarrative(_ raw: String) -> (String?, String?) {
        let lines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (lines.first, lines.count >= 2 ? lines[1] : nil)
    }
}
