import Foundation

/// A billable client or organization that the user works with.
///
/// Clients are the top-level billing entity. Each client can have multiple
/// ``Project`` records, and interactions/work sessions are attributed to a
/// client (optionally via a project) for billing and timeline purposes.
///
/// Unlike ``Contact`` (which is auto-created by the AI pipeline), clients
/// are typically created manually by the user, though the system may suggest
/// client creation when it detects repeated interactions with contacts from
/// the same company domain.
public struct Client: Codable, Sendable, Identifiable, Hashable {
    /// Unique identifier (UUID string).
    public let id: EntityID

    /// Display name of the client or organization (e.g., "Acme Corp").
    public var name: String

    /// Primary email domain associated with this client (e.g., "acme.com").
    /// Used by the classification pipeline to auto-attribute interactions.
    public var domain: String?

    /// Free-form notes about this client.
    public var notes: String?

    /// When this client record was created.
    public let createdAt: Date

    /// When this client record was last modified.
    public var updatedAt: Date

    public init(
        id: EntityID = UUID().uuidString,
        name: String,
        domain: String? = nil,
        notes: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.domain = domain
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
