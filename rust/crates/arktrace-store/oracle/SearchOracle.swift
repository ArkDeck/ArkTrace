import ArkTraceCore
import ArkTraceStore
import ArkTraceAnalysis
import Foundation

struct SearchCase: Codable, Sendable {
    let id: String
    let fixture: String
    let query: SearchInput
}
struct SearchInput: Codable, Sendable { let text: String; let limit: Int; let domains: Int }
struct Step: Codable, Sendable { let kind: String; let query: String; let result: String }
struct Source: Decodable { let sha256: String; let byteCount: Int64 }
struct Failure: Encodable { let code: ArkTraceError.Code; let stage: ArkTraceError.Stage; let details: [String: String] }
struct SearchRecord: Encodable {
    let id: String
    var results: TraceSearchResults? = nil
    var error: Failure? = nil
    var steps: [Step] = []
}
private func encoded<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}
struct ProcessInput: Encodable { let processKey: Int64?; let pid: Int64?; let name: String?; let nameMatch: TraceDirectoryNameMatch; let limit: Int }
struct ThreadInput: Encodable { let processKey: Int64?; let pid: Int64?; let threadKey: Int64?; let tid: Int64?; let name: String?; let nameMatch: TraceDirectoryNameMatch; let limit: Int }
struct SliceInput: Encodable { let range: TraceTimeRange; let eventKey: EventKey?; let processKey: Int64?; let pid: Int64?; let threadKey: Int64?; let tid: Int64?; let name: String?; let nameMatch: TraceDirectoryNameMatch; let minimumDurationNs: Int64?; let depth: Int64?; let includesArgumentSet: Bool; let limit: Int }
struct Items<T: Encodable>: Encodable { let items: [T]; let truncated: Bool; let capabilityAvailable: Bool? }

/// Records the actual typed reads issued by the existing search composition.
/// Delegation does not implement filtering, mapping or sorting in the harness.
actor RecordingRepository: TraceRepositoryProtocol {
    func cpuCatalog(_ query: TraceCPUCatalogQuery) async throws -> TraceCPUCatalog { try await base.cpuCatalog(query) }

    private let base: SQLiteTraceRepository
    private var steps: [Step] = []
    init(_ base: SQLiteTraceRepository) { self.base = base }
    func recorded() -> [Step] { steps }
    func metadata() async throws -> TraceMetadata {
        let result = try await base.metadata()
        steps.append(Step(kind: "metadata", query: "{}", result: "{\"durationNs\":\(result.durationNs)}"))
        return result
    }
    func processes(_ q: ProcessQuery) async throws -> BoundedPage<TraceProcess> {
        let result = try await base.processes(q)
        steps.append(Step(kind: "processes", query: try encoded(ProcessInput(processKey: q.processKey?.ipid, pid: q.pid, name: q.name, nameMatch: q.nameMatch, limit: q.limit)), result: try encoded(Items(items: result.items, truncated: result.truncated, capabilityAvailable: nil))))
        return result
    }
    func threads(_ q: ThreadQuery) async throws -> BoundedPage<TraceThread> {
        let result = try await base.threads(q)
        steps.append(Step(kind: "threads", query: try encoded(ThreadInput(processKey: q.processKey?.ipid, pid: q.pid, threadKey: q.threadKey?.itid, tid: q.tid, name: q.name, nameMatch: q.nameMatch, limit: q.limit)), result: try encoded(Items(items: result.items, truncated: result.truncated, capabilityAvailable: nil))))
        return result
    }
    func slices(_ q: TraceSliceQuery) async throws -> TraceEventPage<TraceSlice> {
        let (text, match): (String?, TraceDirectoryNameMatch)
        switch q.name { case .exact(let t): (text,match)=(t,.exact); case .prefix(let t): (text,match)=(t,.prefix); case .contains(let t): (text,match)=(t,.contains); case nil: (text,match)=(nil,.exact) }
        let result = try await base.slices(q)
        steps.append(Step(kind: "slices", query: try encoded(SliceInput(range: q.range, eventKey: q.eventKey, processKey: q.processKey?.ipid, pid: q.pid, threadKey: q.threadKey?.itid, tid: q.tid, name: text, nameMatch: match, minimumDurationNs: q.minimumDurationNs, depth: q.depth, includesArgumentSet: q.includesArgumentSet, limit: q.limit)), result: try encoded(Items(items: result.items, truncated: result.truncated, capabilityAvailable: result.capabilityAvailable))))
        return result
    }
    func summaryFacts(_ q: TraceSummaryQuery) async throws -> TraceSummaryFacts { try await base.summaryFacts(q) }
}

@main struct SearchOracle {
    static func main() async throws {
        let args = CommandLine.arguments
        let output = try await Task.detached {
            guard args.count == 5 else { throw CocoaError(.coderInvalidValue) }
            let decoder = JSONDecoder()
            let parser = try decoder.decode(TraceParserIdentity.self, from: Data(args[2].utf8))
            let source = try decoder.decode(Source.self, from: Data(args[3].utf8))
            let cases = try decoder.decode([SearchCase].self, from: Data(args[4].utf8))
            let repository = try SQLiteTraceRepository(databaseURL: URL(filePath: args[1]), parser: parser, source: TraceSourceDescriptor(traceSHA256: source.sha256, sourceByteCount: source.byteCount))
            var records: [SearchRecord] = []
            for value in cases {
                let recording = RecordingRepository(repository)
                var record = SearchRecord(id: value.id)
                do {
                    record.results = try await TraceViewerSearchEngine(repository: recording).search(TraceViewerSearchRequest(text: value.query.text, limit: value.query.limit, timeout: .seconds(30), domains: .init(rawValue: value.query.domains)))
                } catch let error as ArkTraceError {
                    record.error = Failure(code: error.code, stage: error.stage, details: error.details)
                }
                record.steps = await recording.recorded()
                records.append(record)
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(records)
        }.value
        try FileHandle.standardOutput.write(contentsOf: output)
        try FileHandle.standardOutput.write(contentsOf: Data([10]))
    }
}
