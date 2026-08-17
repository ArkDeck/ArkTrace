import AppKit
import ArkTraceCore

package enum TimelineGeometry {
    public static let rulerHeight: CGFloat = 22
    public static let horizontalLabelInset: CGFloat = 3
    public static let minimumLabelWidth: CGFloat = 36

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

    public static func trackFrame(_ track: TimelineTrackSnapshot) -> CGRect {
        CGRect(
            x: 0,
            y: rulerHeight + CGFloat(track.y),
            width: .greatestFiniteMagnitude,
            height: CGFloat(track.height)
        )
    }

    public static func frame(
        for primitive: TimelinePrimitive,
        in track: TimelineTrackSnapshot,
        viewport: TimelineViewport,
        backingScale: CGFloat
    ) -> CGRect {
        let range: TraceTimeRange
        switch primitive {
        case .detail(let detail): range = detail.range
        case .density(let density): range = density.bucket.range
        }
        let startX = x(for: range.startNs, viewport: viewport)
        let endX = x(for: range.endNs, viewport: viewport)
        let minimumWidth = 1 / max(1, backingScale)
        let width = max(minimumWidth, endX - startX)
        return CGRect(
            x: startX,
            y: rulerHeight + CGFloat(track.y) + 3,
            width: width,
            height: max(1, CGFloat(track.height) - 6)
        )
    }
}
