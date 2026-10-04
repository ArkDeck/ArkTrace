import ArkTraceCore
import ArkTraceStore
import ArkTraceAnalysis
import Foundation
import Synchronization

private struct Source: Codable, Sendable { let sha256: String; let byteCount: Int64 }
private struct Fixture: Decodable, Sendable {
    let id: String; let database: String; let parserIdentity: TraceParserIdentity
    let source: Source; let preparation: TraceDatabasePreparationResult?; let constructionSQL: String?
}
private struct Request: Decodable, Sendable {
    let id: String; let fixture: String; let consumer: String
    let range: TraceTimeRange?; let maximumRowsPerSection: Int; let maximumEventsPerSection: Int
    let deadlineMilliseconds: Int; let preCancelled: Bool
}
private struct Input: Decodable, Sendable { let fixtures: [Fixture]; let requests: [Request] }
private struct Statement: Codable, Sendable { let sql: String; let bindingCount: Int }

private func outsideMainThread() -> Bool { !Thread.isMainThread }
private func object<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
}
// Encoding-only projection. All values and sequence order come from original models.
private func explicitIssueNulls(_ original: Any) -> Any {
    guard let issues = original as? [[String: Any]] else { return original }
    return issues.map { original in
        var item = original
        for key in ["scope", "count", "message"] where item[key] == nil { item[key] = NSNull() }
        return item
    }
}
private func factsWire(_ facts: TraceSummaryFacts) throws -> [String: Any] {
    var value = try object(facts) as! [String: Any]
    for key in ["cpuCount", "cpuSliceCount", "threadStateCount", "namedSliceCount", "counterSeriesCount", "eventCountBySource"] where value[key] == nil {
        value[key] = NSNull()
    }
    value["qualityIssues"] = explicitIssueNulls(value["qualityIssues"]!)
    return value
}
private func errorWire(_ error: any Error) -> [String: Any] {
    if let typed = error as? ArkTraceError {
        return ["kind": "ArkTraceError", "code": typed.code.rawValue, "stage": typed.stage.rawValue,
            "retryable": typed.retryable, "message": typed.message, "details": typed.details,
            "publicContractViolation": typed.publicContractViolation.map { $0.rawValue as Any } ?? NSNull()]
    }
    if error is CancellationError { return ["kind": "CancellationError", "typedPublicError": NSNull()] }
    return ["kind": String(reflecting: type(of: error)), "message": String(describing: error)]
}
@main private struct SummaryOracle {
    static func main() async throws {
        let args = CommandLine.arguments
        let output = try await Task.detached {
            precondition(outsideMainThread())
            let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(filePath: args[2])))
            if args[1] == "construct" {
                var created: [[String: Any]] = []
                for fixture in input.fixtures where fixture.constructionSQL != nil {
                    precondition(!FileManager.default.fileExists(atPath: fixture.database))
                    let prepared = try SQLiteTraceRepository.summaryCanonicalConstruct(
                        databaseURL: URL(filePath: fixture.database), sql: fixture.constructionSQL!)
                    created.append(["id": fixture.id, "preparation": try object(prepared), "outsideMainThread": outsideMainThread()])
                }
                return try JSONSerialization.data(withJSONObject: ["created": created], options: [.sortedKeys])
            }
            var records: [[String: Any]] = []
            var fixtureRecords: [[String: Any]] = []
            for fixture in input.fixtures {
                precondition(outsideMainThread())
                let statements = Mutex<[Statement]>([])
                let repository = try SQLiteTraceRepository.summaryCanonicalObserving(databaseURL: URL(filePath: fixture.database),
                    parser: fixture.parserIdentity, source: TraceSourceDescriptor(traceSHA256: fixture.source.sha256, sourceByteCount: fixture.source.byteCount,
                        sourceFormat: fixture.constructionSQL == nil ? "htrace" : "controlled-sqlite"), preparation: fixture.preparation!,
                    observer: { sql, count in statements.withLock { $0.append(Statement(sql: sql, bindingCount: count)) } })
                let metadata = try await repository.metadata()
                fixtureRecords.append(["id": fixture.id, "metadata": try object(metadata),
                    "databaseDevice": repository.databaseFileIdentity.device, "databaseInode": repository.databaseFileIdentity.inode,
                    "outsideMainThread": outsideMainThread(), "openStatements": try object(statements.withLock { $0 })])
                for request in input.requests where request.fixture == fixture.id {
                    statements.withLock { $0.removeAll(keepingCapacity: true) }
                    let bytes = try await Task.detached {
                        precondition(outsideMainThread())
                        var record: [String: Any] = ["id": request.id, "fixture": fixture.id, "consumer": request.consumer,
                            "preCancelled": request.preCancelled]
                        do {
                            if request.preCancelled {
                                unsafe withUnsafeCurrentTask { task in unsafe task?.cancel() }
                            }
                            if request.consumer == "analysis" {
                                let value = try await TraceSummaryEngine(repository: repository).summarize(
                                    try TraceSummaryRequest(range: request.range, maximumRowsPerSection: request.maximumRowsPerSection,
                                        maximumEventsPerSection: request.maximumEventsPerSection, timeout: .milliseconds(request.deadlineMilliseconds)))
                                record["summaryOriginalEncoder"] = try object(value)
                                record["status"] = "success"
                            } else {
                                let query = try TraceSummaryQuery(range: request.range, maximumRowsPerSection: request.maximumRowsPerSection,
                                    maximumEventsPerSection: request.maximumEventsPerSection,
                                    deadline: ContinuousClock.now.advanced(by: .milliseconds(request.deadlineMilliseconds)))
                                let value = try await repository.summaryFacts(query)
                                record["factsOriginalEncoder"] = try object(value)
                                record["facts"] = try factsWire(value)
                                record["status"] = "success"
                            }
                        } catch {
                            record["status"] = "error"; record["error"] = errorWire(error)
                        }
                        record["outsideMainThread"] = outsideMainThread()
                        record["observedStatements"] = try object(statements.withLock { $0 })
                        return try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                    }.value
                    records.append(try JSONSerialization.jsonObject(with: bytes) as! [String: Any])
                }
            }
            precondition(records.count == input.requests.count)
            return try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "fixtures": fixtureRecords, "records": records,
                "outsideMainThread": outsideMainThread(),
                "canonical": "original SQLiteTraceRepository.summaryFacts and original TraceSummaryEngine.summarize; no surrogate count or reduction"], options: [.sortedKeys])
        }.value
        try FileHandle.standardOutput.write(contentsOf: output + Data([10]))
    }
}
