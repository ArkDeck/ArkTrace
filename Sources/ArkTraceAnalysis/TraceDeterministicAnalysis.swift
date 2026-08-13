import ArkTraceCore
import Foundation

private func encodeNullable<T: Encodable, Key: CodingKey>(
    _ value: T?,
    to values: inout KeyedEncodingContainer<Key>,
    forKey key: Key
) throws {
    if let value { try values.encode(value, forKey: key) }
    else { try values.encodeNil(forKey: key) }
}

public enum TraceDeterministicAnalysisKind: String, Codable, Sendable {
    case deterministicBatch
}

/// Exact effective parameters that shaped a deterministic analysis result.
/// Defaults have already been materialized; no omitted field is inferred by a
/// consumer (SPEC §10.1).
public struct TraceDeterministicAnalysisParameters: Hashable, Codable, Sendable {
    public let filters: TraceAgentQueryFilters
    public let maximumCPUSlices: Int
    public let maximumProcessSlices: Int
    public let maximumThreadSlices: Int
    public let maximumStateIntervals: Int
    public let maximumNamedSlices: Int
    public let maximumSchedulingEvents: Int
    public let maximumHotEvents: Int
    public let topProcessLimit: Int
    public let topThreadLimit: Int
    public let longSliceLimit: Int
    public let schedulingSampleLimit: Int
    public let hotIntervalLimit: Int
    public let hotBucketCount: Int
    public let minimumLongSliceDurationNs: Int64
    public let timeoutSeconds: Int64
    public let timeoutAttoseconds: Int64
}

public struct TraceDeterministicAnalysisRequest: Sendable {
    public let range: TraceTimeRange
    public let filters: TraceAgentQueryFilters
    public let maximumCPUSlices: Int
    public let maximumProcessSlices: Int
    public let maximumThreadSlices: Int
    public let maximumStateIntervals: Int
    public let maximumNamedSlices: Int
    public let maximumSchedulingEvents: Int
    public let maximumHotEvents: Int
    public let topProcessLimit: Int
    public let topThreadLimit: Int
    public let longSliceLimit: Int
    public let schedulingSampleLimit: Int
    public let hotIntervalLimit: Int
    public let hotBucketCount: Int
    public let minimumLongSliceDurationNs: Int64
    public let timeout: Duration

    public init(
        range: TraceTimeRange,
        filters: TraceAgentQueryFilters = .none,
        maximumCPUSlices: Int = 20_000,
        maximumProcessSlices: Int = 20_000,
        maximumThreadSlices: Int = 20_000,
        maximumStateIntervals: Int = 20_000,
        maximumNamedSlices: Int = 20_000,
        maximumSchedulingEvents: Int = 20_000,
        maximumHotEvents: Int = 20_000,
        topProcessLimit: Int = 10,
        topThreadLimit: Int = 10,
        longSliceLimit: Int = 20,
        schedulingSampleLimit: Int = 20,
        hotIntervalLimit: Int = 20,
        hotBucketCount: Int = 100,
        minimumLongSliceDurationNs: Int64 = 0,
        timeout: Duration = .seconds(30)
    ) throws {
        let eventBudgets = [
            maximumCPUSlices, maximumProcessSlices, maximumThreadSlices,
            maximumStateIntervals, maximumNamedSlices, maximumSchedulingEvents,
            maximumHotEvents,
        ]
        let outputLimits = [
            topProcessLimit, topThreadLimit, longSliceLimit,
            schedulingSampleLimit, hotIntervalLimit,
        ]
        guard range.startNs < range.endNs,
            filters.cpu == nil, filters.rawState == nil,
            filters.normalizedState == nil, filters.name == nil,
            filters.minimumDurationNs == nil, filters.depth == nil,
            filters.counterFilterID == nil,
            eventBudgets.allSatisfy({ (1...100_000).contains($0) }),
            outputLimits.allSatisfy({ (1...1_000).contains($0) }),
            (1...10_000).contains(hotBucketCount),
            minimumLongSliceDurationNs >= 0,
            timeout >= .milliseconds(100), timeout <= .seconds(120)
        else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Deterministic analysis bounds are invalid"
            )
        }
        self.range = range
        self.filters = filters
        self.maximumCPUSlices = maximumCPUSlices
        self.maximumProcessSlices = maximumProcessSlices
        self.maximumThreadSlices = maximumThreadSlices
        self.maximumStateIntervals = maximumStateIntervals
        self.maximumNamedSlices = maximumNamedSlices
        self.maximumSchedulingEvents = maximumSchedulingEvents
        self.maximumHotEvents = maximumHotEvents
        self.topProcessLimit = topProcessLimit
        self.topThreadLimit = topThreadLimit
        self.longSliceLimit = longSliceLimit
        self.schedulingSampleLimit = schedulingSampleLimit
        self.hotIntervalLimit = hotIntervalLimit
        self.hotBucketCount = hotBucketCount
        self.minimumLongSliceDurationNs = minimumLongSliceDurationNs
        self.timeout = timeout
    }
}

public struct TraceRunningProcess: Hashable, Codable, Sendable {
    public let processKey: ProcessKey
    public let pid: Int64?
    public let name: String?
    public let runningNs: Int64
    public let shareOfOneCPU: Double
    public let sliceCount: Int

    private enum CodingKeys: String, CodingKey {
        case processKey, pid, name, runningNs, shareOfOneCPU, sliceCount
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(processKey, forKey: .processKey)
        try encodeNullable(pid, to: &values, forKey: .pid)
        try encodeNullable(name, to: &values, forKey: .name)
        try values.encode(runningNs, forKey: .runningNs)
        try values.encode(shareOfOneCPU, forKey: .shareOfOneCPU)
        try values.encode(sliceCount, forKey: .sliceCount)
    }
}

