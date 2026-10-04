import ArkTraceCore
import Foundation

// Acceptance-only plans shared with the independent Swift repository harness.
// They do not transport the Core deadline contract across the SDK boundary.
struct BatchProofSlice: Codable, Sendable { let limit: Int; let includesArgumentSet: Bool }
struct BatchProofThread: Codable, Sendable { let limit: Int; let threadKey: ThreadKey? }
struct BatchProofRequest: Codable, Sendable {
    let id: String
    let range: TraceTimeRange
    var cpuSlices: [Int] = []
    var threadStates: [Int] = []
    var slices: [BatchProofSlice] = []
    var counters: [Int] = []
    var counterSeries: [Int] = []
    var densities: [DensityProofRequest] = []
    var threads: [BatchProofThread] = []
    func coreQuery() throws -> TraceRepositoryEventBatch {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        return try TraceRepositoryEventBatch(
            cpuSlices: cpuSlices.map { try CpuSliceQuery(range: range, limit: $0, deadline: deadline) },
            threadStates: threadStates.map { try ThreadStateQuery(range: range, limit: $0, deadline: deadline) },
            slices: slices.map { try TraceSliceQuery(range: range, includesArgumentSet: $0.includesArgumentSet, limit: $0.limit, deadline: deadline) },
            counters: counters.map { try CounterQuery(range: range, limit: $0, deadline: deadline) },
            counterSeries: counterSeries.map { try CounterSeriesQuery(range: range, limit: $0, deadline: deadline) },
            densities: densities.map { try TraceDensityQuery(range: $0.range, source: $0.source, bucketCount: $0.bucketCount, deadline: deadline) },
            threads: threads.map { try ThreadQuery(threadKey: $0.threadKey, limit: $0.limit, deadline: nil) })
    }
}
struct BatchProofContext: Codable, Sendable {
    let metadata: TraceMetadata
    let preparation: TraceDatabasePreparationResult
}
struct BatchProofValue: Codable, Equatable, Sendable {
    let id: String
    let cpuSlices, threadStates, slices, counters, counterSeries, densities, threads: [String]
    let argSetIDs: [[Int64?]]
}
private struct BatchProofDirectory: Encodable, Sendable {
    let items: [TraceThread]
    let truncated: Bool
    let dataQualityIssues: [EventProofIssue]
}
@concurrent func batchProofValue(_ result: TraceRepositoryEventBatchResult, id: String,
    sortMachineQuality: Bool = false) async throws -> BatchProofValue {
    precondition(!Thread.isMainThread)
    func pages<T: Encodable & Sendable>(_ values: [TraceEventPage<T>]) async throws -> [String] {
        var output: [String] = []
        for page in values { output.append(try await eventProofValue(page, id: id, sortMachineQuality: sortMachineQuality).bodyUTF8) }
        return output
    }
    var densities: [String] = [], threads: [String] = []
    for result in result.densities { densities.append(try await densityProofValue(result, id: id, sortMachineQuality: sortMachineQuality).bodyUTF8) }
    for page in result.threads {
        var issues = page.dataQualityIssues.map { EventProofIssue(category: $0.category, scope: $0.scope, count: $0.count) }
        guard issues.count <= 4096, issues.allSatisfy({ $0.category != .unclassified && ($0.count == nil || $0.count! >= 0)
            && ($0.scope == nil || TraceDataQualityScope.machineAllowed.contains($0.scope!)) }) else { throw CocoaError(.coderInvalidValue) }
        if sortMachineQuality { issues.sort { ($0.category.rawValue, $0.scope ?? "", $0.count ?? .min) < ($1.category.rawValue, $1.scope ?? "", $1.count ?? .min) } }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        threads.append(String(decoding: try encoder.encode(BatchProofDirectory(items: page.items, truncated: page.truncated, dataQualityIssues: issues)), as: UTF8.self))
    }
    return try await BatchProofValue(id: id, cpuSlices: pages(result.cpuSlices), threadStates: pages(result.threadStates),
        slices: pages(result.slices), counters: pages(result.counters), counterSeries: pages(result.counterSeries), densities: densities,
        threads: threads, argSetIDs: result.slices.map { $0.items.map(\.argSetID) })
}
