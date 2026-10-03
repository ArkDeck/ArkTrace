import ArkTraceCore
import Foundation

/// Wire DTO; native admission enforces the closed query bounds.
public struct RustArgumentQuery: Codable, Sendable {
    public let argSetID: Int64
    public let limit: Int
    public init(argSetID: Int64, limit: Int = 64) {
        self.argSetID = argSetID
        self.limit = limit
    }
}
