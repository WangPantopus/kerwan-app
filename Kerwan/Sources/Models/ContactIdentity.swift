import Foundation

/// A single identity (email, Slack handle, Zoom name, etc.) linked to a ``Contact``.
///
/// One person may appear under different names across platforms — "Jane Smith"
/// in email, "jsmith" on Slack, "Jane S." in Zoom. Each appearance creates a
/// `ContactIdentity` record. The identity resolution system merges identities
/// that belong to the same person into one ``Contact``, using name similarity,
/// email matching, and co-occurrence signals.
///
/// The ``confidence`` score (0.0–1.0) reflects how certain the system is that
/// this identity correctly maps to its parent contact. Low-confidence links
/// surface in the user's review queue.
public struct ContactIdentity: Codable, Sendable, Identifiable, Hashable {
    /// Unique identifier (UUID string).
    public let id: EntityID

    /// The ``Contact/id`` this identity is linked to.
    public let contactId: EntityID

    /// The platform or channel where this identity was observed.
    public let source: IdentitySource

    /// The raw identifier on that platform (email address, Slack user ID,
    /// Zoom display name, LinkedIn URL slug, calendar attendee URI).
    public let identifier: String

    /// An optional human-readable display name as it appeared on the source
    /// platform (may differ from the canonical ``Contact/displayName``).
    public var displayName: String?

    /// Confidence that this identity correctly maps to the parent contact
    /// (0.0 = uncertain, 1.0 = confirmed by user).
    public var confidence: Double

    public init(
        id: EntityID = UUID().uuidString,
        contactId: EntityID,
        source: IdentitySource,
        identifier: String,
        displayName: String? = nil,
        confidence: Double = 0.5
    ) {
        self.id = id
        self.contactId = contactId
        self.source = source
        self.identifier = identifier
        self.displayName = displayName
        self.confidence = max(0.0, min(1.0, confidence))
    }
}

/// The platform or channel from which a contact identity was observed.
public enum IdentitySource: String, Codable, Sendable, CaseIterable {
    /// Email address (from Gmail IMAP or calendar attendees).
    case email
    /// Slack workspace user.
    case slack
    /// Zoom meeting participant name.
    case zoom
    /// LinkedIn profile (from browser extension).
    case linkedin
    /// Calendar event attendee.
    case calendar
}
