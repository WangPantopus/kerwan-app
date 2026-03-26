import Foundation

/// A contiguous block of work attributed to a client, suitable for billing.
///
/// Work sessions are produced by the billing engine, which clusters nearby
/// interactions and app activity into coherent work blocks. For example,
/// a 45-minute Zoom call followed by 20 minutes of Figma work for the same
/// client becomes a single 65-minute work session.
///
/// Sessions start as ``BillableStatus/suggested`` and appear in the billing
/// review queue. The user can confirm, reject, or edit them before export.
/// Confirmed sessions can have ``invoiceText`` set for direct inclusion
/// in client invoices.
public struct WorkSession: Codable, Sendable, Identifiable, Hashable {
    public static func == (lhs: WorkSession, rhs: WorkSession) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    /// Unique identifier (UUID string).
    public let id: EntityID

    /// The ``Client/id`` this session is billed to, if attributed.
    public var clientId: EntityID?

    /// The ``Project/id`` this session is associated with, if known.
    public var projectId: EntityID?

    /// When this work session started.
    public let startedAt: Date

    /// When this work session ended.
    public let endedAt: Date

    /// Total duration in seconds.
    public let durationSecs: Int

    /// The billing status of this session.
    public var billableStatus: BillableStatus

    /// The clustering engine's confidence that this session is correctly
    /// grouped and attributed (0.0–1.0).
    public var confidence: Double

    /// A human-readable description of what was done during this session
    /// (e.g., "Zoom call discussing Q2 roadmap, then Figma mockup revisions").
    public var description: String?

    /// Formatted text suitable for inclusion on a client invoice
    /// (e.g., "Design review and mockup revisions — 1.5 hrs").
    public var invoiceText: String?

    /// When the user reviewed this session in the billing queue. Nil if unreviewed.
    public var reviewedAt: Date?

    /// Duration expressed in fractional hours, rounded to two decimal places.
    public var durationHours: Double {
        (Double(durationSecs) / 3600.0 * 100).rounded() / 100
    }

    public init(
        id: EntityID = UUID().uuidString,
        clientId: EntityID? = nil,
        projectId: EntityID? = nil,
        startedAt: Date,
        endedAt: Date,
        durationSecs: Int,
        billableStatus: BillableStatus = .suggested,
        confidence: Double = 0.5,
        description: String? = nil,
        invoiceText: String? = nil,
        reviewedAt: Date? = nil
    ) {
        self.id = id
        self.clientId = clientId
        self.projectId = projectId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSecs = durationSecs
        self.billableStatus = billableStatus
        self.confidence = max(0.0, min(1.0, confidence))
        self.description = description
        self.invoiceText = invoiceText
        self.reviewedAt = reviewedAt
    }
}

/// The billing lifecycle status of a work session.
public enum BillableStatus: String, Codable, Sendable, CaseIterable {
    /// Auto-suggested by the clustering engine; awaiting user review.
    case suggested
    /// Confirmed as billable by the user.
    case confirmed
    /// Rejected by the user (not billable).
    case rejected
    /// Marked as non-billable work (internal, admin, etc.).
    case nonBillable
}
