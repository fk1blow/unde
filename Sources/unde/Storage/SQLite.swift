import Foundation
import SQLite3

// Bind/step against a live connection. Deliberately tiny — just enough for the
// history repository, using the system SQLite (no third-party runtime).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A thin, synchronous wrapper over a single SQLite connection. All access
/// happens on one serial queue so the connection is never touched concurrently.
final class SQLiteDatabase {

    enum SQLiteError: Error {
        case open(Int32)
        case prepare(String)
        case step(Int32, String)
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.codeagency.unde.sqlite")

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK else {
            throw SQLiteError.open(rc)
        }
        // Durable but fast enough for human-cadence writes.
        try? execute("PRAGMA journal_mode=WAL;")
        try? execute("PRAGMA synchronous=NORMAL;")
        try? execute("PRAGMA foreign_keys=ON;")
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    /// Run work with exclusive access to the connection.
    func sync<T>(_ body: (OpaquePointer?) throws -> T) rethrows -> T {
        try queue.sync { try body(db) }
    }

    /// Execute a statement with no result rows (DDL, INSERT, DELETE…).
    func execute(_ sql: String, _ params: [SQLiteValue] = []) throws {
        try sync { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SQLiteError.prepare(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            Self.bind(params, to: stmt)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                throw SQLiteError.step(rc, String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// Run a query and map each row via `rowMapper`.
    func query<T>(_ sql: String, _ params: [SQLiteValue] = [], _ rowMapper: (Row) -> T) throws -> [T] {
        try sync { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SQLiteError.prepare(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            Self.bind(params, to: stmt)
            var results: [T] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(rowMapper(Row(stmt: stmt)))
            }
            return results
        }
    }

    private static func bind(_ params: [SQLiteValue], to stmt: OpaquePointer?) {
        for (i, value) in params.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case .null:
                sqlite3_bind_null(stmt, idx)
            case .int(let n):
                sqlite3_bind_int64(stmt, idx, n)
            case .double(let d):
                sqlite3_bind_double(stmt, idx, d)
            case .text(let s):
                sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            }
        }
    }
}

/// A bound parameter value.
enum SQLiteValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)

    static func intOrNull(_ v: Int?) -> SQLiteValue { v.map { .int(Int64($0)) } ?? .null }
    static func textOrNull(_ v: String?) -> SQLiteValue { v.map { .text($0) } ?? .null }
    static func doubleOrNull(_ v: Double?) -> SQLiteValue { v.map { .double($0) } ?? .null }
}

/// Column accessors for a single result row.
struct Row {
    let stmt: OpaquePointer?

    func text(_ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
              let c = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: c)
    }
    func int(_ col: Int32) -> Int? {
        sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, col))
    }
    func double(_ col: Int32) -> Double? {
        sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, col)
    }
}
