import ArkTraceCore
import Darwin
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class SQLiteVMProgressBudget {
    private var callbacksRemaining: Int
    private(set) var exhausted = false

    init(vmStepBudget: Int, callbackInterval: Int32) {
        let interval = Int(callbackInterval)
        callbacksRemaining = max(1, (vmStepBudget + interval - 1) / interval)
    }

    func advance() -> Int32 {
        callbacksRemaining -= 1
        guard callbacksRemaining <= 0 else { return 0 }
        exhausted = true
        return 1
    }
}

private let sqliteVMProgressCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = {
    context in
    guard let context else { return 1 }
    return Unmanaged<SQLiteVMProgressBudget>.fromOpaque(context)
        .takeUnretainedValue()
        .advance()
}

private let sqliteTaskCancellationCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = {
    _ in Task.isCancelled ? 1 : 0
}

/// Minimal SQLite3 wrapper. Not Sendable by design: an instance is owned by a
/// single repository actor (DESIGN §9.2) or a single test.
final class TraceDatabase {
    static let maximumSchemaTableCount = 4_096

    struct VMInstructionBudgetExceeded: Error {}

    enum Binding {
        case int64(Int64)
        case text(String)
    }

    struct Row {
        let statement: OpaquePointer

        func int64(_ index: Int32) -> Int64? {
            guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else {
                return nil
            }
            return sqlite3_column_int64(statement, index)
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

    init(url: URL, readOnly: Bool, createIfMissing: Bool = true) throws {
        var db: OpaquePointer?
        // macOS exposes /var through a symlink. Resolve parent components but
        // deliberately preserve the final component so SQLITE_OPEN_NOFOLLOW
        // rejects a database-file symlink without rejecting canonical temp roots.
        let parent = url.deletingLastPathComponent()
        var canonicalParent = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = parent.path.withCString {
            Darwin.realpath($0, &canonicalParent)
        }
        let openURL = resolved.map {
            URL(fileURLWithPath: String(cString: $0), isDirectory: true)
                .appendingPathComponent(url.lastPathComponent)
        } ?? url
        var flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        if !readOnly, createIfMissing {
            flags |= SQLITE_OPEN_CREATE
        }
        if readOnly || !createIfMissing {
            flags |= SQLITE_OPEN_NOFOLLOW
        }
        let rc = sqlite3_open_v2(openURL.path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            if let db {
                sqlite3_close_v2(db)
            }
            throw ArkTraceError(
                code: .traceDatabaseInvalid,
                stage: .openingDatabase,
                message: "Cannot open SQLite database",
                details: ["sqliteCode": String(rc)]
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
        vmStepBudget: Int? = nil,
        stage: ArkTraceError.Stage = .querying,
        map: (Row) throws -> T
    ) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement
        else {
            throw ArkTraceError(
                code: stage == .querying ? .queryFailed : .traceDatabaseInvalid,
                stage: stage,
                message: "Failed to prepare internal SQLite statement",
                details: ["sqliteCode": String(sqlite3_errcode(handle))]
            )
        }
        defer { sqlite3_finalize(statement) }

        let progressInterval: Int32 = 100
        let progressBudget = vmStepBudget.map {
            SQLiteVMProgressBudget(vmStepBudget: max(1, $0), callbackInterval: progressInterval)
        }
        if let progressBudget {
            sqlite3_progress_handler(
                handle,
                progressInterval,
                sqliteVMProgressCallback,
                Unmanaged.passUnretained(progressBudget).toOpaque()
            )
        }
        defer {
            if progressBudget != nil {
                sqlite3_progress_handler(handle, 0, nil, nil)
            }
        }

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
                if rc == SQLITE_INTERRUPT, progressBudget?.exhausted == true {
                    throw VMInstructionBudgetExceeded()
                }
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
    func execute(
        _ sql: String,
        stage: ArkTraceError.Stage = .openingDatabase,
        observesTaskCancellation: Bool = false
    ) throws {
        if observesTaskCancellation {
            try Task.checkCancellation()
            sqlite3_progress_handler(
                handle,
                1_000,
                sqliteTaskCancellationCallback,
                nil
            )
        }
        defer {
            if observesTaskCancellation {
                sqlite3_progress_handler(handle, 0, nil, nil)
            }
        }
        let rc = sqlite3_exec(handle, sql, nil, nil, nil)
        if rc == SQLITE_INTERRUPT, observesTaskCancellation, Task.isCancelled {
            throw CancellationError()
        }
        guard rc == SQLITE_OK else {
            throw ArkTraceError(
                code: .traceDatabaseInvalid,
                stage: stage,
                message: "Failed to execute internal SQLite statement",
                details: ["sqliteCode": String(rc)]
            )
        }
    }

    func flush() throws {
        let rc = sqlite3_db_cacheflush(handle)
        guard rc == SQLITE_OK else {
            throw ArkTraceError(
                code: .traceDatabaseInvalid,
                stage: .indexing,
                message: "Failed to flush staging SQLite pages",
                details: ["sqliteCode": String(rc)]
            )
        }
    }

    func quickCheckIsOK() -> Bool {
        let result = try? query("PRAGMA quick_check(1)", stage: .validating) { $0.text(0) }
        return result?.first == "ok"
    }

    func tableNames() throws -> Set<String> {
        let sampledNames = try query(
            """
            SELECT name FROM sqlite_master
            WHERE type = 'table'
            LIMIT \(Self.maximumSchemaTableCount + 1)
            """,
            stage: .validating
        ) { $0.text(0) }
        guard sampledNames.count <= Self.maximumSchemaTableCount else {
            throw ArkTraceError(
                code: .traceSchemaUnsupported,
                stage: .validating,
                message: "Database schema contains too many tables",
                details: [
                    "maximum": String(Self.maximumSchemaTableCount),
                    "observedAtLeast": String(Self.maximumSchemaTableCount + 1),
                ]
            )
        }
        return Set(
            sampledNames.compactMap { $0 }
        )
    }

    /// `PRAGMA table_info` cannot bind identifiers. Names discovered from
    /// sqlite_master are quoted by doubling embedded quotes so every legal
    /// SQLite table participates in the schema fingerprint.
    func columns(of table: String) throws -> [ColumnInfo] {
        let quotedTable = "\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\""
        return try query("PRAGMA table_info(\(quotedTable))", stage: .validating) { row in
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
