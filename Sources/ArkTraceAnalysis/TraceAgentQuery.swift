import ArkTraceCore
import Foundation

/// Closed, deterministic Agent-facing event query boundary (P4-T01).
///
/// The engine only translates reviewed typed filters into repository query
/// values. It never accepts a table, column, SQL fragment, or expression.
public struct TraceAgentQueryEngine: Sendable {
    private let repository: any TraceRepositoryProtocol

    public init(repository: any TraceRepositoryProtocol) {
        self.repository = repository
    }

    public func query(_ request: TraceAgentQueryRequest) async throws -> TraceAgentQueryResult {
        do {
            return try await TraceAnalysisOperationDeadline.run(
                timeout: request.timeout,
                stage: .querying,
                timeoutMessage: "Agent query deadline was reached"
            ) { deadline in
                try await query(
                    view: request.view,
                    range: request.range,
                    filters: request.filters,
                    limit: request.limit,
                    deadline: deadline
                )
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw ArkTraceError(
                    code: .cancelled,
                    stage: .querying,
                    message: "Agent query was cancelled",
                    retryable: true
                )
            }
            throw error
        }
    }

    /// Internal absolute-deadline entry used by TraceContext so a valid
    /// 100 ms top-level request does not manufacture an invalid sub-request
    /// after some of that same deadline has elapsed.
    func query(
        view: TraceAgentQueryView,
        range: TraceTimeRange,
        filters: TraceAgentQueryFilters,
        limit: Int,
        deadline: ContinuousClock.Instant
    ) async throws -> TraceAgentQueryResult {
            try Self.check(deadline)
            try Self.validateFilters(filters, for: view)
            let metadata = try await repository.metadata()
            try Self.check(deadline)
            guard range.endNs <= metadata.durationNs else {
                throw ArkTraceError(
                    code: .invalidArgument,
                    stage: .request,
                    message: "Agent query range exceeds trace duration"
                )
            }

            switch view {
            case .cpuSlices:
                let page = try await repository.cpuSlices(
                    try CpuSliceQuery(
                        range: range,
                        cpu: filters.cpu,
                        processKey: filters.processKey,
                        pid: filters.pid,
                        threadKey: filters.threadKey,
                        tid: filters.tid,
                        limit: limit,
                        deadline: deadline
                    )
                )
                let sorted = try Self.stableEvents(
                    page.items,
                    start: \CpuSlice.startNs,
                    key: \CpuSlice.key,
                    deadline: deadline
                )
                return try TraceAgentQueryResult(
                    view: view,
                    range: range,
                    filters: filters,
                    capabilityAvailable: page.capabilityAvailable,
                    truncated: page.truncated || sorted.count > limit,
                    dataQuality: Self.quality(metadata.dataQuality, page.dataQuality),
                    cpuSlices: Array(sorted.prefix(limit))
                )

            case .threadStates:
                let page = try await repository.threadStates(
                    try ThreadStateQuery(
                        range: range,
                        cpu: filters.cpu,
                        processKey: filters.processKey,
                        pid: filters.pid,
                        threadKey: filters.threadKey,
                        tid: filters.tid,
                        rawState: filters.rawState,
                        state: filters.normalizedState,
                        limit: limit,
                        deadline: deadline
                    )
                )
                let sorted = try Self.stableEvents(
                    page.items,
                    start: \ThreadStateInterval.startNs,
                    key: \ThreadStateInterval.key,
                    deadline: deadline
                )
                return try TraceAgentQueryResult(
                    view: view,
                    range: range,
                    filters: filters,
                    capabilityAvailable: page.capabilityAvailable,
                    truncated: page.truncated || sorted.count > limit,
                    dataQuality: Self.quality(metadata.dataQuality, page.dataQuality),
                    threadStates: Array(sorted.prefix(limit))
                )

            case .slices:
                let page = try await repository.slices(
                    try TraceSliceQuery(
                        range: range,
                        processKey: filters.processKey,
                        pid: filters.pid,
                        threadKey: filters.threadKey,
                        tid: filters.tid,
                        name: Self.sliceName(filters),
                        minimumDurationNs: filters.minimumDurationNs,
                        depth: filters.depth,
                        limit: limit,
                        deadline: deadline
                    )
                )
                let sorted = try Self.stableEvents(
                    page.items,
                    start: \TraceSlice.startNs,
                    key: \TraceSlice.key,
                    deadline: deadline
                )
                return try TraceAgentQueryResult(
                    view: view,
                    range: range,
                    filters: filters,
                    capabilityAvailable: page.capabilityAvailable,
                    truncated: page.truncated || sorted.count > limit,
                    dataQuality: Self.quality(metadata.dataQuality, page.dataQuality),
                    slices: Array(sorted.prefix(limit))
                )

            case .counters:
                let page = try await repository.counters(
                    try CounterQuery(
                        range: range,
                        filterID: filters.counterFilterID,
                        cpu: filters.cpu,
                        processKey: filters.processKey,
                        pid: filters.pid,
                        name: Self.counterName(filters),
                        limit: limit,
                        deadline: deadline
                    )
                )
                let sorted = try Self.stableCounters(page.items, deadline: deadline)
                try Self.check(deadline)
                return try TraceAgentQueryResult(
                    view: view,
                    range: range,
                    filters: filters,
                    capabilityAvailable: page.capabilityAvailable,
                    truncated: page.truncated || sorted.count > limit,
                    dataQuality: Self.quality(metadata.dataQuality, page.dataQuality),
                    counters: Array(sorted.prefix(limit))
                )
        }
    }