public struct TraceRunningThread: Hashable, Codable, Sendable {
    public let threadKey: ThreadKey
    public let processKey: ProcessKey?
    public let tid: Int64?
    public let pid: Int64?
    public let name: String?
    public let processName: String?
    public let runningNs: Int64
    public let shareOfOneCPU: Double
    public let sliceCount: Int

    private enum CodingKeys: String, CodingKey {
        case threadKey, processKey, tid, pid, name, processName
        case runningNs, shareOfOneCPU, sliceCount
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(threadKey, forKey: .threadKey)
        try encodeNullable(processKey, to: &values, forKey: .processKey)
        try encodeNullable(tid, to: &values, forKey: .tid)
        try encodeNullable(pid, to: &values, forKey: .pid)
        try encodeNullable(name, to: &values, forKey: .name)
        try encodeNullable(processName, to: &values, forKey: .processName)
        try values.encode(runningNs, forKey: .runningNs)
        try values.encode(shareOfOneCPU, forKey: .shareOfOneCPU)
        try values.encode(sliceCount, forKey: .sliceCount)
    }
}

public struct TraceThreadStateDistribution: Hashable, Codable, Sendable {
    public let threadKey: ThreadKey
    public let processKey: ProcessKey?
    public let tid: Int64?
    public let pid: Int64?
    public let rawState: String
    public let normalizedState: TraceThreadState?
    public let durationNs: Int64
    public let percentageOfRange: Double
    public let intervalCount: Int

    private enum CodingKeys: String, CodingKey {
        case threadKey, processKey, tid, pid, rawState, normalizedState
        case durationNs, percentageOfRange, intervalCount
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(threadKey, forKey: .threadKey)
        try encodeNullable(processKey, to: &values, forKey: .processKey)
        try encodeNullable(tid, to: &values, forKey: .tid)
        try encodeNullable(pid, to: &values, forKey: .pid)
        try values.encode(rawState, forKey: .rawState)
        try encodeNullable(normalizedState, to: &values, forKey: .normalizedState)
        try values.encode(durationNs, forKey: .durationNs)
        try values.encode(percentageOfRange, forKey: .percentageOfRange)
        try values.encode(intervalCount, forKey: .intervalCount)
    }
}

public struct TracePercentiles: Hashable, Codable, Sendable {
    public let p50Ns: Int64
    public let p90Ns: Int64
    public let p95Ns: Int64
    public let p99Ns: Int64
    public let maxNs: Int64
}

public enum TraceSchedulingUnsupportedReason: String, Codable, Sendable {
    case capabilityUnavailable
    case noProvableRunnableTransitions
}

public struct TraceSchedulingLatencySample: Hashable, Codable, Sendable {
    public let threadKey: ThreadKey
    public let runnableEventKey: EventKey
    public let runningEventKey: EventKey
    public let runnableEndNs: Int64
    public let runningStartNs: Int64
    public let latencyNs: Int64
}

public struct TraceSchedulingLatencyResult: Hashable, Codable, Sendable {
    public let supported: Bool
    public let unsupportedReason: TraceSchedulingUnsupportedReason?
    public let count: Int
    public let percentiles: TracePercentiles?
    public let topSamples: [TraceSchedulingLatencySample]
    public let truncated: Bool

    private enum CodingKeys: String, CodingKey {
        case supported, unsupportedReason, count, percentiles, topSamples, truncated
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(supported, forKey: .supported)
        try encodeNullable(unsupportedReason, to: &values, forKey: .unsupportedReason)
        try values.encode(count, forKey: .count)
        try encodeNullable(percentiles, to: &values, forKey: .percentiles)
        try values.encode(topSamples, forKey: .topSamples)
        try values.encode(truncated, forKey: .truncated)
    }
}

public struct TraceHotIntervalScore: Hashable, Codable, Sendable {
    /// Fixed public conversion from a context-switch observation to score time.
    public static let contextSwitchWeightNs: Int64 = 1_000_000

    public let cpuBusyNs: Int64
    public let contextSwitchCount: Int
    public let contextSwitchScoreNs: Int64
    public let longSliceNs: Int64
    public let total: Int64
}

public struct TraceHotInterval: Hashable, Codable, Sendable {
    public let range: TraceTimeRange
    public let score: TraceHotIntervalScore
    public let cpuSliceCount: Int
    public let namedSliceCount: Int
}

public struct TraceAnalysisSectionStatus: Hashable, Codable, Sendable {
    public let returnedCount: Int
    public let matchedCount: Int?
    public let truncated: Bool

    private enum CodingKeys: String, CodingKey {
        case returnedCount, matchedCount, truncated
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(returnedCount, forKey: .returnedCount)
        try encodeNullable(matchedCount, to: &values, forKey: .matchedCount)
        try values.encode(truncated, forKey: .truncated)
    }
}

public struct TraceDeterministicAnalysisSections: Hashable, Codable, Sendable {
    public let cpuUtilization: TraceAnalysisSectionStatus
    public let topProcesses: TraceAnalysisSectionStatus
    public let topThreads: TraceAnalysisSectionStatus
    public let longSlices: TraceAnalysisSectionStatus
    public let threadStateDistribution: TraceAnalysisSectionStatus
    public let schedulingLatency: TraceAnalysisSectionStatus
    public let hotIntervals: TraceAnalysisSectionStatus
}

