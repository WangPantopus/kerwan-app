// EmailCaptureServiceTests.swift
// Kerwan — Email capture tests
//
// All tests use MockIMAPClient; no live network connections.
//
// Note: `Recorder<T>` is defined in GmailOAuthManagerTests.swift and is
// accessible here because both files compile in the same test module.
//
// Test groups
// ───────────
//  IMAPAddressTests              — address model helpers
//  IMAPClientParsingTests        — static formatters (white-box)
//  EmailCaptureMetadataTests     — encode/decode, rawText builder
//  EmailCaptureServiceLifecycleTests — connect, disconnect
//  HistoricalImportTests         — happy path, resume, dedup, batch error, auth retry
//  IncrementalSyncTests          — happy path, dedup, stop on disconnect
//  ImportProgressTests           — progress snapshots

import XCTest
@testable import Kerwan

// MARK: - MockIMAPClient
//
// All configuration (responses, message bank, error injection) is passed
// in `init` and is immutable thereafter.  This avoids the need to mutate
// actor-isolated properties from outside the actor.

actor MockIMAPClient: IMAPClientProtocol {

    // MARK: Immutable configuration

    private let authenticateResults: [Result<Void, Error>]
    private let searchUIDLists:      [[UInt32]]
    private let messageBank:         [IMAPMessage]
    private let fetchError:          Error?

    // MARK: Mutable call-tracking state (actor-isolated)

    private(set) var connectCallCount      = 0
    private(set) var authenticateCallCount = 0
    private(set) var selectCallCount       = 0
    private(set) var searchCallCount       = 0
    private(set) var fetchCallCount        = 0
    private(set) var logoutCallCount       = 0
    private(set) var fetchedUIDSets:       [[UInt32]] = []
    private(set) var lastAuthToken:         String?

    var isConnected: Bool = false

    // MARK: Init

    init(
        authenticateResults: [Result<Void, Error>] = [.success(())],
        searchUIDLists:      [[UInt32]]            = [[]],
        messageBank:         [IMAPMessage]          = [],
        fetchError:          Error?                 = nil
    ) {
        self.authenticateResults = authenticateResults
        self.searchUIDLists      = searchUIDLists
        self.messageBank         = messageBank
        self.fetchError          = fetchError
    }

    // MARK: IMAPClientProtocol

    func connect(host: String, port: UInt16) async throws {
        connectCallCount += 1
        isConnected = true
    }

    func authenticate(email: String, accessToken: String) async throws {
        let idx = min(authenticateCallCount, authenticateResults.count - 1)
        authenticateCallCount += 1
        lastAuthToken = accessToken
        try authenticateResults[idx].get()
    }

    func selectMailbox(_ mailbox: String) async throws {
        selectCallCount += 1
    }

    func searchUIDs(since date: Date) async throws -> [UInt32] {
        let idx = min(searchCallCount, searchUIDLists.count - 1)
        searchCallCount += 1
        return searchUIDLists[idx]
    }

    func fetchMessages(uids: [UInt32]) async throws -> [IMAPMessage] {
        fetchCallCount += 1
        fetchedUIDSets.append(uids)
        if let err = fetchError { throw err }
        return messageBank.filter { uids.contains($0.uid) }
    }

    func logout() async {
        logoutCallCount += 1
        isConnected = false
    }
}

// MARK: - EmailMockEventDelegate

actor EmailMockEventDelegate: CaptureEventDelegate {
    private(set) var allEvents: [RawEvent] = []
    func didCapture(_ events: [RawEvent]) async {
        allEvents.append(contentsOf: events)
    }
}

// MARK: - Test fixtures

private func makeTestMessage(
    uid:             UInt32,
    messageId:       String?  = nil,
    subject:         String?  = "Test Subject",
    from:            String   = "sender@example.com",
    body:            String?  = "Hello world",
    date:            Date     = Date(timeIntervalSince1970: 1_000_000),
    hasAttachments:  Bool     = false,
    isBodyCorrupted: Bool     = false
) -> IMAPMessage {
    IMAPMessage(
        uid:             uid,
        messageId:       messageId ?? "msg-\(uid)@test",
        from:            [IMAPAddress(name: "Sender", email: from)],
        to:              [IMAPAddress(name: "Me",     email: "me@gmail.com")],
        cc:              [],
        subject:         subject,
        date:            date,
        bodyText:        body,
        hasAttachments:  hasAttachments,
        isBodyCorrupted: isBodyCorrupted
    )
}

