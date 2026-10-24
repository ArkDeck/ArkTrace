package enum TraceDensitySource: Hashable, Codable, Sendable {
    case cpu(Int64)
    case threadState(ThreadKey)
    case namedSlice(ThreadKey?)
    case cpuCounter(filterID: Int64, cpu: Int64?)
    case processCounter(filterID: Int64, processKey: ProcessKey?)
    case frame(processKey: ProcessKey?)
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

/// What a density bucket is mostly made of.
///
/// An aggregate bucket has no single event to take a colour from, which used
/// to mean the band could only be painted in a colour of the viewer's own
/// invention. Carrying the identity of the event that occupies the bucket
/// longest lets the band be filled the way that event would have been filled
/// at detail level, so zooming in changes the resolution of the picture rather
/// than its colours. The cases are exactly the identities the upstream palette
/// keys on.
public enum TraceDensityIdentity: Hashable, Codable, Sendable {
    /// A CPU slice's running process, or its thread when the scheduling row
    /// carries no process — upstream's `colorForThread` argument.
    case processOrThread(Int64)
    /// A named slice's name, hashed the way upstream hashes function names.
    case name(String)
    /// A thread state, kept as the raw upstream state string so it resolves
    /// through the same table the detail rows use.
    case threadState(String)
    /// A frame's `jank_tag`.
    case jank(Int64)
}

public struct TraceDensityBucket: Hashable, Codable, Sendable {
    public let range: TraceTimeRange
    public let eventCount: Int64
    public let occupiedNs: Int64?
    public let utilization: Double?
    /// The identity of the longest event in the bucket, when the source has
    /// one. Longest rather than most frequent: it is the event that would
    /// cover most of these pixels at detail level, so it is the one whose
    /// colour the band should borrow.
    public let dominant: TraceDensityIdentity?

    public init(
        range: TraceTimeRange,
        eventCount: Int64,
        occupiedNs: Int64?,
        utilization: Double?,
        dominant: TraceDensityIdentity?
    ) {
        self.range = range
        self.eventCount = eventCount
        self.occupiedNs = occupiedNs
        self.utilization = utilization
        self.dominant = dominant
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
