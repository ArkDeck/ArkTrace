import ArkTraceCore
import Foundation

/// Wire DTO; native admission enforces the closed query bounds.
public struct RustThreadQuery: Codable, Sendable {
    public let processKey: Int64?
    public let pid: Int64?
    public let threadKey: Int64?
    public let tid: Int64?
    public let name: String?
    public let nameMatch: RustNameMatch
    public let limit: Int
    public init(processKey: Int64? = nil, pid: Int64? = nil, threadKey: Int64? = nil, tid: Int64? = nil, name: String? = nil, nameMatch: RustNameMatch = .exact, limit: Int = 10_000) {
        self.processKey = processKey
        self.pid = pid
        self.threadKey = threadKey
        self.tid = tid
        self.name = name
        self.nameMatch = nameMatch
        self.limit = limit
    }
}