private func makeTestAccount(email: String = "me@gmail.com") -> GmailAccount {
    GmailAccount(email: email, refreshToken: "RT", accessToken: "AT")
}

// MARK: - Environment factory

extension EmailCaptureService.Environment {
    static func mock(
        imapClient:         MockIMAPClient                                             = MockIMAPClient(),
        tokenProvider:      @escaping @Sendable (GmailAccount) async throws -> String  = { _ in "TOKEN" },
        forceRefresh:       @escaping @Sendable (GmailAccount) async throws -> String  = { _ in "FRESH_TOKEN" },
        importedIds:        @escaping @Sendable (String) async -> Bool                 = { _ in false },
        lastSyncDate:       Date?                                                       = nil,
        lastImportedUID:    UInt32?                                                     = nil,
        savedSyncDates:     Recorder<(String, Date)>                                    = Recorder(),
        savedUIDs:          Recorder<(String, UInt32)>                                  = Recorder(),
        batchDelay:         TimeInterval                                                = 0,
        syncInterval:       TimeInterval                                                = 300,
        historyLookback:    TimeInterval                                                = 60 * 60 * 24 * 365 * 2,
        batchSize:          Int                                                         = 100,
        now:                Date                                                        = Date(timeIntervalSince1970: 1_000_000)
    ) -> EmailCaptureService.Environment {

        let clientCapture = imapClient
        return EmailCaptureService.Environment(
            makeIMAPClient:      { clientCapture },
            getAccessToken:      tokenProvider,
            forceRefreshToken:   forceRefresh,
            isMessageImported:   importedIds,
            loadLastSyncDate:    { _ in lastSyncDate },
            saveLastSyncDate:    { e, d in savedSyncDates.record((e, d)) },
            loadLastImportedUID: { _ in lastImportedUID },
            saveLastImportedUID: { e, u in savedUIDs.record((e, u)) },
            currentDate:         { now },
            batchDelay:          batchDelay,
            syncInterval:        syncInterval,
            historyLookback:     historyLookback,
            batchSize:           batchSize
        )
    }
}

// MARK: - IMAPAddressTests

final class IMAPAddressTests: XCTestCase {

    func test_displayString_withName() {
        XCTAssertEqual(
            IMAPAddress(name: "Alice", email: "alice@example.com").displayString,
            "Alice <alice@example.com>"
        )
    }

    func test_displayString_withoutName() {
        XCTAssertEqual(
            IMAPAddress(name: nil, email: "bob@example.com").displayString,
            "bob@example.com"
        )
    }

    func test_displayString_emptyNameTreatedAsNoName() {
        XCTAssertEqual(
            IMAPAddress(name: "", email: "c@x.com").displayString,
            "c@x.com"
        )
    }

    func test_encodeDecode_roundTrip() throws {
        let a = IMAPAddress(name: "Dave", email: "d@e.com")
        let d = try JSONDecoder().decode(IMAPAddress.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(d, a)
    }
}

// MARK: - IMAPClientParsingTests (white-box)

final class IMAPClientParsingTests: XCTestCase {

    func test_imapDateFormatter_producesThreeParts() {
        let str   = IMAPClient.imapDateFormatter.string(from: Date(timeIntervalSince1970: 1_000_000))
        let parts = str.components(separatedBy: "-")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[1].count, 3, "Month abbreviation must be 3 letters")
    }

    func test_imapDateFormatter_locale_isEnglish() {
        // Jan 15, 2001 at noon UTC — safely within January even accounting for timezone offsets.
        let str = IMAPClient.imapDateFormatter.string(from: Date(timeIntervalSinceReferenceDate: 14 * 86400 + 43200))
        XCTAssertTrue(str.contains("Jan"))
    }
}

// MARK: - EmailCaptureMetadataTests

final class EmailCaptureMetadataTests: XCTestCase {

    func test_from_message_setsAllFields() {
        let meta = EmailCaptureMetadata.from(makeTestMessage(uid: 1, messageId: "x@test", body: "Hi"))
        XCTAssertEqual(meta.messageId, "x@test")
        XCTAssertFalse(meta.isBodyTruncated)
        XCTAssertFalse(meta.isBodyCorrupted)
        XCTAssertFalse(meta.hasAttachments)
        XCTAssertEqual(meta.bodyPreview, "Hi")
    }

