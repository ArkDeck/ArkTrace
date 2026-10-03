import ArkTraceCore
@testable import ArkTraceStore
import Foundation

// Acceptance adapter only. Production repository performs all interpretation.
struct Case: Codable, Sendable {
    let id: String
    let fixture: String
    let query: Query
    let lookup: Lookup?
}
struct Query: Codable, Sendable { let argSetID: Int64; let limit: Int }
struct Lookup: Codable, Sendable { let range: TraceTimeRange; let eventKey: EventKey }
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


struct Failure: Encodable { let code: ArkTraceError.Code; let stage: ArkTraceError.Stage; let details: [String: String] }
struct Record: Encodable {
    let id: String
    var page: Page<TraceEventArgument>? = nil
    var requestedHandles: [Int64?]? = nil
    var unrequestedHandles: [Int64?]? = nil
    var error: Failure? = nil
}
struct SampleSets: Encodable {
    let sampledRows: Int
    let prefixTruncated: Bool
    let sets: [Int64]
}
@main struct ArgumentOracle {
    static func main() async throws {
        let args = CommandLine.arguments
        let output = try await Task.detached {
            guard args.count == 5 else { throw CocoaError(.coderInvalidValue) }
            let decoder = JSONDecoder()
            let parser = try decoder.decode(TraceParserIdentity.self, from: Data(args[2].utf8))
            let source = try decoder.decode(Source.self, from: Data(args[3].utf8))
            if args[4] == "--sample-sets" {
                // Harness-only discovery of up to three actual argument sets.
                // Bound the physical prefix before filtering; do not claim
                // all sets were examined and do not add SQL to product APIs.
                let db = try TraceDatabase(url: URL(filePath: args[1]), readOnly: true)
                let rows = try db.query("SELECT argset FROM args LIMIT 129", vmStepBudget: 100_000, stage: .querying,
                    observesTaskCancellation: true, deadline: .now.advanced(by: .seconds(30))) {
                    $0.int64(0)
                }
                let sets = Array(Set(rows.prefix(128).compactMap { $0 }).sorted().prefix(3))
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                return try encoder.encode(SampleSets(sampledRows: min(128, rows.count), prefixTruncated: rows.count > 128, sets: sets))
            }
            let cases = try decoder.decode([Case].self, from: Data(args[4].utf8))
            let repository = try SQLiteTraceRepository(databaseURL: URL(filePath: args[1]), parser: parser, source: TraceSourceDescriptor(traceSHA256: source.sha256, sourceByteCount: source.byteCount))
            var records: [Record] = []
            for value in cases {
                var record = Record(id: value.id)
                let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                do {
                    if let lookup = value.lookup {
                        let plain = try await repository.slices(TraceSliceQuery(range: lookup.range, eventKey: lookup.eventKey, limit: 1, deadline: deadline))
                        let selected = try await repository.slices(TraceSliceQuery(range: lookup.range, eventKey: lookup.eventKey, includesArgumentSet: true, limit: 1, deadline: deadline))
                        record.unrequestedHandles = plain.items.map(\.argSetID)
                        record.requestedHandles = selected.items.map(\.argSetID)
                    }
                    record.page = try Page(await repository.arguments(TraceArgumentQuery(argSetID: value.query.argSetID, limit: value.query.limit, deadline: deadline)))
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
