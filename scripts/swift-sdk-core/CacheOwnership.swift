import ArkTraceCore
import ArkTraceRustRuntime
import Foundation

private struct Input: Decodable, Sendable {
    let source, namespace, cacheDirectory, helper, parser, helperSHA256: String
    let format: UInt32
    let parserIdentity: TraceParserIdentity
}
@concurrent private func load(_ path: String) async throws -> Input {
    try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(filePath: path)))
}
@concurrent private func encode<T: Encodable & Sendable>(_ value: T) async throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}
@concurrent private func page(_ session: RustSession) async throws -> Data {
    let page = try await session.processes(RustProcessQuery(limit: 100))
    let copied = try await page.copyCorePage()
    return try await encode(ProcessPageDocument(items: copied.items, truncated: copied.truncated, dataQualityIssues: copied.dataQualityIssues))
}
private struct ProcessPageDocument: Encodable, Sendable {
    let items: [TraceProcess]
    let truncated: Bool
    let dataQualityIssues: [TraceDataQualityIssue]
}
@concurrent private func emit(_ report: [String: Bool]) async throws {
    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(report) + Data([10]))
}

@MainActor private struct CacheOwnership {
    static func run() async throws {
        let input = try await load(CommandLine.arguments[1])
        let format = RustSourceFormat(rawValue: input.format)!
        let config = RustConfiguration.developmentFixture(namespace: URL(filePath: input.namespace),
            helper: URL(filePath: input.helper), parser: URL(filePath: input.parser), helperSHA256: input.helperSHA256,
            parserIdentity: input.parserIdentity, storagePolicy: .contentAddressed(cacheDirectory: URL(filePath: input.cacheDirectory)))
        var engine: RustEngine? = try await RustEngine.createDevelopmentFixture(config)
        var first: RustSession? = try await engine!.open(URL(filePath: input.source), format: format)
        var cold: RustOpenView? = try await first!.openingView()
        precondition(!cold!.cacheHit)
        let coldWire = try await first!.opening.decode(RustOpenResult.self)
        precondition(!coldWire.cacheHit)
        let coldCreated = await cold!.metadata.createdAt.copyString()
        let coldAccessed = await cold!.metadata.lastAccessedAt.copyString()
        let metadata = try await cold!.copyTraceMetadata(sourceFormat: format)
        let original = try await page(first!)
        try await Task.sleep(for: .seconds(1))
        var second: RustSession? = try await engine!.open(URL(filePath: input.source), format: format)
        var warm: RustOpenView? = try await second!.openingView()
        precondition(warm!.cacheHit)
        let warmCreated = await warm!.metadata.createdAt.copyString()
        let warmAccessed = await warm!.metadata.lastAccessedAt.copyString()
        precondition(warmCreated == coldCreated && warmAccessed > coldAccessed)
        let current = try await page(first!), other = try await page(second!)
        precondition(current == original && other == original)
        let warmMetadata = try await warm!.copyTraceMetadata(sourceFormat: format)
        let a = try await encode(metadata), b = try await encode(warmMetadata)
        precondition(a == b)
        try await first!.close(); try await first!.close(); first = nil
        let afterClose = try await page(second!)
        precondition(afterClose == original)
        try await second!.close(); second = nil; try await RustCleanup.flush()
        let nativeBytes = try await engine!.retainedResultBytes()
        precondition(nativeBytes == 0)
        try await engine!.shutdown(); engine = nil
        precondition(cold!.cacheHit == false && warm!.cacheHit)
        // Retained opening views survive native drain, then return their credits.
        cold = nil; warm = nil
        let counts = RustEngine.developmentColdStorageCounts()
        precondition(counts.bytes == 0 && counts.owners == 0 && counts.stagingBytes == 0 && counts.stagingOwners == 0)
        var reopenedEngine: RustEngine? = try await RustEngine.createDevelopmentFixture(config)
        var reopened: RustSession? = try await reopenedEngine!.open(URL(filePath: input.source), format: format)
        let reopenedWire = try await reopened!.opening.decode(RustOpenResult.self)
        precondition(reopenedWire.cacheHit)
        let afterRestart = try await page(reopened!)
        precondition(afterRestart == original)
        try await reopened!.close(); reopened = nil; try await RustCleanup.flush()
        let reopenedNativeBytes = try await reopenedEngine!.retainedResultBytes()
        precondition(reopenedNativeBytes == 0)
        try await reopenedEngine!.shutdown(); reopenedEngine = nil
        try await emit(["coldOpened": true, "warmCacheHit": true, "timestampAdvanced": true, "createdTimestampPreserved": true,
            "concurrentSessionSurvivesTouch": true, "secondSessionSurvivesFirstClose": true, "openingOwnersSurviveShutdown": true,
            "allStorageCreditsReleased": true, "restartCacheHit": true, "queryPagesEqual": true, "fullCacheAcceptance": false,
            "appCutover": false])
    }
}

@MainActor func runCacheOwnership() async throws { try await CacheOwnership.run() }