public struct TraceDeterministicAnalysis: Hashable, Codable, Sendable {
    public let kind: TraceDeterministicAnalysisKind
    public let parameters: TraceDeterministicAnalysisParameters
    public let range: TraceTimeRange
    public let cpuUtilization: [TraceCPUUtilization]
    public let topProcesses: [TraceRunningProcess]
    public let topThreads: [TraceRunningThread]
    public let longSlices: [TraceLongSlice]
    public let threadStateDistribution: [TraceThreadStateDistribution]
    public let schedulingLatency: TraceSchedulingLatencyResult
    public let hotIntervals: [TraceHotInterval]
    public let sections: TraceDeterministicAnalysisSections
    public let dataQuality: TraceDataQuality

    /// Applies the CLI's command-global row budget across all seven output
    /// sections in a fixed semantic priority. Store input budgets remain
    /// independent; this is the final bounded result projection.
    public func retainingRows(maximumRows: Int) throws -> Self {
        guard maximumRows >= 0 else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Analysis row budget must be non-negative"
            )
        }
        var remaining = maximumRows
        func retained<T>(_ values: [T]) -> [T] {
            let count = min(remaining, values.count)
            remaining -= count
            return Array(values.prefix(count))
        }
        func status(
            _ original: TraceAnalysisSectionStatus,
            returnedCount: Int
        ) -> TraceAnalysisSectionStatus {
            TraceAnalysisSectionStatus(
                returnedCount: returnedCount,
                matchedCount: original.matchedCount,
                truncated: original.truncated || returnedCount < original.returnedCount
            )
        }

        let retainedCPU = retained(cpuUtilization)
        let retainedProcesses = retained(topProcesses)
        let retainedThreads = retained(topThreads)
        let retainedLongSlices = retained(longSlices)
        let retainedStates = retained(threadStateDistribution)
        let retainedSamples = retained(schedulingLatency.topSamples)
        let retainedHot = retained(hotIntervals)
        let retainedScheduling = TraceSchedulingLatencyResult(
            supported: schedulingLatency.supported,
            unsupportedReason: schedulingLatency.unsupportedReason,
            count: schedulingLatency.count,
            percentiles: schedulingLatency.percentiles,
            topSamples: retainedSamples,
            truncated: schedulingLatency.truncated
                || retainedSamples.count < schedulingLatency.topSamples.count
        )
        return TraceDeterministicAnalysis(
            kind: kind,
            parameters: parameters,
            range: range,
            cpuUtilization: retainedCPU,
            topProcesses: retainedProcesses,
            topThreads: retainedThreads,
            longSlices: retainedLongSlices,
            threadStateDistribution: retainedStates,
            schedulingLatency: retainedScheduling,
            hotIntervals: retainedHot,
            sections: TraceDeterministicAnalysisSections(
                cpuUtilization: status(
                    sections.cpuUtilization, returnedCount: retainedCPU.count
                ),
                topProcesses: status(
                    sections.topProcesses, returnedCount: retainedProcesses.count
                ),
                topThreads: status(
                    sections.topThreads, returnedCount: retainedThreads.count
                ),
                longSlices: status(
                    sections.longSlices, returnedCount: retainedLongSlices.count
                ),
                threadStateDistribution: status(
                    sections.threadStateDistribution, returnedCount: retainedStates.count
                ),
                schedulingLatency: status(
                    sections.schedulingLatency, returnedCount: retainedSamples.count
                ),
                hotIntervals: status(
                    sections.hotIntervals, returnedCount: retainedHot.count
                )
            ),
            dataQuality: dataQuality
        )
    }
}

public struct TraceDeterministicAnalysisEngine: Sendable {
    private struct ProcessAccumulator {
        var pid: Int64?
        var name: String?
        var runningNs: Int64 = 0
        var count: Int = 0
    }

    private struct ThreadAccumulator {
        var processKey: ProcessKey?
        var tid: Int64?
        var pid: Int64?
        var name: String?
        var processName: String?
        var runningNs: Int64 = 0
        var count: Int = 0
    }

    private struct StateKey: Hashable {
        let threadKey: ThreadKey
        let processKey: ProcessKey?
        let tid: Int64?
        let pid: Int64?
        let rawState: String
        let normalizedState: TraceThreadState?
    }

    private struct RunningTransitionKey: Hashable {
        let threadKey: ThreadKey
        let startNs: Int64
    }

    private struct BucketAccumulator {
        var cpuBusyNs: Int64 = 0
        var cpuSliceCount: Int = 0
        var contextSwitchCount: Int = 0
        var longSliceNs: Int64 = 0
        var namedSliceCount: Int = 0
    }

    private let repository: any TraceRepositoryProtocol

    public init(repository: any TraceRepositoryProtocol) {
        self.repository = repository
    }

    public func analyze(
        _ request: TraceDeterministicAnalysisRequest
    ) async throws -> TraceDeterministicAnalysis {
        do {
            return try await TraceAnalysisOperationDeadline.run(
                timeout: request.timeout,
                stage: .analyzing,
                timeoutMessage: "Deterministic analysis deadline was reached"
            ) { deadline in
                try await analyze(request, deadline: deadline)
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw ArkTraceError(
                    code: .cancelled,
                    stage: .analyzing,
                    message: "Deterministic analysis was cancelled",
                    retryable: true
                )
            }
            throw error
        }
    }

