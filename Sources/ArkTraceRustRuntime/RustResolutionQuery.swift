import ArkTraceCore
import Foundation

public struct RustResolutionQuery: Codable, Sendable {
    public let source: RustDensitySource
    public let bucket: TraceTimeRange
    public let timeNs: Int64
    public init(source: RustDensitySource, bucket: TraceTimeRange, timeNs: Int64) {
        self.source = source; self.bucket = bucket; self.timeNs = timeNs
    }
}
