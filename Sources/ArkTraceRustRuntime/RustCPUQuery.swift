import ArkTraceCore
import Foundation

public struct RustCPUQuery: Codable, Sendable {
    public let range: TraceTimeRange
    public let cpu: Int64?
    public let processKey: Int64?
    public let pid: Int64?
    public let threadKey: Int64?
    public let tid: Int64?
    public let limit: Int
    public init(range: TraceTimeRange, cpu: Int64? = nil, processKey: Int64? = nil, pid: Int64? = nil, threadKey: Int64? = nil, tid: Int64? = nil, limit: Int = 10_000) {
        self.range = range; self.cpu = cpu; self.processKey = processKey; self.pid = pid
        self.threadKey = threadKey; self.tid = tid; self.limit = limit
    }
}
