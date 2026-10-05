import CoreGraphics

/// Native immutable geometry is used for the exact display viewport/scale.
/// While an intent loads, the existing platform transform keeps pan/zoom live.
package struct TimelinePrimitiveProjection: Hashable, Sendable {
    package let viewport: TimelineViewport
    package let backingScale: Double
    package let frame: CGRect?
    package let colorRGB: UInt32
    package func frame(in viewport: TimelineViewport, scale: CGFloat) -> CGRect? {
        guard self.viewport.range == viewport.range,
            self.viewport.widthPoints == viewport.widthPoints,
            self.viewport.heightPoints == viewport.heightPoints,
            self.viewport.verticalOffsetPoints == viewport.verticalOffsetPoints,
            backingScale == Double(scale) else { return nil }
        return frame
    }
    package var color: TimelineColor {
        TimelineColor(red: UInt8((colorRGB >> 16) & 255),
            green: UInt8((colorRGB >> 8) & 255), blue: UInt8(colorRGB & 255))
    }
}
