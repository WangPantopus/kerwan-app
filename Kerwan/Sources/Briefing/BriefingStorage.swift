import Foundation

/// Storage operations required by ``BriefingScheduler``.
///
/// `StorageActor` will conform to this protocol when the KerwanStorage
/// workstream wires it in. Until then, `BriefingScheduler` holds `nil`
/// and gracefully degrades to Ollama-only briefings with no history context.
protocol BriefingStorage: Actor {
    /// Returns the contact whose `emailPrimary` matches `email` (case-insensitive),
    /// or `nil` if not found.
    func findContact(byEmail email: String) async throws -> Contact?

    /// Returns the first contact whose `displayName` matches `name` (case-insensitive),
    /// or `nil` if not found.
    func findContact(byName name: String) async throws -> Contact?

    /// Inserts or updates a contact record.
    func upsertContact(_ contact: Contact) async throws

    /// Returns up to `limit` interactions for `contactId`, sorted newest-first.
    func fetchRecentInteractions(contactId: EntityID, limit: Int) async throws -> [Interaction]

    /// Returns all open (status == `.open`) promises for `contactId`.
    func fetchOpenPromises(contactId: EntityID) async throws -> [Promise]

    /// Returns all raw events with the given `source` whose `startedAt` falls
    /// in the half-open interval `[from, to)`.
    func fetchRawEvents(from: Date, to: Date, source: EventSource) async throws -> [RawEvent]

    /// Inserts a new interaction record.
    func insertInteraction(_ interaction: Interaction) async throws
}
