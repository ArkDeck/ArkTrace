import ArkTraceCore
import CoreGraphics
import Foundation

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
    case namedSlice(ThreadKey?)
    case cpuCounter(filterID: Int64, cpu: Int64?)
    case processCounter(filterID: Int64, processKey: ProcessKey?)
    /// Expected and actual frames for one process, drawn as two rows.
    case frame(ProcessKey?)

    public var stableID: TimelineTrackID {
        switch self {
        case .cpu(let cpu): return TimelineTrackID(rawValue: "cpu:\(cpu)")
        case .threadState(let key):
            return TimelineTrackID(rawValue: "thread-state:\(key.itid)")
        case .namedSlice(let key):
            return TimelineTrackID(
                rawValue: "named-slice:\(key.map { String($0.itid) } ?? "unattributed")"
            )
        case .cpuCounter(let filterID, let cpu):
            return TimelineTrackID(rawValue: "cpu-counter:\(filterID):\(cpu.map(String.init) ?? "all")")
        case .processCounter(let filterID, let processKey):
            return TimelineTrackID(
                rawValue: "process-counter:\(filterID):\(processKey.map { String($0.ipid) } ?? "all")"
            )
        case .frame(let processKey):
            return TimelineTrackID(
                rawValue: "frame:\(processKey.map { String($0.ipid) } ?? "all")"
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
        case .frame(let processKey):
            return .frame(processKey: processKey)
        }
    }
}

public struct TrackDescriptor: Hashable, Codable, Sendable {
    public let id: TimelineTrackID
    public let title: String
    public let source: TimelineTrackSource
    /// Track visibility. A collapsed track is not rendered at all; this is how
    /// a 199-thread trace stays navigable (AT-APP-003).
    public let isCollapsed: Bool
    /// Whether nested call depth gets its own row. Independent of
    /// ``isCollapsed``: hiding a track and flattening its call stack are
    /// different requests, and overloading one control would remove the
    /// ability to hide. Only named-slice tracks have depth to flatten; false
    /// draws depth 0 alone, in one row, and never discards session data
    /// (DESIGN §13.3).
    public let showsNestedDepth: Bool

