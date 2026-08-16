import ArkTraceCore
import Foundation

private struct RepositoryValidationCacheKey: Hashable {
    let file: TraceDatabaseFileSnapshot
    let preparation: TraceDatabasePreparationResult
}

/// Avoids rescanning a multi-gigabyte Ready database for every cache hit in
/// one process. Keys include inode, size, mtime and ctime from the descriptor
/// SQLite actually opened. Replacement or in-place mutation therefore misses
/// and must pass quick_check plus full schema validation again. The bounded
/// memo is never persisted across launches.
private final class RepositoryValidationCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RepositoryValidationCacheKey: TraceSchemaAdapter.Validation] = [:]
    private var order: [RepositoryValidationCacheKey] = []
    private let maximumEntries = 64

    func value(for key: RepositoryValidationCacheKey) -> TraceSchemaAdapter.Validation? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func insert(
        _ validation: TraceSchemaAdapter.Validation,
        for key: RepositoryValidationCacheKey
    ) {
        lock.lock()
        defer { lock.unlock() }
        if values.updateValue(validation, forKey: key) == nil {
            order.append(key)
        }
        while order.count > maximumEntries {
            values.removeValue(forKey: order.removeFirst())
        }
    }
}

private let repositoryValidationCache = RepositoryValidationCache()

private enum RepositoryEventBatchItem: Sendable {
    case cpu(Int, TraceEventPage<CpuSlice>)
    case state(Int, TraceEventPage<ThreadStateInterval>)
    case slice(Int, TraceEventPage<TraceSlice>)
    case counter(Int, TraceEventPage<CounterSeries>)
    case density(Int, TraceDensityResult)
}

