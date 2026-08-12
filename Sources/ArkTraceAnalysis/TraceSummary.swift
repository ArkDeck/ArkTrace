import ArkTraceCore
import Foundation

private final class TraceSummaryDeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func add(_ task: Task<Void, Never>) {
        lock.lock()
        if result != nil {
            lock.unlock()
            task.cancel()
        } else {
            tasks.append(task)
            lock.unlock()
        }
    }

    func finish(_ result: Result<Value, any Error>) {
        let continuation: CheckedContinuation<Value, any Error>?
        let tasks: [Task<Void, Never>]
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        continuation = self.continuation
        self.continuation = nil
        tasks = self.tasks
        self.tasks.removeAll(keepingCapacity: false)
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}

public enum TraceSummarySection: String, Codable, Sendable, CaseIterable {
    case cpuCount
    case processCount
    case threadCount
    case cpuSliceCount
    case threadStateCount
    case namedSliceCount
    case counterSeriesCount
    case eventCountBySource
}

public struct TraceSummaryRequest: Sendable {
    public let range: TraceTimeRange?
    public let maximumRowsPerSection: Int
    public let timeout: Duration

    public init(
        range: TraceTimeRange? = nil,
        maximumRowsPerSection: Int = 100_000,
        timeout: Duration = .seconds(30)
    ) throws {
        guard maximumRowsPerSection >= 1, maximumRowsPerSection <= 1_000_000 else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "maximumRowsPerSection must be within 1...1000000"
            )
        }
        guard timeout > .zero, timeout <= .seconds(300) else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "summary timeout must be within (0, 300] seconds"
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
        self.timeout = timeout
    }
}

/// Deterministic, path-free summary reduction (AT-AN-001/009). Optional event
/// counts represent unsupported evidence, never a guessed zero.
public struct TraceSummary: Hashable, Codable, Sendable {
    public let range: TraceTimeRange
    public let durationNs: Int64
    public let cpuCount: Int64?
    public let processCount: Int64
    public let threadCount: Int64
    public let cpuSliceCount: Int64?
    public let threadStateCount: Int64?
    public let namedSliceCount: Int64?
    public let counterSeriesCount: Int64?
    public let eventCountBySource: [TraceEventSourceCount]?
    public let capabilities: TraceCapabilities
    public let schemaFingerprint: String
    public let dataQuality: TraceDataQuality
    public let truncatedSections: [TraceSummarySection]

    public init(
        range: TraceTimeRange,
        durationNs: Int64,
        cpuCount: Int64?,
        processCount: Int64,
        threadCount: Int64,
        cpuSliceCount: Int64?,
        threadStateCount: Int64?,
        namedSliceCount: Int64?,
        counterSeriesCount: Int64?,
        eventCountBySource: [TraceEventSourceCount]?,
        capabilities: TraceCapabilities,
        schemaFingerprint: String,
        dataQuality: TraceDataQuality,
        truncatedSections: [TraceSummarySection]
    ) {
        self.range = range
        self.durationNs = durationNs
        self.cpuCount = cpuCount
        self.processCount = processCount
        self.threadCount = threadCount
        self.cpuSliceCount = cpuSliceCount
        self.threadStateCount = threadStateCount
        self.namedSliceCount = namedSliceCount
        self.counterSeriesCount = counterSeriesCount
        self.eventCountBySource = eventCountBySource
        self.capabilities = capabilities
        self.schemaFingerprint = schemaFingerprint
        self.dataQuality = dataQuality
        self.truncatedSections = truncatedSections
    }

    private enum CodingKeys: String, CodingKey {
        case range
        case durationNs
        case cpuCount
        case processCount
        case threadCount
        case cpuSliceCount
        case threadStateCount
        case namedSliceCount
        case counterSeriesCount
        case eventCountBySource
        case capabilities
        case schemaFingerprint
        case dataQuality
        case truncatedSections
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(range, forKey: .range)
        try container.encode(durationNs, forKey: .durationNs)
        try encodeNullable(cpuCount, to: &container, forKey: .cpuCount)
        try container.encode(processCount, forKey: .processCount)
        try container.encode(threadCount, forKey: .threadCount)
        try encodeNullable(cpuSliceCount, to: &container, forKey: .cpuSliceCount)
        try encodeNullable(threadStateCount, to: &container, forKey: .threadStateCount)
        try encodeNullable(namedSliceCount, to: &container, forKey: .namedSliceCount)
        try encodeNullable(counterSeriesCount, to: &container, forKey: .counterSeriesCount)
        try encodeNullable(eventCountBySource, to: &container, forKey: .eventCountBySource)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(schemaFingerprint, forKey: .schemaFingerprint)
        try container.encode(dataQuality, forKey: .dataQuality)
        try container.encode(truncatedSections, forKey: .truncatedSections)
    }

    private func encodeNullable<T: Encodable>(
        _ value: T?,
        to container: inout KeyedEncodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }
}

public struct TraceSummaryEngine: Sendable {
    private let repository: any TraceRepositoryProtocol

    public init(repository: any TraceRepositoryProtocol) {
        self.repository = repository
    }

