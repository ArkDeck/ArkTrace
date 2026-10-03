import ArkTraceCore
import Foundation

/// Wire DTO; native admission enforces the closed query bounds.
public struct RustProcessQuery: Codable, Sendable {
    public let processKey: Int64?
    public let pid: Int64?
    public let name: String?
    public let nameMatch: RustNameMatch
    public let limit: Int
    public init(processKey: Int64? = nil, pid: Int64? = nil, name: String? = nil, nameMatch: RustNameMatch = .exact, limit: Int = 10_000) {
        self.processKey = processKey
        self.pid = pid
        self.name = name
        self.nameMatch = nameMatch
        self.limit = limit
    }
}
