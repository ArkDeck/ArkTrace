import ArkTraceCore
import ArkTraceStore
import ArkTraceAnalysis
import Foundation

// Acceptance adapter only: no SQL or production row mapping is reimplemented.
struct Case: Codable, Sendable {
    let id: String
    let fixture: String
    let view: String
    let query: Query
}
struct Query: Codable, Sendable {
    let range: TraceTimeRange
    let processKey: Int64?
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

enum AnyPage: Encodable {
    case cpu(Page<CpuSlice>)
    case state(Page<ThreadStateInterval>)
    case slices(Page<TraceSlice>)
    case frames(Page<TraceFrame>)
    func encode(to encoder: Encoder) throws {
        switch self {
        case .cpu(let p): try p.encode(to: encoder)
        case .state(let p): try p.encode(to: encoder)
        case .slices(let p): try p.encode(to: encoder)
        case .frames(let p): try p.encode(to: encoder)
        }
    }
}
struct Jank: Encodable { let isJank: Bool; let jankTag: Int64 }
struct Failure: Encodable { let code: ArkTraceError.Code; let stage: ArkTraceError.Stage; let details: [String: String] }
struct Record: Encodable {
    let id: String
    var page: AnyPage? = nil
    var agentPage: AnyPage? = nil
    var jank: [Jank]? = nil
    var error: Failure? = nil
}
@main struct EventOracle {
    static func main() async throws {
        let args = CommandLine.arguments
        let output = try await Task.detached {
            guard args.count == 5 else { throw CocoaError(.coderInvalidValue) }
            let decoder = JSONDecoder()
            let parser = try decoder.decode(TraceParserIdentity.self, from: Data(args[2].utf8))
            let source = try decoder.decode(Source.self, from: Data(args[3].utf8))
            let cases = try decoder.decode([Case].self, from: Data(args[4].utf8))
            let repository = try SQLiteTraceRepository(databaseURL: URL(filePath: args[1]), parser: parser, source: TraceSourceDescriptor(traceSHA256: source.sha256, sourceByteCount: source.byteCount))
            let engine = TraceAgentQueryEngine(repository: repository)
            var records: [Record] = []
            for value in cases {
                var record = Record(id: value.id)
                let q = value.query
                let key = q.processKey.map(ProcessKey.init)
                let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                do {
                    switch value.view {
                    case "frames":
                        let p = try await repository.frames(TraceFrameQuery(range: q.range, processKey: key, limit: q.limit, deadline: deadline))
                        record.page = .frames(try Page(p))
                        record.jank = p.items.map { Jank(isJank: $0.isJank, jankTag: TraceFrame.jankTag($0.flag)) }
                    case "cpuSlices":
                        record.page = .cpu(try Page(await repository.cpuSlices(CpuSliceQuery(range: q.range, processKey: key, limit: q.limit, deadline: deadline))))
                        let a = try await engine.query(TraceAgentQueryRequest(view: .cpuSlices, range: q.range, filters: TraceAgentQueryFilters(processKey: key), limit: q.limit, timeout: .seconds(30)))
                        record.agentPage = .cpu(try Page(TraceEventPage(items: a.cpuSlices, truncated: a.truncated, capabilityAvailable: a.capabilityAvailable, dataQuality: a.dataQuality)))
                    case "threadStates":
                        record.page = .state(try Page(await repository.threadStates(ThreadStateQuery(range: q.range, processKey: key, limit: q.limit, deadline: deadline))))
                        let a = try await engine.query(TraceAgentQueryRequest(view: .threadStates, range: q.range, filters: TraceAgentQueryFilters(processKey: key), limit: q.limit, timeout: .seconds(30)))
                        record.agentPage = .state(try Page(TraceEventPage(items: a.threadStates, truncated: a.truncated, capabilityAvailable: a.capabilityAvailable, dataQuality: a.dataQuality)))
                    case "slices":
                        record.page = .slices(try Page(await repository.slices(TraceSliceQuery(range: q.range, processKey: key, limit: q.limit, deadline: deadline))))
                        let a = try await engine.query(TraceAgentQueryRequest(view: .slices, range: q.range, filters: TraceAgentQueryFilters(processKey: key), limit: q.limit, timeout: .seconds(30)))
                        record.agentPage = .slices(try Page(TraceEventPage(items: a.slices, truncated: a.truncated, capabilityAvailable: a.capabilityAvailable, dataQuality: a.dataQuality)))
                    default: throw CocoaError(.coderInvalidValue)
                    }
                } catch let error as ArkTraceError {
                    record.error = Failure(code: error.code, stage: error.stage, details: error.details)
                }
                records.append(record)
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(records)
        }.value
        try FileHandle.standardOutput.write(contentsOf: output)
        try FileHandle.standardOutput.write(contentsOf: Data([10]))
    }
    struct Source: Decodable { let sha256: String; let byteCount: Int64 }
}
