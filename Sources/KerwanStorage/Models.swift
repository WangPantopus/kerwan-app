import Foundation

// MARK: - Contact

/// A person tracked in Kerwan's relationship memory.
public struct Contact: Sendable, Equatable, Identifiable {
    public let id: String
    public var displayName: String
    public var emailPrimary: String
    public var company: String?
    public var jobTitle: String?
    public var notes: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        emailPrimary: String,
        company: String? = nil,
        jobTitle: String? = nil,
        notes: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.displayName = displayName
        self.emailPrimary = emailPrimary
        self.company = company
        self.jobTitle = jobTitle
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - ContactIdentity

/// A platform-specific handle belonging to a Contact (Slack ID, LinkedIn URL, etc.).
public struct ContactIdentity: Sendable, Equatable, Identifiable {
    public enum Platform: String, Sendable, CaseIterable, Codable {
        case email, slack, linkedin, twitter, github, phone, zoom, teams, other
    }

    public let id: String
    public let contactId: String
    public var platform: Platform
    public var platformId: String
    public var displayName: String?

    public init(
        id: String = UUID().uuidString,
        contactId: String,
        platform: Platform,
        platformId: String,
        displayName: String? = nil
    ) {
        self.id = id
        self.contactId = contactId
        self.platform = platform
        self.platformId = platformId
        self.displayName = displayName
    }
}

// MARK: - Client

/// A billing client. Contacts belong to clients via client_contacts.
public struct Client: Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var domain: String?
    public var invoicePrefix: String?
    public var hourlyRate: Double?
    public var currency: String
    public var notes: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        domain: String? = nil,
        invoicePrefix: String? = nil,
        hourlyRate: Double? = nil,
        currency: String = "USD",
        notes: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.domain = domain
        self.invoicePrefix = invoicePrefix
        self.hourlyRate = hourlyRate
        self.currency = currency
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - ClientContact

/// Join table: which contacts belong to which client.
public struct ClientContact: Sendable, Equatable {
    public let clientId: String
    public let contactId: String
    public var role: String?

    public init(clientId: String, contactId: String, role: String? = nil) {
        self.clientId = clientId
        self.contactId = contactId
        self.role = role
    }
}

// MARK: - Project

/// A billable project under a client.
public struct Project: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, CaseIterable, Codable {
        case active, archived, completed
    }

    public let id: String
    public let clientId: String
    public var name: String
    public var code: String?
    public var status: Status
    public var budget: Double?
    public var notes: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        clientId: String,
        name: String,
        code: String? = nil,
        status: Status = .active,
        budget: Double? = nil,
        notes: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.clientId = clientId
        self.name = name
        self.code = code
        self.status = status
        self.budget = budget
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - RawEvent

/// A single captured activity event from any source.
public struct RawEvent: Sendable, Equatable, Identifiable {
    public enum Source: String, Sendable, CaseIterable, Codable {
        case screenCapture, audioTranscription, calendarEvent
        case emailCapture, browserHistory, documentAccess, windowFocus
    }

    public let id: String
    public var sessionId: String?
    public var timestamp: Date
    public var source: Source
    public var sourceApp: String?
    public var windowTitle: String?
    public var url: String?
    public var duration: Double
    /// JSON blob for source-specific metadata.
    public var metadata: String?
    /// JSON array of email addresses extracted from this event.
    public var emails: String?

    public init(
        id: String = UUID().uuidString,
        sessionId: String? = nil,
        timestamp: Date = .now,
        source: Source,
        sourceApp: String? = nil,
        windowTitle: String? = nil,
        url: String? = nil,
        duration: Double = 0,
        metadata: String? = nil,
        emails: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.source = source
        self.sourceApp = sourceApp
        self.windowTitle = windowTitle
        self.url = url
        self.duration = duration
        self.metadata = metadata
        self.emails = emails
    }
}

// MARK: - Interaction

/// A classified, meaningful interaction (email, meeting, call, etc.).
public struct Interaction: Sendable, Equatable, Identifiable {
    public enum InteractionType: String, Sendable, CaseIterable, Codable {
        case email, meeting, call, message, document, codeReview, other
    }

    public enum Sentiment: String, Sendable, CaseIterable, Codable {
        case positive, neutral, negative, unknown
    }

    public let id: String
    public var contactId: String?
    public var clientId: String?
    public var projectId: String?
    public var type: InteractionType
    public var subject: String?
    public var body: String?
    public var summary: String?
    public var sentiment: Sentiment
    public var startedAt: Date
    public var endedAt: Date?
    public var source: String
    public var metadata: String?

