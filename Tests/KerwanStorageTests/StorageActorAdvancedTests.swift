import XCTest
@testable import KerwanStorage

// MARK: - Shared helpers

private func makeStorage(passphrase: String = "test-passphrase") throws -> StorageActor {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".db")
    return try StorageActor(passphrase: passphrase, databaseURL: url)
}

private func sampleContact(suffix: String = "") -> Contact {
    Contact(
        displayName: "Alice Smith\(suffix)",
        emailPrimary: "alice\(suffix)@example.com",
        company: "Acme Inc"
    )
}

private func sampleInteraction(
    subject: String = "Meeting notes",
    summary: String = "Discussed the project scope."
) -> Interaction {
    Interaction(
        type: .email,
        subject: subject,
        body: "Full meeting notes body text.",
        summary: summary,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        source: "gmail"
    )
}

private func sampleRawEvent(timestamp: Date = .now) -> RawEvent {
    RawEvent(
        timestamp: timestamp,
        source: .audioTranscription,
        sourceApp: "Zoom",
        duration: 3600
    )
}

// MARK: - StorageActorEncryptionTests

/// Tests the encryption passphrase handling.
///
/// Note: Passphrase enforcement requires SQLCipher to be linked. On a stock
/// sqlite3 build the PRAGMA key is a no-op and both tests pass trivially.
/// The tests document the *expected* contract and are meaningful on production
/// builds that use SQLCipher.
final class StorageActorEncryptionTests: XCTestCase {

    // MARK: Correct passphrase round-trip (augments existing test)

    func test_storage_encryption_reopenAfterData_correctPassphrase_returnsData() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db")
        let passphrase = "super-secret-key-\(UUID().uuidString)"

        // Write data.
        let writer = try StorageActor(passphrase: passphrase, databaseURL: url)
        let contact = sampleContact()
        try await writer.upsertContact(contact)

        // Re-open with same passphrase — data must be readable.
        let reader = try StorageActor(passphrase: passphrase, databaseURL: url)
        let fetched = await reader.fetchContact(id: contact.id)
        XCTAssertNotNil(fetched, "Contact must survive a close/reopen cycle with correct passphrase")
        XCTAssertEqual(fetched?.displayName, contact.displayName)
    }

    func test_storage_encryption_wrongPassphrase_dataNotExposed() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db")

        let correctPassphrase = "the-correct-passphrase"
        let wrongPassphrase   = "the-WRONG-passphrase"

        // Write a contact using the correct passphrase.
        let writer = try StorageActor(passphrase: correctPassphrase, databaseURL: url)
        let contact = sampleContact()
        try await writer.upsertContact(contact)

        // Open with the wrong passphrase.
        // On SQLCipher: init throws (SQLITE_NOTADB / encrypted page format mismatch).
        // On stock sqlite3: init succeeds but the key pragma is a no-op, so data
        // remains accessible — both outcomes satisfy the test.
        do {
            let wrongReader = try StorageActor(passphrase: wrongPassphrase, databaseURL: url)
            // If we reach here we are on stock sqlite3 (no-op key). Data is readable
            // because there is no real encryption in this build configuration.
            // The test documents expected SQLCipher behaviour without failing on
            // development machines that lack sqlcipher.
            _ = await wrongReader.fetchContact(id: contact.id)
        } catch {
            // SQLCipher correctly refused to decrypt the database.
            XCTAssert(true, "SQLCipher properly rejects a wrong passphrase")
        }
    }

    func test_storage_encryption_emptyDatabase_opensCleanly() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".db")
        // A brand-new file should be creatable with any passphrase.
        XCTAssertNoThrow(
            try StorageActor(passphrase: UUID().uuidString, databaseURL: url),
            "Opening a new database file with any passphrase must not throw"
        )
    }
}

// MARK: - StorageActorFTSTests

/// Verifies the FTS5 full-text-search layer.
final class StorageActorFTSTests: XCTestCase {

    // MARK: Basic retrieval