    private func analyze(
        _ request: TraceDeterministicAnalysisRequest,
        deadline: ContinuousClock.Instant
    ) async throws -> TraceDeterministicAnalysis {
            try Self.check(deadline)
            let metadata = try await repository.metadata()
            guard request.range.endNs <= metadata.durationNs else {
                throw ArkTraceError(
                    code: .invalidArgument,
                    stage: .request,
                    message: "Analysis range exceeds trace duration"
                )
            }
            try Self.check(deadline)

            // Each section has an independent Store query and budget. One
            // truncated section cannot silently lower another section's data.
            let cpuPage = try await repository.cpuSlices(
                try CpuSliceQuery(
                    range: request.range,
                    processKey: request.filters.processKey,
                    pid: request.filters.pid,
                    threadKey: request.filters.threadKey,
                    tid: request.filters.tid,
                    limit: request.maximumCPUSlices,
                    deadline: deadline
                )
            )
            let processPage = try await repository.cpuSlices(
                try CpuSliceQuery(
                    range: request.range,
                    processKey: request.filters.processKey,
                    pid: request.filters.pid,
                    threadKey: request.filters.threadKey,
                    tid: request.filters.tid,
                    limit: request.maximumProcessSlices,
                    deadline: deadline
                )
            )
            let threadPage = try await repository.cpuSlices(
                try CpuSliceQuery(
                    range: request.range,
                    processKey: request.filters.processKey,
                    pid: request.filters.pid,
                    threadKey: request.filters.threadKey,
                    tid: request.filters.tid,
                    limit: request.maximumThreadSlices,
                    deadline: deadline
                )
            )
            let statePage = try await repository.threadStates(
                try ThreadStateQuery(
                    range: request.range,
                    processKey: request.filters.processKey,
                    pid: request.filters.pid,
                    threadKey: request.filters.threadKey,
                    tid: request.filters.tid,
                    limit: request.maximumStateIntervals,
                    deadline: deadline
                )
            )
            let namedPage = try await repository.slices(
                try TraceSliceQuery(
                    range: request.range,
                    processKey: request.filters.processKey,
                    pid: request.filters.pid,
                    threadKey: request.filters.threadKey,
                    tid: request.filters.tid,
                    minimumDurationNs: request.minimumLongSliceDurationNs,
                    limit: request.maximumNamedSlices,
                    deadline: deadline
                )
            )
            let schedulingCPUPage = try await repository.cpuSlices(
                try CpuSliceQuery(
                    range: request.range,
                    processKey: request.filters.processKey,
                    pid: request.filters.pid,
                    threadKey: request.filters.threadKey,
                    tid: request.filters.tid,
                    limit: request.maximumSchedulingEvents,
                    deadline: deadline
                )
            )
            let schedulingStatePage = try await repository.threadStates(
                try ThreadStateQuery(
                    range: request.range,
                    processKey: request.filters.processKey,
                    pid: request.filters.pid,
                    threadKey: request.filters.threadKey,
                    tid: request.filters.tid,
                    state: .runnable,
                    limit: request.maximumSchedulingEvents,
                    deadline: deadline
                )
            )
            let hotCPUPage = try await repository.cpuSlices(
                try CpuSliceQuery(
                    range: request.range,
                    processKey: request.filters.processKey,
                    pid: request.filters.pid,
                    threadKey: request.filters.threadKey,
                    tid: request.filters.tid,
                    limit: request.maximumHotEvents,
                    deadline: deadline
                )
            )
            let hotNamedPage = try await repository.slices(
                try TraceSliceQuery(
                    range: request.range,
                    processKey: request.filters.processKey,
                    pid: request.filters.pid,
                    threadKey: request.filters.threadKey,
                    tid: request.filters.tid,
                    minimumDurationNs: request.minimumLongSliceDurationNs,
                    limit: request.maximumHotEvents,
                    deadline: deadline
                )
            )
            try Self.check(deadline)

            let cpu = try Self.cpuUtilization(cpuPage.items, request.range, deadline)
            let processes = try Self.topProcesses(
                processPage.items, request.range, request.topProcessLimit, deadline
            )
            let threads = try Self.topThreads(
                threadPage.items, request.range, request.topThreadLimit, deadline
            )
            let states = try Self.stateDistribution(
                statePage.items, request.range, deadline
            )
            let longCandidates = namedPage.items.sorted(by: Self.longSliceOrder)
            try Self.check(deadline)
            let longSlices = longCandidates.prefix(request.longSliceLimit).map(Self.longSlice)
            let scheduling = try Self.schedulingLatency(
                cpu: schedulingCPUPage,
                states: schedulingStatePage,
                capabilities: metadata.capabilities,
                sampleLimit: request.schedulingSampleLimit,
                deadline: deadline
            )
            let hotCandidates = try Self.hotIntervals(
                cpu: hotCPUPage.items,
                named: hotNamedPage.items,
                range: request.range,
                bucketCount: request.hotBucketCount,
                minimumLongSliceDurationNs: request.minimumLongSliceDurationNs,
                deadline: deadline
            )
            let hot = Array(hotCandidates.prefix(request.hotIntervalLimit))

            var issues = metadata.dataQuality.issues
                + cpuPage.dataQuality.issues + processPage.dataQuality.issues
                + threadPage.dataQuality.issues + statePage.dataQuality.issues
                + namedPage.dataQuality.issues + schedulingCPUPage.dataQuality.issues
                + schedulingStatePage.dataQuality.issues + hotCPUPage.dataQuality.issues
                + hotNamedPage.dataQuality.issues
            let overlapCPUCount = cpu.reduce(into: 0) {
                if $1.rawRunningNs > request.range.durationNs { $0 += 1 }
            }
            if overlapCPUCount > 0 {
                issues.append(
                    TraceDataQualityIssue(
                        category: .invalidValue,
                        scope: "sched_slice.overlap",
                        count: Int64(overlapCPUCount),
                        message: "Raw scheduled time exceeded the selected range"
                    )
                )
            }
            let quality = Self.stableQuality(issues)
            let sections = TraceDeterministicAnalysisSections(
                cpuUtilization: .init(
                    returnedCount: cpu.count,
                    matchedCount: cpuPage.truncated ? nil : cpuPage.items.count,
                    truncated: cpuPage.truncated
                ),
                topProcesses: .init(
                    returnedCount: processes.items.count,
                    matchedCount: processPage.truncated ? nil : processes.matched,
                    truncated: processPage.truncated || processes.matched > processes.items.count
                ),
                topThreads: .init(
                    returnedCount: threads.items.count,
                    matchedCount: threadPage.truncated ? nil : threads.matched,
                    truncated: threadPage.truncated || threads.matched > threads.items.count
                ),
                longSlices: .init(
                    returnedCount: longSlices.count,
                    matchedCount: namedPage.truncated ? nil : longCandidates.count,
                    truncated: namedPage.truncated || longCandidates.count > longSlices.count
                ),
                threadStateDistribution: .init(
                    returnedCount: states.count,
                    matchedCount: statePage.truncated ? nil : statePage.items.count,
                    truncated: statePage.truncated
                ),
                schedulingLatency: .init(
                    returnedCount: scheduling.topSamples.count,
                    matchedCount: schedulingCPUPage.truncated || schedulingStatePage.truncated
                        ? nil : scheduling.count,
                    truncated: scheduling.truncated
                ),
                hotIntervals: .init(
                    returnedCount: hot.count,
                    matchedCount: hotCPUPage.truncated || hotNamedPage.truncated
                        ? nil : hotCandidates.count,
                    truncated: hotCPUPage.truncated || hotNamedPage.truncated
                        || hotCandidates.count > hot.count
                )
            )
            try Self.check(deadline)
            return TraceDeterministicAnalysis(
                kind: .deterministicBatch,
                parameters: Self.parameters(request),
                range: request.range,
                cpuUtilization: cpu,
                topProcesses: processes.items,
                topThreads: threads.items,
                longSlices: Array(longSlices),
                threadStateDistribution: states,
                schedulingLatency: scheduling,
                hotIntervals: hot,
                sections: sections,
                dataQuality: quality
            )
    }

