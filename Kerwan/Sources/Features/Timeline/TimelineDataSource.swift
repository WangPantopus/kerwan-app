import Foundation

// MARK: - TimelineFilter

/// Serialisable filter state passed to any `TimelineDataSource`.
struct TimelineFilter: Sendable {
    var source:     TimelineSourceFilter = .all
    var clientId:   EntityID?            = nil
    var dateStart:  Date?                = nil
    var dateEnd:    Date?                = nil

    var isActive: Bool {
        source != .all || clientId != nil || dateStart != nil || dateEnd != nil
    }
}

// MARK: - TimelineSourceFilter

/// Top-level source filter options shown in the filter bar.
enum TimelineSourceFilter: String, CaseIterable, Identifiable {
    case all         = "All"
    case email       = "Email"
    case meeting     = "Meeting"
    case slack       = "Slack"
    case appActivity = "App Activity"

    var id: String { rawValue }

    func matches(_ interaction: Interaction) -> Bool {
        switch self {
        case .all:         return true
        case .email:       return interaction.source == .email
        case .meeting:     return interaction.interactionType == .meeting
        case .slack:       return interaction.interactionType == .slackDM
        case .appActivity: return interaction.interactionType == .appActivity
        }
    }
}

// MARK: - TimelineItem

/// A fully-resolved row in the timeline: interaction + related display data.
struct TimelineItem: Identifiable, Sendable {
    var id: EntityID { interaction.id }
    let interaction:    Interaction
    let contactName:    String?
    let contactCompany: String?
    let clientName:     String?
    let promises:       [Promise]
}

// MARK: - TimelineDateSection

/// Interactions grouped by calendar day for the section-header layout.
struct TimelineDateSection: Identifiable {
    let id:    String   // "YYYY-MM-DD" — stable ID for ScrollViewReader anchoring
    let date:  Date
    let label: String   // "Today", "Yesterday", "March 18, 2026"
    var items: [TimelineItem]
}

// MARK: - TimelineDataSource

/// Abstracts paged, filtered interaction data for the Timeline feature.
///
/// The production implementation will bridge to `KerwanStorage.StorageActor`.
/// `MockTimelineDataSource` is used during development and in SwiftUI previews.
protocol TimelineDataSource: AnyObject, Sendable {
    /// Returns up to `limit` `TimelineItem`s in reverse-chronological order,
    /// skipping the first `offset` results that match `filter`.
    func fetchPage(
        offset: Int,
        limit:  Int,
        filter: TimelineFilter
    ) async throws -> [TimelineItem]

    /// Returns all clients available as filter options.
    func fetchClients() async throws -> [Client]
}

// MARK: - MockTimelineDataSource

/// In-memory data source seeded with realistic fixture data.
final class MockTimelineDataSource: TimelineDataSource, @unchecked Sendable {

    private let allItems:   [TimelineItem]
    private let allClients: [Client]

