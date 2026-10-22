import ArkTraceCore
import ArkTraceRustRuntime
import Foundation

private struct SummaryVector: Decodable, Sendable {
    let id: String
    let query: RustSummaryQuery
}
private struct SummaryInput: Decodable, Sendable {
    let source: String
    let format: UInt32
    let namespace: String
    let helper: String
    let parser: String
    let helperSHA256: String
    let parserIdentity: TraceParserIdentity
    let vectors: [SummaryVector]
}
private struct SummaryResponse: Codable, Sendable {
    let id: String
    let utf8: String
    let afterShutdownUTF8: String
    let typedBodyUTF8: String
    let typedAfterShutdownBodyUTF8: String
}
private struct SummaryReport: Codable, Sendable {
    let responses: [SummaryResponse]
    let pastDurationCode: ArkTraceError.Code
    let pastDurationStage: ArkTraceError.Stage
    let invalidLimitAdmission: UInt32
    let preCancelledOutcome: String
    let queryRejectedAfterClose: Bool
    let heldOwners: Int
    let heldBytes: Int
    let peakOwners: Int
    let sharedCapAndRecovery: Bool
    let ownersAfterViewDrop: Int
    let finalOwners: Int
    let finalBytes: Int
    let finalStagingBytes: Int
    let finalStagingOwners: Int
    let textSurvivesViewsAndRecords: Bool
}
private func count(_ value: RustSummaryCountView?) -> Any {
    guard let value else { return NSNull() }
    return ["value": value.value, "truncated": value.truncated] as [String: Any]
}
// Explicit consumer materialization is performed off MainActor. These arrays
// and strings are caller-owned, not retained SDK storage.
@concurrent private func body(_ value: RustSummaryView) async throws -> String {
    precondition(!Thread.isMainThread)
    var quality: [[String: Any]] = []
    for index in 0..<value.qualityIssueCount {
        let issue = value.qualityIssue(at: index)
        let scope = if let text = issue.scope { await text.copyString() } else { nil as String? }
        quality.append(["category": issue.category.rawValue, "scope": scope as Any? ?? NSNull(),
            "count": issue.count as Any? ?? NSNull(), "message": NSNull()])
    }
    var sources: Any = NSNull()
    if let collection = value.eventCountBySource {
        var items: [[String: Any]] = []
        for index in 0..<collection.count {
            items.append(["source": await collection[index].source.copyString(), "count": collection[index].count])
        }
        sources = ["items": items, "truncated": collection.truncated] as [String: Any]
    }
    let facts: [String: Any] = ["cpuCount": count(value.cpuCount), "processCount": count(value.processCount),
        "threadCount": count(value.threadCount), "cpuSliceCount": count(value.cpuSliceCount),
        "threadStateCount": count(value.threadStateCount), "namedSliceCount": count(value.namedSliceCount),
        "counterSeriesCount": count(value.counterSeriesCount), "eventCountBySource": sources, "dataQualityIssues": quality]
    return String(decoding: try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]), as: UTF8.self)
}
@concurrent private func text(_ value: RustResult) async -> String {
    precondition(!Thread.isMainThread)
    return value.withBytes { span in String(decoding: (0..<span.count).map { span[$0] }, as: UTF8.self) }
}
@concurrent private func loadInput(_ path: String) async throws -> SummaryInput {
    try JSONDecoder().decode(SummaryInput.self, from: Data(contentsOf: URL(filePath: path)))
}
@concurrent private func emit(_ value: SummaryReport) async throws {
    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(value) + Data([10]))
}
@MainActor @main private struct SummaryOwnership {
    static func main() async throws {
        let input = try await loadInput(CommandLine.arguments[1])
        let configuration = RustConfiguration.developmentFixture(namespace: URL(filePath: input.namespace),
            helper: URL(filePath: input.helper), parser: URL(filePath: input.parser), helperSHA256: input.helperSHA256,
            parserIdentity: input.parserIdentity)
        let engine = try await RustEngine.createDevelopmentFixture(configuration)
        let session = try await engine.open(URL(filePath: input.source), format: RustSourceFormat(rawValue: input.format)!)
        let opening = try await session.opening.decode(RustOpenResult.self)
        var held: [RustResult] = [], initial: [String] = []
        var typed: [RustSummaryView] = [], typedInitial: [String] = []
        for vector in input.vectors {
            let result = try await session.query(.summaryFacts(vector.query))
            initial.append(await text(result)); held.append(result)
            let view = try await session.summaryFacts(vector.query)
            typedInitial.append(try await body(view)); typed.append(view)
        }
        let heldCounts = RustEngine.developmentColdStorageCounts()
        precondition(heldCounts.owners == input.vectors.count && heldCounts.stagingBytes == 0 && heldCounts.stagingOwners == 0)
        var countFacet: RustSummaryCountView? = typed[0].processCount
        var sources = typed[0].eventCountBySource
        precondition(sources != nil && sources!.count > 0)
        var sourceRecord: RustSummarySourceRecord? = sources![0]
        var sourceText: RustOwnedText? = sourceRecord!.source
        let expectedText = await sourceText!.copyString()
        let expectedCount = countFacet!.value
        // All three typed response families consume the same process-wide
        // 256-owner pool. Independent native queries, not copies, fill it.
        do {
            var opening: RustOpenView? = try await session.openingView()
            var parser: RustParserIdentityView? = opening!.metadata.parser; opening = nil
            var page: RustProcessPage? = try await session.processes(RustProcessQuery(processKey: .max, limit: 1))
            var pressure: [RustSummaryCountView] = []
            let query = RustSummaryQuery(maximumRowsPerSection: 1, maximumEventsPerSection: 1)
            for index in 0..<(254 - typed.count) {
                let view = try await session.summaryFacts(query)
                pressure.append(view.processCount)
                if index.isMultiple(of: 32) { try await RustCleanup.flush() }
            }
            precondition(RustEngine.developmentColdStorageCounts().owners == 256)
            var rejected = 0
            do { _ = try await session.summaryFacts(query) } catch RustAdmission.capacity { rejected += 1 }
            do { _ = try await session.openingView() } catch RustAdmission.capacity { rejected += 1 }
            do { _ = try await session.processes(RustProcessQuery(processKey: .max, limit: 1)) } catch RustAdmission.capacity { rejected += 1 }
            precondition(rejected == 3 && RustEngine.developmentColdStorageCounts().owners == 256)
            pressure.removeLast()
            precondition(RustEngine.developmentColdStorageCounts().owners == 255)
            do {
                let recovered = try await session.summaryFacts(query)
                precondition(RustEngine.developmentColdStorageCounts().owners == 256 && recovered.sessionIdentity == typed[0].sessionIdentity)
            }
            precondition(RustEngine.developmentColdStorageCounts().owners == 255)
            precondition(parser!.name.utf8Count > 0 && page!.count == 0)
            pressure.removeAll(); parser = nil; page = nil
        }
        try await RustCleanup.flush()
        precondition(RustEngine.developmentColdStorageCounts().bytes == heldCounts.bytes)
        var limit: UInt32 = 0
        do {
            _ = try await session.summaryFacts(RustSummaryQuery(maximumRowsPerSection: 0))
            preconditionFailure("invalid summary budget was accepted")
        } catch let error as RustAdmission { limit = error.rawValue }
        let cancelled = Task { @MainActor in
            do {
                _ = try await session.summaryFacts()
                preconditionFailure("pre-cancelled summary was accepted")
            } catch is CancellationError { return "swiftCancellationError" }
            catch let error as RustAdmission {
                precondition(error == .cancelled)
                return "rustCancelled"
            }
        }
        // The current MainActor turn cancels this task before its first entry.
        cancelled.cancel()
        let cancellation = try await cancelled.value
        var code: ArkTraceError.Code = .internalError, stage: ArkTraceError.Stage = .querying
        do {
            let range = try TraceTimeRange(startNs: 0, endNs: opening.inspection.durationNs + 1)
            _ = try await session.summaryFacts(RustSummaryQuery(range: range))
            preconditionFailure("summary range past duration was accepted")
        } catch let error as ArkTraceError { code = error.code; stage = error.stage }
        // A new successful native request proves terminal failure did not poison
        // the worker or the private SQLite connection.
        _ = try await session.summaryFacts()
        try await session.close()
        var closed = false
        do { _ = try await session.summaryFacts() }
        catch RustAdmission.closed { closed = true }
        try await engine.shutdown()
        var responses: [SummaryResponse] = []
        for (index, result) in held.enumerated() {
            let after = await text(result)
            precondition(after == initial[index])
            let typedAfter = try await body(typed[index])
            precondition(typedAfter == typedInitial[index])
            responses.append(SummaryResponse(id: input.vectors[index].id, utf8: initial[index], afterShutdownUTF8: after,
                typedBodyUTF8: typedInitial[index], typedAfterShutdownBodyUTF8: typedAfter))
        }
        typed.removeAll()
        let afterViews = RustEngine.developmentColdStorageCounts()
        precondition(afterViews.owners == 1 && countFacet!.value == expectedCount && sources![0].count == sourceRecord!.count)
        countFacet = nil; sources = nil; sourceRecord = nil
        let afterText = await sourceText!.copyString()
        precondition(afterText == expectedText && RustEngine.developmentColdStorageCounts().owners == 1)
        sourceText = nil
        let final = RustEngine.developmentColdStorageCounts()
        precondition(final.bytes == 0 && final.owners == 0 && final.stagingBytes == 0 && final.stagingOwners == 0)
        try await emit(SummaryReport(responses: responses, pastDurationCode: code, pastDurationStage: stage,
            invalidLimitAdmission: limit, preCancelledOutcome: cancellation, queryRejectedAfterClose: closed,
            heldOwners: heldCounts.owners, heldBytes: heldCounts.bytes, peakOwners: 256, sharedCapAndRecovery: true,
            ownersAfterViewDrop: afterViews.owners, finalOwners: final.owners, finalBytes: final.bytes,
            finalStagingBytes: final.stagingBytes, finalStagingOwners: final.stagingOwners, textSurvivesViewsAndRecords: true))
    }
}
