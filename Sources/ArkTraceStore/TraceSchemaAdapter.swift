import ArkTraceCore
import CryptoKit
import Foundation

/// Establishes what an exported TraceStreamer database actually supports
/// (DESIGN §9.1). Required tables missing → `TRACE_SCHEMA_UNSUPPORTED`;
/// additive upstream columns and unrelated new tables are compatible
/// (AT-DB-004).
enum TraceSchemaAdapter {
    static let version = "2"
    private static let semanticProbeLimit = 1_024
    private static let relationshipVMInstructionBudget =
        TraceDatabaseStagingPreparer.relationshipVMInstructionBudget

    struct Validation: Sendable {
        let capabilities: TraceCapabilities
        let schemaFingerprint: String
        /// Absolute trace start/end as stored by TraceStreamer; the Store
        /// keeps absolute times internal and converts at the boundary
        /// (DESIGN §7.1).
        let traceStartTs: Int64
        let traceEndTs: Int64
        let durationNs: Int64
        let dataQuality: TraceDataQuality
        let eventSourceCountsAvailable: Bool
    }

    private enum DeclaredAffinity: String {
        case integer = "INTEGER"
        case text = "TEXT"
        case blob = "BLOB"
        case real = "REAL"
        case numeric = "NUMERIC"

        /// Implements SQLite's declared-type affinity rules. Validation uses
        /// affinity rather than exact spelling so canonical declarations such
        /// as INT and UNSIGNED BIG INT remain compatible.
        init(declaredType: String) {
            let type = declaredType.uppercased()
            if type.contains("INT") {
                self = .integer
            } else if type.contains("CHAR") || type.contains("CLOB")
                || type.contains("TEXT")
            {
                self = .text
            } else if type.isEmpty || type.contains("BLOB") {
                self = .blob
            } else if type.contains("REAL") || type.contains("FLOA")
                || type.contains("DOUB")
            {
                self = .real
            } else {
                self = .numeric
            }
        }
    }

    private struct RequiredColumn {
        let name: String
        let affinity: DeclaredAffinity

        static func integer(_ name: String) -> RequiredColumn {
            RequiredColumn(name: name, affinity: .integer)
        }

        static func text(_ name: String) -> RequiredColumn {
            RequiredColumn(name: name, affinity: .text)
        }
    }

    private struct RequiredTable {
        let name: String
        let columns: [RequiredColumn]
    }

    private static let requiredTables: [RequiredTable] = [
        RequiredTable(
            name: "trace_range",
            columns: [.integer("start_ts"), .integer("end_ts")]
        ),
        RequiredTable(
            name: "process",
            columns: [.integer("ipid"), .integer("pid"), .text("name"), .integer("start_ts")]
        ),
        RequiredTable(
            name: "thread",
            columns: [
                .integer("itid"), .integer("tid"), .text("name"), .integer("start_ts"),
                .integer("ipid"),
            ]
        ),
        RequiredTable(
            name: "sched_slice",
            columns: [
                .integer("id"), .integer("ts"), .integer("dur"), .integer("cpu"),
                .integer("itid"), .integer("ipid"),
            ]
        ),
        RequiredTable(
            name: "thread_state",
            columns: [
                .integer("id"), .integer("ts"), .integer("dur"), .integer("itid"),
                .text("state"),
            ]
        ),
        RequiredTable(
            name: "callstack",
            columns: [
                .integer("id"), .integer("ts"), .integer("dur"), .integer("callid"),
                .text("name"),
            ]
        ),
    ]

    private static let measureColumns: [RequiredColumn] = [
        .integer("ts"), .integer("value"), .integer("filter_id"),
    ]
    private static let measureFilterColumns: [RequiredColumn] = [
        .integer("id"), .text("name"),
    ]

