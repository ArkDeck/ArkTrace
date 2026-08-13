import ArkTraceCore
import Darwin
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct TraceDatabaseFileIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

private final class SQLiteQueryProgressController {
    private var callbacksRemaining: Int?
    private let observesTaskCancellation: Bool
    private let deadline: ContinuousClock.Instant?
    private let progressHook: (@Sendable () -> Void)?
    private(set) var exhausted = false
    private(set) var cancelled = false
    private(set) var timedOut = false

    init(
        vmStepBudget: Int?,
        callbackInterval: Int32,
        observesTaskCancellation: Bool,
        deadline: ContinuousClock.Instant?,
        progressHook: (@Sendable () -> Void)?
    ) {
        let interval = Int(callbackInterval)
        callbacksRemaining = vmStepBudget.map {
            max(1, ($0 + interval - 1) / interval)
        }
        self.observesTaskCancellation = observesTaskCancellation
        self.deadline = deadline
        self.progressHook = progressHook
    }

    func advance() -> Int32 {
        progressHook?()
        if observesTaskCancellation, Task.isCancelled {
            cancelled = true
            return 1
        }
        if let deadline, ContinuousClock.now >= deadline {
            timedOut = true
            return 1
        }
        guard let remaining = callbacksRemaining else { return 0 }
        callbacksRemaining = remaining - 1
        guard remaining <= 1 else { return 0 }
        exhausted = true
        return 1
    }
}

private let sqliteVMProgressCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = {
    context in
    guard let context else { return 1 }
    return Unmanaged<SQLiteQueryProgressController>.fromOpaque(context)
        .takeUnretainedValue()
        .advance()
}

/// Minimal SQLite3 wrapper. Not Sendable by design: an instance is owned by a
/// single repository actor (DESIGN §9.2) or a single test.
final class TraceDatabase {
    static let maximumSchemaTableCount = 4_096

    struct VMInstructionBudgetExceeded: Error {}

    enum Binding: Sendable {
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
            guard let bytes = textBytes(index) else { return nil }
            return String(data: bytes, encoding: .utf8)
        }

        func textBytes(_ index: Int32) -> Data? {
            guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
                let bytes = sqlite3_column_text(statement, index)
            else {
                return nil
            }
            let count = Int(sqlite3_column_bytes(statement, index))
            return Data(bytes: bytes, count: count)
        }

