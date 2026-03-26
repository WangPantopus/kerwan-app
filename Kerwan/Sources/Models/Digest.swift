import Foundation

/// A generated summary record — either a daily or weekly digest.
///
/// `Digest` records are produced by `DigestGenerator`, persisted to the database,
/// and retrieved by `TodayView`. The structured stats fields allow the UI to render
/// rich cards without re-running the storage queries.
public struct Digest: Codable, Sendable, Identifiable, Hashable {
    public static func == (lhs: Digest, rhs: Digest) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    /// Unique identifier (UUID string).
    public let id: EntityID

    /// Whether this is a daily or weekly digest.
    public let kind: DigestKind

    /// When this digest was generated.
    public let generatedAt: Date

    /// Short title shown in the notification banner and Today card header.
    /// Example: "Morning Digest · Mon Mar 24"
    public let title: String

    /// AI-generated (or template) 2–3 sentence narrative.
    public let bodyText: String

    // MARK: Daily stats (always populated)

    /// Meetings that occurred yesterday.
    public let meetingCount: Int

    /// Emails (sent + received) yesterday.
    public let emailCount: Int

    /// Slack messages yesterday.
    public let slackCount: Int

    /// Open promises at time of generation.
    public let openPromiseCount: Int

    /// Work sessions with `.suggested` status at time of generation.
    public let unreviewedSessionCount: Int

    /// Display names of contacts not interacted with in 7+ days.
    public let quietContactNames: [String]

    // MARK: Weekly stats (nil for daily digests)

    /// Total hours tracked across all work sessions this week.
    public let totalHoursTracked: Double?

    /// Estimated billable hours confirmed this week.
    public let estimatedBillableHours: Double?

    /// Sessions moved to `.confirmed` this week.
    public let sessionsReviewedCount: Int?

    /// Sessions still in `.suggested` state at generation time.
    public let sessionsPendingCount: Int?

    /// Estimated billable hours from the prior week (for comparison).
    public let priorWeekBillableHours: Double?

    public init(
        id: EntityID = UUID().uuidString,
        kind: DigestKind,
        generatedAt: Date = Date(),
        title: String,
        bodyText: String,
        meetingCount: Int = 0,
        emailCount: Int = 0,
        slackCount: Int = 0,
        openPromiseCount: Int = 0,
        unreviewedSessionCount: Int = 0,
        quietContactNames: [String] = [],
        totalHoursTracked: Double? = nil,
        estimatedBillableHours: Double? = nil,
        sessionsReviewedCount: Int? = nil,
        sessionsPendingCount: Int? = nil,
        priorWeekBillableHours: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.generatedAt = generatedAt
        self.title = title
        self.bodyText = bodyText
        self.meetingCount = meetingCount
        self.emailCount = emailCount
        self.slackCount = slackCount
        self.openPromiseCount = openPromiseCount
        self.unreviewedSessionCount = unreviewedSessionCount
        self.quietContactNames = quietContactNames
        self.totalHoursTracked = totalHoursTracked
        self.estimatedBillableHours = estimatedBillableHours
        self.sessionsReviewedCount = sessionsReviewedCount
        self.sessionsPendingCount = sessionsPendingCount
        self.priorWeekBillableHours = priorWeekBillableHours
    }
}

/// Whether a digest covers a single day or a full week.
public enum DigestKind: String, Codable, Sendable, CaseIterable {
    case daily
    case weekly
}
