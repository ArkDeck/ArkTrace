/// Bounded directory page: repositories never return unbounded lists (AT-DB-007).
/// Truncation is detected with limit+1 (AT-QUERY-002).
public struct BoundedPage<Element: Sendable>: Sendable {
    public let items: [Element]
    public let truncated: Bool

    public init(items: [Element], truncated: Bool) {
        self.items = items
        self.truncated = truncated
    }
}

public struct ProcessQuery: Sendable {
    public let pid: Int64?
    public let name: String?
    public let limit: Int

    public init(pid: Int64? = nil, name: String? = nil, limit: Int = 10_000) throws {
        guard limit >= 1, limit <= 100_000 else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "limit must be within 1...100000, got \(limit)"
            )
        }
        self.pid = pid
        self.name = name
        self.limit = limit
    }
}

public struct ThreadQuery: Sendable {
    public let processKey: ProcessKey?
    public let pid: Int64?
    public let threadKey: ThreadKey?
    public let tid: Int64?
    public let name: String?
    public let limit: Int

    public init(
        processKey: ProcessKey? = nil,
        pid: Int64? = nil,
        threadKey: ThreadKey? = nil,
        tid: Int64? = nil,
        name: String? = nil,
        limit: Int = 10_000
    ) throws {
        guard limit >= 1, limit <= 100_000 else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "limit must be within 1...100000, got \(limit)"
            )
        }
        self.processKey = processKey
        self.pid = pid
        self.threadKey = threadKey
        self.tid = tid
        self.name = name
        self.limit = limit
    }
}

/// Deadline- and row-bounded request for deterministic summary facts.
/// The Store validates the range against trace duration and binds every
/// boundary/limit into prepared SQL (AT-AN-001, AT-DB-006/008).
public struct TraceSummaryQuery: Sendable {
    public let range: TraceTimeRange?
    public let maximumRowsPerSection: Int
    public let deadline: ContinuousClock.Instant

    public init(
        range: TraceTimeRange? = nil,
        maximumRowsPerSection: Int = 100_000,
        deadline: ContinuousClock.Instant
    ) throws {
        guard maximumRowsPerSection >= 1, maximumRowsPerSection <= 1_000_000 else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "maximumRowsPerSection must be within 1...1000000"
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
        self.deadline = deadline
    }
}

/// A count may be a deterministic lower bound when the caller's row budget
/// was reached. Consumers must surface `truncated`; they must not present a
/// bounded lower bound as an exact count.
public struct TraceBoundedCount: Hashable, Codable, Sendable {
    public let value: Int64
    public let truncated: Bool

    public init(value: Int64, truncated: Bool) {
        self.value = value
        self.truncated = truncated
    }
}

public struct TraceEventSourceCount: Hashable, Codable, Sendable {
    public let source: String
    public let count: Int64

    public init(source: String, count: Int64) {
        self.source = source
        self.count = count
    }
}

public struct TraceEventSourceCounts: Hashable, Codable, Sendable {
    public let items: [TraceEventSourceCount]
    public let truncated: Bool

    public init(items: [TraceEventSourceCount], truncated: Bool) {
        self.items = items
        self.truncated = truncated
    }
}

/// Store-level evidence consumed by ArkTraceAnalysis. Optional event sections
/// mean unsupported capability, never a guessed zero (AT-JSON-004).
public struct TraceSummaryFacts: Hashable, Codable, Sendable {
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
public protocol TraceRepositoryProtocol: Sendable {
    func metadata() async throws -> TraceMetadata
    func processes(_ query: ProcessQuery) async throws -> BoundedPage<TraceProcess>
    func threads(_ query: ThreadQuery) async throws -> BoundedPage<TraceThread>
    func summaryFacts(_ query: TraceSummaryQuery) async throws -> TraceSummaryFacts
}
