#if canImport(ArkTraceRustRuntime)
import ArkTraceCore
import ArkTraceRuntime
import ArkTraceRustRuntime
import Foundation

/// One fixed product profile and native Engine, shared by its document windows
/// and maintenance service. Requests cannot replace tools, roots or policies.
/// The host closes its controllers before explicitly shutting down this owner.
public final class TraceRustProductRuntime: Sendable {
    public let cacheMaintenance: TraceCacheMaintenanceService
    private let configuration: TraceProductConfiguration
    private let engine: RustEngine
    private let operations: TraceCacheMaintenanceOperations
    private let openTimeoutMilliseconds: UInt32
    private let queryTimeoutMilliseconds: UInt32

    @concurrent
    public static func create(
        configuration: TraceProductConfiguration,
        runtimeConfiguration: RustConfiguration,
        openTimeoutMilliseconds: UInt32 = 60_000,
        queryTimeoutMilliseconds: UInt32 = 30_000
    ) async throws -> TraceRustProductRuntime {
        try validate(configuration, runtimeConfiguration, openTimeoutMilliseconds, queryTimeoutMilliseconds)
        do {
            return TraceRustProductRuntime(configuration: configuration,
                engine: try await RustEngine.create(runtimeConfiguration),
                openTimeoutMilliseconds: openTimeoutMilliseconds, queryTimeoutMilliseconds: queryTimeoutMilliseconds)
        } catch { throw mapped(error, stage: .preparing) }
    }

    #if ARKTRACE_RUST_PROCESS_FIXTURES
    /// Package-only conformance entry. Production creation still requires the
    /// native publisher policy; this cannot be selected by an open request.
    @concurrent
    package static func createDevelopmentFixture(
        configuration: TraceProductConfiguration,
        runtimeConfiguration: RustConfiguration,
        openTimeoutMilliseconds: UInt32 = 60_000,
        queryTimeoutMilliseconds: UInt32 = 30_000
    ) async throws -> TraceRustProductRuntime {
        try validate(configuration, runtimeConfiguration, openTimeoutMilliseconds, queryTimeoutMilliseconds)
        return TraceRustProductRuntime(configuration: configuration,
            engine: try await RustEngine.createDevelopmentFixture(runtimeConfiguration),
            openTimeoutMilliseconds: openTimeoutMilliseconds, queryTimeoutMilliseconds: queryTimeoutMilliseconds)
    }
    #endif

    private init(configuration: TraceProductConfiguration, engine: RustEngine,
                 openTimeoutMilliseconds: UInt32, queryTimeoutMilliseconds: UInt32) {
        self.configuration = configuration
        self.engine = engine
        self.openTimeoutMilliseconds = openTimeoutMilliseconds
        self.queryTimeoutMilliseconds = queryTimeoutMilliseconds
        let operations = TraceCacheMaintenanceOperations(
            inventory: {
                do { return try await Self.inventory(engine.cacheInventory()) }
                catch { throw Self.mapped(error, stage: .cacheLookup) }
            },
            maintain: {
                do { return try await Self.report(engine.maintainCache()) }
                catch { throw Self.mapped(error, stage: .cacheLookup) }
            },
            purgeUnused: {
                do { return try await Self.report(engine.purgeUnusedCache()) }
                catch { throw Self.mapped(error, stage: .cacheLookup) }
            }
        )
        self.operations = operations
        cacheMaintenance = TraceCacheMaintenanceService(operations: operations)
    }

    @MainActor
    public func makeDocumentController() -> TraceDocumentController {
        TraceDocumentController(
            recentStore: TraceRecentDocumentStore(key: configuration.recentDocumentsKey),
            maintenanceOperations: operations,
            signposts: TraceAppSignposts(subsystem: configuration.signpostSubsystem),
            opener: { [self] source, progress in try await openDocument(source, progress: progress) }
        )
    }

    public func shutdown() async throws { try await engine.shutdown() }

    @concurrent
    private func openDocument(_ source: URL, progress: @escaping TraceProgressHandler) async throws -> TraceOpenedDocument {
        let format: RustSourceFormat = source.pathExtension.lowercased() == "systrace" ? .systrace : .htrace
        let session: RustSession
        do { session = try await engine.open(source, format: format, timeoutMilliseconds: openTimeoutMilliseconds, progress: progress) }
        catch { throw Self.mapped(error, stage: .openingDatabase) }
        do {
            let opening = try await session.openingView()
            let repository = try await RustTraceRepository.create(session: session, opening: opening, sourceFormat: format,
                operationTimeoutMilliseconds: queryTimeoutMilliseconds)
            let trace = await opening.metadata.cacheKey.traceSHA256.copyString()
            let parser = await opening.metadata.cacheKey.parserKey.copyString()
            guard let store = TraceViewStateStore(cacheDirectory: configuration.cacheDirectory,
                traceSHA256: trace, parserKey: parser) else { throw RustAdmission.invalidBuffer }
            try Task.checkCancellation()
            return TraceOpenedDocument(repository: repository, cacheHit: opening.cacheHit, cacheMetadata: nil,
                viewStateStore: store, close: { try await repository.close() })
        } catch {
            // Native close preserves cleanup-failure priority over cancellation.
            try await session.close()
            throw Self.mapped(error, stage: .openingDatabase)
        }
    }

    private static func validate(_ product: TraceProductConfiguration, _ runtime: RustConfiguration,
                                 _ openTimeout: UInt32, _ queryTimeout: UInt32) throws {
        guard runtime.configuredNamespace.standardizedFileURL == product.stagingDirectory,
              runtime.configuredCacheDirectory?.standardizedFileURL == product.cacheDirectory,
              runtime.configuredParser.standardizedFileURL == product.bundledParser.executableURL(in: product.bundleURL),
              (1...300_000).contains(openTimeout), (1...300_000).contains(queryTimeout) else {
            throw ArkTraceError(code: .invalidArgument, stage: .preparing,
                message: "Native trace product configuration does not match its fixed profile")
        }
    }

    private static func inventory(_ value: RustCacheInventory) -> TraceCacheInventory {
        TraceCacheInventory(entryCount: value.entryCount, totalByteCount: value.totalByteCount, activeEntryCount: value.activeEntryCount)
    }
    private static func report(_ value: RustCacheMaintenanceReport) -> TraceCacheMaintenanceReport {
        TraceCacheMaintenanceReport(before: inventory(value.before), after: inventory(value.after),
            recoveredPrivateDirectoryCount: value.recoveredPrivateDirectoryCount,
            removedOrphanOwnerMarkerCount: value.removedOrphanOwnerMarkerCount,
            removedEntryCount: value.removedEntryCount, skippedActiveEntryCount: value.skippedActiveEntryCount)
    }
    private static func mapped(_ error: any Error, stage: ArkTraceError.Stage) -> any Error {
        if error is CancellationError || error is ArkTraceError { return error }
        if let admission = error as? RustAdmission {
            let mapped = RustTraceRepository.admissionError(admission)
            return ArkTraceError(code: mapped.code, stage: stage, message: "Native trace operation could not complete", retryable: mapped.retryable)
        }
        return ArkTraceError(code: .internalError, stage: stage, message: "Native trace operation could not complete")
    }
}
#endif
