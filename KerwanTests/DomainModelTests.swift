import XCTest
@testable import Kerwan

final class DomainModelTests: XCTestCase {

    // MARK: - Contact

    func testContactDefaultInit() {
        let contact = Contact(displayName: "Jane Smith")
        XCTAssertFalse(contact.id.isEmpty)
        XCTAssertEqual(contact.displayName, "Jane Smith")
        XCTAssertNil(contact.company)
        XCTAssertNil(contact.emailPrimary)
        XCTAssertNil(contact.aiSummary)
        XCTAssertEqual(contact.relationshipScore, 0.0)
        XCTAssertTrue(contact.needsReview)
    }

    func testContactRelationshipScoreClamping() {
        let over = Contact(displayName: "A", relationshipScore: 1.5)
        XCTAssertEqual(over.relationshipScore, 1.0)

        let under = Contact(displayName: "B", relationshipScore: -0.3)
        XCTAssertEqual(under.relationshipScore, 0.0)
    }

    func testContactCodableRoundTrip() throws {
        let contact = Contact(
            displayName: "Jane Smith",
            company: "Acme Corp",
            emailPrimary: "jane@acme.com",
            aiSummary: "Design lead",
            relationshipScore: 0.85,
            needsReview: false
        )
        let data = try JSONEncoder().encode(contact)
        let decoded = try JSONDecoder().decode(Contact.self, from: data)
        XCTAssertEqual(decoded, contact)
    }

