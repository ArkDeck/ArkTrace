import ArkTraceCore
import CryptoKit
import Foundation
import SQLite3
import Synchronization

/// Bounded, path-free SQLite runtime facts used by `arktrace doctor`.
package struct TraceSQLiteRuntimeInfo: Equatable, Sendable {
    public let version: String
    public let isThreadSafe: Bool

    public static var current: TraceSQLiteRuntimeInfo {
        unsafe TraceSQLiteRuntimeInfo(
            version: String(cString: sqlite3_libversion()),
            isThreadSafe: sqlite3_threadsafe() != 0
        )
    }
}

/// Bounded, machine-readable evidence for the Phase 3 large-viewport gate.
/// Plans contain only ArkTrace-owned SQL/index identifiers, never input paths.
package struct TraceDatabasePerformanceDiagnostics: Codable, Sendable {
    public let relationshipVMInstructionBudget: Int
    public let relationshipProbeSteps: [String: Int]
    public let queryPlans: [String: [String]]
    public let usesAutomaticIndex: Bool
    public let applicableIndexNames: [String]
    public let persistentIndexNames: [String]
    public let tableRowCounts: [String: Int64]

    public init(
        relationshipVMInstructionBudget: Int,
        relationshipProbeSteps: [String: Int],
        queryPlans: [String: [String]],
        usesAutomaticIndex: Bool,
        applicableIndexNames: [String],
        persistentIndexNames: [String],
        tableRowCounts: [String: Int64]
    ) {
        self.relationshipVMInstructionBudget = relationshipVMInstructionBudget
        self.relationshipProbeSteps = relationshipProbeSteps
        self.queryPlans = queryPlans
        self.usesAutomaticIndex = usesAutomaticIndex
        self.applicableIndexNames = applicableIndexNames
        self.persistentIndexNames = persistentIndexNames
        self.tableRowCounts = tableRowCounts
    }
}

final class TracePerformanceSQLCapture: Sendable {
    private let captured = Mutex<[(String, Int)]>([])

    func record(_ sql: String, bindingCount: Int) {
        captured.withLock { $0.append((sql, bindingCount)) }
    }

    func reset() {
        captured.withLock { $0.removeAll(keepingCapacity: true) }
    }

    func productionStatement() throws -> (String, [TraceDatabase.Binding]) {
        let value = captured.withLock { $0 }
        let candidates = value.filter {
            $0.0.contains("FROM sched_slice AS s")
                || $0.0.contains("FROM thread_state AS s")
                || $0.0.contains("FROM callstack AS s")
        }
        guard candidates.count == 1, let statement = candidates.first else {
            throw ArkTraceError(
                code: .internalError,
                stage: .validating,
                message: "Production SQL diagnostic capture was not exact",
                details: [
                    "reason": "performanceSQLCaptureMismatch",
                    "observed": String(value.count),
                    "candidates": String(candidates.count),
                ]
            )
        }
        return (
            statement.0,
            Array(repeating: TraceDatabase.Binding.int64(0), count: statement.1)
        )
    }
}