    func test_bodyTruncation_at2000Chars() {
        let meta = EmailCaptureMetadata.from(makeTestMessage(uid: 2, body: String(repeating: "x", count: 3000)))
        XCTAssertTrue(meta.isBodyTruncated)
        XCTAssertEqual(meta.bodyPreview?.count, 2000)
    }

    func test_bodyExactly2000_notTruncated() {
        let meta = EmailCaptureMetadata.from(makeTestMessage(uid: 3, body: String(repeating: "y", count: 2000)))
        XCTAssertFalse(meta.isBodyTruncated)
    }

    func test_rawText_includesSubjectFromBody() {
        let meta = EmailCaptureMetadata.from(makeTestMessage(uid: 4, subject: "Hi", from: "a@b.com", body: "Content"))
        let raw  = meta.rawText ?? ""
        XCTAssertTrue(raw.contains("Subject: Hi"))
        XCTAssertTrue(raw.contains("From:"))
        XCTAssertTrue(raw.contains("Content"))
    }

    func test_encodeDecode_roundTrip() throws {
        let meta    = EmailCaptureMetadata.from(makeTestMessage(uid: 5, messageId: "id@x.com"))
        let decoded = EmailCaptureMetadata.decode(from: meta.jsonString!)!
        XCTAssertEqual(decoded.messageId, meta.messageId)
        XCTAssertEqual(decoded.subject,   meta.subject)
    }

    func test_snakeCaseKeys() throws {
        let json = EmailCaptureMetadata.from(makeTestMessage(uid: 6, hasAttachments: true)).jsonString!
        for key in ["message_id", "has_attachments", "body_preview", "is_body_truncated",
                    "is_body_corrupted", "raw_text"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "Missing key: \(key)")
        }
    }

    func test_nilBody_nilPreviewNotTruncated() {
        let meta = EmailCaptureMetadata.from(makeTestMessage(uid: 7, body: nil))
        XCTAssertNil(meta.bodyPreview)
        XCTAssertFalse(meta.isBodyTruncated)
    }

    func test_corruptedBodyFlag_preserved() {
        XCTAssertTrue(EmailCaptureMetadata.from(makeTestMessage(uid: 8, isBodyCorrupted: true)).isBodyCorrupted)
    }

    func test_hasAttachmentsFlag_preserved() {
        XCTAssertTrue(EmailCaptureMetadata.from(makeTestMessage(uid: 9, hasAttachments: true)).hasAttachments)
    }

    func test_decode_invalidJSON_returnsNil() {
        XCTAssertNil(EmailCaptureMetadata.decode(from: "not json"))
    }
}

// MARK: - EmailCaptureServiceLifecycleTests

@MainActor
final class EmailCaptureServiceLifecycleTests: XCTestCase {

    // MARK: Helpers

    private func makeService(client: MockIMAPClient) -> (EmailCaptureService, EmailMockEventDelegate) {
        let delegate = EmailMockEventDelegate()
        let env      = EmailCaptureService.Environment.mock(imapClient: client)
        return (EmailCaptureService(eventDelegate: delegate, environment: env), delegate)
    }

    // MARK: Tests

    func test_connect_callsConnectAuthenticateSelect() async throws {
        let client = MockIMAPClient()
        let (service, _) = makeService(client: client)
        try await service.connect(account: makeTestAccount())

        let cc = await client.connectCallCount
        let ac = await client.authenticateCallCount
        let sc = await client.selectCallCount
        XCTAssertEqual(cc, 1); XCTAssertEqual(ac, 1); XCTAssertEqual(sc, 1)
    }

    func test_connect_passesTokenToAuthenticate() async throws {
        let client = MockIMAPClient()
        let env    = EmailCaptureService.Environment.mock(
            imapClient:    client,
            tokenProvider: { _ in "MY_TOKEN" }
        )
        let service = EmailCaptureService(eventDelegate: EmailMockEventDelegate(), environment: env)
        try await service.connect(account: makeTestAccount())

        let token = await client.lastAuthToken
        XCTAssertEqual(token, "MY_TOKEN")
    }

