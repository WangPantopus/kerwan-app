import Foundation

/// A person Kerwan has observed the user interacting with across any channel.
///
/// Contacts are created automatically when the classification pipeline identifies
/// a person in a meeting transcript, email, Slack message, or calendar event.
/// Multiple ``ContactIdentity`` records may point to the same contact after
/// identity resolution merges duplicates.
///
/// The ``relationshipScore`` is a rolling metric (0.0–1.0) computed from
/// interaction frequency, recency, and importance. It drives the "key contacts"
/// dashboard and notification prioritization.
///
/// Contacts with ``needsReview`` set to `true` were created by the AI pipeline
/// and have not yet been confirmed by the user. The UI surfaces these in a
/// review queue.
public struct Contact: Codable, Sendable, Identifiable, Hashable {

    public static func == (lhs: Contact, rhs: Contact) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    /// Unique identifier (UUID string).
    public let id: EntityID

    /// The display name shown in the UI (e.g., "Jane Smith").
    public var displayName: String

    /// The company or organization this contact is associated with, if known.
    public var company: String?

    /// The primary email address, if known.
    public var emailPrimary: String?

    /// An AI-generated summary of the relationship with this contact
    /// (e.g., "Design lead at Acme. Discussed rebrand project in 4 meetings.").
    public var aiSummary: String?

    /// Rolling relationship score from 0.0 (dormant) to 1.0 (very active).
    /// Computed from interaction frequency, recency, and importance.
    public var relationshipScore: Double

    /// When this contact was first observed in any capture source.
    public let firstSeenAt: Date

    /// When this contact was most recently observed in any capture source.
    public var lastSeenAt: Date

    /// When this record was created in the database.
    public let createdAt: Date

    /// When this record was last modified.
    public var updatedAt: Date

    /// Whether this contact was AI-created and awaits user review.
    public var needsReview: Bool

    public init(
        id: EntityID = UUID().uuidString,
        displayName: String,
        company: String? = nil,
        emailPrimary: String? = nil,
        aiSummary: String? = nil,
        relationshipScore: Double = 0.0,
        firstSeenAt: Date = Date(),
        lastSeenAt: Date = Date(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        needsReview: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.company = company
        self.emailPrimary = emailPrimary
        self.aiSummary = aiSummary
        self.relationshipScore = max(0.0, min(1.0, relationshipScore))
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.needsReview = needsReview
    }
}
