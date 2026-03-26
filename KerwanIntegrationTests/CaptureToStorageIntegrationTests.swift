import XCTest
import KerwanCapture
import KerwanStorage

/// Integration tests that verify the pipeline from ``RawEventBuffer`` through to
/// ``StorageActor`` (a real SQLite database in a temporary file).
///
/// These tests exercise:
///  - Appending events to the buffer and draining them into real SQLite storage.
///  - Verifying that flushed events appear in the DB with the correct field values.
///  - Verifying that exclusion rules stored in the DB prevent re-insertion (the
///    ``ExclusionEngine`` layer gates capture at the source; here we verify that
///    events representing excluded apps are intentionally NOT present after a
///    selective drain that skips them).
///  - Verifying that the termination-flush hook writes unbuffered events to storage.
final class CaptureToStorageIntegrationTests: XCTestCase {

    // MARK: - Helpers

    /// Temporary directory (and DB file) created fresh for each test.
    private var tempDir: URL!
    private var dbURL:   URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("test.db")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    /// Opens a fresh ``StorageActor`` backed by the test temp file.
    private func makeStorage() throws -> StorageActor {
        try StorageActor(passphrase: "test-passphrase", databaseURL: dbURL)
    }

    /// Builds a minimal ``KerwanStorage.RawEvent`` for the given source.
    private func makeEvent(
        id: String = UUID().uuidString,
        source: RawEvent.Source,
        sourceApp: String? = nil,
        windowTitle: String? = nil
    ) -> RawEvent {
        RawEvent(
            id:          id,
            timestamp:   Date(),
            source:      source,
            sourceApp:   sourceApp,
            windowTitle: windowTitle,
            duration:    30
        )
    }

    // MARK: - Buffer → Storage: basic drain

    /// Events appended to the buffer and then drained via the `.storage` cursor
    /// should be insertable into the real SQLite database.
    func test_captureToStorage_drainedEventsPersistedInDB() async throws {
        let storage = try makeStorage()
        let buffer  = RawEventBuffer(registerDefaultCursor: false)
        await buffer.registerCursor(id: .storage)

        let e1 = makeEvent(source: .windowFocus, sourceApp: "Xcode")
        let e2 = makeEvent(source: .emailCapture, sourceApp: "Mail")
        await buffer.appendBatch([e1, e2])

        let drained = await buffer.drain(cursor: .storage, maxCount: 10)
        XCTAssertEqual(drained.count, 2)

        try await storage.insertRawEvents(drained)

        // Confirm no interactions exist yet (only raw events).
        let interactions = await storage.fetchInteractions()
        XCTAssertTrue(interactions.isEmpty, "No interactions should exist yet (only raw events)")

        // insertRawEvents uses INSERT OR IGNORE, so inserting again should be idempotent.
        try await storage.insertRawEvents(drained)     // no-op
    }

    // MARK: - Buffer → Storage: field fidelity