    private static func cpuUtilization(
        _ slices: [CpuSlice],
        _ range: TraceTimeRange,
        _ deadline: ContinuousClock.Instant
    ) throws -> [TraceCPUUtilization] {
        var values: [Int64: (raw: Int64, count: Int)] = [:]
        for (index, slice) in slices.enumerated() {
            if index.isMultiple(of: 512) { try check(deadline) }
            var value = values[slice.cpu] ?? (0, 0)
            value.raw = saturatedAdd(value.raw, slice.range.clippedOverlapNs(with: range))
            value.count = value.count == Int.max ? Int.max : value.count + 1
            values[slice.cpu] = value
        }
        return values.map { cpu, value in
            let raw = max(0, value.raw)
            let occupied = min(range.durationNs, raw)
            return TraceCPUUtilization(
                cpu: cpu,
                rawRunningNs: raw,
                occupiedNs: occupied,
                sliceCount: value.count,
                utilization: Double(occupied) / Double(range.durationNs)
            )
        }.sorted { $0.cpu < $1.cpu }
    }

    private static func topProcesses(
        _ slices: [CpuSlice],
        _ range: TraceTimeRange,
        _ limit: Int,
        _ deadline: ContinuousClock.Instant
    ) throws -> (items: [TraceRunningProcess], matched: Int) {
        var values: [ProcessKey: ProcessAccumulator] = [:]
        for (index, slice) in slices.enumerated() {
            if index.isMultiple(of: 512) { try check(deadline) }
            guard let key = slice.processKey else { continue }
            var value = values[key] ?? ProcessAccumulator()
            value.pid = value.pid ?? slice.pid
            value.name = value.name ?? slice.processName
            value.runningNs = saturatedAdd(
                value.runningNs, slice.range.clippedOverlapNs(with: range)
            )
            value.count = value.count == Int.max ? Int.max : value.count + 1
            values[key] = value
        }
        let rows = values.map { key, value in
            TraceRunningProcess(
                processKey: key, pid: value.pid, name: value.name,
                runningNs: value.runningNs,
                shareOfOneCPU: Double(value.runningNs) / Double(range.durationNs),
                sliceCount: value.count
            )
        }.sorted {
            if $0.runningNs != $1.runningNs { return $0.runningNs > $1.runningNs }
            return $0.processKey.ipid < $1.processKey.ipid
        }
        return (Array(rows.prefix(limit)), rows.count)
    }

    private static func topThreads(
        _ slices: [CpuSlice],
        _ range: TraceTimeRange,
        _ limit: Int,
        _ deadline: ContinuousClock.Instant
    ) throws -> (items: [TraceRunningThread], matched: Int) {
        var values: [ThreadKey: ThreadAccumulator] = [:]
        for (index, slice) in slices.enumerated() {
            if index.isMultiple(of: 512) { try check(deadline) }
            guard let key = slice.threadKey else { continue }
            var value = values[key] ?? ThreadAccumulator()
            value.processKey = value.processKey ?? slice.processKey
            value.tid = value.tid ?? slice.tid
            value.pid = value.pid ?? slice.pid
            value.name = value.name ?? slice.threadName
            value.processName = value.processName ?? slice.processName
            value.runningNs = saturatedAdd(
                value.runningNs, slice.range.clippedOverlapNs(with: range)
            )
            value.count = value.count == Int.max ? Int.max : value.count + 1
            values[key] = value
        }
        let rows = values.map { key, value in
            TraceRunningThread(
                threadKey: key, processKey: value.processKey,
                tid: value.tid, pid: value.pid, name: value.name,
                processName: value.processName, runningNs: value.runningNs,
                shareOfOneCPU: Double(value.runningNs) / Double(range.durationNs),
                sliceCount: value.count
            )
        }.sorted {
            if $0.runningNs != $1.runningNs { return $0.runningNs > $1.runningNs }
            return $0.threadKey.itid < $1.threadKey.itid
        }
        return (Array(rows.prefix(limit)), rows.count)
    }

