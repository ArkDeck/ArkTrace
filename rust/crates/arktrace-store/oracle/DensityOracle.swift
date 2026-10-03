import ArkTraceCore
@testable import ArkTraceStore
import Foundation

// Actual repository is the oracle; this adapter only builds typed requests
// and projects its closed, path-safe machine quality facts.
struct Case: Codable, Sendable { let id: String; let fixture: String; let query: Query }
struct Query: Codable, Sendable { let range: TraceTimeRange; let source: TraceDensitySource; let bucketCount: Int }
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
struct Result: Encodable {
    let buckets: [TraceDensityBucket]
    let capabilityAvailable: Bool
    let dataQuality: MachineQuality
    init(_ result: TraceDensityResult) throws {
        buckets = result.buckets; capabilityAvailable = result.capabilityAvailable
        dataQuality = try MachineQuality(result.dataQuality)
    }
}
struct Failure: Encodable { let code: ArkTraceError.Code; let stage: ArkTraceError.Stage; let details: [String: String] }
struct Record: Encodable { let id: String; let source: TraceDensitySource; var result: Result?; var error: Failure? }
@main struct DensityOracle {
    static func main() async throws {
        let args = CommandLine.arguments
        let output = try await Task.detached {
            guard args.count == 5 else { throw CocoaError(.coderInvalidValue) }
            let decoder = JSONDecoder()
            let parser = try decoder.decode(TraceParserIdentity.self, from: Data(args[2].utf8))
            let source = try decoder.decode(Source.self, from: Data(args[3].utf8))
            let cases = try decoder.decode([Case].self, from: Data(args[4].utf8))
            let repository = try SQLiteTraceRepository(databaseURL: URL(filePath: args[1]), parser: parser, source: TraceSourceDescriptor(traceSHA256: source.sha256, sourceByteCount: source.byteCount))
            var records: [Record] = []
            for value in cases {
                var record = Record(id: value.id, source: value.query.source)
                do {
                    let q = try TraceDensityQuery(range: value.query.range, source: value.query.source, bucketCount: value.query.bucketCount, deadline: .now.advanced(by: .seconds(30)))
                    record.result = try Result(await repository.density(q))
                } catch let error as ArkTraceError { record.error = Failure(code: error.code, stage: error.stage, details: error.details) }
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