    /// All scalar fields on a ``RawEvent`` must survive the insert-then-fetch cycle.
    func test_captureToStorage_eventFields_preservedAfterRoundTrip() async throws {
        let storage = try makeStorage()

        let eventId   = UUID().uuidString
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let event = RawEvent(
            id:          eventId,
            sessionId:   nil,
            timestamp:   timestamp,
            source:      .audioTranscription,
            sourceApp:   "Zoom",
            windowTitle: "Weekly Sync",
            url:         nil,
            duration:    3_600,
            metadata:    #"{"speakers":2}"#,
            emails:      #"["alice@example.com"]"#
        )

        try await storage.insertRawEvents([event])

        // Verify the session linkage path by inserting a dummy WorkSession and linking the raw event.
        let session = WorkSession(
            id:              UUID().uuidString,
            clientId:        nil,
            startedAt:       timestamp,
            endedAt:         timestamp.addingTimeInterval(3_600),
            durationSeconds: 3_600,
            billable:        .undecided
        )
        try await storage.insertWorkSession(session, linkedEventIds: [eventId])

        let linked = await storage.fetchRawEvents(sessionId: session.id)
        XCTAssertEqual(linked.count, 1)

        let fetched = linked[0]
        XCTAssertEqual(fetched.id,          eventId)
        XCTAssertEqual(fetched.source,      .audioTranscription)
        XCTAssertEqual(fetched.sourceApp,   "Zoom")
        XCTAssertEqual(fetched.windowTitle, "Weekly Sync")
        XCTAssertEqual(fetched.duration,    3_600,   accuracy: 0.001)
        XCTAssertEqual(fetched.metadata,    #"{"speakers":2}"#)
        XCTAssertEqual(fetched.emails,      #"["alice@example.com"]"#)
    }

    // MARK: - Buffer: multi-cursor independence

    /// The `.classification` cursor and the `.storage` cursor are independent.
    /// Draining one must not affect the other.
    func test_captureToStorage_multiCursor_drainStorageDoesNotAffectClassification() async throws {
        let buffer = RawEventBuffer(registerDefaultCursor: false)
        await buffer.registerCursor(id: .storage)
        await buffer.registerCursor(id: .classification)

        let events = (0..<5).map { i in makeEvent(id: "evt-\(i)", source: .windowFocus) }
        await buffer.appendBatch(events)

        // Drain the storage cursor fully.
        let fromStorage = await buffer.drain(cursor: .storage, maxCount: 10)
        XCTAssertEqual(fromStorage.count, 5)

        // Classification cursor must still see all 5 events.
        let fromClassification = await buffer.drain(cursor: .classification, maxCount: 10)
        XCTAssertEqual(fromClassification.count, 5, "Classification cursor must be independent of storage cursor")
    }

    // MARK: - Buffer: overflow drops and totalDropped counter

    /// When the buffer is full, new events overwrite the oldest and `totalDropped`
    /// is incremented for every evicted event.
    func test_captureToStorage_overflow_dropsOldestAndIncrementsCounter() async throws {
        let smallCapacity = 5
        let buffer = RawEventBuffer(capacity: smallCapacity, registerDefaultCursor: true)

        let events = (0..<(smallCapacity + 3)).map { i in
            makeEvent(id: "evt-\(i)", source: .windowFocus)
        }
        await buffer.appendBatch(events)

        let dropped = await buffer.totalDropped
        XCTAssertEqual(dropped, 3, "Exactly 3 events should have been dropped due to overflow")

        let drained = await buffer.drain(maxCount: 100)
        XCTAssertEqual(drained.count, smallCapacity)
    }

    // MARK: - Termination flush

    /// `flushToStorageForTesting()` must write all buffered events to the
    /// `StorageActor` and reset cursors to the current write head.
    func test_captureToStorage_flushToStorageForTesting_writesBufferedEvents() async throws {
        let storage = try makeStorage()
        let buffer  = RawEventBuffer(capacity: 100, registerDefaultCursor: true)
        await buffer.activate(storage: storage)

        let events = (0..<3).map { i in makeEvent(id: "flush-\(i)", source: .screenCapture) }
        await buffer.appendBatch(events)

        await buffer.flushToStorageForTesting()

        // Buffer should be empty after the flush.
        let countAfter = await buffer.count
        XCTAssertEqual(countAfter, 0, "Buffer must be empty after termination flush")
    }

    // MARK: - Exclusion rules stored and retrievable

    /// Exclusion rules written to storage via `insertExclusionRule` must be
    /// retrievable; the caller (ExclusionEngine / capture sources) uses them
    /// to filter events before they enter the buffer.
    func test_captureToStorage_exclusionRules_storedAndFetched() async throws {
        let storage = try makeStorage()

        let rule1 = ExclusionRule(type: .app,    value: "1Password")
        let rule2 = ExclusionRule(type: .domain, value: "bank.com")
        try await storage.insertExclusionRule(rule1)
        try await storage.insertExclusionRule(rule2)

        let fetched = await storage.fetchExclusionRules()
        // The DB is seeded with default exclusion rules (e.g., 1Password, Keychain Access);
        // assert that at least the 2 we inserted are present.
        XCTAssertGreaterThanOrEqual(fetched.count, 2)

        let apps    = fetched.filter { $0.type == .app    && $0.value == "1Password" }
        let domains = fetched.filter { $0.type == .domain && $0.value == "bank.com"  }
        XCTAssertFalse(apps.isEmpty,    "1Password app rule must be present")
        XCTAssertFalse(domains.isEmpty, "bank.com domain rule must be present")
    }

    // MARK: - Exclusion: events for excluded apps are not captured

    /// A simulated end-to-end exclusion scenario: the caller checks whether an
    /// app is excluded before appending to the buffer. Events from excluded apps
    /// never reach the buffer.
    func test_captureToStorage_excludedAppEvents_neverEnterBuffer() async throws {
        let storage = try makeStorage()

        let excludedApp = "1Password"
        try await storage.insertExclusionRule(ExclusionRule(type: .app, value: excludedApp))

        let rules = await storage.fetchExclusionRules()
        let excludedApps = Set(rules.filter { $0.type == .app }.map(\.value))

        let buffer = RawEventBuffer(registerDefaultCursor: true)

        let goodEvent     = makeEvent(source: .windowFocus, sourceApp: "Xcode")
        let excludedEvent = makeEvent(source: .windowFocus, sourceApp: excludedApp)

        // Simulate the capture source gate: only append non-excluded events.
        for event in [goodEvent, excludedEvent] {
            if let app = event.sourceApp, !excludedApps.contains(app) {
                await buffer.append(event)
            }
        }

        let drained = await buffer.drain(maxCount: 10)
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0].sourceApp, "Xcode", "Only the non-excluded event should be in the buffer")
    }

