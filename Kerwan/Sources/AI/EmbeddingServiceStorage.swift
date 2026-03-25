import Foundation

/// The subset of storage operations required by the embedding pipeline.
///
/// ``EmbeddingService`` depends on this protocol rather than the concrete `StorageActor`
/// so the embedding layer remains fully testable with an in-memory mock and decoupled
/// from the storage workstream.
///
/// The three storage families below map to three separate vector tables:
/// - `vec_interactions` — one or more embeddings per ``Interaction``
/// - `vec_raw_events` — per-chunk embeddings for emails, transcripts, and manual notes
/// - `vec_promises` — one embedding per ``Promise`` description
///
/// Implementors must be `Actor`-isolated to preserve the serialised, single-writer
/// guarantee required by SQLite.
public protocol EmbeddingServiceStorage: Actor {

    // MARK: - Interaction Embeddings

    /// Returns ``Interaction`` records that have no entry yet in `vec_interactions`.
    ///
    /// Implements:
    /// ```sql
    /// SELECT * FROM interactions
    ///  WHERE id NOT IN (SELECT DISTINCT interaction_id FROM vec_interactions)
    /// ```
    func listUnembeddedInteractions() async throws -> [Interaction]

    /// Stores a 768-dimension nomic-embed-text embedding for an interaction.
    ///
    /// The vector is inserted into `vec_interactions`. Multiple calls for the same
    /// `interactionId` are allowed — each corresponds to a separate content chunk
    /// (e.g., consecutive 500-token windows of a long meeting transcript).
    func insertVectorEmbedding(interactionId: EntityID, embedding: [Float]) async throws

    // MARK: - Raw Event Embeddings

    /// Returns ``RawEvent`` records of the given `sources` that have no entry in
    /// `vec_raw_events`.
    ///
    /// Implements:
    /// ```sql
    /// SELECT * FROM raw_events
    ///  WHERE source IN (?) AND id NOT IN (SELECT DISTINCT raw_event_id FROM vec_raw_events)
    /// ```
    func listUnembeddedRawEvents(sources: [EventSource]) async throws -> [RawEvent]

    /// Stores a chunk embedding for a raw event.
    ///
    /// `chunkIndex` is 0 for single-chunk events (emails, manual notes) and 0…n for
    /// multi-chunk audio transcripts. The primary key in `vec_raw_events` is
    /// `(raw_event_id, chunk_index)`.
    func insertRawEventEmbedding(rawEventId: EntityID, chunkIndex: Int, embedding: [Float]) async throws

    // MARK: - Promise Embeddings

    /// Returns ``Promise`` records that have no entry in `vec_promises`.
    ///
    /// Implements:
    /// ```sql
    /// SELECT * FROM promises
    ///  WHERE id NOT IN (SELECT promise_id FROM vec_promises)
    /// ```
    func listUnembeddedPromises() async throws -> [Promise]

    /// Stores a 768-dimension embedding for a promise description.
    func insertPromiseEmbedding(promiseId: EntityID, embedding: [Float]) async throws
}
