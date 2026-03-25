import Foundation
import SQLite3
import os.log

// MARK: - StorageActor

/// The single, authoritative owner of all Kerwan database I/O.
///
/// - All write operations are actor-isolated: only one write runs at a time.
/// - Read operations use a separate WAL-mode read connection protected by
///   `ReadConnectionBox` (NSLock), allowing reads to proceed without waiting
///   for in-flight writes at the SQLite WAL layer.
/// - Both connections are opened with PRAGMA journal_mode = WAL.
public actor StorageActor {

    // MARK: - State

    private let writeConn: SQLiteConnection
    private let reader: ReadConnectionBox
    private let dbPath: String
    private let log = Logger(subsystem: "com.kerwan.app", category: "StorageActor")

    // MARK: - Init

    /// Opens and configures the Kerwan database.
    /// - Parameter passphrase: AES-256 encryption key (managed by KeychainManager).
    /// - Parameter databaseURL: Override for the database file URL; defaults to
    ///   `~/Library/Application Support/Kerwan/kerwan.db`.
    public init(passphrase: String, databaseURL: URL? = nil) throws {
        let url: URL
        if let override = databaseURL {
            url = override
        } else {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = appSupport.appendingPathComponent("Kerwan", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent("kerwan.db")
        }

        dbPath = url.path
        log.info("Database path: \(url.path)")

        // --- Write connection ---
        let wConn = SQLiteConnection(path: dbPath)
        try wConn.open()
        try StorageActor.configure(wConn, passphrase: passphrase)
        writeConn = wConn

        // --- Read connection (WAL shared-cache reader) ---
        let rConn = SQLiteConnection(path: dbPath)
        try rConn.openReadOnly()
        try StorageActor.configureReadOnly(rConn, passphrase: passphrase)
        reader = ReadConnectionBox(conn: rConn)

        // --- Migrations ---
        let migrator = MigrationRunner(conn: writeConn)
        try migrator.runAll()

        log.info("StorageActor ready.")
    }

    // MARK: - Configuration helpers (static, called before actor is live)

    private static func configure(_ conn: SQLiteConnection, passphrase: String) throws {
        // SQLCipher key — no-op on stock sqlite3; active when linked against SQLCipher.
        try conn.execute("PRAGMA key = '\(passphrase)'")
        try conn.execute("PRAGMA cipher_page_size = 4096")
        try conn.execute("PRAGMA kdf_iter = 256000")
        // WAL mode for concurrent reads
        try conn.execute("PRAGMA journal_mode = WAL")
        try conn.execute("PRAGMA synchronous = NORMAL")
        try conn.execute("PRAGMA cache_size = -64000")   // 64 MB
        try conn.execute("PRAGMA mmap_size = 268435456") // 256 MB
        try conn.execute("PRAGMA foreign_keys = ON")
        try conn.execute("PRAGMA temp_store = MEMORY")
    }

    private static func configureReadOnly(_ conn: SQLiteConnection, passphrase: String) throws {
        // SQLCipher key — must be set before any other pragma.
        try conn.execute("PRAGMA key = '\(passphrase)'")
        try conn.execute("PRAGMA cipher_page_size = 4096")
        // query_only prevents accidental writes through this connection.
        // The connection itself is opened READWRITE (see openReadOnly()) because
        // WAL mode requires write access to the .db-shm coordination file.
        try conn.execute("PRAGMA query_only = ON")
        try conn.execute("PRAGMA cache_size = -32000")
    }

    // ====================================================================
    // MARK: - WRITE METHODS
    // ====================================================================

    // MARK: RawEvents

    /// Bulk-inserts raw capture events using a prepared statement.
    public func insertRawEvents(_ events: [RawEvent]) throws {
        guard !events.isEmpty else { return }
        let sql = """
            INSERT OR IGNORE INTO raw_events
                (id, session_id, timestamp, source, source_app,
                 window_title, url, duration, metadata, emails)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """
        try writeConn.transaction {
            let stmt = try writeConn.prepare(sql)
            defer { sqlite3_finalize(stmt) }
            for event in events {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                try writeConn.bind([
                    .text(event.id),
                    .from(event.sessionId),
                    .from(event.timestamp),
                    .text(event.source.rawValue),
                    .from(event.sourceApp),
                    .from(event.windowTitle),
                    .from(event.url),
                    .real(event.duration),
                    .from(event.metadata),
                    .from(event.emails),
                ], to: stmt)
                try writeConn.step(stmt)
            }
        }
    }

    // MARK: Interactions

    /// Inserts a new Interaction and links it to the given raw event IDs.
    /// Inserts a new Interaction and links it to the given raw event IDs.
    public func insertInteraction(_ interaction: Interaction, linkedEventIds: [String]) throws {
        try writeConn.transaction {
            let sql = """
                INSERT INTO interactions
                    (id, contact_id, client_id, project_id, type,
                     subject, body, summary, sentiment, started_at,
                     ended_at, source, metadata, direction)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """
            let stmt = try writeConn.prepare(sql)
            defer { sqlite3_finalize(stmt) }
            try writeConn.bind([
                .text(interaction.id),
                .from(interaction.contactId),
                .from(interaction.clientId),
                .from(interaction.projectId),
                .text(interaction.type.rawValue),
                .from(interaction.subject),
                .from(interaction.body),
                .from(interaction.summary),
                .text(interaction.sentiment.rawValue),
                .from(interaction.startedAt),
                .from(interaction.endedAt),
                .text(interaction.source),
                .from(interaction.metadata),
                .text(interaction.direction.rawValue),
            ], to: stmt)
            try writeConn.step(stmt)

            for eventId in linkedEventIds {
                try writeConn.execute("""
                    INSERT OR IGNORE INTO interaction_events(interaction_id, event_id)
                    VALUES('\(interaction.id)', '\(eventId)')
                    """)
            }
        }
    }

    // MARK: Promises

    /// Inserts a new promise (commitment extracted from an interaction).
    public func insertPromise(_ promise: Promise) throws {
        let sql = """
            INSERT INTO promises
                (id, contact_id, client_id, interaction_id, text,
                 due_date, status, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?)
            """
        let stmt = try writeConn.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try writeConn.bind([
            .text(promise.id),
            .from(promise.contactId),
            .from(promise.clientId),
            .from(promise.interactionId),
            .text(promise.text),
            .from(promise.dueDate),
            .text(promise.status.rawValue),
            .from(promise.createdAt),
            .from(promise.updatedAt),
        ], to: stmt)
        try writeConn.step(stmt)
    }

    // MARK: WorkSessions

    /// Inserts a proposed work session and links raw events to it.
    public func insertWorkSession(_ session: WorkSession, linkedEventIds: [String]) throws {
        try writeConn.transaction {
            let sql = """
                INSERT INTO work_sessions
                    (id, client_id, project_id, started_at, ended_at,
                     duration_seconds, auto_title, invoice_text, billable,
                     reviewed, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """
            let stmt = try writeConn.prepare(sql)
            defer { sqlite3_finalize(stmt) }
            try writeConn.bind([
                .text(session.id),
                .from(session.clientId),
                .from(session.projectId),
                .from(session.startedAt),
                .from(session.endedAt),
                .real(session.durationSeconds),
                .from(session.autoTitle),
                .from(session.invoiceText),
                .text(session.billable.rawValue),
                .from(session.reviewed),
                .from(session.createdAt),
            ], to: stmt)
            try writeConn.step(stmt)

            for eventId in linkedEventIds {
                try writeConn.execute("""
                    INSERT OR IGNORE INTO session_events(session_id, event_id)
                    VALUES('\(session.id)', '\(eventId)')
                    """)
                // Also stamp the raw_event with the session_id
                try writeConn.execute("""
                    UPDATE raw_events SET session_id = '\(session.id)'
                    WHERE id = '\(eventId)' AND session_id IS NULL
                    """)
            }
        }
    }

    // MARK: Contacts

    /// Inserts or updates a contact matched by email_primary.
    /// Inserts or updates a contact matched by email_primary.
    ///
    /// - `relationship_score` is intentionally excluded from the ON CONFLICT clause;
    ///   it is owned by `RelationshipScoreEngine` and must not be clobbered on a
    ///   routine contact upsert.
    /// - `last_seen_at` advances monotonically: `MAX(last_seen_at, excluded.last_seen_at)`
    ///   ensures we never roll back a contact's last-seen timestamp.
    public func upsertContact(_ contact: Contact) throws {
        let sql = """
            INSERT INTO contacts
                (id, display_name, email_primary, company, job_title,
                 notes, created_at, updated_at, last_seen_at)
            VALUES (?,?,?,?,?,?,?,?,?)
            ON CONFLICT(email_primary) DO UPDATE SET
                display_name = excluded.display_name,
                company      = excluded.company,
                job_title    = excluded.job_title,
                notes        = excluded.notes,
                updated_at   = excluded.updated_at,
                last_seen_at = MAX(last_seen_at, excluded.last_seen_at)
            """
        let stmt = try writeConn.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try writeConn.bind([
            .text(contact.id),
            .text(contact.displayName),
            .text(contact.emailPrimary),
            .from(contact.company),
            .from(contact.jobTitle),
            .from(contact.notes),
            .from(contact.createdAt),
            .from(contact.updatedAt),
            .from(contact.lastSeenAt),
        ], to: stmt)
        try writeConn.step(stmt)
    }

    /// Inserts or updates a contact identity (platform handle).
    public func upsertContactIdentity(_ identity: ContactIdentity) throws {
        let sql = """
            INSERT INTO contact_identities
                (id, contact_id, platform, platform_id, display_name)
            VALUES (?,?,?,?,?)
            ON CONFLICT(contact_id, platform, platform_id) DO UPDATE SET
                display_name = excluded.display_name
            """
        let stmt = try writeConn.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try writeConn.bind([
            .text(identity.id),
            .text(identity.contactId),
            .text(identity.platform.rawValue),
            .text(identity.platformId),
            .from(identity.displayName),
        ], to: stmt)
        try writeConn.step(stmt)
    }

    // MARK: Clients

    /// Inserts or updates a client by id.
    public func upsertClient(_ client: Client) throws {
        let sql = """
            INSERT INTO clients
                (id, name, domain, invoice_prefix, hourly_rate,
                 currency, notes, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                name           = excluded.name,
                domain         = excluded.domain,
                invoice_prefix = excluded.invoice_prefix,
                hourly_rate    = excluded.hourly_rate,
                currency       = excluded.currency,
                notes          = excluded.notes,
                updated_at     = excluded.updated_at
            """
        let stmt = try writeConn.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try writeConn.bind([
            .text(client.id),
            .text(client.name),
            .from(client.domain),
            .from(client.invoicePrefix),
            .from(client.hourlyRate),
            .text(client.currency),
            .from(client.notes),
            .from(client.createdAt),
            .from(client.updatedAt),
        ], to: stmt)
        try writeConn.step(stmt)
    }

    // MARK: Updates

    /// Updates a work session's billable status and optional invoice text.
    public func updateWorkSession(
        id: String,
        billable: WorkSession.BillableStatus,
        invoiceText: String?
    ) throws {
        let sql = """
            UPDATE work_sessions
            SET billable = ?, invoice_text = ?, reviewed = 1
            WHERE id = ?
            """
        let stmt = try writeConn.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try writeConn.bind([
            .text(billable.rawValue),
            .from(invoiceText),
            .text(id),
        ], to: stmt)
        try writeConn.step(stmt)
    }

    /// Updates the status of a promise.
    public func updatePromiseStatus(id: String, status: Promise.Status) throws {
        let now = Date().timeIntervalSince1970
        try writeConn.execute("""
            UPDATE promises
            SET status = '\(status.rawValue)', updated_at = \(now)
            WHERE id = '\(id)'
            """)
    }

    // MARK: Deletes

    /// Deletes a contact and all cascade-linked records.
    /// Also removes any vec_interactions rows for interactions linked to this contact.
    public func deleteContact(id: String) throws {
        try writeConn.transaction {
            // Collect interaction IDs linked to this contact before deletion
            var interactionIds: [String] = []
            try writeConn.query(
                "SELECT id FROM interactions WHERE contact_id = ?",
                bindings: [.text(id)]
            ) { stmt in
                if let iid = writeConn.columnText(stmt, at: 0) {
                    interactionIds.append(iid)
                }
            }
            // Delete from vec_interactions (table may not exist on stock SQLite without sqlite-vec)
            for iid in interactionIds {
                try? writeConn.execute(
                    "DELETE FROM vec_interactions WHERE interaction_id = '\(iid)'"
                )
            }
            // FK ON DELETE CASCADE handles contact_identities, client_contacts,
            // and sets NULL on interactions.contact_id / promises.contact_id.
            try writeConn.execute("DELETE FROM contacts WHERE id = '\(id)'")
        }
    }

    /// Deletes all raw_events, interactions, and work_sessions in the given range.
    public func deleteTimeRange(from: Date, to: Date) throws {
        let start = from.timeIntervalSince1970
        let end   = to.timeIntervalSince1970
        try writeConn.transaction {
            // Cascades via interaction_events → interaction delete
            try writeConn.execute("""
                DELETE FROM interactions
                WHERE started_at >= \(start) AND started_at <= \(end)
                """)
            try writeConn.execute("""
                DELETE FROM work_sessions
                WHERE started_at >= \(start) AND started_at <= \(end)
                """)
            // raw_events — session_events / interaction_events already cascaded
            try writeConn.execute("""
                DELETE FROM raw_events
                WHERE timestamp >= \(start) AND timestamp <= \(end)
                """)
        }
    }

    /// Drops and recreates all tables. Equivalent to a factory reset.
    public func deleteAllData() throws {
        try writeConn.transaction {
            let tables = [
                "fts_interactions", "vec_interactions", "vec_raw_events",
                "session_events", "interaction_events",
                "promises", "work_sessions", "interactions",
                "raw_events", "projects", "client_contacts",
                "contact_identities", "clients", "contacts",
                "exclusion_rules", "capture_pauses", "user_settings",
            ]
            for table in tables {
                try writeConn.execute("DROP TABLE IF EXISTS \(table)")
            }
        }
        // Re-run migration_001 to recreate everything cleanly
        try MigrationRunner(conn: writeConn).runAll()
    }

    // MARK: Vectors

    /// Inserts a 768-float embedding into vec_interactions for KNN search.
    /// Requires the sqlite-vec extension to be loaded. If the extension is absent
    /// (unit tests on stock SQLite), the write fails fast with a typed error.
    public func insertVectorEmbedding(interactionId: String, embedding: [Float]) throws {
        guard embedding.count == 768 else {
            throw StorageError.writeFailed(
                SQLiteError(code: -1, message: "Expected 768-dim embedding, got \(embedding.count)")
            )
        }
        let blob = embedding.withUnsafeBufferPointer { buf in
            Data(buffer: buf)
        }
        // Use execute to check for table existence first. If vec_interactions doesn't
        // exist (sqlite-vec not loaded), we get a clear error rather than a confusing one.
        let sql = """
            INSERT OR REPLACE INTO vec_interactions(interaction_id, embedding)
            VALUES (?, ?)
            """
        let stmt = try writeConn.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try writeConn.bind([.text(interactionId), .blob(blob)], to: stmt)
        try writeConn.step(stmt)
    }

    // MARK: ExclusionRules

    /// Inserts a new exclusion rule.
    public func insertExclusionRule(_ rule: ExclusionRule) throws {
        let sql = """
            INSERT OR IGNORE INTO exclusion_rules(id, type, value, created_at)
            VALUES (?,?,?,?)
            """
        let stmt = try writeConn.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try writeConn.bind([
            .text(rule.id),
            .text(rule.type.rawValue),
            .text(rule.value),
            .from(rule.createdAt),
        ], to: stmt)
        try writeConn.step(stmt)
    }

    /// Deletes an exclusion rule by id.
    public func deleteExclusionRule(id: String) throws {
        try writeConn.execute("DELETE FROM exclusion_rules WHERE id = '\(id)'")
    }

    // MARK: CapturePauses

    /// Inserts a new capture-pause record. `endedAt` is nil until the pause ends.
    public func insertCapturePause(_ pause: CapturePause) throws {
        let sql = """
            INSERT INTO capture_pauses(id, started_at, ended_at, reason)
            VALUES (?,?,?,?)
            """
        let stmt = try writeConn.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try writeConn.bind([
            .text(pause.id),
            .from(pause.startedAt),
            .from(pause.endedAt),
            .from(pause.reason),
        ], to: stmt)
        try writeConn.step(stmt)
    }

    /// Stamps the end time on an open pause. Safe to call even if the pause is
    /// already closed (UPDATE is a no-op when `ended_at` is already set via
    /// re-application; callers should only call this once).
    public func endCapturePause(id: String, endedAt: Date = .now) throws {
        let sql = "UPDATE capture_pauses SET ended_at = ? WHERE id = ?"
        let stmt = try writeConn.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try writeConn.bind([.from(endedAt), .text(id)], to: stmt)
        try writeConn.step(stmt)
    }

    // MARK: UserSettings

    /// Upserts a single key-value setting.
    public func updateUserSetting(key: String, value: String) throws {
        try writeConn.execute("""
            INSERT OR REPLACE INTO user_settings(key, value)
            VALUES('\(escapeSQL(key))', '\(escapeSQL(value))')
            """)
    }

    // ====================================================================
    // MARK: - READ METHODS  (use separate WAL read connection)
    // ====================================================================

    // MARK: Contacts

    /// Fetches a contact by primary key.
    public func fetchContact(id: String) -> Contact? {
        try? reader.withConnection { conn in
            var result: Contact?
            try conn.query(
                "SELECT * FROM contacts WHERE id = ? LIMIT 1",
                bindings: [.text(id)]
            ) { stmt in
                result = Self.contactFromRow(stmt, conn: conn)
            }
            return result
        }
    }

    /// Fetches the first contact matching email_primary (case-insensitive).
    public func fetchContactByEmail(_ email: String) -> Contact? {
        try? reader.withConnection { conn in
            var result: Contact?
            try conn.query(
                "SELECT * FROM contacts WHERE email_primary = ? COLLATE NOCASE LIMIT 1",
                bindings: [.text(email)]
            ) { stmt in
                result = Self.contactFromRow(stmt, conn: conn)
            }
            return result
        }
    }

    /// Fetches a paginated list of all contacts ordered by display_name.
    public func fetchAllContacts(limit: Int = 100, offset: Int = 0) -> [Contact] {
        (try? reader.withConnection { conn in
            var results: [Contact] = []
            try conn.query(
                "SELECT * FROM contacts ORDER BY display_name COLLATE NOCASE LIMIT ? OFFSET ?",
                bindings: [.integer(Int64(limit)), .integer(Int64(offset))]
            ) { stmt in
                results.append(Self.contactFromRow(stmt, conn: conn))
            }
            return results
        }) ?? []
    }

    /// Fetches all platform identities for a contact.
    public func fetchContactIdentities(contactId: String) -> [ContactIdentity] {
        (try? reader.withConnection { conn in
            var results: [ContactIdentity] = []
            try conn.query(
                "SELECT * FROM contact_identities WHERE contact_id = ?",
                bindings: [.text(contactId)]
            ) { stmt in
                results.append(Self.identityFromRow(stmt, conn: conn))
            }
            return results
        }) ?? []
    }

    // MARK: Clients

    public func fetchClient(id: String) -> Client? {
        try? reader.withConnection { conn in
            var result: Client?
            try conn.query("SELECT * FROM clients WHERE id = ? LIMIT 1",
                           bindings: [.text(id)]) { stmt in
                result = Self.clientFromRow(stmt, conn: conn)
            }
            return result
        }
    }

    public func fetchAllClients() -> [Client] {
        (try? reader.withConnection { conn in
            var results: [Client] = []
            try conn.query("SELECT * FROM clients ORDER BY name COLLATE NOCASE") { stmt in
                results.append(Self.clientFromRow(stmt, conn: conn))
            }
            return results
        }) ?? []
    }

    // MARK: Projects

    public func fetchProjects(clientId: String) -> [Project] {
        (try? reader.withConnection { conn in
            var results: [Project] = []
            try conn.query(
                "SELECT * FROM projects WHERE client_id = ? ORDER BY name",
                bindings: [.text(clientId)]
            ) { stmt in
                results.append(Self.projectFromRow(stmt, conn: conn))
            }
            return results
        }) ?? []
    }

    // MARK: Interactions

    /// Fetches interactions filtered by optional contact and/or client.
    public func fetchInteractions(
        contactId: String? = nil,
        clientId: String? = nil,
        limit: Int = 50,
        offset: Int = 0
    ) -> [Interaction] {
        (try? reader.withConnection { conn in
            var clauses: [String] = []
            var bindings: [SQLiteValue] = []
            if let cid = contactId {
                clauses.append("contact_id = ?")
                bindings.append(.text(cid))
            }
            if let kid = clientId {
                clauses.append("client_id = ?")
                bindings.append(.text(kid))
            }
            let where_ = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            bindings.append(.integer(Int64(limit)))
            bindings.append(.integer(Int64(offset)))
            var results: [Interaction] = []
            try conn.query(
                "SELECT * FROM interactions \(where_) ORDER BY started_at DESC LIMIT ? OFFSET ?",
                bindings: bindings
            ) { stmt in
                results.append(Self.interactionFromRow(stmt, conn: conn))
            }
            return results
        }) ?? []
    }

    // MARK: Promises

    public func fetchPromises(
        contactId: String? = nil,
        status: Promise.Status? = nil
    ) -> [Promise] {
        (try? reader.withConnection { conn in
            var clauses: [String] = []
            var bindings: [SQLiteValue] = []
            if let cid = contactId {
                clauses.append("contact_id = ?")
                bindings.append(.text(cid))
            }
            if let s = status {
                clauses.append("status = ?")
                bindings.append(.text(s.rawValue))
            }
            let where_ = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            var results: [Promise] = []
            try conn.query(
                "SELECT * FROM promises \(where_) ORDER BY due_date ASC, created_at DESC",
                bindings: bindings
            ) { stmt in
                results.append(Self.promiseFromRow(stmt, conn: conn))
            }
            return results
        }) ?? []
    }

    // MARK: WorkSessions

    public func fetchWorkSessions(
        clientId: String? = nil,
        billable: WorkSession.BillableStatus? = nil,
        from: Date? = nil,
        to: Date? = nil
    ) -> [WorkSession] {
        (try? reader.withConnection { conn in
            var clauses: [String] = []
            var bindings: [SQLiteValue] = []
            if let cid = clientId {
                clauses.append("client_id = ?")
                bindings.append(.text(cid))
            }
            if let b = billable {
                clauses.append("billable = ?")
                bindings.append(.text(b.rawValue))
            }
            if let f = from {
                clauses.append("started_at >= ?")
                bindings.append(.real(f.timeIntervalSince1970))
            }
            if let t = to {
                clauses.append("ended_at <= ?")
                bindings.append(.real(t.timeIntervalSince1970))
            }
            let where_ = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            var results: [WorkSession] = []
            try conn.query(
                "SELECT * FROM work_sessions \(where_) ORDER BY started_at DESC",
                bindings: bindings
            ) { stmt in
                results.append(Self.sessionFromRow(stmt, conn: conn))
            }
            return results
        }) ?? []
    }

    public func fetchUnreviewedSessions(since: Date) -> [WorkSession] {
        (try? reader.withConnection { conn in
            var results: [WorkSession] = []
            try conn.query(
                "SELECT * FROM work_sessions WHERE reviewed = 0 AND started_at >= ? ORDER BY started_at DESC",
                bindings: [.real(since.timeIntervalSince1970)]
            ) { stmt in
                results.append(Self.sessionFromRow(stmt, conn: conn))
            }
            return results
        }) ?? []
    }

    // MARK: RawEvents

    public func fetchRawEvents(sessionId: String) -> [RawEvent] {
        (try? reader.withConnection { conn in
            var results: [RawEvent] = []
            try conn.query(
                """
                SELECT re.* FROM raw_events re
                JOIN session_events se ON se.event_id = re.id
                WHERE se.session_id = ?
                ORDER BY re.timestamp ASC
                """,
                bindings: [.text(sessionId)]
            ) { stmt in
                results.append(Self.rawEventFromRow(stmt, conn: conn))
            }
            return results
        }) ?? []
    }

    // MARK: ExclusionRules

    public func fetchExclusionRules() -> [ExclusionRule] {
        (try? reader.withConnection { conn in
            var results: [ExclusionRule] = []
            try conn.query("SELECT * FROM exclusion_rules ORDER BY created_at") { stmt in
                results.append(Self.exclusionRuleFromRow(stmt, conn: conn))
            }
            return results
        }) ?? []
    }

    // MARK: CapturePauses

    /// Fetches capture pauses, optionally filtered to those that started within
    /// the given half-open interval `[from, to)`. Returns all pauses when both
    /// bounds are `nil`, ordered most-recent first.
    public func fetchCapturePauses(from: Date? = nil, to: Date? = nil) -> [CapturePause] {
        (try? reader.withConnection { conn in
            var clauses: [String] = []
            var bindings: [SQLiteValue] = []
            if let f = from {
                clauses.append("started_at >= ?")
                bindings.append(.real(f.timeIntervalSince1970))
            }
            if let t = to {
                clauses.append("started_at < ?")
                bindings.append(.real(t.timeIntervalSince1970))
            }
            let where_ = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            var results: [CapturePause] = []
            try conn.query(
                "SELECT * FROM capture_pauses \(where_) ORDER BY started_at DESC",
                bindings: bindings
            ) { stmt in
                results.append(Self.capturePauseFromRow(stmt, conn: conn))
            }
            return results
        }) ?? []
    }

    // MARK: UserSettings

    public func fetchUserSettings() -> UserSettings {
        let raw: [String: String] = (try? reader.withConnection { conn in
            var map: [String: String] = [:]
            try conn.query("SELECT key, value FROM user_settings") { stmt in
                if let k = conn.columnText(stmt, at: 0),
                   let v = conn.columnText(stmt, at: 1) {
                    map[k] = v
                }
            }
            return map
        }) ?? [:]

        return UserSettings(
            schemaVersion:       Int(raw["schema_version"] ?? "1") ?? 1,
            captureEnabled:      (raw["capture_enabled"] ?? "true") == "true",
            audioEnabled:        (raw["audio_enabled"] ?? "false") == "true",
            whisperModel:        raw["whisper_model"] ?? "base",
            ollamaModel:         raw["ollama_model"] ?? "llama3:8b",
            embedModel:          raw["embed_model"] ?? "nomic-embed-text",
            reviewReminderDays:  Int(raw["review_reminder_days"] ?? "7") ?? 7,
            defaultCurrency:     raw["default_currency"] ?? "USD",
            onboardingCompleted: (raw["onboarding_completed"] ?? "false") == "true"
        )
    }

    // MARK: Search

    /// Full-text search over interactions using FTS5.
    public func searchKeyword(query: String, limit: Int = 20) -> [SearchResult] {
        (try? reader.withConnection { conn in
            let escaped = query.replacingOccurrences(of: "\"", with: "\"\"")
            var results: [SearchResult] = []
            // Standalone FTS5: join back to interactions via interaction_id for
            // the timestamp and bm25 rank. bm25() is referenced by the FTS table name.
            try conn.query(
                """
                SELECT f.interaction_id, f.subject, f.summary, i.started_at,
                       bm25(fts_interactions) AS rank
                FROM fts_interactions f
                JOIN interactions i ON i.id = f.interaction_id
                WHERE fts_interactions MATCH ?
                ORDER BY rank
                LIMIT ?
                """,
                bindings: [.text(escaped), .integer(Int64(limit))]
            ) { stmt in
                let id        = conn.columnText(stmt, at: 0) ?? ""
                let subject   = conn.columnText(stmt, at: 1) ?? "(no subject)"
                let summary   = conn.columnText(stmt, at: 2) ?? ""
                let timestamp = conn.columnDate(stmt, at: 3)
                let rank      = conn.columnDouble(stmt, at: 4)
                results.append(SearchResult(
                    id: id, type: .interaction,
                    title: subject, snippet: String(summary.prefix(200)),
                    score: abs(rank), timestamp: timestamp
                ))
            }
            return results
        }) ?? []
    }

    /// KNN vector similarity search over vec_interactions.
    public func searchVector(
        embedding: [Float],
        limit: Int = 10
    ) -> [(interactionId: String, distance: Float)] {
        guard embedding.count == 768 else { return [] }
        let blob = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
        return (try? reader.withConnection { conn in
            var results: [(String, Float)] = []
            try conn.query(
                """
                SELECT interaction_id, distance
                FROM vec_interactions
                WHERE embedding MATCH ?
                ORDER BY distance
                LIMIT ?
                """,
                bindings: [.blob(blob), .integer(Int64(limit))]
            ) { stmt in
                let iid  = conn.columnText(stmt, at: 0) ?? ""
                let dist = Float(conn.columnDouble(stmt, at: 1))
                results.append((iid, dist))
            }
            return results
        }) ?? []
    }

    // MARK: Counts

    public func countUnreviewedSessions() -> Int {
        let v: Int64? = try? reader.withConnection { conn in
            try conn.scalar("SELECT count(*) FROM work_sessions WHERE reviewed = 0")
        }
        return Int(v ?? 0)
    }

    public func countOpenPromises() -> Int {
        let v: Int64? = try? reader.withConnection { conn in
            try conn.scalar("SELECT count(*) FROM promises WHERE status = 'open'")
        }
        return Int(v ?? 0)
    }

    // ====================================================================
    // MARK: - MAINTENANCE
    // ====================================================================

    /// Runs VACUUM to reclaim space. Should only be called during app idle.
    public func vacuum() async {
        do {
            try writeConn.execute("VACUUM")
            log.info("VACUUM completed.")
        } catch {
            log.error("VACUUM failed: \(error)")
        }
    }

    /// Forces a WAL checkpoint to flush the WAL file back to the main database.
    public func checkpoint() async {
        do {
            try writeConn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            log.info("WAL checkpoint completed.")
        } catch {
            log.error("WAL checkpoint failed: \(error)")
        }
    }

    /// Copies the live database to `url`. If `encrypt` is true, the copy retains
    /// the SQLCipher key; otherwise it exports a plain sqlite3 file via ATTACH.
    public func exportDatabase(to url: URL, encrypt: Bool) throws {
        do {
            if encrypt {
                try FileManager.default.copyItem(
                    atPath: dbPath,
                    toPath: url.path
                )
            } else {
                // Plain-text export via sqlite3_backup_init
                let destConn = SQLiteConnection(path: url.path)
                try destConn.open()
                defer { destConn.close() }

                guard let destDB = destConn.db, let srcDB = writeConn.db else {
                    throw StorageError.exportFailed(
                        SQLiteError(code: -1, message: "connection not open")
                    )
                }
                guard let backup = sqlite3_backup_init(destDB, "main", srcDB, "main") else {
                    throw StorageError.exportFailed(
                        SQLiteError(code: Int32(sqlite3_errcode(destDB)),
                                    message: String(cString: sqlite3_errmsg(destDB)))
                    )
                }
                var rc: Int32
                repeat {
                    rc = sqlite3_backup_step(backup, 100)
                } while rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED
                sqlite3_backup_finish(backup)
                guard rc == SQLITE_DONE else {
                    throw StorageError.exportFailed(
                        SQLiteError(code: rc, message: "backup step failed")
                    )
                }
            }
            log.info("Database exported to \(url.path, privacy: .private)")
        } catch let e as StorageError {
            throw e
        } catch {
            throw StorageError.exportFailed(error)
        }
    }

    // ====================================================================
    // MARK: - Row-to-model converters (static, no actor isolation needed)
    // ====================================================================

    private static func contactFromRow(_ stmt: OpaquePointer, conn: SQLiteConnection) -> Contact {
        // Columns 8 and 9 were added in migration_002; columnDouble/columnDate return 0
        // for NULL (pre-migration rows are given DEFAULT 0), which maps to distantPast.
        let rawLastSeen = conn.columnDouble(stmt, at: 9)
        let lastSeenAt: Date = rawLastSeen > 0
            ? Date(timeIntervalSince1970: rawLastSeen)
            : .distantPast
        return Contact(
            id:                conn.columnText(stmt, at: 0) ?? "",
            displayName:       conn.columnText(stmt, at: 1) ?? "",
            emailPrimary:      conn.columnText(stmt, at: 2) ?? "",
            company:           conn.columnText(stmt, at: 3),
            jobTitle:          conn.columnText(stmt, at: 4),
            notes:             conn.columnText(stmt, at: 5),
            createdAt:         conn.columnDate(stmt, at: 6),
            updatedAt:         conn.columnDate(stmt, at: 7),
            relationshipScore: conn.columnDouble(stmt, at: 8),
            lastSeenAt:        lastSeenAt
        )
    }

    private static func identityFromRow(_ stmt: OpaquePointer, conn: SQLiteConnection) -> ContactIdentity {
        ContactIdentity(
            id:          conn.columnText(stmt, at: 0) ?? "",
            contactId:   conn.columnText(stmt, at: 1) ?? "",
            platform:    ContactIdentity.Platform(rawValue: conn.columnText(stmt, at: 2) ?? "") ?? .other,
            platformId:  conn.columnText(stmt, at: 3) ?? "",
            displayName: conn.columnText(stmt, at: 4)
        )
    }

    private static func clientFromRow(_ stmt: OpaquePointer, conn: SQLiteConnection) -> Client {
        Client(
            id:            conn.columnText(stmt, at: 0) ?? "",
            name:          conn.columnText(stmt, at: 1) ?? "",
            domain:        conn.columnText(stmt, at: 2),
            invoicePrefix: conn.columnText(stmt, at: 3),
            hourlyRate:    sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : conn.columnDouble(stmt, at: 4),
            currency:      conn.columnText(stmt, at: 5) ?? "USD",
            notes:         conn.columnText(stmt, at: 6),
            createdAt:     conn.columnDate(stmt, at: 7),
            updatedAt:     conn.columnDate(stmt, at: 8)
        )
    }

    private static func projectFromRow(_ stmt: OpaquePointer, conn: SQLiteConnection) -> Project {
        Project(
            id:        conn.columnText(stmt, at: 0) ?? "",
            clientId:  conn.columnText(stmt, at: 1) ?? "",
            name:      conn.columnText(stmt, at: 2) ?? "",
            code:      conn.columnText(stmt, at: 3),
            status:    Project.Status(rawValue: conn.columnText(stmt, at: 4) ?? "") ?? .active,
            budget:    sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : conn.columnDouble(stmt, at: 5),
            notes:     conn.columnText(stmt, at: 6),
            createdAt: conn.columnDate(stmt, at: 7),
            updatedAt: conn.columnDate(stmt, at: 8)
        )
    }

    private static func rawEventFromRow(_ stmt: OpaquePointer, conn: SQLiteConnection) -> RawEvent {
        RawEvent(
            id:          conn.columnText(stmt, at: 0) ?? "",
            sessionId:   conn.columnText(stmt, at: 1),
            timestamp:   conn.columnDate(stmt, at: 2),
            source:      RawEvent.Source(rawValue: conn.columnText(stmt, at: 3) ?? "") ?? .windowFocus,
            sourceApp:   conn.columnText(stmt, at: 4),
            windowTitle: conn.columnText(stmt, at: 5),
            url:         conn.columnText(stmt, at: 6),
            duration:    conn.columnDouble(stmt, at: 7),
            metadata:    conn.columnText(stmt, at: 8),
            emails:      conn.columnText(stmt, at: 9)
        )
    }

    private static func interactionFromRow(_ stmt: OpaquePointer, conn: SQLiteConnection) -> Interaction {
        // Column 13 (direction) was added in migration_002; rows without it default to 'mutual'.
        Interaction(
            id:        conn.columnText(stmt, at: 0) ?? "",
            contactId: conn.columnText(stmt, at: 1),
            clientId:  conn.columnText(stmt, at: 2),
            projectId: conn.columnText(stmt, at: 3),
            type:      Interaction.InteractionType(rawValue: conn.columnText(stmt, at: 4) ?? "") ?? .other,
            subject:   conn.columnText(stmt, at: 5),
            body:      conn.columnText(stmt, at: 6),
            summary:   conn.columnText(stmt, at: 7),
            sentiment: Interaction.Sentiment(rawValue: conn.columnText(stmt, at: 8) ?? "") ?? .unknown,
            startedAt: conn.columnDate(stmt, at: 9),
            endedAt:   conn.columnDateOptional(stmt, at: 10),
            source:    conn.columnText(stmt, at: 11) ?? "",
            metadata:  conn.columnText(stmt, at: 12),
            direction: Interaction.Direction(rawValue: conn.columnText(stmt, at: 13) ?? "") ?? .mutual
        )
    }

    private static func promiseFromRow(_ stmt: OpaquePointer, conn: SQLiteConnection) -> Promise {
        Promise(
            id:            conn.columnText(stmt, at: 0) ?? "",
            contactId:     conn.columnText(stmt, at: 1),
            clientId:      conn.columnText(stmt, at: 2),
            interactionId: conn.columnText(stmt, at: 3),
            text:          conn.columnText(stmt, at: 4) ?? "",
            dueDate:       conn.columnDateOptional(stmt, at: 5),
            status:        Promise.Status(rawValue: conn.columnText(stmt, at: 6) ?? "") ?? .open,
            createdAt:     conn.columnDate(stmt, at: 7),
            updatedAt:     conn.columnDate(stmt, at: 8)
        )
    }

    private static func sessionFromRow(_ stmt: OpaquePointer, conn: SQLiteConnection) -> WorkSession {
        WorkSession(
            id:              conn.columnText(stmt, at: 0) ?? "",
            clientId:        conn.columnText(stmt, at: 1),
            projectId:       conn.columnText(stmt, at: 2),
            startedAt:       conn.columnDate(stmt, at: 3),
            endedAt:         conn.columnDate(stmt, at: 4),
            durationSeconds: conn.columnDouble(stmt, at: 5),
            autoTitle:       conn.columnText(stmt, at: 6),
            invoiceText:     conn.columnText(stmt, at: 7),
            billable:        WorkSession.BillableStatus(rawValue: conn.columnText(stmt, at: 8) ?? "") ?? .undecided,
            reviewed:        conn.columnBool(stmt, at: 9),
            createdAt:       conn.columnDate(stmt, at: 10)
        )
    }

    private static func exclusionRuleFromRow(_ stmt: OpaquePointer, conn: SQLiteConnection) -> ExclusionRule {
        ExclusionRule(
            id:        conn.columnText(stmt, at: 0) ?? "",
            type:      ExclusionRule.RuleType(rawValue: conn.columnText(stmt, at: 1) ?? "") ?? .app,
            value:     conn.columnText(stmt, at: 2) ?? "",
            createdAt: conn.columnDate(stmt, at: 3)
        )
    }

    private static func capturePauseFromRow(_ stmt: OpaquePointer, conn: SQLiteConnection) -> CapturePause {
        CapturePause(
            id:        conn.columnText(stmt, at: 0) ?? "",
            startedAt: conn.columnDate(stmt, at: 1),
            endedAt:   conn.columnDateOptional(stmt, at: 2),
            reason:    conn.columnText(stmt, at: 3)
        )
    }

    // ====================================================================
    // MARK: - Internal connection accessors for module-internal extensions
    // ====================================================================

    /// Executes `block` with the actor-isolated write connection.
    ///
    /// Used by `StorageActor+Scoring.swift` and other module-internal extensions that
    /// need direct SQL access without coupling to the private `writeConn` property.
    func withWriteConnection<T: Sendable>(
        _ block: @Sendable (SQLiteConnection) throws -> T
    ) throws -> T {
        try block(writeConn)
    }

    /// Executes `block` on the thread-safe read connection box.
    ///
    /// Used by `StorageActor+Scoring.swift` and other module-internal extensions.
    func withReadConnection<T: Sendable>(
        _ block: @Sendable (SQLiteConnection) throws -> T
    ) throws -> T {
        try reader.withConnection(block)
    }

    // ====================================================================
    // MARK: - SQL helpers
    // ====================================================================

    private func sqlText(_ s: String?) -> String {
        guard let s else { return "NULL" }
        return "'\(escapeSQL(s))'"
    }

    private func sqlReal(_ d: Date?) -> String {
        guard let d else { return "NULL" }
        return "\(d.timeIntervalSince1970)"
    }

    private func escapeSQL(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }
}