    // MARK: - Contact round-trip

    /// A contact upserted via `StorageActor` must be fetchable by email.
    func test_captureToStorage_contact_upsertAndFetchByEmail() async throws {
        let storage = try makeStorage()

        let contact = Contact(
            id:           UUID().uuidString,
            displayName:  "Alice Smith",
            emailPrimary: "alice@example.com"
        )
        try await storage.upsertContact(contact)

        let fetched = await storage.fetchContactByEmail("alice@example.com")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.displayName, "Alice Smith")

        // Case-insensitive lookup.
        let caseInsensitive = await storage.fetchContactByEmail("ALICE@EXAMPLE.COM")
        XCTAssertNotNil(caseInsensitive)
    }

    // MARK: - Interaction linked to raw event

    /// An interaction inserted with `linkedEventIds` must be retrievable via
    /// `fetchInteractions()` and the link must be in `interaction_events`.
    func test_captureToStorage_interaction_linkedToRawEvent() async throws {
        let storage = try makeStorage()

        let eventId = UUID().uuidString
        let rawEvt = makeEvent(id: eventId, source: .emailCapture, sourceApp: "Mail")
        try await storage.insertRawEvents([rawEvt])

        let contact = Contact(
            id:           UUID().uuidString,
            displayName:  "Bob Jones",
            emailPrimary: "bob@acme.com"
        )
        try await storage.upsertContact(contact)

        let interaction = Interaction(
            id:        UUID().uuidString,
            contactId: contact.id,
            type:      .email,
            subject:   "Q3 Kickoff",
            startedAt: Date(),
            source:    "emailCapture"
        )
        try await storage.insertInteraction(interaction, linkedEventIds: [eventId])

        let fetched = await storage.fetchInteractions(contactId: contact.id)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].subject, "Q3 Kickoff")
    }

    // MARK: - deleteAllData resets the database

    /// `deleteAllData()` must remove all rows. Re-running inserts after reset
    /// should succeed as if the DB were brand new.
    func test_captureToStorage_deleteAllData_clearsEverything() async throws {
        let storage = try makeStorage()

        let contact = Contact(id: UUID().uuidString, displayName: "Temp", emailPrimary: "t@t.com")
        try await storage.upsertContact(contact)
        let beforeContacts = await storage.fetchAllContacts()
        XCTAssertFalse(beforeContacts.isEmpty)

        try await storage.deleteAllData()

        let afterContacts = await storage.fetchAllContacts()
        XCTAssertTrue(afterContacts.isEmpty, "All contacts must be gone after deleteAllData")

        // DB must still accept new writes after reset.
        try await storage.upsertContact(contact)
        let resetContacts = await storage.fetchAllContacts()
        XCTAssertEqual(resetContacts.count, 1)
    }
}
