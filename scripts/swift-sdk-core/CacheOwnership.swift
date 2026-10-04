import ArkTraceCore
import ArkTraceRustRuntime
import Foundation

private struct Input: Decodable, Sendable {
    let source, namespace, cacheDirectory, helper, parser, helperSHA256: String
    let format: UInt32
    let parserIdentity: TraceParserIdentity
    let maintenance: Bool?
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
        if input.maintenance == true {
            let empty = try await engine!.cacheInventory()
            precondition(empty.entryCount == 0 && empty.totalByteCount == 0 && empty.activeEntryCount == 0)
            let maintained = try await engine!.maintainCache()
            let purged = try await engine!.purgeUnusedCache()
            precondition(maintained.removedEntryCount == 0 && maintained.after.entryCount == 0)
            precondition(purged.removedEntryCount == 0 && purged.after.entryCount == 0)
        }
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
        if input.maintenance == true {
            let inventory = try await engine!.cacheInventory()
            precondition(inventory.entryCount == 1 && inventory.activeEntryCount == 1 && inventory.totalByteCount > 0)
            let report = try await engine!.purgeUnusedCache()
            precondition(report.removedEntryCount == 0 && report.skippedActiveEntryCount == 1 && report.after.entryCount == 1)
            let maintained = try await engine!.maintainCache()
            precondition(maintained.removedEntryCount == 0 && maintained.after.entryCount == 1)
        }
        try await first!.close(); try await first!.close(); first = nil
        if input.maintenance == true {
            let report = try await engine!.purgeUnusedCache()
            precondition(report.removedEntryCount == 0 && report.skippedActiveEntryCount == 1 && report.after.activeEntryCount == 1)
        }
        let afterClose = try await page(second!)
        precondition(afterClose == original)
        try await second!.close(); second = nil; try await RustCleanup.flush()
        if input.maintenance == true {
            let fixed = engine!
            // This task inherits MainActor and is cancelled before its first
            // actor hop. An inactive Ready would be deleted if admitted.
            let cancelled = Task { try await fixed.purgeUnusedCache() }
            cancelled.cancel()
            do { _ = try await cancelled.value; preconditionFailure("pre-cancelled purge admitted") }
            catch { precondition(error is CancellationError) }
            let inventory = try await engine!.cacheInventory()
            precondition(inventory.entryCount == 1 && inventory.activeEntryCount == 0)
            do { _ = try await engine!.cacheInventory(timeoutMilliseconds: 0); preconditionFailure("zero timeout admitted") }
            catch { precondition(error as? RustAdmission == .invalidInput) }
            try await RustCleanup.flush()
        }
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
        if input.maintenance == true {
            let report = try await reopenedEngine!.purgeUnusedCache()
            precondition(report.removedEntryCount == 1 && report.after.entryCount == 0)
            let empty = try await reopenedEngine!.cacheInventory()
            precondition(empty.entryCount == 0 && empty.totalByteCount == 0)
            var reparsed: RustSession? = try await reopenedEngine!.open(URL(filePath: input.source), format: format)
            let opening = try await reparsed!.opening.decode(RustOpenResult.self)
            precondition(!opening.cacheHit)
            let current = try await page(reparsed!)
            precondition(current == original)
            try await reparsed!.close(); reparsed = nil
            try await RustCleanup.flush()
        }
        let reopenedNativeBytes = try await reopenedEngine!.retainedResultBytes()
        precondition(reopenedNativeBytes == 0)
        try await reopenedEngine!.shutdown(); reopenedEngine = nil
        var report = ["coldOpened": true, "warmCacheHit": true, "timestampAdvanced": true, "createdTimestampPreserved": true,
            "concurrentSessionSurvivesTouch": true, "secondSessionSurvivesFirstClose": true, "openingOwnersSurviveShutdown": true,
            "allStorageCreditsReleased": true, "restartCacheHit": true, "queryPagesEqual": true, "fullCacheAcceptance": false,
            "appCutover": false]
        if input.maintenance == true {
            report["runtimeSDKMaintenanceConnected"] = true
            report["cacheMaintenanceBeforeOpen"] = true
            report["cacheMaintenanceActiveProtected"] = true
            report["cacheMaintenanceOneReaderProtected"] = true
            report["cacheMaintenancePurgeAndReparse"] = true
            report["cacheMaintenancePreCancelledPreservesReady"] = true
        }
        try await emit(report)
    }
}

@MainActor func runCacheOwnership() async throws { try await CacheOwnership.run() }
