import Foundation
import SQLite
import os

/// Schema migration system for the Kerwan database.
///
/// Migrations are numbered sequentially starting at 1. Each migration runs
/// inside a transaction — if any statement fails, the entire migration is
/// rolled back and the database stays at its previous version.
///
/// The current schema version is stored in the `user_settings` table under
/// the key `"schema_version"`. A fresh database starts at version 0 (no tables).
enum Migrations {

    /// The highest migration number defined. Bump this when adding a new migration.
    static let currentVersion = 1

    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "migrations"
    )

    // MARK: - Public Entry Point

    /// Runs all pending migrations on the given database connection.
    ///
    /// Migrations execute sequentially from the current version + 1 up to
    /// ``currentVersion``. Each migration runs in its own transaction.
    ///
    /// - Parameter db: An open read-write SQLite ``Connection``.
    /// - Throws: ``StorageError/migrationFailed(version:message:)`` if any
    ///   migration fails.
    static func run(on db: Connection) throws {
        let version = try getCurrentVersion(db: db)
        logger.info("Current schema version: \(version), target: \(currentVersion)")

        if version >= currentVersion {
            logger.info("Schema is up to date.")
            return
        }

        if version < 1 {
            try runMigration(1, on: db, body: migration001)
        }
        // Future migrations:
        // if version < 2 { try runMigration(2, on: db, body: migration002) }
    }

    // MARK: - Version Tracking

    /// Reads the current schema version from the `user_settings` table.
    /// Returns 0 if the table does not exist yet (fresh database).
    private static func getCurrentVersion(db: Connection) throws -> Int {
        // Check if user_settings table exists
        let tableExists = try db.scalar(
            "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'user_settings'"
        ) as? Int64 ?? 0

        guard tableExists > 0 else { return 0 }

        guard let versionStr = try db.scalar(
            "SELECT value FROM user_settings WHERE key = 'schema_version'"
        ) as? String else {
            return 0
        }

        return Int(versionStr) ?? 0
    }

    /// Writes the schema version to the `user_settings` table.
    private static func setVersion(_ version: Int, on db: Connection) throws {
        try db.run(
            "INSERT OR REPLACE INTO user_settings (key, value) VALUES ('schema_version', ?)",
            String(version)
        )
    }

    /// Wraps a migration body in a transaction with logging and error mapping.
    private static func runMigration(
        _ version: Int,
        on db: Connection,
        body: (Connection) throws -> Void
    ) throws {
        logger.info("Running migration \(version)…")
        do {
            try db.transaction(.immediate) {
                try body(db)
                try setVersion(version, on: db)
            }
            logger.info("Migration \(version) completed successfully.")
        } catch {
            logger.error("Migration \(version) failed: \(error.localizedDescription)")
            throw StorageError.migrationFailed(
                version: version,
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Migration 001 — Initial Schema

    /// Creates all tables, indexes, FTS5 virtual table, triggers, and seeds
    /// default settings.
    private static func migration001(_ db: Connection) throws {

        // ── Enable foreign keys ─────────────────────────────────────────
        try db.execute("PRAGMA foreign_keys = ON")

        // ── Core entity tables ──────────────────────────────────────────

        try db.execute("""
            CREATE TABLE IF NOT EXISTS contacts (
                id              TEXT PRIMARY KEY NOT NULL,
                display_name    TEXT NOT NULL,
                company         TEXT,
                email_primary   TEXT,
                ai_summary      TEXT,
                relationship_score REAL NOT NULL DEFAULT 0.0,
                first_seen_at   TEXT NOT NULL,
                last_seen_at    TEXT NOT NULL,
                created_at      TEXT NOT NULL,
                updated_at      TEXT NOT NULL,
                needs_review    INTEGER NOT NULL DEFAULT 1
            )
            """)

        try db.execute("""
            CREATE TABLE IF NOT EXISTS contact_identities (
                id              TEXT PRIMARY KEY NOT NULL,
                contact_id      TEXT NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
                source          TEXT NOT NULL,
                identifier      TEXT NOT NULL,
                display_name    TEXT,
                confidence      REAL NOT NULL DEFAULT 0.5
            )
            """)

        try db.execute("""
            CREATE TABLE IF NOT EXISTS clients (
                id              TEXT PRIMARY KEY NOT NULL,
                name            TEXT NOT NULL,
                domain          TEXT,
                notes           TEXT,
                created_at      TEXT NOT NULL,
                updated_at      TEXT NOT NULL
            )
            """)

        try db.execute("""
            CREATE TABLE IF NOT EXISTS client_contacts (
                client_id       TEXT NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
                contact_id      TEXT NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
                PRIMARY KEY (client_id, contact_id)
            )
            """)

        try db.execute("""
            CREATE TABLE IF NOT EXISTS projects (
                id              TEXT PRIMARY KEY NOT NULL,
                client_id       TEXT NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
                name            TEXT NOT NULL,
                hourly_rate     REAL,
                is_active       INTEGER NOT NULL DEFAULT 1,
                created_at      TEXT NOT NULL
            )
            """)

        // ── Capture & classification tables ─────────────────────────────

        try db.execute("""
            CREATE TABLE IF NOT EXISTS raw_events (
                id              TEXT PRIMARY KEY NOT NULL,
                source          TEXT NOT NULL,
                source_app      TEXT,
                started_at      TEXT NOT NULL,
                ended_at        TEXT,
                duration_secs   INTEGER,
                raw_text        TEXT,
                metadata_json   TEXT,
                is_excluded     INTEGER NOT NULL DEFAULT 0
            )
            """)

        try db.execute("""
            CREATE TABLE IF NOT EXISTS interactions (
                id              TEXT PRIMARY KEY NOT NULL,
                contact_id      TEXT REFERENCES contacts(id) ON DELETE SET NULL,
                client_id       TEXT REFERENCES clients(id) ON DELETE SET NULL,
                project_id      TEXT REFERENCES projects(id) ON DELETE SET NULL,
                source          TEXT NOT NULL,
                interaction_type TEXT NOT NULL,
                started_at      TEXT NOT NULL,
                ended_at        TEXT,
                summary         TEXT,
                sentiment       TEXT NOT NULL DEFAULT 'neutral',
                importance      REAL NOT NULL DEFAULT 0.5,
                content_tags    TEXT NOT NULL DEFAULT '[]',
                is_reviewed     INTEGER NOT NULL DEFAULT 0
            )
            """)

        try db.execute("""
            CREATE TABLE IF NOT EXISTS interaction_events (
                interaction_id  TEXT NOT NULL REFERENCES interactions(id) ON DELETE CASCADE,
                raw_event_id    TEXT NOT NULL REFERENCES raw_events(id) ON DELETE CASCADE,
                PRIMARY KEY (interaction_id, raw_event_id)
            )
            """)

        // ── Promises ────────────────────────────────────────────────────

        try db.execute("""
            CREATE TABLE IF NOT EXISTS promises (
                id              TEXT PRIMARY KEY NOT NULL,
                interaction_id  TEXT REFERENCES interactions(id) ON DELETE SET NULL,
                contact_id      TEXT REFERENCES contacts(id) ON DELETE SET NULL,
                client_id       TEXT REFERENCES clients(id) ON DELETE SET NULL,
                direction       TEXT NOT NULL,
                description     TEXT NOT NULL,
                due_date        TEXT,
                status          TEXT NOT NULL DEFAULT 'open',
                source_quote    TEXT,
                extracted_at    TEXT NOT NULL,
                resolved_at     TEXT
            )
            """)

        // ── Billing ─────────────────────────────────────────────────────

        try db.execute("""
            CREATE TABLE IF NOT EXISTS work_sessions (
                id              TEXT PRIMARY KEY NOT NULL,
                client_id       TEXT REFERENCES clients(id) ON DELETE SET NULL,
                project_id      TEXT REFERENCES projects(id) ON DELETE SET NULL,
                started_at      TEXT NOT NULL,
                ended_at        TEXT NOT NULL,
                duration_secs   INTEGER NOT NULL,
                billable_status TEXT NOT NULL DEFAULT 'suggested',
                confidence      REAL NOT NULL DEFAULT 0.5,
                description     TEXT,
                invoice_text    TEXT,
                reviewed_at     TEXT
            )
            """)

        try db.execute("""
            CREATE TABLE IF NOT EXISTS session_events (
                session_id      TEXT NOT NULL REFERENCES work_sessions(id) ON DELETE CASCADE,
                raw_event_id    TEXT NOT NULL REFERENCES raw_events(id) ON DELETE CASCADE,
                PRIMARY KEY (session_id, raw_event_id)
            )
            """)

        // ── Privacy & settings ──────────────────────────────────────────

        try db.execute("""
            CREATE TABLE IF NOT EXISTS exclusion_rules (
                id              TEXT PRIMARY KEY NOT NULL,
                rule_type       TEXT NOT NULL,
                pattern         TEXT NOT NULL
            )
            """)

        try db.execute("""
            CREATE TABLE IF NOT EXISTS capture_pauses (
                id              TEXT PRIMARY KEY NOT NULL,
                started_at      TEXT NOT NULL,
                ended_at        TEXT,
                reason          TEXT
            )
            """)

        try db.execute("""
            CREATE TABLE IF NOT EXISTS user_settings (
                key             TEXT PRIMARY KEY NOT NULL,
                value           TEXT NOT NULL
            )
            """)

        // ── Vector tables (sqlite-vec) ──────────────────────────────────
        // These are optional — if sqlite-vec is not loaded, skip gracefully.

        do {
            try db.execute("""
                CREATE VIRTUAL TABLE IF NOT EXISTS vec_interactions USING vec0(
                    interaction_id TEXT PRIMARY KEY,
                    embedding float[384]
                )
                """)
            try db.execute("""
                CREATE VIRTUAL TABLE IF NOT EXISTS vec_raw_events USING vec0(
                    raw_event_id TEXT PRIMARY KEY,
                    embedding float[384]
                )
                """)
        } catch {
            logger.warning("sqlite-vec tables skipped (extension not loaded): \(error.localizedDescription)")
        }

        // ── FTS5 full-text search ───────────────────────────────────────

        try db.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS interactions_fts USING fts5(
                summary,
                content_tags,
                content='interactions',
                content_rowid='rowid'
            )
            """)

        // Triggers to keep FTS5 index in sync with interactions table.

        try db.execute("""
            CREATE TRIGGER IF NOT EXISTS interactions_fts_insert
            AFTER INSERT ON interactions BEGIN
                INSERT INTO interactions_fts(rowid, summary, content_tags)
                VALUES (new.rowid, new.summary, new.content_tags);
            END
            """)

        try db.execute("""
            CREATE TRIGGER IF NOT EXISTS interactions_fts_delete
            AFTER DELETE ON interactions BEGIN
                INSERT INTO interactions_fts(interactions_fts, rowid, summary, content_tags)
                VALUES ('delete', old.rowid, old.summary, old.content_tags);
            END
            """)

        try db.execute("""
            CREATE TRIGGER IF NOT EXISTS interactions_fts_update
            AFTER UPDATE ON interactions BEGIN
                INSERT INTO interactions_fts(interactions_fts, rowid, summary, content_tags)
                VALUES ('delete', old.rowid, old.summary, old.content_tags);
                INSERT INTO interactions_fts(rowid, summary, content_tags)
                VALUES (new.rowid, new.summary, new.content_tags);
            END
            """)

        // ── Indexes ─────────────────────────────────────────────────────

        // Contacts
        try db.execute("CREATE INDEX IF NOT EXISTS idx_contacts_email ON contacts(email_primary)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_contacts_score ON contacts(relationship_score)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_contacts_last_seen ON contacts(last_seen_at)")

        // Contact identities
        try db.execute("CREATE INDEX IF NOT EXISTS idx_identities_contact ON contact_identities(contact_id)")
        try db.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_identities_source_ident ON contact_identities(source, identifier)"
        )

        // Projects
        try db.execute("CREATE INDEX IF NOT EXISTS idx_projects_client ON projects(client_id)")

        // Raw events
        try db.execute("CREATE INDEX IF NOT EXISTS idx_raw_events_started ON raw_events(started_at)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_raw_events_source ON raw_events(source)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_raw_events_excluded ON raw_events(is_excluded)")

        // Interactions
        try db.execute("CREATE INDEX IF NOT EXISTS idx_interactions_contact ON interactions(contact_id)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_interactions_client ON interactions(client_id)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_interactions_project ON interactions(project_id)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_interactions_started ON interactions(started_at)")

        // Promises
        try db.execute("CREATE INDEX IF NOT EXISTS idx_promises_contact ON promises(contact_id)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_promises_status ON promises(status)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_promises_due ON promises(due_date)")

        // Work sessions
        try db.execute("CREATE INDEX IF NOT EXISTS idx_sessions_client ON work_sessions(client_id)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_sessions_started ON work_sessions(started_at)")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_sessions_billable ON work_sessions(billable_status)")

        // Exclusion rules
        try db.execute("CREATE INDEX IF NOT EXISTS idx_exclusion_type ON exclusion_rules(rule_type)")

        // ── Seed default settings ───────────────────────────────────────

        let defaults = UserSettings.defaults
        let seeds: [(String, String)] = [
            ("capture_audio", String(defaults.captureAudio)),
            ("capture_accessibility", String(defaults.captureAccessibility)),
            ("digest_time", defaults.digestTime),
            ("billable_default_rate", String(defaults.billableDefaultRate)),
            ("consent_mode", String(defaults.consentMode)),
            ("passphrase_in_keychain", String(defaults.passphraseInKeychain)),
        ]
        for (key, value) in seeds {
            try db.run(
                "INSERT OR IGNORE INTO user_settings (key, value) VALUES (?, ?)",
                key, value
            )
        }

        logger.info("Migration 001 complete — all tables, indexes, FTS5, and seeds created.")
    }
}
