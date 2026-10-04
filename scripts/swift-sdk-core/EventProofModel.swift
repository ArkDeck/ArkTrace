import ArkTraceCore
import Foundation

// Acceptance-only request and output schema, shared with the independent
// original Swift repository harness. It is not a product request/wire API.
enum EventProofKind: String, Codable, Sendable, CaseIterable {
    case cpuSlices, threadStates, slices, frames, counterSeries, counters, arguments
}
struct EventProofRequest: Codable, Sendable {
    let id: String
    let kind: EventProofKind
    let range: TraceTimeRange
    let limit: Int
    var includesArgumentSet = false
    var argSetID: Int64? = nil
}
struct EventProofValue: Codable, Sendable {
    let id: String
    let bodyUTF8: String
    let argSetIDs: [Int64?]?
}
struct EventProofIssue: Encodable, Sendable {
    let category: TraceDataQualityIssue.Category
    let scope: String?
    let count: Int64?
    private enum CodingKeys: CodingKey { case category, scope, count, message }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(category, forKey: .category); try values.encode(scope, forKey: .scope)
        try values.encode(count, forKey: .count); try values.encodeNil(forKey: .message)
    }
}
private struct EventProofQuality: Encodable, Sendable {
    let status: TraceDataQuality.Status
    let warnings: [EventProofIssue]
}
private struct EventProofPage<T: Encodable & Sendable>: Encodable, Sendable {
    let items: [T]
    let truncated: Bool
    let capabilityAvailable: Bool
    let dataQuality: EventProofQuality
}
@concurrent func eventProofValue<T: Encodable & Sendable>(_ page: TraceEventPage<T>, id: String,
    handles: [Int64?]? = nil, sortMachineQuality: Bool = false) async throws -> EventProofValue {
    precondition(!Thread.isMainThread)
    var issues = page.dataQuality.issues.map { EventProofIssue(category: $0.category, scope: $0.scope, count: $0.count) }
    guard issues.count <= 4096, issues.allSatisfy({ $0.category != .unclassified && ($0.count == nil || $0.count! >= 0)
        && ($0.scope == nil || TraceDataQualityScope.machineAllowed.contains($0.scope!)) }) else { throw CocoaError(.coderInvalidValue) }
    if sortMachineQuality { issues.sort { ($0.category.rawValue, $0.scope ?? "", $0.count ?? .min) < ($1.category.rawValue, $1.scope ?? "", $1.count ?? .min) } }
    let value = EventProofPage(items: page.items, truncated: page.truncated, capabilityAvailable: page.capabilityAvailable,
        dataQuality: EventProofQuality(status: issues.isEmpty ? .ok : .warnings, warnings: issues))
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return EventProofValue(id: id, bodyUTF8: String(decoding: try encoder.encode(value), as: UTF8.self), argSetIDs: handles)
}
