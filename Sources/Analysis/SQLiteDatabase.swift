import Foundation
import SQLite3

struct SQLiteError: Error, CustomStringConvertible {
    var code: Int32
    var message: String
    var description: String { "SQLite error \(code): \(message)" }
}

enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
}

/// Thin wrapper over one sqlite3 connection. Not thread-safe; `TrendStore` serialises access.
final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    // Tells SQLite to copy bound strings, since Swift's buffer is gone after the call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let error = lastError()
            sqlite3_close(handle)
            throw error
        }
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit { sqlite3_close(handle) }

    private func lastError(code: Int32? = nil) -> SQLiteError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        return SQLiteError(code: code ?? sqlite3_errcode(handle), message: message)
    }

    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        try query(sql, values) { _ in }
    }

    /// Runs `sql` and calls `row` for each result row.
    func query(_ sql: String, _ values: [SQLValue] = [], row: (Row) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError()
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case .int(let v): result = sqlite3_bind_int64(statement, position, v)
            case .double(let v): result = sqlite3_bind_double(statement, position, v)
            case .text(let v):
                result = sqlite3_bind_text(statement, position, v, -1, Self.transient)
            }
            guard result == SQLITE_OK else { throw lastError(code: result) }
        }

        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                row(Row(statement: statement))
            } else if step == SQLITE_DONE {
                return
            } else {
                throw lastError(code: step)
            }
        }
    }

    func inTransaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    struct Row {
        fileprivate let statement: OpaquePointer?
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        /// NULL reads as an empty string.
        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
    }
}
