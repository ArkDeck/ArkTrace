import AppKit
import ArkTraceCore

package enum TimelineGeometry {
    public static let rulerHeight: CGFloat = 22
    public static let horizontalLabelInset: CGFloat = 3
    public static let minimumLabelWidth: CGFloat = 36
    /// Padding above the first depth row and below the last.
    public static let trackVerticalInset: CGFloat = 3
    /// Vertical stride of one depth row. A single-row track is therefore
    /// `2 * inset + span` = 28 points tall, which is what every track was
    /// before depth existed, so undepthed tracks keep their exact geometry.
    public static let depthRowSpan: CGFloat = 22

    /// Height a track needs to show `depthRowCount` rows.
    public static func trackHeight(depthRowCount: Int) -> Double {
        Double(2 * trackVerticalInset + CGFloat(max(1, depthRowCount)) * depthRowSpan)
    }

    /// One row's stride, derived from the snapshot rather than assumed, so a
    /// track whose height was chosen elsewhere still lays its rows out inside
    /// its own bounds.
    static func rowSpan(in track: TimelineTrackSnapshot) -> CGFloat {
        let usable = CGFloat(track.height) - 2 * trackVerticalInset
        return max(1, usable / CGFloat(max(1, track.depthRowCount)))
    }

    public static func x(
        for timeNs: Int64,
        viewport: TimelineViewport
    ) -> CGFloat {
        let delta: Int64
        if timeNs <= viewport.range.startNs {
            delta = 0
        } else if timeNs >= viewport.range.endNs {
            delta = viewport.range.durationNs
        } else {
            delta = timeNs - viewport.range.startNs
        }
        return CGFloat(Double(delta) / Double(viewport.range.durationNs)
            * viewport.widthPoints)
    }

    public static func time(
        forX x: CGFloat,
        viewport: TimelineViewport
    ) -> Int64 {
        let clampedX = min(max(0, Double(x)), viewport.widthPoints)
        if clampedX <= 0 { return viewport.range.startNs }
        if clampedX >= viewport.widthPoints { return viewport.range.endNs }
        let fraction = clampedX / viewport.widthPoints
        let scaled = (fraction * Double(viewport.range.durationNs)).rounded(.down)
        let maximumDelta = viewport.range.durationNs - 1
        let delta: Int64
        if !scaled.isFinite || scaled <= 0 {
            delta = 0
        } else if scaled >= Double(maximumDelta) {
            delta = maximumDelta
        } else {
            delta = Int64(scaled)
        }
        let (value, overflow) = viewport.range.startNs.addingReportingOverflow(delta)
        if overflow { return viewport.range.endNs }
        return min(value, viewport.range.endNs)
    }

    /// Horizontal reach of one selection endpoint handle, each side of its
    /// edge. The handle spans the whole track body vertically, so a 24 point
    /// wide column clears AT-APP-011's 24×24 floor.
    static let selectionHandleReach = TimelineAccessibilityLayout.minimumTargetPoints / 2

    /// The endpoint a press at `point` grabs, or `nil` for anywhere else.
    ///
    /// Two 24 point targets cannot both be centred on their edge once the
    /// selection is narrower than 24 points without overlapping, which
    /// AT-APP-011 forbids. Below that width the midpoint becomes the boundary
    /// and each handle extends *outward* instead, so both keep a full 24
    /// points and neither can be grabbed by mistake. The boundary point itself
    /// resolves to ``TimelineSelectionEndpoint/start``.
    package static func selectionEndpoint(
        at point: CGPoint,
        selection: TraceTimeRange,
        viewport: TimelineViewport
    ) -> TimelineSelectionEndpoint? {
        guard point.y >= rulerHeight else { return nil }
        let startX = x(for: selection.startNs, viewport: viewport)
        let endX = x(for: selection.endNs, viewport: viewport)
        let reach = selectionHandleReach
        let startRegion: ClosedRange<CGFloat>
        let endRegion: ClosedRange<CGFloat>
        if endX - startX >= TimelineAccessibilityLayout.minimumTargetPoints {
            startRegion = (startX - reach)...(startX + reach)
            endRegion = (endX - reach)...(endX + reach)
        } else {
            let midpoint = (startX + endX) / 2
            startRegion = (midpoint - 2 * reach)...midpoint
            endRegion = midpoint...(midpoint + 2 * reach)
        }
        if startRegion.contains(point.x) { return .start }
        if endRegion.contains(point.x) { return .end }
        return nil
    }

    public static func trackFrame(_ track: TimelineTrackSnapshot) -> CGRect {
        CGRect(
            x: 0,
            y: rulerHeight + CGFloat(track.y),
            width: .greatestFiniteMagnitude,
            height: CGFloat(track.height)
        )
    }

    /// Whether a primitive falls inside the viewport's range at all.
    ///
    /// `x(for:viewport:)` clamps, so a primitive outside the range does not
    /// vanish on its own -- it collapses onto whichever edge it is past and is
    /// drawn there as a minimum-width sliver. Nothing in a freshly loaded
    /// snapshot is out of range, but the generation that carries the previous
    /// primitives through a new viewport while a zoom or a pan loads is full
    /// of them, and a wall of slivers along both edges is not what the user
    /// asked to see.
    package static func isVisible(
        _ primitive: TimelinePrimitive,
        in viewport: TimelineViewport
    ) -> Bool {
        let range = primitive.range
        return range.endNs >= viewport.range.startNs
            && range.startNs <= viewport.range.endNs
    }

    public static func frame(
        for primitive: TimelinePrimitive,
        in track: TimelineTrackSnapshot,
        viewport: TimelineViewport,
        backingScale: CGFloat
    ) -> CGRect {
        let detail: TimelineDetailPrimitive
        switch primitive {
        case .detail(let value):
            detail = value
        case .density(let density):
            // A density bucket summarizes the whole track, so it spans every
            // reserved row rather than sitting in one.
            return bandFrame(
                for: density.bucket.range, in: track,
                viewport: viewport, backingScale: backingScale
            )
        }
        let startX = x(for: detail.range.startNs, viewport: viewport)
        let endX = x(for: detail.range.endNs, viewport: viewport)
        let minimumWidth = 1 / max(1, backingScale)
        let width = max(minimumWidth, endX - startX)
        let span = rowSpan(in: track)
        // Clamp to the rows the track actually reserved: a primitive deeper
        // than the track was sized for is drawn on the last row instead of
        // outside the track's bounds, where it could never be hit-tested.
        let row = CGFloat(min(max(0, detail.depth), max(0, track.depthRowCount - 1)))
        return CGRect(
            x: startX,
            y: rulerHeight + CGFloat(track.y) + trackVerticalInset + row * span,
            width: width,
            height: max(1, span)
        )
    }

    /// The rectangle a time range occupies across a whole track body.
    ///
    /// A density bucket summarizes every depth at once, so it spans all the
    /// reserved rows rather than sitting in one; so does the outline of a
    /// selection the current LOD draws no primitive for. Both come from here,
    /// which is what keeps the band a press lands on and the mark that press
    /// leaves behind in the same place.
    package static func bandFrame(
        for range: TraceTimeRange,
        in track: TimelineTrackSnapshot,
        viewport: TimelineViewport,
        backingScale: CGFloat
    ) -> CGRect {
        let startX = x(for: range.startNs, viewport: viewport)
        let endX = x(for: range.endNs, viewport: viewport)
        let minimumWidth = 1 / max(1, backingScale)
        return CGRect(
            x: startX,
            y: rulerHeight + CGFloat(track.y) + trackVerticalInset,
            width: max(minimumWidth, endX - startX),
            height: max(1, CGFloat(track.height) - 2 * trackVerticalInset)
        )
    }
}
