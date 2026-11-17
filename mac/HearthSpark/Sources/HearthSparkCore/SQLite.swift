import Foundation
import SQLite3

/// A minimal read-only SQLite connection.
///
/// Opened with `mode=ro`, so Hearth Spark can never modify the user's Messages or call
/// databases, even by accident.
final class ReadOnlyDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw SourceError.notReadable(path)
        }
        let uri = "file:\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw SourceError.notReadable("\(path) (\(message))")
        }
    }

    deinit { sqlite3_close(handle) }

    /// Column names of a table, for checking the schema before trusting a query.
    func columns(of table: String) throws -> Set<String> {
        var names = Set<String>()
        try query("SELECT name FROM pragma_table_info('\(table)')") { row in
            if let name = row.text(0) { names.insert(name) }
        }
        return names
    }

    func query(_ sql: String, bind: [Double] = [], row: (Row) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SourceError.queryFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bind.enumerated() {
            sqlite3_bind_double(statement, Int32(index + 1), value)
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw SourceError.queryFailed(String(cString: sqlite3_errmsg(handle)))
            }
            row(Row(statement: statement))
        }
    }

    struct Row {
        let statement: OpaquePointer?

        func text(_ column: Int32) -> String? {
            // Works for TEXT and for BLOB columns holding UTF-8, as some versions of
            // the call history store addresses.
            guard sqlite3_column_type(statement, column) != SQLITE_NULL,
                  let bytes = sqlite3_column_text(statement, column)
            else { return nil }
            return String(cString: bytes)
        }

        func double(_ column: Int32) -> Double? {
            sqlite3_column_type(statement, column) == SQLITE_NULL
                ? nil : sqlite3_column_double(statement, column)
        }

        func int(_ column: Int32) -> Int {
            Int(sqlite3_column_int64(statement, column))
        }
    }
}

public enum SourceError: LocalizedError, Equatable {
    case notReadable(String)
    case notSetUp(String)
    case unexpectedSchema(table: String, missing: [String])
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notReadable(let path):
            "Can't read \(path). Give your terminal Full Disk Access in System Settings → Privacy & Security, then run again."
        case .notSetUp(let reason):
            reason
        case let .unexpectedSchema(table, missing):
            "The \(table) table has changed in this macOS version (missing: \(missing.joined(separator: ", "))). Hearth Spark won't guess, so this source was skipped."
        case .queryFailed(let message):
            "Database query failed: \(message)"
        }
    }
}
