import ArkTraceCore
import ArkTraceRustRuntime
import Foundation

private struct Vector: Decodable, Sendable { let id: String; let query: RustSummaryQuery }
private struct Input: Decodable, Sendable {
    let source, namespace, helper, parser, helperSHA256: String
    let format: UInt32
    let parserIdentity: TraceParserIdentity
    let vectors: [Vector]
    let eventOracle: String?
    let densityOracle: String?
    let densityReadyCopy: String?
    let batchOracle: String?
    let deadlineOracle: String?
}
private struct Response: Codable, Sendable { let id, nativeBodyUTF8, coreBodyUTF8, afterShutdownCoreBodyUTF8: String }
private struct UnsortedOrderProbe: Codable, Sendable { let beforeUTF8, afterUTF8: String; let sameJSONValue: Bool }
private struct Report: Codable, Sendable {
    let eventProof: EventProofReport?
    let densityProof: DensityProofReport?
    let batchProof: BatchProofReport?
    let deadlineProof: DeadlineProofReport?
    let unsortedOrderProbes: [UnsortedOrderProbe]
    let metadata: TraceMetadata
    let afterShutdownMetadata: TraceMetadata
    let responses: [Response]
    let processPages: Int
    let threadPages: Int
    let directoryRecordsCompared: Int
    let copiedCallerDTOsSurviveShutdown: Bool
    let storageBytesAfterCopies: Int
    let storageOwnersAfterCopies: Int
    let stagingBytesAfterCopies: Int
    let stagingOwnersAfterCopies: Int
    let nativeBytesBeforeShutdown: UInt64
}
@concurrent private func load(_ path: String) async throws -> Input {
    try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(filePath: path)))
}
@concurrent private func encode<T: Encodable & Sendable>(_ value: T) async throws -> String {
    precondition(!Thread.isMainThread)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}
