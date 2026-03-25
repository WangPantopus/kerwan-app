// EmailCaptureService.swift
// Kerwan — Email capture layer
//
// Actor that drives the full Gmail → RawEvent pipeline via IMAP.
//
// Historical import
// ─────────────────
//   1. UID SEARCH SINCE <2 years ago> → full UID list
//   2. Sort ascending; batch in groups of `batchSize` (default 100).
//   3. Skip UIDs ≤ lastImportedUID (resume after an interrupted run).
//   4. Fetch each batch → check messageId deduplication → emit RawEvents.
//   5. After each batch: save lastImportedUID + 500 ms inter-batch delay.
//   6. When all batches complete: mark import done, update lastSyncDate.
//
// Incremental sync
// ────────────────
//   Every `syncInterval` (default 5 min):
//     UID SEARCH SINCE lastSyncDate → new UIDs → fetch → deduplicate → emit.
//
// Error handling
// ──────────────
//   • Network / IMAP server errors   → retry with exponential back-off:
//                                       1 min, 2 min, 4 min … up to 1 hour.
//   • Authentication failure (first) → refresh token, reconnect, retry once.
//   • IMAP error on individual batch → log + skip that batch, continue.
//   • Corrupted body                 → emit event with isBodyCorrupted=true.

import Foundation
import os

// MARK: - ImportProgress

/// Snapshot of the historical import state; safe to read from any context.
public struct ImportProgress: Sendable, Equatable {
    public let totalMessages:    Int
    public let importedMessages: Int
    public let isComplete:       Bool
    public let currentBatch:     Int

    public static let idle = ImportProgress(
        totalMessages: 0, importedMessages: 0, isComplete: false, currentBatch: 0
    )
}

// MARK: - EmailCaptureService

