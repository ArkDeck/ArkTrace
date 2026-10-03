import ArkTraceCore
import Foundation

/// Wire DTO; native admission enforces the closed query bounds.
public struct RustFrameQuery: Codable, Sendable {
    public let range: TraceTimeRange
    public let processKey: Int64?
    public let limit: Int
    public init(range: TraceTimeRange, processKey: Int64? = nil, limit: Int = 10_000) {
        self.range = range
        self.processKey = processKey
        self.limit = limit
    }
}