        func isNull(_ index: Int32) -> Bool {
            sqlite3_column_type(statement, index) == SQLITE_NULL
        }
    }

    struct ColumnInfo: Hashable {
        let name: String
        let type: String
        let notNull: Bool
        let primaryKeyIndex: Int
        /// 0 normal, 1 hidden virtual-table column, 2 VIRTUAL generated,
        /// 3 STORED generated, following pragma_table_xinfo.
        let hiddenKind: Int
    }

    private var handle: OpaquePointer
    private let bindingDescriptor: Int32?
    private let queryObserver: (@Sendable (String, Int) -> Void)?
    let fileIdentity: TraceDatabaseFileIdentity?

    init(
        url: URL,
        readOnly: Bool,
        createIfMissing: Bool = true,
        queryObserver: (@Sendable (String, Int) -> Void)? = nil
    ) throws {
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
        let bindingDescriptor: Int32?
        let sqliteOpenPath: String
        let fileIdentity: TraceDatabaseFileIdentity?
        if readOnly {
            let descriptor = openURL.path.withCString {
                Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else {
                throw ArkTraceError(
                    code: .traceDatabaseInvalid,
                    stage: .openingDatabase,
                    message: "Cannot open SQLite database"
                )
            }
            var info = stat()
            guard Darwin.fstat(descriptor, &info) == 0,
                (info.st_mode & S_IFMT) == S_IFREG
            else {
                _ = Darwin.close(descriptor)
                throw ArkTraceError(
                    code: .traceDatabaseInvalid,
                    stage: .openingDatabase,
                    message: "Cannot open SQLite database"
                )
            }
            bindingDescriptor = descriptor
            sqliteOpenPath = "/dev/fd/\(descriptor)"
            fileIdentity = TraceDatabaseFileIdentity(
                device: UInt64(info.st_dev),
                inode: UInt64(info.st_ino)
            )
        } else {
            bindingDescriptor = nil
            sqliteOpenPath = openURL.path
            fileIdentity = nil
        }
        var flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        if !readOnly, createIfMissing {
            flags |= SQLITE_OPEN_CREATE
        }
        if readOnly || !createIfMissing {
            flags |= SQLITE_OPEN_NOFOLLOW
        }
        let rc = sqlite3_open_v2(sqliteOpenPath, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            if let db {
                sqlite3_close_v2(db)
            }
            if let bindingDescriptor { _ = Darwin.close(bindingDescriptor) }
            throw ArkTraceError(
                code: .traceDatabaseInvalid,
                stage: .openingDatabase,
                message: "Cannot open SQLite database",
                details: ["sqliteCode": String(rc)]
            )
        }
        self.handle = db
        self.bindingDescriptor = bindingDescriptor
        self.fileIdentity = fileIdentity
        self.queryObserver = queryObserver
    }

    deinit {
        sqlite3_close_v2(handle)
        if let bindingDescriptor { _ = Darwin.close(bindingDescriptor) }
    }

    func query<T>(
        _ sql: String,
        bindings: [Binding] = [],
        vmStepBudget: Int? = nil,
        vmStepObserver: ((Int) -> Void)? = nil,
        stage: ArkTraceError.Stage = .querying,
        observesTaskCancellation: Bool = false,
        deadline: ContinuousClock.Instant? = nil,
        progressHook: (@Sendable () -> Void)? = nil,
        map: (Row) throws -> T
    ) throws -> [T] {
        queryObserver?(sql, bindings.count)
        if observesTaskCancellation {
            try Task.checkCancellation()
        }
        if let deadline, ContinuousClock.now >= deadline {
            throw Self.timeout(stage: stage)
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement
        else {
            throw ArkTraceError(
                code: Self.failureCode(for: stage),
                stage: stage,
                message: "Failed to prepare internal SQLite statement",
                details: ["sqliteCode": String(sqlite3_errcode(handle))]
            )
        }
        defer {
            if let vmStepObserver {
                vmStepObserver(Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0)))
            }
            sqlite3_finalize(statement)
        }

        let progressInterval: Int32 = 100
        let progressController: SQLiteQueryProgressController?
        if vmStepBudget != nil || observesTaskCancellation || deadline != nil
            || progressHook != nil
        {
            progressController = SQLiteQueryProgressController(
                vmStepBudget: vmStepBudget.map { max(1, $0) },
                callbackInterval: progressInterval,
                observesTaskCancellation: observesTaskCancellation,
                deadline: deadline,
                progressHook: progressHook
            )
        } else {
            progressController = nil
        }
        if let progressController {
            sqlite3_progress_handler(
                handle,
                progressInterval,
                sqliteVMProgressCallback,
                Unmanaged.passUnretained(progressController).toOpaque()
            )
        }
        defer {
            if progressController != nil {
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
                    code: Self.failureCode(for: stage),
                    stage: stage,
                    message: "Failed to bind internal SQLite parameter",
                    details: ["sqliteCode": String(rc)]
                )
            }
        }

        var results: [T] = []
        while true {
            if observesTaskCancellation {
                try Task.checkCancellation()
            }
            if let deadline, ContinuousClock.now >= deadline {
                sqlite3_interrupt(handle)
                throw Self.timeout(stage: stage)
            }
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                results.append(try map(Row(statement: statement)))
            case SQLITE_DONE:
                if observesTaskCancellation {
                    try Task.checkCancellation()
                }
                if let deadline, ContinuousClock.now >= deadline {
                    throw Self.timeout(stage: stage)
                }
                return results
            case let rc:
                if rc == SQLITE_INTERRUPT {
                    if progressController?.cancelled == true
                        || (observesTaskCancellation && Task.isCancelled)
                    {
                        throw CancellationError()
                    }
                    if progressController?.timedOut == true
                        || deadline.map({ ContinuousClock.now >= $0 }) == true
                    {
                        throw Self.timeout(stage: stage)
                    }
                    if progressController?.exhausted == true {
                        throw VMInstructionBudgetExceeded()
                    }
                }
                throw ArkTraceError(
                    code: Self.failureCode(for: stage),
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
        let progressController: SQLiteQueryProgressController?
        if observesTaskCancellation {
            try Task.checkCancellation()
            let controller = SQLiteQueryProgressController(
                vmStepBudget: nil,
                callbackInterval: 1_000,
                observesTaskCancellation: true,
                deadline: nil,
                progressHook: nil
            )
            progressController = controller
            sqlite3_progress_handler(
                handle,
                1_000,
                sqliteVMProgressCallback,
                Unmanaged.passUnretained(controller).toOpaque()
            )
        } else {
            progressController = nil
        }
        defer {
            if observesTaskCancellation {
                sqlite3_progress_handler(handle, 0, nil, nil)
            }
        }
        let rc = withExtendedLifetime(progressController) {
            sqlite3_exec(handle, sql, nil, nil, nil)
        }
        if rc == SQLITE_INTERRUPT,
            progressController?.cancelled == true || (observesTaskCancellation && Task.isCancelled)
        {
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

    private static func timeout(stage: ArkTraceError.Stage) -> ArkTraceError {
        ArkTraceError(
            code: .queryTimeout,
            stage: stage,
            message: "Trace query deadline was reached",
            retryable: true
        )
    }

    /// QUERY_FAILED is reserved for the public querying stage. Failures in
    /// validation, indexing, or database opening describe an invalid database
    /// transaction and must retain a code/stage tuple accepted by AT-ERR-003.
    private static func failureCode(for stage: ArkTraceError.Stage) -> ArkTraceError.Code {
        switch stage {
        case .querying:
            return .queryFailed
        case .validating, .indexing, .openingDatabase:
            return .traceDatabaseInvalid
        case .request, .preparing, .hashing, .cacheLookup, .parsing, .analyzing, .encoding:
            // These are not valid TraceDatabase operation stages. Keep an
            // accidental internal caller from manufacturing a public tuple
            // whose code and stage contradict each other.
            return .internalError
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

    func quickCheckIsOK(
        stage: ArkTraceError.Stage = .validating,
        progressHook: (@Sendable () -> Void)? = nil
    ) throws -> Bool {
        let result = try query(
            "PRAGMA quick_check(1)",
            stage: stage,
            observesTaskCancellation: true,
            progressHook: progressHook
        ) { $0.text(0) }
        return result.first == "ok"
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
    func columns(
        of table: String,
        stage: ArkTraceError.Stage = .validating,
        observesTaskCancellation: Bool = false,
        deadline: ContinuousClock.Instant? = nil
    ) throws -> [ColumnInfo] {
        let quotedTable = "\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\""
        return try query(
            "PRAGMA table_xinfo(\(quotedTable))",
            stage: stage,
            observesTaskCancellation: observesTaskCancellation,
            deadline: deadline
        ) { row in
            ColumnInfo(
                name: row.text(1) ?? "",
                type: row.text(2) ?? "",
                notNull: (row.int64(3) ?? 0) != 0,
                primaryKeyIndex: Int(row.int64(5) ?? 0),
                hiddenKind: Int(row.int64(6) ?? 0)
            )
        }
    }

    /// Returns a deterministic bounded-prefix scan without assuming every
    /// compatible SQLite table exposes a hidden `rowid`. Ordinary tables use
    /// an unshadowed rowid alias. WITHOUT ROWID tables and ordinary tables
    /// that shadow every alias use `NOT INDEXED` physical B-tree/record order.
    func boundedSamplingOrderClause(
        of table: String,
        deadline: ContinuousClock.Instant? = nil
    ) throws -> String {
        guard Self.isSafeIdentifier(table) else {
            throw ArkTraceError(
                code: .traceSchemaUnsupported,
                stage: .querying,
                message: "Summary sampling table is unsupported"
            )
        }
        let rowIDAlias = try unshadowedRowIDAlias(of: table, deadline: deadline)
        let tableRows = try query(
            """
            SELECT wr FROM pragma_table_list(?)
            WHERE schema = 'main' AND name = ? AND type = 'table'
            LIMIT 2
            """,
            bindings: [.text(table), .text(table)],
            vmStepBudget: 10_000,
            stage: .querying,
            observesTaskCancellation: true,
            deadline: deadline
        ) { $0.int64(0) }
        guard tableRows.count == 1, let withoutRowID = tableRows[0] else {
            throw ArkTraceError(
                code: .traceSchemaUnsupported,
                stage: .querying,
                message: "Summary sampling table identity is unavailable"
            )
        }
        if withoutRowID == 0, let rowIDAlias {
            return "ORDER BY \(rowIDAlias) ASC"
        }
        // WITHOUT ROWID storage is already a stable primary-key B-tree, but
        // pragma_table_xinfo does not expose each declared ASC/DESC direction.
        // NOT INDEXED forces its physical record order and avoids a temp sort.
        // It also preserves additive compatibility when all rowid aliases of
        // an ordinary table are shadowed.
        return "NOT INDEXED"
    }

    /// Returns an unshadowed SQLite row identity alias for ordinary tables.
    /// Generated/hidden additive columns participate through table_xinfo, so
    /// callers never mistake a user column for SQLite's stable record ID.
    func unshadowedRowIDAlias(
        of table: String,
        deadline: ContinuousClock.Instant? = nil
    ) throws -> String? {
        guard Self.isSafeIdentifier(table) else {
            throw ArkTraceError(
                code: .traceSchemaUnsupported,
                stage: .querying,
                message: "Event identity table is unsupported"
            )
        }
        let columns = try columns(
            of: table,
            stage: .querying,
            observesTaskCancellation: true,
            deadline: deadline
        )
        let names = Set(columns.map { $0.name.lowercased() })
        let tableRows = try query(
            """
            SELECT wr FROM pragma_table_list(?)
            WHERE schema = 'main' AND name = ? AND type = 'table'
            LIMIT 2
            """,
            bindings: [.text(table), .text(table)],
            vmStepBudget: 10_000,
            stage: .querying,
            observesTaskCancellation: true,
            deadline: deadline
        ) { $0.int64(0) }
        guard tableRows.count == 1, tableRows[0] == 0 else { return nil }
        return ["rowid", "_rowid_", "oid"].first { !names.contains($0) }
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
