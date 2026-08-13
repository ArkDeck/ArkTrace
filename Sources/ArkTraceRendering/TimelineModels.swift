import ArkTraceCore

public struct TimelineTrackID: Hashable, Codable, Sendable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: TimelineTrackID, rhs: TimelineTrackID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum TimelineTrackSource: Hashable, Codable, Sendable {
    case cpu(Int64)
    case threadState(ThreadKey)
    case namedSlice(ThreadKey)
    case cpuCounter(filterID: Int64, cpu: Int64?)
    case processCounter(filterID: Int64, processKey: ProcessKey?)

    var stableID: TimelineTrackID {
        switch self {
        case .cpu(let cpu): return TimelineTrackID(rawValue: "cpu:\(cpu)")
        case .threadState(let key):
            return TimelineTrackID(rawValue: "thread-state:\(key.itid)")
        case .namedSlice(let key):
            return TimelineTrackID(rawValue: "named-slice:\(key.itid)")
        case .cpuCounter(let filterID, let cpu):
            return TimelineTrackID(rawValue: "cpu-counter:\(filterID):\(cpu.map(String.init) ?? "all")")
        case .processCounter(let filterID, let processKey):
            return TimelineTrackID(
                rawValue: "process-counter:\(filterID):\(processKey.map { String($0.ipid) } ?? "all")"
            )
        }
    }

    var densitySource: TraceDensitySource {
        switch self {
        case .cpu(let cpu): return .cpu(cpu)
        case .threadState(let key): return .threadState(key)
        case .namedSlice(let key): return .namedSlice(key)
        case .cpuCounter(let filterID, let cpu):
            return .cpuCounter(filterID: filterID, cpu: cpu)
        case .processCounter(let filterID, let processKey):
            return .processCounter(filterID: filterID, processKey: processKey)
        }
    }
}

public struct TrackDescriptor: Hashable, Codable, Sendable {
    public let id: TimelineTrackID
    public let title: String
    public let source: TimelineTrackSource
    public let isCollapsed: Bool

    public init(title: String, source: TimelineTrackSource, isCollapsed: Bool = false) {
        self.id = source.stableID
        self.title = title
        self.source = source
        self.isCollapsed = isCollapsed
    }
}

public struct TimelineViewport: Hashable, Codable, Sendable {
    public let range: TraceTimeRange
    public let nsPerPoint: Double
    public let widthPoints: Double
    public let heightPoints: Double
    public let verticalOffsetPoints: Double
    public let generation: UInt64

    public init(
        range: TraceTimeRange,
        widthPoints: Double,
        heightPoints: Double,
        verticalOffsetPoints: Double = 0,
        generation: UInt64
    ) throws {
        guard range.startNs < range.endNs,
            widthPoints.isFinite, widthPoints > 0,
            heightPoints.isFinite, heightPoints > 0,
            verticalOffsetPoints.isFinite, verticalOffsetPoints >= 0
        else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Timeline viewport dimensions or range are invalid"
            )
        }
        let nsPerPoint = Double(range.durationNs) / widthPoints
        guard nsPerPoint.isFinite, nsPerPoint > 0 else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Timeline viewport scale is not representable"
            )
        }
        self.range = range
        self.nsPerPoint = nsPerPoint
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.verticalOffsetPoints = verticalOffsetPoints
        self.generation = generation
    }
}

public enum TimelineDetailPreference: String, Codable, Sendable {
    case automatic
    case detail
    case density
}

public struct ViewportRequest: Sendable {
    public let viewport: TimelineViewport
    public let tracks: [TrackDescriptor]
    public let pixelWidth: Int
    public let generation: UInt64
    public let preference: TimelineDetailPreference
    public let maximumPrimitives: Int
    public let deadline: ContinuousClock.Instant

    public init(
        viewport: TimelineViewport,
        tracks: [TrackDescriptor],
        pixelWidth: Int,
        generation: UInt64,
        preference: TimelineDetailPreference = .automatic,
        maximumPrimitives: Int? = nil,
        deadline: ContinuousClock.Instant
    ) throws {
        guard pixelWidth >= 1, pixelWidth <= 100_000,
            generation == viewport.generation,
            tracks.count <= 10_000
        else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Viewport request bounds are invalid"
            )
        }
        let defaultBudget = Self.detailBudget(pixelWidth: pixelWidth)
        let requested = maximumPrimitives ?? defaultBudget
        guard requested >= 1, requested <= 20_000 else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "maximumPrimitives must be within 1...20000"
            )
        }
        self.viewport = viewport
        self.tracks = tracks
        self.pixelWidth = pixelWidth
        self.generation = generation
        self.preference = preference
        self.maximumPrimitives = min(requested, defaultBudget)
        self.deadline = deadline
    }

    public static func detailBudget(pixelWidth: Int) -> Int {
        let (scaled, overflow) = max(0, pixelWidth).multipliedReportingOverflow(by: 8)
        return min(20_000, max(2_000, overflow ? 20_000 : scaled))
    }
}

public struct TimelineDetailPrimitive: Hashable, Codable, Sendable {
    public let trackID: TimelineTrackID
    public let eventKey: EventKey
    public let range: TraceTimeRange
    public let label: String?
    public let category: String?

    public init(
        trackID: TimelineTrackID,
        eventKey: EventKey,
        range: TraceTimeRange,
        label: String? = nil,
        category: String? = nil
    ) {
        self.trackID = trackID
        self.eventKey = eventKey
        self.range = range
        self.label = label
        self.category = category
    }
}

public struct TimelineDensityPrimitive: Hashable, Codable, Sendable {
    public let trackID: TimelineTrackID
    public let bucket: TraceDensityBucket

    public init(trackID: TimelineTrackID, bucket: TraceDensityBucket) {
        self.trackID = trackID
        self.bucket = bucket
    }
}

public enum TimelinePrimitive: Hashable, Codable, Sendable {
    case detail(TimelineDetailPrimitive)
    case density(TimelineDensityPrimitive)

    public var selectableEventKey: EventKey? {
        if case .detail(let primitive) = self { return primitive.eventKey }
        return nil
    }
}

public struct TimelineTrackSnapshot: Hashable, Codable, Sendable {
    public let descriptor: TrackDescriptor
    public let y: Double
    public let height: Double
    public let primitives: [TimelinePrimitive]

    public init(
        descriptor: TrackDescriptor,
        y: Double,
        height: Double,
        primitives: [TimelinePrimitive]
    ) {
        self.descriptor = descriptor
        self.y = y
        self.height = height
        self.primitives = primitives
    }
}

public struct TimelineSnapshot: Hashable, Codable, Sendable {
    public let viewport: TimelineViewport
    public let tracks: [TimelineTrackSnapshot]
    public let generation: UInt64
    public let dataQuality: TraceDataQuality
    public let isLoading: Bool

    public init(
        viewport: TimelineViewport,
        tracks: [TimelineTrackSnapshot],
        generation: UInt64,
        dataQuality: TraceDataQuality,
        isLoading: Bool = false
    ) {
        self.viewport = viewport
        self.tracks = tracks
        self.generation = generation
        self.dataQuality = dataQuality
        self.isLoading = isLoading
    }

    public var primitiveCount: Int {
        tracks.reduce(0) { $0 + $1.primitives.count }
    }
}
