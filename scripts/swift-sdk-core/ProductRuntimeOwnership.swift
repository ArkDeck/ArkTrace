import ArkTraceAppSupport
import ArkTraceCore
import ArkTraceRendering
import ArkTraceRustRuntime
import Foundation

private struct ProductInput: Decodable, Sendable {
    let source, namespace, cacheDirectory, helper, parser, helperSHA256, manifest: String
    let parserIdentity: TraceParserIdentity
}
@concurrent private func productInput() async throws -> ProductInput {
    try JSONDecoder().decode(ProductInput.self, from: Data(contentsOf: URL(filePath: CommandLine.arguments[1])))
}
@concurrent private func prepareProductRoots(_ input: ProductInput) async throws -> (URL, URL) {
    let base = URL(filePath: input.cacheDirectory).deletingLastPathComponent().appending(path: "product-runtime")
    let native = base.appending(path: "native"), legacy = base.appending(path: "legacy")
    for root in [native, legacy] {
        for leaf in ["traces", "staging"] {
            try FileManager.default.createDirectory(at: root.appending(path: leaf), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
    }
    let copied = URL(filePath: input.parser).deletingLastPathComponent().appending(path: "manifest.json")
    try FileManager.default.copyItem(at: URL(filePath: input.manifest), to: copied)
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: copied.path)
    return (native, legacy)
}
private func productProfile(_ root: URL, input: ProductInput, key: String) throws -> TraceProductConfiguration {
    try TraceProductConfiguration(bundleURL: URL(filePath: input.parser).deletingLastPathComponent(),
        cacheDirectory: root.appending(path: "traces"), stagingDirectory: root.appending(path: "staging"),
        recentDocumentsKey: key, signpostSubsystem: "dev.arktrace.product.conformance",
        bundledParser: TraceBundledParserLocation(executableRelativePath: "parser", manifestRelativePath: "manifest.json"))
}
@concurrent private func productRaw<T: Encodable & Sendable>(_ value: T) async throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}
// Same explicit machine boundary as NativeViewportOracle. Keep every typed
// fact, null/count and duplicate; only prose and probe traversal order differ.
// Raw outputs remain separate evidence. No product result is changed here.
private func productQuality(_ value: TraceDataQuality) throws -> TraceDataQuality {
    guard value.issues.count <= 4096,
          value.status == (value.issues.isEmpty ? .ok : .warnings) else { throw RustAdmission.invalidBuffer }
    return try TraceDataQuality(machineIssues: value.issues.sorted {
        ($0.category.rawValue, $0.scope ?? "", $0.count ?? .min)
            < ($1.category.rawValue, $1.scope ?? "", $1.count ?? .min)
    })
}
@concurrent private func productMetadata(_ metadata: TraceMetadata?) async throws -> Data {
    guard let value = metadata else { return try await productRaw(metadata) }
    return try await productRaw(TraceMetadata(traceSHA256: value.traceSHA256, sourceByteCount: value.sourceByteCount,
        durationNs: value.durationNs, sourceFormat: value.sourceFormat, parser: value.parser,
        schemaFingerprint: value.schemaFingerprint, capabilities: value.capabilities, dataQuality: productQuality(value.dataQuality)))
}
private func productSnapshot(_ value: TimelineSnapshot?) throws -> TimelineSnapshot? {
    try value.map { try TimelineSnapshot(viewport: $0.viewport, tracks: $0.tracks, generation: $0.generation,
        dataQuality: productQuality($0.dataQuality), isLoading: $0.isLoading) }
}
@concurrent private func preserveProductMetadata(_ native: Data, _ legacy: Data, input: ProductInput) async throws {
    let root = URL(filePath: input.cacheDirectory).deletingLastPathComponent()
    try native.write(to: root.appending(path: "product-native-metadata.json"))
    try legacy.write(to: root.appending(path: "product-swift-metadata.json"))
}
@concurrent private func productSourceAliases(_ source: URL, input: ProductInput) async throws -> [URL] {
    let root = URL(filePath: input.cacheDirectory).deletingLastPathComponent().appending(path: "source-aliases")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return try ["ftrace", "trace", "HTRACE", ""].map { hint in
        let alias = root.appending(path: hint.isEmpty ? "source" : "source.\(hint)")
        try FileManager.default.copyItem(at: source, to: alias)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: alias.path)
        return alias
    }
}
@concurrent private func preserveProductAliasMetadata(_ native: Data, _ legacy: Data, alias: URL) async throws {
    let name = alias.lastPathComponent
    try native.write(to: alias.deletingLastPathComponent().appending(path: "\(name)-native.json"))
    try legacy.write(to: alias.deletingLastPathComponent().appending(path: "\(name)-swift.json"))
}
@concurrent private func preserveProductSidecar(_ root: URL, input: ProductInput) async throws {
    let manager = FileManager.default
    let entries = manager.enumerator(at: root, includingPropertiesForKeys: nil)!
    let files = entries.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "view-state.json" }
    guard files.count == 1 else { throw ArkTraceError(code: .internalError, stage: .request,
        message: "Product persistence did not create exactly one sidecar") }
    let sidecar = files[0]
    let directory = URL(filePath: input.cacheDirectory).deletingLastPathComponent()
    try Data(contentsOf: sidecar).write(to: directory.appending(path: "product-saved-view-state.json"))
    let attributes = try manager.attributesOfItem(atPath: sidecar.path)
    precondition((attributes[.posixPermissions] as! NSNumber).intValue == 0o600)
    try await productRaw(["permissions": (attributes[.posixPermissions] as! NSNumber).intValue])
        .write(to: directory.appending(path: "product-saved-view-state-permissions.json"))
}
@MainActor private func waitForProduct(_ controller: TraceDocumentController) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(90))
    while controller.phase != .ready {
        if controller.phase == .failed { throw ArkTraceError(code: .internalError, stage: .openingDatabase,
            message: "Product controller failed", details: ["reason": controller.errorPresentation?.reason ?? "unknown"]) }
        guard ContinuousClock.now < deadline else { throw RustAdmission.busy }
        try await Task.sleep(for: .milliseconds(1))
    }
    await controller.awaitCacheMaintenanceForTesting()
}
@concurrent private func productEmit(_ value: [String: Bool]) async throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    try FileHandle.standardOutput.write(contentsOf: encoder.encode(value) + Data([10]))
}

