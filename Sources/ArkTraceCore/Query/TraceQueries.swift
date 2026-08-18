/// Bounded directory page: repositories never return unbounded lists (AT-DB-007).
/// Truncation is detected with limit+1 (AT-QUERY-002).
package struct BoundedPage<Element: Sendable>: Sendable {
    public let items: [Element]
    public let truncated: Bool
    /// Row-level anomalies (invalid names, inverted lifecycles) surfaced as
    /// typed evidence instead of aborting the page or dropping data silently
    /// (AT-QUERY-008).
    public let dataQualityIssues: [TraceDataQualityIssue]

    public init(
        items: [Element],
        truncated: Bool,
        dataQualityIssues: [TraceDataQualityIssue] = []
    ) {
        self.items = items
        self.truncated = truncated
        self.dataQualityIssues = dataQualityIssues
    }
}

package enum TraceDirectoryNameMatch: String, Codable, Sendable {
    case exact
    case prefix
    case contains
}

package struct ProcessQuery: Sendable {
    public let processKey: ProcessKey?
    public let pid: Int64?
    public let name: String?
    public let nameMatch: TraceDirectoryNameMatch
    public let limit: Int
    public let deadline: ContinuousClock.Instant?

    public init(
        processKey: ProcessKey? = nil,
        pid: Int64? = nil,
        name: String? = nil,
        nameMatch: TraceDirectoryNameMatch = .exact,
        limit: Int = 10_000,
        deadline: ContinuousClock.Instant? = nil
    ) throws {
        guard limit >= 1, limit <= 100_000 else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "limit must be within 1...100000, got \(limit)"
            )
        }
        if let name, name.isEmpty || name.utf8.count > 4_096 {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "process name filter must be 1...4096 UTF-8 bytes"
            )
        }
        self.processKey = processKey
        self.pid = pid
        self.name = name
        self.nameMatch = nameMatch
        self.limit = limit
        self.deadline = deadline
    }
}

package struct ThreadQuery: Sendable {
    public let processKey: ProcessKey?
    public let pid: Int64?
    public let threadKey: ThreadKey?
    public let tid: Int64?
    public let name: String?
    public let nameMatch: TraceDirectoryNameMatch
    public let limit: Int
    public let deadline: ContinuousClock.Instant?

    public init(
        processKey: ProcessKey? = nil,
        pid: Int64? = nil,
        threadKey: ThreadKey? = nil,
        tid: Int64? = nil,
        name: String? = nil,
        nameMatch: TraceDirectoryNameMatch = .exact,
        limit: Int = 10_000,
        deadline: ContinuousClock.Instant? = nil
    ) throws {
        guard limit >= 1, limit <= 100_000 else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "limit must be within 1...100000, got \(limit)"
            )
        }
        if let name, name.isEmpty || name.utf8.count > 4_096 {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "thread name filter must be 1...4096 UTF-8 bytes"
            )
        }
        self.processKey = processKey
        self.pid = pid
        self.threadKey = threadKey
        self.tid = tid
        self.name = name
        self.nameMatch = nameMatch
        self.limit = limit
        self.deadline = deadline
    }
}

/// Deadline- and row-bounded request for deterministic summary facts.
/// The Store validates the range against trace duration and binds every
/// boundary/limit into prepared SQL (AT-AN-001, AT-DB-006/008).
package struct TraceSummaryQuery: Sendable {
    public let range: TraceTimeRange?
    public let maximumRowsPerSection: Int
    public let maximumEventsPerSection: Int
    public let deadline: ContinuousClock.Instant

    public init(
        range: TraceTimeRange? = nil,
        maximumRowsPerSection: Int = 100_000,
        maximumEventsPerSection: Int? = nil,
        deadline: ContinuousClock.Instant
    ) throws {
        guard maximumRowsPerSection >= 1, maximumRowsPerSection <= 1_000_000 else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "maximumRowsPerSection must be within 1...1000000"
            )
        }
        let maximumEventsPerSection = maximumEventsPerSection ?? maximumRowsPerSection
        guard maximumEventsPerSection >= 1, maximumEventsPerSection <= 1_000_000 else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "maximumEventsPerSection must be within 1...1000000"
            )
        }
        if let range, range.startNs >= range.endNs {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Summary range must satisfy startNs < endNs"
            )
        }
        self.range = range
        self.maximumRowsPerSection = maximumRowsPerSection
        self.maximumEventsPerSection = maximumEventsPerSection
        self.deadline = deadline
    }
}