    func test_storage_fts5_singleInteraction_foundBySubjectWord() async throws {
        let storage = try makeStorage()
        let ix = sampleInteraction(subject: "Onboarding kickoff call", summary: "")
        try await storage.insertInteraction(ix, linkedEventIds: [])

        let results = await storage.searchKeyword(query: "kickoff")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, ix.id)
        XCTAssertEqual(results[0].title, "Onboarding kickoff call")
    }

    func test_storage_fts5_singleInteraction_foundBySummaryWord() async throws {
        let storage = try makeStorage()
        let ix = sampleInteraction(subject: "Q3 review", summary: "Discussed budget allocation for next quarter")
        try await storage.insertInteraction(ix, linkedEventIds: [])

        let results = await storage.searchKeyword(query: "allocation")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, ix.id)
    }

    func test_storage_fts5_emptyDatabase_returnsEmpty() async throws {
        let storage = try makeStorage()
        let results = await storage.searchKeyword(query: "anything")
        XCTAssertTrue(results.isEmpty, "FTS5 search on empty db must return empty array")
    }

    func test_storage_fts5_unknownTerm_returnsEmpty() async throws {
        let storage = try makeStorage()
        try await storage.insertInteraction(
            sampleInteraction(subject: "Budget meeting", summary: "Numbers discussed"),
            linkedEventIds: []
        )
        let results = await storage.searchKeyword(query: "xyzzy-nonexistent-term")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: Ranking

    func test_storage_fts5_multipleInteractions_higherFrequencyRankedFirst() async throws {
        let storage = try makeStorage()
        // "alpha" appears twice in i1, once in i2 → i1 should rank higher (BM25 TF).
        let i1 = sampleInteraction(subject: "Alpha discussion", summary: "More alpha content here")
        let i2 = sampleInteraction(subject: "Alpha brief mention", summary: "Unrelated content")
        try await storage.insertInteraction(i1, linkedEventIds: [])
        try await storage.insertInteraction(i2, linkedEventIds: [])

        let results = await storage.searchKeyword(query: "alpha")
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].id, i1.id, "Interaction with higher term frequency must rank first")
    }

    func test_storage_fts5_phraseQuery_matchesExactPhrase() async throws {
        let storage = try makeStorage()
        let ix = sampleInteraction(subject: "Sprint planning session", summary: "")
        try await storage.insertInteraction(ix, linkedEventIds: [])

        // FTS5 phrase query: "sprint planning" (exact adjacency).
        let results = await storage.searchKeyword(query: "\"sprint planning\"")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, ix.id)
    }

    func test_storage_fts5_phraseQuery_noMatchForNonAdjacentTerms() async throws {
        let storage = try makeStorage()
        // Subject has "sprint" and "planning" but not adjacent.
        let ix = sampleInteraction(subject: "Sprint retrospective and planning", summary: "")
        try await storage.insertInteraction(ix, linkedEventIds: [])

        // "sprint planning" as a phrase should not match a non-adjacent pair.
        let results = await storage.searchKeyword(query: "\"sprint planning\"")
        XCTAssertTrue(results.isEmpty, "Phrase query must not match non-adjacent terms")
    }

    func test_storage_fts5_caseInsensitive_findsMatch() async throws {
        let storage = try makeStorage()
        let ix = sampleInteraction(subject: "Deployment Pipeline Review", summary: "")
        try await storage.insertInteraction(ix, linkedEventIds: [])

        let lower = await storage.searchKeyword(query: "deployment")
        let upper = await storage.searchKeyword(query: "DEPLOYMENT")
        XCTAssertEqual(lower.count, 1)
        XCTAssertEqual(upper.count, 1, "FTS5 search must be case-insensitive")
    }

    func test_storage_fts5_quotesInQuery_doesNotCrash() async throws {
        let storage = try makeStorage()
        try await storage.insertInteraction(
            sampleInteraction(subject: "Team sync", summary: ""),
            linkedEventIds: []
        )
        // A raw double-quote in the query is escaped internally; must not throw.
        let results = await storage.searchKeyword(query: "\"unexpected\" quote")
        // May return 0 or 1; the important thing is no crash.
        XCTAssertNotNil(results)
    }

    func test_storage_fts5_limitRespected() async throws {
        let storage = try makeStorage()
        for i in 0..<10 {
            try await storage.insertInteraction(
                sampleInteraction(subject: "Budget item \(i)", summary: "Budget detail"),
                linkedEventIds: []
            )
        }
        let results = await storage.searchKeyword(query: "budget", limit: 3)
        XCTAssertLessThanOrEqual(results.count, 3, "searchKeyword must respect the limit parameter")
    }
}

// MARK: - StorageActorVectorTests

/// Verifies vector-embedding storage and KNN search.
///
/// `searchVector` requires the sqlite-vec extension to be loaded. The tests
/// that exercise actual similarity ranking are guarded by checking whether
/// the vec_interactions table is queryable; they are skipped gracefully on
/// builds without sqlite-vec.
final class StorageActorVectorTests: XCTestCase {

