import Foundation

/// A commitment extracted from an interaction — something the user or a contact
/// promised to do.
///
/// The classification pipeline scans meeting transcripts and emails for language
/// like "I'll send that over by Friday" or "Can you review the proposal?". Each
/// detected commitment becomes a `Promise` record linked to its source interaction.
///
/// Promises surface in the dashboard as action items. The user can mark them
/// done, snooze them, or dismiss false positives. Overdue promises trigger
/// notifications via the daily digest.
public struct Promise: Codable, Sendable, Identifiable, Hashable {
    public static func == (lhs: Promise, rhs: Promise) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    /// Unique identifier (UUID string).
    public let id: EntityID

    /// The ``Interaction/id`` from which this promise was extracted.
    public var interactionId: EntityID?

    /// The ``Contact/id`` who made or received the promise.
    public var contactId: EntityID?

    /// The ``Client/id`` this promise relates to, if attributable.
    public var clientId: EntityID?

    /// Who made the commitment.
    public let direction: PromiseDirection

    /// Human-readable description of the commitment
    /// (e.g., "Send revised proposal by end of week").
    public var description: String

    /// The deadline extracted from the conversation, if any.
    public var dueDate: Date?

    /// Current status of this promise.
    public var status: PromiseStatus

    /// The original quote from the transcript or email that triggered extraction
    /// (e.g., "I'll have the mockups ready by Thursday").
    public var sourceQuote: String?

    /// When the classification pipeline extracted this promise.
    public let extractedAt: Date

    /// When the user marked this promise as done or dismissed.
    public var resolvedAt: Date?

    public init(
        id: EntityID = UUID().uuidString,
        interactionId: EntityID? = nil,
        contactId: EntityID? = nil,
        clientId: EntityID? = nil,
        direction: PromiseDirection,
        description: String,
        dueDate: Date? = nil,
        status: PromiseStatus = .open,
        sourceQuote: String? = nil,
        extractedAt: Date = Date(),
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.interactionId = interactionId
        self.contactId = contactId
        self.clientId = clientId
        self.direction = direction
        self.description = description
        self.dueDate = dueDate
        self.status = status
        self.sourceQuote = sourceQuote
        self.extractedAt = extractedAt
        self.resolvedAt = resolvedAt
    }

    /// Whether this promise is past its due date and still open.
    public var isOverdue: Bool {
        guard let dueDate, status == .open else { return false }
        return dueDate < Date()
    }
}

/// Who made the commitment.
public enum PromiseDirection: String, Codable, Sendable, CaseIterable {
    /// The user committed to do something for a contact.
    case userPromised
    /// A contact committed to do something for the user.
    case contactPromised
}

/// Lifecycle status of a promise.
public enum PromiseStatus: String, Codable, Sendable, CaseIterable {
    /// Active and not yet fulfilled.
    case open
    /// Marked as completed.
    case done
    /// Temporarily deferred by the user.
    case snoozed
    /// Dismissed as a false positive or no longer relevant.
    case dismissed
}
