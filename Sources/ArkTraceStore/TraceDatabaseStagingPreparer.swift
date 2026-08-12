import ArkTraceCore
import CryptoKit
import Foundation

/// Validates and indexes a private parser output before the parser may expose
/// it as a Ready database. Every identifier below is an ArkTrace constant;
/// no caller or upstream text is interpolated into DDL.
public enum TraceDatabaseStagingPreparer {
    /// Public cache identity for the currently accepted TraceStreamer schema
    /// contract. Runtime includes this value in every content-addressed key.
    public static let schemaAdapterVersion = TraceSchemaAdapter.version
    public static let indexVersion = 1

    private struct IndexDefinition {
        let name: String
        let table: String
        let columns: [String]
        let bootstrapForValidation: Bool
        let requiredForReady: Bool
        let unique: Bool
        let partial: Bool

        init(
            name: String,
            table: String,
            columns: [String],
            bootstrapForValidation: Bool,
            requiredForReady: Bool,
            unique: Bool = false,
            partial: Bool = false
        ) {
            self.name = name
            self.table = table
            self.columns = columns
            self.bootstrapForValidation = bootstrapForValidation
            self.requiredForReady = requiredForReady
            self.unique = unique
            self.partial = partial
        }
    }

    private static let indexes = [
        IndexDefinition(
            name: "arktrace_v1_process_pid",
            table: "process",
            columns: ["pid"],
            bootstrapForValidation: false,
            requiredForReady: true
        ),
        IndexDefinition(
            name: "arktrace_v1_process_ipid",
            table: "process",
            columns: ["ipid"],
            bootstrapForValidation: true,
            requiredForReady: true
        ),
        IndexDefinition(
            name: "arktrace_v1_thread_tid_ipid",
            table: "thread",
            columns: ["tid", "ipid"],
            bootstrapForValidation: false,
            requiredForReady: true
        ),
        IndexDefinition(
            name: "arktrace_v1_thread_itid",
            table: "thread",
            columns: ["itid"],
            bootstrapForValidation: true,
            requiredForReady: true
        ),
        IndexDefinition(
            name: "arktrace_v1_sched_slice_ts_cpu",
            table: "sched_slice",
            columns: ["ts", "cpu"],
            bootstrapForValidation: false,
            requiredForReady: true
        ),
        IndexDefinition(
            name: "arktrace_v1_sched_slice_itid_ts",
            table: "sched_slice",
            columns: ["itid", "ts"],
            bootstrapForValidation: false,
            requiredForReady: true
        ),
        IndexDefinition(
            name: "arktrace_v1_thread_state_ts_cpu",
            table: "thread_state",
            columns: ["ts", "cpu"],
            bootstrapForValidation: false,
            requiredForReady: false
        ),
        IndexDefinition(
            name: "arktrace_v1_thread_state_itid_ts",
            table: "thread_state",
            columns: ["itid", "ts"],
            bootstrapForValidation: false,
            requiredForReady: true
        ),
        IndexDefinition(
            name: "arktrace_v1_callstack_callid_ts",
            table: "callstack",
            columns: ["callid", "ts"],
            bootstrapForValidation: false,
            requiredForReady: true
        ),
        IndexDefinition(
            name: "arktrace_v1_measure_filter_id_ts",
            table: "measure",
            columns: ["filter_id", "ts"],
            bootstrapForValidation: false,
            requiredForReady: false
        ),
    ]

    public static func prepare(
        databaseURL: URL,
        progress: TraceProgressHandler? = nil
    ) throws -> TraceDatabasePreparationResult {
        try prepare(
            databaseURL: databaseURL,
            progress: progress,
            quickCheckProgressHook: nil
        )
    }

    /// Internal synchronization seam for deterministic cancellation tests.
    static func prepare(
        databaseURL: URL,
        progress: TraceProgressHandler? = nil,
        quickCheckProgressHook: (@Sendable () -> Void)?
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
        guard try db.quickCheckIsOK(progressHook: quickCheckProgressHook) else {
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
        guard try db.quickCheckIsOK(
            stage: .indexing,
            progressHook: quickCheckProgressHook
        ) else {
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
        Set(indexes.filter(\.requiredForReady).map(\.name))
    }

    /// Verifies the exact versioned Ready index contract without enumerating
    /// arbitrary sqlite_master rows. Optional definitions become applicable
    /// when their table and every indexed column are present in this schema.
    static func validateReadyIndexes(in db: TraceDatabase) throws {
        let available = try availableColumns(in: db)
        let applicable = indexes.filter { definition in
            guard let columns = available[definition.table] else { return false }
            return definition.columns.allSatisfy(columns.contains)
        }
        let applicableNames = Set(applicable.map(\.name))
        guard indexes.allSatisfy({ !$0.requiredForReady || applicableNames.contains($0.name) })
        else {
            throw invalidReadyIndexes()
        }

        for definition in applicable {
            try Task.checkCancellation()
            let rows = try db.query(
                """
                SELECT name, \"unique\", partial
                FROM pragma_index_list(?)
                WHERE name = ?
                LIMIT 2
                """,
                bindings: [.text(definition.table), .text(definition.name)],
                vmStepBudget: 25_000,
                stage: .openingDatabase,
                observesTaskCancellation: true
            ) { row in
                (row.text(0), row.int64(1), row.int64(2))
            }
            guard rows.count == 1,
                rows[0].0 == definition.name,
                rows[0].1 == (definition.unique ? 1 : 0),
                rows[0].2 == (definition.partial ? 1 : 0)
            else {
                throw invalidReadyIndexes()
            }

            let columnRows = try db.query(
                """
                SELECT seqno, cid, name, desc, coll, key
                FROM pragma_index_xinfo(?)
                WHERE key = 1
                ORDER BY seqno
                LIMIT ?
                """,
                bindings: [
                    .text(definition.name),
                    .int64(Int64(definition.columns.count + 1)),
                ],
                vmStepBudget: 25_000,
                stage: .openingDatabase,
                observesTaskCancellation: true
            ) { row in
                (
                    row.int64(0), row.int64(1), row.text(2),
                    row.int64(3), row.text(4), row.int64(5)
                )
            }
            guard columnRows.count == definition.columns.count else {
                throw invalidReadyIndexes()
            }
            for (offset, expectedColumn) in definition.columns.enumerated() {
                let actual = columnRows[offset]
                guard actual.0 == Int64(offset),
                    actual.1 != nil,
                    actual.2 == expectedColumn,
                    actual.3 == 0,
                    actual.4?.uppercased() == "BINARY",
                    actual.5 == 1
                else {
                    throw invalidReadyIndexes()
                }
            }
        }
    }

    private static func invalidReadyIndexes() -> ArkTraceError {
        ArkTraceError(
            code: .traceDatabaseInvalid,
            stage: .openingDatabase,
            message: "Ready database index contract is invalid"
        )
    }

    private static func availableColumns(
        in db: TraceDatabase
    ) throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for table in Set(indexes.map(\.table)) {
            let columns = Set(try db.columns(of: table).map(\.name))
            if !columns.isEmpty { result[table] = columns }
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
        let applicableNames = Set(applicable.map(\.name))
        let missingRequired = definitions.filter {
            $0.requiredForReady && !applicableNames.contains($0.name)
        }
        guard missingRequired.isEmpty else {
            throw ArkTraceError(
                code: .traceSchemaUnsupported,
                stage: .validating,
                message: "Database schema cannot satisfy the Ready index contract",
                details: [
                    "missingIndexInputs": missingRequired.map(\.name).sorted().joined(separator: ",")
                ]
            )
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
