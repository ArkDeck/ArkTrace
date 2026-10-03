import ArkTraceCore
import Foundation

public struct RustViewport: Codable, Sendable {
    public let range: TraceTimeRange
    public let widthPoints: Double
    public let heightPoints: Double
    public let verticalOffsetPoints: Double
    public let generation: UInt64
    public init(range: TraceTimeRange, widthPoints: Double, heightPoints: Double, verticalOffsetPoints: Double, generation: UInt64) {
        self.range = range; self.widthPoints = widthPoints; self.heightPoints = heightPoints
        self.verticalOffsetPoints = verticalOffsetPoints; self.generation = generation
    }
}
public struct RustTrack: Codable, Sendable {
    public let source: RustDensitySource
    public let isCollapsed: Bool
    public let showsNestedDepth: Bool
    public init(source: RustDensitySource, isCollapsed: Bool = false, showsNestedDepth: Bool = true) {
        self.source = source; self.isCollapsed = isCollapsed; self.showsNestedDepth = showsNestedDepth
    }
}
public enum RustDetailPreference: String, Codable, Sendable { case automatic, detail, density }
public struct RustViewportRequest: Codable, Sendable {
    public let viewport: RustViewport
    public let tracks: [RustTrack]
    public let pixelWidth: Int
    public let generation: UInt64
    public let preference: RustDetailPreference
    public let maximumPrimitives: Int?
    public let focusedEventKey: EventKey?
    public init(viewport: RustViewport, tracks: [RustTrack], pixelWidth: Int, generation: UInt64, preference: RustDetailPreference = .automatic, maximumPrimitives: Int? = nil, focusedEventKey: EventKey? = nil) {
        self.viewport = viewport; self.tracks = tracks; self.pixelWidth = pixelWidth; self.generation = generation
        self.preference = preference; self.maximumPrimitives = maximumPrimitives; self.focusedEventKey = focusedEventKey
    }
}
public struct RustViewportQuery: Codable, Sendable {
    public let request: RustViewportRequest
    public let backingScale: Double
    public init(request: RustViewportRequest, backingScale: Double) { self.request = request; self.backingScale = backingScale }
}