    static func validate(_ db: TraceDatabase) throws -> Validation {
        let tables = try db.tableNames()
        var columnsByTable: [String: [TraceDatabase.ColumnInfo]] = [:]
        // Up to `maximumSchemaTableCount` PRAGMA round trips. Bounded, but a
        // hostile schema can still make it long enough that a cancel request
        // must not have to wait for the whole introspection to finish.
        for table in tables {
            try Task.checkCancellation()
            columnsByTable[table] = try db.columns(
                of: table,
                observesTaskCancellation: true
            )
        }

        var missing: [String] = []
        var incompatible: [String] = []
        for required in requiredTables {
            guard let columns = columnsByTable[required.name] else {
                missing.append(required.name)
                continue
            }
            let columnsByName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })
            for column in required.columns {
                guard let actual = columnsByName[column.name] else {
                    missing.append("\(required.name).\(column.name)")
                    continue
                }
                let actualAffinity = DeclaredAffinity(declaredType: actual.type)
                if actualAffinity != column.affinity {
                    incompatible.append(
                        "\(required.name).\(column.name)"
                            + "(expected=\(column.affinity.rawValue),"
                            + "declaredAffinity=\(actualAffinity.rawValue))"
                    )
                }
            }
        }
        guard missing.isEmpty, incompatible.isEmpty else {
            var details: [String: String] = [:]
            if !missing.isEmpty {
                details["missing"] = missing.sorted().joined(separator: ",")
            }
            if !incompatible.isEmpty {
                details["incompatible"] = incompatible.sorted().joined(separator: ",")
            }
            throw ArkTraceError(
                code: .traceSchemaUnsupported,
                stage: .validating,
                message: "Database schema has missing or incompatible required columns",
                details: details
            )
        }

        let schedulingAvailable = try hasCompatibleRows(
            db,
            table: "sched_slice",
            columns: [.integer("ts"), .integer("dur"), .integer("cpu"), .integer("itid")],
            in: columnsByTable
        )
        let threadStatesAvailable = try hasCompatibleRows(
            db,
            table: "thread_state",
            columns: [
                .integer("ts"), .integer("dur"), .integer("itid"), .text("state"),
            ],
            in: columnsByTable
        )
        let namedSlicesAvailable = try hasCompatibleRows(
            db,
            table: "callstack",
            columns: [
                .integer("ts"), .integer("dur"), .integer("callid"), .text("name"),
            ],
            in: columnsByTable
        )
        let cpuCountersAvailable = try hasCompatibleJoinRows(
            db,
            filterTable: "cpu_measure_filter",
            scopeColumn: .integer("cpu"),
            in: columnsByTable
        )
        let processCountersAvailable = try hasCompatibleJoinRows(
            db,
            filterTable: "process_measure_filter",
            scopeColumn: .integer("ipid"),
            in: columnsByTable
        )
        if cpuCountersAvailable {
            try validateUniqueCounterFilterIdentity(
                db, filterTable: "cpu_measure_filter"
            )
        }
        if processCountersAvailable {
            try validateUniqueCounterFilterIdentity(
                db, filterTable: "process_measure_filter"
            )
        }
        if cpuCountersAvailable, processCountersAvailable {
            try validateDisjointCounterFilterIdentities(db)
        }
        let capabilities = TraceCapabilities(
            cpuScheduling: schedulingAvailable,
            threadStates: threadStatesAvailable,
            namedSlices: namedSlicesAvailable,
            cpuCounters: cpuCountersAvailable,
            processCounters: processCountersAvailable
        )
        let eventSourceCountsAvailable = hasCompatibleTable(
            "stat",
            columns: [
                .text("event_name"), .text("stat_type"), .integer("count"),
                .text("source"),
            ],
            in: columnsByTable
        )

        let range = try traceRange(db)
        try validateRequiredIdentities(db)
        try validateRequiredRelationships(db)
        let dataQuality = try qualityEvidence(
            db,
            range: range,
            columnsByTable: columnsByTable
        )

        return Validation(
            capabilities: capabilities,
            schemaFingerprint: fingerprint(of: columnsByTable),
            traceStartTs: range.start,
            traceEndTs: range.end,
            durationNs: range.duration,
            dataQuality: dataQuality,
            eventSourceCountsAvailable: eventSourceCountsAvailable
        )
    }

    private static func hasCompatibleTable(
        _ name: String,
        columns required: [RequiredColumn],
        in columnsByTable: [String: [TraceDatabase.ColumnInfo]]
    ) -> Bool {
        guard let columns = columnsByTable[name] else { return false }
        let columnsByName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })
        return required.allSatisfy { requiredColumn in
            guard let actual = columnsByName[requiredColumn.name] else { return false }
            return DeclaredAffinity(declaredType: actual.type) == requiredColumn.affinity
        }
    }

    private static func hasRows(_ db: TraceDatabase, table: String) throws -> Bool {
        guard TraceDatabase.isSafeIdentifier(table) else { return false }
        return try db.query(
            "SELECT 1 FROM \(table) LIMIT 1",
            stage: .validating,
                observesTaskCancellation: true
        ) { _ in true }.isEmpty == false
    }

    private static func hasCompatibleRows(
        _ db: TraceDatabase,
        table: String,
        columns: [RequiredColumn],
        in columnsByTable: [String: [TraceDatabase.ColumnInfo]]
    ) throws -> Bool {
        guard hasCompatibleTable(table, columns: columns, in: columnsByTable) else {
            return false
        }
        return try hasRows(db, table: table)
    }

    /// Counter capability requires an actual relationship, not merely two
    /// non-empty tables. The VM budget bounds adversarial work without making
    /// capability depend on whichever rows SQLite happens to return in the
    /// first 1,024 physical records.
    private static func hasCompatibleJoinRows(
        _ db: TraceDatabase,
        filterTable: String,
        scopeColumn: RequiredColumn,
        in columnsByTable: [String: [TraceDatabase.ColumnInfo]]
    ) throws -> Bool {
        guard TraceDatabase.isSafeIdentifier(filterTable),
            hasCompatibleTable("measure", columns: measureColumns, in: columnsByTable),
            hasCompatibleTable(
                filterTable,
                columns: measureFilterColumns + [scopeColumn],
                in: columnsByTable
            )
        else {
            return false
        }
        do {
            return try db.query(
                """
                SELECT 1
                FROM \(filterTable) AS sampled_filter
                CROSS JOIN measure AS sampled_measure
                    ON sampled_measure.filter_id = sampled_filter.id
                WHERE typeof(sampled_measure.filter_id) = 'integer'
                    AND typeof(sampled_filter.id) = 'integer'
                LIMIT 1
                """,
                vmStepBudget: relationshipVMInstructionBudget,
                stage: .validating,
                observesTaskCancellation: true
            ) { _ in true }.isEmpty == false
        } catch is TraceDatabase.VMInstructionBudgetExceeded {
            throw ArkTraceError(
                code: .traceSchemaUnsupported,
                stage: .validating,
                message: "Counter capability relationship exceeds validation budget",
                details: [
                    "reason": "vmStepBudgetExceeded",
                    "relationship": "measure.filter_id->\(filterTable).id",
                ]
            )
        }
    }

    /// A measure identity must resolve to exactly one filter row. Duplicate
    /// IDs would duplicate the same EventKey and make name/unit selection
    /// depend on SQLite's plan order, so ambiguity is a schema failure.
    private static func validateUniqueCounterFilterIdentity(
        _ db: TraceDatabase,
        filterTable: String
    ) throws {
        guard TraceDatabase.isSafeIdentifier(filterTable) else { return }
        do {
            let duplicate = try db.query(
                """
                SELECT 1 FROM (
                    SELECT id FROM \(filterTable)
                    WHERE typeof(id) = 'integer'
                    GROUP BY id HAVING COUNT(*) > 1
                    LIMIT 1
                )
                """,
                vmStepBudget: relationshipVMInstructionBudget,
                stage: .validating,
                observesTaskCancellation: true
            ) { _ in true }
            guard duplicate.isEmpty else {
                throw ArkTraceError(
                    code: .traceSchemaUnsupported,
                    stage: .validating,
                    message: "Counter filter identity is ambiguous",
                    details: [
                        "reason": "duplicateFilterIdentity",
                        "table": filterTable,
                    ]
                )
            }
        } catch is TraceDatabase.VMInstructionBudgetExceeded {
            throw ArkTraceError(
                code: .traceSchemaUnsupported,
                stage: .validating,
                message: "Counter filter identity validation exceeds budget",
                details: [
                    "reason": "vmStepBudgetExceeded",
                    "relationship": "\(filterTable).id->unique",
                ]
            )
        }
    }

    private static func validateDisjointCounterFilterIdentities(
        _ db: TraceDatabase
    ) throws {
        do {
            let ambiguous = try db.query(
                """
                SELECT 1
                FROM cpu_measure_filter AS cpu
                INNER JOIN process_measure_filter AS process
                    ON cpu.id = process.id
                WHERE typeof(cpu.id) = 'integer'
                    AND typeof(process.id) = 'integer'
                LIMIT 1
                """,
                vmStepBudget: relationshipVMInstructionBudget,
                stage: .validating,
                observesTaskCancellation: true
            ) { _ in true }
            guard ambiguous.isEmpty else {
                throw ArkTraceError(
                    code: .traceSchemaUnsupported,
                    stage: .validating,
                    message: "Counter filter identity is ambiguous across scopes",
                    details: ["reason": "duplicateFilterIdentity"]
                )
            }
        } catch is TraceDatabase.VMInstructionBudgetExceeded {
            throw ArkTraceError(
                code: .traceSchemaUnsupported,
                stage: .validating,
                message: "Counter filter scope validation exceeds budget",
                details: [
                    "reason": "vmStepBudgetExceeded",
                    "relationship": "counterFilter.id->scope",
                ]
            )
        }
    }

    private static func traceRange(
        _ db: TraceDatabase
    ) throws -> (start: Int64, end: Int64, duration: Int64) {
        let rows = try db.query(
            "SELECT start_ts, end_ts FROM trace_range LIMIT 2",
            stage: .validating,
                observesTaskCancellation: true
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
        let (duration, overflow) = end.subtractingReportingOverflow(start)
        guard !overflow, duration > 0 else {
            throw ArkTraceError(
                code: .traceDatabaseInvalid,
                stage: .validating,
                message: "trace_range duration exceeds supported Int64 nanoseconds"
            )
        }
        return (start, end, duration)
    }

    /// Required identities must use SQLite's INTEGER storage class. SQLite's
    /// numeric accessors coerce NULL/TEXT/REAL (for example, `"abc"` to 0),
    /// which would merge unrelated rows into a forged identity. Validation is
    /// a bounded opening probe; every query repeats the strict storage-class
    /// check before constructing a domain key.
    private static func validateRequiredIdentities(_ db: TraceDatabase) throws {
        let probes = [
            (
                table: "process",
                predicate: "typeof(ipid) <> 'integer' OR typeof(pid) <> 'integer'"
            ),
            (
                table: "thread",
                predicate:
                    "typeof(itid) <> 'integer' OR typeof(tid) <> 'integer' "
                    + "OR (ipid IS NOT NULL AND typeof(ipid) <> 'integer')"
            ),
            (
                table: "sched_slice",
                predicate:
                    "typeof(id) <> 'integer' "
                    + "OR (itid IS NOT NULL AND typeof(itid) <> 'integer') "
                    + "OR (ipid IS NOT NULL AND typeof(ipid) <> 'integer')"
            ),
            (
                table: "thread_state",
                predicate:
                    "typeof(id) <> 'integer' "
                    + "OR (itid IS NOT NULL AND typeof(itid) <> 'integer')"
            ),
            (
                table: "callstack",
                predicate: "typeof(id) <> 'integer' OR typeof(callid) <> 'integer'"
            ),
        ]
        for probe in probes {
            let invalid = try db.query(
                """
                SELECT 1 FROM (
                    SELECT * FROM \(probe.table)
                    LIMIT \(semanticProbeLimit) OFFSET 0
                ) AS sampled
                WHERE \(probe.predicate)
                LIMIT 1
                """,
                stage: .validating,
                observesTaskCancellation: true
            ) { _ in true }
            guard invalid.isEmpty else {
                throw ArkTraceError(
                    code: .traceDatabaseInvalid,
                    stage: .validating,
                    message: "Required trace identity is not an SQLite INTEGER",
                    details: ["table": probe.table]
                )
            }
        }
    }

    /// Bounded probes catch broken joins early without turning every open into
    /// an unbounded referential scan. Zero is an upstream sentinel and NULL is
    /// an allowed absent reference; nonzero sampled references must resolve.
    private static func validateRequiredRelationships(_ db: TraceDatabase) throws {
        let probes = [
            (sourceTable: "thread", sourceColumn: "ipid", targetTable: "process", targetColumn: "ipid"),
            (sourceTable: "sched_slice", sourceColumn: "itid", targetTable: "thread", targetColumn: "itid"),
            (sourceTable: "sched_slice", sourceColumn: "ipid", targetTable: "process", targetColumn: "ipid"),
            (sourceTable: "thread_state", sourceColumn: "itid", targetTable: "thread", targetColumn: "itid"),
        ]
        for probe in probes {
            let relationship =
                "\(probe.sourceTable).\(probe.sourceColumn)"
                + "->\(probe.targetTable).\(probe.targetColumn)"
            let broken: [Bool]
            do {
                broken = try db.query(
                    """
                    SELECT 1
                    FROM (
                        SELECT \(probe.sourceColumn) AS identity
                        FROM \(probe.sourceTable)
                        LIMIT \(semanticProbeLimit) OFFSET 0
                    ) AS sampled
                    LEFT JOIN \(probe.targetTable) AS target
                        ON target.\(probe.targetColumn) = sampled.identity
                    WHERE typeof(sampled.identity) = 'integer'
                        AND sampled.identity <> 0
                        AND target.\(probe.targetColumn) IS NULL
                    LIMIT 1
                    """,
                    vmStepBudget: relationshipVMInstructionBudget,
                    stage: .validating,
                observesTaskCancellation: true
                ) { _ in true }
            } catch is TraceDatabase.VMInstructionBudgetExceeded {
                throw ArkTraceError(
                    code: .traceSchemaUnsupported,
                    stage: .validating,
                    message: "Required identity relationship exceeds validation budget",
                    details: [
                        "reason": "vmStepBudgetExceeded",
                        "relationship": relationship,
                    ]
                )
            }
            guard broken.isEmpty else {
                throw ArkTraceError(
                    code: .traceSchemaUnsupported,
                    stage: .validating,
                    message: "Required trace identity relationship is broken",
                    details: ["relationship": relationship]
                )
            }
        }
    }

    private struct TimeColumn {
        let table: String
        let column: String
    }

    private struct StorageColumn {
        let table: String
        let column: String
        let expectedType: String
        let allowsNull: Bool
    }

    /// Samples at most `semanticProbeLimit` rows per time column. The warnings
    /// make safe clamping/dropping observable while keeping open-time work
    /// independent of total trace size (DESIGN §7.1, AT-QUERY-008).
    private static func qualityEvidence(
        _ db: TraceDatabase,
        range: (start: Int64, end: Int64, duration: Int64),
        columnsByTable: [String: [TraceDatabase.ColumnInfo]]
    ) throws -> TraceDataQuality {
        let candidates = [
            TimeColumn(table: "process", column: "start_ts"),
            TimeColumn(table: "process", column: "end_ts"),
            TimeColumn(table: "thread", column: "start_ts"),
            TimeColumn(table: "thread", column: "end_ts"),
            TimeColumn(table: "sched_slice", column: "ts"),
            TimeColumn(table: "sched_slice", column: "dur"),
            TimeColumn(table: "thread_state", column: "ts"),
            TimeColumn(table: "thread_state", column: "dur"),
            TimeColumn(table: "callstack", column: "ts"),
            TimeColumn(table: "callstack", column: "dur"),
            TimeColumn(table: "measure", column: "ts"),
        ]
        var issues: [TraceDataQualityIssue] = []
        func record(
            _ category: TraceDataQualityIssue.Category,
            scope: String,
            count: Int64?,
            message: String
        ) {
            issues.append(
                TraceDataQualityIssue(
                    category: category,
                    scope: scope,
                    count: count,
                    message: message
                )
            )
        }
        for candidate in candidates {
            guard columnsByTable[candidate.table]?.contains(where: {
                $0.name == candidate.column
            }) == true else {
                continue
            }
            let result = try timeQualityProbe(db, column: candidate, range: range)
            let qualifiedName = "\(candidate.table).\(candidate.column)"
            if result.nonInteger > 0 {
                record(
                    .droppedValue,
                    scope: qualifiedName,
                    count: result.nonInteger,
                    message: "\(qualifiedName): \(result.nonInteger) sampled non-INTEGER value(s) ignored"
                )
            }
            // Negative duration is the valid open-ended sentinel from
            // AT-TIME-005. It is preserved by the shared event predicate and
            // must not be mislabeled as ignored/corrupt data.
            if candidate.column != "dur", result.beforeStart > 0 {
                record(
                    .clampedValue,
                    scope: qualifiedName,
                    count: result.beforeStart,
                    message: "\(qualifiedName): \(result.beforeStart) sampled value(s) precede trace start and are clamped"
                )
            }
            if candidate.column != "dur", result.afterEnd > 0 {
                record(
                    .clampedValue,
                    scope: qualifiedName,
                    count: result.afterEnd,
                    message: "\(qualifiedName): \(result.afterEnd) sampled value(s) exceed trace end and are clamped"
                )
            }
            if result.truncated {
                record(
                    .probeTruncated,
                    scope: qualifiedName,
                    count: nil,
                    message: "\(qualifiedName): quality probe truncated after \(semanticProbeLimit) rows; "
                        + "remaining values were not inspected"
                )
            }
        }

        let storageCandidates = [
            StorageColumn(
                table: "sched_slice", column: "cpu",
                expectedType: "integer", allowsNull: false
            ),
            StorageColumn(
                table: "thread_state", column: "cpu",
                expectedType: "integer", allowsNull: true
            ),
            StorageColumn(
                table: "callstack", column: "depth",
                expectedType: "integer", allowsNull: true
            ),
            StorageColumn(
                table: "callstack", column: "parent_id",
                expectedType: "integer", allowsNull: true
            ),
            StorageColumn(
                table: "callstack", column: "cookie",
                expectedType: "integer", allowsNull: true
            ),
            StorageColumn(
                table: "measure", column: "filter_id",
                expectedType: "integer", allowsNull: false
            ),
            StorageColumn(
                table: "measure", column: "value",
                expectedType: "integer", allowsNull: false
            ),
            StorageColumn(
                table: "measure", column: "dur",
                expectedType: "integer", allowsNull: true
            ),
            StorageColumn(
                table: "cpu_measure_filter", column: "id",
                expectedType: "integer", allowsNull: false
            ),
            StorageColumn(
                table: "cpu_measure_filter", column: "name",
                expectedType: "text", allowsNull: false
            ),
            StorageColumn(
                table: "cpu_measure_filter", column: "cpu",
                expectedType: "integer", allowsNull: false
            ),
            StorageColumn(
                table: "cpu_measure_filter", column: "unit",
                expectedType: "text", allowsNull: true
            ),
            StorageColumn(
                table: "process_measure_filter", column: "id",
                expectedType: "integer", allowsNull: false
            ),
            StorageColumn(
                table: "process_measure_filter", column: "name",
                expectedType: "text", allowsNull: false
            ),
            StorageColumn(
                table: "process_measure_filter", column: "ipid",
                expectedType: "integer", allowsNull: false
            ),
            StorageColumn(
                table: "process_measure_filter", column: "unit",
                expectedType: "text", allowsNull: true
            ),
            StorageColumn(
                table: "stat", column: "count",
                expectedType: "integer", allowsNull: false
            ),
            StorageColumn(
                table: "stat", column: "source",
                expectedType: "text", allowsNull: false
            ),
            StorageColumn(
                table: "stat", column: "event_name",
                expectedType: "text", allowsNull: false
            ),
            StorageColumn(
                table: "stat", column: "stat_type",
                expectedType: "text", allowsNull: false
            ),
        ]
        for candidate in storageCandidates {
            guard columnsByTable[candidate.table]?.contains(where: {
                $0.name == candidate.column
            }) == true else { continue }
            let result = try storageQualityProbe(db, column: candidate)
            let qualifiedName = "\(candidate.table).\(candidate.column)"
            if result.incompatible > 0 {
                record(
                    .droppedValue,
                    scope: qualifiedName,
                    count: result.incompatible,
                    message: "\(qualifiedName): \(result.incompatible) sampled incompatible storage value(s) ignored"
                )
            }
            if result.truncated {
                record(
                    .probeTruncated,
                    scope: qualifiedName,
                    count: nil,
                    message: "\(qualifiedName): quality probe truncated after \(semanticProbeLimit) rows; "
                        + "remaining values were not inspected"
                )
            }
        }
        if columnsByTable["stat"]?.contains(where: { $0.name == "stat_type" }) == true,
            columnsByTable["stat"]?.contains(where: { $0.name == "count" }) == true
        {
            let result = try statQualityProbe(db)
            if result.nonReceived > 0 {
                record(
                    .droppedValue,
                    scope: "stat.stat_type",
                    count: result.nonReceived,
                    message: "stat.stat_type: \(result.nonReceived) sampled non-received row(s) excluded from event counts"
                )
            }
            if result.negativeCount > 0 {
                record(
                    .invalidValue,
                    scope: "stat.count",
                    count: result.negativeCount,
                    message: "stat.count: \(result.negativeCount) sampled negative value(s) excluded from event counts"
                )
            }
            if result.invalidSourceLength > 0 {
                record(
                    .invalidValue,
                    scope: "stat.source",
                    count: result.invalidSourceLength,
                    message: "stat.source: \(result.invalidSourceLength) sampled empty or oversized value(s) excluded from event counts"
                )
            }
            if result.invalidEventNameLength > 0 {
                record(
                    .invalidValue,
                    scope: "stat.event_name",
                    count: result.invalidEventNameLength,
                    message: "stat.event_name: \(result.invalidEventNameLength) sampled oversized value(s) excluded from event counts"
                )
            }
            if result.truncated {
                record(
                    .probeTruncated,
                    scope: "stat",
                    count: nil,
                    message: "stat quality probe truncated after \(semanticProbeLimit) rows; remaining values were not inspected"
                )
            }
        }
        return TraceDataQuality(issues: issues)
    }

    private static func storageQualityProbe(
        _ db: TraceDatabase,
        column: StorageColumn
    ) throws -> (incompatible: Int64, truncated: Bool) {
        let allowedNull = column.allowsNull ? " OR typeof(value) = 'null'" : ""
        let rows = try db.query(
            """
            SELECT COUNT(*), COALESCE(SUM(CASE
                WHEN NOT (typeof(value) = ?\(allowedNull)) THEN 1 ELSE 0 END), 0)
            FROM (
                SELECT \(column.column) AS value FROM \(column.table)
                LIMIT \(semanticProbeLimit + 1) OFFSET 0
            ) AS sampled
            """,
            bindings: [.text(column.expectedType)],
            stage: .validating,
                observesTaskCancellation: true
        ) { row in (row.int64(0) ?? 0, row.int64(1) ?? 0) }
        let counts = rows[0]
        return (min(counts.1, Int64(semanticProbeLimit)), counts.0 > semanticProbeLimit)
    }

    private static func statQualityProbe(
        _ db: TraceDatabase
    ) throws -> (
        nonReceived: Int64,
        negativeCount: Int64,
        invalidSourceLength: Int64,
        invalidEventNameLength: Int64,
        truncated: Bool
    ) {
        let rows = try db.query(
            """
            SELECT COUNT(*),
                COALESCE(SUM(CASE WHEN typeof(stat_type) = 'text'
                    AND stat_type <> 'received' THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN typeof(count) = 'integer'
                    AND count < 0 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN typeof(source) = 'text'
                    AND length(CAST(source AS BLOB)) NOT BETWEEN 1 AND 256
                    THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN typeof(event_name) = 'text'
                    AND length(CAST(event_name AS BLOB)) > 256
                    THEN 1 ELSE 0 END), 0)
            FROM (
                SELECT stat_type, count, source, event_name FROM stat
                LIMIT \(semanticProbeLimit + 1) OFFSET 0
            ) AS sampled
            """,
            stage: .validating,
                observesTaskCancellation: true
        ) { row in
            (
                row.int64(0) ?? 0, row.int64(1) ?? 0, row.int64(2) ?? 0,
                row.int64(3) ?? 0, row.int64(4) ?? 0
            )
        }
        let counts = rows[0]
        let cap = Int64(semanticProbeLimit)
        return (
            min(counts.1, cap), min(counts.2, cap), min(counts.3, cap),
            min(counts.4, cap), counts.0 > cap
        )
    }

    private static func timeQualityProbe(
        _ db: TraceDatabase,
        column: TimeColumn,
        range: (start: Int64, end: Int64, duration: Int64)
    ) throws -> (
        nonInteger: Int64,
        beforeStart: Int64,
        afterEnd: Int64,
        truncated: Bool
    ) {
        let isDuration = column.column == "dur"
        let lowerBound: Int64 = isDuration ? 0 : range.start
        let upperBound: Int64 = isDuration ? .max : range.end
        let rows = try db.query(
            """
            SELECT
                COUNT(*),
                COALESCE(SUM(CASE
                    WHEN typeof(value) NOT IN ('integer', 'null') THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE
                    WHEN typeof(value) = 'integer' AND value < ? THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE
                    WHEN typeof(value) = 'integer' AND value > ? THEN 1 ELSE 0 END), 0)
            FROM (
                SELECT \(column.column) AS value
                FROM \(column.table)
                LIMIT \(semanticProbeLimit + 1) OFFSET 0
            ) AS sampled
            """,
            bindings: [.int64(lowerBound), .int64(upperBound)],
            stage: .validating,
                observesTaskCancellation: true
        ) { row in
            (
                row.int64(0) ?? 0,
                row.int64(1) ?? 0,
                row.int64(2) ?? 0,
                row.int64(3) ?? 0
            )
        }
        let counts = rows[0]
        let cap = Int64(semanticProbeLimit)
        return (
            min(counts.1, cap),
            min(counts.2, cap),
            min(counts.3, cap),
            counts.0 > cap
        )
    }

    /// Fingerprint over sorted table/column/type/notnull/pk descriptions
    /// (DESIGN §9.1). Every variable-length UTF-8 field carries an unsigned
    /// 64-bit length, so legal delimiter/newline bytes cannot create the same
    /// preimage for different schemas. Additive upstream columns produce a
    /// new fingerprint but remain capability-compatible.
    private static func fingerprint(
        of columnsByTable: [String: [TraceDatabase.ColumnInfo]]
    ) -> String {
        let records = columnsByTable
            .flatMap { table, columns in
                columns.map { column in
                    var record = Data()
                    appendLengthPrefixedUTF8(table, to: &record)
                    appendLengthPrefixedUTF8(column.name, to: &record)
                    appendLengthPrefixedUTF8(column.type, to: &record)
                    record.append(column.notNull ? 1 : 0)
                    appendUInt64(UInt64(column.primaryKeyIndex), to: &record)
                    if column.hiddenKind != 0 {
                        // Preserve the locked v2 fingerprint for ordinary
                        // columns while making hidden/generated kinds part of
                        // the uniquely length-delimited record.
                        record.append(0x48)
                        appendUInt64(UInt64(column.hiddenKind), to: &record)
                    }
                    return record
                }
            }
            .sorted { $0.lexicographicallyPrecedes($1) }

        var preimage = Data("ArkTraceSchemaFingerprint".utf8)
        preimage.append(0)
        preimage.append(2)
        appendUInt64(UInt64(records.count), to: &preimage)
        for record in records {
            appendUInt64(UInt64(record.count), to: &preimage)
            preimage.append(record)
        }
        let digest = SHA256.hash(data: preimage)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func appendLengthPrefixedUTF8(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        appendUInt64(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
}
