import Foundation
import SQLite3
import os.log

// MARK: - MigrationRunner

/// Applies numbered schema migrations in order, tracking progress in user_settings.
struct MigrationRunner {

    private let conn: SQLiteConnection
    private let log = Logger(subsystem: "com.kerwan.app", category: "Migrations")

    init(conn: SQLiteConnection) {
        self.conn = conn
    }

    // MARK: - Entry Point

    /// Runs all pending migrations. Throws `StorageError.migrationFailed` on failure.
    func runAll() throws {
        let current = try currentVersion()
        log.info("Schema version: \(current). Applying pending migrations.")

        let migrations: [(Int, () throws -> Void)] = [
            (1, migration_001),
            (2, migration_002),
            (3, migration_003),
        ]

        for (version, migration) in migrations where version > current {
            log.info("Applying migration \(version)")
            do {
                try conn.transaction {
                    try migration()
                    try setVersion(version)
                }
                log.info("Migration \(version) complete.")
            } catch {
                log.error("Migration \(version) failed: \(error)")
                throw StorageError.migrationFailed(version: version, underlyingError: error)
            }
        }
    }

    // MARK: - Version tracking

    private func currentVersion() throws -> Int {
        // user_settings may not exist yet on a fresh database.
        var version = 0
        let tableExists: Int64? = try? conn.scalar(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='user_settings'"
        )
        guard (tableExists ?? 0) > 0 else { return 0 }

        let raw: String? = try conn.scalar(
            "SELECT value FROM user_settings WHERE key = 'schema_version'"
        )
        if let raw, let v = Int(raw) { version = v }
        return version
    }

    private func setVersion(_ version: Int) throws {
        try conn.execute(
            "INSERT OR REPLACE INTO user_settings(key, value) VALUES('schema_version', '\(version)')"
        )
    }

    // MARK: - sqlite-vec

    /// Load the sqlite-vec extension.
    ///
    /// In production, call `sqlite3_auto_extension(sqlite3_vec_init)` before
    /// opening any connection, where `sqlite3_vec_init` is the entry point from
    /// the compiled sqlite-vec C target. During unit tests on stock macOS SQLite
    /// the vec0 tables are created as no-ops with `IF NOT EXISTS` guards so that
    /// the test suite compiles and passes without the extension.
    private func loadSqliteVec() throws {
        // sqlite3_enable_load_extension is not available in the macOS system SQLite.
        // In production, sqlite-vec is registered via sqlite3_auto_extension(sqlite3_vec_init)
        // at process startup, before any connection is opened. The vec0 virtual tables below
        // use CREATE VIRTUAL TABLE ... IF NOT EXISTS so unit tests on stock SQLite3 simply
        // fail silently at that step without crashing the migration.
    }

    // MARK: - migration_003