    func test_connect_authFailure_retriesWithFreshToken() async throws {
        // First authenticate call → fail; second → succeed.
        let client = MockIMAPClient(
            authenticateResults: [
                .failure(IMAPError.authenticationFailed("stale")),
                .success(())
            ]
        )
        let env = EmailCaptureService.Environment.mock(
            imapClient:    client,
            tokenProvider: { _ in "STALE" },
            forceRefresh:  { _ in "FRESH" }
        )
        let service = EmailCaptureService(eventDelegate: EmailMockEventDelegate(), environment: env)
        try await service.connect(account: makeTestAccount())

        let ac    = await client.authenticateCallCount
        let token = await client.lastAuthToken
        XCTAssertEqual(ac,    2)
        XCTAssertEqual(token, "FRESH")
    }

    func test_connect_authFailureTwice_throws() async throws {
        let client = MockIMAPClient(
            authenticateResults: [
                .failure(IMAPError.authenticationFailed("bad1")),
                .failure(IMAPError.authenticationFailed("bad2"))
            ]
        )
        let env     = EmailCaptureService.Environment.mock(imapClient: client)
        let service = EmailCaptureService(eventDelegate: EmailMockEventDelegate(), environment: env)

        await XCTAssertThrowsErrorAsync(try await service.connect(account: makeTestAccount())) { err in
            guard case IMAPError.authenticationFailed = err else {
                XCTFail("Expected authenticationFailed, got \(err)"); return
            }
        }
    }

    func test_disconnect_callsLogout() async throws {
        let client = MockIMAPClient()
        let (service, _) = makeService(client: client)
        try await service.connect(account: makeTestAccount())
        await service.disconnect()

        let lc = await client.logoutCallCount
        XCTAssertEqual(lc, 1)
    }

    func test_disconnect_resetsProgressToIdle() async throws {
        let client = MockIMAPClient()
        let (service, _) = makeService(client: client)
        try await service.connect(account: makeTestAccount())
        await service.disconnect()
        let p = await service.importProgress
        XCTAssertEqual(p, ImportProgress.idle)
    }
}

// MARK: - HistoricalImportTests

@MainActor
final class HistoricalImportTests: XCTestCase {

    // MARK: Helpers

    private func makeConnectedService(
        client:          MockIMAPClient,
        importedIds:     @escaping @Sendable (String) async -> Bool = { _ in false },
        lastImportedUID: UInt32?                                    = nil,
        savedUIDs:       Recorder<(String, UInt32)>                 = Recorder(),
        savedSyncDates:  Recorder<(String, Date)>                   = Recorder(),
        batchSize:       Int                                        = 100
    ) async throws -> (EmailCaptureService, EmailMockEventDelegate) {
        let delegate = EmailMockEventDelegate()
        let env = EmailCaptureService.Environment.mock(
            imapClient:      client,
            importedIds:     importedIds,
            lastImportedUID: lastImportedUID,
            savedSyncDates:  savedSyncDates,
            savedUIDs:       savedUIDs,
            batchDelay:      0,
            batchSize:       batchSize
        )
        let service = EmailCaptureService(eventDelegate: delegate, environment: env)
        try await service.connect(account: makeTestAccount())
        return (service, delegate)
    }

    // MARK: Happy path

    func test_happyPath_emitsOneEventPerMessage() async throws {
        let client = MockIMAPClient(
            searchUIDLists: [[1, 2, 3]],
            messageBank:    (1...3).map { makeTestMessage(uid: $0, messageId: "m\($0)@t") }
        )
        let (service, delegate) = try await makeConnectedService(client: client)
        let progress = try await service.startHistoricalImport()

        let events = await delegate.allEvents
        XCTAssertEqual(events.count,             3)
        XCTAssertEqual(progress.totalMessages,   3)
        XCTAssertEqual(progress.importedMessages, 3)
        XCTAssertTrue(progress.isComplete)
    }

    func test_events_haveEmailSource() async throws {
        let client = MockIMAPClient(
            searchUIDLists: [[10]],
            messageBank:    [makeTestMessage(uid: 10)]
        )
        let (service, delegate) = try await makeConnectedService(client: client)
        _ = try await service.startHistoricalImport()

        let event = await delegate.allEvents.first
        XCTAssertEqual(event?.source,    .email)
        XCTAssertEqual(event?.sourceApp, "Gmail")
    }