enum TracePerformanceQuery: Sendable {
    case cpuDetail(TraceTimeRange, ContinuousClock.Instant)
    case threadStateDetail(TraceTimeRange, ContinuousClock.Instant)
    case namedSliceDetail(TraceTimeRange, ContinuousClock.Instant)
    case cpuDensity(TraceTimeRange, ContinuousClock.Instant)
    case threadStateDensity(TraceTimeRange, ContinuousClock.Instant)
    case namedSliceDensity(TraceTimeRange, ContinuousClock.Instant)
}

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
    public nonisolated let databaseFileIdentity: TraceDatabaseFileIdentity
    private let databaseURL: URL
    private let expectedPreparation: TraceDatabasePreparationResult?
    private let db: TraceDatabase
    private let parserIdentity: TraceParserIdentity
    private let source: TraceSourceDescriptor
    private let validation: TraceSchemaAdapter.Validation
    private let processHasEndTs: Bool
    private let processHasThreadCount: Bool
    private let threadHasEndTs: Bool
    private let threadHasIsMainThread: Bool
    private let schedSliceHasEndState: Bool
    private let schedSliceHasPriority: Bool
    private let threadStateHasCPU: Bool
    private let callstackHasDepth: Bool
    private let callstackHasCategory: Bool
    private let callstackHasParentID: Bool
    private let callstackHasCookie: Bool
    private let measureHasDuration: Bool
    private let cpuFilterHasUnit: Bool
    private let processFilterHasUnit: Bool

    public init(
        databaseURL: URL,
        parser: TraceParserIdentity,
        source: TraceSourceDescriptor,
        expectedPreparation: TraceDatabasePreparationResult? = nil
    ) throws {
        try self.init(
            databaseURL: databaseURL,
            parser: parser,
            source: source,
            expectedPreparation: expectedPreparation,
            diagnosticQueryObserver: nil
        )
    }

    /// Internal-only observer used to prove that performance plans are built
    /// from the exact production repository statements rather than surrogate
    /// SQL. It is intentionally absent from the public repository API.
    init(
        databaseURL: URL,
        parser: TraceParserIdentity,
        source: TraceSourceDescriptor,
        expectedPreparation: TraceDatabasePreparationResult? = nil,
        diagnosticQueryObserver: (@Sendable (String, Int) -> Void)?
    ) throws {
        let db = try TraceDatabase(
            url: databaseURL, readOnly: true,
            queryObserver: diagnosticQueryObserver
        )
        guard let databaseFileIdentity = db.fileIdentity else {
            throw ArkTraceError(
                code: .traceDatabaseInvalid,
                stage: .openingDatabase,
                message: "Ready database identity is unavailable"
            )
        }
        let validationCacheKey = expectedPreparation.flatMap { preparation in
            db.fileSnapshot.map {
                RepositoryValidationCacheKey(file: $0, preparation: preparation)
            }
        }
        let validation: TraceSchemaAdapter.Validation
        if let validationCacheKey,
            let cached = repositoryValidationCache.value(for: validationCacheKey)
        {
            validation = cached
        } else {
            guard try db.quickCheckIsOK() else {
                throw ArkTraceError(
                    code: .traceDatabaseInvalid,
                    stage: .validating,
                    message: "SQLite quick_check failed"
                )
            }
            validation = try TraceSchemaAdapter.validate(db)
        }
        if let expectedPreparation {
            guard expectedPreparation.schemaAdapterVersion
                == TraceDatabaseStagingPreparer.schemaAdapterVersion,
                expectedPreparation.indexVersion == TraceDatabaseStagingPreparer.indexVersion,
                expectedPreparation.schemaFingerprint == validation.schemaFingerprint
            else {
                throw ArkTraceError(
                    code: .traceDatabaseInvalid,
                    stage: .openingDatabase,
                    message: "Ready database identity does not match its preparation metadata"
                )
            }
            try TraceDatabaseStagingPreparer.validateReadyIndexes(in: db)
        }
        if let validationCacheKey {
            repositoryValidationCache.insert(validation, for: validationCacheKey)
        }

        self.db = db
        self.databaseURL = databaseURL
        self.expectedPreparation = expectedPreparation
        self.databaseFileIdentity = databaseFileIdentity
        self.parserIdentity = parser
        self.source = source
        self.validation = validation

        let processColumns = Set(try db.columns(of: "process").map(\.name))
        let threadColumns = Set(try db.columns(of: "thread").map(\.name))
        let schedSliceColumns = Set(try db.columns(of: "sched_slice").map(\.name))
        let threadStateColumns = Set(try db.columns(of: "thread_state").map(\.name))
        let callstackColumns = Set(try db.columns(of: "callstack").map(\.name))
        let measureColumns = Set(try db.columns(of: "measure").map(\.name))
        let cpuFilterColumns = Set(try db.columns(of: "cpu_measure_filter").map(\.name))
        let processFilterColumns = Set(
            try db.columns(of: "process_measure_filter").map(\.name)
        )
        self.processHasEndTs = processColumns.contains("end_ts")
        self.processHasThreadCount = processColumns.contains("thread_count")
        self.threadHasEndTs = threadColumns.contains("end_ts")
        self.threadHasIsMainThread = threadColumns.contains("is_main_thread")
        self.schedSliceHasEndState = schedSliceColumns.contains("end_state")
        self.schedSliceHasPriority = schedSliceColumns.contains("priority")
        self.threadStateHasCPU = threadStateColumns.contains("cpu")
        self.callstackHasDepth = callstackColumns.contains("depth")
        self.callstackHasCategory = callstackColumns.contains("cat")
        self.callstackHasParentID = callstackColumns.contains("parent_id")
        self.callstackHasCookie = callstackColumns.contains("cookie")
        self.measureHasDuration = measureColumns.contains("dur")
        self.cpuFilterHasUnit = cpuFilterColumns.contains("unit")
        self.processFilterHasUnit = processFilterColumns.contains("unit")
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
            dataQuality: validation.dataQuality
        )
    }

    public func eventBatch(
        _ batch: TraceRepositoryEventBatch
    ) async throws -> TraceRepositoryEventBatchResult {
        guard let expectedPreparation else {
            return try await sequentialEventBatch(batch)
        }
        let databaseURL = self.databaseURL
        let parserIdentity = self.parserIdentity
        let source = self.source
        let expectedIdentity = databaseFileIdentity
        var cpu = Array<TraceEventPage<CpuSlice>?>(
            repeating: nil, count: batch.cpuSlices.count
        )
        var states = Array<TraceEventPage<ThreadStateInterval>?>(
            repeating: nil, count: batch.threadStates.count
        )
        var slices = Array<TraceEventPage<TraceSlice>?>(
            repeating: nil, count: batch.slices.count
        )
        var counters = Array<TraceEventPage<CounterSeries>?>(
            repeating: nil, count: batch.counters.count
        )
        var densities = Array<TraceDensityResult?>(
            repeating: nil, count: batch.densities.count
        )

        try await withThrowingTaskGroup(of: RepositoryEventBatchItem.self) { group in
            func clone() throws -> SQLiteTraceRepository {
                let repository = try SQLiteTraceRepository(
                    databaseURL: databaseURL,
                    parser: parserIdentity,
                    source: source,
                    expectedPreparation: expectedPreparation
                )
                guard repository.databaseFileIdentity == expectedIdentity else {
                    throw ArkTraceError(
                        code: .traceDatabaseInvalid,
                        stage: .openingDatabase,
                        message: "Ready database changed before concurrent query open"
                    )
                }
                return repository
            }
            for (index, query) in batch.cpuSlices.enumerated() {
                group.addTask {
                    .cpu(index, try await clone().cpuSlices(query))
                }
            }
            for (index, query) in batch.threadStates.enumerated() {
                group.addTask {
                    .state(index, try await clone().threadStates(query))
                }
            }
            for (index, query) in batch.slices.enumerated() {
                group.addTask {
                    .slice(index, try await clone().slices(query))
                }
            }
            for (index, query) in batch.counters.enumerated() {
                group.addTask {
                    .counter(index, try await clone().counters(query))
                }
            }
            for (index, query) in batch.densities.enumerated() {
                group.addTask {
                    .density(index, try await clone().density(query))
                }
            }
            for try await item in group {
                switch item {
                case .cpu(let index, let page): cpu[index] = page
                case .state(let index, let page): states[index] = page
                case .slice(let index, let page): slices[index] = page
                case .counter(let index, let page): counters[index] = page
                case .density(let index, let result): densities[index] = result
                }
            }
        }
        guard cpu.allSatisfy({ $0 != nil }), states.allSatisfy({ $0 != nil }),
            slices.allSatisfy({ $0 != nil }), counters.allSatisfy({ $0 != nil }),
            densities.allSatisfy({ $0 != nil })
        else {
            throw ArkTraceError(
                code: .internalError,
                stage: .querying,
                message: "Repository event batch returned an incomplete result"
            )
        }
        return TraceRepositoryEventBatchResult(
            cpuSlices: cpu.map { $0! },
            threadStates: states.map { $0! },
            slices: slices.map { $0! },
            counters: counters.map { $0! },
            densities: densities.map { $0! }
        )
    }

    private func sequentialEventBatch(
        _ batch: TraceRepositoryEventBatch
    ) async throws -> TraceRepositoryEventBatchResult {
        var cpu: [TraceEventPage<CpuSlice>] = []
        var states: [TraceEventPage<ThreadStateInterval>] = []
        var slices: [TraceEventPage<TraceSlice>] = []
        var counters: [TraceEventPage<CounterSeries>] = []
        var densities: [TraceDensityResult] = []
        for query in batch.cpuSlices { cpu.append(try await cpuSlices(query)) }
        for query in batch.threadStates { states.append(try await threadStates(query)) }
        for query in batch.slices { slices.append(try await self.slices(query)) }
        for query in batch.counters { counters.append(try await self.counters(query)) }
        for query in batch.densities { densities.append(try await density(query)) }
        return TraceRepositoryEventBatchResult(
            cpuSlices: cpu,
            threadStates: states,
            slices: slices,
            counters: counters,
            densities: densities
        )
    }

    /// Runs a production repository entry point while the diagnostic observer
    /// attached to this repository records its exact SQL and binding count.
    func performPerformanceQuery(_ query: TracePerformanceQuery) async throws {
        switch query {
            case .cpuDetail(let range, let deadline):
                _ = try await cpuSlices(
                    try CpuSliceQuery(range: range, cpu: 0, limit: 1, deadline: deadline)
                )
            case .threadStateDetail(let range, let deadline):
                _ = try await threadStates(
                    try ThreadStateQuery(
                        range: range, threadKey: ThreadKey(itid: 1),
                        limit: 1, deadline: deadline
                    )
                )
            case .namedSliceDetail(let range, let deadline):
                _ = try await slices(
                    try TraceSliceQuery(
                        range: range, threadKey: ThreadKey(itid: 1),
                        limit: 1, deadline: deadline
                    )
                )
            case .cpuDensity(let range, let deadline):
                _ = try await density(
                    try TraceDensityQuery(
                        range: range, source: .cpu(0), bucketCount: 64,
                        deadline: deadline
                    )
                )
            case .threadStateDensity(let range, let deadline):
                _ = try await density(
                    try TraceDensityQuery(
                        range: range, source: .threadState(ThreadKey(itid: 1)),
                        bucketCount: 64, deadline: deadline
                    )
                )
            case .namedSliceDensity(let range, let deadline):
                _ = try await density(
                    try TraceDensityQuery(
                        range: range, source: .namedSlice(ThreadKey(itid: 1)),
                        bucketCount: 64, deadline: deadline
                    )
                )
        }
    }

    public func processes(_ query: ProcessQuery) async throws -> BoundedPage<TraceProcess> {
        var select = ["ipid", "pid", "name", "start_ts"]
        if processHasEndTs { select.append("end_ts") }
        if processHasThreadCount { select.append("thread_count") }

        var sql = "SELECT \(select.joined(separator: ", ")) FROM process"
        var conditions = ["(ipid IS NULL OR ipid <> 0)"]
        var bindings: [TraceDatabase.Binding] = []
        if let processKey = query.processKey {
            conditions.append("ipid = ?")
            bindings.append(.int64(processKey.ipid))
        }
        if let pid = query.pid {
            conditions.append("pid = ?")
            bindings.append(.int64(pid))
        }
        if let name = query.name {
            appendNameCondition(
                column: "name",
                value: name,
                match: query.nameMatch,
                conditions: &conditions,
                bindings: &bindings
            )
        }
        sql += " WHERE " + conditions.joined(separator: " AND ")
        sql += " ORDER BY pid ASC, ipid ASC LIMIT ?"
        bindings.append(.int64(Int64(query.limit) + 1))

        let endIndex: Int32? = processHasEndTs ? 4 : nil
        let threadCountIndex: Int32? =
            processHasThreadCount ? (processHasEndTs ? 5 : 4) : nil

        var invalidNameCount: Int64 = 0
        var invalidLifecycleCount: Int64 = 0
        let rows = try db.query(
            sql,
            bindings: bindings,
            observesTaskCancellation: true,
            deadline: query.deadline
        ) { row in
            guard let ipid = row.int64(0), let pid = row.int64(1) else {
                throw Self.invalidIdentity(table: "process")
            }
            let startNs = try relative(row.int64(3))
            var endNs = try relative(endIndex.flatMap { row.int64($0) })
            if let start = startNs, let end = endNs, end < start {
                // Inverted lifecycle (raw or clamp-induced): report the end
                // as unknown instead of letting the machine contract abort
                // the whole page on one anomalous row.
                invalidLifecycleCount += 1
                endNs = nil
            }
            return TraceProcess(
                key: ProcessKey(ipid: ipid),
                pid: pid,
                name: Self.boundedDirectoryName(row, 2, invalidCount: &invalidNameCount),
                startNs: startNs,
                endNs: endNs,
                threadCount: threadCountIndex.flatMap { row.int64($0) }.map(Int.init)
            )
        }
        return page(
            rows,
            limit: query.limit,
            issues: Self.directoryPageIssues(
                prefix: "process",
                invalidNames: [("process.name", invalidNameCount)],
                invalidLifecycles: invalidLifecycleCount
            )
        )
    }

    public func threads(_ query: ThreadQuery) async throws -> BoundedPage<TraceThread> {
        var select = ["t.itid", "t.tid", "t.name", "t.start_ts", "t.ipid", "p.pid", "p.name"]
        if threadHasEndTs { select.append("t.end_ts") }
        if threadHasIsMainThread { select.append("t.is_main_thread") }

        var sql = """
            SELECT \(select.joined(separator: ", "))
            FROM thread t LEFT JOIN process p ON t.ipid = p.ipid
            """
        var conditions = ["(t.itid IS NULL OR t.itid <> 0)"]
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
            appendNameCondition(
                column: "t.name",
                value: name,
                match: query.nameMatch,
                conditions: &conditions,
                bindings: &bindings
            )
        }
        sql += " WHERE " + conditions.joined(separator: " AND ")
        sql += " ORDER BY (p.pid IS NULL) ASC, p.pid ASC, t.tid ASC, t.itid ASC LIMIT ?"
        bindings.append(.int64(Int64(query.limit) + 1))

        let endIndex: Int32? = threadHasEndTs ? 7 : nil
        let mainThreadIndex: Int32? =
            threadHasIsMainThread ? (threadHasEndTs ? 8 : 7) : nil

        var invalidNameCount: Int64 = 0
        var invalidProcessNameCount: Int64 = 0
        var invalidLifecycleCount: Int64 = 0
        let rows = try db.query(
            sql,
            bindings: bindings,
            observesTaskCancellation: true,
            deadline: query.deadline
        ) { row in
            guard let itid = row.int64(0), let tid = row.int64(1) else {
                throw Self.invalidIdentity(table: "thread")
            }
            let startNs = try relative(row.int64(3))
            var endNs = try relative(endIndex.flatMap { row.int64($0) })
            if let start = startNs, let end = endNs, end < start {
                invalidLifecycleCount += 1
                endNs = nil
            }
            return TraceThread(
                key: ThreadKey(itid: itid),
                processKey: Self.processKey(row.int64(4)),
                tid: tid,
                pid: row.int64(5),
                name: Self.boundedDirectoryName(row, 2, invalidCount: &invalidNameCount),
                processName: Self.boundedDirectoryName(
                    row, 6, invalidCount: &invalidProcessNameCount
                ),
                startNs: startNs,
                endNs: endNs,
                isMainThread: mainThreadIndex.flatMap { row.int64($0) }.map { $0 != 0 }
            )
        }
        return page(
            rows,
            limit: query.limit,
            issues: Self.directoryPageIssues(
                prefix: "thread",
                invalidNames: [
                    ("thread.name", invalidNameCount),
                    ("thread.processName", invalidProcessNameCount),
                ],
                invalidLifecycles: invalidLifecycleCount
            )
        )
    }

    public func summaryFacts(_ query: TraceSummaryQuery) async throws -> TraceSummaryFacts {
        let relativeRange: TraceTimeRange
        if let requested = query.range {
            guard requested.startNs < requested.endNs,
                requested.endNs <= validation.durationNs
            else {
                throw ArkTraceError(
                    code: .invalidArgument,
                    stage: .request,
                    message: "Summary range is empty or exceeds trace duration"
                )
            }
            relativeRange = requested
        } else {
            // AT-AN-001: no range describes the entire trace. The base init
            // permits a degenerate zero-duration trace, and the inclusive
            // absolute window below covers events stored exactly at
            // trace_range.end_ts (trace_streamer derives end_ts from the
            // maximum event timestamp, so the final event always sits there).
            relativeRange = try TraceTimeRange(
                startNs: 0,
                endNs: validation.durationNs
            )
        }
        let absoluteRange = try absoluteRange(
            relativeRange,
            inclusiveEnd: query.range == nil
        )
        let includesSaturatedFinalTimestamp = query.range == nil
            && validation.traceEndTs == Int64.max
        let rowLimit = query.maximumRowsPerSection
        let eventLimit = query.maximumEventsPerSection

        // CPU count is trace topology, not a range-scoped event count in
        // AT-AN-001. Every table is sampled by rowid before filtering or
        // reduction, so the caller's budget bounds actual SQLite work.
        let cpuCount = validation.capabilities.cpuScheduling
            ? try boundedDistinctCPUCount(
                limit: eventLimit,
                deadline: query.deadline
            ) : nil
        let process = try boundedDirectoryCount(
            table: "process",
            identityColumn: "ipid",
            hasEndTimestamp: processHasEndTs,
            range: absoluteRange,
            includesFinalTimestamp: includesSaturatedFinalTimestamp,
            limit: rowLimit,
            deadline: query.deadline
        )
        let thread = try boundedDirectoryCount(
            table: "thread",
            identityColumn: "itid",
            hasEndTimestamp: threadHasEndTs,
            range: absoluteRange,
            includesFinalTimestamp: includesSaturatedFinalTimestamp,
            limit: rowLimit,
            deadline: query.deadline
        )
        var qualityIssues: [TraceDataQualityIssue] = []
        qualityIssues.append(
            contentsOf: Self.directoryLifecycleIssues(
                table: "process", countField: "processCount", summary: process
            )
        )
        qualityIssues.append(
            contentsOf: Self.directoryLifecycleIssues(
                table: "thread", countField: "threadCount", summary: thread
            )
        )

        let cpuSliceCount = validation.capabilities.cpuScheduling
            ? try boundedEventCount(
                table: "sched_slice",
                range: absoluteRange,
                includesFinalTimestamp: includesSaturatedFinalTimestamp,
                limit: eventLimit,
                deadline: query.deadline
            ) : nil
        let threadStateCount = validation.capabilities.threadStates
            ? try boundedEventCount(
                table: "thread_state",
                range: absoluteRange,
                includesFinalTimestamp: includesSaturatedFinalTimestamp,
                limit: eventLimit,
                deadline: query.deadline
            ) : nil
        let namedSliceCount = validation.capabilities.namedSlices
            ? try boundedEventCount(
                table: "callstack",
                range: absoluteRange,
                includesFinalTimestamp: includesSaturatedFinalTimestamp,
                limit: eventLimit,
                deadline: query.deadline
            ) : nil
        let counterSeriesCount = try boundedCounterSeriesCount(
            range: absoluteRange,
            includesFinalTimestamp: includesSaturatedFinalTimestamp,
            limit: eventLimit,
            deadline: query.deadline
        )
        let eventCountBySource: TraceEventSourceCounts?
        if query.range == nil, validation.eventSourceCountsAvailable {
            let eventSourceSummary = try boundedEventSourceCounts(
                limit: eventLimit,
                deadline: query.deadline
            )
            eventCountBySource = eventSourceSummary.counts
            qualityIssues.append(contentsOf: eventSourceSummary.qualityIssues)
        } else {
            // `stat` has no timestamp and cannot honestly be range scoped.
            eventCountBySource = nil
        }

        return TraceSummaryFacts(
            cpuCount: cpuCount,
            processCount: process.count,
            threadCount: thread.count,
            cpuSliceCount: cpuSliceCount,
            threadStateCount: threadStateCount,
            namedSliceCount: namedSliceCount,
            counterSeriesCount: counterSeriesCount,
            eventCountBySource: eventCountBySource,
            qualityIssues: qualityIssues
        )
    }

    public func cpuSlices(_ query: CpuSliceQuery) async throws -> TraceEventPage<CpuSlice> {
        guard validation.capabilities.cpuScheduling else { return .unavailable }
        let range = try validatedAbsoluteRange(query.range)
        var conditions = [TraceEventIntersection.sqlPredicate(alias: "s")]
        var bindings = TraceEventIntersection.bindings(
            queryStart: range.start, queryEnd: range.end,
            traceEnd: validation.traceEndTs
        )
        if let value = query.cpu {
            conditions.append("typeof(s.cpu) = 'integer' AND s.cpu = ?")
            bindings.append(.int64(value))
        }
        if let value = query.processKey {
            conditions.append("s.ipid = ?")
            bindings.append(.int64(value.ipid))
        }
        if let value = query.pid {
            conditions.append("p.pid = ?")
            bindings.append(.int64(value))
        }
        if let value = query.threadKey {
            conditions.append("s.itid = ?")
            bindings.append(.int64(value.itid))
        }
        if let value = query.tid {
            conditions.append("t.tid = ?")
            bindings.append(.int64(value))
        }
        bindings.append(.int64(Int64(query.limit) + 1))

        let endStateSelection = schedSliceHasEndState
            ? "CASE WHEN typeof(s.end_state) = 'text' "
                + "AND length(CAST(s.end_state AS BLOB)) <= 256 "
                + "THEN s.end_state ELSE NULL END"
            : "NULL"
        let prioritySelection = schedSliceHasPriority
            ? "CASE WHEN typeof(s.priority) = 'integer' THEN s.priority ELSE NULL END"
            : "NULL"
        var invalidValueTerms = [
            "CASE WHEN p.pid IS NOT NULL AND typeof(p.pid) <> 'integer' THEN 1 ELSE 0 END",
            "CASE WHEN t.tid IS NOT NULL AND typeof(t.tid) <> 'integer' THEN 1 ELSE 0 END",
            "CASE WHEN p.name IS NOT NULL AND (typeof(p.name) <> 'text' "
                + "OR length(CAST(p.name AS BLOB)) > 4096) THEN 1 ELSE 0 END",
            "CASE WHEN t.name IS NOT NULL AND (typeof(t.name) <> 'text' "
                + "OR length(CAST(t.name AS BLOB)) > 4096) THEN 1 ELSE 0 END",
            "CASE WHEN p.name IS NOT NULL AND (typeof(p.name) <> 'text' "
                + "OR length(CAST(p.name AS BLOB)) > 4096) THEN 1 ELSE 0 END",
            "CASE WHEN t.name IS NOT NULL AND (typeof(t.name) <> 'text' "
                + "OR length(CAST(t.name AS BLOB)) > 4096) THEN 1 ELSE 0 END",
        ]
        if schedSliceHasEndState {
            invalidValueTerms.append(
                "CASE WHEN s.end_state IS NOT NULL AND (typeof(s.end_state) <> 'text' "
                    + "OR length(CAST(s.end_state AS BLOB)) > 256) THEN 1 ELSE 0 END"
            )
        }
        if schedSliceHasPriority {
            invalidValueTerms.append(
                "CASE WHEN s.priority IS NOT NULL AND typeof(s.priority) <> 'integer' "
                    + "THEN 1 ELSE 0 END"
            )
        }

        let rows = try db.query(
            """
            SELECT s.id, s.ts, s.dur, s.cpu, s.ipid, s.itid,
                p.pid, t.tid,
                CASE WHEN typeof(p.name) = 'text'
                    AND length(CAST(p.name AS BLOB)) <= 4096 THEN p.name ELSE NULL END,
                CASE WHEN typeof(t.name) = 'text'
                    AND length(CAST(t.name AS BLOB)) <= 4096 THEN t.name ELSE NULL END,
                \(endStateSelection), \(prioritySelection),
                CASE WHEN s.ipid IS NOT NULL AND s.ipid <> 0
                    AND p.ipid IS NULL THEN 1 ELSE 0 END,
                CASE WHEN s.itid IS NOT NULL AND s.itid <> 0
                    AND t.itid IS NULL THEN 1 ELSE 0 END,
                \(invalidValueTerms.joined(separator: " + "))
            FROM sched_slice AS s
            LEFT JOIN process AS p ON p.ipid = s.ipid
            LEFT JOIN thread AS t ON t.itid = s.itid
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY s.ts ASC, s.id ASC LIMIT ?
            """,
            bindings: bindings,
            observesTaskCancellation: true,
            deadline: query.deadline
        ) { row in
            EventRow(
                id: row.int64(0), timestamp: row.int64(1), duration: row.int64(2),
                durationIsNull: row.isNull(2), number: row.int64(3),
                processKey: row.int64(4), threadKey: row.int64(5),
                pid: row.int64(6), tid: row.int64(7), text: row.text(8),
                secondaryText: row.text(9), tertiaryText: row.text(10),
                auxiliaryText: nil, depth: nil,
                auxiliaryNumber: row.int64(11), parentID: nil,
                isAsync: false,
                missingProcess: row.int64(12) == 1,
                missingThread: row.int64(13) == 1,
                invalidOptionalValueCount: row.int64(14) ?? 0
            )
        }
        var items: [CpuSlice] = []
        var quality = EventQuality()
        for (index, row) in rows.prefix(query.limit).enumerated() {
            if index.isMultiple(of: 1_024) { try checkQueryBoundary(query.deadline) }
            guard let id = row.id else { throw Self.invalidIdentity(table: "sched_slice") }
            quality.invalidNumeric += row.invalidOptionalValueCount
            guard let cpu = row.number else {
                quality.invalidNumeric += 1
                continue
            }
            let interval = try eventInterval(
                timestamp: row.timestamp, duration: row.duration,
                durationIsNull: row.durationIsNull, table: "sched_slice", quality: &quality
            )
            guard let interval else { continue }
            quality.missingReference += (row.missingProcess ? 1 : 0)
                + (row.missingThread ? 1 : 0)
            items.append(
                CpuSlice(
                    key: EventKey(table: .schedSlice, rowID: id),
                    range: try TraceTimeRange(
                        startNs: interval.start, endNs: interval.end
                    ),
                    cpu: cpu,
                    threadKey: Self.threadKey(row.threadKey),
                    processKey: Self.processKey(row.processKey),
                    tid: row.tid, pid: row.pid,
                    threadName: row.secondaryText, processName: row.text,
                    endState: row.tertiaryText, priority: row.auxiliaryNumber,
                    isOpenEnded: interval.openEnded
                )
            )
        }
        quality.schedulingOverlap = overlappingSliceCount(items)
        try checkQueryBoundary(query.deadline)
        return eventPage(
            items: items, sourceRows: rows.count, limit: query.limit,
            table: "sched_slice", quality: quality
        )
    }

    public func threadStates(
        _ query: ThreadStateQuery
    ) async throws -> TraceEventPage<ThreadStateInterval> {
        guard validation.capabilities.threadStates else { return .unavailable }
        if query.cpu != nil, !threadStateHasCPU { return .unavailable }
        let range = try validatedAbsoluteRange(query.range)
        var conditions = [TraceEventIntersection.sqlPredicate(alias: "s")]
        var bindings = TraceEventIntersection.bindings(
            queryStart: range.start, queryEnd: range.end,
            traceEnd: validation.traceEndTs
        )
        if let value = query.cpu {
            conditions.append("typeof(s.cpu) = 'integer' AND s.cpu = ?")
            bindings.append(.int64(value))
        }
        if let value = query.processKey {
            conditions.append("t.ipid = ?")
            bindings.append(.int64(value.ipid))
        }
        if let value = query.pid {
            conditions.append("p.pid = ?")
            bindings.append(.int64(value))
        }
        if let value = query.threadKey {
            conditions.append("s.itid = ?")
            bindings.append(.int64(value.itid))
        }
        if let value = query.tid {
            conditions.append("t.tid = ?")
            bindings.append(.int64(value))
        }
        if let value = query.rawState {
            conditions.append("s.state = ?")
            bindings.append(.text(value))
        }
        if let value = query.state {
            conditions.append(Self.normalizedStatePredicate(value, column: "s.state"))
        }
        bindings.append(.int64(Int64(query.limit) + 1))
        let cpuSelection = threadStateHasCPU
            ? "CASE WHEN typeof(s.cpu) = 'integer' THEN s.cpu ELSE NULL END"
            : "NULL"
        var invalidValueTerms = [
            "CASE WHEN s.itid IS NULL OR typeof(s.itid) <> 'integer' "
                + "OR s.itid = 0 THEN 1 ELSE 0 END",
            "CASE WHEN p.pid IS NOT NULL AND typeof(p.pid) <> 'integer' THEN 1 ELSE 0 END",
            "CASE WHEN t.tid IS NOT NULL AND typeof(t.tid) <> 'integer' THEN 1 ELSE 0 END",
        ]
        if threadStateHasCPU {
            invalidValueTerms.append(
                "CASE WHEN s.cpu IS NOT NULL AND typeof(s.cpu) <> 'integer' "
                    + "THEN 1 ELSE 0 END"
            )
        }
        let rows = try db.query(
            """
            SELECT s.id, s.ts, s.dur, \(cpuSelection), t.ipid, s.itid,
                p.pid, t.tid,
                CASE WHEN typeof(s.state) = 'text'
                    AND length(CAST(s.state AS BLOB)) <= 256
                    THEN s.state ELSE NULL END,
                CASE WHEN typeof(p.name) = 'text'
                    AND length(CAST(p.name AS BLOB)) <= 4096 THEN p.name ELSE NULL END,
                CASE WHEN typeof(t.name) = 'text'
                    AND length(CAST(t.name AS BLOB)) <= 4096 THEN t.name ELSE NULL END,
                CASE WHEN s.itid IS NOT NULL AND s.itid <> 0
                    AND t.itid IS NULL THEN 1 ELSE 0 END,
                \(invalidValueTerms.joined(separator: " + "))
            FROM thread_state AS s
            LEFT JOIN thread AS t ON t.itid = s.itid
            LEFT JOIN process AS p ON p.ipid = t.ipid
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY s.ts ASC, s.id ASC LIMIT ?
            """,
            bindings: bindings,
            observesTaskCancellation: true,
            deadline: query.deadline
        ) { row in
            EventRow(
                id: row.int64(0), timestamp: row.int64(1), duration: row.int64(2),
                durationIsNull: row.isNull(2), number: row.int64(3),
                processKey: row.int64(4), threadKey: row.int64(5),
                pid: row.int64(6), tid: row.int64(7), text: row.text(8),
                secondaryText: row.text(9), tertiaryText: row.text(10),
                auxiliaryText: nil, depth: nil, auxiliaryNumber: nil,
                parentID: nil, isAsync: false,
                missingProcess: false, missingThread: row.int64(11) == 1,
                invalidOptionalValueCount: row.int64(12) ?? 0
            )
        }
        var items: [ThreadStateInterval] = []
        var quality = EventQuality()
        for (index, row) in rows.prefix(query.limit).enumerated() {
            if index.isMultiple(of: 1_024) { try checkQueryBoundary(query.deadline) }
            guard let id = row.id else { throw Self.invalidIdentity(table: "thread_state") }
            quality.invalidNumeric += row.invalidOptionalValueCount
            guard let threadKey = row.threadKey, threadKey != 0 else { continue }
            guard let rawState = row.text else {
                quality.invalidText += 1
                continue
            }
            let interval = try eventInterval(
                timestamp: row.timestamp, duration: row.duration,
                durationIsNull: row.durationIsNull, table: "thread_state", quality: &quality
            )
            guard let interval else { continue }
            let normalizedState = Self.normalizeState(rawState)
            if normalizedState == nil { quality.unknownState += 1 }
            quality.missingReference += row.missingThread ? 1 : 0
            items.append(
                ThreadStateInterval(
                    key: EventKey(table: .threadState, rowID: id),
                    range: try TraceTimeRange(
                        startNs: interval.start, endNs: interval.end
                    ),
                    threadKey: ThreadKey(itid: threadKey),
                    processKey: Self.processKey(row.processKey),
                    state: rawState, normalizedState: normalizedState,
                    cpu: row.number, tid: row.tid, pid: row.pid,
                    processName: row.secondaryText,
                    threadName: row.tertiaryText,
                    isOpenEnded: interval.openEnded
                )
            )
        }
        try checkQueryBoundary(query.deadline)
        return eventPage(
            items: items, sourceRows: rows.count, limit: query.limit,
            table: "thread_state", quality: quality
        )
    }

    public func slices(_ query: TraceSliceQuery) async throws -> TraceEventPage<TraceSlice> {
        guard validation.capabilities.namedSlices else { return .unavailable }
        if query.depth != nil, !callstackHasDepth {
            throw ArkTraceError(
                code: .traceSchemaUnsupported,
                stage: .querying,
                message: "Named-slice depth is unavailable in this trace schema",
                details: ["missingCapability": "namedSliceDepth"]
            )
        }
        let range = try validatedAbsoluteRange(query.range)
        var conditions = [TraceEventIntersection.sqlPredicate(alias: "s")]
        var bindings = TraceEventIntersection.bindings(
            queryStart: range.start, queryEnd: range.end,
            traceEnd: validation.traceEndTs
        )
        if let eventKey = query.eventKey {
            conditions.append("s.id = ?")
            bindings.append(.int64(eventKey.rowID))
        }
        if let value = query.processKey {
            conditions.append("t.ipid = ?")
            bindings.append(.int64(value.ipid))
        }
        if let value = query.pid {
            conditions.append("p.pid = ?")
            bindings.append(.int64(value))
        }
        if let value = query.threadKey {
            conditions.append("s.callid = ?")
            bindings.append(.int64(value.itid))
        }
        if let value = query.tid {
            conditions.append("t.tid = ?")
            bindings.append(.int64(value))
        }
        if let value = query.name {
            switch value {
            case .exact(let text):
                conditions.append("s.name = ?")
                bindings.append(.text(text))
            case .prefix(let text):
                conditions.append("s.name LIKE ? ESCAPE '\\'")
                bindings.append(.text(Self.escapedLike(text) + "%"))
            case .contains(let text):
                conditions.append("s.name LIKE ? ESCAPE '\\'")
                bindings.append(.text("%" + Self.escapedLike(text) + "%"))
            }
        }
        if let value = query.minimumDurationNs {
            conditions.append(
                """
                CASE
                    WHEN s.ts >= ? THEN 0
                    WHEN s.dur IS NULL OR s.dur < 0
                        THEN ? - MAX(s.ts, ?)
                    WHEN s.dur = 0 THEN 0
                    WHEN s.ts < ? THEN
                        CASE
                            WHEN s.dur <= ? - s.ts THEN 0
                            WHEN s.dur >= ? - s.ts THEN ?
                            ELSE s.dur - (? - s.ts)
                        END
                    ELSE MIN(s.dur, ? - s.ts)
                END >= ?
                """
            )
            bindings.append(.int64(validation.traceEndTs))
            bindings.append(.int64(validation.traceEndTs))
            bindings.append(.int64(validation.traceStartTs))
            bindings.append(.int64(validation.traceStartTs))
            bindings.append(.int64(validation.traceStartTs))
            bindings.append(.int64(validation.traceEndTs))
            bindings.append(.int64(validation.durationNs))
            bindings.append(.int64(validation.traceStartTs))
            bindings.append(.int64(validation.traceEndTs))
            bindings.append(.int64(value))
        }
        if let value = query.depth {
            conditions.append("typeof(s.depth) = 'integer' AND s.depth = ?")
            bindings.append(.int64(value))
        }
        bindings.append(.int64(Int64(query.limit) + 1))
        let depthSelection = callstackHasDepth
            ? "CASE WHEN typeof(s.depth) = 'integer' THEN s.depth ELSE NULL END"
            : "NULL"
        let categorySelection = callstackHasCategory
            ? "CASE WHEN typeof(s.cat) = 'text' "
                + "AND length(CAST(s.cat AS BLOB)) <= 1024 THEN s.cat ELSE NULL END"
            : "NULL"
        let parentSelection = callstackHasParentID
            ? "CASE WHEN typeof(s.parent_id) = 'integer' "
                + "AND s.parent_id > 0 AND s.parent_id <> 4294967295 "
                + "THEN s.parent_id ELSE NULL END"
            : "NULL"
        let asyncSelection = callstackHasCookie
            ? "CASE WHEN typeof(s.cookie) = 'integer' AND s.cookie <> 0 THEN 1 ELSE 0 END"
            : "0"
        var invalidValueTerms = [
            "CASE WHEN p.pid IS NOT NULL AND typeof(p.pid) <> 'integer' THEN 1 ELSE 0 END",
            "CASE WHEN t.tid IS NOT NULL AND typeof(t.tid) <> 'integer' THEN 1 ELSE 0 END",
            "CASE WHEN p.name IS NOT NULL AND (typeof(p.name) <> 'text' "
                + "OR length(CAST(p.name AS BLOB)) > 4096) THEN 1 ELSE 0 END",
            "CASE WHEN t.name IS NOT NULL AND (typeof(t.name) <> 'text' "
                + "OR length(CAST(t.name AS BLOB)) > 4096) THEN 1 ELSE 0 END",
        ]
        if callstackHasDepth {
            invalidValueTerms.append(
                "CASE WHEN s.depth IS NOT NULL AND typeof(s.depth) <> 'integer' "
                    + "THEN 1 ELSE 0 END"
            )
        }
        if callstackHasCategory {
            invalidValueTerms.append(
                "CASE WHEN s.cat IS NOT NULL AND (typeof(s.cat) <> 'text' "
                    + "OR length(CAST(s.cat AS BLOB)) > 1024) THEN 1 ELSE 0 END"
            )
        }
        if callstackHasParentID {
            invalidValueTerms.append(
                "CASE WHEN s.parent_id IS NOT NULL AND typeof(s.parent_id) <> 'integer' "
                    + "THEN 1 ELSE 0 END"
            )
        }
        if callstackHasCookie {
            invalidValueTerms.append(
                "CASE WHEN s.cookie IS NOT NULL AND typeof(s.cookie) <> 'integer' "
                    + "THEN 1 ELSE 0 END"
            )
        }
        let rows = try db.query(
            """
            SELECT s.id, s.ts, s.dur, s.callid, t.ipid, p.pid, t.tid,
                CASE WHEN typeof(p.name) = 'text'
                    AND length(CAST(p.name AS BLOB)) <= 4096 THEN p.name ELSE NULL END,
                CASE WHEN typeof(t.name) = 'text'
                    AND length(CAST(t.name AS BLOB)) <= 4096 THEN t.name ELSE NULL END,
                CASE WHEN typeof(s.name) = 'text'
                    AND length(CAST(s.name AS BLOB)) <= 4096
                    THEN s.name ELSE NULL END,
                \(categorySelection), \(depthSelection),
                \(parentSelection), \(asyncSelection),
                CASE WHEN s.callid IS NOT NULL AND s.callid <> 0
                    AND t.itid IS NULL THEN 1 ELSE 0 END,
                \(invalidValueTerms.joined(separator: " + "))
            FROM callstack AS s
            LEFT JOIN thread AS t ON t.itid = s.callid
            LEFT JOIN process AS p ON p.ipid = t.ipid
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY s.ts ASC, s.id ASC LIMIT ?
            """,
            bindings: bindings,
            observesTaskCancellation: true,
            deadline: query.deadline
        ) { row in
            EventRow(
                id: row.int64(0), timestamp: row.int64(1), duration: row.int64(2),
                durationIsNull: row.isNull(2), number: nil,
                processKey: row.int64(4), threadKey: row.int64(3),
                pid: row.int64(5), tid: row.int64(6), text: row.text(9),
                secondaryText: row.text(10), tertiaryText: row.text(7),
                auxiliaryText: row.text(8), depth: row.int64(11),
                auxiliaryNumber: nil, parentID: row.int64(12),
                isAsync: row.int64(13) == 1,
                missingProcess: false, missingThread: row.int64(14) == 1,
                invalidOptionalValueCount: row.int64(15) ?? 0
            )
        }
        var items: [TraceSlice] = []
        var quality = EventQuality()
        for (index, row) in rows.prefix(query.limit).enumerated() {
            if index.isMultiple(of: 1_024) { try checkQueryBoundary(query.deadline) }
            guard let id = row.id else {
                throw Self.invalidIdentity(table: "callstack")
            }
            quality.invalidNumeric += row.invalidOptionalValueCount
            guard let name = row.text else {
                quality.invalidText += 1
                continue
            }
            let interval = try eventInterval(
                timestamp: row.timestamp, duration: row.duration,
                durationIsNull: row.durationIsNull, table: "callstack", quality: &quality
            )
            guard let interval else { continue }
            quality.missingReference += row.missingThread ? 1 : 0
            items.append(
                TraceSlice(
                    key: EventKey(table: .callstack, rowID: id),
                    range: try TraceTimeRange(
                        startNs: interval.start, endNs: interval.end
                    ),
                    threadKey: Self.threadKey(row.threadKey),
                    processKey: Self.processKey(row.processKey),
                    pid: row.pid,
                    tid: row.tid,
                    processName: row.tertiaryText,
                    threadName: row.auxiliaryText,
                    name: name, category: row.secondaryText, depth: row.depth,
                    parentEventKey: row.parentID.map {
                        EventKey(table: .callstack, rowID: $0)
                    },
                    isAsync: row.isAsync, isOpenEnded: interval.openEnded
                )
            )
        }
        try checkQueryBoundary(query.deadline)
        return eventPage(
            items: items, sourceRows: rows.count, limit: query.limit,
            table: "callstack", quality: quality
        )
    }

    public func counters(_ query: CounterQuery) async throws -> TraceEventPage<CounterSeries> {
        let cpuAvailable = validation.capabilities.cpuCounters
        let processAvailable = validation.capabilities.processCounters
        guard cpuAvailable || processAvailable else { return .unavailable }
        if query.cpu != nil, !cpuAvailable { return .unavailable }
        if query.processKey != nil || query.pid != nil, !processAvailable { return .unavailable }
        let range = try validatedAbsoluteRange(query.range)
        guard let rowID = try db.unshadowedRowIDAlias(
            of: "measure", deadline: query.deadline
        ) else {
            throw ArkTraceError(
                code: .traceSchemaUnsupported,
                stage: .querying,
                message: "Counter samples have no stable row identity",
                details: ["missingCapability": "counterSampleIdentity"]
            )
        }
        var samples: [CounterResultRow] = []
        var sourceTruncated = false
        if cpuAvailable, query.processKey == nil, query.pid == nil {
            let result = try counterRows(
                filterTable: "cpu_measure_filter", scopeColumn: "cpu",
                scopeValue: query.cpu, filterID: query.filterID, pid: nil,
                name: query.name,
                hasUnit: cpuFilterHasUnit,
                rowID: rowID, range: range, limit: query.limit,
                deadline: query.deadline, sourceOrder: 0
            )
            samples.append(contentsOf: result.rows)
            sourceTruncated = sourceTruncated || result.truncated
        }
        if processAvailable, query.cpu == nil {
            let result = try counterRows(
                filterTable: "process_measure_filter", scopeColumn: "ipid",
                scopeValue: query.processKey?.ipid, filterID: query.filterID,
                pid: query.pid, name: query.name,
                hasUnit: processFilterHasUnit,
                rowID: rowID, range: range, limit: query.limit,
                deadline: query.deadline, sourceOrder: 1
            )
            samples.append(contentsOf: result.rows)
            sourceTruncated = sourceTruncated || result.truncated
        }
        samples.sort {
            ($0.timestamp, $0.rowID, $0.sourceOrder, $0.filterID)
                < ($1.timestamp, $1.rowID, $1.sourceOrder, $1.filterID)
        }
        let totalTruncated = sourceTruncated || samples.count > query.limit
        let selected = samples.prefix(query.limit)
        var grouped: [CounterSeriesKey: [CounterSample]] = [:]
        var names: [CounterSeriesKey: String] = [:]
        var units: [CounterSeriesKey: String] = [:]
        var pids: [CounterSeriesKey: Int64] = [:]
        var processNames: [CounterSeriesKey: String] = [:]
        var invalidOptionalValues: Int64 = 0
        var missingProcessReferences: Int64 = 0
        var counterQuality = EventQuality()
        var seenSampleKeys: Set<EventKey> = []
        for (index, row) in selected.enumerated() {
            if index.isMultiple(of: 1_024) { try checkQueryBoundary(query.deadline) }
            let key = CounterSeriesKey(
                sourceOrder: row.sourceOrder, filterID: row.filterID, scopeID: row.scopeID
            )
            let eventKey = EventKey(table: .measure, rowID: row.rowID)
            guard seenSampleKeys.insert(eventKey).inserted else {
                throw ArkTraceError(
                    code: .queryFailed,
                    stage: .querying,
                    message: "Counter filter identity produced a duplicate sample"
                )
            }
            invalidOptionalValues += row.invalidOptionalValueCount
            missingProcessReferences += row.missingProcessReferenceCount
            let normalized = try normalizedCounterSample(
                row, quality: &counterQuality
            )
            grouped[key, default: []].append(
                CounterSample(
                    key: eventKey,
                    timestampNs: normalized.timestampNs, value: row.value,
                    durationNs: normalized.durationNs
                )
            )
            names[key] = row.name
            units[key] = row.unit
            pids[key] = row.pid
            processNames[key] = row.processName
        }
        let orderedKeys = grouped.keys.sorted {
            ($0.sourceOrder, $0.scopeID, $0.filterID)
                < ($1.sourceOrder, $1.scopeID, $1.filterID)
        }
        let series = orderedKeys.map { key in
            CounterSeries(
                filterID: key.filterID,
                name: names[key]!,
                scope: key.sourceOrder == 0 ? .cpu : .process,
                cpu: key.sourceOrder == 0 ? key.scopeID : nil,
                processKey: key.sourceOrder == 1
                    ? Self.processKey(key.scopeID) : nil,
                pid: key.sourceOrder == 1 ? pids[key] : nil,
                processName: key.sourceOrder == 1 ? processNames[key] : nil,
                unit: units[key],
                samples: grouped[key]!
            )
        }
        try checkQueryBoundary(query.deadline)
        var issues = validation.dataQuality.issues
        if invalidOptionalValues > 0 {
            issues.append(
                TraceDataQualityIssue(
                    category: .droppedValue,
                    scope: "measure.optional",
                    count: invalidOptionalValues
                )
            )
        }
        if counterQuality.clampedTimestamp > 0 {
            issues.append(
                TraceDataQualityIssue(
                    category: .clampedValue,
                    scope: "measure.ts",
                    count: counterQuality.clampedTimestamp
                )
            )
        }
        if counterQuality.clampedDuration > 0 {
            issues.append(
                TraceDataQualityIssue(
                    category: .clampedValue,
                    scope: "measure.dur",
                    count: counterQuality.clampedDuration
                )
            )
        }
        if missingProcessReferences > 0 {
            issues.append(
                TraceDataQualityIssue(
                    category: .referentialIntegrity,
                    scope: "process_measure_filter.ipid",
                    count: missingProcessReferences
                )
            )
        }
        return TraceEventPage(
            items: series,
            truncated: totalTruncated || invalidOptionalValues > 0
                || counterQuality.invalidTime > 0,
            capabilityAvailable: true,
            dataQuality: TraceDataQuality(issues: issues)
        )
    }

    public func density(_ query: TraceDensityQuery) async throws -> TraceDensityResult {
        let range = try validatedAbsoluteRange(query.range)
        let (quotient, remainder) = query.range.durationNs.quotientAndRemainder(
            dividingBy: Int64(query.bucketCount)
        )
        let bucketWidth = quotient + (remainder == 0 ? 0 : 1)
        guard bucketWidth > 0 else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Density bucket width is invalid"
            )
        }

        var bindings: [TraceDatabase.Binding] = [
            .int64(range.start), .int64(range.start), .int64(bucketWidth),
        ]
        let sampleSQL: String
        let timeQualityScope: String
        let counterInvalidDurationSelection = measureHasDuration
            ? "CASE WHEN m.dur IS NOT NULL AND typeof(m.dur) <> 'integer' "
                + "THEN 1 ELSE 0 END"
            : "0"
        let counterClampedDurationSelection = measureHasDuration
            ? "CASE WHEN typeof(m.dur) = 'integer' AND m.dur > 0 "
                + "AND (m.dur > ? OR m.ts + m.dur > ?) THEN 1 ELSE 0 END"
            : "0"
        switch query.source {
        case .cpu(let cpu):
            guard validation.capabilities.cpuScheduling else { return .unavailable }
            timeQualityScope = "sched_slice.ts"
            bindings.append(.int64(validation.traceStartTs))
            bindings.append(.int64(validation.traceEndTs))
            bindings.append(contentsOf: TraceEventIntersection.bindings(
                queryStart: range.start, queryEnd: range.end,
                traceEnd: validation.traceEndTs
            ))
            bindings.append(.int64(cpu))
            sampleSQL = """
                SELECT MIN(\(query.bucketCount - 1), MAX(0,
                        CASE WHEN s.ts <= ? THEN 0 ELSE (s.ts - ?) / ? END
                    )) AS bucket,
                    CASE WHEN s.ts < ? OR s.ts > ? THEN 1 ELSE 0 END AS clamped,
                    0 AS invalid_duration, 0 AS clamped_duration
                FROM sched_slice AS s
                    INDEXED BY arktrace_v3_sched_slice_cpu_ts_dur
                WHERE \(TraceEventIntersection.sqlPredicate(alias: "s"))
                    AND typeof(s.cpu) = 'integer' AND s.cpu = ?
                """
        case .threadState(let threadKey):
            guard validation.capabilities.threadStates else { return .unavailable }
            timeQualityScope = "thread_state.ts"
            bindings.append(.int64(validation.traceStartTs))
            bindings.append(.int64(validation.traceEndTs))
            bindings.append(contentsOf: TraceEventIntersection.bindings(
                queryStart: range.start, queryEnd: range.end,
                traceEnd: validation.traceEndTs
            ))
            bindings.append(.int64(threadKey.itid))
            sampleSQL = """
                SELECT MIN(\(query.bucketCount - 1), MAX(0,
                        CASE WHEN s.ts <= ? THEN 0 ELSE (s.ts - ?) / ? END
                    )) AS bucket,
                    CASE WHEN s.ts < ? OR s.ts > ? THEN 1 ELSE 0 END AS clamped,
                    0 AS invalid_duration, 0 AS clamped_duration
                FROM thread_state AS s
                    INDEXED BY arktrace_v3_thread_state_itid_ts_dur
                WHERE \(TraceEventIntersection.sqlPredicate(alias: "s"))
                    AND typeof(s.itid) = 'integer' AND s.itid = ?
                """
        case .namedSlice(let threadKey):
            guard validation.capabilities.namedSlices else { return .unavailable }
            timeQualityScope = "callstack.ts"
            bindings.append(.int64(validation.traceStartTs))
            bindings.append(.int64(validation.traceEndTs))
            bindings.append(contentsOf: TraceEventIntersection.bindings(
                queryStart: range.start, queryEnd: range.end,
                traceEnd: validation.traceEndTs
            ))
            let threadCondition: String
            if let threadKey {
                bindings.append(.int64(threadKey.itid))
                threadCondition = "AND typeof(s.callid) = 'integer' AND s.callid = ?"
            } else {
                threadCondition = "AND (s.callid IS NULL OR s.callid = 0)"
            }
            sampleSQL = """
                SELECT MIN(\(query.bucketCount - 1), MAX(0,
                        CASE WHEN s.ts <= ? THEN 0 ELSE (s.ts - ?) / ? END
                    )) AS bucket,
                    CASE WHEN s.ts < ? OR s.ts > ? THEN 1 ELSE 0 END AS clamped,
                    0 AS invalid_duration, 0 AS clamped_duration
                FROM callstack AS s
                    INDEXED BY arktrace_v3_callstack_callid_ts_dur
                WHERE \(TraceEventIntersection.sqlPredicate(alias: "s"))
                    \(threadCondition)
                """
        case .cpuCounter(let filterID, let cpu):
            guard validation.capabilities.cpuCounters else { return .unavailable }
            timeQualityScope = "measure.ts"
            let timeFilter = counterTimeFilter(range: range)
            bindings.append(.int64(validation.traceStartTs))
            bindings.append(.int64(validation.traceEndTs))
            if measureHasDuration {
                bindings.append(.int64(validation.durationNs))
                bindings.append(.int64(validation.traceEndTs))
            }
            bindings.append(contentsOf: timeFilter.bindings)
            bindings.append(.int64(filterID))
            if let cpu { bindings.append(.int64(cpu)) }
            sampleSQL = """
                SELECT MIN(\(query.bucketCount - 1), MAX(0,
                        CASE WHEN m.ts <= ? THEN 0 ELSE (m.ts - ?) / ? END
                    )) AS bucket,
                    CASE WHEN m.ts < ? OR m.ts > ? THEN 1 ELSE 0 END AS clamped,
                    \(counterInvalidDurationSelection) AS invalid_duration,
                    \(counterClampedDurationSelection) AS clamped_duration
                FROM measure AS m
                INNER JOIN cpu_measure_filter AS f ON f.id = m.filter_id
                WHERE typeof(m.ts) = 'integer'
                    AND typeof(m.filter_id) = 'integer'
                    AND typeof(f.id) = 'integer' AND typeof(f.cpu) = 'integer'
                    AND \(timeFilter.predicate)
                    AND f.id = ? \(cpu == nil ? "" : "AND f.cpu = ?")
                """
        case .processCounter(let filterID, let processKey):
            guard validation.capabilities.processCounters else { return .unavailable }
            timeQualityScope = "measure.ts"
            let timeFilter = counterTimeFilter(range: range)
            bindings.append(.int64(validation.traceStartTs))
            bindings.append(.int64(validation.traceEndTs))
            if measureHasDuration {
                bindings.append(.int64(validation.durationNs))
                bindings.append(.int64(validation.traceEndTs))
            }
            bindings.append(contentsOf: timeFilter.bindings)
            bindings.append(.int64(filterID))
            if let processKey { bindings.append(.int64(processKey.ipid)) }
            sampleSQL = """
                SELECT MIN(\(query.bucketCount - 1), MAX(0,
                        CASE WHEN m.ts <= ? THEN 0 ELSE (m.ts - ?) / ? END
                    )) AS bucket,
                    CASE WHEN m.ts < ? OR m.ts > ? THEN 1 ELSE 0 END AS clamped,
                    \(counterInvalidDurationSelection) AS invalid_duration,
                    \(counterClampedDurationSelection) AS clamped_duration
                FROM measure AS m
                INNER JOIN process_measure_filter AS f ON f.id = m.filter_id
                WHERE typeof(m.ts) = 'integer'
                    AND typeof(m.filter_id) = 'integer'
                    AND typeof(f.id) = 'integer' AND typeof(f.ipid) = 'integer'
                    AND \(timeFilter.predicate)
                    AND f.id = ? \(processKey == nil ? "" : "AND f.ipid = ?")
                """
        }

        let rows = try db.query(
            """
            WITH sampled AS (
                \(sampleSQL)
            )
            SELECT bucket, COUNT(*), NULL,
                SUM(clamped), SUM(invalid_duration), SUM(clamped_duration)
            FROM sampled GROUP BY bucket ORDER BY bucket ASC
            """,
            bindings: bindings,
            observesTaskCancellation: true,
            deadline: query.deadline
        ) { row in
            (
                row.int64(0), row.int64(1), row.int64(2),
                row.int64(3), row.int64(4), row.int64(5)
            )
        }
        var buckets: [TraceDensityBucket] = []
        var clampedTimestampCount: Int64 = 0
        var invalidCounterDurationCount: Int64 = 0
        var clampedCounterDurationCount: Int64 = 0
        buckets.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 1_024) { try checkQueryBoundary(query.deadline) }
            guard let bucket = row.0, let count = row.1,
                bucket >= 0, bucket < Int64(query.bucketCount), count >= 0
            else {
                throw ArkTraceError(
                    code: .queryFailed,
                    stage: .querying,
                    message: "Density aggregation returned an invalid bucket"
                )
            }
            let (offset, offsetOverflow) = bucket.multipliedReportingOverflow(by: bucketWidth)
            let (start, startOverflow) = query.range.startNs.addingReportingOverflow(offset)
            let (candidateEnd, endOverflow) = start.addingReportingOverflow(bucketWidth)
            guard !offsetOverflow, !startOverflow else {
                throw ArkTraceError(
                    code: .queryFailed,
                    stage: .querying,
                    message: "Density bucket cannot be represented"
                )
            }
            let end = endOverflow ? query.range.endNs : min(candidateEnd, query.range.endNs)
            clampedTimestampCount += row.3 ?? 0
            invalidCounterDurationCount += row.4 ?? 0
            clampedCounterDurationCount += row.5 ?? 0
            buckets.append(
                TraceDensityBucket(
                    range: try TraceTimeRange.query(startNs: start, endNs: end),
                    eventCount: count,
                    occupiedNs: nil,
                    utilization: nil,
                    dominantThreadKey: Self.threadKey(row.2)
                )
            )
        }
        try checkQueryBoundary(query.deadline)
        var issues = validation.dataQuality.issues
        if clampedTimestampCount > 0 {
            issues.append(
                TraceDataQualityIssue(
                    category: .clampedValue,
                    scope: timeQualityScope,
                    count: clampedTimestampCount
                )
            )
        }
        if invalidCounterDurationCount > 0 {
            issues.append(
                TraceDataQualityIssue(
                    category: .droppedValue,
                    scope: "timeline.counter.duration",
                    count: invalidCounterDurationCount
                )
            )
        }
        if clampedCounterDurationCount > 0 {
            issues.append(
                TraceDataQualityIssue(
                    category: .clampedValue,
                    scope: "timeline.counter.duration",
                    count: clampedCounterDurationCount
                )
            )
        }
        if !buckets.isEmpty {
            issues.append(
                TraceDataQualityIssue(
                    category: .unavailableValue,
                    scope: "timeline.density.occupancy"
                )
            )
            issues.append(
                TraceDataQualityIssue(
                    category: .unavailableValue,
                    scope: "timeline.density.dominantThread"
                )
            )
        }
        return TraceDensityResult(
            buckets: buckets,
            capabilityAvailable: true,
            dataQuality: TraceDataQuality(issues: issues)
        )
    }

    // MARK: - Helpers

    private func validatedAbsoluteRange(
        _ range: TraceTimeRange
    ) throws -> (start: Int64, end: Int64) {
        guard range.startNs < range.endNs, range.endNs <= validation.durationNs else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Event query range is empty or exceeds trace duration"
            )
        }
        return try absoluteRange(range)
    }

    private func requiredRelative(_ timestamp: Int64) throws -> Int64 {
        guard let value = try relative(timestamp) else {
            throw ArkTraceError(
                code: .queryFailed,
                stage: .querying,
                message: "Counter timestamp is unavailable"
            )
        }
        return value
    }

    /// Counter duration uses the same half-open/instant/open-ended semantics
    /// as other events. A schema without `measure.dur` is an instant series;
    /// NULL/negative values remain open-ended as `durationNs == nil`.
    private func normalizedCounterSample(
        _ row: CounterResultRow,
        quality: inout EventQuality
    ) throws -> (timestampNs: Int64, durationNs: Int64?) {
        switch row.durationState {
        case .absent:
            return (try requiredRelative(row.timestamp), 0)
        case .invalid:
            // The optional value is already counted by the SQL projection.
            // Treat the retained sample as an instant instead of turning an
            // incompatible value into an open-ended interval.
            return (try requiredRelative(row.timestamp), 0)
        case .null:
            let interval = try eventInterval(
                timestamp: row.timestamp,
                duration: nil,
                durationIsNull: true,
                table: "measure",
                quality: &quality
            )
            guard let interval else {
                throw ArkTraceError(
                    code: .queryFailed,
                    stage: .querying,
                    message: "Counter timestamp is unavailable"
                )
            }
            return (interval.start, nil)
        case .integer:
            let interval = try eventInterval(
                timestamp: row.timestamp,
                duration: row.duration,
                durationIsNull: false,
                table: "measure",
                quality: &quality
            )
            guard let interval else {
                throw ArkTraceError(
                    code: .queryFailed,
                    stage: .querying,
                    message: "Counter interval is unavailable"
                )
            }
            if interval.openEnded { return (interval.start, nil) }
            let (duration, overflow) = interval.end.subtractingReportingOverflow(
                interval.start
            )
            guard !overflow, duration >= 0 else {
                throw ArkTraceError(
                    code: .queryFailed,
                    stage: .querying,
                    message: "Counter duration cannot be represented"
                )
            }
            return (interval.start, duration)
        }
    }

    private func eventInterval(
        timestamp: Int64?,
        duration: Int64?,
        durationIsNull: Bool,
        table: String,
        quality: inout EventQuality
    ) throws -> EventInterval? {
        guard let timestamp, duration != nil || durationIsNull else {
            quality.invalidTime += 1
            return nil
        }
        let start = try requiredRelative(timestamp)
        if timestamp < validation.traceStartTs || timestamp > validation.traceEndTs {
            quality.clampedTimestamp += 1
        }
        guard let duration else {
            return EventInterval(start: start, end: validation.durationNs, openEnded: true)
        }
        if duration < 0 {
            return EventInterval(start: start, end: validation.durationNs, openEnded: true)
        }
        if duration == 0 {
            return EventInterval(start: start, end: start, openEnded: false)
        }
        let (absoluteEnd, overflow) = timestamp.addingReportingOverflow(duration)
        if overflow {
            quality.clampedDuration += 1
            return EventInterval(start: start, end: validation.durationNs, openEnded: false)
        }
        let clampedAbsoluteEnd = min(
            validation.traceEndTs,
            max(validation.traceStartTs, absoluteEnd)
        )
        if timestamp < validation.traceStartTs
            || absoluteEnd != clampedAbsoluteEnd {
            quality.clampedDuration += 1
        }
        let end = try requiredRelative(clampedAbsoluteEnd)
        guard end >= start else {
            quality.invalidTime += 1
            return nil
        }
        return EventInterval(start: start, end: end, openEnded: false)
    }

    private func eventPage<T: Sendable>(
        items: [T],
        sourceRows: Int,
        limit: Int,
        table: String,
        quality: EventQuality
    ) -> TraceEventPage<T> {
        var issues = validation.dataQuality.issues
        if quality.invalidNumeric > 0 || quality.invalidText > 0 || quality.invalidTime > 0 {
            issues.append(
                TraceDataQualityIssue(
                    category: .droppedValue,
                    scope: TraceDataQualityScope.eventValue(table: table),
                    count: quality.invalidNumeric + quality.invalidText + quality.invalidTime
                )
            )
        }
        if quality.clampedTimestamp > 0 {
            issues.append(
                TraceDataQualityIssue(
                    category: .clampedValue,
                    scope: "\(table).ts",
                    count: quality.clampedTimestamp
                )
            )
        }
        if quality.clampedDuration > 0 {
            issues.append(
                TraceDataQualityIssue(
                    category: .clampedValue,
                    scope: "\(table).dur",
                    count: quality.clampedDuration
                )
            )
        }
        if quality.missingReference > 0 {
            issues.append(
                TraceDataQualityIssue(
                    category: .referentialIntegrity,
                    scope: TraceDataQualityScope.eventIdentity(table: table),
                    count: quality.missingReference
                )
            )
        }
        if quality.unknownState > 0 {
            issues.append(
                TraceDataQualityIssue(
                    category: .invalidValue,
                    scope: "thread_state.state",
                    count: quality.unknownState
                )
            )
        }
        if quality.schedulingOverlap > 0 {
            issues.append(
                TraceDataQualityIssue(
                    category: .invalidValue,
                    scope: "sched_slice.overlap",
                    count: quality.schedulingOverlap
                )
            )
        }
        return TraceEventPage(
            items: items,
            truncated: sourceRows > limit
                || quality.invalidNumeric > 0 || quality.invalidText > 0
                || quality.invalidTime > 0,
            capabilityAvailable: true,
            dataQuality: TraceDataQuality(issues: issues)
        )
    }

    private func overlappingSliceCount(_ slices: [CpuSlice]) -> Int64 {
        var lastEndByCPU: [Int64: Int64] = [:]
        var overlaps: Int64 = 0
        for slice in slices {
            let effectiveEnd = slice.isInstant ? slice.startNs : slice.endNs
            if let lastEnd = lastEndByCPU[slice.cpu], slice.startNs < lastEnd {
                overlaps += 1
            }
            lastEndByCPU[slice.cpu] = max(lastEndByCPU[slice.cpu] ?? .min, effectiveEnd)
        }
        return overlaps
    }

    private func counterRows(
        filterTable: String,
        scopeColumn: String,
        scopeValue: Int64?,
        filterID: Int64?,
        pid: Int64?,
        name: CounterNameFilter?,
        hasUnit: Bool,
        rowID: String,
        range: (start: Int64, end: Int64),
        limit: Int,
        deadline: ContinuousClock.Instant,
        sourceOrder: Int64
    ) throws -> (rows: [CounterResultRow], truncated: Bool) {
        var conditions = [
            "typeof(m.ts) = 'integer'", "typeof(m.value) = 'integer'",
            "typeof(m.filter_id) = 'integer'", "typeof(f.id) = 'integer'",
            "typeof(f.\(scopeColumn)) = 'integer'", "typeof(f.name) = 'text'",
            "length(CAST(f.name AS BLOB)) <= 256",
        ]
        let timeFilter = counterTimeFilter(range: range)
        conditions.append(timeFilter.predicate)
        var bindings = timeFilter.bindings
        if let filterID {
            conditions.append("f.id = ?")
            bindings.append(.int64(filterID))
        }
        if let scopeValue {
            conditions.append("f.\(scopeColumn) = ?")
            bindings.append(.int64(scopeValue))
        }
        if let pid {
            guard filterTable == "process_measure_filter" else {
                throw ArkTraceError(
                    code: .invalidArgument,
                    stage: .request,
                    message: "PID filtering requires process counters"
                )
            }
            conditions.append("p.pid = ?")
            bindings.append(.int64(pid))
        }
        if let name {
            switch name {
            case .exact(let text):
                conditions.append("f.name = ?")
                bindings.append(.text(text))
            case .prefix(let text):
                conditions.append("f.name LIKE ? ESCAPE '\\'")
                bindings.append(.text(Self.escapedLike(text) + "%"))
            case .contains(let text):
                conditions.append("f.name LIKE ? ESCAPE '\\'")
                bindings.append(.text("%" + Self.escapedLike(text) + "%"))
            }
        }
        bindings.append(.int64(Int64(limit) + 1))
        let durationSelection = measureHasDuration
            ? "CASE WHEN typeof(m.dur) = 'integer' THEN m.dur ELSE NULL END"
            : "0"
        let durationStateSelection = measureHasDuration
            ? "CASE WHEN m.dur IS NULL THEN 1 "
                + "WHEN typeof(m.dur) = 'integer' THEN 2 ELSE 3 END"
            : "0"
        let unitSelection = hasUnit
            ? "CASE WHEN typeof(f.unit) = 'text' "
                + "AND length(CAST(f.unit AS BLOB)) <= 256 THEN f.unit ELSE NULL END"
            : "NULL"
        let isProcessScope = filterTable == "process_measure_filter"
        let processJoin = isProcessScope
            ? "LEFT JOIN process AS p ON p.ipid = f.ipid" : ""
        let pidSelection = isProcessScope
            ? "CASE WHEN typeof(p.pid) = 'integer' THEN p.pid ELSE NULL END" : "NULL"
        let processNameSelection = isProcessScope
            ? "CASE WHEN typeof(p.name) = 'text' "
                + "AND length(CAST(p.name AS BLOB)) <= 4096 THEN p.name ELSE NULL END"
            : "NULL"
        let missingProcessSelection = isProcessScope
            ? "CASE WHEN f.ipid <> 0 AND p.ipid IS NULL THEN 1 ELSE 0 END"
            : "0"
        var invalidValueTerms: [String] = []
        if measureHasDuration {
            invalidValueTerms.append(
                "CASE WHEN m.dur IS NOT NULL AND typeof(m.dur) <> 'integer' "
                    + "THEN 1 ELSE 0 END"
            )
        }
        if hasUnit {
            invalidValueTerms.append(
                "CASE WHEN f.unit IS NOT NULL AND (typeof(f.unit) <> 'text' "
                    + "OR length(CAST(f.unit AS BLOB)) > 256) THEN 1 ELSE 0 END"
            )
        }
        if isProcessScope {
            invalidValueTerms.append(
                "CASE WHEN p.pid IS NOT NULL AND typeof(p.pid) <> 'integer' THEN 1 ELSE 0 END"
            )
            invalidValueTerms.append(
                "CASE WHEN p.name IS NOT NULL AND (typeof(p.name) <> 'text' "
                    + "OR length(CAST(p.name AS BLOB)) > 4096) THEN 1 ELSE 0 END"
            )
        }
        let invalidSelection = invalidValueTerms.isEmpty
            ? "0" : invalidValueTerms.joined(separator: " + ")
        let rows = try db.query(
            """
            SELECT m.\(rowID), m.ts, m.value, f.id, f.name, f.\(scopeColumn),
                \(durationSelection), \(durationStateSelection),
                \(unitSelection), \(invalidSelection),
                \(pidSelection), \(processNameSelection), \(missingProcessSelection)
            FROM measure AS m
            INNER JOIN \(filterTable) AS f ON f.id = m.filter_id
            \(processJoin)
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY m.ts ASC, m.\(rowID) ASC LIMIT ?
            """,
            bindings: bindings,
            observesTaskCancellation: true,
            deadline: deadline
        ) { row -> CounterResultRow in
            guard let rowID = row.int64(0), let timestamp = row.int64(1),
                let value = row.int64(2), let filterID = row.int64(3),
                let name = row.text(4), let scopeID = row.int64(5)
            else {
                throw ArkTraceError(
                    code: .queryFailed,
                    stage: .querying,
                    message: "Counter sample has incompatible storage"
                )
            }
            return CounterResultRow(
                rowID: rowID, timestamp: timestamp, value: value,
                filterID: filterID, name: name, scopeID: scopeID,
                sourceOrder: sourceOrder, duration: row.int64(6),
                durationState: CounterDurationState(rawValue: row.int64(7) ?? 3)
                    ?? .invalid,
                unit: row.text(8),
                invalidOptionalValueCount: row.int64(9) ?? 0,
                pid: row.int64(10),
                processName: row.text(11),
                missingProcessReferenceCount: row.int64(12) ?? 0
            )
        }
        return (Array(rows.prefix(limit)), rows.count > limit)
    }

    /// Counter detail and density must agree on interval intersection. A
    /// schema without measure.dur contains instant samples. If an optional
    /// duration has an incompatible dynamic storage class, retain that row as
    /// an instant; bounded quality evidence reports the dropped value.
    private func counterTimeFilter(
        range: (start: Int64, end: Int64)
    ) -> (predicate: String, bindings: [TraceDatabase.Binding]) {
        guard measureHasDuration else {
            return (
                "m.ts >= ? AND m.ts < ?",
                [.int64(range.start), .int64(range.end)]
            )
        }
        return (
            """
            (
                ((m.dur IS NULL OR typeof(m.dur) = 'integer') AND (
                    \(TraceEventIntersection.sqlPredicate(alias: "m"))
                ))
                OR (
                    m.dur IS NOT NULL AND typeof(m.dur) <> 'integer'
                    AND m.ts >= ? AND m.ts < ?
                )
            )
            """,
            TraceEventIntersection.bindings(
                queryStart: range.start,
                queryEnd: range.end,
                traceEnd: validation.traceEndTs
            ) + [.int64(range.start), .int64(range.end)]
        )
    }

    private static func escapedLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func appendNameCondition(
        column: String,
        value: String,
        match: TraceDirectoryNameMatch,
        conditions: inout [String],
        bindings: inout [TraceDatabase.Binding]
    ) {
        switch match {
        case .exact:
            conditions.append("\(column) = ?")
            bindings.append(.text(value))
        case .prefix:
            conditions.append("\(column) LIKE ? ESCAPE '\\'")
            bindings.append(.text("\(Self.escapedLike(value))%"))
        case .contains:
            conditions.append("\(column) LIKE ? ESCAPE '\\'")
            bindings.append(.text("%\(Self.escapedLike(value))%"))
        }
    }

    /// TraceStreamer uses zero for an absent relationship. Never let that
    /// sentinel cross the Store boundary as a forged stable identity.
    private static func processKey(_ raw: Int64?) -> ProcessKey? {
        guard let raw, raw != 0 else { return nil }
        return ProcessKey(ipid: raw)
    }

    /// TraceStreamer uses zero for an absent relationship. Never let that
    /// sentinel cross the Store boundary as a forged stable identity.
    private static func threadKey(_ raw: Int64?) -> ThreadKey? {
        guard let raw, raw != 0 else { return nil }
        return ThreadKey(itid: raw)
    }

    private static func normalizeState(_ raw: String) -> TraceThreadState? {
        switch raw.uppercased() {
        case "RUNNING": return .running
        case "R", "R+", "RUNNABLE", "READY": return .runnable
        case "S", "SLEEPING", "SLEEP": return .sleeping
        case "D", "BLOCKED", "UNINTERRUPTIBLE": return .blocked
        case "T", "STOPPED": return .stopped
        default: return nil
        }
    }

    private static func normalizedStatePredicate(
        _ state: TraceThreadState,
        column: String
    ) -> String {
        switch state {
        case .running: return "UPPER(\(column)) IN ('RUNNING')"
        case .runnable: return "UPPER(\(column)) IN ('R', 'R+', 'RUNNABLE', 'READY')"
        case .sleeping: return "UPPER(\(column)) IN ('S', 'SLEEPING', 'SLEEP')"
        case .blocked: return "UPPER(\(column)) IN ('D', 'BLOCKED', 'UNINTERRUPTIBLE')"
        case .stopped: return "UPPER(\(column)) IN ('T', 'STOPPED')"
        }
    }

    private func absoluteRange(
        _ relativeRange: TraceTimeRange,
        inclusiveEnd: Bool = false
    ) throws -> (start: Int64, end: Int64) {
        let (start, startOverflow) = validation.traceStartTs.addingReportingOverflow(
            relativeRange.startNs
        )
        var (end, endOverflow) = validation.traceStartTs.addingReportingOverflow(
            relativeRange.endNs
        )
        if inclusiveEnd, !endOverflow, end != Int64.max {
            // Whole-trace window: half-open predicates then cover events at
            // exactly trace_range.end_ts via end_ts + 1 (AT-AN-001), while
            // caller-supplied ranges keep AT-TIME-004 half-open semantics.
            let bumped = end.addingReportingOverflow(1)
            end = bumped.partialValue
            endOverflow = bumped.overflow
        }
        guard !startOverflow, !endOverflow,
            start >= validation.traceStartTs,
            (inclusiveEnd ? end - 1 : end) <= validation.traceEndTs
        else {
            throw ArkTraceError(
                code: .traceDatabaseInvalid,
                stage: .querying,
                message: "Summary range cannot be represented in database time"
            )
        }
        return (start, end)
    }

    private func boundedEventCount(
        table: String,
        range: (start: Int64, end: Int64),
        includesFinalTimestamp: Bool,
        limit: Int,
        deadline: ContinuousClock.Instant
    ) throws -> TraceBoundedCount {
        guard TraceDatabase.isSafeIdentifier(table) else {
            throw ArkTraceError(
                code: .traceSchemaUnsupported,
                stage: .querying,
                message: "Summary event table is unsupported"
            )
        }
        // SQLite evaluates the shared intersection predicate, so `limit` bounds
        // the number of matches instead of the length of the scanned rowid
        // prefix. The previous prefix sampling reported zero events for every
        // range that lies past the first `limit` rows of the table, which is
        // indistinguishable from a genuinely empty range (AT-AN-001,
        // AT-JSON-005).
        var predicate = TraceEventIntersection.sqlPredicate()
        var bindings = TraceEventIntersection.bindings(
            queryStart: range.start,
            queryEnd: range.end,
            traceEnd: validation.traceEndTs
        )
        if includesFinalTimestamp {
            // Saturated trace end: the exclusive bound could not be bumped past
            // Int64.max, so admit that final timestamp explicitly.
            predicate = "(\(predicate)) OR (typeof(ts) = 'integer' AND ts = ?)"
            bindings.append(.int64(range.end))
        }
        bindings.append(.int64(Int64(limit) + 1))
        let rows = try db.query(
            """
            SELECT COUNT(*) FROM (
                SELECT 1 FROM \(table)
                WHERE \(predicate)
                LIMIT ?
            )
            """,
            bindings: bindings,
            stage: .querying,
            observesTaskCancellation: true,
            deadline: deadline
        ) { $0.int64(0) }
        try checkQueryBoundary(deadline)
        guard let matched = rows.first ?? nil, matched >= 0 else {
            throw ArkTraceError(
                code: .queryFailed,
                stage: .querying,
                message: "Trace count query returned an invalid value"
            )
        }
        return TraceBoundedCount(
            value: min(matched, Int64(limit)),
            truncated: matched > Int64(limit)
        )
    }

    /// Whole-trace exclusive end bound: `trace_range.end_ts + 1`, saturating
    /// so a pathological end at `Int64.max` degrades to the old bound rather
    /// than trapping.
    private var wholeTraceInclusiveEnd: Int64 {
        validation.traceEndTs == Int64.max
            ? validation.traceEndTs
            : validation.traceEndTs + 1
    }

    private func boundedDistinctCPUCount(
        limit: Int,
        deadline: ContinuousClock.Instant
    ) throws -> TraceBoundedCount {
        // CPU discovery covers the whole trace, including the slice that
        // defines trace_range.end_ts, so the window end is inclusive
        // (see absoluteRange(_:inclusiveEnd:)). SQLite performs the DISTINCT
        // reduction against `arktrace_v3_sched_slice_cpu_ts_dur`, so `limit`
        // bounds distinct CPUs rather than the scanned rowid prefix.
        var bindings = TraceEventIntersection.bindings(
            queryStart: validation.traceStartTs,
            queryEnd: wholeTraceInclusiveEnd,
            traceEnd: validation.traceEndTs
        )
        bindings.append(.int64(Int64(limit) + 1))
        let rows = try db.query(
            """
            SELECT COUNT(*) FROM (
                SELECT DISTINCT cpu FROM sched_slice
                WHERE typeof(cpu) = 'integer'
                    AND \(TraceEventIntersection.sqlPredicate())
                LIMIT ?
            )
            """,
            bindings: bindings,
            stage: .querying,
            observesTaskCancellation: true,
            deadline: deadline
        ) { $0.int64(0) }
        try checkQueryBoundary(deadline)
        guard let distinct = rows.first ?? nil, distinct >= 0 else {
            throw ArkTraceError(
                code: .queryFailed,
                stage: .querying,
                message: "Trace count query returned an invalid value"
            )
        }
        return TraceBoundedCount(
            value: min(distinct, Int64(limit)),
            truncated: distinct > Int64(limit)
        )
    }

    private func boundedDirectoryCount(
        table: String,
        identityColumn: String,
        hasEndTimestamp: Bool,
        range: (start: Int64, end: Int64),
        includesFinalTimestamp: Bool,
        limit: Int,
        deadline: ContinuousClock.Instant
    ) throws -> DirectorySummary {
        let endSelection = hasEndTimestamp ? ", end_ts" : ", NULL"
        let order = try db.boundedSamplingOrderClause(of: table, deadline: deadline)
        let rows = try db.query(
            """
            SELECT \(identityColumn), start_ts\(endSelection) FROM \(table)
            \(order) LIMIT ?
            """,
            bindings: [.int64(Int64(limit) + 1)],
            stage: .querying,
            observesTaskCancellation: true,
            deadline: deadline
        ) { row in
            DirectorySample(
                identity: row.int64(0),
                start: row.int64(1),
                startIsNull: row.isNull(1),
                end: row.int64(2),
                endIsNull: row.isNull(2)
            )
        }
        var count: Int64 = 0
        let tailUnchecked = rows.count > limit
        var invalidSampled: Int64 = 0
        var unknownStartSampled: Int64 = 0
        for (index, row) in rows.prefix(limit).enumerated() {
            if index.isMultiple(of: 1_024) { try checkQueryBoundary(deadline) }
            guard let identity = row.identity else {
                throw Self.invalidIdentity(table: table)
            }
            if identity == 0 { continue }
            // A SQL NULL start_ts is the upstream representation of "this
            // process/thread already existed when capture began" (DESIGN
            // section 7.1), not corrupt data. The pinned exporter writes NULL
            // for every kernel-discovered row, so treating it as invalid used
            // to report processCount/threadCount as 0 for real traces.
            // Only an incompatible storage class is a genuine anomaly.
            let startNs: Int64?
            if let value = row.start {
                startNs = value
            } else if row.startIsNull {
                startNs = nil
                unknownStartSampled += 1
            } else {
                invalidSampled += 1
                continue
            }
            let endsAfterRangeStart: Bool
            if hasEndTimestamp {
                if let end = row.end {
                    if let startNs, end <= startNs {
                        invalidSampled += 1
                        continue
                    }
                    endsAfterRangeStart = end > range.start
                } else if row.endIsNull {
                    endsAfterRangeStart = true
                } else {
                    invalidSampled += 1
                    continue
                }
            } else {
                endsAfterRangeStart = true
            }
            // An unknown lower bound cannot be excluded by the range's upper
            // bound; the entry may have been alive for the whole window.
            let startsBeforeRangeEnd: Bool
            if let startNs {
                startsBeforeRangeEnd = startNs < range.end
                    || (includesFinalTimestamp && startNs == range.end)
            } else {
                startsBeforeRangeEnd = true
            }
            if startsBeforeRangeEnd, endsAfterRangeStart {
                count += 1
            }
        }
        try checkQueryBoundary(deadline)
        return DirectorySummary(
            count: TraceBoundedCount(
                value: count,
                truncated: tailUnchecked || invalidSampled > 0
            ),
            tailUnchecked: tailUnchecked,
            invalidSampled: invalidSampled,
            unknownStartSampled: unknownStartSampled
        )
    }

    private func boundedCounterSeriesCount(
        range: (start: Int64, end: Int64),
        includesFinalTimestamp: Bool,
        limit: Int,
        deadline: ContinuousClock.Instant
    ) throws -> TraceBoundedCount? {
        guard validation.capabilities.cpuCounters
            || validation.capabilities.processCounters
        else { return nil }
        // Counter detail and this count must agree on interval intersection,
        // so both go through `counterTimeFilter`. Pushing it into SQL keeps
        // `limit` a bound on distinct matching series rather than on the
        // scanned rowid prefix.
        let timeFilter = counterTimeFilter(range: range)
        var timePredicate = "(\(timeFilter.predicate))"
        var bindings = timeFilter.bindings
        if includesFinalTimestamp {
            timePredicate = "(\(timePredicate) OR (typeof(m.ts) = 'integer' AND m.ts = ?))"
            bindings.append(.int64(range.end))
        }
        bindings.append(.int64(Int64(limit) + 1))
        let sampledFilterIDs = try db.query(
            """
            SELECT DISTINCT m.filter_id FROM measure AS m
            WHERE typeof(m.filter_id) = 'integer' AND \(timePredicate)
            ORDER BY m.filter_id ASC
            LIMIT ?
            """,
            bindings: bindings,
            stage: .querying,
            observesTaskCancellation: true,
            deadline: deadline
        ) { $0.int64(0) }
        var filterSets: [(source: Int64, ids: Set<Int64>)] = []
        var incomplete = sampledFilterIDs.count > limit
        if validation.capabilities.cpuCounters {
            let sample = try boundedFilterIDs(
                table: "cpu_measure_filter", limit: limit, deadline: deadline
            )
            filterSets.append((0, sample.ids))
            incomplete = incomplete || sample.incomplete
        }
        if validation.capabilities.processCounters {
            let sample = try boundedFilterIDs(
                table: "process_measure_filter", limit: limit, deadline: deadline
            )
            filterSets.append((1, sample.ids))
            incomplete = incomplete || sample.incomplete
        }
        var series: Set<CounterSeriesIdentity> = []
        for (index, sample) in sampledFilterIDs.prefix(limit).enumerated() {
            if index.isMultiple(of: 1_024) { try checkQueryBoundary(deadline) }
            guard let filterID = sample else {
                incomplete = true
                continue
            }
            for filter in filterSets where filter.ids.contains(filterID) {
                series.insert(CounterSeriesIdentity(source: filter.source, series: filterID))
            }
        }
        try checkQueryBoundary(deadline)
        return TraceBoundedCount(
            value: Int64(series.count),
            truncated: incomplete
        )
    }

    private func boundedFilterIDs(
        table: String,
        limit: Int,
        deadline: ContinuousClock.Instant
    ) throws -> (ids: Set<Int64>, incomplete: Bool) {
        let order = try db.boundedSamplingOrderClause(of: table, deadline: deadline)
        let rows = try db.query(
            "SELECT id FROM \(table) \(order) LIMIT ?",
            bindings: [.int64(Int64(limit) + 1)],
            stage: .querying,
            observesTaskCancellation: true,
            deadline: deadline
        ) { $0.int64(0) }
        var ids: Set<Int64> = []
        var incomplete = rows.count > limit
        for (index, value) in rows.prefix(limit).enumerated() {
            if index.isMultiple(of: 1_024) { try checkQueryBoundary(deadline) }
            if let value { ids.insert(value) } else { incomplete = true }
        }
        try checkQueryBoundary(deadline)
        return (ids, incomplete)
    }

    private func boundedEventSourceCounts(
        limit: Int,
        deadline: ContinuousClock.Instant
    ) throws -> EventSourceSummary {
        let order = try db.boundedSamplingOrderClause(of: "stat", deadline: deadline)
        let rows = try db.query(
            """
            SELECT
                CASE WHEN typeof(source) = 'text'
                    AND length(CAST(source AS BLOB)) BETWEEN 1 AND 256
                    THEN source ELSE NULL END,
                CASE WHEN typeof(event_name) = 'text'
                    AND length(CAST(event_name AS BLOB)) <= 256
                    THEN event_name ELSE NULL END,
                count,
                CASE WHEN typeof(stat_type) = 'text' THEN 1 ELSE 0 END,
                CASE WHEN typeof(stat_type) = 'text' AND stat_type = 'received'
                    THEN 1 ELSE 0 END
            FROM stat \(order) LIMIT ?
            """,
            bindings: [.int64(Int64(limit) + 1)],
            stage: .querying,
            observesTaskCancellation: true,
            deadline: deadline
        ) { row in
            StatSample(
                sourceBytes: row.textBytes(0),
                eventNameValid: row.textBytes(1) != nil,
                count: row.int64(2),
                statTypeValid: row.int64(3) == 1,
                received: row.int64(4) == 1
            )
        }
        var totals: [Data: Int64] = [:]
        var sourceStrings: [Data: String] = [:]
        var incomplete = rows.count > limit
        var invalidUTF8Count: Int64 = 0
        for (index, row) in rows.prefix(limit).enumerated() {
            if index.isMultiple(of: 1_024) { try checkQueryBoundary(deadline) }
            guard row.statTypeValid else {
                incomplete = true
                continue
            }
            guard row.received else { continue }
            guard let sourceBytes = row.sourceBytes,
                row.eventNameValid,
                let count = row.count,
                count >= 0
            else {
                incomplete = true
                continue
            }
            guard let source = String(data: sourceBytes, encoding: .utf8) else {
                incomplete = true
                invalidUTF8Count += 1
                continue
            }
            let (total, overflow) = (totals[sourceBytes] ?? 0).addingReportingOverflow(count)
            guard !overflow else {
                throw ArkTraceError(
                    code: .queryFailed,
                    stage: .querying,
                    message: "Trace stat count cannot be represented"
                )
            }
            totals[sourceBytes] = total
            sourceStrings[sourceBytes] = source
        }
        try checkQueryBoundary(deadline)
        let orderedSources = try stableSortedDataKeys(
            Array(totals.keys), deadline: deadline
        )
        var items: [TraceEventSourceCount] = []
        items.reserveCapacity(orderedSources.count)
        for (index, sourceBytes) in orderedSources.enumerated() {
            if index.isMultiple(of: 1_024) { try checkQueryBoundary(deadline) }
            items.append(
                TraceEventSourceCount(
                    source: sourceStrings[sourceBytes]!, count: totals[sourceBytes]!
                )
            )
        }
        try checkQueryBoundary(deadline)
        return EventSourceSummary(
            counts: TraceEventSourceCounts(items: items, truncated: incomplete),
            qualityIssues: invalidUTF8Count > 0
                ? [
                    TraceDataQualityIssue(
                        category: .invalidValue,
                        scope: "stat.source",
                        count: invalidUTF8Count,
                        message: "stat.source: \(invalidUTF8Count) sampled invalid UTF-8 value(s) excluded from event counts"
                    )
                ] : []
        )
    }

    private func stableSortedDataKeys(
        _ values: [Data],
        deadline: ContinuousClock.Instant
    ) throws -> [Data] {
        guard values.count > 1 else { return values }
        var source = values
        var destination = values
        var width = 1
        var operations = 0
        while width < source.count {
            var lower = 0
            while lower < source.count {
                let middle = min(lower + width, source.count)
                let upper = min(lower + width + width, source.count)
                var left = lower
                var right = middle
                var output = lower
                while left < middle || right < upper {
                    if right >= upper || (left < middle
                        && source[left].lexicographicallyPrecedes(source[right]))
                    {
                        destination[output] = source[left]
                        left += 1
                    } else {
                        destination[output] = source[right]
                        right += 1
                    }
                    output += 1
                    operations += 1
                    if operations.isMultiple(of: 1_024) {
                        try checkQueryBoundary(deadline)
                    }
                }
                lower = upper
            }
            swap(&source, &destination)
            width = width > source.count / 2 ? source.count : width * 2
            try checkQueryBoundary(deadline)
        }
        return source
    }

    private func boundedCount(_ raw: Int64?, limit: Int) throws -> TraceBoundedCount {
        guard let raw, raw >= 0 else {
            throw ArkTraceError(
                code: .queryFailed,
                stage: .querying,
                message: "Trace count query returned an invalid value"
            )
        }
        return TraceBoundedCount(
            value: min(raw, Int64(limit)),
            truncated: raw > Int64(limit)
        )
    }

    private func checkQueryBoundary(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw ArkTraceError(
                code: .queryTimeout,
                stage: .querying,
                message: "Trace query deadline was reached",
                retryable: true
            )
        }
    }

    private struct CounterSeriesIdentity: Hashable {
        let source: Int64
        let series: Int64
    }

    private struct EventRow {
        let id: Int64?
        let timestamp: Int64?
        let duration: Int64?
        let durationIsNull: Bool
        let number: Int64?
        let processKey: Int64?
        let threadKey: Int64?
        let pid: Int64?
        let tid: Int64?
        let text: String?
        let secondaryText: String?
        let tertiaryText: String?
        let auxiliaryText: String?
        let depth: Int64?
        let auxiliaryNumber: Int64?
        let parentID: Int64?
        let isAsync: Bool
        let missingProcess: Bool
        let missingThread: Bool
        let invalidOptionalValueCount: Int64
    }

    private struct EventInterval {
        let start: Int64
        let end: Int64
        let openEnded: Bool
    }

    private struct EventQuality {
        var invalidNumeric: Int64 = 0
        var invalidText: Int64 = 0
        var invalidTime: Int64 = 0
        var clampedTimestamp: Int64 = 0
        var clampedDuration: Int64 = 0
        var missingReference: Int64 = 0
        var unknownState: Int64 = 0
        var schedulingOverlap: Int64 = 0
    }

    private struct CounterResultRow {
        let rowID: Int64
        let timestamp: Int64
        let value: Int64
        let filterID: Int64
        let name: String
        let scopeID: Int64
        let sourceOrder: Int64
        let duration: Int64?
        let durationState: CounterDurationState
        let unit: String?
        let invalidOptionalValueCount: Int64
        let pid: Int64?
        let processName: String?
        let missingProcessReferenceCount: Int64
    }

    private enum CounterDurationState: Int64 {
        /// Optional column is absent; counter samples are instants.
        case absent = 0
        /// SQL NULL is the AT-TIME-005 open-ended sentinel.
        case null = 1
        case integer = 2
        case invalid = 3
    }

    private struct CounterSeriesKey: Hashable {
        let sourceOrder: Int64
        let filterID: Int64
        let scopeID: Int64
    }

    private struct DirectorySample {
        let identity: Int64?
        let start: Int64?
        let startIsNull: Bool
        let end: Int64?
        let endIsNull: Bool
    }

    private struct DirectorySummary {
        let count: TraceBoundedCount
        /// `true` means limit+1 proved that rows beyond the inspected prefix
        /// exist; it does not imply any sampled row is malformed.
        let tailUnchecked: Bool
        /// Number of sampled rows whose lifecycle cannot be interpreted.
        /// This is distinct from an unchecked tail so machine output can
        /// classify real data anomalies without parsing human messages.
        let invalidSampled: Int64
        /// Number of counted rows whose `start_ts` is SQL NULL. These are
        /// retained (an unknown lower bound cannot exclude the entry) but the
        /// range scoping of the count is weaker for them, so the fact is
        /// reported as a typed unavailable value rather than hidden.
        let unknownStartSampled: Int64
    }

    private struct StatSample {
        let sourceBytes: Data?
        let eventNameValid: Bool
        let count: Int64?
        let statTypeValid: Bool
        let received: Bool
    }

    private struct EventSourceSummary {
        let counts: TraceEventSourceCounts
        let qualityIssues: [TraceDataQualityIssue]
    }

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

    private func page<T>(
        _ rows: [T],
        limit: Int,
        issues: [TraceDataQualityIssue] = []
    ) -> BoundedPage<T> {
        BoundedPage(
            items: Array(rows.prefix(limit)),
            truncated: rows.count > limit,
            dataQualityIssues: issues
        )
    }

    /// Directory name columns carry untrusted TEXT: a non-NULL value that is
    /// empty, exceeds the machine contract's 4096-byte bound, or is not
    /// decodable text (BLOB storage, invalid UTF-8) becomes `nil` plus a
    /// typed invalidValue issue — never a silent null and never a page abort
    /// at the presentation boundary (AT-QUERY-008).
    private static func boundedDirectoryName(
        _ row: TraceDatabase.Row,
        _ index: Int32,
        invalidCount: inout Int64
    ) -> String? {
        if row.isNull(index) { return nil }
        guard let name = row.text(index), !name.isEmpty, name.utf8.count <= 4_096
        else {
            invalidCount += 1
            return nil
        }
        return name
    }

    /// Typed lifecycle evidence for one directory count. The three signals are
    /// deliberately distinct: an unchecked tail bounds the count, an
    /// incompatible storage class is a real anomaly, and a NULL `start_ts`
    /// only weakens range scoping for rows that are still counted.
    private static func directoryLifecycleIssues(
        table: String,
        countField: String,
        summary: DirectorySummary
    ) -> [TraceDataQualityIssue] {
        var issues: [TraceDataQualityIssue] = []
        if summary.tailUnchecked {
            issues.append(
                TraceDataQualityIssue(
                    category: .probeTruncated,
                    scope: "\(table).lifecycle",
                    message: "\(table) lifecycle: probe tail was not inspected; \(countField) is a lower bound"
                )
            )
        }
        if summary.invalidSampled > 0 {
            issues.append(
                TraceDataQualityIssue(
                    category: .invalidValue,
                    scope: "\(table).lifecycle",
                    count: summary.invalidSampled,
                    message: "\(table) lifecycle: invalid sampled value(s) excluded; \(countField) is a lower bound"
                )
            )
        }
        if summary.unknownStartSampled > 0 {
            issues.append(
                TraceDataQualityIssue(
                    category: .unavailableValue,
                    scope: "\(table).start_ts",
                    count: summary.unknownStartSampled,
                    message: "\(table).start_ts: \(summary.unknownStartSampled) sampled row(s) have no start timestamp; they are counted but cannot be excluded by the requested range"
                )
            )
        }
        return issues
    }

    private static func directoryPageIssues(
        prefix: String,
        invalidNames: [(scope: String, count: Int64)],
        invalidLifecycles: Int64
    ) -> [TraceDataQualityIssue] {
        var issues: [TraceDataQualityIssue] = []
        for entry in invalidNames where entry.count > 0 {
            issues.append(
                TraceDataQualityIssue(
                    category: .invalidValue,
                    scope: entry.scope,
                    count: entry.count,
                    message: "\(entry.scope): invalid or unrepresentable value(s) reported as unknown"
                )
            )
        }
        if invalidLifecycles > 0 {
            issues.append(
                TraceDataQualityIssue(
                    category: .invalidValue,
                    scope: "\(prefix).lifecycle",
                    count: invalidLifecycles,
                    message: "\(prefix) lifecycle: inverted range(s); end reported as unknown"
                )
            )
        }
        return issues
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
