import ArkTraceCore
import Foundation

/// What the repository knows about the original trace file; the exported
/// database alone cannot provide this (and must not, see AT-PARSE-004).
public struct TraceSourceDescriptor: Sendable {
    public let traceSHA256: String
    public let sourceByteCount: Int64
    public let sourceFormat: String?

    public init(traceSHA256: String, sourceByteCount: Int64, sourceFormat: String? = nil) {
        self.traceSHA256 = traceSHA256
        self.sourceByteCount = sourceByteCount
        self.sourceFormat = sourceFormat
    }
}

/// Typed repository over one exported TraceStreamer database (DESIGN §9.2).
///
/// The database is opened read-only (AT-DB-010); every caller-supplied value
/// is bound, never interpolated (AT-DB-006); directory queries are bounded
/// with limit+1 truncation detection (AT-QUERY-002); public times are
/// trace-relative Int64 nanoseconds (AT-TIME-001/002).
public actor SQLiteTraceRepository: TraceRepositoryProtocol {
    private let db: TraceDatabase
    private let parserIdentity: TraceParserIdentity
    private let source: TraceSourceDescriptor
    private let validation: TraceSchemaAdapter.Validation
    private let processHasEndTs: Bool
    private let processHasThreadCount: Bool
    private let threadHasEndTs: Bool
    private let threadHasIsMainThread: Bool

    public init(
        databaseURL: URL,
        parser: TraceParserIdentity,
        source: TraceSourceDescriptor
    ) throws {
        let db = try TraceDatabase(url: databaseURL, readOnly: true)
        guard db.quickCheckIsOK() else {
            throw ArkTraceError(
                code: .traceDatabaseInvalid,
                stage: .validating,
                message: "SQLite quick_check failed"
            )
        }
        self.db = db
        self.parserIdentity = parser
        self.source = source
        self.validation = try TraceSchemaAdapter.validate(db)

        let processColumns = Set(try db.columns(of: "process").map(\.name))
        let threadColumns = Set(try db.columns(of: "thread").map(\.name))
        self.processHasEndTs = processColumns.contains("end_ts")
        self.processHasThreadCount = processColumns.contains("thread_count")
        self.threadHasEndTs = threadColumns.contains("end_ts")
        self.threadHasIsMainThread = threadColumns.contains("is_main_thread")
    }

    // MARK: - TraceRepositoryProtocol

    public func metadata() async throws -> TraceMetadata {
        TraceMetadata(
            traceSHA256: source.traceSHA256,
            sourceByteCount: source.sourceByteCount,
            durationNs: validation.durationNs,
            sourceFormat: source.sourceFormat,
            parser: parserIdentity,
            schemaFingerprint: validation.schemaFingerprint,
            capabilities: validation.capabilities,
            dataQuality: TraceDataQuality(warnings: validation.warnings)
        )
    }

    public func processes(_ query: ProcessQuery) async throws -> BoundedPage<TraceProcess> {
        var select = ["ipid", "pid", "name", "start_ts"]
        if processHasEndTs { select.append("end_ts") }
        if processHasThreadCount { select.append("thread_count") }

        var sql = "SELECT \(select.joined(separator: ", ")) FROM process"
        var conditions: [String] = []
        var bindings: [TraceDatabase.Binding] = []
        if let pid = query.pid {
            conditions.append("pid = ?")
            bindings.append(.int64(pid))
        }
        if let name = query.name {
            conditions.append("name = ?")
            bindings.append(.text(name))
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY pid ASC, ipid ASC LIMIT ?"
        bindings.append(.int64(Int64(query.limit) + 1))

        let endIndex: Int32? = processHasEndTs ? 4 : nil
        let threadCountIndex: Int32? =
            processHasThreadCount ? (processHasEndTs ? 5 : 4) : nil

        let rows = try db.query(sql, bindings: bindings) { row in
            guard let ipid = row.int64(0), let pid = row.int64(1) else {
                throw Self.invalidIdentity(table: "process")
            }
            return TraceProcess(
                key: ProcessKey(ipid: ipid),
                pid: pid,
                name: row.text(2),
                startNs: try relative(row.int64(3)),
                endNs: try relative(endIndex.flatMap { row.int64($0) }),
                threadCount: threadCountIndex.flatMap { row.int64($0) }.map(Int.init)
            )
        }
        return page(rows, limit: query.limit)
    }

    public func threads(_ query: ThreadQuery) async throws -> BoundedPage<TraceThread> {
        var select = ["t.itid", "t.tid", "t.name", "t.start_ts", "t.ipid", "p.pid", "p.name"]
        if threadHasEndTs { select.append("t.end_ts") }
        if threadHasIsMainThread { select.append("t.is_main_thread") }

        var sql = """
            SELECT \(select.joined(separator: ", "))
            FROM thread t LEFT JOIN process p ON t.ipid = p.ipid
            """
        var conditions: [String] = []
        var bindings: [TraceDatabase.Binding] = []
        if let processKey = query.processKey {
            conditions.append("t.ipid = ?")
            bindings.append(.int64(processKey.ipid))
        }
        if let pid = query.pid {
            conditions.append("p.pid = ?")
            bindings.append(.int64(pid))
        }
        if let threadKey = query.threadKey {
            conditions.append("t.itid = ?")
            bindings.append(.int64(threadKey.itid))
        }
        if let tid = query.tid {
            conditions.append("t.tid = ?")
            bindings.append(.int64(tid))
        }
        if let name = query.name {
            conditions.append("t.name = ?")
            bindings.append(.text(name))
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY (p.pid IS NULL) ASC, p.pid ASC, t.tid ASC, t.itid ASC LIMIT ?"
        bindings.append(.int64(Int64(query.limit) + 1))

        let endIndex: Int32? = threadHasEndTs ? 7 : nil
        let mainThreadIndex: Int32? =
            threadHasIsMainThread ? (threadHasEndTs ? 8 : 7) : nil

        let rows = try db.query(sql, bindings: bindings) { row in
            guard let itid = row.int64(0), let tid = row.int64(1) else {
                throw Self.invalidIdentity(table: "thread")
            }
            return TraceThread(
                key: ThreadKey(itid: itid),
                processKey: row.int64(4).map(ProcessKey.init(ipid:)),
                tid: tid,
                pid: row.int64(5),
                name: row.text(2),
                processName: row.text(6),
                startNs: try relative(row.int64(3)),
                endNs: try relative(endIndex.flatMap { row.int64($0) }),
                isMainThread: mainThreadIndex.flatMap { row.int64($0) }.map { $0 != 0 }
            )
        }
        return page(rows, limit: query.limit)
    }

    // MARK: - Helpers

    /// Absolute TraceStreamer time → trace-relative nanoseconds, clamped into
    /// `[0, durationNs]`. Only the Store sees absolute times (DESIGN §7.1).
    private func relative(_ absolute: Int64?) throws -> Int64? {
        guard let value = absolute else { return nil }
        if value <= validation.traceStartTs { return 0 }
        if value >= validation.traceEndTs { return validation.durationNs }

        let (relative, overflow) = value.subtractingReportingOverflow(validation.traceStartTs)
        guard !overflow, relative >= 0, relative <= validation.durationNs else {
            throw ArkTraceError(
                code: .traceDatabaseInvalid,
                stage: .querying,
                message: "Trace timestamp cannot be represented relative to trace start"
            )
        }
        return relative
    }

    private func page<T>(_ rows: [T], limit: Int) -> BoundedPage<T> {
        BoundedPage(items: Array(rows.prefix(limit)), truncated: rows.count > limit)
    }

    private static func invalidIdentity(table: String) -> ArkTraceError {
        ArkTraceError(
            code: .traceDatabaseInvalid,
            stage: .querying,
            message: "Required trace identity is not an SQLite INTEGER",
            details: ["table": table]
        )
    }
}
