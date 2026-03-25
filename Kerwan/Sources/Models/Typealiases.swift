import Foundation

/// A string-based entity identifier used throughout Kerwan's domain model.
///
/// All entities use opaque string IDs (typically UUIDs) rather than integer
/// auto-increment keys. This avoids coupling to database row ordering and
/// simplifies merge/sync scenarios if ever needed.
public typealias EntityID = String
