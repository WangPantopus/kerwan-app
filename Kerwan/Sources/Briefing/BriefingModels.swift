import Foundation

// MARK: - CalendarEventBrief

/// A lightweight representation of an upcoming calendar event, posted in the
/// `.kerwanPreCallBriefingNeeded` notification by `CalendarCaptureService`
/// 2 minutes before the event starts.
public struct CalendarEventBrief: Codable, Sendable, Identifiable {
    /// The EventKit `eventIdentifier` for deduplication.
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    /// Attendee email addresses extracted from `EKParticipant`.
    public let attendeeEmails: [String]
    /// Attendee display names in the same order as `attendeeEmails`.
    public let attendeeNames: [String]
    public let location: String?

    public init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        attendeeEmails: [String],
        attendeeNames: [String],
        location: String? = nil
    ) {
        self.id             = id
        self.title          = title
        self.startDate      = startDate
        self.endDate        = endDate
        self.attendeeEmails = attendeeEmails
        self.attendeeNames  = attendeeNames
        self.location       = location
    }
}

// MARK: - AttendeeContext

/// Per-attendee context assembled from storage for a briefing.
public struct AttendeeContext: Sendable, Identifiable {
    public let contact: Contact
    /// Up to 5 most-recent interactions with this contact.
    public let recentInteractions: [Interaction]
    /// Open (unresolved) promises with this contact.
    public let openPromises: [Promise]

    public var id: String { contact.id }
    public var openItemCount: Int { openPromises.count }
    public var lastInteractionSummary: String? { recentInteractions.first?.summary }
    public var lastInteractionDate: Date? { recentInteractions.first?.startedAt }

    public init(contact: Contact, recentInteractions: [Interaction], openPromises: [Promise]) {
        self.contact            = contact
        self.recentInteractions = recentInteractions
        self.openPromises       = openPromises
    }
}

// MARK: - PreCallBriefing

/// The complete briefing delivered to the panel and UI layer.
public struct PreCallBriefing: Sendable, Identifiable {
    public let id: String
    public let event: CalendarEventBrief
    public let attendees: [AttendeeContext]
    /// LLM-generated or fallback bullet points (3–7 items).
    public let bulletPoints: [String]
    public let generatedAt: Date

    public init(
        id: String = UUID().uuidString,
        event: CalendarEventBrief,
        attendees: [AttendeeContext],
        bulletPoints: [String],
        generatedAt: Date = Date()
    ) {
        self.id           = id
        self.event        = event
        self.attendees    = attendees
        self.bulletPoints = bulletPoints
        self.generatedAt  = generatedAt
    }
}

// MARK: - Notification infrastructure

/// Keys for `userInfo` dictionaries on briefing notifications.
enum BriefingNotificationKey {
    /// `CalendarEventBrief` value in `.kerwanPreCallBriefingNeeded` userInfo.
    static let brief    = "com.kerwan.briefing.brief"
    /// `PreCallBriefing` value in `.kerwanBriefingReady` userInfo.
    static let briefing = "com.kerwan.briefing.result"
    /// UNNotificationCategory identifier for briefing notifications.
    static let category = "KERWAN_BRIEFING"
}

extension Notification.Name {
    /// Posted by `CalendarCaptureService` 2 minutes before a calendar event.
    ///
    /// `userInfo[BriefingNotificationKey.brief]` = `CalendarEventBrief`
    static let kerwanPreCallBriefingNeeded = Notification.Name("com.kerwan.app.preCallBriefingNeeded")

    /// Posted by `BriefingScheduler` when a briefing is ready for the panel.
    ///
    /// `userInfo[BriefingNotificationKey.briefing]` = `PreCallBriefing`
    static let kerwanBriefingReady = Notification.Name("com.kerwan.app.briefingReady")
}

extension Notification {
    /// Extracts the `CalendarEventBrief` from a `.kerwanPreCallBriefingNeeded` notification.
    var calendarEventBrief: CalendarEventBrief? {
        userInfo?[BriefingNotificationKey.brief] as? CalendarEventBrief
    }
}