public actor EmailCaptureService {

    // MARK: - Environment

    public struct Environment: @unchecked Sendable {
        /// Creates a fresh IMAP client for each connection attempt.
        var makeIMAPClient: @Sendable () -> any IMAPClientProtocol

        /// Returns a valid access token (refreshes if needed) for the account.
        var getAccessToken: @Sendable (GmailAccount) async throws -> String

        /// Forces a token refresh (called after `authenticationFailed`).
        var forceRefreshToken: @Sendable (GmailAccount) async throws -> String

        /// `true` if a raw_event with this IMAP Message-ID already exists.
        var isMessageImported: @Sendable (String) async -> Bool

        /// Loads the last sync date for the account (nil → never synced).
        var loadLastSyncDate: @Sendable (String) -> Date?

        /// Persists the last sync date.
        var saveLastSyncDate: @Sendable (String, Date) -> Void

        /// Loads the last successfully imported UID (nil → not started).
        var loadLastImportedUID: @Sendable (String) -> UInt32?

        /// Persists the last successfully imported UID.
        var saveLastImportedUID: @Sendable (String, UInt32) -> Void

        /// Returns the current date (injectable for testing).
        var currentDate: @Sendable () -> Date

        /// Pause between batches (default 0.5 s).
        var batchDelay: TimeInterval

        /// Incremental-sync poll interval (default 300 s = 5 min).
        var syncInterval: TimeInterval

        /// Historical import lookback period (default 2 years in seconds).
        var historyLookback: TimeInterval

        /// Number of UIDs per FETCH batch (default 100).
        var batchSize: Int

        // MARK: Live

        public static func live(
            gMailOAuthManager:     GmailOAuthManager,
            eventDelegate:         any CaptureEventDelegate,
            isMessageImported:     @escaping @Sendable (String) async -> Bool
        ) -> Environment {
            Environment(
                makeIMAPClient:      { IMAPClient() },
                getAccessToken:      { account in
                    try await gMailOAuthManager.getValidAccessToken(for: account)
                },
                forceRefreshToken:   { account in
                    try await gMailOAuthManager.getValidAccessToken(for: account)
                },
                isMessageImported:   isMessageImported,
                loadLastSyncDate:    { email in
                    UserDefaults.standard.object(forKey: "kerwan.email.lastSync.\(email)") as? Date
                },
                saveLastSyncDate:    { email, date in
                    UserDefaults.standard.set(date, forKey: "kerwan.email.lastSync.\(email)")
                },
                loadLastImportedUID: { email in
                    let v = UserDefaults.standard.integer(forKey: "kerwan.email.lastUID.\(email)")
                    return v > 0 ? UInt32(v) : nil
                },
                saveLastImportedUID: { email, uid in
                    UserDefaults.standard.set(Int(uid), forKey: "kerwan.email.lastUID.\(email)")
                },
                currentDate:  { Date() },
                batchDelay:   0.5,
                syncInterval: 300,
                historyLookback: 60 * 60 * 24 * 365 * 2,  // 2 years
                batchSize:    100
            )
        }
    }

    // MARK: - State

    private let env:           Environment
    private let eventDelegate: any CaptureEventDelegate
    private let log = Logger(subsystem: "com.kerwan.app", category: "EmailCaptureService")

    private var imapClient:     (any IMAPClientProtocol)?
    private var currentAccount: GmailAccount?
    private var syncTask:       Task<Void, Never>?

    public private(set) var importProgress: ImportProgress = .idle

    // MARK: - Init

    public init(
        eventDelegate: any CaptureEventDelegate,
        environment:   Environment
    ) {
        self.eventDelegate = eventDelegate
        self.env           = environment
    }

    // MARK: - Public API

    /// Connects to imap.gmail.com:993 and authenticates with XOAUTH2.
    ///
    /// Retries once with a fresh token on authentication failure.
    public func connect(account: GmailAccount) async throws {
        currentAccount = account
        try await doConnect(account: account, allowTokenRefresh: true)
        log.info("EmailCaptureService connected for \(account.email, privacy: .private)")
    }

    /// Runs the full historical import (2 years of email).
    ///
    /// - Returns: Final `ImportProgress` when import completes.
    /// - Throws: Connection / IMAP errors that exhaust all retry attempts.
    @discardableResult
    public func startHistoricalImport() async throws -> ImportProgress {
        guard let account = currentAccount, let client = imapClient else {
            throw IMAPError.connectionFailed("Call connect(account:) first")
        }

        let since = env.currentDate().addingTimeInterval(-env.historyLookback)
        let allUIDs = try await client.searchUIDs(since: since)
        let sortedUIDs = allUIDs.sorted()

        let lastImported = env.loadLastImportedUID(account.email)

        // Skip UIDs already processed in a previous (interrupted) run.
        let pendingUIDs = lastImported != nil
            ? sortedUIDs.filter { $0 > lastImported! }
            : sortedUIDs

        importProgress = ImportProgress(
            totalMessages:    sortedUIDs.count,
            importedMessages: sortedUIDs.count - pendingUIDs.count,
            isComplete:       false,
            currentBatch:     0
        )

        let batches = stride(from: 0, to: pendingUIDs.count, by: env.batchSize)
            .map { Array(pendingUIDs[$0..<min($0 + env.batchSize, pendingUIDs.count)]) }

        var imported = importProgress.importedMessages

        for (batchIndex, batch) in batches.enumerated() {
            do {
                let messages = try await client.fetchMessages(uids: batch)
                let newEvents = try await buildEvents(from: messages, account: account)
                if !newEvents.isEmpty {
                    await eventDelegate.didCapture(newEvents)
                }
                imported += newEvents.count

                if let maxUID = batch.max() {
                    env.saveLastImportedUID(account.email, maxUID)
                }

                importProgress = ImportProgress(
                    totalMessages:    sortedUIDs.count,
                    importedMessages: imported,
                    isComplete:       false,
                    currentBatch:     batchIndex + 1
                )

                log.info("Batch \(batchIndex + 1)/\(batches.count): imported \(newEvents.count) events")

            } catch IMAPError.authenticationFailed {
                // Auth error mid-import → attempt token refresh + reconnect.
                log.warning("Auth failure during batch \(batchIndex + 1) — refreshing token")
                do {
                    try await doConnect(account: account, allowTokenRefresh: true)
                    let messages = try await imapClient!.fetchMessages(uids: batch)
                    let newEvents = try await buildEvents(from: messages, account: account)
                    if !newEvents.isEmpty { await eventDelegate.didCapture(newEvents) }
                    imported += newEvents.count
                } catch {
                    log.error("Batch \(batchIndex + 1) failed after token refresh: \(error)")
                    // Skip this batch and continue.
                }

            } catch {
                // IMAP server error on one batch → log and continue.
                log.error("Batch \(batchIndex + 1) IMAP error (skipping): \(error.localizedDescription)")
            }

            if batchIndex < batches.count - 1 {
                try? await Task.sleep(nanoseconds: UInt64(env.batchDelay * 1_000_000_000))
            }

            // Abort if the task has been cancelled (e.g. disconnect()).
            if Task.isCancelled { break }
        }

        let isComplete = !Task.isCancelled
        importProgress = ImportProgress(
            totalMessages:    sortedUIDs.count,
            importedMessages: imported,
            isComplete:       isComplete,
            currentBatch:     batches.count
        )

        if isComplete {
            env.saveLastSyncDate(account.email, env.currentDate())
            log.info("Historical import complete — \(imported) events total")
        }

        return importProgress
    }

    /// Starts a background polling loop that fetches new emails every 5 minutes.
    ///
    /// Calling this again while a sync is already running is a no-op.
    public func startIncrementalSync() async {
        guard syncTask == nil || syncTask?.isCancelled == true else { return }
        guard let account = currentAccount else { return }

        syncTask = Task { [weak self] in
            await self?.syncLoop(account: account)
        }
        log.info("Incremental sync started (interval \(Int(self.env.syncInterval))s)")
    }

    /// Stops incremental sync and disconnects from the IMAP server.
    public func disconnect() async {
        syncTask?.cancel()
        syncTask = nil
        await imapClient?.logout()
        imapClient     = nil
        currentAccount = nil
        importProgress = .idle
        log.info("EmailCaptureService disconnected")
    }

    // MARK: - Private: connection

    private func doConnect(account: GmailAccount, allowTokenRefresh: Bool) async throws {
        let token: String
        do {
            token = try await env.getAccessToken(account)
        } catch {
            throw IMAPError.authenticationFailed("Token fetch failed: \(error.localizedDescription)")
        }

        let client = env.makeIMAPClient()
        try await client.connect(host: "imap.gmail.com", port: 993)

        do {
            try await client.authenticate(email: account.email, accessToken: token)
        } catch IMAPError.authenticationFailed where allowTokenRefresh {
            log.warning("Initial auth failed — forcing token refresh")
            let freshToken = try await env.forceRefreshToken(account)
            client.cancel()   // discard old connection
            let client2 = env.makeIMAPClient()
            try await client2.connect(host: "imap.gmail.com", port: 993)
            try await client2.authenticate(email: account.email, accessToken: freshToken)
            try await client2.selectMailbox("INBOX")
            imapClient = client2
            return
        }

        try await client.selectMailbox("INBOX")
        imapClient = client
    }

    // MARK: - Private: incremental sync loop

    private func syncLoop(account: GmailAccount) async {
        let backoffs: [TimeInterval] = [60, 120, 240, 480, 960, 1920, 3600]
        var backoffIdx = 0

        while !Task.isCancelled {
            // Wait for the sync interval before the first poll too.
            try? await Task.sleep(nanoseconds: UInt64(env.syncInterval * 1_000_000_000))
            guard !Task.isCancelled else { break }

            do {
                try await runIncrementalSync(account: account)
                backoffIdx = 0  // success → reset backoff
            } catch {
                let delay = backoffs[min(backoffIdx, backoffs.count - 1)]
                backoffIdx += 1
                log.error("Incremental sync error (retry in \(Int(delay))s): \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func runIncrementalSync(account: GmailAccount) async throws {
        guard let client = imapClient else {
            try await doConnect(account: account, allowTokenRefresh: true)
            return
        }

        let since: Date
        if let last = env.loadLastSyncDate(account.email) {
            since = last
        } else {
            since = env.currentDate().addingTimeInterval(-env.historyLookback)
        }

        let uids = try await client.searchUIDs(since: since)
        guard !uids.isEmpty else {
            env.saveLastSyncDate(account.email, env.currentDate())
            return
        }

        let messages = try await client.fetchMessages(uids: uids.sorted())
        let events   = try await buildEvents(from: messages, account: account)

        if !events.isEmpty {
            await eventDelegate.didCapture(events)
            log.info("Incremental sync: \(events.count) new event(s) for \(account.email, privacy: .private)")
        }

        env.saveLastSyncDate(account.email, env.currentDate())
    }

    // MARK: - Private: event construction

    private func buildEvents(
        from messages: [IMAPMessage],
        account: GmailAccount
    ) async throws -> [RawEvent] {
        var events: [RawEvent] = []
        for message in messages {
            // Deduplication: skip if already imported.
            if let mid = message.messageId, await env.isMessageImported(mid) {
                continue
            }

            let metadata = EmailCaptureMetadata.from(message)
            let eventDate = message.date ?? env.currentDate()
            let event = RawEvent(
                source:       .email,
                sourceApp:    "Gmail",
                startedAt:    eventDate,
                endedAt:      eventDate,
                metadataJSON: metadata.jsonString
            )
            events.append(event)
        }
        return events
    }
}

// MARK: - IMAPClientProtocol cancel helper

private extension IMAPClientProtocol {
    /// Disconnects without awaiting response (fire-and-forget helper used
    /// when we need to immediately discard a failed connection).
    func cancel() {
        Task { await self.logout() }
    }
}