    func test_startedAt_matchesEmailDate() async throws {
        let emailDate = Date(timeIntervalSince1970: 500_000)
        let client    = MockIMAPClient(
            searchUIDLists: [[5]],
            messageBank:    [makeTestMessage(uid: 5, date: emailDate)]
        )
        let (service, delegate) = try await makeConnectedService(client: client)
        _ = try await service.startHistoricalImport()

        let event = await delegate.allEvents.first
        XCTAssertEqual(event?.startedAt.timeIntervalSince1970 ?? 0,
                       emailDate.timeIntervalSince1970, accuracy: 1)
    }

    func test_metadataJSON_containsMessageId() async throws {
        let client = MockIMAPClient(
            searchUIDLists: [[7]],
            messageBank:    [makeTestMessage(uid: 7, messageId: "unique-id@example")]
        )
        let (service, delegate) = try await makeConnectedService(client: client)
        _ = try await service.startHistoricalImport()

        let json = await delegate.allEvents.first?.metadataJSON ?? ""
        XCTAssertTrue(json.contains("unique-id@example"))
    }

    // MARK: Deduplication

    func test_deduplication_skipsAlreadyImported() async throws {
        let client = MockIMAPClient(
            searchUIDLists: [[1, 2, 3]],
            messageBank:    [
                makeTestMessage(uid: 1, messageId: "dup@test"),
                makeTestMessage(uid: 2, messageId: "new1@test"),
                makeTestMessage(uid: 3, messageId: "new2@test")
            ]
        )
        let (service, delegate) = try await makeConnectedService(
            client:      client,
            importedIds: { mid in mid == "dup@test" }
        )
        _ = try await service.startHistoricalImport()

        let ids = await delegate.allEvents
            .compactMap { $0.metadataJSON }
            .compactMap { EmailCaptureMetadata.decode(from: $0)?.messageId }
        XCTAssertEqual(ids.count, 2)
        XCTAssertFalse(ids.contains("dup@test"))
    }

    // MARK: Resume

    func test_resumeFromLastUID_skipsAlreadyProcessed() async throws {
        let client = MockIMAPClient(
            searchUIDLists: [[1, 2, 3, 4, 5]],
            messageBank:    (1...5).map { makeTestMessage(uid: $0, messageId: "m\($0)@t") }
        )
        let (service, delegate) = try await makeConnectedService(
            client:          client,
            lastImportedUID: 3   // UIDs 1-3 already done
        )
        let progress = try await service.startHistoricalImport()
        let events   = await delegate.allEvents

        XCTAssertEqual(events.count,              2)   // only UIDs 4 and 5
        XCTAssertEqual(progress.importedMessages, 5)   // 3 skipped + 2 new
        XCTAssertTrue(progress.isComplete)
    }

    // MARK: Batching

    func test_batching_correctNumberOfFetchCalls() async throws {
        // 5 UIDs, batchSize=2 → 3 fetch calls
        let client = MockIMAPClient(
            searchUIDLists: [[1, 2, 3, 4, 5]],
            messageBank:    (1...5).map { makeTestMessage(uid: $0, messageId: "m\($0)@t") }
        )
        let (service, _) = try await makeConnectedService(client: client, batchSize: 2)
        _ = try await service.startHistoricalImport()

        let fc = await client.fetchCallCount
        XCTAssertEqual(fc, 3)
    }

    func test_batching_UIDs_sentAscendingOrder() async throws {
        let client = MockIMAPClient(
            searchUIDLists: [[30, 10, 20]],   // SEARCH returns unsorted
            messageBank:    [10, 20, 30].map { makeTestMessage(uid: $0, messageId: "m\($0)@t") }
        )
        let (service, _) = try await makeConnectedService(client: client, batchSize: 1)
        _ = try await service.startHistoricalImport()

        let sets = await client.fetchedUIDSets
        XCTAssertEqual(sets.flatMap { $0 }, [10, 20, 30])
    }

    // MARK: Error handling

    func test_fetchError_skipsBatch_doesNotThrow() async throws {
        let client = MockIMAPClient(
            searchUIDLists: [[1, 2, 3]],
            fetchError:     IMAPError.commandFailed("server error")
        )
        let (service, delegate) = try await makeConnectedService(client: client)

        let progress = try await service.startHistoricalImport()
        XCTAssertNotNil(progress)  // did not throw
        let events = await delegate.allEvents
        XCTAssertEqual(events.count, 0)  // all batches errored → 0 imported
    }

