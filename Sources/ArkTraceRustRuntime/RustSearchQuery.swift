import ArkTraceCore
import Foundation

/// Wire DTO; native admission enforces the closed query bounds.
public struct RustSearchQuery: Codable, Sendable {
    public let text: String
    public let limit: Int
    public let domains: Int64
    public init(text: String, limit: Int = 100, domains: Int64 = 7) {
        self.text = text
        self.limit = limit
        self.domains = domains
    }
}