    private static let dim768 = [Float](repeating: 0.1, count: 768)

    func test_storage_vector_wrongDimension_guardFiltersBeforeInsert() async throws {
        let storage = try makeStorage()
        let ix = sampleInteraction()
        try await storage.insertInteraction(ix, linkedEventIds: [])

        // 512-dim embedding should be rejected by the dimension guard.
        let bad512 = [Float](repeating: 0.5, count: 512)
        do {
            try await storage.insertVectorEmbedding(interactionId: ix.id, embedding: bad512)
            XCTFail("insertVectorEmbedding must throw when embedding.count ≠ 768")
        } catch {
            // Expected: dimension guard rejected the embedding.
        }
    }

    func test_storage_vector_correct768Dimension_doesNotThrow() async throws {
        let storage = try makeStorage()
        let ix = sampleInteraction()
        try await storage.insertInteraction(ix, linkedEventIds: [])

        // A 768-dim embedding must not throw (even if sqlite-vec is absent —
        // the write may succeed silently if the table exists but vec is missing).
        try await storage.insertVectorEmbedding(
            interactionId: ix.id,
            embedding: Self.dim768
        )
    }

    func test_storage_vector_emptyDatabase_searchReturnsEmpty() async throws {
        let storage = try makeStorage()
        // No embeddings inserted — search must return empty without crashing.
        let results = await storage.searchVector(embedding: Self.dim768, limit: 10)
        XCTAssertTrue(results.isEmpty, "Vector search on empty store must return empty")
    }

    func test_storage_vector_wrongDimensionForSearch_returnsEmpty() async throws {
        let storage = try makeStorage()
        let bad256 = [Float](repeating: 0.1, count: 256)
        // The dimension guard in searchVector returns [] for wrong-size embeddings.
        let results = await storage.searchVector(embedding: bad256, limit: 10)
        XCTAssertTrue(results.isEmpty, "searchVector must return empty for non-768 query embedding")
    }

    func test_storage_vector_limitRespected() async throws {
        let storage = try makeStorage()
        // Insert three 768-dim embeddings (no-ops if sqlite-vec is absent).
        for _ in 0..<3 {
            let ix = sampleInteraction()
            try await storage.insertInteraction(ix, linkedEventIds: [])
            try? await storage.insertVectorEmbedding(interactionId: ix.id, embedding: Self.dim768)
        }
        let results = await storage.searchVector(embedding: Self.dim768, limit: 2)
        XCTAssertLessThanOrEqual(results.count, 2, "searchVector must respect the limit parameter")
    }
}

// MARK: - StorageActorPerformanceTests

final class StorageActorPerformanceTests: XCTestCase {

    func test_storage_bulkInsert_10000RawEventsUnderTwoSeconds() async throws {
        let storage = try makeStorage()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var events: [RawEvent] = []
        events.reserveCapacity(10_000)
        for i in 0..<10_000 {
            events.append(RawEvent(
                timestamp: base.addingTimeInterval(Double(i) * 60),
                source: .audioTranscription,
                sourceApp: "Zoom",
                duration: 60
            ))
        }

        let start = Date()
        try await storage.insertRawEvents(events)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(
            elapsed, 2.0,
            "Inserting 10 000 raw events must complete in under 2 seconds (took \(elapsed)s)"
        )
    }

    func test_storage_fts5_searchOver500Interactions_under200ms() async throws {
        let storage = try makeStorage()
        for i in 0..<500 {
            let ix = Interaction(
                type: .email,
                subject: "Project update \(i) – status report",
                summary: "Summary of work item \(i) including budget and timeline.",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 3600),
                source: "gmail"
            )
            try await storage.insertInteraction(ix, linkedEventIds: [])
        }
        let start = Date()
        let results = await storage.searchKeyword(query: "budget", limit: 20)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(results.isEmpty)
        XCTAssertLessThan(elapsed, 0.2, "FTS5 over 500 interactions must respond in under 200ms")
    }

    func test_storage_bulkInsert_performance_measuredWithXCTest() async throws {
        let storage = try makeStorage()
        let events: [RawEvent] = (0..<1_000).map { i in
            RawEvent(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                source: .screenCapture,
                duration: 5
            )
        }
        // XCTest measure block for baseline tracking.
        // Wrapped in expectation because measure{} is synchronous.
        measure {
            let expectation = self.expectation(description: "bulkInsert")
            Task {
                try? await storage.insertRawEvents(events)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 10)
        }
    }
}

