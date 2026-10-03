import ArkTraceCore
import Foundation

public struct RustDensityQuery: Codable, Sendable {
    public let range: TraceTimeRange
    public let source: RustDensitySource
    public let bucketCount: Int
    public init(range: TraceTimeRange, source: RustDensitySource, bucketCount: Int) {
        self.range = range; self.source = source; self.bucketCount = bucketCount
    }
}