/// A count may be a deterministic lower bound when the caller's row budget
/// was reached. Consumers must surface `truncated`; they must not present a
/// bounded lower bound as an exact count.
package struct TraceBoundedCount: Hashable, Codable, Sendable {
    public let value: Int64
    public let truncated: Bool

    public init(value: Int64, truncated: Bool) {
        self.value = value
        self.truncated = truncated
    }
}

package struct TraceEventSourceCount: Hashable, Codable, Sendable {
    public let source: String
    public let count: Int64

    public init(source: String, count: Int64) {
        self.source = source
        self.count = count
    }
}

package struct TraceEventSourceCounts: Hashable, Codable, Sendable {
    public let items: [TraceEventSourceCount]
    public let truncated: Bool

    public init(items: [TraceEventSourceCount], truncated: Bool) {
        self.items = items
        self.truncated = truncated
    }
}

/// Store-level evidence consumed by ArkTraceAnalysis. Optional event sections
/// mean unsupported capability, never a guessed zero (AT-JSON-004).
package struct TraceSummaryFacts: Hashable, Codable, Sendable {
    public let cpuCount: TraceBoundedCount?
    public let processCount: TraceBoundedCount
    public let threadCount: TraceBoundedCount
    public let cpuSliceCount: TraceBoundedCount?
    public let threadStateCount: TraceBoundedCount?
    public let namedSliceCount: TraceBoundedCount?
    public let counterSeriesCount: TraceBoundedCount?
    public let eventCountBySource: TraceEventSourceCounts?
    /// Query-specific quality evidence, such as lifecycle rows whose overlap
    /// cannot be proven. Analysis merges these with trace-level metadata.
    public let warnings: [String]
    public let qualityIssues: [TraceDataQualityIssue]

    public init(
        cpuCount: TraceBoundedCount?,
        processCount: TraceBoundedCount,
        threadCount: TraceBoundedCount,
        cpuSliceCount: TraceBoundedCount?,
        threadStateCount: TraceBoundedCount?,
        namedSliceCount: TraceBoundedCount?,
        counterSeriesCount: TraceBoundedCount?,
        eventCountBySource: TraceEventSourceCounts?,
        warnings: [String] = [],
        qualityIssues: [TraceDataQualityIssue] = []
    ) {
        self.cpuCount = cpuCount
        self.processCount = processCount
        self.threadCount = threadCount
        self.cpuSliceCount = cpuSliceCount
        self.threadStateCount = threadStateCount
        self.namedSliceCount = namedSliceCount
        self.counterSeriesCount = counterSeriesCount
        self.eventCountBySource = eventCountBySource
        let quality = TraceDataQuality(warnings: warnings, issues: qualityIssues)
        self.warnings = quality.warnings
        self.qualityIssues = quality.issues
    }
}

/// Typed repository boundary shared by App, CLI, and analysis (DESIGN §9.2).
/// Phase 1 scope: metadata and process/thread directories.
package protocol TraceRepositoryProtocol: Sendable {
    func metadata() async throws -> TraceMetadata
    func processes(_ query: ProcessQuery) async throws -> BoundedPage<TraceProcess>
    func threads(_ query: ThreadQuery) async throws -> BoundedPage<TraceThread>
    func summaryFacts(_ query: TraceSummaryQuery) async throws -> TraceSummaryFacts
    func cpuSlices(_ query: CpuSliceQuery) async throws -> TraceEventPage<CpuSlice>
    func threadStates(
        _ query: ThreadStateQuery
    ) async throws -> TraceEventPage<ThreadStateInterval>
    func slices(_ query: TraceSliceQuery) async throws -> TraceEventPage<TraceSlice>
    func arguments(
        _ query: TraceArgumentQuery
    ) async throws -> TraceEventPage<TraceEventArgument>
    func frames(_ query: TraceFrameQuery) async throws -> TraceEventPage<TraceFrame>
    func counters(_ query: CounterQuery) async throws -> TraceEventPage<CounterSeries>
    func counterSeries(
        _ query: CounterSeriesQuery
    ) async throws -> TraceEventPage<CounterSeriesDescriptor>
    func density(_ query: TraceDensityQuery) async throws -> TraceDensityResult
    func eventBatch(_ batch: TraceRepositoryEventBatch) async throws
        -> TraceRepositoryEventBatchResult
}