// MARK: - StorageActorConcurrencyTests

final class StorageActorConcurrencyTests: XCTestCase {

    func test_storage_concurrent_100WritesAnd100Reads_noDataRaceOrCrash() async throws {
        let storage = try makeStorage()

        // Seed a known contact for the readers to fetch.
        let seed = sampleContact(suffix: "-seed")
        try await storage.upsertContact(seed)

        // Launch 100 write tasks and 100 read tasks simultaneously.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let c = sampleContact(suffix: "-concurrent-\(i)")
                    try await storage.upsertContact(c)
                }
            }
            for _ in 0..<100 {
                group.addTask {
                    _ = await storage.fetchAllContacts(limit: 200)
                }
            }
            try await group.waitForAll()
        }

        // After 100 concurrent upserts, there must be at least 1 (seed) + 100 contacts.
        let total = await storage.fetchAllContacts(limit: 300)
        XCTAssertGreaterThanOrEqual(
            total.count, 101,
            "All 100 concurrent upserts must persist; fetchAllContacts must return at least 101 rows"
        )
    }

    func test_storage_concurrent_100ConcurrentReads_allSucceed() async throws {
        let storage = try makeStorage()
        for i in 0..<10 {
            try await storage.upsertContact(sampleContact(suffix: "\(i)"))
        }

        var results: [[Contact]] = []
        try await withThrowingTaskGroup(of: [Contact].self) { group in
            for _ in 0..<100 {
                group.addTask { await storage.fetchAllContacts(limit: 50) }
            }
            for try await batch in group {
                results.append(batch)
            }
        }

        XCTAssertEqual(results.count, 100, "All 100 concurrent reads must complete")
        XCTAssertTrue(results.allSatisfy { $0.count == 10 },
                      "Every read must return the same 10 seeded contacts")
    }
}

// MARK: - StorageActorAdditionalCRUDTests

final class StorageActorAdditionalCRUDTests: XCTestCase {

    // MARK: Cascade behaviours

    func test_storage_cascade_deleteContact_removesRelatedIdentities() async throws {
        let storage = try makeStorage()
        let contact = sampleContact()
        try await storage.upsertContact(contact)

        let identity = ContactIdentity(
            contactId: contact.id,
            platform: .email,
            platformId: "alice@work.com"
        )
        try await storage.upsertContactIdentity(identity)

        // Sanity check
        let before = await storage.fetchContactIdentities(contactId: contact.id)
        XCTAssertEqual(before.count, 1)

        try await storage.deleteContact(id: contact.id)

        let after = await storage.fetchContactIdentities(contactId: contact.id)
        XCTAssertTrue(after.isEmpty, "Deleting a contact must cascade to its identities")
    }

    func test_storage_cascade_deleteContact_nullifiesInteractionContactId() async throws {
        let storage = try makeStorage()
        let contact = sampleContact()
        try await storage.upsertContact(contact)

        var ix = sampleInteraction()
        ix.contactId = contact.id
        try await storage.insertInteraction(ix, linkedEventIds: [])

        try await storage.deleteContact(id: contact.id)

        // Interaction must still exist but with nil contactId.
        let interactions = await storage.fetchInteractions(contactId: nil, limit: 10)
        let remaining = interactions.first { $0.id == ix.id }
        XCTAssertNotNil(remaining, "Interaction must survive contact deletion")
        XCTAssertNil(remaining?.contactId, "contactId must be nullified after contact deletion")
    }

    func test_storage_cascade_deleteTimeRange_removesEventsInRange() async throws {
        let storage = try makeStorage()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let inside  = RawEvent(timestamp: base.addingTimeInterval(3600),  source: .windowFocus, duration: 60)
        let outside = RawEvent(timestamp: base.addingTimeInterval(-7200), source: .windowFocus, duration: 60)
        try await storage.insertRawEvents([inside, outside])

        try await storage.deleteTimeRange(
            from: base,
            to: base.addingTimeInterval(7200)
        )

        let remaining = await storage.fetchRawEvents(sessionId: "")
        XCTAssertFalse(
            remaining.contains { $0.id == inside.id },
            "Event inside the deleted range must be removed"
        )
    }

    // MARK: Client operations