    init() {
        let acme   = Client(id: "cl1", name: "Acme Corp",    domain: "acme.com")
        let widget = Client(id: "cl2", name: "Widget Labs",  domain: "widget.io")
        let solo   = Client(id: "cl3", name: "Solo Project", domain: nil)
        allClients = [acme, widget, solo]

        // (contactName, company, clientId, interactionType, source, summary, importance, sentiment)
        typealias Seed = (String?, String?, String?, InteractionType, EventSource,
                          String, Double, Sentiment)
        let seeds: [Seed] = [
            ("Alice Wong",   "Acme Corp",    "cl1", .meeting,       .audio,      "Discussed Q2 roadmap and hiring plan. Agreed to send proposal by Friday.", 0.9, .positive),
            ("Bob Chen",     "Acme Corp",    "cl1", .emailReceived, .email,      "Re: Invoice — confirmed payment will be processed by end of week.", 0.6, .neutral),
            ("Carol Davis",  "Widget Labs",  "cl2", .slackDM,       .slack,      "Quick clarification on API integration spec for the dashboard module.", 0.5, .neutral),
            (nil,            "Acme Corp",    "cl1", .appActivity,   .appFocus,   "Worked in Figma on Acme branding assets — exported v3 icon set.", 0.4, .neutral),
            ("Dave Kim",     "Widget Labs",  "cl2", .meeting,       .audio,      "Sprint planning — reviewed backlog, assigned story points, agreed on scope.", 0.8, .positive),
            ("Alice Wong",   "Acme Corp",    "cl1", .emailSent,     .email,      "Sent revised proposal with updated pricing and three-month timeline.", 0.7, .positive),
            ("Eve Patel",    "Solo Project", "cl3", .phoneCalled,   .audio,      "Intro call — exploring potential collaboration on new mobile product.", 0.75, .positive),
            (nil,            nil,            nil,   .appActivity,   .appFocus,   "Admin work — updated billing spreadsheets and quarterly expense reports.", 0.3, .neutral),
            ("Bob Chen",     "Acme Corp",    "cl1", .meeting,       .calendar,   "Weekly check-in. Reviewed feature progress. No blockers reported.", 0.6, .positive),
            ("Carol Davis",  "Widget Labs",  "cl2", .emailReceived, .email,      "Sent over final design assets for v2 launch. Everything looks great.", 0.65, .positive),
            ("Frank Turner", "Solo Project", "cl3", .slackDM,       .slack,      "Shared draft architecture diagram. Requested feedback on data model.", 0.55, .neutral),
            ("Alice Wong",   "Acme Corp",    "cl1", .emailSent,     .email,      "Follow-up on last week's proposal. Added notes from our meeting.", 0.6, .neutral),
            (nil,            "Widget Labs",  "cl2", .appActivity,   .appFocus,   "Code review on widget-api PR #112 — approved with minor comments.", 0.45, .neutral),
            ("Dave Kim",     "Widget Labs",  "cl2", .emailReceived, .email,      "Shared onboarding doc draft. Requesting review before Monday standup.", 0.5, .neutral),
            ("Carol Davis",  "Widget Labs",  "cl2", .meeting,       .audio,      "Design critique session — went through wireframes for onboarding flow.", 0.85, .positive),
            ("Eve Patel",    "Solo Project", "cl3", .emailSent,     .email,      "Sent NDA and scope of work. Awaiting signature before kickoff.", 0.7, .neutral),
            (nil,            "Acme Corp",    "cl1", .appActivity,   .browser,    "Researched competitor pricing pages for Acme pitch deck preparation.", 0.4, .neutral),
            ("Bob Chen",     "Acme Corp",    "cl1", .slackDM,       .slack,      "Quick status update on deployment window. Confirmed Thursday 6 PM.", 0.5, .neutral),
            ("Frank Turner", "Solo Project", "cl3", .meeting,       .audio,      "Technical deep-dive on auth flow. Decided on OAuth 2 + refresh tokens.", 0.9, .positive),
            ("Alice Wong",   "Acme Corp",    "cl1", .emailReceived, .email,      "Loved the proposal. A few questions on retainer structure — can we chat?", 0.8, .positive),
        ]

        let now   = Date()
        let times = [(2, 0), (9, 30), (14, 0), (16, 30)]

        var built: [TimelineItem] = []
        for (i, seed) in seeds.enumerated() {
            let (contactName, company, clientId, type, src, summary, importance, sentiment) = seed
            let dayOffset  = TimeInterval(i / 2) * 86_400
            let (h, m)     = times[i % 4]
            let timeOfDay  = TimeInterval(h) * 3_600 + TimeInterval(m) * 60
            let startedAt  = now - dayOffset - timeOfDay

            let duration: TimeInterval = type == .meeting ? 3_600 : (type == .slackDM ? 600 : 0)
            let endedAt: Date?         = duration > 0 ? startedAt + duration : nil

            let promises: [Promise] = importance > 0.7 ? [
                Promise(
                    id: "pr\(i)",
                    interactionId: "int\(i)",
                    contactId:  contactName != nil ? "ct\(i)" : nil,
                    clientId:   clientId,
                    direction:  i.isMultiple(of: 2) ? .userPromised : .contactPromised,
                    description: [
                        "Send revised proposal before Friday",
                        "Review design mockups by Monday",
                        "Share onboarding doc draft",
                        "Schedule follow-up call next week",
                        "Confirm deployment window with ops team"
                    ][i % 5],
                    dueDate:    startedAt + 3 * 86_400,
                    status:     i.isMultiple(of: 3) ? .done : .open,
                    sourceQuote: "I'll have that ready by end of week."
                )
            ] : []

            built.append(
                TimelineItem(
                    interaction: Interaction(
                        id:              "int\(i)",
                        contactId:       contactName != nil ? "ct\(i)" : nil,
                        clientId:        clientId,
                        source:          src,
                        interactionType: type,
                        startedAt:       startedAt,
                        endedAt:         endedAt,
                        summary:         summary,
                        sentiment:       sentiment,
                        importance:      importance,
                        contentTags:     [],
                        isReviewed:      i.isMultiple(of: 3)
                    ),
                    contactName:    contactName,
                    contactCompany: company,
                    clientName:     clientId.flatMap { id in [acme, widget, solo].first { $0.id == id }?.name },
                    promises:       promises
                )
            )
        }

        allItems = built.sorted { $0.interaction.startedAt > $1.interaction.startedAt }
    }

    func fetchPage(offset: Int, limit: Int, filter: TimelineFilter) async throws -> [TimelineItem] {
        // Simulate async DB latency
        try await Task.sleep(nanoseconds: 250_000_000)

        var filtered = allItems

        if filter.source != .all {
            filtered = filtered.filter { filter.source.matches($0.interaction) }
        }
        if let cid = filter.clientId {
            filtered = filtered.filter { $0.interaction.clientId == cid }
        }
        if let start = filter.dateStart {
            filtered = filtered.filter { $0.interaction.startedAt >= start }
        }
        if let end = filter.dateEnd {
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end
            filtered = filtered.filter { $0.interaction.startedAt < endOfDay }
        }

        guard offset < filtered.count else { return [] }
        return Array(filtered[offset ..< min(offset + limit, filtered.count)])
    }

    func fetchClients() async throws -> [Client] { allClients }
}