    private static func stateDistribution(
        _ intervals: [ThreadStateInterval],
        _ range: TraceTimeRange,
        _ deadline: ContinuousClock.Instant
    ) throws -> [TraceThreadStateDistribution] {
        var values: [StateKey: (duration: Int64, count: Int)] = [:]
        for (index, interval) in intervals.enumerated() {
            if index.isMultiple(of: 512) { try check(deadline) }
            let key = StateKey(
                threadKey: interval.threadKey,
                processKey: interval.processKey,
                tid: interval.tid,
                pid: interval.pid,
                rawState: interval.state,
                normalizedState: interval.normalizedState
            )
            var value = values[key] ?? (0, 0)
            value.duration = saturatedAdd(
                value.duration, interval.range.clippedOverlapNs(with: range)
            )
            value.count = value.count == Int.max ? Int.max : value.count + 1
            values[key] = value
        }
        return values.map { key, value in
            TraceThreadStateDistribution(
                threadKey: key.threadKey,
                processKey: key.processKey,
                tid: key.tid,
                pid: key.pid,
                rawState: key.rawState,
                normalizedState: key.normalizedState,
                durationNs: value.duration,
                percentageOfRange: Double(value.duration) / Double(range.durationNs),
                intervalCount: value.count
            )
        }.sorted {
            if $0.threadKey.itid != $1.threadKey.itid {
                return $0.threadKey.itid < $1.threadKey.itid
            }
            if $0.processKey != $1.processKey {
                return optionalPrecedes(
                    $0.processKey.map(\.ipid), $1.processKey.map(\.ipid)
                )
            }
            if $0.tid != $1.tid { return optionalPrecedes($0.tid, $1.tid) }
            if $0.pid != $1.pid { return optionalPrecedes($0.pid, $1.pid) }
            let lhs = Data($0.rawState.utf8)
            let rhs = Data($1.rawState.utf8)
            if lhs != rhs { return lhs.lexicographicallyPrecedes(rhs) }
            if $0.normalizedState != $1.normalizedState {
                return optionalUTF8Precedes(
                    $0.normalizedState?.rawValue, $1.normalizedState?.rawValue
                )
            }
            return false
        }
    }