/// A bounded group of independent, immutable Ready-database reads. The Store
/// may execute these reads concurrently, but every result retains the exact
/// semantics, limit and deadline of its corresponding typed query.
package struct TraceRepositoryEventBatch: Sendable {
    public static let maximumQueryCount = 32

    public let cpuSlices: [CpuSliceQuery]
    public let threadStates: [ThreadStateQuery]
    public let slices: [TraceSliceQuery]
    public let counters: [CounterQuery]
    public let counterSeries: [CounterSeriesQuery]
    public let densities: [TraceDensityQuery]
    public let threads: [ThreadQuery]

    public init(
        cpuSlices: [CpuSliceQuery] = [],
        threadStates: [ThreadStateQuery] = [],
        slices: [TraceSliceQuery] = [],
        counters: [CounterQuery] = [],
        counterSeries: [CounterSeriesQuery] = [],
        densities: [TraceDensityQuery] = [],
        threads: [ThreadQuery] = []
    ) throws {
        let count = cpuSlices.count + threadStates.count + slices.count
            + counters.count + counterSeries.count + densities.count + threads.count
        guard (1...Self.maximumQueryCount).contains(count) else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Repository event batch must contain 1...32 queries"
            )
        }
        self.cpuSlices = cpuSlices
        self.threadStates = threadStates
        self.slices = slices
        self.counters = counters
        self.counterSeries = counterSeries
        self.densities = densities
        self.threads = threads
    }
}

package struct TraceRepositoryEventBatchResult: Sendable {
    public let cpuSlices: [TraceEventPage<CpuSlice>]
    public let threadStates: [TraceEventPage<ThreadStateInterval>]
    public let slices: [TraceEventPage<TraceSlice>]
    public let counters: [TraceEventPage<CounterSeries>]
    public let counterSeries: [TraceEventPage<CounterSeriesDescriptor>]
    public let densities: [TraceDensityResult]
    public let threads: [BoundedPage<TraceThread>]

    public init(
        cpuSlices: [TraceEventPage<CpuSlice>],
        threadStates: [TraceEventPage<ThreadStateInterval>],
        slices: [TraceEventPage<TraceSlice>],
        counters: [TraceEventPage<CounterSeries>],
        counterSeries: [TraceEventPage<CounterSeriesDescriptor>] = [],
        densities: [TraceDensityResult],
        threads: [BoundedPage<TraceThread>] = []
    ) {
        self.cpuSlices = cpuSlices
        self.threadStates = threadStates
        self.slices = slices
        self.counters = counters
        self.counterSeries = counterSeries
        self.densities = densities
        self.threads = threads
    }
}

/// Additive event APIs do not force summary-only adapters to manufacture
/// event data. Production Store overrides every method.
package extension TraceRepositoryProtocol {
    func cpuSlices(_ query: CpuSliceQuery) async throws -> TraceEventPage<CpuSlice> {
        .unavailable
    }

    func threadStates(
        _ query: ThreadStateQuery
    ) async throws -> TraceEventPage<ThreadStateInterval> {
        .unavailable
    }

    func arguments(
        _ query: TraceArgumentQuery
    ) async throws -> TraceEventPage<TraceEventArgument> {
        .unavailable
    }

    func frames(_ query: TraceFrameQuery) async throws -> TraceEventPage<TraceFrame> {
        .unavailable
    }

    func slices(_ query: TraceSliceQuery) async throws -> TraceEventPage<TraceSlice> {
        .unavailable
    }

    func counters(_ query: CounterQuery) async throws -> TraceEventPage<CounterSeries> {
        .unavailable
    }

    func counterSeries(
        _ query: CounterSeriesQuery
    ) async throws -> TraceEventPage<CounterSeriesDescriptor> {
        .unavailable
    }

    func density(_ query: TraceDensityQuery) async throws -> TraceDensityResult {
        .unavailable
    }

    func eventBatch(
        _ batch: TraceRepositoryEventBatch
    ) async throws -> TraceRepositoryEventBatchResult {
        var cpu: [TraceEventPage<CpuSlice>] = []
        var states: [TraceEventPage<ThreadStateInterval>] = []
        var slices: [TraceEventPage<TraceSlice>] = []
        var counters: [TraceEventPage<CounterSeries>] = []
        var counterSeriesPages: [TraceEventPage<CounterSeriesDescriptor>] = []
        var densities: [TraceDensityResult] = []
        var threads: [BoundedPage<TraceThread>] = []
        for query in batch.cpuSlices { cpu.append(try await cpuSlices(query)) }
        for query in batch.threadStates { states.append(try await threadStates(query)) }
        for query in batch.slices { slices.append(try await self.slices(query)) }
        for query in batch.counters { counters.append(try await self.counters(query)) }
        for query in batch.counterSeries {
            counterSeriesPages.append(try await counterSeries(query))
        }
        for query in batch.densities { densities.append(try await density(query)) }
        for query in batch.threads { threads.append(try await self.threads(query)) }
        return TraceRepositoryEventBatchResult(
            cpuSlices: cpu,
            threadStates: states,
            slices: slices,
            counters: counters,
            counterSeries: counterSeriesPages,
            densities: densities,
            threads: threads
        )
    }
}
