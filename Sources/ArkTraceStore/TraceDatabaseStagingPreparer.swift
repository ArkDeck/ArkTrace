import ArkTraceCore
import CryptoKit
import Foundation

/// Validates and indexes a private parser output before the parser may expose
/// it as a Ready database. Every identifier below is an ArkTrace constant;
/// no caller or upstream text is interpolated into DDL.
public enum TraceDatabaseStagingPreparer {
    public static let indexVersion = 1

    private struct IndexDefinition {
        let name: String
        let table: String
        let columns: [String]
        let bootstrapForValidation: Bool
    }

    private static let indexes = [
        IndexDefinition(
            name: "arktrace_v1_process_pid",
            table: "process",
            columns: ["pid"],
            bootstrapForValidation: false
        ),
        IndexDefinition(
            name: "arktrace_v1_process_ipid",
            table: "process",
            columns: ["ipid"],
            bootstrapForValidation: true
        ),
        IndexDefinition(
            name: "arktrace_v1_thread_tid_ipid",
            table: "thread",
            columns: ["tid", "ipid"],
            bootstrapForValidation: false
        ),
        IndexDefinition(
            name: "arktrace_v1_thread_itid",
            table: "thread",
            columns: ["itid"],
            bootstrapForValidation: true
        ),
        IndexDefinition(
            name: "arktrace_v1_sched_slice_ts_cpu",
            table: "sched_slice",
            columns: ["ts", "cpu"],
            bootstrapForValidation: false
        ),
        IndexDefinition(
            name: "arktrace_v1_sched_slice_itid_ts",
            table: "sched_slice",
            columns: ["itid", "ts"],
            bootstrapForValidation: false
        ),
        IndexDefinition(
            name: "arktrace_v1_thread_state_ts_cpu",
            table: "thread_state",
            columns: ["ts", "cpu"],
            bootstrapForValidation: false
        ),
        IndexDefinition(
            name: "arktrace_v1_thread_state_itid_ts",
            table: "thread_state",
            columns: ["itid", "ts"],
            bootstrapForValidation: false
        ),
        IndexDefinition(
            name: "arktrace_v1_callstack_callid_ts",
            table: "callstack",
            columns: ["callid", "ts"],
            bootstrapForValidation: false
        ),
        IndexDefinition(
            name: "arktrace_v1_measure_filter_id_ts",
            table: "measure",
            columns: ["filter_id", "ts"],
            bootstrapForValidation: false
        ),
    ]

    public static func prepare(
        databaseURL: URL,
        progress: TraceProgressHandler? = nil
    ) throws -> TraceDatabasePreparationResult {
        progress?(.validating)
        try Task.checkCancellation()
        let upstreamDatabase = try sha256AndSize(at: databaseURL)
        try Task.checkCancellation()
        let db = try TraceDatabase(
            url: databaseURL,
            readOnly: false,
            createIfMissing: false
        )
        guard db.quickCheckIsOK() else {
            throw ArkTraceError(
                code: .traceDatabaseInvalid,
                stage: .validating,
                message: "SQLite quick_check failed"
            )
        }
        try Task.checkCancellation()

        let available = try availableColumns(in: db)
        // These two target indexes bound the relationship probes on upstream
        // exports that contain no indexes. They are validation infrastructure;
        // the full migration stage begins only after semantic validation.
        try recreateIndexes(
            indexes.filter(\.bootstrapForValidation),
            availableColumns: available,
            in: db
        )
        try Task.checkCancellation()

        let validation = try TraceSchemaAdapter.validate(db)
        try Task.checkCancellation()
        progress?(.indexing)
        try recreateIndexes(indexes, availableColumns: available, in: db)
        try Task.checkCancellation()
        guard db.quickCheckIsOK() else {
            throw ArkTraceError(
                code: .traceDatabaseInvalid,
                stage: .indexing,
                message: "SQLite quick_check failed after index migration"
            )
        }
        try db.flush()
        try Task.checkCancellation()

        return TraceDatabasePreparationResult(
            schemaAdapterVersion: TraceSchemaAdapter.version,
            schemaFingerprint: validation.schemaFingerprint,
            indexVersion: indexVersion,
            upstreamDatabaseSHA256: upstreamDatabase.sha256,
            upstreamDatabaseByteCount: upstreamDatabase.byteCount
        )
    }

    public static var requiredIndexNames: Set<String> {
        Set(indexes.filter { $0.table != "measure" }.map(\.name))
    }

    private static func availableColumns(
        in db: TraceDatabase
    ) throws -> [String: Set<String>] {
        let tables = try db.tableNames()
        var result: [String: Set<String>] = [:]
        for table in tables where TraceDatabase.isSafeIdentifier(table) {
            result[table] = Set(try db.columns(of: table).map(\.name))
        }
        return result
    }

    private static func recreateIndexes(
        _ definitions: [IndexDefinition],
        availableColumns: [String: Set<String>],
        in db: TraceDatabase
    ) throws {
        let applicable = definitions.filter { definition in
            guard let columns = availableColumns[definition.table] else { return false }
            return definition.columns.allSatisfy(columns.contains)
        }
        guard !applicable.isEmpty else { return }

        try db.execute(
            "BEGIN IMMEDIATE",
            stage: .indexing,
            observesTaskCancellation: true
        )
        do {
            for definition in applicable {
                try Task.checkCancellation()
                try db.execute(
                    "DROP INDEX IF EXISTS \(definition.name)",
                    stage: .indexing,
                    observesTaskCancellation: true
                )
                try db.execute(
                    "CREATE INDEX \(definition.name) ON \(definition.table)"
                        + "(\(definition.columns.joined(separator: ", ")))",
                    stage: .indexing,
                    observesTaskCancellation: true
                )
            }
            try db.execute(
                "COMMIT",
                stage: .indexing,
                observesTaskCancellation: true
            )
        } catch {
            try? db.execute("ROLLBACK", stage: .indexing)
            throw error
        }
    }

    private static func sha256AndSize(
        at url: URL
    ) throws -> (sha256: String, byteCount: Int64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ArkTraceError(
                code: .traceDatabaseInvalid,
                stage: .validating,
                message: "Cannot hash private staging database"
            )
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while true {
            let data: Data
            do {
                data = try handle.read(upToCount: 1 << 20) ?? Data()
            } catch {
                throw ArkTraceError(
                    code: .traceDatabaseInvalid,
                    stage: .validating,
                    message: "Cannot hash private staging database"
                )
            }
            guard !data.isEmpty else { break }
            hasher.update(data: data)
            let (next, overflow) = byteCount.addingReportingOverflow(Int64(data.count))
            guard !overflow else {
                throw ArkTraceError(
                    code: .traceDatabaseInvalid,
                    stage: .validating,
                    message: "Private staging database exceeds supported size"
                )
            }
            byteCount = next
            try Task.checkCancellation()
        }
        return (
            hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            byteCount
        )
    }
}
