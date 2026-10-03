import ArkTraceCore
import Foundation

/// Wire DTO; native admission enforces the closed query bounds.
public struct RustAnalysisQuery: Codable, Sendable {
    public let request: RustAnalysisRequest
    public let scope: RustAnalysisScope
    public init(request: RustAnalysisRequest, scope: RustAnalysisScope = RustAnalysisScope()) {
        self.request = request
        self.scope = scope
    }
}
