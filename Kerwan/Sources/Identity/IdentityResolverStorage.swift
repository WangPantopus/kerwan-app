import Foundation

/// The subset of storage operations required by the identity resolution pipeline.
///
/// ``IdentityResolver`` depends on this protocol rather than the concrete `StorageActor`.
/// This decouples the two layers and allows the resolver to be fully tested with
/// an in-memory mock.
///
/// Implementors must be `Actor`-isolated to guarantee the serialised, single-writer
/// guarantees that SQLite (via `StorageActor`) requires.
public protocol IdentityResolverStorage: Actor {

    // MARK: - ContactIdentity

    /// Returns all ``ContactIdentity`` records whose `identifier` matches the given
    /// email address (case-insensitive).
    func findIdentities(byEmail email: String) async throws -> [ContactIdentity]

    /// Returns all ``ContactIdentity`` records linked to the given contact.
    func findIdentities(forContactId contactId: EntityID) async throws -> [ContactIdentity]

    /// Inserts or replaces a ``ContactIdentity`` record by `id`.
    func upsertIdentity(_ identity: ContactIdentity) async throws

    /// Deletes all ``ContactIdentity`` records for the given contact and source.
    func deleteIdentities(forContactId contactId: EntityID, source: IdentitySource) async throws

    // MARK: - Contact CRUD

    /// Looks up a contact by exact (case-insensitive) email address.
    ///
    /// Searches the ``Contact/emailPrimary`` field.
    func findContact(byEmail email: String) async throws -> Contact?

    /// Returns all contacts whose ``Contact/displayName`` fuzzy-matches the
    /// given normalised name string (trimmed, lowercased).
    ///
    /// The caller is responsible for applying similarity thresholds; this method
    /// returns all candidates so the resolver can rank them.
    func findContacts(byNormalisedName name: String) async throws -> [Contact]

    /// Inserts a new contact or replaces an existing one by `id`.
    func upsertContact(_ contact: Contact) async throws

    /// Deletes the contact with the given id and all of its ``ContactIdentity`` children.
    func deleteContact(id: EntityID) async throws

    // MARK: - Temporal Proximity

    /// Returns `true` when the given contact has at least one ``Interaction``
    /// within `windowSeconds` of `timestamp`.
    ///
    /// Used as a tiebreaker in Step 3 of the resolution algorithm: two contacts
    /// with similar names are more likely the same person when they have been
    /// seen in close temporal proximity.
    func contactHasInteraction(
        contactId: EntityID,
        near timestamp: Date,
        windowSeconds: Double
    ) async throws -> Bool

    // MARK: - Merge Support

    /// Reassigns all ``Interaction`` records from `sourceContactId` to `targetContactId`.
    func reassignInteractions(from sourceContactId: EntityID, to targetContactId: EntityID) async throws

    /// Reassigns all ``Promise`` records from `sourceContactId` to `targetContactId`.
    func reassignPromises(from sourceContactId: EntityID, to targetContactId: EntityID) async throws

    // MARK: - Client

    /// Returns all client records. Used for domain-based client matching.
    func listClients() async throws -> [Client]

    // MARK: - Correction Log

    /// Inserts a ``CorrectionLog`` record.
    func insertCorrectionLog(_ log: CorrectionLog) async throws

    /// Returns all correction log entries, newest first.
    func listCorrectionLogs() async throws -> [CorrectionLog]
}
