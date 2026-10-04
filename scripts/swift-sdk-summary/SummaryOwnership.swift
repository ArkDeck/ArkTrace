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
}
private struct SummaryReport: Codable, Sendable {
    let responses: [SummaryResponse]
    let pastDurationCode: ArkTraceError.Code
    let pastDurationStage: ArkTraceError.Stage
    let invalidLimitAdmission: UInt32
    let preCancelledOutcome: String
    let queryRejectedAfterClose: Bool
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
        for vector in input.vectors {
            let result = try await session.query(.summaryFacts(vector.query))
            initial.append(await text(result)); held.append(result)
        }
        var limit: UInt32 = 0
        do {
            _ = try await session.query(.summaryFacts(RustSummaryQuery(maximumRowsPerSection: 0)))
            preconditionFailure("invalid summary budget was accepted")
        } catch let error as RustAdmission { limit = error.rawValue }
        let cancelled = Task { @MainActor in
            do {
                _ = try await session.query(.summaryFacts(RustSummaryQuery()))
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
            _ = try await session.query(.summaryFacts(RustSummaryQuery(range: range)))
            preconditionFailure("summary range past duration was accepted")
        } catch let error as ArkTraceError { code = error.code; stage = error.stage }
        // A new successful native request proves terminal failure did not poison
        // the worker or the private SQLite connection.
        _ = try await session.query(.summaryFacts(RustSummaryQuery()))
        try await session.close()
        var closed = false
        do { _ = try await session.query(.summaryFacts(RustSummaryQuery())) }
        catch RustAdmission.closed { closed = true }
        try await engine.shutdown()
        var responses: [SummaryResponse] = []
        for (index, result) in held.enumerated() {
            let after = await text(result)
            precondition(after == initial[index])
            responses.append(SummaryResponse(id: input.vectors[index].id, utf8: initial[index], afterShutdownUTF8: after))
        }
        try await emit(SummaryReport(responses: responses, pastDurationCode: code, pastDurationStage: stage,
            invalidLimitAdmission: limit, preCancelledOutcome: cancellation, queryRejectedAfterClose: closed))
    }
}