@concurrent private func unsorted<T: Encodable & Sendable>(_ value: T) async throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}
@concurrent private func sameJSON(_ lhs: String, _ rhs: String) async throws -> Bool {
    let a = try JSONSerialization.jsonObject(with: Data(lhs.utf8)) as! NSDictionary
    let b = try JSONSerialization.jsonObject(with: Data(rhs.utf8)) as! NSDictionary
    return a == b
}
@concurrent private func opening(_ value: RustSession, format: RustSourceFormat) async throws -> TraceMetadata {
    let view = try await value.openingView()
    let copied = try await view.copyTraceMetadata(sourceFormat: format)
    let old = try await value.opening.decode(RustOpenResult.self).traceMetadata(sourceFormat: format)
    let lhs = try await encode(copied), rhs = try await encode(old)
    let left = try JSONSerialization.jsonObject(with: Data(lhs.utf8)) as! NSDictionary
    let right = try JSONSerialization.jsonObject(with: Data(rhs.utf8)) as! NSDictionary
    precondition(left == right)
    return copied
}
@concurrent private func processes(_ session: RustSession, limit: Int) async throws -> Int {
    let view = try await session.processes(RustProcessQuery(limit: limit))
    let copied = try await view.copyCorePage()
    precondition(copied.items.count == view.count && copied.truncated == view.truncated && copied.dataQualityIssues.count == view.qualityIssueCount)
    for index in 0..<view.count {
        let record = view[index], copy = copied.items[index]
        let name = if let name = record.name { await name.copyString() } else { nil as String? }
        precondition(copy.key == record.key && copy.pid == record.pid && copy.name == name && copy.startNs == record.startNs
            && copy.endNs == record.endNs && copy.threadCount.map(Int64.init) == record.threadCount)
    }
    for index in 0..<view.qualityIssueCount { let issue = try await view.qualityIssue(at: index).copyCoreIssue(); precondition(copied.dataQualityIssues[index] == issue) }
    return copied.items.count
}
@concurrent private func threads(_ session: RustSession, limit: Int) async throws -> Int {
    let view = try await session.threads(RustThreadQuery(limit: limit))
    let copied = try await view.copyCorePage()
    precondition(copied.items.count == view.count && copied.truncated == view.truncated && copied.dataQualityIssues.count == view.qualityIssueCount)
    for index in 0..<view.count {
        let record = view[index], copy = copied.items[index]
        let name = if let name = record.name { await name.copyString() } else { nil as String? }
        let processName = if let name = record.processName { await name.copyString() } else { nil as String? }
        precondition(copy.key == record.key && copy.processKey == record.processKey && copy.tid == record.tid && copy.pid == record.pid
            && copy.name == name && copy.processName == processName && copy.startNs == record.startNs && copy.endNs == record.endNs && copy.isMainThread == record.isMainThread)
    }
    for index in 0..<view.qualityIssueCount { let issue = try await view.qualityIssue(at: index).copyCoreIssue(); precondition(copied.dataQualityIssues[index] == issue) }
    return copied.items.count
}
@concurrent private func facts(_ session: RustSession, query: RustSummaryQuery) async throws -> (TraceSummaryFacts, String) {
    let view = try await session.summaryFacts(query)
    let copied = try await view.copyCoreFacts()
    let native = try await session.query(.summaryFacts(query))
    let body = try native.withBytes { span in
        let bytes = (0..<span.count).map { span[$0] }
        return try JSONSerialization.jsonObject(with: Data(bytes)) as! [String: Any]
    }
    let encoded = try JSONSerialization.data(withJSONObject: body["body"]!)
    return (copied, String(decoding: encoded, as: UTF8.self))
}
@concurrent private func roundTrip(_ value: TraceMetadata) async throws -> TraceMetadata {
    try JSONDecoder().decode(TraceMetadata.self, from: JSONEncoder().encode(value))
}
@concurrent private func emit(_ report: Report) async throws {
    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(report) + Data([10]))
}
@MainActor @main private struct CoreOwnership {
    static func main() async throws {
        let input = try await load(CommandLine.arguments[1])
        let configuration = RustConfiguration.developmentFixture(namespace: URL(filePath: input.namespace), helper: URL(filePath: input.helper),
            parser: URL(filePath: input.parser), helperSHA256: input.helperSHA256, parserIdentity: input.parserIdentity)
        let engine = try await RustEngine.createDevelopmentFixture(configuration)
        var session: RustSession? = try await engine.open(URL(filePath: input.source), format: RustSourceFormat(rawValue: input.format)!)
        let metadata = try await opening(session!, format: RustSourceFormat(rawValue: input.format)!)
        var count = 0
        for limit in [1, 100_000] { count += try await processes(session!, limit: limit); count += try await threads(session!, limit: limit) }
        var held: [TraceSummaryFacts] = [], native: [String] = [], initial: [String] = [], unordered: [String] = []
        for vector in input.vectors {
            let pair = try await facts(session!, query: vector.query)
            held.append(pair.0); native.append(pair.1); initial.append(try await encode(pair.0)); unordered.append(try await unsorted(pair.0))
        }
        var eventProof: EventHeldProof? = if let oracle = input.eventOracle {
            try await EventHeldProof.prepare(session: session!, namespace: input.namespace, oracle: oracle, metadata: metadata)
        } else { nil }
        var densityProof: DensityHeldProof? = if let oracle = input.densityOracle {
            try await DensityHeldProof.prepare(session: session!, namespace: input.namespace, oracle: oracle,
                metadata: metadata, readyCopy: input.densityReadyCopy)
        } else { nil }
        var batchProof: BatchHeldProof? = if let oracle = input.batchOracle {
            try await BatchHeldProof.prepare(session: session!, namespace: input.namespace, oracle: oracle, metadata: metadata)
        } else { nil }
        var deadlineProof: DeadlineHeldProof? = if let oracle = input.deadlineOracle {
            try await DeadlineHeldProof.prepare(session: session!, namespace: input.namespace, oracle: oracle, metadata: metadata)
        } else { nil }
        let countsBeforeShutdown = RustEngine.developmentColdStorageCounts()
        precondition(countsBeforeShutdown.stagingBytes == 0 && countsBeforeShutdown.stagingOwners == 0)
        try await session!.close(); session = nil; try await RustCleanup.flush()
        let nativeBytes = try await engine.retainedResultBytes(); precondition(nativeBytes == 0)
        try await engine.shutdown()
        let eventReport = try await eventProof?.finish()
        eventProof = nil
        let densityReport = try await densityProof?.finish()
        densityProof = nil
        let batchReport = try await batchProof?.finish()
        batchProof = nil
        let deadlineReport = try await deadlineProof?.finish()
        deadlineProof = nil
        let counters = RustEngine.developmentColdStorageCounts()
        precondition(counters.bytes == 0 && counters.owners == 0 && counters.stagingBytes == 0 && counters.stagingOwners == 0)
        var responses: [Response] = [], probes: [UnsortedOrderProbe] = []
        for index in held.indices {
            let after = try await encode(held[index]); precondition(after == initial[index])
            let afterUnsorted = try await unsorted(held[index])
            let equal = try await sameJSON(unordered[index], afterUnsorted); precondition(equal)
            probes.append(UnsortedOrderProbe(beforeUTF8: unordered[index], afterUTF8: afterUnsorted, sameJSONValue: equal))
            responses.append(Response(id: input.vectors[index].id, nativeBodyUTF8: native[index], coreBodyUTF8: initial[index], afterShutdownCoreBodyUTF8: after))
        }
        let after = try await roundTrip(metadata)
        precondition(after.dataQuality == metadata.dataQuality)
        try await emit(Report(eventProof: eventReport, densityProof: densityReport, batchProof: batchReport, deadlineProof: deadlineReport, unsortedOrderProbes: probes, metadata: metadata, afterShutdownMetadata: after, responses: responses, processPages: 2, threadPages: 2,
            directoryRecordsCompared: count, copiedCallerDTOsSurviveShutdown: true, storageBytesAfterCopies: counters.bytes,
            storageOwnersAfterCopies: counters.owners, stagingBytesAfterCopies: counters.stagingBytes, stagingOwnersAfterCopies: counters.stagingOwners,
            nativeBytesBeforeShutdown: nativeBytes))
    }
}
