import ArkTraceCore
import ArkTraceParser
import ArkTraceStore
import Darwin
import Foundation

/// One loaded trace, shared by App and CLI (DESIGN §10).
///
/// The session owns either an active content-cache lease or an ephemeral
/// session directory. Cancellation follows structured concurrency: cancelling
/// the calling task terminates the parser and never leaves a public partial
/// cache entry.
public actor TraceSession {
    private final class ProgressRelay: @unchecked Sendable {
        private let lock = NSLock()
        private let observer: TraceProgressHandler?
        private var last: TraceLoadingStage?
        private var terminal = false

        init(observer: TraceProgressHandler?) {
            self.observer = observer
        }

        func emit(_ stage: TraceLoadingStage) {
            lock.lock()
            guard !terminal, last != stage else {
                lock.unlock()
                return
            }
            last = stage
            terminal = stage == .ready || stage == .failed || stage == .cancelled
            let observer = observer
            lock.unlock()
            observer?(stage)
        }
    }

    public let repository: SQLiteTraceRepository
    public let parsed: ParsedTrace
    public let cacheHit: Bool
    public let cacheMetadata: TraceCacheMetadata?
    private let resourceOwner: TraceSessionResourceOwner

    private init(
        repository: SQLiteTraceRepository,
        parsed: ParsedTrace,
        cacheHit: Bool,
        cacheMetadata: TraceCacheMetadata?,
        resourceOwner: TraceSessionResourceOwner
    ) {
        self.repository = repository
        self.parsed = parsed
        self.cacheHit = cacheHit
        self.cacheMetadata = cacheMetadata
        self.resourceOwner = resourceOwner
    }

    /// Releases the active cache lease or removes an ephemeral Ready database.
    /// Calling `close()` more than once is safe.
    public func close() async throws {
        do {
            try await resourceOwner.close()
        } catch {
            throw ArkTraceError(
                code: .traceParseFailed,
                stage: .openingDatabase,
                message: "Trace session storage could not be released",
                retryable: true,
                details: ["reason": "sessionCleanupFailed"]
            )
        }
    }

    /// Creates a unique child beneath `stagingDirectory`, parses into that
    /// session-owned directory, and opens the resulting database. Concurrent
    /// sessions may safely share the same staging root (AT-PARSE-008).
    public static func open(
        source: URL,
        parser: some TraceParser,
        stagingDirectory: URL,
        progress: TraceProgressHandler? = nil
    ) async throws -> TraceSession {
        try await open(
            source: source,
            parser: parser,
            stagingDirectory: stagingDirectory,
            progress: progress,
            repositoryValidationHook: nil
        )
    }

    /// Opens with an explicit storage policy. CLI uses `.contentAddressed` by
    /// default and maps `--no-cache` to `.ephemeral`; the compatibility
    /// overload above remains ephemeral for existing library callers.
    public static func open(
        source: URL,
        parser: some TraceParser,
        stagingDirectory: URL,
        storagePolicy: TraceSessionStoragePolicy,
        progress: TraceProgressHandler? = nil
    ) async throws -> TraceSession {
        switch storagePolicy {
        case .ephemeral:
            return try await open(
                source: source,
                parser: parser,
                stagingDirectory: stagingDirectory,
                progress: progress
            )
        case .contentAddressed(let cacheDirectory):
            return try await openCached(
                source: source,
                parser: parser,
                stagingDirectory: stagingDirectory,
                cacheDirectory: cacheDirectory,
                progress: progress,
                hooks: TraceCacheTestHooks(),
                repositoryValidationHook: nil
            )
        }
    }

    /// Internal seams keep atomic-promotion and cancellation tests
    /// deterministic without expanding the public API.
    static func openCached(
        source: URL,
        parser: some TraceParser,
        stagingDirectory: URL,
        cacheDirectory: URL,
        progress: TraceProgressHandler? = nil,
        hooks: TraceCacheTestHooks = TraceCacheTestHooks(),
        repositoryValidationHook: (@Sendable () async -> Void)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) async throws -> TraceSession {
        let progressRelay = ProgressRelay(observer: progress)
        let report: TraceProgressHandler = { progressRelay.emit($0) }
        do {
            let opened = try await TraceContentAddressedCache.open(
                source: source,
                parser: parser,
                stagingDirectory: stagingDirectory,
                cacheDirectory: cacheDirectory,
                report: report,
                hooks: hooks,
                repositoryValidationHook: repositoryValidationHook,
                now: now
            )
            return TraceSession(
                repository: opened.repository,
                parsed: opened.parsed,
                cacheHit: opened.cacheHit,
                cacheMetadata: opened.metadata,
                resourceOwner: TraceSessionResourceOwner(lease: opened.lease)
            )
        } catch let error as ArkTraceError {
            report(error.code == .cancelled ? .cancelled : .failed)
            throw error
        } catch is CancellationError {
            report(.cancelled)
            throw Self.cancelled(stage: .cacheLookup)
        } catch {
            report(.failed)
            throw ArkTraceError(
                code: .traceCacheCorrupt,
                stage: .cacheLookup,
                message: "Unable to open content-addressed cache",
                retryable: true,
                details: ["reason": "cacheIO"]
            )
        }
    }

    /// Internal synchronization hook used by deterministic cancellation tests.
    static func open(
        source: URL,
        parser: some TraceParser,
        stagingDirectory: URL,
        progress: TraceProgressHandler? = nil,
        repositoryValidationHook: (@Sendable () async -> Void)?,
        directoryRemovalHook: (@Sendable (URL) throws -> Void)? = nil,
        directoryInitialProbeHook: (@Sendable (URL) throws -> Void)? = nil
    ) async throws -> TraceSession {
        let progressRelay = ProgressRelay(observer: progress)
        let report: TraceProgressHandler = { progressRelay.emit($0) }
        report(.preparing)
        var sessionDirectory: TraceOwnedDirectory?
        var cancellationStage: ArkTraceError.Stage = .preparing
        do {
            let directory = try await TraceContentAddressedCache.createOwnedDirectory(
                root: stagingDirectory,
                prefix: "session-"
            )
            sessionDirectory = directory
            try Task.checkCancellation()
            let databaseURL = directory.url.appendingPathComponent("trace.sqlite")
            cancellationStage = .parsing
            let parsed = try await parser.parse(
                source: source,
                destination: databaseURL,
                progress: report,
                prepareDatabase: { databaseURL, progress in
                    try TraceDatabaseStagingPreparer.prepare(
                        databaseURL: databaseURL,
                        progress: progress
                    )
                }
            )
            try Task.checkCancellation()

            let sourceDescriptor = TraceSourceDescriptor(
                traceSHA256: parsed.sourceSHA256,
                sourceByteCount: parsed.sourceByteCount,
                sourceFormat: source.pathExtension.isEmpty ? nil : source.pathExtension
            )
            cancellationStage = .openingDatabase
            report(.openingDatabase)
            let repositoryTask = Task.detached {
                let loadedSidecar = try Self.loadAndValidateSidecar(for: parsed)
                let sidecar = loadedSidecar.sidecar
                let repository = try SQLiteTraceRepository(
                    databaseURL: parsed.databaseURL,
                    parser: parsed.parser,
                    source: sourceDescriptor,
                    expectedPreparation: sidecar.databasePreparation
                )
                let metadata = try await repository.metadata()
                guard metadata.schemaFingerprint == sidecar.databasePreparation.schemaFingerprint
                else {
                    throw ArkTraceError(
                        code: .traceDatabaseInvalid,
                        stage: .openingDatabase,
                        message: "Ready database no longer matches its preparation metadata"
                    )
                }
                if let repositoryValidationHook { await repositoryValidationHook() }
                try Task.checkCancellation()
                return (repository, loadedSidecar.fileIdentity)
            }
            let opened = try await withTaskCancellationHandler {
                let opened = try await repositoryTask.value
                try Task.checkCancellation()
                return opened
            } onCancel: {
                repositoryTask.cancel()
            }
            try Task.checkCancellation()
            guard TraceContentAddressedCache.readyHandoffMatches(
                directory: directory,
                expectedURL: directory.url,
                databaseURL: parsed.databaseURL,
                databaseFileIdentity: opened.0.databaseFileIdentity,
                metadataURL: parsed.metadataSidecarURL,
                metadataFileIdentity: opened.1
            ) else {
                throw ArkTraceError(
                    code: .traceDatabaseInvalid,
                    stage: .openingDatabase,
                    message: "Ready database changed before session handoff"
                )
            }
            report(.ready)
            sessionDirectory = nil
            return TraceSession(
                repository: opened.0,
                parsed: parsed,
                cacheHit: false,
                cacheMetadata: nil,
                resourceOwner: TraceSessionResourceOwner(
                    directoryToRemove: directory,
                    directoryRemovalHook: directoryRemovalHook,
                    directoryInitialProbeHook: directoryInitialProbeHook
                )
            )
        } catch {
            var cleanupFailed = error is TraceStorageTransactionError
            if let sessionDirectory {
                do {
                    try await TraceContentAddressedCache.removeOwnedDirectory(
                        sessionDirectory,
                        removalHook: directoryRemovalHook,
                        initialProbeHook: directoryInitialProbeHook
                    )
                } catch {
                    cleanupFailed = true
                }
            }
            if cleanupFailed {
                report(.failed)
                throw ArkTraceError(
                    code: .traceParseFailed,
                    stage: .openingDatabase,
                    message: "Trace session storage could not be released",
                    retryable: true,
                    details: ["reason": "sessionCleanupFailed"]
                )
            }
            if let error = error as? ArkTraceError, error.code == .cancelled {
                report(.cancelled)
                throw error
            }
            if error is CancellationError || Task.isCancelled {
                report(.cancelled)
                throw Self.cancelled(stage: cancellationStage)
            }
            if let error = error as? ArkTraceError {
                report(.failed)
                throw error
            }
            report(.failed)
            throw ArkTraceError(
                code: .traceParseFailed,
                stage: cancellationStage,
                message: "Unable to open private trace session",
                retryable: true,
                details: ["reason": cancellationStage == .preparing ? "stagingIO" : "sessionIO"]
            )
        }
    }

    private static func loadAndValidateSidecar(
        for parsed: ParsedTrace
    ) throws -> (
        sidecar: TraceDatabaseMetadataSidecar,
        fileIdentity: TraceDatabaseFileIdentity
    ) {
        guard let snapshot = readBoundedRegularFileSnapshot(
            at: parsed.metadataSidecarURL,
            maximumByteCount: 4_096
        ),
            let sidecar = try? JSONDecoder().decode(
                TraceDatabaseMetadataSidecar.self,
                from: snapshot.data
            ),
            sidecar.formatVersion == 1,
            sidecar.parser == parsed.parser,
            sidecar.sourceSHA256 == parsed.sourceSHA256,
            sidecar.sourceByteCount == parsed.sourceByteCount,
            sidecar.databasePreparation == parsed.databasePreparation
        else {
            throw ArkTraceError(
                code: .traceDatabaseInvalid,
                stage: .openingDatabase,
                message: "Ready database metadata sidecar is invalid"
            )
        }
        return (sidecar, snapshot.fileIdentity)
    }

    private static func readBoundedRegularFileSnapshot(
        at url: URL,
        maximumByteCount: Int
    ) -> (data: Data, fileIdentity: TraceDatabaseFileIdentity)? {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
            (info.st_mode & S_IFMT) == S_IFREG,
            info.st_size > 0,
            info.st_size <= maximumByteCount
        else {
            try? handle.close()
            return nil
        }
        let data = try? handle.read(upToCount: maximumByteCount + 1)
        try? handle.close()
        guard let data, !data.isEmpty, data.count <= maximumByteCount else { return nil }
        return (
            data,
            TraceDatabaseFileIdentity(
                device: UInt64(info.st_dev),
                inode: UInt64(info.st_ino)
            )
        )
    }

    private static func cancelled(stage: ArkTraceError.Stage) -> ArkTraceError {
        ArkTraceError(
            code: .cancelled,
            stage: stage,
            message: "Trace session opening was cancelled",
            retryable: true
        )
    }
}
