import Foundation

/// A classified interaction between the user and one or more contacts.
///
/// Interactions are the primary building blocks of client timelines. They are
/// produced by the classification pipeline from one or more ``RawEvent`` records.
/// For example, a 30-minute Zoom call (audio raw event) becomes a single
/// interaction of type `.meeting`, attributed to the detected contacts and client.
///
/// Interactions carry an AI-generated ``summary``, ``sentiment``, and
/// ``importance`` score. They also hold extracted ``contentTags`` for
/// topic-based filtering and search.
///
/// Interactions with ``isReviewed`` = false were auto-classified and may
/// need user confirmation of contact/client attribution.
public struct Interaction: Codable, Sendable, Identifiable, Hashable {
    /// Unique identifier (UUID string).
    public let id: EntityID

    /// The primary ``Contact/id`` involved, if identified.
    public var contactId: EntityID?

    /// The ``Client/id`` this interaction is attributed to, if known.
    public var clientId: EntityID?

    /// The ``Project/id`` this interaction is attributed to, if known.
    public var projectId: EntityID?

    /// The capture source that originated this interaction.
    public let source: EventSource

    /// The classified type of interaction.
    public let interactionType: InteractionType

    /// When this interaction started.
    public let startedAt: Date

    /// When this interaction ended. Nil for point-in-time interactions
    /// (e.g., a single email).
    public var endedAt: Date?

    /// AI-generated one-line summary of the interaction content.
    public var summary: String?

    /// Overall sentiment of the interaction as classified by the LLM.
    public var sentiment: Sentiment

    /// Importance score from 0.0 (routine) to 1.0 (critical).
    /// Used for timeline prioritization and notification thresholds.
    public var importance: Double

    /// Topic tags extracted by the classification pipeline
    /// (e.g., ["pricing", "contract", "Q2 deliverables"]).
    public var contentTags: [String]

    /// Whether the user has reviewed and confirmed this interaction's
    /// classification (contact, client, type, summary).
    public var isReviewed: Bool

    public init(
        id: EntityID = UUID().uuidString,
        contactId: EntityID? = nil,
        clientId: EntityID? = nil,
        projectId: EntityID? = nil,
        source: EventSource,
        interactionType: InteractionType,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        summary: String? = nil,
        sentiment: Sentiment = .neutral,
        importance: Double = 0.5,
        contentTags: [String] = [],
        isReviewed: Bool = false
    ) {
        self.id = id
        self.contactId = contactId
        self.clientId = clientId
        self.projectId = projectId
        self.source = source
        self.interactionType = interactionType
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.summary = summary
        self.sentiment = sentiment
        self.importance = max(0.0, min(1.0, importance))
        self.contentTags = contentTags
        self.isReviewed = isReviewed
    }
}

/// The classified type of an interaction.
public enum InteractionType: String, Codable, Sendable, CaseIterable {
    /// A real-time meeting (Zoom, Teams, in-person with mic).
    case meeting
    /// An email sent by the user.
    case emailSent
    /// An email received by the user.
    case emailReceived
    /// A Slack direct message exchange.
    case slackDM
    /// A phone or VoIP call.
    case phoneCalled
    /// Detected application activity related to a client/project
    /// (e.g., working in Figma on a client's design file).
    case appActivity
}

/// Sentiment classification for an interaction.
public enum Sentiment: String, Codable, Sendable, CaseIterable {
    /// Predominantly positive tone (agreement, praise, enthusiasm).
    case positive
    /// Neutral or informational tone.
    case neutral
    /// Predominantly negative tone (disagreement, complaints, frustration).
    case negative
    /// Mixed signals — both positive and negative elements detected.
    case mixed
}
