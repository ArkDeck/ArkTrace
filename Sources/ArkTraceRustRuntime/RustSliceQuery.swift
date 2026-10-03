import ArkTraceCore
import Foundation

/// Wire DTO; native admission enforces the closed query bounds.
public struct RustSliceQuery: Codable, Sendable {
    public let range: TraceTimeRange
    public let eventKey: EventKey?
    public let processKey: Int64?
    public let pid: Int64?
    public let threadKey: Int64?
    public let tid: Int64?
    public let unattributedOnly: Bool
    public let name: String?
    public let nameMatch: RustNameMatch
    public let minimumDurationNs: Int64?
    public let depth: Int64?
    public let includesArgumentSet: Bool
    public let limit: Int
    public init(range: TraceTimeRange, eventKey: EventKey? = nil, processKey: Int64? = nil, pid: Int64? = nil, threadKey: Int64? = nil, tid: Int64? = nil, unattributedOnly: Bool = false, name: String? = nil, nameMatch: RustNameMatch = .exact, minimumDurationNs: Int64? = nil, depth: Int64? = nil, includesArgumentSet: Bool = false, limit: Int = 10_000) {
        self.range = range
        self.eventKey = eventKey
        self.processKey = processKey
        self.pid = pid
        self.threadKey = threadKey
        self.tid = tid
        self.unattributedOnly = unattributedOnly
        self.name = name
        self.nameMatch = nameMatch
        self.minimumDurationNs = minimumDurationNs
        self.depth = depth
        self.includesArgumentSet = includesArgumentSet
        self.limit = limit
    }
}
