import ArkTraceCore
import Foundation

// Acceptance schema, shared by independent original Core/Store and actual
// Core protocol consumers. It preserves query record order and nil. Opening
// and event quality follow existing native canonical machine ordering; summary
// quality retains original source order. Human diagnostic prose is omitted.
enum RepositoryProofKind: String, Codable, Sendable, CaseIterable {
    case metadata, processes, threads, summaryFacts, cpuSlices, threadStates, slices, arguments, frames, counters, counterSeries, density, eventBatch
}
struct RepositoryProofRequest: Codable, Sendable {
    let id: String
    let kind: RepositoryProofKind
    let range: TraceTimeRange
    let limit: Int
    var deadline: DeadlineProofEpoch?
    var processKey: ProcessKey?
    var threadKey: ThreadKey?
    var name: String?
    var nameMatch: String = "exact"
    var argSetID: Int64 = 7
    var includesArgumentSet = true
    var maximumEvents: Int = 7
    var densitySource: TraceDensitySource = .cpu(0)
    var batch: DeadlineProofRequest?
}
struct RepositoryProofValue: Codable, Equatable, Sendable {
    let id: String
    let bodyUTF8: String?
    let argSetIDs: [Int64?]?
    let code, stage: String?
    let retryable: Bool?
    init(id: String, body: String, handles: [Int64?]? = nil) {
        self.id = id; bodyUTF8 = body; argSetIDs = handles; code = nil; stage = nil; retryable = nil
    }
    init(id: String, error: ArkTraceError) {
        self.id = id; bodyUTF8 = nil; argSetIDs = nil; code = error.code.rawValue; stage = error.stage.rawValue; retryable = error.retryable
        precondition(error.publicContractViolation == nil)
    }
}
private struct RepositoryProofQuality: Encodable, Sendable { let status: TraceDataQuality.Status; let warnings: [EventProofIssue] }
private struct RepositoryProofDirectory<T: Encodable & Sendable>: Encodable, Sendable {
    let items: [T]; let truncated: Bool; let dataQualityIssues: [EventProofIssue]
}
private struct RepositoryProofMetadata: Encodable, Sendable {
    let traceSHA256: String; let sourceByteCount, durationNs: Int64; let sourceFormat: String?
    let parser: TraceParserIdentity; let schemaFingerprint: String; let capabilities: TraceCapabilities
    let dataQuality: RepositoryProofQuality
}
private struct RepositoryProofSummary: Encodable, Sendable {
    let cpuCount: TraceBoundedCount?; let processCount, threadCount: TraceBoundedCount
    let cpuSliceCount, threadStateCount, namedSliceCount, counterSeriesCount: TraceBoundedCount?
    let eventCountBySource: TraceEventSourceCounts?; let dataQuality: RepositoryProofQuality
}
@concurrent private func repositoryProofEncode<T: Encodable & Sendable>(_ value: T) async throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}
private func repositoryProofIssues(_ values: [TraceDataQualityIssue], sorted: Bool) throws -> [EventProofIssue] {
    var result = values.map { EventProofIssue(category: $0.category, scope: $0.scope, count: $0.count) }
    guard result.count <= 4096 && result.allSatisfy({ $0.category != .unclassified && ($0.count == nil || $0.count! >= 0)
        && ($0.scope == nil || TraceDataQualityScope.machineAllowed.contains($0.scope!)) }) else { throw CocoaError(.coderInvalidValue) }
    if sorted { result.sort { ($0.category.rawValue, $0.scope ?? "", $0.count ?? .min) < ($1.category.rawValue, $1.scope ?? "", $1.count ?? .min) } }
    return result
}
enum RepositoryProofHeld: Sendable {
    case metadata(TraceMetadata), processes(BoundedPage<TraceProcess>), threads(BoundedPage<TraceThread>), summaryFacts(TraceSummaryFacts)
    case cpuSlices(TraceEventPage<CpuSlice>), threadStates(TraceEventPage<ThreadStateInterval>), slices(TraceEventPage<TraceSlice>)
    case arguments(TraceEventPage<TraceEventArgument>), frames(TraceEventPage<TraceFrame>), counters(TraceEventPage<CounterSeries>)
    case counterSeries(TraceEventPage<CounterSeriesDescriptor>), density(TraceDensityResult), eventBatch(TraceRepositoryEventBatchResult)
    @concurrent func proofValue(id: String, sortMachineQuality: Bool = false) async throws -> RepositoryProofValue {
        func quality(_ issues: [TraceDataQualityIssue], sorted: Bool? = nil) throws -> RepositoryProofQuality {
            RepositoryProofQuality(status: issues.isEmpty ? .ok : .warnings, warnings: try repositoryProofIssues(issues, sorted: sorted ?? sortMachineQuality))
        }
        func directory<T: Encodable & Sendable>(_ page: BoundedPage<T>) async throws -> String {
            try await repositoryProofEncode(RepositoryProofDirectory(items: page.items, truncated: page.truncated,
                dataQualityIssues: repositoryProofIssues(page.dataQualityIssues, sorted: sortMachineQuality)))
        }
        let body: String
        var handles: [Int64?]?
        switch self {
        case .metadata(let value):
            body = try await repositoryProofEncode(RepositoryProofMetadata(traceSHA256: value.traceSHA256, sourceByteCount: value.sourceByteCount,
                durationNs: value.durationNs, sourceFormat: value.sourceFormat, parser: value.parser, schemaFingerprint: value.schemaFingerprint,
                capabilities: value.capabilities, dataQuality: quality(value.dataQuality.issues)))
        case .processes(let value): body = try await directory(value)
        case .threads(let value): body = try await directory(value)
        case .summaryFacts(let value):
            body = try await repositoryProofEncode(RepositoryProofSummary(cpuCount: value.cpuCount, processCount: value.processCount, threadCount: value.threadCount,
                cpuSliceCount: value.cpuSliceCount, threadStateCount: value.threadStateCount, namedSliceCount: value.namedSliceCount,
                counterSeriesCount: value.counterSeriesCount, eventCountBySource: value.eventCountBySource, dataQuality: quality(value.qualityIssues, sorted: false)))
        case .cpuSlices(let value): body = try await eventProofValue(value, id: id, sortMachineQuality: sortMachineQuality).bodyUTF8
        case .threadStates(let value): body = try await eventProofValue(value, id: id, sortMachineQuality: sortMachineQuality).bodyUTF8
        case .slices(let value):
            handles = value.items.map(\.argSetID)
            body = try await eventProofValue(value, id: id, sortMachineQuality: sortMachineQuality).bodyUTF8
        case .arguments(let value): body = try await eventProofValue(value, id: id, sortMachineQuality: sortMachineQuality).bodyUTF8
        case .frames(let value): body = try await eventProofValue(value, id: id, sortMachineQuality: sortMachineQuality).bodyUTF8
        case .counters(let value): body = try await eventProofValue(value, id: id, sortMachineQuality: sortMachineQuality).bodyUTF8
        case .counterSeries(let value): body = try await eventProofValue(value, id: id, sortMachineQuality: sortMachineQuality).bodyUTF8
        case .density(let value): body = try await densityProofValue(value, id: id, sortMachineQuality: sortMachineQuality).bodyUTF8
        case .eventBatch(let value): body = try await repositoryProofEncode(batchProofValue(value, id: id, sortMachineQuality: sortMachineQuality))
        }
        return RepositoryProofValue(id: id, body: body, handles: handles)
    }
}
@concurrent func repositoryProofFetch(_ repository: any TraceRepositoryProtocol, request: RepositoryProofRequest) async throws -> RepositoryProofHeld {
    precondition(!Thread.isMainThread)
    let deadline = request.deadline?.instant
    let match: TraceDirectoryNameMatch = switch request.nameMatch { case "prefix": .prefix; case "contains": .contains; default: .exact }
    let sliceName: TraceSliceNameFilter? = request.name.map { name in
        switch request.nameMatch { case "prefix": .prefix(name); case "contains": .contains(name); default: .exact(name) }
    }
    switch request.kind {
    case .metadata: return try await .metadata(repository.metadata())
    case .processes: return try await .processes(repository.processes(ProcessQuery(processKey: request.processKey, name: request.name, nameMatch: match, limit: request.limit, deadline: deadline)))
    case .threads: return try await .threads(repository.threads(ThreadQuery(processKey: request.processKey, threadKey: request.threadKey, name: request.name, nameMatch: match, limit: request.limit, deadline: deadline)))
    case .summaryFacts: return try await .summaryFacts(repository.summaryFacts(TraceSummaryQuery(range: request.range, maximumRowsPerSection: request.limit, maximumEventsPerSection: request.maximumEvents, deadline: deadline!)))
    case .cpuSlices: return try await .cpuSlices(repository.cpuSlices(CpuSliceQuery(range: request.range, processKey: request.processKey, threadKey: request.threadKey, limit: request.limit, deadline: deadline!)))
    case .threadStates: return try await .threadStates(repository.threadStates(ThreadStateQuery(range: request.range, processKey: request.processKey, threadKey: request.threadKey, limit: request.limit, deadline: deadline!)))
    case .slices: return try await .slices(repository.slices(TraceSliceQuery(range: request.range, processKey: request.processKey, threadKey: request.threadKey, name: sliceName, includesArgumentSet: request.includesArgumentSet, limit: request.limit, deadline: deadline!)))
    case .arguments: return try await .arguments(repository.arguments(TraceArgumentQuery(argSetID: request.argSetID, limit: request.limit, deadline: deadline!)))
    case .frames: return try await .frames(repository.frames(TraceFrameQuery(range: request.range, processKey: request.processKey, limit: request.limit, deadline: deadline!)))
    case .counters: return try await .counters(repository.counters(CounterQuery(range: request.range, limit: request.limit, deadline: deadline!)))
    case .counterSeries: return try await .counterSeries(repository.counterSeries(CounterSeriesQuery(range: request.range, limit: request.limit, deadline: deadline!)))
    case .density: return try await .density(repository.density(TraceDensityQuery(range: request.range, source: request.densitySource, bucketCount: request.limit, deadline: deadline!)))
    case .eventBatch: return try await .eventBatch(repository.eventBatch(request.batch!.coreQuery()))
    }
}
@concurrent func repositoryProofValue(_ repository: any TraceRepositoryProtocol, request: RepositoryProofRequest,
                                      sortMachineQuality: Bool = false) async throws -> RepositoryProofValue {
    do {
        return try await repositoryProofFetch(repository, request: request).proofValue(id: request.id, sortMachineQuality: sortMachineQuality)
    } catch let error as ArkTraceError { return RepositoryProofValue(id: request.id, error: error) }
}