    public init(
        title: String,
        source: TimelineTrackSource,
        isCollapsed: Bool = false,
        showsNestedDepth: Bool = true
    ) {
        self.id = source.stableID
        self.title = title
        self.source = source
        self.isCollapsed = isCollapsed
        self.showsNestedDepth = showsNestedDepth
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

    /// Converts a pan expressed in points into a saturating nanosecond delta.
    ///
    /// `nsPerPoint` is finite and positive by construction, but `points`
    /// arrives from AppKit input. An infinite product saturates, which the
    /// caller then clamps against the trace bounds. NaN is not a pan at all,
    /// and it compares false against both saturation bounds, so it must be
    /// rejected before the `Int64` conversion traps.
    public func nanosecondDelta(forPoints points: Double) -> Int64 {
        let raw = points * nsPerPoint
        guard !raw.isNaN else { return 0 }
        if raw >= Double(Int64.max) { return .max }
        if raw <= Double(Int64.min) { return .min }
        return Int64(raw.rounded())
    }
}

package enum TimelineDetailPreference: String, Codable, Sendable {
    case automatic
    case detail
    case density
}

public enum TimelineViewportIntent: Sendable {
    case panPoints(Double, sourceViewport: TimelineViewport)
    case zoom(anchorNs: Int64, scale: Double, sourceViewport: TimelineViewport)
}

/// Bounded keyboard actions supported by the single Timeline accessibility
/// element. Navigation never materializes events outside the current snapshot.
package enum TimelineKeyboardCommand: Hashable, Sendable {
    case previousEvent
    case nextEvent
    case previousTrack
    case nextTrack
    case panBackward
    case panForward
    case zoomIn
    case zoomOut
    /// SmartPerf Host's `W` / `S`. Same zoom step as ``zoomIn`` / ``zoomOut``,
    /// but anchored at the pointer the way upstream anchors on its
    /// `centerXPercentage`, so the trace grows around what is under the cursor
    /// instead of around the selection or the viewport center.
    case zoomInAtPointer
    case zoomOutAtPointer
    case selectFocusedEvent
    case zoomSelection
    case resetViewport
    case clearSelection
}

/// Which edge of a range selection a gesture is acting on. Upstream keeps the
/// same identity in `RangeRuler.ts:88-89` as `markAObj` / `markBObj`, so an
/// endpoint drag moves one edge and leaves the other where it is.
package enum TimelineSelectionEndpoint: Hashable, Sendable {
    case start
    case end
}

public enum TimelineAccessibilityLayout {
    /// AT-APP-011 hard floor for every custom interactive target.
    public static let minimumTargetPoints: CGFloat = 24
    /// Desktop primary-toolbar target used by the native App shell.
    public static let primaryToolbarTargetPoints: CGFloat = 40
}

/// What one scroll gesture means to the timeline. Resolved from the event's
/// deltas and modifiers before any viewport work, so the mapping is testable
/// without synthesizing an `NSEvent`.
package enum TimelineScrollResolution: Hashable, Sendable {
    /// Not ours: let the enclosing scroll view have it (vertical scrolling).
    case passThrough
    case pan(points: Double)
    /// Same units as ``TimelineViewportIntent/zoom``: below 1 narrows the
    /// viewport, above 1 widens it.
    case zoom(scale: Double)
}

/// Scroll-wheel semantics.
///
/// Upstream binds `Ctrl + Scroll wheel` to zoom (`component/SpKeyboard.html.ts`
/// Mouse Controls). ArkTrace accepts ⌃ and ⌥ both: ⌃-scroll is taken by the
/// system's zoom accessibility feature on many machines, and ⌥ is the macOS
/// convention for "the other axis / the finer gesture".
package enum TimelineScrollGesture {
    /// Points a legacy wheel detent is worth. AppKit reports non-precise
    /// deltas in lines; this is the same order as the line height AppKit's own
    /// scroll views use, so one detent is a visible but not violent step.
    static let pointsPerLine: Double = 16
    /// Zoom exponent per point of scroll. One wheel detent (16 points) is
    /// `exp(-0.16)` ≈ 0.85, i.e. about 17% per detent.
    static let zoomExponentPerPoint: Double = 0.01
    /// Ceiling on a single event's exponent, so a flung trackpad cannot
    /// teleport the viewport: at most e× in or out per event.
    static let maximumZoomExponent: Double = 1

    /// Deltas below this are noise from the orthogonal axis of a gesture.
    static let deadZonePoints: Double = 0.01

    static func resolve(
        deltaX: Double,
        deltaY: Double,
        hasPreciseDeltas: Bool,
        zooms: Bool
    ) -> TimelineScrollResolution {
        let vertical = hasPreciseDeltas ? deltaY : deltaY * pointsPerLine
        // Zoom reads the vertical axis only, which is the one a wheel mouse
        // has. A modified horizontal scroll keeps panning rather than becoming
        // an accidental zoom.
        if zooms, abs(vertical) > deadZonePoints {
            let exponent = min(
                maximumZoomExponent,
                max(-maximumZoomExponent, vertical * zoomExponentPerPoint)
            )
            // Scrolling up (positive delta) zooms in, matching the sign
            // convention `magnify(with:)` uses for a pinch-out.
            return .zoom(scale: exp(-exponent))
        }
        // Panning keeps consuming the raw horizontal delta it always did:
        // normalizing it here would silently make every existing wheel pan
        // sixteen times longer.
        guard abs(deltaX) > deadZonePoints else { return .passThrough }
        return .pan(points: deltaX)
    }
}

package enum TimelineInteraction {
    public static func pan(
        range: TraceTimeRange,
        deltaNs: Int64,
        within bounds: TraceTimeRange
    ) throws -> TraceTimeRange {
        guard range.startNs >= bounds.startNs, range.endNs <= bounds.endNs else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Viewport range exceeds trace bounds"
            )
        }
        let maximumStart = bounds.endNs - range.durationNs
        let candidate: Int64
        let (value, overflow) = range.startNs.addingReportingOverflow(deltaNs)
        if overflow {
            candidate = deltaNs < 0 ? bounds.startNs : maximumStart
        } else {
            candidate = value
        }
        let start = min(max(bounds.startNs, candidate), maximumStart)
        return try TraceTimeRange.query(
            startNs: start,
            endNs: start + range.durationNs
        )
    }

    public static func zoom(
        range: TraceTimeRange,
        anchorNs: Int64,
        scale: Double,
        within bounds: TraceTimeRange
    ) throws -> TraceTimeRange {
        guard scale.isFinite, scale > 0,
            range.startNs >= bounds.startNs,
            range.endNs <= bounds.endNs
        else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Zoom request is invalid"
            )
        }
        let boundedScale = min(20, max(0.05, scale))
        let proposed = Double(range.durationNs) * boundedScale
        let newDuration: Int64
        if !proposed.isFinite || proposed >= Double(bounds.durationNs) {
            newDuration = bounds.durationNs
        } else {
            newDuration = max(1, Int64(proposed.rounded()))
        }
        if newDuration >= bounds.durationNs { return bounds }
        let anchor = min(max(range.startNs, anchorNs), range.endNs)
        let fraction = Double(anchor - range.startNs) / Double(range.durationNs)
        let offsetDouble = fraction * Double(newDuration)
        let offset = offsetDouble >= Double(Int64.max)
            ? Int64.max
            : max(0, Int64(offsetDouble.rounded(.down)))
        let rawStart: Int64
        let (candidate, underflow) = anchor.subtractingReportingOverflow(offset)
        rawStart = underflow ? bounds.startNs : candidate
        let maximumStart = bounds.endNs - newDuration
        let start = min(max(bounds.startNs, rawStart), maximumStart)
        return try TraceTimeRange.query(startNs: start, endNs: start + newDuration)
    }
}