    public init(
        id: String = UUID().uuidString,
        contactId: String? = nil,
        clientId: String? = nil,
        projectId: String? = nil,
        type: InteractionType,
        subject: String? = nil,
        body: String? = nil,
        summary: String? = nil,
        sentiment: Sentiment = .unknown,
        startedAt: Date = .now,
        endedAt: Date? = nil,
        source: String,
        metadata: String? = nil
    ) {
        self.id = id
        self.contactId = contactId
        self.clientId = clientId
        self.projectId = projectId
        self.type = type
        self.subject = subject
        self.body = body
        self.summary = summary
        self.sentiment = sentiment
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.metadata = metadata
    }
}

// MARK: - Promise

/// A commitment extracted from an interaction.
public struct Promise: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, CaseIterable, Codable {
        case open, fulfilled, dismissed
    }

    public let id: String
    public var contactId: String?
    public var clientId: String?
    public var interactionId: String?
    public var text: String
    public var dueDate: Date?
    public var status: Status
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        contactId: String? = nil,
        clientId: String? = nil,
        interactionId: String? = nil,
        text: String,
        dueDate: Date? = nil,
        status: Status = .open,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.contactId = contactId
        self.clientId = clientId
        self.interactionId = interactionId
        self.text = text
        self.dueDate = dueDate
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - WorkSession

/// A proposed or confirmed billable work session.
public struct WorkSession: Sendable, Equatable, Identifiable {
    public enum BillableStatus: String, Sendable, CaseIterable, Codable {
        case billable, nonBillable, undecided
    }

    public let id: String
    public var clientId: String?
    public var projectId: String?
    public var startedAt: Date
    public var endedAt: Date
    public var durationSeconds: Double
    public var autoTitle: String?
    public var invoiceText: String?
    public var billable: BillableStatus
    public var reviewed: Bool
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        clientId: String? = nil,
        projectId: String? = nil,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: Double,
        autoTitle: String? = nil,
        invoiceText: String? = nil,
        billable: BillableStatus = .undecided,
        reviewed: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.clientId = clientId
        self.projectId = projectId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.autoTitle = autoTitle
        self.invoiceText = invoiceText
        self.billable = billable
        self.reviewed = reviewed
        self.createdAt = createdAt
    }
}

// MARK: - ExclusionRule

/// A rule that prevents capture of matching events.
public struct ExclusionRule: Sendable, Equatable, Identifiable {
    public enum RuleType: String, Sendable, CaseIterable, Codable {
        case app, domain, contact, windowTitleRegex
    }

    public let id: String
    public var type: RuleType
    public var value: String
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        type: RuleType,
        value: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.type = type
        self.value = value
        self.createdAt = createdAt
    }
}

// MARK: - CapturePause

/// A time range during which capture was paused by the user.
public struct CapturePause: Sendable, Equatable, Identifiable {
    public let id: String
    public var startedAt: Date
    public var endedAt: Date?
    public var reason: String?

    public init(
        id: String = UUID().uuidString,
        startedAt: Date = .now,
        endedAt: Date? = nil,
        reason: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.reason = reason
    }
}

// MARK: - UserSettings

/// Flat key-value settings hydrated from the user_settings table.
public struct UserSettings: Sendable {
    public var schemaVersion: Int
    public var captureEnabled: Bool
    public var audioEnabled: Bool
    public var whisperModel: String
    public var ollamaModel: String
    public var embedModel: String
    public var reviewReminderDays: Int
    public var defaultCurrency: String
    public var onboardingCompleted: Bool

    public init(
        schemaVersion: Int = 1,
        captureEnabled: Bool = true,
        audioEnabled: Bool = false,
        whisperModel: String = "base",
        ollamaModel: String = "llama3:8b",
        embedModel: String = "nomic-embed-text",
        reviewReminderDays: Int = 7,
        defaultCurrency: String = "USD",
        onboardingCompleted: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.captureEnabled = captureEnabled
        self.audioEnabled = audioEnabled
        self.whisperModel = whisperModel
        self.ollamaModel = ollamaModel
        self.embedModel = embedModel
        self.reviewReminderDays = reviewReminderDays
        self.defaultCurrency = defaultCurrency
        self.onboardingCompleted = onboardingCompleted
    }
}

// MARK: - SearchResult

/// A unified result from FTS5 keyword search or vector similarity search.
public struct SearchResult: Sendable {
    public enum ResultType: String, Sendable {
        case interaction, contact, workSession
    }

    public let id: String
    public let type: ResultType
    public let title: String
    public let snippet: String
    public let score: Double
    public let timestamp: Date

    public init(
        id: String,
        type: ResultType,
        title: String,
        snippet: String,
        score: Double,
        timestamp: Date
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.snippet = snippet
        self.score = score
        self.timestamp = timestamp
    }
}
