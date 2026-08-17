package enum TraceDensitySource: Hashable, Codable, Sendable {
    case cpu(Int64)
    case threadState(ThreadKey)
    case namedSlice(ThreadKey?)
    case cpuCounter(filterID: Int64, cpu: Int64?)
    case processCounter(filterID: Int64, processKey: ProcessKey?)
}

package struct TraceDensityQuery: Sendable {
    public let range: TraceTimeRange
    public let source: TraceDensitySource
    public let bucketCount: Int
    public let deadline: ContinuousClock.Instant

    public init(
        range: TraceTimeRange,
        source: TraceDensitySource,
        bucketCount: Int,
        deadline: ContinuousClock.Instant
    ) throws {
        guard range.startNs < range.endNs else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Density range must be non-empty"
            )
        }
        guard (1...40_000).contains(bucketCount) else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "bucketCount must be within 1...40000"
            )
        }
        self.range = range
        self.source = source
        self.bucketCount = bucketCount
        self.deadline = deadline
    }
}
public struct TraceDensityBucket: Hashable, Codable, Sendable {
    public let range: TraceTimeRange
    public let eventCount: Int64
    public let occupiedNs: Int64?
    public let utilization: Double?
    public let dominantThreadKey: ThreadKey?

    public init(
        range: TraceTimeRange,
        eventCount: Int64,
        occupiedNs: Int64?,
        utilization: Double?,
        dominantThreadKey: ThreadKey?
    ) {
        self.range = range
        self.eventCount = eventCount
        self.occupiedNs = occupiedNs
        self.utilization = utilization
        self.dominantThreadKey = dominantThreadKey
    }
}

package struct TraceDensityResult: Sendable {
    public let buckets: [TraceDensityBucket]
    public let capabilityAvailable: Bool
    public let dataQuality: TraceDataQuality

    public init(
        buckets: [TraceDensityBucket],
        capabilityAvailable: Bool = true,
        dataQuality: TraceDataQuality = TraceDataQuality()
    ) {
        self.buckets = buckets
        self.capabilityAvailable = capabilityAvailable
        self.dataQuality = dataQuality
    }

    public static var unavailable: TraceDensityResult {
        TraceDensityResult(buckets: [], capabilityAvailable: false)
    }
}