    private static func validateFilters(
        _ filters: TraceAgentQueryFilters,
        for view: TraceAgentQueryView
    ) throws {
        let invalid: Bool
        switch view {
        case .cpuSlices:
            invalid = filters.rawState != nil || filters.normalizedState != nil
                || filters.name != nil || filters.minimumDurationNs != nil
                || filters.depth != nil || filters.counterFilterID != nil
        case .threadStates:
            invalid = filters.name != nil
                || filters.minimumDurationNs != nil || filters.depth != nil
                || filters.counterFilterID != nil
        case .slices:
            invalid = filters.cpu != nil || filters.rawState != nil
                || filters.normalizedState != nil || filters.counterFilterID != nil
        case .counters:
            invalid = filters.threadKey != nil || filters.tid != nil
                || filters.rawState != nil || filters.normalizedState != nil
                || filters.minimumDurationNs != nil || filters.depth != nil
                || (filters.cpu != nil
                    && (filters.processKey != nil || filters.pid != nil))
        }
        guard !invalid else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Agent query filter is not supported by the selected view"
            )
        }
    }

    private static func sliceName(_ filters: TraceAgentQueryFilters) -> TraceSliceNameFilter? {
        guard let name = filters.name else { return nil }
        switch filters.nameMatch {
        case .exact: return .exact(name)
        case .prefix: return .prefix(name)
        case .contains: return .contains(name)
        }
    }

    private static func counterName(_ filters: TraceAgentQueryFilters) -> CounterNameFilter? {
        guard let name = filters.name else { return nil }
        switch filters.nameMatch {
        case .exact: return .exact(name)
        case .prefix: return .prefix(name)
        case .contains: return .contains(name)
        }
    }

    private static func stableEvents<Element>(
        _ items: [Element],
        start: KeyPath<Element, Int64>,
        key: KeyPath<Element, EventKey>,
        deadline: ContinuousClock.Instant
    ) throws -> [Element] {
        try check(deadline)
        let sorted = items.sorted { lhs, rhs in
            let lhsStart = lhs[keyPath: start]
            let rhsStart = rhs[keyPath: start]
            if lhsStart != rhsStart { return lhsStart < rhsStart }
            return eventKey(lhs[keyPath: key], precedes: rhs[keyPath: key])
        }
        try check(deadline)
        return sorted
    }

    private static func stableCounters(
        _ values: [CounterSeries],
        deadline: ContinuousClock.Instant
    ) throws -> [TraceAgentCounterEvent] {
        try check(deadline)
        var events: [TraceAgentCounterEvent] = []
        for (index, series) in values.enumerated() {
            if index.isMultiple(of: 256) { try check(deadline) }
            events.append(contentsOf: series.samples.map {
                TraceAgentCounterEvent(series: series, sample: $0)
            })
        }
        let sorted = events.sorted { lhs, rhs in
            if lhs.sample.timestampNs != rhs.sample.timestampNs {
                return lhs.sample.timestampNs < rhs.sample.timestampNs
            }
            return eventKey(lhs.sample.key, precedes: rhs.sample.key)
        }
        try check(deadline)
        return sorted
    }

    private static func eventKey(_ lhs: EventKey, precedes rhs: EventKey) -> Bool {
        if lhs.table.rawValue != rhs.table.rawValue {
            return lhs.table.rawValue < rhs.table.rawValue
        }
        return lhs.rowID < rhs.rowID
    }

    private static func quality(
        _ trace: TraceDataQuality,
        _ page: TraceDataQuality
    ) -> TraceDataQuality {
        let issues = Array(Set(trace.issues + page.issues)).sorted {
            let lhs = ($0.category.rawValue, $0.scope ?? "", $0.count ?? .min, $0.message ?? "")
            let rhs = ($1.category.rawValue, $1.scope ?? "", $1.count ?? .min, $1.message ?? "")
            return lhs < rhs
        }
        return TraceDataQuality(issues: issues)
    }

    private static func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw ArkTraceError(
                code: .queryTimeout,
                stage: .querying,
                message: "Agent query deadline was reached",
                retryable: true
            )
        }
    }
}

/// Structured, draining deadline boundary shared by the P4 Agent, Analysis,
/// and Context entry points. A timer actively cancels the child operation;
/// an ordinary failure observed after the absolute deadline cannot mask the
/// timeout, and parent cancellation remains highest priority.
enum TraceAnalysisOperationDeadline {
    static func run<Value: Sendable>(
        timeout: Duration,
        stage: ArkTraceError.Stage,
        timeoutMessage: String,
        operation: @escaping @Sendable (ContinuousClock.Instant) async throws -> Value
    ) async throws -> Value {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        do {
            let value = try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask { try await operation(deadline) }
                group.addTask {
                    try await clock.sleep(until: deadline)
                    throw timeoutError(timeoutMessage, stage: stage)
                }
                do {
                    guard let value = try await group.next() else {
                        throw ArkTraceError(
                            code: .internalError,
                            stage: .analyzing,
                            message: "Analysis deadline race ended without a result"
                        )
                    }
                    group.cancelAll()
                    return value
                } catch {
                    group.cancelAll()
                    try Task.checkCancellation()
                    if clock.now >= deadline {
                        throw timeoutError(timeoutMessage, stage: stage)
                    }
                    throw error
                }
            }
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw timeoutError(timeoutMessage, stage: stage)
            }
            return value
        } catch {
            try Task.checkCancellation()
            if clock.now >= deadline, (error as? ArkTraceError)?.code != .cancelled {
                throw timeoutError(timeoutMessage, stage: stage)
            }
            throw error
        }
    }

    private static func timeoutError(
        _ message: String,
        stage: ArkTraceError.Stage
    ) -> ArkTraceError {
        ArkTraceError(
            code: .queryTimeout,
            stage: stage,
            message: message,
            retryable: true
        )
    }
}
