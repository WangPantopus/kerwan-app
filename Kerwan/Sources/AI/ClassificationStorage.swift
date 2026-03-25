import Foundation

/// The subset of storage operations required by the classification pipeline.
///
/// ``ClassificationActor`` depends on this protocol rather than directly on a concrete
/// `StorageActor` implementation. This decouples the two workstreams and makes the
/// classification layer fully testable with a lightweight in-memory mock.
///
/// Implementors must be `Actor`-isolated to guarantee the serialised, single-writer
/// guarantees that SQLite (via `StorageActor`) requires.
public protocol ClassificationStorage: Actor {

    // MARK: - Contact Operations

    /// Looks up a contact by exact (case-insensitive) email address.
    func findContact(byEmail email: String) async throws -> Contact?

    /// Looks up a contact by normalised display name.
    ///
    /// Normalisation: trimmed, lowercased. If multiple contacts share the same
    /// normalised name the most recently seen is returned.
    func findContact(byName name: String) async throws -> Contact?

    /// Inserts a new contact or replaces an existing one by `id`.
    func upsertContact(_ contact: Contact) async throws

    // MARK: - Client Operations

    /// Returns all client records. Used by the pipeline for fuzzy client matching.
    func listClients() async throws -> [Client]

    // MARK: - Write Operations

    /// Inserts a new interaction record. The caller is responsible for generating the `id`.
    func insertInteraction(_ interaction: Interaction) async throws

    /// Inserts a promise record extracted from a classified event.
    func insertPromise(_ promise: Promise) async throws

    /// Stores a 768-dimension nomic-embed-text embedding for an interaction.
    ///
    /// The vector is persisted in the `vec_interactions` virtual table alongside
    /// `interaction_id` for later retrieval by the semantic search engine.
    func storeInteractionEmbedding(interactionId: EntityID, vector: [Float]) async throws
}
