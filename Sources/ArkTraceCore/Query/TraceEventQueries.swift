private enum TraceEventQueryValidation {
    static func limit(_ value: Int) throws {
        guard (1...100_000).contains(value) else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "limit must be within 1...100000"
            )
        }
    }

    static func range(_ value: TraceTimeRange) throws {
        guard value.startNs < value.endNs else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Event query range must be non-empty"
            )
        }
    }
}

package struct CpuSliceQuery: Sendable {
    public let range: TraceTimeRange
    public let cpu: Int64?
    public let processKey: ProcessKey?
    public let pid: Int64?
    public let threadKey: ThreadKey?
    public let tid: Int64?
    public let limit: Int
    public let deadline: ContinuousClock.Instant

    public init(
        range: TraceTimeRange,
        cpu: Int64? = nil,
        processKey: ProcessKey? = nil,
        pid: Int64? = nil,
        threadKey: ThreadKey? = nil,
        tid: Int64? = nil,
        limit: Int = 10_000,
        deadline: ContinuousClock.Instant
    ) throws {
        try TraceEventQueryValidation.range(range)
        try TraceEventQueryValidation.limit(limit)
        self.range = range
        self.cpu = cpu
        self.processKey = processKey
        self.pid = pid
        self.threadKey = threadKey
        self.tid = tid
        self.limit = limit
        self.deadline = deadline
    }
}

package struct ThreadStateQuery: Sendable {
    public let range: TraceTimeRange
    public let cpu: Int64?
    public let processKey: ProcessKey?
    public let pid: Int64?
    public let threadKey: ThreadKey?
    public let tid: Int64?
    public let rawState: String?
    public let state: TraceThreadState?
    public let limit: Int
    public let deadline: ContinuousClock.Instant

    public init(
        range: TraceTimeRange,
        cpu: Int64? = nil,
        processKey: ProcessKey? = nil,
        pid: Int64? = nil,
        threadKey: ThreadKey? = nil,
        tid: Int64? = nil,
        rawState: String? = nil,
        state: TraceThreadState? = nil,
        limit: Int = 10_000,
        deadline: ContinuousClock.Instant
    ) throws {
        try TraceEventQueryValidation.range(range)
        try TraceEventQueryValidation.limit(limit)
        if let rawState, rawState.utf8.count > 256 {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "rawState exceeds 256 UTF-8 bytes"
            )
        }
        self.range = range
        self.cpu = cpu
        self.processKey = processKey
        self.pid = pid
        self.threadKey = threadKey
        self.tid = tid
        self.rawState = rawState
        self.state = state
        self.limit = limit
        self.deadline = deadline
    }
}

package enum TraceSliceNameFilter: Hashable, Sendable {
    case exact(String)
    case prefix(String)
    case contains(String)
}

package struct TraceSliceQuery: Sendable {
    public let range: TraceTimeRange
    public let eventKey: EventKey?
    public let processKey: ProcessKey?
    public let pid: Int64?
    public let threadKey: ThreadKey?
    public let tid: Int64?
    public let name: TraceSliceNameFilter?
    public let minimumDurationNs: Int64?
    public let depth: Int64?
    /// Whether the result carries `TraceSlice.argSetID`.
    ///
    /// Off by default because it is the difference between a covering-index
    /// plan and a table lookup per row: no ArkTrace index covers
    /// `callstack.argsetid`, so selecting it turns the viewport's hottest query
    /// into `SEARCH … USING INDEX` and costs measurably on a real trace
    /// (medium fixture: 3.09 → 3.72 ms p95). The one caller that needs the id
    /// asks for a single already-selected slice, where the extra lookup is one
    /// row (DESIGN §14.2.4).
    public let includesArgumentSet: Bool
    public let limit: Int
    public let deadline: ContinuousClock.Instant

    public init(
        range: TraceTimeRange,
        eventKey: EventKey? = nil,
        processKey: ProcessKey? = nil,
        pid: Int64? = nil,
        threadKey: ThreadKey? = nil,
        tid: Int64? = nil,
        name: TraceSliceNameFilter? = nil,
        minimumDurationNs: Int64? = nil,
        depth: Int64? = nil,
        includesArgumentSet: Bool = false,
        limit: Int = 10_000,
        deadline: ContinuousClock.Instant
    ) throws {
        try TraceEventQueryValidation.range(range)
        try TraceEventQueryValidation.limit(limit)
        if let eventKey, eventKey.table != .callstack {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Named-slice event key uses the wrong table"
            )
        }
        if let minimumDurationNs, minimumDurationNs < 0 {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "minimumDurationNs must be non-negative"
            )
        }
        if let depth, depth < 0 {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "depth must be non-negative"
            )
        }
        if let name {
            let value: String
            switch name {
            case .exact(let text), .prefix(let text), .contains(let text): value = text
            }
            guard value.utf8.count <= 4_096 else {
                throw ArkTraceError(
                    code: .invalidArgument,
                    stage: .request,
                    message: "slice name filter exceeds 4096 UTF-8 bytes"
                )
            }
        }
        self.range = range
        self.eventKey = eventKey
        self.processKey = processKey
        self.pid = pid
        self.threadKey = threadKey
        self.tid = tid
        self.name = name
        self.minimumDurationNs = minimumDurationNs
        self.depth = depth
        self.includesArgumentSet = includesArgumentSet
        self.limit = limit
        self.deadline = deadline
    }
}

/// Enumerates the counter series a trace contains, bounded like every other
/// directory query (AT-DB-007). Separate from `CounterQuery` because it is
/// bounded by *series*, not by samples: one series with a million samples must
/// not be able to hide the others.
package struct CounterSeriesQuery: Sendable {
    public let range: TraceTimeRange
    public let limit: Int
    public let deadline: ContinuousClock.Instant

    public init(
        range: TraceTimeRange,
        limit: Int = 1_000,
        deadline: ContinuousClock.Instant
    ) throws {
        try TraceEventQueryValidation.range(range)
        try TraceEventQueryValidation.limit(limit)
        self.range = range
        self.limit = limit
        self.deadline = deadline
    }
}

package struct CounterQuery: Sendable {
    public let range: TraceTimeRange
    public let filterID: Int64?
    public let cpu: Int64?
    public let processKey: ProcessKey?
    public let pid: Int64?
    public let name: CounterNameFilter?
    public let limit: Int
    public let deadline: ContinuousClock.Instant

    public init(
        range: TraceTimeRange,
        filterID: Int64? = nil,
        cpu: Int64? = nil,
        processKey: ProcessKey? = nil,
        pid: Int64? = nil,
        name: CounterNameFilter? = nil,
        limit: Int = 10_000,
        deadline: ContinuousClock.Instant
    ) throws {
        try TraceEventQueryValidation.range(range)
        try TraceEventQueryValidation.limit(limit)
        guard cpu == nil || (processKey == nil && pid == nil) else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Counter query accepts one scope at a time"
            )
        }
        if let name {
            let text: String
            switch name {
            case .exact(let value), .prefix(let value), .contains(let value): text = value
            }
            guard !text.isEmpty, text.utf8.count <= 256 else {
                throw ArkTraceError(
                    code: .invalidArgument,
                    stage: .request,
                    message: "counter name filter must be 1...256 UTF-8 bytes"
                )
            }
        }
        self.range = range
        self.filterID = filterID
        self.cpu = cpu
        self.processKey = processKey
        self.pid = pid
        self.name = name
        self.limit = limit
        self.deadline = deadline
    }
}

package enum CounterNameFilter: Hashable, Sendable {
    case exact(String)
    case prefix(String)
    case contains(String)
}