    func test_corruptedBody_stillEmitsEvent() async throws {
        let client = MockIMAPClient(
            searchUIDLists: [[99]],
            messageBank:    [makeTestMessage(uid: 99, isBodyCorrupted: true)]
        )
        let (service, delegate) = try await makeConnectedService(client: client)
        _ = try await service.startHistoricalImport()

        let events = await delegate.allEvents
        XCTAssertEqual(events.count, 1)
        let meta = events.first.flatMap { $0.metadataJSON }
            .flatMap { EmailCaptureMetadata.decode(from: $0) }
        XCTAssertTrue(meta?.isBodyCorrupted ?? false)
    }

    // MARK: Persistence

    func test_savesLastImportedUID_afterEachBatch() async throws {
        let savedUIDs = Recorder<(String, UInt32)>()
        let client    = MockIMAPClient(
            searchUIDLists: [[10, 20, 30]],
            messageBank:    [10, 20, 30].map { makeTestMessage(uid: $0, messageId: "m\($0)@t") }
        )
        let (service, _) = try await makeConnectedService(
            client:    client,
            savedUIDs: savedUIDs,
            batchSize: 100
        )
        _ = try await service.startHistoricalImport()

        XCTAssertFalse(savedUIDs.values.isEmpty)
        XCTAssertEqual(savedUIDs.values.last?.1, 30)
    }

    func test_savesLastSyncDate_onCompletion() async throws {
        let savedSyncDates = Recorder<(String, Date)>()
        let client         = MockIMAPClient(searchUIDLists: [[1]], messageBank: [makeTestMessage(uid: 1)])
        let (service, _)   = try await makeConnectedService(
            client:         client,
            savedSyncDates: savedSyncDates
        )
        _ = try await service.startHistoricalImport()
        XCTAssertFalse(savedSyncDates.values.isEmpty)
    }

    func test_emptyMailbox_completesImmediately() async throws {
        let client = MockIMAPClient(searchUIDLists: [[]])
        let (service, delegate) = try await makeConnectedService(client: client)
        let progress = try await service.startHistoricalImport()
        XCTAssertEqual(progress.totalMessages, 0)
        XCTAssertTrue(progress.isComplete)
        let events = await delegate.allEvents
        XCTAssertEqual(events.count, 0)
    }
}

// MARK: - IncrementalSyncTests

@MainActor
final class IncrementalSyncTests: XCTestCase {

    func test_incrementalSync_findsNewMessages() async throws {
        // Search call 1 (historical = empty), search call 2+ (incremental = 2 UIDs)
        let client = MockIMAPClient(
            searchUIDLists: [[], [101, 102]],
            messageBank:    [
                makeTestMessage(uid: 101, messageId: "n1@test"),
                makeTestMessage(uid: 102, messageId: "n2@test")
            ]
        )
        let delegate = EmailMockEventDelegate()
        let env = EmailCaptureService.Environment.mock(
            imapClient:   client,
            syncInterval: 0.001
        )
        let service = EmailCaptureService(eventDelegate: delegate, environment: env)
        try await service.connect(account: makeTestAccount())
        await service.startIncrementalSync()
        try await Task.sleep(nanoseconds: 80_000_000)
        await service.disconnect()

        let events = await delegate.allEvents
        XCTAssertGreaterThanOrEqual(events.count, 2)
    }

    func test_incrementalSync_deduplicates() async throws {
        let client = MockIMAPClient(
            searchUIDLists: [[], [200, 201]],
            messageBank:    [
                makeTestMessage(uid: 200, messageId: "existing@t"),
                makeTestMessage(uid: 201, messageId: "fresh@t")
            ]
        )
        let delegate = EmailMockEventDelegate()
        let env = EmailCaptureService.Environment.mock(
            imapClient:   client,
            importedIds:  { mid in mid == "existing@t" },
            syncInterval: 0.001
        )
        let service = EmailCaptureService(eventDelegate: delegate, environment: env)
        try await service.connect(account: makeTestAccount())
        await service.startIncrementalSync()
        try await Task.sleep(nanoseconds: 80_000_000)
        await service.disconnect()

        let ids = await delegate.allEvents
            .compactMap { $0.metadataJSON }
            .compactMap { EmailCaptureMetadata.decode(from: $0)?.messageId }
        XCTAssertFalse(ids.contains("existing@t"))
    }

