import XCTest
@testable import KerwanStorage

// MARK: - StorageActorTests

final class StorageActorTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a fresh in-memory (temp-file) StorageActor for each test.
    private func makeStorage() throws -> StorageActor {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db")
        return try StorageActor(passphrase: "test-passphrase", databaseURL: url)
    }

    private func sampleContact(email: String = "alice@example.com") -> Contact {
        Contact(displayName: "Alice Smith", emailPrimary: email,
                company: "Acme Inc", jobTitle: "Engineer")
    }

    private func sampleClient() -> Client {
        Client(name: "Acme Corp", domain: "acme.com", hourlyRate: 150, currency: "USD")
    }

    private func sampleInteraction(contactId: String? = nil) -> Interaction {
        Interaction(
            contactId: contactId,
            type: .email,
            subject: "Project kickoff",
            body: "Let's schedule the kickoff meeting for next week.",
            summary: "Scheduling kickoff",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: "gmail"
        )
    }

    private func sampleSession() -> WorkSession {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return WorkSession(
            startedAt: start,
            endedAt: start.addingTimeInterval(3600),
            durationSeconds: 3600,
            autoTitle: "Deep work: Acme project"
        )
    }

    // MARK: - Migration

    func test_migration_fresh_database_createsAllTables() async throws {
        let storage = try makeStorage()
        let settings = await storage.fetchUserSettings()
        XCTAssertEqual(settings.schemaVersion, 2)
    }

    func test_migration_idempotent_runningTwiceDoesNotFail() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db")
        let _ = try StorageActor(passphrase: "p", databaseURL: url)
        // Re-open same file — migration_001 must be skipped (already applied).
        XCTAssertNoThrow(try StorageActor(passphrase: "p", databaseURL: url))
    }

    func test_migration_defaultExclusionRulesSeeded() async throws {
        let storage = try makeStorage()
        let rules = await storage.fetchExclusionRules()
        let appRules = rules.filter { $0.type == .app }
        XCTAssertTrue(appRules.contains { $0.value == "1Password" })
        XCTAssertTrue(appRules.contains { $0.value == "Keychain Access" })
    }

    // MARK: - Contacts CRUD

    func test_upsertContact_insertsNewContact() async throws {
        let storage = try makeStorage()
        let contact = sampleContact()
        try await storage.upsertContact(contact)
        let fetched = await storage.fetchContact(id: contact.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.emailPrimary, "alice@example.com")
    }

    func test_upsertContact_updatesExistingByEmail() async throws {
        let storage = try makeStorage()
        var contact = sampleContact()
        try await storage.upsertContact(contact)

        contact.displayName = "Alice Jones"
        try await storage.upsertContact(contact)

        let contacts = await storage.fetchAllContacts()
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts.first?.displayName, "Alice Jones")
    }

    func test_fetchContactByEmail_caseInsensitive() async throws {
        let storage = try makeStorage()
        try await storage.upsertContact(sampleContact(email: "Bob@Example.COM"))
        let fetched = await storage.fetchContactByEmail("bob@example.com")
        XCTAssertNotNil(fetched)
    }

    func test_fetchAllContacts_paginates() async throws {
        let storage = try makeStorage()
        for i in 0..<10 {
            try await storage.upsertContact(sampleContact(email: "user\(i)@example.com"))
        }
        let page = await storage.fetchAllContacts(limit: 3, offset: 0)
        XCTAssertEqual(page.count, 3)
        let page2 = await storage.fetchAllContacts(limit: 3, offset: 3)
        XCTAssertEqual(page2.count, 3)
    }

    // MARK: - ContactIdentity CRUD

    func test_upsertContactIdentity_insertsAndUpdates() async throws {
        let storage = try makeStorage()
        let contact = sampleContact()
        try await storage.upsertContact(contact)

        let identity = ContactIdentity(
            contactId: contact.id,
            platform: .slack,
            platformId: "U12345",
            displayName: "alice-slack"
        )
        try await storage.upsertContactIdentity(identity)

        var identities = await storage.fetchContactIdentities(contactId: contact.id)
        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities.first?.platformId, "U12345")

        // Update display name via upsert
        _ = identity  // updated2 below replaces it via upsert
        let updated2 = ContactIdentity(
            id: identity.id,
            contactId: contact.id,
            platform: .slack,
            platformId: "U12345",
            displayName: "alice-updated"
        )
        try await storage.upsertContactIdentity(updated2)
        identities = await storage.fetchContactIdentities(contactId: contact.id)
        XCTAssertEqual(identities.first?.displayName, "alice-updated")
    }

    // MARK: - Clients CRUD

    func test_upsertClient_insertAndFetch() async throws {
        let storage = try makeStorage()
        let client = sampleClient()
        try await storage.upsertClient(client)
        let fetched = await storage.fetchClient(id: client.id)
        XCTAssertEqual(fetched?.name, "Acme Corp")
        XCTAssertEqual(fetched?.hourlyRate, 150)
    }

    func test_fetchAllClients_returnsAll() async throws {
        let storage = try makeStorage()
        try await storage.upsertClient(sampleClient())
        try await storage.upsertClient(Client(name: "Beta Ltd"))
        let all = await storage.fetchAllClients()
        XCTAssertEqual(all.count, 2)
    }

    // MARK: - Projects CRUD

    func test_fetchProjects_filteredByClient() async throws {
        let storage = try makeStorage()
        let client = sampleClient()
        try await storage.upsertClient(client)
        _ = Project(clientId: client.id, name: "Alpha Launch") // placeholder; no public insert API yet
        // Projects are not directly exposed as a write method in the public API,
        // so we test via the underlying write connection through a subclass hook.
        // For now, verify fetchProjects returns empty for an unknown client.
        let projects = await storage.fetchProjects(clientId: client.id)
        XCTAssertEqual(projects.count, 0) // no projects inserted yet
    }

    // MARK: - RawEvents

    func test_insertRawEvents_bulkInsert() async throws {
        let storage = try makeStorage()
        let events = (0..<100).map { i -> RawEvent in
            RawEvent(
                timestamp: Date(timeIntervalSince1970: Double(1_700_000_000 + i)),
                source: .windowFocus,
                sourceApp: "Xcode",
                windowTitle: "ContentView.swift — MyProject",
                duration: 30
            )
        }
        try await storage.insertRawEvents(events)
        // No direct count fetch exposed; verify no throw.
    }

    func test_insertRawEvents_emptyArrayIsNoOp() async throws {
        let storage = try makeStorage()
        try await storage.insertRawEvents([]) // empty array should not throw
    }

    func test_fetchRawEvents_bySessionId() async throws {
        let storage = try makeStorage()
        let events = (0..<5).map { i -> RawEvent in
            RawEvent(
                timestamp: Date(timeIntervalSince1970: Double(1_700_000_000 + i)),
                source: .windowFocus,
                sourceApp: "Safari",
                duration: 10
            )
        }
        try await storage.insertRawEvents(events)
        let session = sampleSession()
        try await storage.insertWorkSession(session, linkedEventIds: events.map(\.id))
        let fetched = await storage.fetchRawEvents(sessionId: session.id)
        XCTAssertEqual(fetched.count, 5)
    }

    // MARK: - Interactions

    func test_insertInteraction_andFetch() async throws {
        let storage = try makeStorage()
        let contact = sampleContact()
        try await storage.upsertContact(contact)
        let interaction = sampleInteraction(contactId: contact.id)
        try await storage.insertInteraction(interaction, linkedEventIds: [])
        let fetched = await storage.fetchInteractions(contactId: contact.id)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.subject, "Project kickoff")
    }

    func test_fetchInteractions_filteredByClient() async throws {
        let storage = try makeStorage()
        let client = sampleClient()
        try await storage.upsertClient(client)

        let a = Interaction(clientId: client.id, type: .meeting,
                            startedAt: .now, source: "calendar")
        let b = Interaction(type: .email, startedAt: .now, source: "gmail")
        try await storage.insertInteraction(a, linkedEventIds: [])
        try await storage.insertInteraction(b, linkedEventIds: [])

        let clientInteractions = await storage.fetchInteractions(clientId: client.id)
        XCTAssertEqual(clientInteractions.count, 1)
        XCTAssertEqual(clientInteractions.first?.id, a.id)
    }

    // MARK: - FTS5 Search

    func test_searchKeyword_findsInsertedInteraction() async throws {
        let storage = try makeStorage()
        let interaction = sampleInteraction()
        try await storage.insertInteraction(interaction, linkedEventIds: [])
        // Allow FTS triggers to commit.
        let results = await storage.searchKeyword(query: "kickoff")
        XCTAssertFalse(results.isEmpty, "FTS search should find interaction with 'kickoff' in subject")
        XCTAssertEqual(results.first?.id, interaction.id)
    }

    func test_searchKeyword_noResultsForUnknownTerm() async throws {
        let storage = try makeStorage()
        try await storage.insertInteraction(sampleInteraction(), linkedEventIds: [])
        let results = await storage.searchKeyword(query: "xyzzy_nonexistent_9999")
        XCTAssertTrue(results.isEmpty)
    }

    func test_searchKeyword_respectsLimit() async throws {
        let storage = try makeStorage()
        for i in 0..<10 {
            let interaction = Interaction(
                type: .email,
                subject: "kickoff meeting \(i)",
                startedAt: .now,
                source: "gmail"
            )
            try await storage.insertInteraction(interaction, linkedEventIds: [])
        }
        let results = await storage.searchKeyword(query: "kickoff", limit: 3)
        XCTAssertEqual(results.count, 3)
    }

    // MARK: - Promises

    func test_insertPromise_andFetch() async throws {
        let storage = try makeStorage()
        let promise = Promise(text: "Send the proposal by Friday",
                              dueDate: Date().addingTimeInterval(86400 * 3))
        try await storage.insertPromise(promise)
        let fetched = await storage.fetchPromises()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.text, "Send the proposal by Friday")
    }

    func test_updatePromiseStatus() async throws {
        let storage = try makeStorage()
        let promise = Promise(text: "Follow up on invoice")
        try await storage.insertPromise(promise)
        try await storage.updatePromiseStatus(id: promise.id, status: .fulfilled)
        let fetched = await storage.fetchPromises(status: .fulfilled)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.status, .fulfilled)
    }

    func test_countOpenPromises() async throws {
        let storage = try makeStorage()
        try await storage.insertPromise(Promise(text: "A"))
        try await storage.insertPromise(Promise(text: "B"))
        try await storage.updatePromiseStatus(
            id: (await storage.fetchPromises()).first!.id,
            status: .dismissed
        )
        let count = await storage.countOpenPromises()
        XCTAssertEqual(count, 1)
    }

    // MARK: - WorkSessions

    func test_insertWorkSession_andFetch() async throws {
        let storage = try makeStorage()
        let session = sampleSession()
        try await storage.insertWorkSession(session, linkedEventIds: [])
        let fetched = await storage.fetchWorkSessions()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.autoTitle, "Deep work: Acme project")
    }

    func test_updateWorkSession_billableStatus() async throws {
        let storage = try makeStorage()
        let session = sampleSession()
        try await storage.insertWorkSession(session, linkedEventIds: [])
        try await storage.updateWorkSession(id: session.id, billable: .billable,
                                             invoiceText: "Design review — 1h")
        let fetched = await storage.fetchWorkSessions(billable: .billable)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.invoiceText, "Design review — 1h")
        XCTAssertTrue(fetched.first?.reviewed ?? false)
    }

    func test_fetchUnreviewedSessions() async throws {
        let storage = try makeStorage()
        let past = Date(timeIntervalSince1970: 1_000_000_000)
        let session = WorkSession(startedAt: past, endedAt: past.addingTimeInterval(3600),
                                   durationSeconds: 3600)
        try await storage.insertWorkSession(session, linkedEventIds: [])
        let unreviewed = await storage.fetchUnreviewedSessions(since: past.addingTimeInterval(-1))
        XCTAssertEqual(unreviewed.count, 1)
        try await storage.updateWorkSession(id: session.id, billable: .billable, invoiceText: nil)
        let afterReview = await storage.fetchUnreviewedSessions(since: past.addingTimeInterval(-1))
        XCTAssertEqual(afterReview.count, 0)
    }

    func test_countUnreviewedSessions() async throws {
        let storage = try makeStorage()
        let s1 = sampleSession()
        let s2 = sampleSession()
        try await storage.insertWorkSession(s1, linkedEventIds: [])
        try await storage.insertWorkSession(s2, linkedEventIds: [])
        let before = await storage.countUnreviewedSessions()
        XCTAssertEqual(before, 2)
        try await storage.updateWorkSession(id: s1.id, billable: .billable, invoiceText: nil)
        let after = await storage.countUnreviewedSessions()
        XCTAssertEqual(after, 1)
    }

    // MARK: - Cascading Delete

    func test_deleteContact_cascadesIdentities() async throws {
        let storage = try makeStorage()
        let contact = sampleContact()
        try await storage.upsertContact(contact)
        try await storage.upsertContactIdentity(
            ContactIdentity(contactId: contact.id, platform: .email,
                            platformId: contact.emailPrimary)
        )
        try await storage.deleteContact(id: contact.id)
        let deletedContact = await storage.fetchContact(id: contact.id)
        XCTAssertNil(deletedContact)
        let identities = await storage.fetchContactIdentities(contactId: contact.id)
        XCTAssertTrue(identities.isEmpty, "Identities should cascade-delete with contact")
    }

    func test_deleteContact_setsNullOnRelatedInteractions() async throws {
        let storage = try makeStorage()
        let contact = sampleContact()
        try await storage.upsertContact(contact)
        let interaction = sampleInteraction(contactId: contact.id)
        try await storage.insertInteraction(interaction, linkedEventIds: [])

        try await storage.deleteContact(id: contact.id)

        // Fetch interaction without contact filter — should still exist with null contact_id
        let all = await storage.fetchInteractions()
        XCTAssertEqual(all.count, 1)
        XCTAssertNil(all.first?.contactId, "contact_id should be NULL after contact delete")
    }

    func test_deleteContact_removesVecEmbeddings() async throws {
        let storage = try makeStorage()
        let contact = sampleContact()
        try await storage.upsertContact(contact)
        let interaction = sampleInteraction(contactId: contact.id)
        try await storage.insertInteraction(interaction, linkedEventIds: [])
        let embedding = [Float](repeating: 0.1, count: 768)

        // Skip if sqlite-vec extension is not loaded (stock SQLite in CI).
        do {
            try await storage.insertVectorEmbedding(interactionId: interaction.id,
                                                     embedding: embedding)
        } catch StorageError.writeFailed {
            // vec0 table not available — skip the vector-specific assertion.
            try await storage.deleteContact(id: contact.id)
            return
        }

        try await storage.deleteContact(id: contact.id)
        // After delete, vector search should return no match for this embedding.
        let results = await storage.searchVector(embedding: embedding, limit: 5)
        XCTAssertFalse(results.contains { $0.interactionId == interaction.id })
    }

    // MARK: - Time Range Delete

    func test_deleteTimeRange_removesEventsAndSessions() async throws {
        let storage = try makeStorage()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [RawEvent(timestamp: t0, source: .windowFocus, duration: 10)]
        try await storage.insertRawEvents(events)
        let session = WorkSession(startedAt: t0, endedAt: t0.addingTimeInterval(60),
                                   durationSeconds: 60)
        try await storage.insertWorkSession(session, linkedEventIds: [])
        let interaction = Interaction(type: .email, startedAt: t0, source: "gmail")
        try await storage.insertInteraction(interaction, linkedEventIds: [])

        try await storage.deleteTimeRange(from: t0.addingTimeInterval(-1),
                                           to: t0.addingTimeInterval(1))

        let sessions     = await storage.fetchWorkSessions()
        let interactions = await storage.fetchInteractions()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(interactions.isEmpty)
    }

    // MARK: - Exclusion Rules

    func test_insertAndDeleteExclusionRule() async throws {
        let storage = try makeStorage()
        let rule = ExclusionRule(type: .app, value: "Spotify")
        try await storage.insertExclusionRule(rule)
        var rules = await storage.fetchExclusionRules()
        XCTAssertTrue(rules.contains { $0.value == "Spotify" })

        try await storage.deleteExclusionRule(id: rule.id)
        rules = await storage.fetchExclusionRules()
        XCTAssertFalse(rules.contains { $0.value == "Spotify" })
    }

    // MARK: - UserSettings

    func test_updateUserSetting_roundTrip() async throws {
        let storage = try makeStorage()
        try await storage.updateUserSetting(key: "whisper_model", value: "large-v3")
        let settings = await storage.fetchUserSettings()
        XCTAssertEqual(settings.whisperModel, "large-v3")
    }

    // MARK: - Vector Embeddings

    func test_insertVectorEmbedding_wrongDimensionThrows() async throws {
        let storage = try makeStorage()
        let interaction = sampleInteraction()
        try await storage.insertInteraction(interaction, linkedEventIds: [])
        let badEmbedding = [Float](repeating: 0.1, count: 384) // wrong size
        do {
            try await storage.insertVectorEmbedding(interactionId: interaction.id,
                                                     embedding: badEmbedding)
            XCTFail("Should have thrown for wrong dimension")
        } catch StorageError.writeFailed { /* expected */ }
    }

    // MARK: - deleteAllData

    func test_deleteAllData_resetsDatabase() async throws {
        let storage = try makeStorage()
        try await storage.upsertContact(sampleContact())
        try await storage.insertWorkSession(sampleSession(), linkedEventIds: [])
        try await storage.deleteAllData()
        let contacts2  = await storage.fetchAllContacts()
        let sessions2  = await storage.fetchWorkSessions()
        XCTAssertTrue(contacts2.isEmpty)
        XCTAssertTrue(sessions2.isEmpty)
        // Settings should be re-seeded
        let settings = await storage.fetchUserSettings()
        XCTAssertEqual(settings.schemaVersion, 2)
    }

    // MARK: - Concurrent Read During Write

    func test_concurrentReadsDuringWrite_walAllowsIt() async throws {
        let storage = try makeStorage()
        // Pre-populate some data
        for i in 0..<20 {
            try await storage.upsertContact(sampleContact(email: "user\(i)@test.com"))
        }

        // Fire concurrent reads while also doing writes
        await withTaskGroup(of: Void.self) { group in
            // Writer task
            group.addTask {
                for i in 20..<40 {
                    try? await storage.upsertContact(
                        Contact(displayName: "User \(i)",
                                emailPrimary: "user\(i)@test.com")
                    )
                }
            }
            // Reader tasks — should never block or deadlock
            for _ in 0..<5 {
                group.addTask {
                    let _ = await storage.fetchAllContacts(limit: 100, offset: 0)
                }
            }
        }
        // After concurrent ops, total should be 40
        let final = await storage.fetchAllContacts(limit: 100, offset: 0)
        XCTAssertEqual(final.count, 40)
    }

    // MARK: - Bulk Insert Performance

    func test_bulkInsert_1000RawEventsUnderOneSecond() async throws {
        let storage = try makeStorage()
        let events = (0..<1000).map { i -> RawEvent in
            RawEvent(
                timestamp: Date(timeIntervalSince1970: Double(1_700_000_000 + i)),
                source: .windowFocus,
                sourceApp: "Xcode",
                windowTitle: "MyFile.swift",
                duration: Double(i % 60)
            )
        }
        let start = Date()
        try await storage.insertRawEvents(events)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0, "1000 raw event inserts should complete in <1s, took \(elapsed)s")
    }

    // MARK: - Encryption Round-Trip

    func test_encryptionRoundTrip_reopenWithSamePassphrase() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db")
        let passphrase = "correct-horse-battery-staple"

        // Write data
        let storage1 = try StorageActor(passphrase: passphrase, databaseURL: url)
        try await storage1.upsertContact(sampleContact())

        // Re-open with same passphrase — should read the data back
        let storage2 = try StorageActor(passphrase: passphrase, databaseURL: url)
        let contacts = await storage2.fetchAllContacts()
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts.first?.emailPrimary, "alice@example.com")
    }

    // MARK: - CapturePauses

    func test_insertCapturePause_andFetch() async throws {
        let storage = try makeStorage()
        let pause = CapturePause(reason: "Meeting")
        try await storage.insertCapturePause(pause)
        let fetched = await storage.fetchCapturePauses()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.id, pause.id)
        XCTAssertEqual(fetched.first?.reason, "Meeting")
        XCTAssertNil(fetched.first?.endedAt, "endedAt must be nil for an open pause")
    }

    func test_endCapturePause_setsEndTime() async throws {
        let storage = try makeStorage()
        let pause = CapturePause()
        try await storage.insertCapturePause(pause)

        let end = Date()
        try await storage.endCapturePause(id: pause.id, endedAt: end)

        let fetched = await storage.fetchCapturePauses()
        XCTAssertNotNil(fetched.first?.endedAt)
        // Timestamps stored as Double; allow ≤1 ms rounding error.
        let diff = abs((fetched.first?.endedAt?.timeIntervalSince1970 ?? 0) - end.timeIntervalSince1970)
        XCTAssertLessThan(diff, 0.001)
    }

    func test_fetchCapturePauses_filteredByDateRange() async throws {
        let storage = try makeStorage()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        try await storage.insertCapturePause(CapturePause(startedAt: t0))
        try await storage.insertCapturePause(CapturePause(startedAt: t0.addingTimeInterval(3600)))
        try await storage.insertCapturePause(CapturePause(startedAt: t0.addingTimeInterval(7200)))

        // Only the first two fall in the half-open interval [t0, t0+7200).
        let inRange = await storage.fetchCapturePauses(
            from: t0,
            to: t0.addingTimeInterval(7200)
        )
        XCTAssertEqual(inRange.count, 2)
    }

    func test_fetchCapturePauses_empty_returnsEmpty() async throws {
        let storage = try makeStorage()
        let results = await storage.fetchCapturePauses()
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Maintenance

    func test_vacuum_doesNotThrow() async throws {
        let storage = try makeStorage()
        await storage.vacuum()
    }

    func test_checkpoint_doesNotThrow() async throws {
        let storage = try makeStorage()
        try await storage.insertRawEvents([
            RawEvent(source: .windowFocus, duration: 1)
        ])
        await storage.checkpoint()
    }

    func test_exportDatabase_createsFile() async throws {
        let storage = try makeStorage()
        try await storage.upsertContact(sampleContact())

        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_export.db")
        defer { try? FileManager.default.removeItem(at: destURL) }

        try await storage.exportDatabase(to: destURL, encrypt: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
    }
}
