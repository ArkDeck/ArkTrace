import ArkTraceCore
import Foundation

public struct RustDetailQuery: Codable, Sendable {
    public let range: TraceTimeRange
    public let source: RustDensitySource
    public let limit: Int
    public init(range: TraceTimeRange, source: RustDensitySource, limit: Int) {
        self.range = range; self.source = source; self.limit = limit
    }
}