/// Validates and indexes a private parser output before the parser may expose
/// it as a Ready database. Every identifier below is an ArkTrace constant;
/// no caller or upstream text is interpolated into DDL.
package enum TraceDatabaseStagingPreparer {
    /// Public cache identity for the currently accepted TraceStreamer schema
    /// contract. Runtime includes this value in every content-addressed key.
    public static let schemaAdapterVersion = TraceSchemaAdapter.version
    public static let indexVersion = 3
    public static let relationshipVMInstructionBudget = 250_000

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
            name: "arktrace_v2_process_ipid_pid_name",
            table: "process",
            columns: ["ipid", "pid", "name"],
            bootstrapForValidation: false,
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
            name: "arktrace_v2_thread_itid_tid_name_ipid",
            table: "thread",
            columns: ["itid", "tid", "name", "ipid"],
            bootstrapForValidation: false,
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
            name: "arktrace_v2_sched_slice_cpu_ts_id_dur_itid",
            table: "sched_slice",
            columns: ["cpu", "ts", "id", "dur", "itid", "ipid"],
            bootstrapForValidation: false,
            requiredForReady: true
        ),
        IndexDefinition(
            name: "arktrace_v2_sched_slice_cpu_ts_cover_optional",
            table: "sched_slice",
            columns: [
                "cpu", "ts", "id", "dur", "itid", "ipid", "end_state", "priority",
            ],
            bootstrapForValidation: false,
            requiredForReady: false
        ),
        IndexDefinition(
            name: "arktrace_v3_sched_slice_cpu_ts_dur",
            table: "sched_slice",
            columns: ["cpu", "ts", "dur"],
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
            name: "arktrace_v2_thread_state_itid_ts_id_dur",
            table: "thread_state",
            columns: ["itid", "ts", "id", "dur", "state"],
            bootstrapForValidation: false,
            requiredForReady: true
        ),
        IndexDefinition(
            name: "arktrace_v2_thread_state_itid_ts_cover_cpu",
            table: "thread_state",
            columns: ["itid", "ts", "id", "dur", "state", "cpu"],
            bootstrapForValidation: false,
            requiredForReady: false
        ),
        IndexDefinition(
            name: "arktrace_v3_thread_state_itid_ts_dur",
            table: "thread_state",
            columns: ["itid", "ts", "dur"],
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
            name: "arktrace_v2_callstack_callid_ts_id_dur",
            table: "callstack",
            columns: ["callid", "ts", "id", "dur", "name"],
            bootstrapForValidation: false,
            requiredForReady: true
        ),
        IndexDefinition(
            name: "arktrace_v2_callstack_callid_ts_cover_optional",
            table: "callstack",
            columns: [
                "callid", "ts", "id", "dur", "name", "cat", "depth", "parent_id",
                "cookie",
            ],
            bootstrapForValidation: false,
            requiredForReady: false
        ),
        IndexDefinition(
            name: "arktrace_v3_callstack_ts_id_dur_callid",
            table: "callstack",
            columns: ["ts", "id", "dur", "callid", "name"],
            bootstrapForValidation: false,
            requiredForReady: true
        ),
        IndexDefinition(
            name: "arktrace_v3_callstack_callid_ts_dur",
            table: "callstack",
            columns: ["callid", "ts", "dur"],
            bootstrapForValidation: false,
            requiredForReady: true
        ),
        IndexDefinition(
            name: "arktrace_v1_measure_filter_id_ts",
            table: "measure",
            columns: ["filter_id", "ts"],
            bootstrapForValidation: true,
            requiredForReady: false
        ),
        IndexDefinition(
            name: "arktrace_v2_cpu_measure_filter_id",
            table: "cpu_measure_filter",
            columns: ["id"],
            bootstrapForValidation: true,
            requiredForReady: false
        ),
        IndexDefinition(
            name: "arktrace_v2_process_measure_filter_id",
            table: "process_measure_filter",
            columns: ["id"],
            bootstrapForValidation: true,
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
            performanceObserver: nil,
            quickCheckProgressHook: nil
        )
    }

    /// Package performance seam used by Runtime's production open pipeline.
    /// The observer is never persisted; every operation is also emitted to the
    /// points-of-interest log when no benchmark observer is installed.
    package static func prepare(
        databaseURL: URL,
        progress: TraceProgressHandler? = nil,
        performanceObserver: TracePerformanceObserver?
    ) throws -> TraceDatabasePreparationResult {
        try prepare(
            databaseURL: databaseURL,
            progress: progress,
            performanceObserver: performanceObserver,
            quickCheckProgressHook: nil
        )
    }

    /// Internal synchronization seam for deterministic cancellation tests.
    static func prepare(
        databaseURL: URL,
        progress: TraceProgressHandler? = nil,
        performanceObserver: TracePerformanceObserver? = nil,
        quickCheckProgressHook: (@Sendable () -> Void)?
    ) throws -> TraceDatabasePreparationResult {
        progress?(.validating)
        try Task.checkCancellation()
        let upstreamDatabase = try measured(
            "database.hash", observer: performanceObserver
        ) {
            try sha256AndSize(at: databaseURL)
        }
        try Task.checkCancellation()
        let db = try measured("database.open", observer: performanceObserver) {
            try TraceDatabase(
                url: databaseURL,
                readOnly: false,
                createIfMissing: false
            )
        }
        let initialQuickCheck = try measured(
            "quickCheck.beforeIndexes", observer: performanceObserver
        ) {
            try db.quickCheckIsOK(progressHook: quickCheckProgressHook)
        }
        guard initialQuickCheck else {
            throw ArkTraceError(
                code: .traceDatabaseInvalid,
                stage: .validating,
                message: "SQLite quick_check failed"
            )
        }
        try Task.checkCancellation()

        let available = try measured(
            "schema.availableColumns", observer: performanceObserver
        ) {
            try availableColumns(in: db)
        }
        // These two target indexes bound the relationship probes on upstream
        // exports that contain no indexes. They are validation infrastructure;
        // the full migration stage begins only after semantic validation.
        try recreateIndexes(
            indexes.filter(\.bootstrapForValidation),
            availableColumns: available,
            in: db,
            phase: "bootstrap",
            performanceObserver: performanceObserver
        )
        try Task.checkCancellation()

        let validation = try measured(
            "schema.semanticValidation", observer: performanceObserver
        ) {
            try TraceSchemaAdapter.validate(db)
        }
        try Task.checkCancellation()
        progress?(.indexing)
        try measured("indexes.configure", observer: performanceObserver) {
            try db.configureForPrivateIndexBuild()
        }
        // Bootstrap indexes were created from ArkTrace-owned definitions in
        // the transaction above. Rebuilding the same bytes here only repeats
        // an indexed table scan; keep them and build the remaining Ready
        // closure once.
        do {
            try recreateIndexes(
                indexes.filter { !$0.bootstrapForValidation },
                availableColumns: available,
                in: db,
                phase: "ready",
                performanceObserver: performanceObserver,
                report: { created, total in
                    progress?(
                        TraceLoadingProgress(
                            stage: .indexing,
                            completed: Int64(created),
                            total: Int64(total)
                        )
                    )
                }
            )
            try measured("indexes.restore", observer: performanceObserver) {
                try db.restoreAfterPrivateIndexBuild()
            }
        } catch {
            try? db.restoreAfterPrivateIndexBuild()
            throw error
        }
        try Task.checkCancellation()
        let finalQuickCheck = try measured(
            "quickCheck.afterIndexes", observer: performanceObserver
        ) {
            try db.quickCheckIsOK(
                stage: .indexing,
                progressHook: quickCheckProgressHook
            )
        }
        guard finalQuickCheck else {
            throw ArkTraceError(
                code: .traceDatabaseInvalid,
                stage: .indexing,
                message: "SQLite quick_check failed after index migration"
            )
        }
        try measured("database.flush", observer: performanceObserver) {
            try db.flush()
        }
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

    /// Exact index closure applicable to a database's actual optional-column
    /// set. Release evidence uses this rather than a prefix or subset check.
    public static func applicableIndexNames(databaseURL: URL) throws -> [String] {
        let db = try TraceDatabase(
            url: databaseURL, readOnly: true, createIfMissing: false
        )
        let available = try availableColumns(in: db)
        return indexes.filter { definition in
            guard let tableColumns = available[definition.table] else { return false }
            return Set(definition.columns).isSubset(of: tableColumns)
        }.map(\.name).sorted()
    }

    /// Replays the bounded relationship probes and representative viewport
    /// plans against an already prepared database. This diagnostic does not
    /// mutate the DB and is consumed only by release gates.
    public static func performanceDiagnostics(
        databaseURL: URL
    ) async throws -> TraceDatabasePerformanceDiagnostics {
        let db = try TraceDatabase(url: databaseURL, readOnly: true, createIfMissing: false)
        let relationships = [
            (
                name: "thread.ipid->process.ipid",
                sourceTable: "thread", sourceColumn: "ipid",
                targetTable: "process", targetColumn: "ipid"
            ),
            (
                name: "sched_slice.itid->thread.itid",
                sourceTable: "sched_slice", sourceColumn: "itid",
                targetTable: "thread", targetColumn: "itid"
            ),
            (
                name: "sched_slice.ipid->process.ipid",
                sourceTable: "sched_slice", sourceColumn: "ipid",
                targetTable: "process", targetColumn: "ipid"
            ),
            (
                name: "thread_state.itid->thread.itid",
                sourceTable: "thread_state", sourceColumn: "itid",
                targetTable: "thread", targetColumn: "itid"
            ),
        ]
        var relationshipSteps: [String: Int] = [:]
        var plans: [String: [String]] = [:]
        for relationship in relationships {
            let sql = """
                SELECT 1
                FROM (
                    SELECT \(relationship.sourceColumn) AS identity
                    FROM \(relationship.sourceTable)
                    LIMIT 1024 OFFSET 0
                ) AS sampled
                LEFT JOIN \(relationship.targetTable) AS target
                    ON target.\(relationship.targetColumn) = sampled.identity
                WHERE typeof(sampled.identity) = 'integer'
                    AND sampled.identity <> 0
                    AND target.\(relationship.targetColumn) IS NULL
                LIMIT 1
                """
            var steps = 0
            _ = try db.query(
                sql,
                vmStepBudget: relationshipVMInstructionBudget,
                vmStepObserver: { steps = $0 },
                stage: .validating
            ) { _ in true }
            relationshipSteps[relationship.name] = steps
            plans[relationship.name] = try explain(sql, bindings: [], in: db)
        }

        let diagnosticParser = TraceParserIdentity(
            name: "performance-diagnostic", reportedVersion: "1",
            binarySHA256: String(repeating: "0", count: 64),
            upstreamRepository: "https://invalid.example/diagnostic",
            upstreamRevision: String(repeating: "0", count: 40),
            architecture: "diagnostic", adapterVersion: "diagnostic",
            buildRecipeVersion: String(repeating: "0", count: 64)
        )
        let capture = TracePerformanceSQLCapture()
        let repository = try SQLiteTraceRepository(
            databaseURL: databaseURL,
            parser: diagnosticParser,
            source: TraceSourceDescriptor(
                traceSHA256: String(repeating: "0", count: 64),
                sourceByteCount: 0
            ),
            diagnosticQueryObserver: { sql, count in
                capture.record(sql, bindingCount: count)
            }
        )
        let metadata = try await repository.metadata()
        guard metadata.durationNs > 0 else {
            throw ArkTraceError(
                code: .traceDatabaseInvalid,
                stage: .validating,
                message: "Performance diagnostic requires a non-empty trace"
            )
        }
        let range = try TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        func capturePlan(_ name: String, _ query: TracePerformanceQuery) async throws {
            capture.reset()
            try await repository.performPerformanceQuery(query)
            let statement = try capture.productionStatement()
            plans[name] = try explain(statement.0, bindings: statement.1, in: db)
        }

        try await capturePlan("viewport.cpu.detail", .cpuDetail(range, deadline))
        try await capturePlan(
            "viewport.threadState.detail", .threadStateDetail(range, deadline)
        )
        try await capturePlan(
            "viewport.namedSlice.detail", .namedSliceDetail(range, deadline)
        )
        try await capturePlan("viewport.cpu.density", .cpuDensity(range, deadline))
        try await capturePlan(
            "viewport.threadState.density", .threadStateDensity(range, deadline)
        )
        try await capturePlan(
            "viewport.namedSlice.density", .namedSliceDensity(range, deadline)
        )

        let expectedNames = try applicableIndexNames(databaseURL: databaseURL)
        let placeholders = Array(repeating: "?", count: expectedNames.count)
            .joined(separator: ",")
        let persistentNames = try db.query(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name IN (\(placeholders)) LIMIT \(expectedNames.count)",
            bindings: expectedNames.map(TraceDatabase.Binding.text),
            stage: .validating
        ) { $0.text(0) }.compactMap { $0 }.sorted()
        let flattenedPlans = plans.values.flatMap { $0 }
        var tableRowCounts: [String: Int64] = [:]
        for table in ["process", "thread", "sched_slice", "thread_state", "callstack"] {
            let rows = try db.query(
                "SELECT COUNT(*) FROM \(table)", stage: .validating
            ) { $0.int64(0) }
            guard let count = rows.first ?? nil else {
                throw ArkTraceError(
                    code: .traceDatabaseInvalid,
                    stage: .validating,
                    message: "Performance row-count evidence is unavailable"
                )
            }
            tableRowCounts[table] = count
        }
        return TraceDatabasePerformanceDiagnostics(
            relationshipVMInstructionBudget: relationshipVMInstructionBudget,
            relationshipProbeSteps: relationshipSteps,
            queryPlans: plans,
            usesAutomaticIndex: flattenedPlans.contains {
                $0.localizedCaseInsensitiveContains("AUTOMATIC")
            },
            applicableIndexNames: expectedNames,
            persistentIndexNames: persistentNames,
            tableRowCounts: tableRowCounts
        )
    }

    private static func explain(
        _ sql: String,
        bindings: [TraceDatabase.Binding],
        in db: TraceDatabase
    ) throws -> [String] {
        try db.query(
            "EXPLAIN QUERY PLAN \(sql)",
            bindings: bindings,
            stage: .validating
        ) { $0.text(3) }.compactMap { $0 }.prefix(64).map { String($0.prefix(512)) }
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
        in db: TraceDatabase,
        phase: String,
        performanceObserver: TracePerformanceObserver?,
        report: ((_ created: Int, _ total: Int) -> Void)? = nil
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

        try measured(
            "indexes.\(phase).total",
            workUnits: Int64(applicable.count),
            workUnit: "indexes",
            observer: performanceObserver
        ) {
            try db.execute(
                "BEGIN IMMEDIATE",
                stage: .indexing,
                observesTaskCancellation: true
            )
            do {
                for (position, definition) in applicable.enumerated() {
                    try Task.checkCancellation()
                    try measured(
                        "index.\(phase).\(definition.name)",
                        observer: performanceObserver
                    ) {
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
                    // Indexes differ in cost, so this counts indexes rather than
                    // claiming a share of the time. It is the only honest measure
                    // the stage has, and on a cold open of a 265 MB capture that
                    // stage is a third of the wait.
                    report?(position + 1, applicable.count)
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
    }

    private static func measured<T>(
        _ operation: String,
        workUnits: Int64? = nil,
        workUnit: String? = nil,
        observer: TracePerformanceObserver?,
        _ body: () throws -> T
    ) throws -> T {
        let startedAt = ContinuousClock.now
        defer {
            TracePerformanceMetrics.record(
                scope: "databasePreparation",
                operation: operation,
                startedAt: startedAt,
                workUnits: workUnits,
                workUnit: workUnit,
                observer: observer
            )
        }
        return try body()
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
            hasher.finalize().lowercaseHexString(),
            byteCount
        )
    }
}