    private static func optionalPrecedes<T: Comparable>(
        _ lhs: T?, _ rhs: T?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, .some): true
        case (.some, nil), (nil, nil): false
        case (.some(let lhs), .some(let rhs)): lhs < rhs
        }
    }

    private static func optionalUTF8Precedes(
        _ lhs: String?, _ rhs: String?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, .some): true
        case (.some, nil), (nil, nil): false
        case (.some(let lhs), .some(let rhs)):
            Data(lhs.utf8).lexicographicallyPrecedes(Data(rhs.utf8))
        }
    }

    private static func schedulingLatency(
        cpu: TraceEventPage<CpuSlice>,
        states: TraceEventPage<ThreadStateInterval>,
        capabilities: TraceCapabilities,
        sampleLimit: Int,
        deadline: ContinuousClock.Instant
    ) throws -> TraceSchedulingLatencyResult {
        guard capabilities.cpuScheduling, capabilities.threadStates,
            cpu.capabilityAvailable, states.capabilityAvailable
        else {
            return TraceSchedulingLatencyResult(
                supported: false, unsupportedReason: .capabilityUnavailable,
                count: 0, percentiles: nil, topSamples: [], truncated: false
            )
        }
        var running: [RunningTransitionKey: CpuSlice] = [:]
        for (index, slice) in cpu.items.enumerated() {
            if index.isMultiple(of: 512) { try check(deadline) }
            guard let threadKey = slice.threadKey else { continue }
            let key = RunningTransitionKey(threadKey: threadKey, startNs: slice.startNs)
            if let existing = running[key] {
                if eventKey(slice.key, precedes: existing.key) { running[key] = slice }
            } else {
                running[key] = slice
            }
        }
        var samples: [TraceSchedulingLatencySample] = []
        for (index, state) in states.items.enumerated() {
            if index.isMultiple(of: 256) { try check(deadline) }
            guard state.normalizedState == .runnable,
                let next = running[
                    RunningTransitionKey(threadKey: state.threadKey, startNs: state.endNs)
                ]
            else { continue }
            samples.append(
                TraceSchedulingLatencySample(
                    threadKey: state.threadKey,
                    runnableEventKey: state.key,
                    runningEventKey: next.key,
                    runnableEndNs: state.endNs,
                    runningStartNs: next.startNs,
                    latencyNs: state.range.durationNs
                )
            )
        }
        guard !samples.isEmpty else {
            return TraceSchedulingLatencyResult(
                supported: false,
                unsupportedReason: .noProvableRunnableTransitions,
                count: 0, percentiles: nil, topSamples: [],
                truncated: cpu.truncated || states.truncated
            )
        }
        let orderedValues = samples.map(\.latencyNs).sorted()
        try check(deadline)
        let top = samples.sorted {
            if $0.latencyNs != $1.latencyNs { return $0.latencyNs > $1.latencyNs }
            if $0.threadKey.itid != $1.threadKey.itid {
                return $0.threadKey.itid < $1.threadKey.itid
            }
            return eventKey($0.runnableEventKey, precedes: $1.runnableEventKey)
        }
        try check(deadline)
        return TraceSchedulingLatencyResult(
            supported: true,
            unsupportedReason: nil,
            count: orderedValues.count,
            percentiles: TracePercentiles(
                p50Ns: percentile(orderedValues, numerator: 50),
                p90Ns: percentile(orderedValues, numerator: 90),
                p95Ns: percentile(orderedValues, numerator: 95),
                p99Ns: percentile(orderedValues, numerator: 99),
                maxNs: orderedValues.last!
            ),
            topSamples: Array(top.prefix(sampleLimit)),
            truncated: cpu.truncated || states.truncated || top.count > sampleLimit
        )
    }

    /// Fixed nearest-rank percentile: `ceil(percent * count / 100) - 1`.
    private static func percentile(_ sorted: [Int64], numerator: Int) -> Int64 {
        let rank = max(1, (numerator * sorted.count + 99) / 100)
        return sorted[rank - 1]
    }

    private static func hotIntervals(
        cpu: [CpuSlice],
        named: [TraceSlice],
        range: TraceTimeRange,
        bucketCount: Int,
        minimumLongSliceDurationNs: Int64,
        deadline: ContinuousClock.Instant
    ) throws -> [TraceHotInterval] {
        let buckets = try bucketRanges(range, count: bucketCount)
        var values = Array(repeating: BucketAccumulator(), count: buckets.count)
        var cpuFullCoverage = Array(repeating: Int64(0), count: buckets.count + 1)
        var namedFullCoverage = Array(repeating: Int64(0), count: buckets.count + 1)
        for (index, slice) in cpu.enumerated() {
            if index.isMultiple(of: 256) { try check(deadline) }
            guard let span = bucketSpan(slice.range, buckets: buckets) else { continue }
            if span.first == span.last {
                let overlap = slice.range.clippedOverlapNs(with: buckets[span.first])
                values[span.first].cpuBusyNs = saturatedAdd(
                    values[span.first].cpuBusyNs, overlap
                )
                values[span.first].cpuSliceCount = saturatedIncrement(
                    values[span.first].cpuSliceCount
                )
            } else {
                for bucketIndex in [span.first, span.last] {
                    let overlap = slice.range.clippedOverlapNs(with: buckets[bucketIndex])
                    values[bucketIndex].cpuBusyNs = saturatedAdd(
                        values[bucketIndex].cpuBusyNs, overlap
                    )
                    values[bucketIndex].cpuSliceCount = saturatedIncrement(
                        values[bucketIndex].cpuSliceCount
                    )
                }
                if span.first + 1 < span.last {
                    cpuFullCoverage[span.first + 1] += 1
                    cpuFullCoverage[span.last] -= 1
                }
            }
            if let switchBucket = bucketIndex(containing: slice.startNs, buckets: buckets) {
                values[switchBucket].contextSwitchCount = saturatedIncrement(
                    values[switchBucket].contextSwitchCount
                )
            }
        }
        for (index, slice) in named.enumerated() {
            if index.isMultiple(of: 256) { try check(deadline) }
            guard slice.range.durationNs >= minimumLongSliceDurationNs,
                let span = bucketSpan(slice.range, buckets: buckets)
            else { continue }
            if span.first == span.last {
                let overlap = slice.range.clippedOverlapNs(with: buckets[span.first])
                values[span.first].longSliceNs = saturatedAdd(
                    values[span.first].longSliceNs, overlap
                )
                values[span.first].namedSliceCount = saturatedIncrement(
                    values[span.first].namedSliceCount
                )
            } else {
                for bucketIndex in [span.first, span.last] {
                    let overlap = slice.range.clippedOverlapNs(with: buckets[bucketIndex])
                    values[bucketIndex].longSliceNs = saturatedAdd(
                        values[bucketIndex].longSliceNs, overlap
                    )
                    values[bucketIndex].namedSliceCount = saturatedIncrement(
                        values[bucketIndex].namedSliceCount
                    )
                }
                if span.first + 1 < span.last {
                    namedFullCoverage[span.first + 1] += 1
                    namedFullCoverage[span.last] -= 1
                }
            }
        }
        var activeCPU: Int64 = 0
        var activeNamed: Int64 = 0
        for index in buckets.indices {
            if index.isMultiple(of: 512) { try check(deadline) }
            activeCPU += cpuFullCoverage[index]
            activeNamed += namedFullCoverage[index]
            if activeCPU > 0 {
                values[index].cpuBusyNs = saturatedAdd(
                    values[index].cpuBusyNs,
                    saturatedMultiply(buckets[index].durationNs, activeCPU)
                )
                values[index].cpuSliceCount = saturatedAddCount(
                    values[index].cpuSliceCount, activeCPU
                )
            }
            if activeNamed > 0 {
                values[index].longSliceNs = saturatedAdd(
                    values[index].longSliceNs,
                    saturatedMultiply(buckets[index].durationNs, activeNamed)
                )
                values[index].namedSliceCount = saturatedAddCount(
                    values[index].namedSliceCount, activeNamed
                )
            }
        }
        return zip(buckets, values).map { bucket, value in
            let switchScore = saturatedMultiply(
                Int64(value.contextSwitchCount), TraceHotIntervalScore.contextSwitchWeightNs
            )
            let total = saturatedAdd(
                saturatedAdd(value.cpuBusyNs, switchScore), value.longSliceNs
            )
            return TraceHotInterval(
                range: bucket,
                score: TraceHotIntervalScore(
                    cpuBusyNs: value.cpuBusyNs,
                    contextSwitchCount: value.contextSwitchCount,
                    contextSwitchScoreNs: switchScore,
                    longSliceNs: value.longSliceNs,
                    total: total
                ),
                cpuSliceCount: value.cpuSliceCount,
                namedSliceCount: value.namedSliceCount
            )
        }.filter { $0.cpuSliceCount > 0 || $0.namedSliceCount > 0 }.sorted {
            if $0.score.total != $1.score.total { return $0.score.total > $1.score.total }
            return $0.range.startNs < $1.range.startNs
        }
    }

    private static func bucketRanges(
        _ range: TraceTimeRange,
        count: Int
    ) throws -> [TraceTimeRange] {
        let actualCount = min(count, Int(range.durationNs))
        let quotient = range.durationNs / Int64(actualCount)
        let remainder = range.durationNs % Int64(actualCount)
        var start = range.startNs
        var output: [TraceTimeRange] = []
        output.reserveCapacity(actualCount)
        for index in 0..<actualCount {
            let width = quotient + (Int64(index) < remainder ? 1 : 0)
            let end = start + width
            output.append(try TraceTimeRange.query(startNs: start, endNs: end))
            start = end
        }
        return output
    }

    private static func bucketSpan(
        _ event: TraceTimeRange,
        buckets: [TraceTimeRange]
    ) -> (first: Int, last: Int)? {
        if event.isInstant {
            guard let index = bucketIndex(containing: event.startNs, buckets: buckets) else {
                return nil
            }
            return (index, index)
        }
        let start = max(event.startNs, buckets[0].startNs)
        let end = min(event.endNs, buckets[buckets.count - 1].endNs)
        guard start < end,
            let first = bucketIndex(containing: start, buckets: buckets),
            let last = bucketIndex(containing: end - 1, buckets: buckets)
        else { return nil }
        return (first, last)
    }

    private static func bucketIndex(
        containing timestamp: Int64,
        buckets: [TraceTimeRange]
    ) -> Int? {
        guard let first = buckets.first, let last = buckets.last,
            timestamp >= first.startNs, timestamp < last.endNs
        else { return nil }
        var lower = 0
        var upper = buckets.count - 1
        while lower <= upper {
            let middle = lower + (upper - lower) / 2
            let bucket = buckets[middle]
            if timestamp < bucket.startNs {
                upper = middle - 1
            } else if timestamp >= bucket.endNs {
                lower = middle + 1
            } else {
                return middle
            }
        }
        return nil
    }

    private static func longSliceOrder(_ lhs: TraceSlice, _ rhs: TraceSlice) -> Bool {
        if lhs.range.durationNs != rhs.range.durationNs {
            return lhs.range.durationNs > rhs.range.durationNs
        }
        return eventKey(lhs.key, precedes: rhs.key)
    }

    private static func longSlice(_ value: TraceSlice) -> TraceLongSlice {
        TraceLongSlice(
            key: value.key, range: value.range, name: value.name,
            category: value.category, processKey: value.processKey,
            threadKey: value.threadKey, pid: value.pid, tid: value.tid,
            processName: value.processName, threadName: value.threadName
        )
    }

    private static func eventKey(_ lhs: EventKey, precedes rhs: EventKey) -> Bool {
        if lhs.table.rawValue != rhs.table.rawValue {
            return lhs.table.rawValue < rhs.table.rawValue
        }
        return lhs.rowID < rhs.rowID
    }

    private static func stableQuality(
        _ values: [TraceDataQualityIssue]
    ) -> TraceDataQuality {
        let issues = Array(Set(values)).sorted {
            let lhs = ($0.category.rawValue, $0.scope ?? "", $0.count ?? .min, $0.message ?? "")
            let rhs = ($1.category.rawValue, $1.scope ?? "", $1.count ?? .min, $1.message ?? "")
            return lhs < rhs
        }
        return TraceDataQuality(issues: issues)
    }

    private static func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }

    private static func saturatedMultiply(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? .max : value
    }

    private static func saturatedIncrement(_ value: Int) -> Int {
        value == .max ? .max : value + 1
    }

    private static func saturatedAddCount(_ value: Int, _ increment: Int64) -> Int {
        guard increment > 0 else { return value }
        if increment >= Int64(Int.max) { return .max }
        let amount = Int(increment)
        let (result, overflow) = value.addingReportingOverflow(amount)
        return overflow ? .max : result
    }

    private static func parameters(
        _ request: TraceDeterministicAnalysisRequest
    ) -> TraceDeterministicAnalysisParameters {
        let components = request.timeout.components
        return TraceDeterministicAnalysisParameters(
            filters: request.filters,
            maximumCPUSlices: request.maximumCPUSlices,
            maximumProcessSlices: request.maximumProcessSlices,
            maximumThreadSlices: request.maximumThreadSlices,
            maximumStateIntervals: request.maximumStateIntervals,
            maximumNamedSlices: request.maximumNamedSlices,
            maximumSchedulingEvents: request.maximumSchedulingEvents,
            maximumHotEvents: request.maximumHotEvents,
            topProcessLimit: request.topProcessLimit,
            topThreadLimit: request.topThreadLimit,
            longSliceLimit: request.longSliceLimit,
            schedulingSampleLimit: request.schedulingSampleLimit,
            hotIntervalLimit: request.hotIntervalLimit,
            hotBucketCount: request.hotBucketCount,
            minimumLongSliceDurationNs: request.minimumLongSliceDurationNs,
            timeoutSeconds: components.seconds,
            timeoutAttoseconds: components.attoseconds
        )
    }

    private static func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw ArkTraceError(
                code: .queryTimeout,
                stage: .analyzing,
                message: "Deterministic analysis deadline was reached",
                retryable: true
            )
        }
    }
}
