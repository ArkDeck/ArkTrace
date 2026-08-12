import ArkTraceCore
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal SQLite3 wrapper. Not Sendable by design: an instance is owned by a
/// single repository actor (DESIGN §9.2) or a single test.
final class TraceDatabase {
    enum Binding {
        case int64(Int64)
        case text(String)
    }

    struct Row {
        let statement: OpaquePointer

        func int64(_ index: Int32) -> Int64? {
            sqlite3_column_type(statement, index) == SQLITE_NULL
                ? nil : sqlite3_column_int64(statement, index)
        }

        func text(_ index: Int32) -> String? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL,
                let cString = sqlite3_column_text(statement, index)
            else {
                return nil
            }
            return String(cString: cString)
        }
    }

    struct ColumnInfo: Hashable {
        let name: String
        let type: String
        let notNull: Bool
        let primaryKeyIndex: Int
    }

    private var handle: OpaquePointer

    init(url: URL, readOnly: Bool) throws {
        var db: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot allocate"
            if let db {
                sqlite3_close_v2(db)
            }
            throw ArkTraceError(
                code: .traceDatabaseInvalid,
                stage: .openingDatabase,
                message: "Cannot open SQLite database: \(message)"
            )
        }
        self.handle = db
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func query<T>(
        _ sql: String,
        bindings: [Binding] = [],
        stage: ArkTraceError.Stage = .querying,
        map: (Row) throws -> T
    ) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement
        else {
            throw ArkTraceError(
                code: stage == .querying ? .queryFailed : .traceDatabaseInvalid,
                stage: stage,
                message: "Failed to prepare statement: \(String(cString: sqlite3_errmsg(handle)))"
            )
        }
        defer { sqlite3_finalize(statement) }

        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch binding {
            case .int64(let value):
                rc = sqlite3_bind_int64(statement, index, value)
            case .text(let value):
                rc = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            }
            guard rc == SQLITE_OK else {
                throw ArkTraceError(
                    code: .queryFailed,
                    stage: stage,
                    message: "Failed to bind parameter \(index)"
                )
            }
        }

        var results: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                results.append(try map(Row(statement: statement)))
            case SQLITE_DONE:
                return results
            case let rc:
                throw ArkTraceError(
                    code: stage == .querying ? .queryFailed : .traceDatabaseInvalid,
                    stage: stage,
                    message: "Statement failed with SQLite code \(rc)"
                )
            }
        }
    }

    /// DDL/insert helper for staging migrations and test fixtures only.
    /// Never receives caller-supplied values (AT-DB-006).
    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw ArkTraceError(
                code: .traceDatabaseInvalid,
                stage: .openingDatabase,
                message: "Failed to execute statement: \(String(cString: sqlite3_errmsg(handle)))"
            )
        }
    }

    func quickCheckIsOK() -> Bool {
        let result = try? query("PRAGMA quick_check(1)", stage: .validating) { $0.text(0) }
        return result?.first == "ok"
    }

    func tableNames() throws -> Set<String> {
        Set(
            try query(
                "SELECT name FROM sqlite_master WHERE type = 'table'",
                stage: .validating
            ) { $0.text(0) }.compactMap { $0 }
        )
    }

    /// `PRAGMA table_info` cannot bind identifiers, so table names are
    /// restricted to a strict identifier alphabet before interpolation.
    func columns(of table: String) throws -> [ColumnInfo] {
        guard Self.isSafeIdentifier(table) else {
            throw ArkTraceError(
                code: .internalError,
                stage: .validating,
                message: "Unsafe table identifier"
            )
        }
        return try query("PRAGMA table_info(\"\(table)\")", stage: .validating) { row in
            ColumnInfo(
                name: row.text(1) ?? "",
                type: row.text(2) ?? "",
                notNull: (row.int64(3) ?? 0) != 0,
                primaryKeyIndex: Int(row.int64(5) ?? 0)
            )
        }
    }

    static func isSafeIdentifier(_ name: String) -> Bool {
        !name.isEmpty
            && name.utf8.allSatisfy { byte in
                (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                    || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                    || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                    || byte == UInt8(ascii: "_")
            }
    }
}
