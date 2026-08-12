import ArkTraceCore
import ArkTraceParser
import ArkTraceStore
import Darwin
import Foundation

/// One loaded trace, shared by App and CLI (DESIGN §10).
///
/// Phase 1 scope: prepare → parse → validate → open, all off the caller's
/// actor; Phase 1 index migration completes before atomic Ready promotion.
/// Content-addressed caching arrives in Phase 2. Cancellation follows structured concurrency: cancelling the
/// calling task terminates the parser process and no partial output is kept.
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

    private init(repository: SQLiteTraceRepository, parsed: ParsedTrace) {
        self.repository = repository
        self.parsed = parsed
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

    /// Internal synchronization hook used by deterministic cancellation tests.
    static func open(
        source: URL,
        parser: some TraceParser,
        stagingDirectory: URL,
        progress: TraceProgressHandler? = nil,
        repositoryValidationHook: (@Sendable () async -> Void)?
    ) async throws -> TraceSession {
        let progressRelay = ProgressRelay(observer: progress)
        let report: TraceProgressHandler = { progressRelay.emit($0) }
        report(.preparing)
        let sessionDirectory: URL
        var createdDirectory: URL?
        do {
            let stagingTask = Task.detached {
                let fm = FileManager.default
                try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
                let directory = stagingDirectory.appendingPathComponent(
                    "session-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: directory, withIntermediateDirectories: false)
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                return directory
            }
            let directory = try await withTaskCancellationHandler {
                try await stagingTask.value
            } onCancel: {
                stagingTask.cancel()
            }
            createdDirectory = directory
            try Task.checkCancellation()
            sessionDirectory = directory
        } catch is CancellationError {
            if let createdDirectory {
                await Task.detached { try? FileManager.default.removeItem(at: createdDirectory) }
                    .value
            }
            report(.cancelled)
            throw Self.cancelled(stage: .preparing)
        } catch let error as ArkTraceError {
            report(error.code == .cancelled ? .cancelled : .failed)
            throw error
        } catch {
            if let createdDirectory {
                await Task.detached { try? FileManager.default.removeItem(at: createdDirectory) }
                    .value
            }
            report(.failed)
            throw ArkTraceError(
                code: .traceParseFailed,
                stage: .preparing,
                message: "Unable to create private session staging",
                retryable: true,
                details: ["reason": "stagingIO"]
            )
        }

        do {
            let databaseURL = sessionDirectory.appendingPathComponent("trace.sqlite")
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
            report(.openingDatabase)
            let repositoryTask = Task.detached {
                let sidecar = try Self.loadAndValidateSidecar(for: parsed)
                let repository = try SQLiteTraceRepository(
                    databaseURL: parsed.databaseURL,
                    parser: parsed.parser,
                    source: sourceDescriptor
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
                return repository
            }
            let repository = try await withTaskCancellationHandler {
                let repository = try await repositoryTask.value
                try Task.checkCancellation()
                return repository
            } onCancel: {
                repositoryTask.cancel()
            }
            try Task.checkCancellation()
            report(.ready)
            return TraceSession(repository: repository, parsed: parsed)
        } catch {
            await Task.detached {
                try? FileManager.default.removeItem(at: sessionDirectory)
            }.value
            if let error = error as? ArkTraceError, error.code == .cancelled {
                report(.cancelled)
                throw error
            }
            if error is CancellationError || Task.isCancelled {
                report(.cancelled)
                throw Self.cancelled(stage: .openingDatabase)
            }
            report(.failed)
            throw error
        }
    }

    private static func loadAndValidateSidecar(
        for parsed: ParsedTrace
    ) throws -> TraceDatabaseMetadataSidecar {
        guard let data = readBoundedRegularFile(
            at: parsed.metadataSidecarURL,
            maximumByteCount: 4_096
        ),
            let sidecar = try? JSONDecoder().decode(
                TraceDatabaseMetadataSidecar.self,
                from: data
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
        return sidecar
    }

    private static func readBoundedRegularFile(
        at url: URL,
        maximumByteCount: Int
    ) -> Data? {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW)
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
        return data
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
