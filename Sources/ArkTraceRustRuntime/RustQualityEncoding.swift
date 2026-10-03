import ArkTraceCore
import Foundation

/// Keep the native cold result's explicit nulls while reusing Core's issue type.
struct RustQualityEncoding: Encodable {
    let issue: TraceDataQualityIssue
    private enum CodingKeys: String, CodingKey { case category, scope, count, message }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(issue.category, forKey: .category)
        try values.encode(issue.scope, forKey: .scope)
        try values.encode(issue.count, forKey: .count)
        try values.encode(issue.message, forKey: .message)
    }
}
