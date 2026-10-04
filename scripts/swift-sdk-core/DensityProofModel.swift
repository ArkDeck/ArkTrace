import ArkTraceCore
import Foundation

// Acceptance-only schema, shared with the independent original repository.
struct DensityProofRequest: Codable, Sendable {
    let id: String
    let range: TraceTimeRange
    let source: TraceDensitySource
    let bucketCount: Int
}
struct DensityProofValue: Codable, Equatable, Sendable { let id, bodyUTF8: String }
private struct DensityProofQuality: Encodable, Sendable {
    let status: TraceDataQuality.Status
    let warnings: [EventProofIssue]
}
private struct DensityProofBody: Encodable, Sendable {
    let buckets: [TraceDensityBucket]
    let capabilityAvailable: Bool
    let dataQuality: DensityProofQuality
}
@concurrent func densityProofValue(_ result: TraceDensityResult, id: String,
    sortMachineQuality: Bool = false) async throws -> DensityProofValue {
    precondition(!Thread.isMainThread)
    var issues = result.dataQuality.issues.map { EventProofIssue(category: $0.category, scope: $0.scope, count: $0.count) }
    guard issues.count <= 4096, issues.allSatisfy({ $0.category != .unclassified && ($0.count == nil || $0.count! >= 0)
        && ($0.scope == nil || TraceDataQualityScope.machineAllowed.contains($0.scope!)) }) else { throw CocoaError(.coderInvalidValue) }
    if sortMachineQuality { issues.sort { ($0.category.rawValue, $0.scope ?? "", $0.count ?? .min) < ($1.category.rawValue, $1.scope ?? "", $1.count ?? .min) } }
    let value = DensityProofBody(buckets: result.buckets, capabilityAvailable: result.capabilityAvailable,
        dataQuality: DensityProofQuality(status: issues.isEmpty ? .ok : .warnings, warnings: issues))
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return DensityProofValue(id: id, bodyUTF8: String(decoding: try encoder.encode(value), as: UTF8.self))
}