@MainActor func runProductRuntimeOwnership() async throws {
    let input = try await productInput()
    let roots = try await prepareProductRoots(input)
    let key = "ArkTraceNativeProductConformance.\(UUID().uuidString)"
    let legacyKey = key + ".legacy"
    defer { UserDefaults.standard.removeObject(forKey: key); UserDefaults.standard.removeObject(forKey: legacyKey) }
    let profile = try productProfile(roots.0, input: input, key: key)
    let config = RustConfiguration.developmentFixture(namespace: profile.stagingDirectory,
        helper: URL(filePath: input.helper), parser: URL(filePath: input.parser), helperSHA256: input.helperSHA256,
        parserIdentity: input.parserIdentity, storagePolicy: .contentAddressed(cacheDirectory: profile.cacheDirectory))
    let product = try await TraceRustProductRuntime.createDevelopmentFixture(configuration: profile, runtimeConfiguration: config)
    let before = try await product.cacheMaintenance.inventory()
    precondition(before.entryCount == 0 && before.totalByteCount == 0 && before.activeEntryCount == 0)
    let first = product.makeDocumentController(), second = product.makeDocumentController()
    let legacy = TraceDocumentController(configuration: try productProfile(roots.1, input: input, key: legacyKey))
    let source = URL(filePath: input.source)
    first.open(source); try await waitForProduct(first)
    legacy.open(source); try await waitForProduct(legacy)
    let nativeMetadata = try await productMetadata(first.metadata), legacyMetadata = try await productMetadata(legacy.metadata)
    try await preserveProductMetadata(productRaw(first.metadata), productRaw(legacy.metadata), input: input)
    precondition(nativeMetadata == legacyMetadata)
    precondition(first.trackGroups == legacy.trackGroups)
    let nativeSnapshot = try productSnapshot(first.snapshot), legacySnapshot = try productSnapshot(legacy.snapshot)
    precondition(nativeSnapshot == legacySnapshot)
    precondition(!first.cacheHit && first.snapshot != nil && !first.trackGroups.isEmpty)
    second.open(source); try await waitForProduct(second)
    let secondMetadata = try await productMetadata(second.metadata)
    precondition(second.cacheHit && secondMetadata == nativeMetadata)
    for alias in try await productSourceAliases(source, input: input) {
        second.open(alias); try await waitForProduct(second)
        legacy.open(alias); try await waitForProduct(legacy)
        let aliasNative = try await productMetadata(second.metadata), aliasLegacy = try await productMetadata(legacy.metadata)
        try await preserveProductAliasMetadata(productRaw(second.metadata), productRaw(legacy.metadata), alias: alias)
        precondition(second.cacheHit && legacy.cacheHit && aliasNative == aliasLegacy)
        precondition(second.metadata?.sourceFormat == (alias.pathExtension.isEmpty ? nil : alias.pathExtension))
        precondition(second.trackGroups == legacy.trackGroups)
        let aliasNativeSnapshot = try productSnapshot(second.snapshot), aliasLegacySnapshot = try productSnapshot(legacy.snapshot)
        precondition(aliasNativeSnapshot == aliasLegacySnapshot)
    }
    second.open(source); try await waitForProduct(second)
    precondition(second.cacheHit)
    await first.refreshCacheInventory()
    precondition(first.cacheInventory?.entryCount == 1 && first.cacheInventory?.activeEntryCount == 1)
    await first.purgeUnusedCache()
    precondition(first.cacheInventory?.entryCount == 1)
    let activePurge = try await product.cacheMaintenance.purgeUnused()
    precondition(activePurge.removedEntryCount == 0 && activePurge.skippedActiveEntryCount == 1)
    await first.close()
    let oneReader = try await product.cacheMaintenance.purgeUnused()
    precondition(oneReader.removedEntryCount == 0 && oneReader.after.activeEntryCount == 1)

    let bounds = second.timelineBounds!
    _ = second.addFlag(atNs: bounds.startNs, label: "保存 🦀")
    let range = try TraceTimeRange.query(startNs: bounds.startNs, endNs: min(bounds.endNs, bounds.startNs + 100))
    second.selectRange(range)
    _ = second.addMark(isPersistent: true, label: "kept")
    _ = second.addMark(isPersistent: false, label: "transient")
    let track = second.trackGroups.flatMap(\.tracks)[0].id
    second.toggleFavorite(track)
    let expectedFlags = second.annotations.flags
    let expectedMarks = second.annotations.marks.filter(\.isPersistent)
    let expectedFavorites = second.favoriteTrackIDs
    await second.close()
    try await preserveProductSidecar(profile.cacheDirectory, input: input)
    second.open(source); try await waitForProduct(second)
    precondition(second.cacheHit && second.annotations.flags == expectedFlags)
    precondition(second.annotations.marks == expectedMarks && second.favoriteTrackIDs == expectedFavorites)
    await second.close()
    await second.purgeUnusedCache()
    precondition(second.cacheInventory?.entryCount == 0)
    second.open(source); try await waitForProduct(second)
    precondition(!second.cacheHit && second.annotations.isEmpty && second.favoriteTrackIDs.isEmpty)
    await second.close(); await legacy.close()
    try await product.shutdown(); try await RustCleanup.flush()
    let storage = RustEngine.developmentColdStorageCounts()
    precondition(storage.bytes == 0 && storage.owners == 0 && storage.stagingBytes == 0 && storage.stagingOwners == 0)
    try await productEmit(["productRuntimeConnected": true, "controllerMachineModelsEqualToSwift": true,
        "sourceFormatAliasMetadataEqualToSwift": true,
        "cacheMaintenanceBeforeOpen": true, "cacheMaintenanceActiveProtected": true,
        "cacheMaintenanceOneReaderProtected": true, "controllerSettingsPurgeAndReparse": true,
        "annotationsAndFavoritesRoundTrip": true, "persistenceDrainedBeforeClose": true,
        "allStorageCreditsReleased": true, "appCutover": false, "fullCacheAcceptance": false])
}
