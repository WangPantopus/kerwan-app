import Foundation

/// A billable project belonging to a ``Client``.
///
/// Projects subdivide a client's work for finer-grained time tracking.
/// Each ``WorkSession`` and ``Interaction`` may optionally reference a project.
/// When generating invoices, sessions are grouped by project so the client
/// sees a per-project breakdown.
///
/// An inactive project (``isActive`` = false) no longer appears in suggestion
/// dropdowns but retains its historical data.
public struct Project: Codable, Sendable, Identifiable, Hashable {
    /// Unique identifier (UUID string).
    public let id: EntityID

    /// The ``Client/id`` this project belongs to.
    public let clientId: EntityID

    /// Display name of the project (e.g., "Website Redesign Q1").
    public var name: String

    /// Default hourly billing rate for this project, in the user's currency.
    /// When nil, falls back to ``UserSettings/billableDefaultRate``.
    public var hourlyRate: Double?

    /// Whether this project is currently active. Inactive projects are hidden
    /// from new session attribution but retain historical data.
    public var isActive: Bool

    /// When this project record was created.
    public let createdAt: Date

    public init(
        id: EntityID = UUID().uuidString,
        clientId: EntityID,
        name: String,
        hourlyRate: Double? = nil,
        isActive: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.clientId = clientId
        self.name = name
        self.hourlyRate = hourlyRate
        self.isActive = isActive
        self.createdAt = createdAt
    }
}
