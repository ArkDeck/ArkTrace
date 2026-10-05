import ArkTraceAppSupport
import ArkTraceCore
import ArkTraceRendering
import ArkTraceRustRuntime
import Foundation

private struct ProductMigrationInput: Decodable, Sendable {
    let source, namespace, cacheDirectory, helper, parser, helperSHA256: String
    let legacyCacheDirectory, backupDirectory: String
    let parserIdentity: TraceParserIdentity
}
private struct ProductMigrationOutput: Encodable, Sendable {
    let coldStatus, warmStatus: String
    let flags: [TimelineFlag]
    let persistentMarks: [TimelineMark]
    let favoriteTrackIDs: [String]
    let unmatchedFavoriteTrackIDs: [String]
    let candidateCount: Int
    let traceRemainedReady, latestEditRestored, activeEntriesReleased: Bool
    let sdkStorageBytes, sdkStorageOwners, nativeInputBytes: Int
}
@concurrent private func loadProductMigration() async throws -> ProductMigrationInput {
    try JSONDecoder().decode(ProductMigrationInput.self,
        from: Data(contentsOf: URL(filePath: CommandLine.arguments[1])))
}
@concurrent private func emitProductMigration(_ output: ProductMigrationOutput) async throws {
    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(output) + Data([10]))
}
@MainActor private func awaitProductMigration(_ controller: TraceDocumentController) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(60))
    while controller.phase != .ready {
        guard controller.phase != .failed, ContinuousClock.now < deadline else {
            throw ArkTraceError(code: .internalError, stage: .openingDatabase,
                message: "Migration controller did not become Ready", details: ["diagnostic": controller.errorPresentation?.diagnostic ?? "deadline"])
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    precondition(controller.errorPresentation == nil)
}

/// Development-only package consumer. Runs the same native opener, restoration,
/// persistence queue and generation state as a product controller.
@MainActor func runProductMigrationOwnership() async throws {
    let input = try await loadProductMigration()
    let parser = URL(filePath: input.parser)
    let migration = try TraceProductViewStateMigrationConfiguration(
        legacyCacheDirectory: URL(filePath: input.legacyCacheDirectory), backupDirectory: URL(filePath: input.backupDirectory))
    let key = "ArkTraceProductMigrationConformance.\(UUID().uuidString)"
    defer { UserDefaults.standard.removeObject(forKey: key) }
    let profile = try TraceProductConfiguration(bundleURL: parser.deletingLastPathComponent(),
        cacheDirectory: URL(filePath: input.cacheDirectory), stagingDirectory: URL(filePath: input.namespace),
        recentDocumentsKey: key, signpostSubsystem: "dev.arktrace.migration.conformance",
        bundledParser: TraceBundledParserLocation(executableRelativePath: parser.lastPathComponent, manifestRelativePath: "manifest.json"),
        viewStateMigration: migration)
    let runtime = RustConfiguration.developmentFixture(namespace: profile.stagingDirectory,
        helper: URL(filePath: input.helper), parser: parser, helperSHA256: input.helperSHA256,
        parserIdentity: input.parserIdentity, storagePolicy: .contentAddressed(cacheDirectory: profile.cacheDirectory),
        viewStateMigration: RustViewStateMigrationConfiguration(legacyCacheDirectory: migration.legacyCacheDirectory,
            backupDirectory: migration.backupDirectory))
    var product: TraceRustProductRuntime? = try await TraceRustProductRuntime.createDevelopmentFixture(
        configuration: profile, runtimeConfiguration: runtime)
    var controller: TraceDocumentController? = product!.makeDocumentController()
    let source = URL(filePath: input.source)
    controller!.open(source); try await awaitProductMigration(controller!)
    precondition(!controller!.cacheHit && !controller!.isImportingLegacyViewState)
    let report = controller!.viewStateMigration!
    precondition(report.status == .imported)
    let flags = controller!.annotations.flags
    let marks = controller!.annotations.marks.filter(\.isPersistent)
    let favorites = controller!.favoriteTrackIDs.map(\.rawValue)
    await controller!.close(); precondition(controller!.phase == .idle)
    controller!.open(source); try await awaitProductMigration(controller!)
    precondition(controller!.cacheHit && controller!.annotations.flags == flags
        && controller!.annotations.marks.filter(\.isPersistent) == marks
        && controller!.favoriteTrackIDs.map(\.rawValue) == favorites)
    let warm = controller!.viewStateMigration!.status
    precondition(warm == .alreadyCompleted)
    let added = controller!.addFlag(atNs: 10, label: "native controller edit")!
    await controller!.close(); precondition(controller!.phase == .idle)
    controller!.open(source); try await awaitProductMigration(controller!)
    precondition(controller!.annotations.flags == flags + [added])
    precondition(controller!.favoriteTrackIDs.map(\.rawValue) == favorites)
    await controller!.close(); controller = nil
    let inventory = try await product!.cacheMaintenance.inventory()
    precondition(inventory.activeEntryCount == 0)
    try await product!.shutdown(); product = nil
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while RustEngine.developmentColdStorageCounts().owners != 0 {
        precondition(ContinuousClock.now < deadline)
        try await Task.sleep(for: .milliseconds(1))
    }
    let storage = RustEngine.developmentColdStorageCounts(), credits = RustEngine.developmentViewStateInputCounts()
    precondition(storage.bytes == 0 && storage.owners == 0 && storage.stagingBytes == 0
        && storage.stagingOwners == 0 && credits.bytes == 0 && credits.owners == 0)
    try await emitProductMigration(ProductMigrationOutput(coldStatus: report.status.rawValue, warmStatus: warm.rawValue,
        flags: flags, persistentMarks: marks, favoriteTrackIDs: favorites,
        unmatchedFavoriteTrackIDs: report.unmatchedFavoriteTrackIDs, candidateCount: report.candidates.count,
        traceRemainedReady: true, latestEditRestored: true, activeEntriesReleased: true,
        sdkStorageBytes: storage.bytes, sdkStorageOwners: storage.owners, nativeInputBytes: credits.bytes))
}