    func testContactHashable() {
        let a = Contact(id: "test-id", displayName: "Jane")
        let b = Contact(id: "test-id", displayName: "Jane")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    // MARK: - ContactIdentity

    func testContactIdentitySources() {
        XCTAssertEqual(IdentitySource.allCases.count, 5)
        XCTAssertEqual(IdentitySource.email.rawValue, "email")
        XCTAssertEqual(IdentitySource.linkedin.rawValue, "linkedin")
    }

    func testContactIdentityConfidenceClamping() {
        let over = ContactIdentity(contactId: "c1", source: .email, identifier: "a@b.com", confidence: 2.0)
        XCTAssertEqual(over.confidence, 1.0)

        let under = ContactIdentity(contactId: "c1", source: .slack, identifier: "user", confidence: -1.0)
        XCTAssertEqual(under.confidence, 0.0)
    }

    func testContactIdentityCodableRoundTrip() throws {
        let identity = ContactIdentity(
            contactId: "c-123",
            source: .zoom,
            identifier: "Jane Smith",
            displayName: "Jane S.",
            confidence: 0.75
        )
        let data = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(ContactIdentity.self, from: data)
        XCTAssertEqual(decoded, identity)
    }

    // MARK: - Client

    func testClientDefaultInit() {
        let client = Client(name: "Acme Corp", domain: "acme.com")
        XCTAssertFalse(client.id.isEmpty)
        XCTAssertEqual(client.name, "Acme Corp")
        XCTAssertEqual(client.domain, "acme.com")
        XCTAssertNil(client.notes)
    }

    func testClientCodableRoundTrip() throws {
        let client = Client(name: "Test", domain: "test.com", notes: "Good client")
        let data = try JSONEncoder().encode(client)
        let decoded = try JSONDecoder().decode(Client.self, from: data)
        XCTAssertEqual(decoded, client)
    }

    // MARK: - Project

    func testProjectDefaultInit() {
        let project = Project(clientId: "c-1", name: "Website Redesign")
        XCTAssertTrue(project.isActive)
        XCTAssertNil(project.hourlyRate)
    }

    func testProjectCodableRoundTrip() throws {
        let project = Project(clientId: "c-1", name: "Redesign", hourlyRate: 200.0, isActive: false)
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(decoded, project)
    }

    // MARK: - RawEvent

    func testRawEventSources() {
        XCTAssertEqual(EventSource.allCases.count, 7)
        XCTAssertEqual(EventSource.audio.rawValue, "audio")
        XCTAssertEqual(EventSource.manualNote.rawValue, "manualNote")
    }

    func testRawEventDefaultInit() {
        let event = RawEvent(source: .audio, sourceApp: "Zoom")
        XCTAssertFalse(event.id.isEmpty)
        XCTAssertEqual(event.source, .audio)
        XCTAssertEqual(event.sourceApp, "Zoom")
        XCTAssertFalse(event.isExcluded)
        XCTAssertNil(event.endedAt)
        XCTAssertNil(event.rawText)
    }

    func testRawEventCodableRoundTrip() throws {
        let event = RawEvent(
            source: .email,
            sourceApp: "Mail",
            rawText: "Hello, here's the proposal...",
            metadataJSON: "{\"subject\":\"Proposal\"}",
            isExcluded: true
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(RawEvent.self, from: data)
        XCTAssertEqual(decoded, event)
    }

    // MARK: - Interaction

    func testInteractionTypes() {
        XCTAssertEqual(InteractionType.allCases.count, 6)
        XCTAssertEqual(InteractionType.meeting.rawValue, "meeting")
        XCTAssertEqual(InteractionType.appActivity.rawValue, "appActivity")
    }

    func testSentimentValues() {
        XCTAssertEqual(Sentiment.allCases.count, 4)
    }

    func testInteractionImportanceClamping() {
        let over = Interaction(source: .audio, interactionType: .meeting, importance: 1.5)
        XCTAssertEqual(over.importance, 1.0)

        let under = Interaction(source: .audio, interactionType: .meeting, importance: -0.2)
        XCTAssertEqual(under.importance, 0.0)
    }

    func testInteractionCodableRoundTrip() throws {
        let interaction = Interaction(
            contactId: "ct-1",
            clientId: "cl-1",
            projectId: "p-1",
            source: .audio,
            interactionType: .meeting,
            summary: "Discussed roadmap",
            sentiment: .positive,
            importance: 0.9,
            contentTags: ["roadmap", "Q2"]
        )
        let data = try JSONEncoder().encode(interaction)
        let decoded = try JSONDecoder().decode(Interaction.self, from: data)
        XCTAssertEqual(decoded, interaction)
        XCTAssertEqual(decoded.contentTags, ["roadmap", "Q2"])
    }

    // MARK: - Promise

    func testPromiseDirectionValues() {
        XCTAssertEqual(PromiseDirection.allCases.count, 2)
        XCTAssertEqual(PromiseDirection.userPromised.rawValue, "userPromised")
    }

    func testPromiseStatusValues() {
        XCTAssertEqual(PromiseStatus.allCases.count, 4)
    }

    func testPromiseIsOverdue() {
        let pastDue = Promise(
            direction: .userPromised,
            description: "Send proposal",
            dueDate: Date(timeIntervalSinceNow: -86400),
            status: .open
        )
        XCTAssertTrue(pastDue.isOverdue)

        let futureDue = Promise(
            direction: .userPromised,
            description: "Send proposal",
            dueDate: Date(timeIntervalSinceNow: 86400),
            status: .open
        )
        XCTAssertFalse(futureDue.isOverdue)

        let donePromise = Promise(
            direction: .contactPromised,
            description: "Review doc",
            dueDate: Date(timeIntervalSinceNow: -86400),
            status: .done
        )
        XCTAssertFalse(donePromise.isOverdue)

        let noDueDate = Promise(
            direction: .userPromised,
            description: "Eventually",
            status: .open
        )
        XCTAssertFalse(noDueDate.isOverdue)
    }

    func testPromiseCodableRoundTrip() throws {
        let promise = Promise(
            interactionId: "i-1",
            contactId: "ct-1",
            clientId: "cl-1",
            direction: .contactPromised,
            description: "Send the contract",
            dueDate: Date(),
            status: .snoozed,
            sourceQuote: "I'll send the contract by Friday"
        )
        let data = try JSONEncoder().encode(promise)
        let decoded = try JSONDecoder().decode(Promise.self, from: data)
        XCTAssertEqual(decoded, promise)
    }

    // MARK: - WorkSession

    func testWorkSessionDurationHours() {
        let session = WorkSession(
            startedAt: Date(),
            endedAt: Date(timeIntervalSinceNow: 5400),
            durationSecs: 5400
        )
        XCTAssertEqual(session.durationHours, 1.5)
    }

    func testWorkSessionDurationHoursRounding() {
        // 40 minutes = 0.67 hours
        let session = WorkSession(
            startedAt: Date(),
            endedAt: Date(timeIntervalSinceNow: 2400),
            durationSecs: 2400
        )
        XCTAssertEqual(session.durationHours, 0.67, accuracy: 0.01)
    }

    func testBillableStatusValues() {
        XCTAssertEqual(BillableStatus.allCases.count, 4)
        XCTAssertEqual(BillableStatus.suggested.rawValue, "suggested")
        XCTAssertEqual(BillableStatus.nonBillable.rawValue, "nonBillable")
    }

    func testWorkSessionConfidenceClamping() {
        let over = WorkSession(
            startedAt: Date(),
            endedAt: Date(timeIntervalSinceNow: 3600),
            durationSecs: 3600,
            confidence: 5.0
        )
        XCTAssertEqual(over.confidence, 1.0)
    }

    func testWorkSessionCodableRoundTrip() throws {
        let session = WorkSession(
            clientId: "cl-1",
            projectId: "p-1",
            startedAt: Date(),
            endedAt: Date(timeIntervalSinceNow: 3600),
            durationSecs: 3600,
            billableStatus: .confirmed,
            confidence: 0.92,
            description: "Design review",
            invoiceText: "Design review — 1.0 hr"
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(WorkSession.self, from: data)
        XCTAssertEqual(decoded, session)
    }

    // MARK: - ExclusionRule

    func testExclusionRuleTypes() {
        XCTAssertEqual(ExclusionRuleType.allCases.count, 4)
        XCTAssertEqual(ExclusionRuleType.windowTitleRegex.rawValue, "windowTitleRegex")
    }

    func testExclusionRuleCodableRoundTrip() throws {
        let rule = ExclusionRule(ruleType: .app, pattern: "1Password")
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(ExclusionRule.self, from: data)
        XCTAssertEqual(decoded, rule)
    }

    // MARK: - UserSettings

    func testUserSettingsDefaults() {
        let defaults = UserSettings.defaults
        XCTAssertTrue(defaults.captureAudio)
        XCTAssertTrue(defaults.captureAccessibility)
        XCTAssertEqual(defaults.digestTime, "09:00")
        XCTAssertEqual(defaults.billableDefaultRate, 150.0)
        XCTAssertFalse(defaults.consentMode)
        XCTAssertTrue(defaults.passphraseInKeychain)
    }

    func testUserSettingsCodableRoundTrip() throws {
        let settings = UserSettings(
            captureAudio: false,
            captureAccessibility: true,
            digestTime: "18:30",
            billableDefaultRate: 250.0,
            consentMode: true,
            passphraseInKeychain: false
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(UserSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    // MARK: - SearchResult

    func testSearchResultTypes() {
        XCTAssertEqual(SearchResultType.allCases.count, 4)
        XCTAssertEqual(SearchResultType.workSession.rawValue, "workSession")
    }

    func testSearchResultRelevanceClamping() {
        let over = SearchResult(
            id: "s-1",
            type: .interaction,
            title: "Test",
            snippet: "Snippet",
            timestamp: Date(),
            relevanceScore: 2.0
        )
        XCTAssertEqual(over.relevanceScore, 1.0)
    }

    func testSearchResultCodableRoundTrip() throws {
        let result = SearchResult(
            id: "s-1",
            type: .contact,
            title: "Jane Smith",
            snippet: "Design lead at Acme",
            timestamp: Date(),
            relevanceScore: 0.87,
            contactName: "Jane Smith",
            clientName: "Acme Corp"
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(SearchResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    // MARK: - CaptureStatus

    func testCaptureStatusIsActive() {
        XCTAssertFalse(CaptureStatus.idle.isActive)
        XCTAssertTrue(CaptureStatus.capturing.isActive)
        XCTAssertFalse(CaptureStatus.paused.isActive)
        XCTAssertFalse(CaptureStatus.privateMode.isActive)
        XCTAssertFalse(CaptureStatus.error("test").isActive)
    }

    func testCaptureStatusDescription() {
        XCTAssertEqual(CaptureStatus.idle.description, "Idle")
        XCTAssertEqual(CaptureStatus.capturing.description, "Capturing")
        XCTAssertEqual(CaptureStatus.paused.description, "Paused")
        XCTAssertEqual(CaptureStatus.privateMode.description, "Private Mode")
        XCTAssertEqual(CaptureStatus.error("mic denied").description, "Error: mic denied")
    }

    func testCaptureStatusCodableRoundTrip() throws {
        let statuses: [CaptureStatus] = [
            .idle, .capturing, .paused, .privateMode, .error("test error")
        ]
        for status in statuses {
            let data = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(CaptureStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }
    }

    func testCaptureStatusHashable() {
        let set: Set<CaptureStatus> = [.idle, .capturing, .idle, .error("a"), .error("a")]
        XCTAssertEqual(set.count, 3)
    }

    // MARK: - Digest

    func testDigestKindValues() {
        XCTAssertEqual(DigestKind.allCases.count, 2)
        XCTAssertEqual(DigestKind.daily.rawValue, "daily")
        XCTAssertEqual(DigestKind.weekly.rawValue, "weekly")
    }

    func testDailyDigestDefaultInit() {
        let digest = Digest(kind: .daily, title: "Morning Digest", bodyText: "Today was busy.")
        XCTAssertFalse(digest.id.isEmpty)
        XCTAssertEqual(digest.kind, .daily)
        XCTAssertEqual(digest.title, "Morning Digest")
        XCTAssertEqual(digest.meetingCount, 0)
        XCTAssertEqual(digest.emailCount, 0)
        XCTAssertNil(digest.totalHoursTracked)
        XCTAssertTrue(digest.quietContactNames.isEmpty)
    }

    func testWeeklyDigestStats() {
        let digest = Digest(
            kind: .weekly,
            title: "Weekly Summary",
            bodyText: "Strong week.",
            meetingCount: 5,
            totalHoursTracked: 32.5,
            estimatedBillableHours: 28.0,
            sessionsReviewedCount: 12,
            sessionsPendingCount: 3,
            priorWeekBillableHours: 24.0
        )
        XCTAssertEqual(digest.kind, .weekly)
        XCTAssertEqual(digest.meetingCount, 5)
        XCTAssertEqual(digest.totalHoursTracked, 32.5)
        XCTAssertEqual(digest.estimatedBillableHours, 28.0)
        XCTAssertEqual(digest.sessionsReviewedCount, 12)
        XCTAssertEqual(digest.sessionsPendingCount, 3)
        XCTAssertEqual(digest.priorWeekBillableHours, 24.0)
    }

    func testDigestCodableRoundTrip() throws {
        let digest = Digest(
            id: "d-001",
            kind: .daily,
            title: "Morning Digest · Mon Mar 24",
            bodyText: "You had 3 meetings.",
            meetingCount: 3,
            emailCount: 12,
            slackCount: 7,
            openPromiseCount: 2,
            unreviewedSessionCount: 1,
            quietContactNames: ["Alice", "Bob"]
        )
        let data = try JSONEncoder().encode(digest)
        let decoded = try JSONDecoder().decode(Digest.self, from: data)
        XCTAssertEqual(decoded, digest)
        XCTAssertEqual(decoded.quietContactNames, ["Alice", "Bob"])
    }

    func testDigestHashable() {
        let d1 = Digest(id: "same-id", kind: .daily, title: "A", bodyText: "B")
        let d2 = Digest(id: "same-id", kind: .daily, title: "A", bodyText: "B")
        XCTAssertEqual(d1, d2)
        let set: Set<Digest> = [d1, d2]
        XCTAssertEqual(set.count, 1)
    }

    // MARK: - WorkSession.durationFormatted (ReviewQueueView extension)

    func testDurationFormattedMinutes() {
        let session = WorkSession(
            startedAt: Date(), endedAt: Date(timeIntervalSinceNow: 2700), durationSecs: 2700
        )
        XCTAssertEqual(session.durationFormatted, "45 min")
    }

    func testDurationFormattedWholeHours() {
        let session = WorkSession(
            startedAt: Date(), endedAt: Date(timeIntervalSinceNow: 7200), durationSecs: 7200
        )
        XCTAssertEqual(session.durationFormatted, "2h")
    }

    func testDurationFormattedHoursAndMinutes() {
        let session = WorkSession(
            startedAt: Date(), endedAt: Date(timeIntervalSinceNow: 5400), durationSecs: 5400
        )
        XCTAssertEqual(session.durationFormatted, "1h 30m")
    }
}
