import ArkTraceCore
import ArkTraceStore
import ArkTraceAnalysis
import Foundation

// Native acceptance harness only. Every row, directory and Agent result is
// produced by the unchanged production Swift repository/Agent engine.
struct Case: Codable, Sendable {
    let id: String
    let fixture: String
    let query: Query
}
struct Query: Codable, Sendable {
    let range: TraceTimeRange
    let filterID: Int64?
    let cpu: Int64?
    let processKey: Int64?
    let pid: Int64?
    let name: String?
    let nameMatch: TraceAgentTextMatch
    let limit: Int
}
struct MachineWarning: Encodable {
    let category: TraceDataQualityIssue.Category
    let scope: String?
    let count: Int64?
    let message: String? = nil
    enum CodingKeys: CodingKey { case category, scope, count, message }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(category, forKey: .category)
        try c.encode(scope, forKey: .scope)
        try c.encode(count, forKey: .count)
        try c.encode(message, forKey: .message)
    }
}
struct MachineQuality: Encodable {
    let status: TraceDataQuality.Status
    let warnings: [MachineWarning]
    init(_ quality: TraceDataQuality) throws {
        guard quality.issues.count <= 4096, quality.issues.allSatisfy({ $0.category != .unclassified && ($0.count == nil || $0.count! >= 0) && ($0.scope == nil || TraceDataQualityScope.machineAllowed.contains($0.scope!)) }) else { throw CocoaError(.coderInvalidValue) }
        warnings = quality.issues.map { MachineWarning(category: $0.category, scope: $0.scope, count: $0.count) }.sorted {
            ($0.category.rawValue, $0.scope ?? "", $0.count ?? .min) < ($1.category.rawValue, $1.scope ?? "", $1.count ?? .min)
        }
        status = warnings.isEmpty ? .ok : .warnings
    }
}
struct Page<T: Encodable>: Encodable {
    let items: [T]
    let truncated: Bool
    let capabilityAvailable: Bool
    let dataQuality: MachineQuality
    init(_ page: TraceEventPage<T>) throws where T: Sendable {
        items = page.items; truncated = page.truncated; capabilityAvailable = page.capabilityAvailable
        dataQuality = try MachineQuality(page.dataQuality)
    }
}
struct Record: Encodable {
    let id: String
    let repositoryPage: Page<CounterSeries>
    let page: Page<TraceAgentCounterEvent>
    let seriesPage: Page<CounterSeriesDescriptor>
}
@main struct CounterOracle {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let output = try await Task.detached {
            guard arguments.count == 5 else { throw CocoaError(.coderInvalidValue) }
            let decoder = JSONDecoder()
            let parser = try decoder.decode(TraceParserIdentity.self, from: Data(arguments[2].utf8))
            let source = try decoder.decode(Source.self, from: Data(arguments[3].utf8))
            let cases = try decoder.decode([Case].self, from: Data(arguments[4].utf8))
            let repository = try SQLiteTraceRepository(databaseURL: URL(filePath: arguments[1]), parser: parser, source: TraceSourceDescriptor(traceSHA256: source.sha256, sourceByteCount: source.byteCount))
            let engine = TraceAgentQueryEngine(repository: repository)
            var records: [Record] = []
            for value in cases {
                let q = value.query
                let name: CounterNameFilter? = q.name.map { switch q.nameMatch { case .exact: .exact($0); case .prefix: .prefix($0); case .contains: .contains($0) } }
                let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                let raw = try await repository.counters(CounterQuery(range: q.range, filterID: q.filterID, cpu: q.cpu, processKey: q.processKey.map(ProcessKey.init), pid: q.pid, name: name, limit: q.limit, deadline: deadline))
                let directory = try await repository.counterSeries(CounterSeriesQuery(range: q.range, limit: q.limit, deadline: deadline))
                let agent = try await engine.query(TraceAgentQueryRequest(view: .counters, range: q.range, filters: TraceAgentQueryFilters(cpu: q.cpu, processKey: q.processKey.map(ProcessKey.init), pid: q.pid, name: q.name, nameMatch: q.nameMatch, counterFilterID: q.filterID), limit: q.limit, timeout: .seconds(30)))
                let page = TraceEventPage(items: agent.counters, truncated: agent.truncated, capabilityAvailable: agent.capabilityAvailable, dataQuality: agent.dataQuality)
                records.append(Record(id: value.id, repositoryPage: try Page(raw), page: try Page(page), seriesPage: try Page(directory)))
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(records)
        }.value
        try FileHandle.standardOutput.write(contentsOf: output)
        try FileHandle.standardOutput.write(contentsOf: Data([10]))
    }
    struct Source: Decodable { let sha256: String; let byteCount: Int64 }
}
