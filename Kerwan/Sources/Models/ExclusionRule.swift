import Foundation

/// A user-defined rule that excludes certain activity from capture and classification.
///
/// Exclusion rules let the user protect privacy by filtering out specific apps,
/// domains, contacts, or window titles. When a ``RawEvent`` matches any active
/// exclusion rule, it is marked ``RawEvent/isExcluded`` and skipped by the
/// classification pipeline.
///
/// Examples:
/// - Exclude the "1Password" app from app-focus tracking
/// - Exclude "*.personal.com" domains from browser capture
/// - Exclude window titles matching "Private.*" regex
public struct ExclusionRule: Codable, Sendable, Identifiable, Hashable {
    public static func == (lhs: ExclusionRule, rhs: ExclusionRule) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    /// Unique identifier (UUID string).
    public let id: EntityID

    /// The type of entity this rule matches against.
    public let ruleType: ExclusionRuleType

    /// The matching pattern. Interpretation depends on ``ruleType``:
    /// - `.app`: exact app name or bundle identifier (e.g., "1Password")
    /// - `.domain`: domain glob pattern (e.g., "*.personal.com")
    /// - `.contact`: exact contact display name or email
    /// - `.windowTitleRegex`: a regular expression matched against window titles
    public let pattern: String

    public init(
        id: EntityID = UUID().uuidString,
        ruleType: ExclusionRuleType,
        pattern: String
    ) {
        self.id = id
        self.ruleType = ruleType
        self.pattern = pattern
    }
}

/// The type of entity an ``ExclusionRule`` matches against.
public enum ExclusionRuleType: String, Codable, Sendable, CaseIterable {
    /// Match against the application name or bundle identifier.
    case app
    /// Match against web domains (supports glob patterns).
    case domain
    /// Match against contact display name or email address.
    case contact
    /// Match window titles using a regular expression.
    case windowTitleRegex
}
