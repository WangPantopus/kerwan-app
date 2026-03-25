import Foundation
import SQLite3
import os.log

// MARK: - SQLiteValue

/// Typed value for SQLite parameter binding.
enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

extension SQLiteValue {
    static func from(_ v: String?)  -> SQLiteValue { v.map { .text($0) }    ?? .null }
    static func from(_ v: Double?)  -> SQLiteValue { v.map { .real($0) }    ?? .null }
    static func from(_ v: Int?)     -> SQLiteValue { v.map { .integer(Int64($0)) } ?? .null }
    static func from(_ v: Int64?)   -> SQLiteValue { v.map { .integer($0) } ?? .null }
    static func from(_ v: Bool)     -> SQLiteValue { .integer(v ? 1 : 0) }
    static func from(_ v: Date)     -> SQLiteValue { .real(v.timeIntervalSince1970) }
    static func from(_ v: Date?)    -> SQLiteValue { v.map { .real($0.timeIntervalSince1970) } ?? .null }
}

// MARK: - SQLITE_TRANSIENT

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - SQLiteConnection

/// A thin, non-Sendable wrapper around a raw `sqlite3*` handle.
///
/// Not thread-safe on its own. Thread safety is enforced by the
/// `StorageActor` (writes) and `ReadConnectionBox` (reads via NSLock).
final class SQLiteConnection {

    private(set) var db: OpaquePointer?
    let path: String
    private let log = Logger(subsystem: "com.kerwan.app", category: "SQLiteConnection")

    init(path: String) {
        self.path = path
    }

    deinit { close() }

    // MARK: - Lifecycle

    /// Opens the database with the given flags.
    func open(
        flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    ) throws {
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, db != nil else {
            throw StorageError.databaseNotFound
        }
    }

    /// Opens the database for WAL-mode reading.
    ///
    /// WAL-mode databases require write access to the `.db-shm` shared-memory file
    /// even for reader connections (SQLite uses it for WAL coordination). Opening
    /// with `SQLITE_OPEN_READONLY` will fail with `SQLITE_CANTOPEN` because SQLite
    /// cannot update the WAL index. We therefore open with `READWRITE` and enforce
    /// read-only semantics via `PRAGMA query_only = ON` in `configureReadOnly`.
    func openReadOnly() throws {
        try open(flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX)
    }

    func close() {
        guard let handle = db else { return }
        sqlite3_close_v2(handle)
        db = nil
    }

    // MARK: - Direct Execute

    /// Executes a SQL string that produces no rows.
    func execute(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw StorageError.writeFailed(SQLiteError(code: rc, message: msg))
        }
    }

    // MARK: - Prepare

    /// Returns a compiled statement. Caller must finalize it.
    func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw StorageError.writeFailed(SQLiteError(code: rc, message: errorMessage))
        }
        return stmt
    }

    // MARK: - Binding

    func bind(_ values: [SQLiteValue], to stmt: OpaquePointer) throws {
        for (idx, value) in values.enumerated() {
            let col = Int32(idx + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(stmt, col)
            case .integer(let i):
                rc = sqlite3_bind_int64(stmt, col, i)
            case .real(let d):
                rc = sqlite3_bind_double(stmt, col, d)
            case .text(let s):
                rc = sqlite3_bind_text(stmt, col, s, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                rc = data.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, col, ptr.baseAddress,
                                      Int32(data.count), SQLITE_TRANSIENT)
                }
            }
            guard rc == SQLITE_OK else {
                throw StorageError.writeFailed(SQLiteError(code: rc, message: errorMessage))
            }
        }
    }

    // MARK: - Step helpers

    /// Executes a write statement (INSERT/UPDATE/DELETE). Throws on error.
    func step(_ stmt: OpaquePointer) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw StorageError.writeFailed(SQLiteError(code: rc, message: errorMessage))
        }
    }

    // MARK: - Row Iteration

    /// Iterates over all rows returned by a SELECT.
    func query(
        _ sql: String,
        bindings: [SQLiteValue] = [],
        each handler: (OpaquePointer) throws -> Void
    ) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(bindings, to: stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                try handler(stmt)
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw StorageError.readFailed(SQLiteError(code: rc, message: errorMessage))
            }
        }
    }

    // MARK: - Scalar Query

    func scalar<T>(_ sql: String, bindings: [SQLiteValue] = []) throws -> T? {
        var result: T?
        try query(sql, bindings: bindings) { stmt in
            result = column(stmt, at: 0) as? T
        }
        return result
    }

    // MARK: - Column Accessors

    func column(_ stmt: OpaquePointer, at index: Int32) -> Any? {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_INTEGER: return sqlite3_column_int64(stmt, index)
        case SQLITE_FLOAT:   return sqlite3_column_double(stmt, index)
        case SQLITE_TEXT:    return columnText(stmt, at: index)
        case SQLITE_BLOB:
            guard let ptr = sqlite3_column_blob(stmt, index) else { return nil }
            return Data(bytes: ptr, count: Int(sqlite3_column_bytes(stmt, index)))
        default:             return nil
        }
    }

    func columnText(_ stmt: OpaquePointer, at index: Int32) -> String? {
        guard let cstr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cstr)
    }

    func columnInt64(_ stmt: OpaquePointer, at index: Int32) -> Int64 {
        sqlite3_column_int64(stmt, index)
    }

    func columnDouble(_ stmt: OpaquePointer, at index: Int32) -> Double {
        sqlite3_column_double(stmt, index)
    }

    func columnBool(_ stmt: OpaquePointer, at index: Int32) -> Bool {
        sqlite3_column_int64(stmt, index) != 0
    }

    func columnDate(_ stmt: OpaquePointer, at index: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
    }

    func columnDateOptional(_ stmt: OpaquePointer, at index: Int32) -> Date? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
    }

    // MARK: - Transactions

    /// Runs `block` inside BEGIN IMMEDIATE / COMMIT, rolling back on throw.
    @discardableResult
    func transaction<T>(_ block: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try block()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Metadata

    var errorMessage: String {
        guard let db else { return "no database open" }
        return String(cString: sqlite3_errmsg(db))
    }

    var lastInsertRowid: Int64 {
        guard let db else { return 0 }
        return sqlite3_last_insert_rowid(db)
    }

    var changes: Int32 {
        guard let db else { return 0 }
        return sqlite3_changes(db)
    }
}

// MARK: - ReadConnectionBox

/// A thread-safe box around a single read connection, protected by NSLock.
/// Allows reads to proceed concurrently with actor-isolated writes at the SQLite level.
final class ReadConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private let conn: SQLiteConnection

    init(conn: SQLiteConnection) {
        self.conn = conn
    }

    /// Executes `block` while holding the lock.
    func withConnection<T>(_ block: (SQLiteConnection) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try block(conn)
    }
}
