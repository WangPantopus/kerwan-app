import Foundation

/// A record of a user-initiated identity correction — a merge, split, or manual
/// reassignment that the system can learn from to improve future resolution accuracy.
///
/// `CorrectionLog` entries are written whenever the user confirms a merge,
/// reverses an auto-merge (split), or manually overrides a contact attribution.
/// ``IdentityResolver/adjustThresholds(basedOnCorrections:)`` aggregates these
/// records to tune resolution thresholds over time.
public struct CorrectionLog: Codable, Sendable, Identifiable {
    /// Unique identifier (UUID string).
    public let id: EntityID

    /// The type of correction the user made.
    public let action: CorrectionAction

    /// The contact that was the source of a merge, or the contact being split.
    public let sourceContactId: EntityID?

    /// The target contact in a merge (the surviving record).
    public let targetContactId: EntityID?

    /// Optional JSON blob for action-specific payload
    /// (e.g., split identity IDs, threshold that triggered the bad merge).
    public let detailsJSON: String?

    /// When this correction was recorded.
    public let createdAt: Date

    public init(
        id: EntityID = UUID().uuidString,
        action: CorrectionAction,
        sourceContactId: EntityID? = nil,
        targetContactId: EntityID? = nil,
        detailsJSON: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.action = action
        self.sourceContactId = sourceContactId
        self.targetContactId = targetContactId
        self.detailsJSON = detailsJSON
        self.createdAt = createdAt
    }
}

/// The kind of correction recorded in ``CorrectionLog``.
public enum CorrectionAction: String, Codable, Sendable, CaseIterable {
    /// User confirmed that two contacts are the same person (manual merge).
    case merge
    /// User reversed a merge, splitting identities back into separate contacts.
    case split
    /// User corrected contact attribution on an interaction or identity.
    case reassign
}

// MARK: - SQL Migration

extension CorrectionLog {
    /// DDL to create the `correction_log` table.
    ///
    /// Add this string to the ordered migrations array in `StorageActor`
    /// so it runs during the next schema upgrade.
    static let createTableSQL: String = """
        CREATE TABLE IF NOT EXISTS correction_log (
            id                TEXT PRIMARY KEY,
            action            TEXT NOT NULL,
            source_contact_id TEXT,
            target_contact_id TEXT,
            details_json      TEXT,
            created_at        TEXT NOT NULL DEFAULT (datetime('now'))
        );
        """
}
