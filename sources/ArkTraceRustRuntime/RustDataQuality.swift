import ArkTraceCore
import Foundation

public struct RustDataQuality: Codable, Sendable {
    public let status: TraceDataQuality.Status
    public let warnings: [TraceDataQualityIssue]
    private enum CodingKeys: String, CodingKey { case status, warnings }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(status, forKey: .status)
        var issues = values.nestedUnkeyedContainer(forKey: .warnings)
        for issue in warnings { try RustQualityEncoding(issue: issue).encode(to: issues.superEncoder()) }
    }
}