package struct ViewportRequest: Sendable {
    public let viewport: TimelineViewport
    public let tracks: [TrackDescriptor]
    public let pixelWidth: Int
    public let generation: UInt64
    public let preference: TimelineDetailPreference
    public let maximumPrimitives: Int
    public let focusedEventKey: EventKey?
    public let deadline: ContinuousClock.Instant

    public init(
        viewport: TimelineViewport,
        tracks: [TrackDescriptor],
        pixelWidth: Int,
        generation: UInt64,
        preference: TimelineDetailPreference = .automatic,
        maximumPrimitives: Int? = nil,
        focusedEventKey: EventKey? = nil,
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
        self.focusedEventKey = focusedEventKey
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
    public let inspector: TraceEventInspector?
    /// Call depth for named slices; every other event type is 0. Depth selects
    /// the row within the track and is deliberately **not** part of the fill
    /// colour: upstream passes a literal `0` as the second argument of its
    /// colour hash at the pinned revision, so mixing real depth in here would
    /// silently diverge from it (UPSTREAM_ALIGNMENT_AUDIT §5).
    public let depth: Int
    /// Upstream's `jank_tag` for frame primitives; 0 for everything else.
    public let jankTag: Int64

    public init(
        trackID: TimelineTrackID,
        eventKey: EventKey,
        range: TraceTimeRange,
        label: String? = nil,
        category: String? = nil,
        inspector: TraceEventInspector? = nil,
        depth: Int = 0,
        jankTag: Int64 = 0
    ) {
        self.trackID = trackID
        self.eventKey = eventKey
        self.range = range
        self.label = label
        self.category = category
        self.inspector = inspector
        self.depth = max(0, depth)
        self.jankTag = jankTag
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
    /// Depth rows this track reserves, at least 1. `height` is sized for
    /// exactly this many rows, so geometry can derive one row's stride from
    /// the snapshot instead of assuming a constant — draw and hit-test then
    /// cannot drift apart (AT-RENDER-003).
    public let depthRowCount: Int

    public init(
        descriptor: TrackDescriptor,
        y: Double,
        height: Double,
        primitives: [TimelinePrimitive],
        depthRowCount: Int = 1
    ) {
        self.descriptor = descriptor
        self.y = y
        self.height = height
        self.primitives = primitives
        self.depthRowCount = max(1, depthRowCount)
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
