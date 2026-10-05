import ArkTraceAppSupport
import ArkTraceCore
import ArkTraceRendering
import ArkTraceRustRuntime
import Foundation

private struct ProductInput: Decodable, Sendable {
    let source, namespace, cacheDirectory, helper, parser, helperSHA256, manifest: String
    let parserIdentity: TraceParserIdentity
    let productViewStateLockProbe: Bool?
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
    precondition((attributes[.posixPermissions] as! NSNumber).intValue == 0o400)
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

@concurrent private func productSidecarURL(_ root: URL) async throws -> URL {
    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        .compactMap { $0 as? URL }.filter { $0.lastPathComponent == "view-state.json" }
    guard files.count == 1 else { throw RustAdmission.invalidBuffer }
    return files[0]
}
private struct ProductSidecar: Codable, Sendable {
    let formatVersion: Int
    let traceSHA256: String
    let flags: [TimelineFlag]
    let marks: [TimelineMark]
    let favoriteTrackIDs: [String]?
}
@concurrent private func productReplaceSidecar(_ file: URL, _ sidecar: ProductSidecar) async throws -> Data {
    let data = try JSONEncoder().encode(sidecar)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    try data.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return data
}
@concurrent private func productSidecarBytes(_ file: URL) async throws -> Data { try Data(contentsOf: file) }
@concurrent private func productPreserveSidecar(_ data: Data, name: String, input: ProductInput) async throws {
    try data.write(to: URL(filePath: input.cacheDirectory).deletingLastPathComponent().appending(path: name))
}
@concurrent private func productWaitForProbe() async throws {
    _ = try FileHandle.standardInput.read(upToCount: 1)
}
@concurrent private func productProbeEvent(_ value: [String: String]) async throws {
    try await FileHandle.standardOutput.write(contentsOf: productRaw(value) + Data([10]))
}

@MainActor private func productViewStateChecks(_ controller: TraceDocumentController,
    product: TraceRustProductRuntime, profile: TraceProductConfiguration, source: URL, input: ProductInput) async throws {
    let file = try await productSidecarURL(profile.cacheDirectory)
    let trace = file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
    let track = controller.trackGroups.flatMap(\.tracks)[0].id
    let unknown = TimelineTrackID(rawValue: "missing\0🦀")
    let flags = [TimelineFlag(id: .max, timestampNs: .max, label: "last\0🦀", colorIndex: .max),
                 TimelineFlag(id: 1, timestampNs: .min, label: "first", colorIndex: .min)]
    let marks = [TimelineMark(id: .min, range: try .query(startNs: .max - 1, endNs: .max),
        label: "kept extreme", colorIndex: .max, isPersistent: true)]
    let favorites = [unknown, track, unknown, track]
    await controller.close()
    let original = ProductSidecar(formatVersion: 1, traceSHA256: trace, flags: flags, marks: marks,
        favoriteTrackIDs: favorites.map(\.rawValue))
    _ = try await productReplaceSidecar(file, original)
    controller.open(source); try await waitForProduct(controller)
    precondition(controller.annotations.flags == flags && controller.annotations.marks == marks)
    precondition(controller.favoriteTrackIDs == favorites && controller.favoriteTracks().map(\.id) == [track])
    let added = controller.addFlag(atNs: 0, label: "unused identity")!
    precondition(added.id == 2)
    controller.updateFlag(id: .max, colorIndex: TimelineAnnotationColor.nextIndex(after: .max))
    await controller.close()
    let stored = try await productSidecarBytes(file)
    let decoded = try JSONDecoder().decode(ProductSidecar.self, from: stored)
    precondition(decoded.flags[0].id == .max && decoded.flags[0].timestampNs == .max && decoded.flags[0].colorIndex == 2)
    precondition(decoded.flags[1] == flags[1] && decoded.marks == marks && decoded.favoriteTrackIDs == favorites.map(\.rawValue))
    try await productPreserveSidecar(stored, name: "product-extreme-view-state.json", input: input)

    let future = ProductSidecar(formatVersion: 999, traceSHA256: trace, flags: flags, marks: marks,
        favoriteTrackIDs: favorites.map(\.rawValue))
    let futureBytes = try await productReplaceSidecar(file, future)
    controller.open(source); try await waitForProduct(controller)
    precondition(controller.phase == .ready && controller.annotations.isEmpty && controller.errorPresentation != nil)
    _ = controller.addFlag(atNs: 0, label: "cannot replace future")
    await controller.close()
    precondition(controller.phase == .failed && controller.errorPresentation?.diagnostic.contains("viewStatePreserved") == true)
    let afterFuture = try await productSidecarBytes(file)
    precondition(afterFuture == futureBytes)
    try await productPreserveSidecar(afterFuture, name: "product-future-view-state.json", input: input)
    let inventory = try await product.cacheMaintenance.inventory()
    precondition(inventory.activeEntryCount == 0)
    await controller.close()
    precondition(controller.phase == .idle)
    _ = try await productReplaceSidecar(file, original)
    controller.open(source); try await waitForProduct(controller)
    precondition(controller.annotations.flags == flags && controller.errorPresentation == nil)

    if input.productViewStateLockProbe == true {
        try await productProbeEvent(["phase": "controller-lock-ready", "parserKey": file.deletingLastPathComponent().lastPathComponent])
        try await productWaitForProbe()
        let start = ContinuousClock.now
        var uiTicks = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled { uiTicks += 1; try? await Task.sleep(for: .milliseconds(1)) }
        }
        _ = controller.addFlag(atNs: 0, label: "blocked native save")
        await controller.close()
        ticker.cancel()
        precondition(start.duration(to: .now) < .seconds(5))
        precondition(uiTicks > 5)
        precondition(controller.phase == .failed && controller.errorPresentation?.diagnostic.contains("QUERY_TIMEOUT") == true)
        precondition(controller.annotations.flags.count == 3)
        try await productProbeEvent(["phase": "controller-lock-complete", "closeBounded": "true", "saveTimeoutVisible": "true", "uiTicks": String(uiTicks)])
        try await productWaitForProbe()
        let released = try await product.cacheMaintenance.inventory()
        precondition(released.activeEntryCount == 0)
        await controller.close()
        precondition(controller.phase == .idle)
        controller.open(source); try await waitForProduct(controller)
        precondition(controller.annotations.flags == flags && controller.errorPresentation == nil)
    }
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
    let product = try await TraceRustProductRuntime.createDevelopmentFixture(configuration: profile, runtimeConfiguration: config,
        queryTimeoutMilliseconds: input.productViewStateLockProbe == true ? 1_000 : 30_000)
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
    try await productViewStateChecks(second, product: product, profile: profile, source: source, input: input)
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
        "controllerViewStateExtremaAndUnknownFavorites": true, "controllerFutureSidecarPreserved": true,
        "failedSaveStillReleasesSession": true,
        "allStorageCreditsReleased": true, "appCutover": false, "fullCacheAcceptance": false])
}
