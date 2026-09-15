import Foundation
import SQLite3

/// SQLite's own "this string is a copy, take it" sentinel, which Swift does not expose.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct SQLiteError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
    var localizedDescription: String { message }
}

/**
 A thin wrapper over the SQLite that every iPhone already has.

 Deliberately thin, and deliberately not Core Data. What this app stores is a few hundred thousand
 rows of four integers each, written a handful at a time and read in one sweep at launch; the
 queries it runs are the ones the Android build's DAOs run, written out in the same SQL. A managed
 object graph would add a lot of machinery on top of that and take the plain SQL away, and the
 statistics really are plain SQL.
 */
final class SQLiteDatabase {

    private var handle: OpaquePointer?

    convenience init(url: URL) throws {
        try self.init(path: url.path)
    }

    init(path: String) throws {
        // FULLMUTEX because the repository actor's work can land on any thread in the pool.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open \(path)"
            sqlite3_close_v2(handle)
            throw SQLiteError(message: message)
        }
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA synchronous = NORMAL")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "statement failed"
            sqlite3_free(error)
            throw SQLiteError(message: "\(message) — while running: \(sql)")
        }
    }

    /// Runs a statement that returns nothing, and says how many rows it touched.
    @discardableResult
    func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw lastError(sql) }
        return Int(sqlite3_changes(handle))
    }

    /// Runs a query, handing each row to `read` in turn.
    func query(_ sql: String, _ bindings: [SQLiteValue] = [], _ read: (Row) -> Void) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw lastError(sql) }
            read(Row(statement: statement))
        }
    }

    /// The first column of the first row, or nil when the query found nothing.
    func scalar(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> SQLiteValue? {
        var value: SQLiteValue?
        try query(sql, bindings) { row in
            if value == nil { value = row.value(0) }
        }
        return value
    }

    /// Everything in `body` commits together, or none of it does.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int {
        guard let value = try? scalar("PRAGMA user_version") else { return 0 }
        return value?.intValue ?? 0
    }

    func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    private func prepare(_ sql: String, _ bindings: [SQLiteValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(sql)
        }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let value): sqlite3_bind_int64(statement, index, value)
            case .real(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            }
        }
        return statement
    }

    private func lastError(_ sql: String) -> SQLiteError {
        SQLiteError(message: "\(String(cString: sqlite3_errmsg(handle))) — while running: \(sql)")
    }

    struct Row {
        let statement: OpaquePointer?

        func value(_ index: Int32) -> SQLiteValue {
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
            case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, index))
            case SQLITE_TEXT:
                guard let raw = sqlite3_column_text(statement, index) else { return .null }
                return .text(String(cString: raw))
            default: return .null
            }
        }

        func int64(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
        func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
        func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }

        func optionalDouble(_ index: Int32) -> Double? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : double(index)
        }

        func text(_ index: Int32) -> String {
            guard let raw = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: raw)
        }

        func optionalText(_ index: Int32) -> String? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(index)
        }
    }
}

enum SQLiteValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    var intValue: Int? {
        if case .integer(let value) = self { return Int(value) }
        return nil
    }

    var int64Value: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    var textValue: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    static func int(_ value: Int) -> SQLiteValue { .integer(Int64(value)) }
    static func optionalReal(_ value: Double?) -> SQLiteValue { value.map { .real($0) } ?? .null }
}