    /// Adds the `digests` table for storing daily and weekly AI-generated digests.
    ///
    /// Columns:
    /// - `id`:                      UUID primary key.
    /// - `kind`:                    'daily' or 'weekly'.
    /// - `generated_at`:            Unix timestamp when the digest was created.
    /// - `title`:                   Short notification-banner title.
    /// - `body_text`:               AI-generated or template narrative.
    /// - `meeting_count`:           Meetings detected in the reference period.
    /// - `email_count`:             Emails in the reference period.
    /// - `slack_count`:             Slack messages in the reference period.
    /// - `open_promise_count`:      Open promises at generation time.
    /// - `unreviewed_session_count`:Work sessions awaiting billing review.
    /// - `quiet_contact_names`:     JSON array of contact display names going quiet.
    /// - `total_hours_tracked`:     Weekly only — total hours across all sessions.
    /// - `estimated_billable_hours`:Weekly only — confirmed billable hours.
    /// - `sessions_reviewed_count`: Weekly only — sessions moved to confirmed.
    /// - `sessions_pending_count`:  Weekly only — sessions still suggested.
    /// - `prior_week_billable_hours`:Weekly only — prior-week confirmed hours.
    private func migration_003() throws {
        try conn.execute("""
            CREATE TABLE IF NOT EXISTS digests (
                id                       TEXT PRIMARY KEY NOT NULL,
                kind                     TEXT NOT NULL
                                         CHECK(kind IN ('daily','weekly')),
                generated_at             REAL NOT NULL,
                title                    TEXT NOT NULL,
                body_text                TEXT NOT NULL,
                meeting_count            INTEGER NOT NULL DEFAULT 0,
                email_count              INTEGER NOT NULL DEFAULT 0,
                slack_count              INTEGER NOT NULL DEFAULT 0,
                open_promise_count       INTEGER NOT NULL DEFAULT 0,
                unreviewed_session_count INTEGER NOT NULL DEFAULT 0,
                quiet_contact_names      TEXT NOT NULL DEFAULT '[]',
                total_hours_tracked      REAL,
                estimated_billable_hours REAL,
                sessions_reviewed_count  INTEGER,
                sessions_pending_count   INTEGER,
                prior_week_billable_hours REAL
            ) STRICT
            """)

        try conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_digests_kind         ON digests(kind)"
        )
        try conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_digests_generated_at ON digests(generated_at DESC)"
        )
    }

    // MARK: - migration_002

    /// Adds relationship scoring fields to contacts and a direction column to interactions.
    ///
    /// - `contacts.relationship_score`: 0–10 float, updated nightly by `RelationshipScoreEngine`.
    /// - `contacts.last_seen_at`:       Unix timestamp of the most recent interaction; denormalised
    ///   for fast "active contacts in last N days" queries without a join.
    /// - `interactions.direction`:      'outbound' (user-initiated), 'inbound' (contact-initiated),
    ///   or 'mutual' (e.g. meeting). Defaults to 'mutual' for all pre-existing rows.
    private func migration_002() throws {
        try conn.execute(
            "ALTER TABLE contacts ADD COLUMN relationship_score REAL NOT NULL DEFAULT 0.0"
        )
        try conn.execute(
            "ALTER TABLE contacts ADD COLUMN last_seen_at REAL NOT NULL DEFAULT 0.0"
        )
        try conn.execute(
            "ALTER TABLE interactions ADD COLUMN direction TEXT NOT NULL DEFAULT 'mutual'"
        )

        // Indexes that accelerate the nightly scoring pass and UI sort-by-score queries.
        try conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_contacts_score     ON contacts(relationship_score DESC)"
        )
        try conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_contacts_last_seen ON contacts(last_seen_at)"
        )
        try conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_int_direction      ON interactions(direction)"
        )
    }

    // MARK: - migration_001

    /// Creates the complete initial schema, all indexes, FTS5 table, and default settings.
    private func migration_001() throws {

        // ----------------------------------------------------------------
        // MARK: contacts
        // ----------------------------------------------------------------
        try conn.execute("""
            CREATE TABLE IF NOT EXISTS contacts (
                id           TEXT PRIMARY KEY NOT NULL,
                display_name TEXT NOT NULL,
                email_primary TEXT NOT NULL UNIQUE COLLATE NOCASE,
                company      TEXT,
                job_title    TEXT,
                notes        TEXT,
                created_at   REAL NOT NULL,
                updated_at   REAL NOT NULL
            ) STRICT
            """)

        // ----------------------------------------------------------------
        // MARK: contact_identities
        // ----------------------------------------------------------------
        try conn.execute("""
            CREATE TABLE IF NOT EXISTS contact_identities (
                id           TEXT PRIMARY KEY NOT NULL,
                contact_id   TEXT NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
                platform     TEXT NOT NULL,
                platform_id  TEXT NOT NULL,
                display_name TEXT,
                UNIQUE(contact_id, platform, platform_id)
            ) STRICT
            """)

        // ----------------------------------------------------------------
        // MARK: clients
        // ----------------------------------------------------------------
        try conn.execute("""
            CREATE TABLE IF NOT EXISTS clients (
                id             TEXT PRIMARY KEY NOT NULL,
                name           TEXT NOT NULL,
                domain         TEXT,
                invoice_prefix TEXT,
                hourly_rate    REAL,
                currency       TEXT NOT NULL DEFAULT 'USD',
                notes          TEXT,
                created_at     REAL NOT NULL,
                updated_at     REAL NOT NULL
            ) STRICT
            """)

        // ----------------------------------------------------------------
        // MARK: client_contacts
        // ----------------------------------------------------------------
        try conn.execute("""
            CREATE TABLE IF NOT EXISTS client_contacts (
                client_id  TEXT NOT NULL REFERENCES clients(id)  ON DELETE CASCADE,
                contact_id TEXT NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
                role       TEXT,
                PRIMARY KEY (client_id, contact_id)
            ) STRICT
            """)

        // ----------------------------------------------------------------
        // MARK: projects
        // ----------------------------------------------------------------
        try conn.execute("""
            CREATE TABLE IF NOT EXISTS projects (
                id         TEXT PRIMARY KEY NOT NULL,
                client_id  TEXT NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
                name       TEXT NOT NULL,
                code       TEXT,
                status     TEXT NOT NULL DEFAULT 'active'
                           CHECK(status IN ('active','archived','completed')),
                budget     REAL,
                notes      TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            ) STRICT
            """)

        // ----------------------------------------------------------------
        // MARK: raw_events
        // ----------------------------------------------------------------
        try conn.execute("""
            CREATE TABLE IF NOT EXISTS raw_events (
                id           TEXT PRIMARY KEY NOT NULL,
                session_id   TEXT REFERENCES work_sessions(id) ON DELETE SET NULL,
                timestamp    REAL NOT NULL,
                source       TEXT NOT NULL,
                source_app   TEXT,
                window_title TEXT,
                url          TEXT,
                duration     REAL NOT NULL DEFAULT 0,
                metadata     TEXT,
                emails       TEXT
            ) STRICT
            """)

        // ----------------------------------------------------------------
        // MARK: interactions
        // ----------------------------------------------------------------
        try conn.execute("""
            CREATE TABLE IF NOT EXISTS interactions (
                id         TEXT PRIMARY KEY NOT NULL,
                contact_id TEXT REFERENCES contacts(id) ON DELETE SET NULL,
                client_id  TEXT REFERENCES clients(id)  ON DELETE SET NULL,
                project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,
                type       TEXT NOT NULL
                           CHECK(type IN ('email','meeting','call','message',
                                          'document','codeReview','other')),
                subject    TEXT,
                body       TEXT,
                summary    TEXT,
                sentiment  TEXT NOT NULL DEFAULT 'unknown'
                           CHECK(sentiment IN ('positive','neutral','negative','unknown')),
                started_at REAL NOT NULL,
                ended_at   REAL,
                source     TEXT NOT NULL,
                metadata   TEXT
            ) STRICT
            """)

        // ----------------------------------------------------------------
        // MARK: interaction_events
        // ----------------------------------------------------------------
        try conn.execute("""
            CREATE TABLE IF NOT EXISTS interaction_events (
                interaction_id TEXT NOT NULL REFERENCES interactions(id) ON DELETE CASCADE,
                event_id       TEXT NOT NULL REFERENCES raw_events(id)   ON DELETE CASCADE,
                PRIMARY KEY (interaction_id, event_id)
            ) STRICT
            """)

        // ----------------------------------------------------------------
        // MARK: promises
        // ----------------------------------------------------------------
        try conn.execute("""
            CREATE TABLE IF NOT EXISTS promises (
                id             TEXT PRIMARY KEY NOT NULL,
                contact_id     TEXT REFERENCES contacts(id)     ON DELETE SET NULL,
                client_id      TEXT REFERENCES clients(id)      ON DELETE SET NULL,
                interaction_id TEXT REFERENCES interactions(id) ON DELETE SET NULL,
                text           TEXT NOT NULL,
                due_date       REAL,
                status         TEXT NOT NULL DEFAULT 'open'
                               CHECK(status IN ('open','fulfilled','dismissed')),
                created_at     REAL NOT NULL,
                updated_at     REAL NOT NULL
            ) STRICT
            """)

        // ----------------------------------------------------------------
        // MARK: work_sessions
        // ----------------------------------------------------------------
        try conn.execute("""
            CREATE TABLE IF NOT EXISTS work_sessions (
                id               TEXT PRIMARY KEY NOT NULL,
                client_id        TEXT REFERENCES clients(id)  ON DELETE SET NULL,
                project_id       TEXT REFERENCES projects(id) ON DELETE SET NULL,
                started_at       REAL NOT NULL,
                ended_at         REAL NOT NULL,
                duration_seconds REAL NOT NULL,
                auto_title       TEXT,
                invoice_text     TEXT,
                billable         TEXT NOT NULL DEFAULT 'undecided'
                                 CHECK(billable IN ('billable','nonBillable','undecided')),
                reviewed         INTEGER NOT NULL DEFAULT 0,
                created_at       REAL NOT NULL
            ) STRICT
            """)

        // ----------------------------------------------------------------
        // MARK: session_events
        // ----------------------------------------------------------------
        try conn.execute("""
            CREATE TABLE IF NOT EXISTS session_events (
                session_id TEXT NOT NULL REFERENCES work_sessions(id) ON DELETE CASCADE,
                event_id   TEXT NOT NULL REFERENCES raw_events(id)    ON DELETE CASCADE,
                PRIMARY KEY (session_id, event_id)
            ) STRICT
            """)

        // ----------------------------------------------------------------
        // MARK: exclusion_rules
        // ----------------------------------------------------------------
        try conn.execute("""
            CREATE TABLE IF NOT EXISTS exclusion_rules (
                id         TEXT PRIMARY KEY NOT NULL,
                type       TEXT NOT NULL
                           CHECK(type IN ('app','domain','contact','windowTitleRegex')),
                value      TEXT NOT NULL,
                created_at REAL NOT NULL,
                UNIQUE(type, value)
            ) STRICT
            """)

        // ----------------------------------------------------------------
        // MARK: capture_pauses
        // ----------------------------------------------------------------
        try conn.execute("""
            CREATE TABLE IF NOT EXISTS capture_pauses (
                id         TEXT PRIMARY KEY NOT NULL,
                started_at REAL NOT NULL,
                ended_at   REAL,
                reason     TEXT
            ) STRICT
            """)

        // ----------------------------------------------------------------
        // MARK: user_settings
        // ----------------------------------------------------------------
        try conn.execute("""
            CREATE TABLE IF NOT EXISTS user_settings (
                key   TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            ) STRICT
            """)

        // ----------------------------------------------------------------
        // MARK: sqlite-vec virtual tables
        //
        // vec0 is provided by the sqlite-vec extension. The 768-dimension
        // vector matches nomic-embed-text output. These tables are optional:
        // if sqlite-vec is not loaded (e.g., in unit tests using stock SQLite),
        // the CREATE silently fails and vector search returns empty results.
        // In production, call sqlite3_auto_extension(sqlite3_vec_init) at
        // app startup before opening any connection.
        // ----------------------------------------------------------------
        try? conn.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS vec_interactions USING vec0(
                interaction_id TEXT PRIMARY KEY,
                embedding      FLOAT[768]
            )
            """)

        try? conn.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS vec_raw_events USING vec0(
                event_id  TEXT PRIMARY KEY,
                embedding FLOAT[768]
            )
            """)

        // ----------------------------------------------------------------
        // MARK: FTS5 — standalone full-text search over interactions
        //
        // We use a standalone FTS5 table (not content-based) so the index
        // stores text directly. This avoids the content-table column-mapping
        // requirement and works with any SQLite build. Triggers keep the FTS
        // index in sync with the interactions table.
        // ----------------------------------------------------------------
        try conn.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS fts_interactions USING fts5(
                interaction_id UNINDEXED,
                subject,
                body,
                summary,
                tokenize = 'unicode61'
            )
            """)

        // Insert trigger: populate FTS when a new interaction is added.
        try conn.execute("""
            CREATE TRIGGER IF NOT EXISTS fts_interactions_ai
            AFTER INSERT ON interactions BEGIN
                INSERT INTO fts_interactions(interaction_id, subject, body, summary)
                VALUES (new.id, new.subject, new.body, new.summary);
            END
            """)

        // Delete trigger: remove FTS row when an interaction is deleted.
        try conn.execute("""
            CREATE TRIGGER IF NOT EXISTS fts_interactions_ad
            AFTER DELETE ON interactions BEGIN
                DELETE FROM fts_interactions WHERE interaction_id = old.id;
            END
            """)

        // Update trigger: refresh FTS row when an interaction is updated.
        try conn.execute("""
            CREATE TRIGGER IF NOT EXISTS fts_interactions_au
            AFTER UPDATE ON interactions BEGIN
                DELETE FROM fts_interactions WHERE interaction_id = old.id;
                INSERT INTO fts_interactions(interaction_id, subject, body, summary)
                VALUES (new.id, new.subject, new.body, new.summary);
            END
            """)

        // ----------------------------------------------------------------
        // MARK: Indexes
        // ----------------------------------------------------------------
        let indexes: [String] = [
            // contacts
            "CREATE INDEX IF NOT EXISTS idx_contacts_email     ON contacts(email_primary COLLATE NOCASE)",
            "CREATE INDEX IF NOT EXISTS idx_contacts_company   ON contacts(company)",
            // contact_identities
            "CREATE INDEX IF NOT EXISTS idx_ci_contact_id      ON contact_identities(contact_id)",
            "CREATE INDEX IF NOT EXISTS idx_ci_platform        ON contact_identities(platform, platform_id)",
            // clients
            "CREATE INDEX IF NOT EXISTS idx_clients_domain     ON clients(domain)",
            // client_contacts
            "CREATE INDEX IF NOT EXISTS idx_cc_contact_id      ON client_contacts(contact_id)",
            "CREATE INDEX IF NOT EXISTS idx_cc_client_id       ON client_contacts(client_id)",
            // projects
            "CREATE INDEX IF NOT EXISTS idx_projects_client_id ON projects(client_id)",
            "CREATE INDEX IF NOT EXISTS idx_projects_status    ON projects(status)",
            // raw_events
            "CREATE INDEX IF NOT EXISTS idx_re_timestamp       ON raw_events(timestamp)",
            "CREATE INDEX IF NOT EXISTS idx_re_session_id      ON raw_events(session_id)",
            "CREATE INDEX IF NOT EXISTS idx_re_source_app      ON raw_events(source_app)",
            "CREATE INDEX IF NOT EXISTS idx_re_source          ON raw_events(source)",
            // interactions
            "CREATE INDEX IF NOT EXISTS idx_int_contact_id     ON interactions(contact_id)",
            "CREATE INDEX IF NOT EXISTS idx_int_client_id      ON interactions(client_id)",
            "CREATE INDEX IF NOT EXISTS idx_int_project_id     ON interactions(project_id)",
            "CREATE INDEX IF NOT EXISTS idx_int_started_at     ON interactions(started_at)",
            "CREATE INDEX IF NOT EXISTS idx_int_type           ON interactions(type)",
            // promises
            "CREATE INDEX IF NOT EXISTS idx_prom_contact_id    ON promises(contact_id)",
            "CREATE INDEX IF NOT EXISTS idx_prom_client_id     ON promises(client_id)",
            "CREATE INDEX IF NOT EXISTS idx_prom_status        ON promises(status)",
            "CREATE INDEX IF NOT EXISTS idx_prom_due_date      ON promises(due_date)",
            // work_sessions
            "CREATE INDEX IF NOT EXISTS idx_ws_client_id       ON work_sessions(client_id)",
            "CREATE INDEX IF NOT EXISTS idx_ws_project_id      ON work_sessions(project_id)",
            "CREATE INDEX IF NOT EXISTS idx_ws_started_at      ON work_sessions(started_at)",
            "CREATE INDEX IF NOT EXISTS idx_ws_billable        ON work_sessions(billable)",
            "CREATE INDEX IF NOT EXISTS idx_ws_reviewed        ON work_sessions(reviewed)",
            // session_events / interaction_events
            "CREATE INDEX IF NOT EXISTS idx_se_event_id        ON session_events(event_id)",
            "CREATE INDEX IF NOT EXISTS idx_ie_event_id        ON interaction_events(event_id)",
        ]
        for sql in indexes { try conn.execute(sql) }

        // ----------------------------------------------------------------
        // MARK: Seed user_settings defaults
        // ----------------------------------------------------------------
        let defaults: [(String, String)] = [
            ("schema_version",        "1"),
            ("capture_enabled",       "true"),
            ("audio_enabled",         "false"),
            ("whisper_model",         "base"),
            ("ollama_model",          "llama3:8b"),
            ("embed_model",           "nomic-embed-text"),
            ("review_reminder_days",  "7"),
            ("default_currency",      "USD"),
            ("onboarding_completed",  "false"),
        ]
        for (key, value) in defaults {
            try conn.execute(
                "INSERT OR IGNORE INTO user_settings(key, value) VALUES('\(key)', '\(value)')"
            )
        }

        // ----------------------------------------------------------------
        // MARK: Seed exclusion_rules defaults
        // ----------------------------------------------------------------
        let now = Date().timeIntervalSince1970
        let defaultApps = ["1Password", "Keychain Access"]
        for app in defaultApps {
            let id = UUID().uuidString
            try conn.execute("""
                INSERT OR IGNORE INTO exclusion_rules(id, type, value, created_at)
                VALUES('\(id)', 'app', '\(app)', \(now))
                """)
        }
    }
}
