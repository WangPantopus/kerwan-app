import XCTest
@testable import Kerwan

// MARK: - In-memory mock storage

/// Thread-safe in-memory mock conforming to ``IdentityResolverStorage``.
actor MockIdentityStorage: IdentityResolverStorage {
    var contacts:    [EntityID: Contact]         = [:]
    var identities:  [EntityID: ContactIdentity] = [:]
    var interactions: [EntityID: Interaction]    = [:]
    var promises:    [EntityID: Promise]         = [:]
    var clients:     [Client]                    = []
    var logs:        [CorrectionLog]             = []

    // MARK: ContactIdentity

    func findIdentities(byEmail email: String) async throws -> [ContactIdentity] {
        identities.values.filter {
            $0.identifier.lowercased() == email.lowercased()
        }
    }

    func findIdentities(forContactId contactId: EntityID) async throws -> [ContactIdentity] {
        identities.values.filter { $0.contactId == contactId }
    }

    func upsertIdentity(_ identity: ContactIdentity) async throws {
        identities[identity.id] = identity
    }

    func deleteIdentities(forContactId contactId: EntityID, source: IdentitySource) async throws {
        identities = identities.filter { _, v in
            !(v.contactId == contactId && v.source == source)
        }
    }

    // MARK: Contact CRUD

    func findContact(byEmail email: String) async throws -> Contact? {
        contacts.values.first {
            $0.emailPrimary?.lowercased() == email.lowercased()
        }
    }

    /// Returns all contacts whose display name contains `name` as a substring
    /// (case- and diacritic-insensitive), simulating a broad search.
    func findContacts(byNormalisedName name: String) async throws -> [Contact] {
        let normName = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return contacts.values.filter {
            $0.displayName
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .contains(normName)
        }
    }

    func upsertContact(_ contact: Contact) async throws {
        contacts[contact.id] = contact
    }

    func deleteContact(id: EntityID) async throws {
        contacts.removeValue(forKey: id)
        identities = identities.filter { _, v in v.contactId != id }
    }

    // MARK: Temporal Proximity

    func contactHasInteraction(
        contactId: EntityID,
        near timestamp: Date,
        windowSeconds: Double
    ) async throws -> Bool {
        interactions.values.contains {
            $0.contactId == contactId &&
            abs($0.startedAt.timeIntervalSince(timestamp)) <= windowSeconds
        }
    }

    // MARK: Merge Support

    func reassignInteractions(from sourceContactId: EntityID, to targetContactId: EntityID) async throws {
        for key in interactions.keys {
            if interactions[key]?.contactId == sourceContactId {
                interactions[key]?.contactId = targetContactId
            }
        }
    }

    func reassignPromises(from sourceContactId: EntityID, to targetContactId: EntityID) async throws {
        for key in promises.keys {
            if promises[key]?.contactId == sourceContactId {
                promises[key]?.contactId = targetContactId
            }
        }
    }

    // MARK: Client

    func listClients() async throws -> [Client] { clients }

    // MARK: Correction Log

    func insertCorrectionLog(_ log: CorrectionLog) async throws {
        logs.append(log)
    }

    func listCorrectionLogs() async throws -> [CorrectionLog] {
        logs.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: Test helpers

    func seedContact(_ contact: Contact) {
        contacts[contact.id] = contact
    }

    func seedIdentity(_ identity: ContactIdentity) {
        identities[identity.id] = identity
    }

    func seedInteraction(_ interaction: Interaction) {
        interactions[interaction.id] = interaction
    }

    func seedClient(_ client: Client) {
        clients.append(client)
    }

    func identityCount() -> Int { identities.count }
    func contactCount()  -> Int { contacts.count }
    func logCount()      -> Int { logs.count }
}

// MARK: - CorrectionLogTests

final class CorrectionLogTests: XCTestCase {

    func test_default_id_is_uuid() {
        let log = CorrectionLog(action: .merge)
        XCTAssertFalse(log.id.isEmpty)
    }

    func test_create_table_sql_contains_table_name() {
        XCTAssertTrue(CorrectionLog.createTableSQL.contains("correction_log"))
        XCTAssertTrue(CorrectionLog.createTableSQL.contains("action"))
        XCTAssertTrue(CorrectionLog.createTableSQL.contains("source_contact_id"))
        XCTAssertTrue(CorrectionLog.createTableSQL.contains("target_contact_id"))
    }

    func test_codable_round_trip() throws {
        let original = CorrectionLog(
            id: "test-id",
            action: .split,
            sourceContactId: "src",
            targetContactId: "tgt",
            detailsJSON: "[\"id1\",\"id2\"]",
            createdAt: Date(timeIntervalSince1970: 1_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CorrectionLog.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.action, .split)
        XCTAssertEqual(decoded.sourceContactId, "src")
        XCTAssertEqual(decoded.targetContactId, "tgt")
        XCTAssertEqual(decoded.detailsJSON, "[\"id1\",\"id2\"]")
    }

    func test_all_actions_codable() throws {
        for action in CorrectionAction.allCases {
            let log = CorrectionLog(action: action)
            let data = try JSONEncoder().encode(log)
            let decoded = try JSONDecoder().decode(CorrectionLog.self, from: data)
            XCTAssertEqual(decoded.action, action)
        }
    }
}

// MARK: - IdentityResolverTests

final class IdentityResolverTests: XCTestCase {

    // MARK: Helpers

    private func makeResolver(storage: MockIdentityStorage) -> IdentityResolver {
        IdentityResolver(storage: storage)
    }

    private func makeContact(
        id: String = UUID().uuidString,
        name: String,
        email: String? = nil
    ) -> Contact {
        Contact(id: id, displayName: name, emailPrimary: email)
    }

    // MARK: Step 1 — Exact email match via ContactIdentity

    func test_exactEmail_matchesViaIdentity() async throws {
        let storage = MockIdentityStorage()
        let contact = makeContact(name: "Jane Smith", email: "jane@acme.com")
        await storage.seedContact(contact)
        let identity = ContactIdentity(
            contactId: contact.id,
            source: .email,
            identifier: "jane@acme.com"
        )
        await storage.seedIdentity(identity)

        let resolver = makeResolver(storage: storage)
        let result = try await resolver.resolve(
            names: [],
            emails: ["jane@acme.com"],
            source: .email,
            timestamp: Date()
        )

        XCTAssertEqual(result.contactId, contact.id)
        XCTAssertEqual(result.confidence, 1.0)
        XCTAssertFalse(result.isNew)
        XCTAssertFalse(result.needsReview)
    }

    func test_exactEmail_matchesViaContactEmailPrimary() async throws {
        let storage = MockIdentityStorage()
        let contact = makeContact(name: "Bob Jones", email: "bob@jones.io")
        await storage.seedContact(contact)

        let resolver = makeResolver(storage: storage)
        let result = try await resolver.resolve(
            names: ["Bob Jones"],
            emails: ["bob@jones.io"],
            source: .email,
            timestamp: Date()
        )

        XCTAssertEqual(result.contactId, contact.id)
        XCTAssertEqual(result.confidence, 1.0)
        XCTAssertFalse(result.isNew)
    }

    func test_exactEmail_caseInsensitive() async throws {
        let storage = MockIdentityStorage()
        let contact = makeContact(name: "Alice", email: "Alice@Corp.com")
        await storage.seedContact(contact)
        let identity = ContactIdentity(
            contactId: contact.id,
            source: .email,
            identifier: "alice@corp.com"
        )
        await storage.seedIdentity(identity)

        let resolver = makeResolver(storage: storage)
        let result = try await resolver.resolve(
            names: [],
            emails: ["ALICE@CORP.COM"],
            source: .email,
            timestamp: Date()
        )

        XCTAssertEqual(result.contactId, contact.id)
        XCTAssertEqual(result.confidence, 1.0)
    }

    func test_exactEmail_createsIdentityLinkIfMissing() async throws {
        let storage = MockIdentityStorage()
        let contact = makeContact(name: "Sam", email: "sam@x.com")
        await storage.seedContact(contact)
        let initialCount = await storage.identityCount()

        let resolver = makeResolver(storage: storage)
        _ = try await resolver.resolve(
            names: [],
            emails: ["sam@x.com"],
            source: .zoom,  // different source; no existing identity for zoom
            timestamp: Date()
        )

        let finalCount = await storage.identityCount()
        XCTAssertEqual(finalCount, initialCount + 1)
    }

    func test_exactEmail_doesNotDuplicateIdentity() async throws {
        let storage = MockIdentityStorage()
        let contact = makeContact(name: "Sam", email: "sam@x.com")
        await storage.seedContact(contact)
        let identity = ContactIdentity(
            contactId: contact.id,
            source: .email,
            identifier: "sam@x.com"
        )
        await storage.seedIdentity(identity)
        let initialCount = await storage.identityCount()

        let resolver = makeResolver(storage: storage)
        _ = try await resolver.resolve(
            names: [],
            emails: ["sam@x.com"],
            source: .email,
            timestamp: Date()
        )

        let identityCount = await storage.identityCount()
        XCTAssertEqual(identityCount, initialCount)
    }

    // MARK: Step 2 — Domain + name similarity

    func test_domainName_singleMatch_confidence085() async throws {
        let storage = MockIdentityStorage()
        let contact = makeContact(name: "Jane Smith", email: "jane.smith@acme.com")
        await storage.seedContact(contact)
        let client = Client(name: "Acme", domain: "acme.com")
        await storage.seedClient(client)

        let resolver = makeResolver(storage: storage)
        let result = try await resolver.resolve(
            names: ["Jane Smith"],
            emails: ["j.smith@acme.com"],
            source: .email,
            timestamp: Date()
        )

        XCTAssertEqual(result.contactId, contact.id)
        XCTAssertEqual(result.confidence, 0.85, accuracy: 0.001)
        XCTAssertEqual(result.clientId, client.id)
        XCTAssertFalse(result.needsReview)
    }

    func test_domainName_multipleMatches_needsReview() async throws {
        let storage = MockIdentityStorage()
        let c1 = makeContact(id: "c1", name: "Jane Smith", email: "jane@corp.com")
        let c2 = makeContact(id: "c2", name: "Jane Smithe", email: "janey@corp.com")
        await storage.seedContact(c1)
        await storage.seedContact(c2)

        let resolver = makeResolver(storage: storage)
        let result = try await resolver.resolve(
            names: ["Jane Smith"],
            emails: ["unknown@corp.com"],
            source: .email,
            timestamp: Date()
        )

        XCTAssertEqual(result.confidence, 0.6, accuracy: 0.001)
        XCTAssertTrue(result.needsReview)
    }

    func test_domainName_belowThreshold_fallsThrough() async throws {
        let storage = MockIdentityStorage()
        // "Bob" vs "Janet Smith" — very low similarity, should fall through to step 4
        let contact = makeContact(name: "Janet Smith", email: "janet@corp.com")
        await storage.seedContact(contact)

        let resolver = makeResolver(storage: storage)
        let result = try await resolver.resolve(
            names: ["Bob"],
            emails: ["someone@corp.com"],
            source: .email,
            timestamp: Date()
        )

        // Should have created a new contact
        XCTAssertTrue(result.isNew)
    }

    // MARK: Step 3 — Name only + temporal proximity

    func test_nameOnly_singleMatch_withProximity_confidence07() async throws {
        let storage = MockIdentityStorage()
        let contact = makeContact(id: "c1", name: "Alexander Johnson")
        await storage.seedContact(contact)

        let now = Date()
        let interaction = Interaction(
            contactId: contact.id,
            source: .audio,
            interactionType: .meeting,
            startedAt: now.addingTimeInterval(-3_600) // 1 hour ago
        )
        await storage.seedInteraction(interaction)

        let resolver = makeResolver(storage: storage)
        let result = try await resolver.resolve(
            names: ["Alexander Johnson"],
            emails: [],
            source: .zoom,
            timestamp: now
        )

        XCTAssertEqual(result.contactId, contact.id)
        XCTAssertEqual(result.confidence, 0.7, accuracy: 0.001)
        XCTAssertFalse(result.isNew)
        XCTAssertFalse(result.needsReview)
    }

    func test_nameOnly_singleMatch_noProximity_createsNew() async throws {
        let storage = MockIdentityStorage()
        let contact = makeContact(name: "Alexander Johnson")
        await storage.seedContact(contact)
        // No interactions seeded — temporal proximity check returns false

        let resolver = makeResolver(storage: storage)
        let result = try await resolver.resolve(
            names: ["Alexander Johnson"],
            emails: [],
            source: .zoom,
            timestamp: Date()
        )

        XCTAssertTrue(result.isNew)
    }

    func test_nameOnly_multipleMatches_createsNew() async throws {
        let storage = MockIdentityStorage()
        await storage.seedContact(makeContact(name: "Alex Johnson", email: "alex@a.com"))
        await storage.seedContact(makeContact(name: "Alex Johnson", email: "alex@b.com"))

        let resolver = makeResolver(storage: storage)
        let result = try await resolver.resolve(
            names: ["Alex Johnson"],
            emails: [],
            source: .zoom,
            timestamp: Date()
        )

        // Multiple candidates → falls through to step 4
        XCTAssertTrue(result.isNew)
    }

    // MARK: Step 4 — Create new contact

    func test_createNew_setsNeedsReview() async throws {
        let storage = MockIdentityStorage()
        let initialCount = await storage.contactCount()

        let resolver = makeResolver(storage: storage)
        let result = try await resolver.resolve(
            names: ["New Person"],
            emails: ["new@person.com"],
            source: .email,
            timestamp: Date()
        )

        XCTAssertTrue(result.isNew)
        XCTAssertTrue(result.needsReview)
        XCTAssertEqual(result.confidence, 0.5, accuracy: 0.001)
        let contactCount = await storage.contactCount()
        XCTAssertEqual(contactCount, initialCount + 1)
    }

    func test_createNew_usesEmailWhenNoName() async throws {
        let storage = MockIdentityStorage()
        let resolver = makeResolver(storage: storage)

        let result = try await resolver.resolve(
            names: [],
            emails: ["noname@x.com"],
            source: .email,
            timestamp: Date()
        )

        XCTAssertNotNil(result.contactId)
        XCTAssertTrue(result.isNew)
        let contact = await storage.contacts[result.contactId!]
        XCTAssertEqual(contact?.emailPrimary, "noname@x.com")
    }

    func test_createNew_createsIdentityRecord() async throws {
        let storage = MockIdentityStorage()
        let resolver = makeResolver(storage: storage)

        _ = try await resolver.resolve(
            names: ["Brand New"],
            emails: ["brand@new.io"],
            source: .slack,
            timestamp: Date()
        )

        let identityCount = await storage.identityCount()
        XCTAssertEqual(identityCount, 1)
    }

    // MARK: Unicode names

    func test_unicode_chineseName_exactMatch() async throws {
        let storage = MockIdentityStorage()
        let contact = makeContact(name: "王芳", email: "wang.fang@example.com")
        await storage.seedContact(contact)

        let resolver = makeResolver(storage: storage)
        let result = try await resolver.resolve(
            names: [],
            emails: ["wang.fang@example.com"],
            source: .email,
            timestamp: Date()
        )

        XCTAssertEqual(result.contactId, contact.id)
        XCTAssertEqual(result.confidence, 1.0)
    }

    func test_unicode_arabicName_createNew() async throws {
        let storage = MockIdentityStorage()
        let resolver = makeResolver(storage: storage)

        let result = try await resolver.resolve(
            names: ["محمد علي"],
            emails: [],
            source: .zoom,
            timestamp: Date()
        )

        XCTAssertTrue(result.isNew)
        let contact = await storage.contacts[result.contactId!]
        XCTAssertEqual(contact?.displayName, "محمد علي")
    }

    func test_unicode_accentedLatin_domainMatch() async throws {
        let storage = MockIdentityStorage()
        // "François Dupont" stored; input is "Francois Dupont" (no accent)
        let contact = makeContact(name: "François Dupont", email: "francois@firm.fr")
        await storage.seedContact(contact)

        let resolver = makeResolver(storage: storage)
        let result = try await resolver.resolve(
            names: ["Francois Dupont"],
            emails: ["f.dupont@firm.fr"],
            source: .email,
            timestamp: Date()
        )

        // Diacritic-insensitive Levenshtein should score ~1.0, domain matches
        XCTAssertEqual(result.contactId, contact.id)
        XCTAssertEqual(result.confidence, 0.85, accuracy: 0.001)
    }

    // MARK: Merge

    func test_merge_reassignsInteractionsAndDeletesSource() async throws {
        let storage = MockIdentityStorage()
        let source = makeContact(id: "src", name: "Jane Doe")
        let target = makeContact(id: "tgt", name: "Jane Smith")
        await storage.seedContact(source)
        await storage.seedContact(target)

        let identity = ContactIdentity(contactId: "src", source: .email, identifier: "jane@old.com")
        await storage.seedIdentity(identity)

        let interaction = Interaction(
            contactId: "src",
            source: .audio,
            interactionType: .meeting,
            startedAt: Date()
        )
        await storage.seedInteraction(interaction)

        let resolver = makeResolver(storage: storage)
        try await resolver.mergeContacts(sourceId: "src", targetId: "tgt")

        // Source contact deleted
        let srcContact = await storage.contacts["src"]
        XCTAssertNil(srcContact)
        // Interaction reassigned
        let movedInteraction = await storage.interactions.values.first
        XCTAssertEqual(movedInteraction?.contactId, "tgt")
        // Identity re-linked
        let movedIdentity = await storage.identities.values.first
        XCTAssertEqual(movedIdentity?.contactId, "tgt")
        // Log recorded
        let logs = await storage.logs
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0].action, .merge)
        XCTAssertEqual(logs[0].sourceContactId, "src")
        XCTAssertEqual(logs[0].targetContactId, "tgt")
    }

    func test_merge_logsCorrection() async throws {
        let storage = MockIdentityStorage()
        await storage.seedContact(makeContact(id: "a", name: "Alpha"))
        await storage.seedContact(makeContact(id: "b", name: "Beta"))

        let resolver = makeResolver(storage: storage)
        try await resolver.mergeContacts(sourceId: "a", targetId: "b")

        let logCount = await storage.logCount()
        XCTAssertEqual(logCount, 1)
        let log = await storage.logs[0]
        XCTAssertEqual(log.action, .merge)
    }

    // MARK: Split

    func test_split_movesIdentitiesAndCreatesNewContact() async throws {
        let storage = MockIdentityStorage()
        let original = makeContact(id: "orig", name: "Jane Doe")
        await storage.seedContact(original)

        let id1 = ContactIdentity(
            id: "ident-1",
            contactId: "orig",
            source: .email,
            identifier: "jane@a.com",
            displayName: "Jane A"
        )
        let id2 = ContactIdentity(
            id: "ident-2",
            contactId: "orig",
            source: .email,
            identifier: "jane@b.com",
            displayName: "Jane B"
        )
        await storage.seedIdentity(id1)
        await storage.seedIdentity(id2)

        let resolver = makeResolver(storage: storage)
        let newContact = try await resolver.splitContact(
            contactId: "orig",
            identityIds: ["ident-1"]
        )

        // New contact created
        XCTAssertNotEqual(newContact.id, "orig")
        XCTAssertTrue(newContact.needsReview)
        // Moved identity now points to new contact
        let movedIdentity = await storage.identities["ident-1"]
        XCTAssertEqual(movedIdentity?.contactId, newContact.id)
        // Other identity untouched
        let stayedIdentity = await storage.identities["ident-2"]
        XCTAssertEqual(stayedIdentity?.contactId, "orig")
        // Log recorded
        let log = await storage.logs[0]
        XCTAssertEqual(log.action, .split)
        XCTAssertEqual(log.sourceContactId, "orig")
    }

    func test_split_inferDisplayNameFromIdentity() async throws {
        let storage = MockIdentityStorage()
        await storage.seedContact(makeContact(id: "c", name: "Placeholder"))
        let identity = ContactIdentity(
            id: "ident-a",
            contactId: "c",
            source: .zoom,
            identifier: "zoom-uid-123",
            displayName: "Real Name"
        )
        await storage.seedIdentity(identity)

        let resolver = makeResolver(storage: storage)
        let newContact = try await resolver.splitContact(
            contactId: "c",
            identityIds: ["ident-a"]
        )

        XCTAssertEqual(newContact.displayName, "Real Name")
    }

    // MARK: Adaptive thresholds

    func test_adjustThresholds_tightensOnHighErrorRate() async throws {
        let storage = MockIdentityStorage()
        let resolver = makeResolver(storage: storage)

        // 10 merges, 3 splits → error rate 0.3 → tighten
        let corrections: [CorrectionLog] =
            (0..<10).map { _ in CorrectionLog(action: .merge) } +
            (0..<3).map  { _ in CorrectionLog(action: .split) }

        let beforeDomain = await resolver.domainNameThreshold
        let beforeName   = await resolver.nameOnlyThreshold

        await resolver.adjustThresholds(basedOnCorrections: corrections)

        let afterDomain = await resolver.domainNameThreshold
        let afterName   = await resolver.nameOnlyThreshold

        XCTAssertGreaterThan(afterDomain, beforeDomain)
        XCTAssertGreaterThan(afterName, beforeName)
    }

    func test_adjustThresholds_relaxesOnLowErrorRateWithManyMerges() async throws {
        let storage = MockIdentityStorage()
        let resolver = makeResolver(storage: storage)

        // 20 merges, 0 splits → error rate 0 → relax
        let corrections: [CorrectionLog] = (0..<20).map { _ in CorrectionLog(action: .merge) }

        let beforeDomain = await resolver.domainNameThreshold

        await resolver.adjustThresholds(basedOnCorrections: corrections)

        let afterDomain = await resolver.domainNameThreshold
        XCTAssertLessThan(afterDomain, beforeDomain)
    }

    func test_adjustThresholds_noOpWithNoMerges() async throws {
        let storage = MockIdentityStorage()
        let resolver = makeResolver(storage: storage)

        let corrections: [CorrectionLog] = (0..<5).map { _ in CorrectionLog(action: .split) }

        let beforeDomain = await resolver.domainNameThreshold
        await resolver.adjustThresholds(basedOnCorrections: corrections)
        let afterDomain = await resolver.domainNameThreshold

        XCTAssertEqual(afterDomain, beforeDomain)
    }

    func test_adjustThresholds_clampsAtMax() async throws {
        let storage = MockIdentityStorage()
        let resolver = makeResolver(storage: storage)

        // Driving 0.80 + 15 × 0.02 = 1.10 would exceed 0.99 without clamping.
        // Error rate = 5/5 = 1.0, which is > 0.20, so thresholds tighten each call.
        let corrections: [CorrectionLog] =
            (0..<5).map { _ in CorrectionLog(action: .merge) } +
            (0..<5).map { _ in CorrectionLog(action: .split) }

        for _ in 0..<15 {
            await resolver.adjustThresholds(basedOnCorrections: corrections)
        }

        let domainNameThreshold = await resolver.domainNameThreshold
        let nameOnlyThreshold = await resolver.nameOnlyThreshold
        XCTAssertLessThanOrEqual(domainNameThreshold, 0.99)
        XCTAssertLessThanOrEqual(nameOnlyThreshold, 0.99)
    }

    // MARK: ResolvedIdentity

    func test_resolvedIdentity_clampedConfidence() {
        let low  = ResolvedIdentity(contactId: nil, clientId: nil, confidence: -1.0, isNew: false, needsReview: false)
        let high = ResolvedIdentity(contactId: nil, clientId: nil, confidence: 2.0, isNew: false, needsReview: false)
        XCTAssertEqual(low.confidence, 0.0)
        XCTAssertEqual(high.confidence, 1.0)
    }
}