    func test_incrementalSync_stopsOnDisconnect() async throws {
        let client = MockIMAPClient(searchUIDLists: Array(repeating: [], count: 200))
        let env = EmailCaptureService.Environment.mock(
            imapClient:   client,
            syncInterval: 0.001
        )
        let service = EmailCaptureService(eventDelegate: EmailMockEventDelegate(), environment: env)
        try await service.connect(account: makeTestAccount())
        await service.startIncrementalSync()

        try await Task.sleep(nanoseconds: 20_000_000)
        let countBefore = await client.searchCallCount
        await service.disconnect()
        try await Task.sleep(nanoseconds: 40_000_000)
        let countAfter = await client.searchCallCount

        // An in-flight sync may complete after cancel() is called before the task
        // checks isCancelled, so allow at most one additional search after disconnect.
        XCTAssertLessThanOrEqual(countAfter, countBefore + 1, "At most one in-flight search may complete after disconnect")
    }

    func test_startIncrementalSync_doubleCall_isNoOp() async throws {
        let client = MockIMAPClient(searchUIDLists: Array(repeating: [], count: 200))
        let env = EmailCaptureService.Environment.mock(
            imapClient:   client,
            syncInterval: 60   // long interval — first tick won't fire during test
        )
        let service = EmailCaptureService(eventDelegate: EmailMockEventDelegate(), environment: env)
        try await service.connect(account: makeTestAccount())

        await service.startIncrementalSync()
        await service.startIncrementalSync()   // no-op

        let sc = await client.searchCallCount
        XCTAssertEqual(sc, 0)  // 60s interval hasn't elapsed
        await service.disconnect()
    }

    func test_incrementalSync_updatesLastSyncDate() async throws {
        let savedSyncDates = Recorder<(String, Date)>()
        let client         = MockIMAPClient(searchUIDLists: Array(repeating: [], count: 10))
        let env = EmailCaptureService.Environment.mock(
            imapClient:     client,
            savedSyncDates: savedSyncDates,
            syncInterval:   0.001
        )
        let service = EmailCaptureService(eventDelegate: EmailMockEventDelegate(), environment: env)
        try await service.connect(account: makeTestAccount())
        await service.startIncrementalSync()
        try await Task.sleep(nanoseconds: 60_000_000)
        await service.disconnect()
        XCTAssertFalse(savedSyncDates.values.isEmpty)
    }
}

// MARK: - ImportProgressTests

final class ImportProgressTests: XCTestCase {

    func test_idle_initialValues() {
        let p = ImportProgress.idle
        XCTAssertEqual(p.totalMessages,    0)
        XCTAssertEqual(p.importedMessages, 0)
        XCTAssertFalse(p.isComplete)
        XCTAssertEqual(p.currentBatch,     0)
    }

    func test_equatability() {
        let a = ImportProgress(totalMessages: 10, importedMessages: 5, isComplete: false, currentBatch: 1)
        let b = ImportProgress(totalMessages: 10, importedMessages: 5, isComplete: false, currentBatch: 1)
        let c = ImportProgress(totalMessages: 10, importedMessages: 6, isComplete: false, currentBatch: 1)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    @MainActor
    func test_progressReflectsAllBatches() async throws {
        let client = MockIMAPClient(
            searchUIDLists: [[1, 2, 3, 4]],
            messageBank:    (1...4).map { makeTestMessage(uid: $0, messageId: "m\($0)@t") }
        )
        let delegate = EmailMockEventDelegate()
        let env = EmailCaptureService.Environment.mock(imapClient: client, batchDelay: 0, batchSize: 2)
        let service  = EmailCaptureService(eventDelegate: delegate, environment: env)
        try await service.connect(account: makeTestAccount())

        let p = try await service.startHistoricalImport()
        XCTAssertEqual(p.totalMessages,    4)
        XCTAssertEqual(p.importedMessages, 4)
        XCTAssertTrue(p.isComplete)
        XCTAssertEqual(p.currentBatch,     2)
    }
}