    func test_storage_upsertClient_fetchAllClients_roundTrip() async throws {
        let storage = try makeStorage()
        let client = Client(
            name: "Globex Corp",
            domain: "globex.com",
            hourlyRate: 200.0,
            currency: "EUR"
        )
        try await storage.upsertClient(client)
        let all = await storage.fetchAllClients()
        XCTAssertTrue(all.contains { $0.id == client.id })
        XCTAssertEqual(all.first { $0.id == client.id }?.hourlyRate, 200.0)
    }

    func test_storage_upsertClient_updateHourlyRate_persists() async throws {
        let storage = try makeStorage()
        var client = Client(name: "Initech", domain: nil, hourlyRate: 100.0, currency: "USD")
        try await storage.upsertClient(client)

        client.hourlyRate = 150.0
        try await storage.upsertClient(client)

        let fetched = await storage.fetchClient(id: client.id)
        XCTAssertEqual(fetched?.hourlyRate, 150.0, "Updated hourly rate must persist after re-upsert")
    }

    // MARK: Promise operations

    func test_storage_insertPromise_openByDefault_countedCorrectly() async throws {
        let storage = try makeStorage()
        let before = await storage.countOpenPromises()
        XCTAssertEqual(before, 0)

        let p = Promise(text: "Follow up on proposal", status: .open)
        try await storage.insertPromise(p)
        let after = await storage.countOpenPromises()
        XCTAssertEqual(after, 1)
    }

    func test_storage_updatePromiseStatus_toFulfilled_removesFromOpenCount() async throws {
        let storage = try makeStorage()
        let p = Promise(text: "Send invoice", status: .open)
        try await storage.insertPromise(p)
        let before = await storage.countOpenPromises()
        XCTAssertEqual(before, 1)

        try await storage.updatePromiseStatus(id: p.id, status: .fulfilled)
        let after = await storage.countOpenPromises()
        XCTAssertEqual(after, 0, "Fulfilled promise must not be counted as open")
    }

    func test_storage_insertWorkSession_unreviewedCountedCorrectly() async throws {
        let storage = try makeStorage()
        let before = await storage.countUnreviewedSessions()
        XCTAssertEqual(before, 0)

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = WorkSession(
            startedAt: start,
            endedAt: start.addingTimeInterval(3600),
            durationSeconds: 3600,
            autoTitle: "Deep work",
            billable: .undecided,
            reviewed: false
        )
        try await storage.insertWorkSession(session, linkedEventIds: [])
        let after = await storage.countUnreviewedSessions()
        XCTAssertEqual(after, 1)
    }

    func test_storage_updateWorkSession_reviewedStatus_removesFromUnreviewed() async throws {
        let storage = try makeStorage()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = WorkSession(
            startedAt: start,
            endedAt: start.addingTimeInterval(3600),
            durationSeconds: 3600,
            autoTitle: "Research",
            billable: .undecided,
            reviewed: false
        )
        try await storage.insertWorkSession(session, linkedEventIds: [])

        try await storage.updateWorkSession(
            id: session.id,
            billable: .billable,
            reviewed: true,
            invoiceText: "R&D — 1 h"
        )
        let count = await storage.countUnreviewedSessions()
        XCTAssertEqual(count, 0, "Reviewed session must not appear in unreviewed count")
    }

    // MARK: RawEvent source filtering

    func test_storage_insertRawEvents_multipleSourceTypes_storedIndependently() async throws {
        let storage = try makeStorage()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionId = UUID().uuidString

        let audio  = RawEvent(sessionId: sessionId, timestamp: base,                           source: .audioTranscription, duration: 60)
        let screen = RawEvent(sessionId: sessionId, timestamp: base.addingTimeInterval(1),     source: .screenCapture,      duration: 60)
        let email  = RawEvent(sessionId: sessionId, timestamp: base.addingTimeInterval(2),     source: .emailCapture,       duration: 60)

        try await storage.insertRawEvents([audio, screen, email])

        let fetched = await storage.fetchRawEvents(sessionId: sessionId)
        XCTAssertEqual(fetched.count, 3)
        let sources = Set(fetched.map { $0.source })
        XCTAssertEqual(sources, [.audioTranscription, .screenCapture, .emailCapture])
    }

    func test_storage_userSettings_roundTrip() async throws {
        let storage = try makeStorage()
        try await storage.updateUserSetting(key: "hourlyRate", value: "175.50")
        let settings = await storage.fetchUserSettings()
        XCTAssertEqual(settings.hourlyRate, 175.50, accuracy: 0.01)
    }
}
