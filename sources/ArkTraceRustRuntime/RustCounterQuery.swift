import ArkTraceCore
import Foundation

/// Wire DTO; native admission enforces the closed query bounds.
public struct RustCounterQuery: Codable, Sendable {
    public let range: TraceTimeRange
    public let scope: RustCounterScope?
    public let filterID: Int64?
    public let cpu: Int64?
    public let processKey: Int64?
    public let pid: Int64?
    public let name: String?
    public let nameMatch: RustNameMatch
    public let limit: Int
    public init(range: TraceTimeRange, scope: RustCounterScope? = nil, filterID: Int64? = nil, cpu: Int64? = nil, processKey: Int64? = nil, pid: Int64? = nil, name: String? = nil, nameMatch: RustNameMatch = .exact, limit: Int = 10_000) {
        self.range = range
        self.scope = scope
        self.filterID = filterID
        self.cpu = cpu
        self.processKey = processKey
        self.pid = pid
        self.name = name
        self.nameMatch = nameMatch
        self.limit = limit
    }
}
