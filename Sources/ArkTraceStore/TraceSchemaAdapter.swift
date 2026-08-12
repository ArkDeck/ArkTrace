import ArkTraceCore
import CryptoKit
import Foundation

/// Establishes what an exported TraceStreamer database actually supports
/// (DESIGN §9.1). Required tables missing → `TRACE_SCHEMA_UNSUPPORTED`;
/// additive upstream columns and unrelated new tables are compatible
/// (AT-DB-004).
enum TraceSchemaAdapter {
    static let version = "1"

    struct Validation {
        let capabilities: TraceCapabilities
        let schemaFingerprint: String
        /// Absolute trace start/end as stored by TraceStreamer; the Store
        /// keeps absolute times internal and converts at the boundary
        /// (DESIGN §7.1).
        let traceStartTs: Int64
        let traceEndTs: Int64
        let warnings: [String]

        var durationNs: Int64 { traceEndTs - traceStartTs }
    }

    private struct RequiredTable {
        let name: String
        let columns: [String]
    }

    private static let requiredTables: [RequiredTable] = [
        RequiredTable(name: "trace_range", columns: ["start_ts", "end_ts"]),
        RequiredTable(name: "process", columns: ["ipid", "pid", "name", "start_ts"]),
        RequiredTable(name: "thread", columns: ["itid", "tid", "name", "ipid"]),
    ]

    static func validate(_ db: TraceDatabase) throws -> Validation {
        let tables = try db.tableNames()
        var columnsByTable: [String: [TraceDatabase.ColumnInfo]] = [:]
        for table in tables where TraceDatabase.isSafeIdentifier(table) {
            columnsByTable[table] = try db.columns(of: table)
        }

        var missing: [String] = []
        for required in requiredTables {
            guard let columns = columnsByTable[required.name] else {
                missing.append(required.name)
                continue
            }
            let names = Set(columns.map(\.name))
            for column in required.columns where !names.contains(column) {
                missing.append("\(required.name).\(column)")
            }
        }
        guard missing.isEmpty else {
            throw ArkTraceError(
                code: .traceSchemaUnsupported,
                stage: .validating,
                message: "Database schema is missing required tables or columns",
                details: ["missing": missing.sorted().joined(separator: ",")]
            )
        }

        let capabilities = TraceCapabilities(
            cpuScheduling: hasTable(
                "sched_slice", columns: ["ts", "dur", "cpu", "itid"], in: columnsByTable),
            threadStates: hasTable(
                "thread_state", columns: ["ts", "dur", "itid", "state"], in: columnsByTable),
            namedSlices: hasTable(
                "callstack", columns: ["ts", "dur", "callid", "name"], in: columnsByTable),
            cpuCounters: hasTable("measure", columns: ["ts", "value", "filter_id"], in: columnsByTable)
                && hasTable("cpu_measure_filter", columns: ["id", "name"], in: columnsByTable),
            processCounters: hasTable(
                "measure", columns: ["ts", "value", "filter_id"], in: columnsByTable)
                && hasTable("process_measure_filter", columns: ["id", "name"], in: columnsByTable)
        )

        let range = try traceRange(db)
        var warnings: [String] = []
        if !capabilities.cpuScheduling {
            warnings.append("sched_slice unavailable: CPU scheduling queries are disabled")
        }

        return Validation(
            capabilities: capabilities,
            schemaFingerprint: fingerprint(of: columnsByTable),
            traceStartTs: range.start,
            traceEndTs: range.end,
            warnings: warnings
        )
    }

    private static func hasTable(
        _ name: String,
        columns required: [String],
        in columnsByTable: [String: [TraceDatabase.ColumnInfo]]
    ) -> Bool {
        guard let columns = columnsByTable[name] else { return false }
        let names = Set(columns.map(\.name))
        return required.allSatisfy(names.contains)
    }

    private static func traceRange(_ db: TraceDatabase) throws -> (start: Int64, end: Int64) {
        let rows = try db.query(
            "SELECT start_ts, end_ts FROM trace_range",
            stage: .validating
        ) { row in
            (row.int64(0), row.int64(1))
        }
        guard rows.count == 1, let start = rows[0].0, let end = rows[0].1, end > start else {
            throw ArkTraceError(
                code: .traceDatabaseInvalid,
                stage: .validating,
                message: "trace_range must contain exactly one row with end_ts > start_ts",
                details: ["rowCount": String(rows.count)]
            )
        }
        return (start, end)
    }

    /// Fingerprint over sorted table/column/type/notnull/pk descriptions
    /// (DESIGN §9.1). Additive upstream columns produce a new fingerprint but
    /// remain capability-compatible.
    private static func fingerprint(
        of columnsByTable: [String: [TraceDatabase.ColumnInfo]]
    ) -> String {
        let lines = columnsByTable
            .flatMap { table, columns in
                columns.map { column in
                    "\(table)|\(column.name)|\(column.type)|\(column.notNull ? 1 : 0)|\(column.primaryKeyIndex)"
                }
            }
            .sorted()
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(lines.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
