import ArkTraceCore
import Foundation

/// Wire DTO; native admission enforces the closed query bounds.
public struct RustCounterSeriesQuery: Codable, Sendable {
    public let range: TraceTimeRange
    public let limit: Int
    public init(range: TraceTimeRange, limit: Int = 10_000) {
        self.range = range
        self.limit = limit
    }
}