    public func summarize(_ request: TraceSummaryRequest) async throws -> TraceSummary {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: request.timeout)
        do {
            let race = TraceSummaryDeadlineRace<TraceSummary>()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    race.install(continuation)
                    let operation = Task {
                        do {
                            race.finish(.success(
                                try await summarize(request, deadline: deadline)
                            ))
                        } catch {
                            race.finish(.failure(error))
                        }
                    }
                    race.add(operation)
                    let timer = Task {
                        do {
                            try await clock.sleep(until: deadline)
                            race.finish(.failure(Self.timeoutError()))
                        } catch {
                            // The winning operation/cancellation cancels this
                            // timer; its result has already been published.
                        }
                    }
                    race.add(timer)
                }
            } onCancel: {
                race.finish(.failure(CancellationError()))
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw ArkTraceError(
                    code: .cancelled,
                    stage: .analyzing,
                    message: "Trace summary was cancelled",
                    retryable: true
                )
            }
            throw error
        }
    }

    private func summarize(
        _ request: TraceSummaryRequest,
        deadline: ContinuousClock.Instant
    ) async throws -> TraceSummary {
        try Self.checkBoundary(deadline)
        let metadata = try await repository.metadata()
        try Self.checkBoundary(deadline)

        let range: TraceTimeRange
        if let requested = request.range {
            guard requested.startNs < requested.endNs,
                requested.endNs <= metadata.durationNs
            else {
                throw ArkTraceError(
                    code: .invalidArgument,
                    stage: .request,
                    message: "Summary range is empty or exceeds trace duration"
                )
            }
            range = requested
        } else {
            range = try TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs)
        }
        let facts = try await repository.summaryFacts(
            try TraceSummaryQuery(
                range: request.range,
                maximumRowsPerSection: request.maximumRowsPerSection,
                deadline: deadline
            )
        )
        try Self.checkBoundary(deadline)

        var truncated: [TraceSummarySection] = []
        let ordered: [(TraceSummarySection, TraceBoundedCount?)] = [
            (.cpuCount, facts.cpuCount),
            (.processCount, facts.processCount),
            (.threadCount, facts.threadCount),
            (.cpuSliceCount, facts.cpuSliceCount),
            (.threadStateCount, facts.threadStateCount),
            (.namedSliceCount, facts.namedSliceCount),
            (.counterSeriesCount, facts.counterSeriesCount),
        ]
        for (index, pair) in ordered.enumerated() {
            if index.isMultiple(of: 4) { try Self.checkBoundary(deadline) }
            if pair.1?.truncated == true { truncated.append(pair.0) }
        }
        if facts.eventCountBySource?.truncated == true {
            truncated.append(.eventCountBySource)
        }

        let eventCounts = try facts.eventCountBySource.map {
            try Self.sortedEventCounts($0.items, deadline: deadline)
        }
        let combinedQuality = TraceDataQuality(
            warnings: metadata.dataQuality.warnings + facts.warnings,
            issues: metadata.dataQuality.issues + facts.qualityIssues
        )
        let qualityIssues = Array(Set(combinedQuality.issues)).sorted {
            let lhs = ($0.category.rawValue, $0.scope ?? "", $0.count ?? Int64.min, $0.message ?? "")
            let rhs = ($1.category.rawValue, $1.scope ?? "", $1.count ?? Int64.min, $1.message ?? "")
            return lhs < rhs
        }
        try Self.checkBoundary(deadline)
        return TraceSummary(
            range: range,
            durationNs: range.durationNs,
            cpuCount: facts.cpuCount?.value,
            processCount: facts.processCount.value,
            threadCount: facts.threadCount.value,
            cpuSliceCount: facts.cpuSliceCount?.value,
            threadStateCount: facts.threadStateCount?.value,
            namedSliceCount: facts.namedSliceCount?.value,
            counterSeriesCount: facts.counterSeriesCount?.value,
            eventCountBySource: eventCounts,
            capabilities: metadata.capabilities,
            schemaFingerprint: metadata.schemaFingerprint,
            dataQuality: TraceDataQuality(issues: qualityIssues),
            truncatedSections: truncated
        )
    }

    private static func sortedEventCounts(
        _ values: [TraceEventSourceCount],
        deadline: ContinuousClock.Instant
    ) throws -> [TraceEventSourceCount] {
        guard values.count > 1 else { return values }
        var source = values
        var destination = values
        var width = 1
        var operations = 0
        func ordered(_ lhs: TraceEventSourceCount, _ rhs: TraceEventSourceCount) -> Bool {
            let lhsBytes = Data(lhs.source.utf8)
            let rhsBytes = Data(rhs.source.utf8)
            if lhsBytes != rhsBytes {
                return lhsBytes.lexicographicallyPrecedes(rhsBytes)
            }
            return lhs.count <= rhs.count
        }
        while width < source.count {
            var lower = 0
            while lower < source.count {
                let middle = min(lower + width, source.count)
                let upper = min(lower + width + width, source.count)
                var left = lower
                var right = middle
                var output = lower
                while left < middle || right < upper {
                    if right >= upper || (left < middle && ordered(source[left], source[right])) {
                        destination[output] = source[left]
                        left += 1
                    } else {
                        destination[output] = source[right]
                        right += 1
                    }
                    output += 1
                    operations += 1
                    if operations.isMultiple(of: 1_024) { try checkBoundary(deadline) }
                }
                lower = upper
            }
            swap(&source, &destination)
            width = width > source.count / 2 ? source.count : width * 2
            try checkBoundary(deadline)
        }
        return source
    }

    private static func checkBoundary(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw timeoutError() }
    }

    private static func timeoutError() -> ArkTraceError {
        ArkTraceError(
            code: .queryTimeout,
            stage: .analyzing,
            message: "Summary deadline was reached",
            retryable: true
        )
    }
}

/// Canonical encoder for Analysis-owned result bytes. The later machine
/// envelope may wrap these fields, but must preserve their deterministic order
/// and integer representation (AT-JSON-002/003).
public enum TraceSummaryJSONEncoder {
    public static func encode(_ summary: TraceSummary) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(summary)
    }
}
