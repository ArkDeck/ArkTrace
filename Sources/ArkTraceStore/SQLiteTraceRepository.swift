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
    public nonisolated let databaseFileIdentity: TraceDatabaseFileIdentity
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
        source: TraceSourceDescriptor,
        expectedPreparation: TraceDatabasePreparationResult? = nil
    ) throws {
        let db = try TraceDatabase(url: databaseURL, readOnly: true)
        guard let databaseFileIdentity = db.fileIdentity else {
            throw ArkTraceError(
                code: .traceDatabaseInvalid,
                stage: .openingDatabase,
                message: "Ready database identity is unavailable"
            )
        }
        guard try db.quickCheckIsOK() else {
            throw ArkTraceError(
                code: .traceDatabaseInvalid,
                stage: .validating,
                message: "SQLite quick_check failed"
            )
        }
        let validation = try TraceSchemaAdapter.validate(db)
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

        self.db = db
        self.databaseFileIdentity = databaseFileIdentity
        self.parserIdentity = parser
        self.source = source
        self.validation = validation

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
            dataQuality: validation.dataQuality
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

        let rows = try db.query(
            sql,
            bindings: bindings,
            observesTaskCancellation: true,
            deadline: query.deadline
        ) { row in
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

        let rows = try db.query(
            sql,
            bindings: bindings,
            observesTaskCancellation: true,
            deadline: query.deadline
        ) { row in
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
            relativeRange = try TraceTimeRange.query(
                startNs: 0,
                endNs: validation.durationNs
            )
        }
        let absoluteRange = try absoluteRange(relativeRange)
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
            limit: rowLimit,
            deadline: query.deadline
        )
        let thread = try boundedDirectoryCount(
            table: "thread",
            identityColumn: "itid",
            hasEndTimestamp: threadHasEndTs,
            range: absoluteRange,
            limit: rowLimit,
            deadline: query.deadline
        )
        var qualityIssues: [TraceDataQualityIssue] = []
        if process.tailUnchecked {
            qualityIssues.append(
                TraceDataQualityIssue(
                    category: .probeTruncated,
                    scope: "process.lifecycle",
                    message: "process lifecycle: probe tail was not inspected; processCount is a lower bound"
                )
            )
        }
        if process.invalidSampled > 0 {
            qualityIssues.append(
                TraceDataQualityIssue(
                    category: .invalidValue,
                    scope: "process.lifecycle",
                    count: process.invalidSampled,
                    message: "process lifecycle: invalid or unknown sampled value(s) excluded; processCount is a lower bound"
                )
            )
        }
        if thread.tailUnchecked {
            qualityIssues.append(
                TraceDataQualityIssue(
                    category: .probeTruncated,
                    scope: "thread.lifecycle",
                    message: "thread lifecycle: probe tail was not inspected; threadCount is a lower bound"
                )
            )
        }
        if thread.invalidSampled > 0 {
            qualityIssues.append(
                TraceDataQualityIssue(
                    category: .invalidValue,
                    scope: "thread.lifecycle",
                    count: thread.invalidSampled,
                    message: "thread lifecycle: invalid or unknown sampled value(s) excluded; threadCount is a lower bound"
                )
            )
        }

        let cpuSliceCount = validation.capabilities.cpuScheduling
            ? try boundedEventCount(
                table: "sched_slice",
                range: absoluteRange,
                limit: eventLimit,
                deadline: query.deadline
            ) : nil
        let threadStateCount = validation.capabilities.threadStates
            ? try boundedEventCount(
                table: "thread_state",
                range: absoluteRange,
                limit: eventLimit,
                deadline: query.deadline
            ) : nil
        let namedSliceCount = validation.capabilities.namedSlices
            ? try boundedEventCount(
                table: "callstack",
                range: absoluteRange,
                limit: eventLimit,
                deadline: query.deadline
            ) : nil
        let counterSeriesCount = try boundedCounterSeriesCount(
            range: absoluteRange,
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

    // MARK: - Helpers

    private func absoluteRange(_ relativeRange: TraceTimeRange) throws
        -> (start: Int64, end: Int64)
    {
        let (start, startOverflow) = validation.traceStartTs.addingReportingOverflow(
            relativeRange.startNs
        )
        let (end, endOverflow) = validation.traceStartTs.addingReportingOverflow(
            relativeRange.endNs
        )
        guard !startOverflow, !endOverflow,
            start >= validation.traceStartTs,
            end <= validation.traceEndTs
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
        limit: Int,
        deadline: ContinuousClock.Instant
    ) throws -> TraceBoundedCount {
        let order = try db.boundedSamplingOrderClause(of: table, deadline: deadline)
        let rows = try db.query(
            """
            SELECT ts, dur FROM \(table)
            \(order) LIMIT ?
            """,
            bindings: [.int64(Int64(limit) + 1)],
            stage: .querying,
            observesTaskCancellation: true,
            deadline: deadline
        ) { row in
            EventSample(
                start: row.int64(0),
                duration: row.int64(1),
                durationIsNull: row.isNull(1)
            )
        }
        var count: Int64 = 0
        var incomplete = rows.count > limit
        for (index, row) in rows.prefix(limit).enumerated() {
            if index.isMultiple(of: 1_024) { try checkQueryBoundary(deadline) }
            guard let start = row.start,
                row.duration != nil || row.durationIsNull
            else {
                incomplete = true
                continue
            }
            if TraceEventIntersection.intersects(
                eventStartNs: start,
                durationNs: row.duration,
                queryStartNs: range.start,
                queryEndNs: range.end,
                traceEndNs: validation.traceEndTs
            ) {
                count += 1
            }
        }
        try checkQueryBoundary(deadline)
        return TraceBoundedCount(value: count, truncated: incomplete)
    }

    private func boundedDistinctCPUCount(
        limit: Int,
        deadline: ContinuousClock.Instant
    ) throws -> TraceBoundedCount {
        let order = try db.boundedSamplingOrderClause(of: "sched_slice", deadline: deadline)
        let rows = try db.query(
            """
            SELECT ts, dur, cpu FROM sched_slice
            \(order) LIMIT ?
            """,
            bindings: [.int64(Int64(limit) + 1)],
            stage: .querying,
            observesTaskCancellation: true,
            deadline: deadline
        ) { row in
            (
                EventSample(
                    start: row.int64(0), duration: row.int64(1),
                    durationIsNull: row.isNull(1)
                ),
                row.int64(2)
            )
        }
        var sampled: Set<Int64> = []
        var incomplete = rows.count > limit
        for (index, row) in rows.prefix(limit).enumerated() {
            if index.isMultiple(of: 1_024) { try checkQueryBoundary(deadline) }
            let event = row.0
            guard let start = event.start,
                event.duration != nil || event.durationIsNull,
                let cpu = row.1
            else {
                incomplete = true
                continue
            }
            if TraceEventIntersection.intersects(
                eventStartNs: start,
                durationNs: event.duration,
                queryStartNs: validation.traceStartTs,
                queryEndNs: validation.traceEndTs,
                traceEndNs: validation.traceEndTs
            ) {
                sampled.insert(cpu)
            }
        }
        try checkQueryBoundary(deadline)
        return TraceBoundedCount(
            value: Int64(sampled.count),
            truncated: incomplete
        )
    }

    private func boundedDirectoryCount(
        table: String,
        identityColumn: String,
        hasEndTimestamp: Bool,
        range: (start: Int64, end: Int64),
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
                end: row.int64(2),
                endIsNull: row.isNull(2)
            )
        }
        var count: Int64 = 0
        let tailUnchecked = rows.count > limit
        var invalidSampled: Int64 = 0
        for (index, row) in rows.prefix(limit).enumerated() {
            if index.isMultiple(of: 1_024) { try checkQueryBoundary(deadline) }
            guard row.identity != nil else { throw Self.invalidIdentity(table: table) }
            guard let start = row.start else {
                invalidSampled += 1
                continue
            }
            let endsAfterStart: Bool
            if hasEndTimestamp {
                if let end = row.end {
                    guard end > start else {
                        invalidSampled += 1
                        continue
                    }
                    endsAfterStart = end > range.start
                } else if row.endIsNull {
                    endsAfterStart = true
                } else {
                    invalidSampled += 1
                    continue
                }
            } else {
                endsAfterStart = true
            }
            if start < range.end, endsAfterStart { count += 1 }
        }
        try checkQueryBoundary(deadline)
        return DirectorySummary(
            count: TraceBoundedCount(
                value: count,
                truncated: tailUnchecked || invalidSampled > 0
            ),
            tailUnchecked: tailUnchecked,
            invalidSampled: invalidSampled
        )
    }

    private func boundedCounterSeriesCount(
        range: (start: Int64, end: Int64),
        limit: Int,
        deadline: ContinuousClock.Instant
    ) throws -> TraceBoundedCount? {
        guard validation.capabilities.cpuCounters
            || validation.capabilities.processCounters
        else { return nil }
        let measureOrder = try db.boundedSamplingOrderClause(of: "measure", deadline: deadline)
        let measures = try db.query(
            """
            SELECT ts, filter_id FROM measure
            \(measureOrder) LIMIT ?
            """,
            bindings: [.int64(Int64(limit) + 1)],
            stage: .querying,
            observesTaskCancellation: true,
            deadline: deadline
        ) { row in
            CounterMeasureSample(timestamp: row.int64(0), filterID: row.int64(1))
        }
        var filterSets: [(source: Int64, ids: Set<Int64>)] = []
        var incomplete = measures.count > limit
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
        for (index, sample) in measures.prefix(limit).enumerated() {
            if index.isMultiple(of: 1_024) { try checkQueryBoundary(deadline) }
            guard let timestamp = sample.timestamp, let filterID = sample.filterID else {
                incomplete = true
                continue
            }
            guard timestamp >= range.start, timestamp < range.end else { continue }
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

    private struct EventSample {
        let start: Int64?
        let duration: Int64?
        let durationIsNull: Bool
    }

    private struct DirectorySample {
        let identity: Int64?
        let start: Int64?
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
    }

    private struct CounterMeasureSample {
        let timestamp: Int64?
        let filterID: Int64?
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
