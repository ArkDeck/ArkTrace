import ArkTraceCore
import CryptoKit
import Darwin
import Foundation
import Synchronization

/// Runs a pinned TraceStreamer executable as a child process (DESIGN §8).
///
/// Invocation is `Process.executableURL + arguments[]`, never a shell
/// (AT-PARSE-003). `-nm` keeps user paths out of the exported database
/// (AT-PARSE-004). Cancellation terminates the child process and never
/// promotes partial output (AT-PARSE-009).
package struct TraceStreamerProcessParser: TraceParser {
    public static let expectedName = "trace_streamer"
    public static let expectedUpstreamRepository =
        "https://gitcode.com/openharmony/developtools_smartperf_host.git"
    public static let expectedUpstreamRevision =
        "447a0a49a7b3b914d6e9bd00648ba5a340f6fbf6"
    public static let expectedArchitecture = "arm64"
    public static let adapterVersion = "1"
    public static let supportedBuildRecipeVersion =
        "a2e47752e1353d627b442e607eed513564aa66a94c54f2660042383a0f6f3b20"

    private let configuredExecutableURL: URL
    private let configuredManifestURL: URL?
    private let identitySnapshotParentDirectory: URL?
    private let identityVerificationHook: (@Sendable () -> Void)?
    private let identityCleanupHook: (@Sendable () -> Void)?
    private let preparationChunkHook: (@Sendable () -> Void)?
    private let parseCleanupHook: (@Sendable () -> Void)?
    private let parseFinalBoundaryHook: (@Sendable () -> Void)?
    private let cleanupRemovalHook: (@Sendable (URL) throws -> Void)?
    private let ownedIdentityProbeHook: (@Sendable (URL) throws -> Void)?
    private let ownedRemovalHook: (@Sendable (URL) throws -> Void)?
    private let finalizationHook: (@Sendable () -> Void)?
    private let processDidLaunchHook: (@Sendable (pid_t) -> Void)?

    /// Construction records configuration only. All filesystem access,
    /// manifest decoding, hashing, and Mach-O inspection happens from the
    /// async methods so a resolver can be used safely by MainActor code.
    public init(executableURL: URL, manifestURL: URL? = nil) throws {
        try self.init(
            executableURL: executableURL,
            manifestURL: manifestURL,
            identitySnapshotParentDirectory: nil,
            identityVerificationHook: nil,
            identityCleanupHook: nil,
            preparationChunkHook: nil,
            parseCleanupHook: nil,
            parseFinalBoundaryHook: nil,
            cleanupRemovalHook: nil,
            ownedIdentityProbeHook: nil,
            ownedRemovalHook: nil,
            finalizationHook: nil,
            processDidLaunchHook: nil
        )
    }

    /// Internal synchronization hook used by deterministic cancellation tests.
    init(
        executableURL: URL,
        manifestURL: URL? = nil,
        identitySnapshotParentDirectory: URL? = nil,
        identityVerificationHook: (@Sendable () -> Void)? = nil,
        identityCleanupHook: (@Sendable () -> Void)? = nil,
        preparationChunkHook: (@Sendable () -> Void)? = nil,
        parseCleanupHook: (@Sendable () -> Void)? = nil,
        parseFinalBoundaryHook: (@Sendable () -> Void)? = nil,
        cleanupRemovalHook: (@Sendable (URL) throws -> Void)? = nil,
        ownedIdentityProbeHook: (@Sendable (URL) throws -> Void)? = nil,
        ownedRemovalHook: (@Sendable (URL) throws -> Void)? = nil,
        finalizationHook: (@Sendable () -> Void)?,
        processDidLaunchHook: (@Sendable (pid_t) -> Void)? = nil
    ) throws {
        guard executableURL.isFileURL,
            manifestURL?.isFileURL != false,
            identitySnapshotParentDirectory?.isFileURL != false
        else {
            throw Self.unavailable(reason: "invalidURL")
        }
        self.configuredExecutableURL = executableURL.standardizedFileURL
        self.configuredManifestURL = manifestURL?.standardizedFileURL
        self.identitySnapshotParentDirectory = identitySnapshotParentDirectory?.standardizedFileURL
        self.identityVerificationHook = identityVerificationHook
        self.identityCleanupHook = identityCleanupHook
        self.preparationChunkHook = preparationChunkHook
        self.parseCleanupHook = parseCleanupHook
        self.parseFinalBoundaryHook = parseFinalBoundaryHook
        self.cleanupRemovalHook = cleanupRemovalHook
        self.ownedIdentityProbeHook = ownedIdentityProbeHook
        self.ownedRemovalHook = ownedRemovalHook
        self.finalizationHook = finalizationHook
        self.processDidLaunchHook = processDidLaunchHook
    }

    public func identity() async throws -> TraceParserIdentity {
        try await verifiedIdentity(launchesVersionProbe: true)
    }

    /// Cache lookup verifies the exact binary snapshot, manifest SHA and
    /// Mach-O identity but does not execute `trace_streamer --version`. A miss
    /// still runs the full parse path, which re-verifies the reported version
    /// before producing a Ready database.
    public func cacheIdentity() async throws -> TraceParserIdentity {
        try await verifiedIdentity(launchesVersionProbe: false)
    }

    private func verifiedIdentity(
        launchesVersionProbe: Bool
    ) async throws -> TraceParserIdentity {
        let configuredExecutableURL = configuredExecutableURL
        let configuredManifestURL = configuredManifestURL
        let snapshotParentDirectory = identitySnapshotParentDirectory
            ?? FileManager.default.temporaryDirectory
        let identityVerificationHook = identityVerificationHook
        let identityCleanupHook = identityCleanupHook
        let cleanupRemovalHook = cleanupRemovalHook
        let snapshotTask = Task.detached {
            try Self.makeParserSnapshot(
                configuredExecutableURL: configuredExecutableURL,
                configuredManifestURL: configuredManifestURL,
                parentDirectory: snapshotParentDirectory,
                cleanupRemovalHook: cleanupRemovalHook
            )
        }
        let snapshot: ParserSnapshot
        do {
            snapshot = try await withTaskCancellationHandler {
                try await snapshotTask.value
            } onCancel: {
                snapshotTask.cancel()
            }
        } catch {
            if Self.isCleanupFailure(error) { throw error }
            if error is CancellationError || Task.isCancelled {
                throw Self.cancelled(stage: .preparing)
            }
            throw error
        }
        let result: Result<TraceParserIdentity, Error>
        do {
            let version: String
            if launchesVersionProbe {
                version = try await Self.reportedVersionOffCallerExecutor(
                    executableURL: snapshot.executableURL)
                try Self.validateReportedVersion(version, manifest: snapshot.manifest)
            } else {
                version = snapshot.manifest.reportedVersion
            }
            let verificationTask = Task.detached { try Self.verify(snapshot: snapshot) }
            try await withTaskCancellationHandler {
                try await verificationTask.value
            } onCancel: {
                verificationTask.cancel()
            }
            identityVerificationHook?()
            try Task.checkCancellation()
            result = .success(Self.identity(manifest: snapshot.manifest, reportedVersion: version))
        } catch {
            result = .failure(error)
        }
        do {
            try await Self.removeOffCallerExecutor(
                [snapshot.directory],
                removalHook: cleanupRemovalHook,
                completionHook: identityCleanupHook
            )
        } catch {
            throw Self.cleanupFailure(stage: .preparing, reason: "identityCleanupFailed")
        }
        do {
            try Task.checkCancellation()
            return try result.get()
        } catch {
            if Self.isCleanupFailure(error) { throw error }
            if error is CancellationError || Task.isCancelled {
                throw Self.cancelled(stage: .preparing)
            }
            throw error
        }
    }

    public func parse(
        source: URL,
        sourceIsImmutableSnapshot: Bool = false,
        destination: URL,
        progress: TraceProgressHandler?,
        prepareDatabase: @escaping TraceDatabasePreparer
    ) async throws -> ParsedTrace {
        try await parseImplementation(
            source: source,
            sourceIsImmutableSnapshot: sourceIsImmutableSnapshot,
            verifiedSource: nil,
            destination: destination,
            progress: progress,
            prepareDatabase: prepareDatabase
        )
    }

    package func parseVerifiedSnapshot(
        source: URL,
        sourceSHA256: String,
        sourceByteCount: Int64,
        destination: URL,
        progress: TraceProgressHandler?,
        prepareDatabase: @escaping TraceDatabasePreparer
    ) async throws -> ParsedTrace {
        guard sourceSHA256.count == 64,
            sourceSHA256.utf8.allSatisfy({
                ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                    || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f"))
            }),
            sourceByteCount >= 0
        else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .preparing,
                message: "Verified trace snapshot identity is invalid"
            )
        }
        return try await parseImplementation(
            source: source,
            sourceIsImmutableSnapshot: true,
            verifiedSource: (sourceSHA256, sourceByteCount),
            destination: destination,
            progress: progress,
            prepareDatabase: prepareDatabase
        )
    }

    private func parseImplementation(
        source: URL,
        sourceIsImmutableSnapshot: Bool,
        verifiedSource: (sha256: String, byteCount: Int64)?,
        destination: URL,
        progress: TraceProgressHandler?,
        prepareDatabase: @escaping TraceDatabasePreparer
    ) async throws -> ParsedTrace {
        progress?(.preparing)
        let configuredExecutableURL = configuredExecutableURL
        let configuredManifestURL = configuredManifestURL
        let preparationChunkHook = preparationChunkHook
        let parseCleanupHook = parseCleanupHook
        let parseFinalBoundaryHook = parseFinalBoundaryHook
        let cleanupRemovalHook = cleanupRemovalHook
        let ownedIdentityProbeHook = ownedIdentityProbeHook
        let ownedRemovalHook = ownedRemovalHook
        let processDidLaunchHook = processDidLaunchHook
        progress?(.hashing)
        let preparationTask = Task.detached {
            try Self.prepareParse(
                source: source,
                sourceIsImmutableSnapshot: sourceIsImmutableSnapshot,
                verifiedSource: verifiedSource,
                destination: destination,
                configuredExecutableURL: configuredExecutableURL,
                configuredManifestURL: configuredManifestURL,
                preparationChunkHook: preparationChunkHook,
                cleanupRemovalHook: cleanupRemovalHook
            )
        }
        let prepared: PreparedParse
        do {
            prepared = try await withTaskCancellationHandler {
                try await preparationTask.value
            } onCancel: {
                preparationTask.cancel()
            }
        } catch {
            if Self.isCleanupFailure(error) { throw error }
            if error is CancellationError || Task.isCancelled {
                throw Self.cancelled(stage: .preparing)
            }
            throw error
        }
        let result: Result<ExecutedParse, Error>
        do {
            result = .success(
                try await Self.execute(
                    prepared: prepared,
                    finalizationHook: finalizationHook,
                    ownedIdentityProbeHook: ownedIdentityProbeHook,
                    ownedRemovalHook: ownedRemovalHook,
                    processDidLaunchHook: processDidLaunchHook,
                    progress: progress,
                    prepareDatabase: prepareDatabase
                )
            )
        } catch {
            result = .failure(error)
        }
        let cleanupError: Error?
        do {
            try await Self.removeOffCallerExecutor(
                [prepared.workDirectory, prepared.destinationClaimURL],
                removalHook: cleanupRemovalHook,
                completionHook: parseCleanupHook
            )
            cleanupError = nil
        } catch {
            cleanupError = error
        }

        let executed = try? result.get()
        if cleanupError != nil, let executed {
            do {
                try await Self.removeOwnedFilesOffCallerExecutor(
                    executed.ownedReadyFiles,
                    identityProbeHook: ownedIdentityProbeHook,
                    preRemovalHook: ownedRemovalHook
                )
            } catch {
                throw Self.cleanupFailure(stage: .parsing, reason: "readyRollbackFailed")
            }
        }
        if cleanupError != nil {
            throw Self.cleanupFailure(stage: .parsing, reason: "stagingCleanupFailed")
        }
        do {
            parseFinalBoundaryHook?()
            try Task.checkCancellation()
            return try result.get().parsed
        } catch {
            if Self.isCleanupFailure(error) { throw error }
            if error is CancellationError || Task.isCancelled {
                if let executed {
                    do {
                        try await Self.removeOwnedFilesOffCallerExecutor(
                            executed.ownedReadyFiles,
                            identityProbeHook: ownedIdentityProbeHook,
                            preRemovalHook: ownedRemovalHook
                        )
                    } catch {
                        throw Self.cleanupFailure(
                            stage: .parsing,
                            reason: "readyRollbackFailed"
                        )
                    }
                }
                throw Self.cancelled(stage: .parsing)
            }
            throw error
        }
    }

    private static func execute(
        prepared: PreparedParse,
        finalizationHook: (@Sendable () -> Void)?,
        ownedIdentityProbeHook: (@Sendable (URL) throws -> Void)?,
        ownedRemovalHook: (@Sendable (URL) throws -> Void)?,
        processDidLaunchHook: (@Sendable (pid_t) -> Void)?,
        progress: TraceProgressHandler?,
        prepareDatabase: @escaping TraceDatabasePreparer
    ) async throws -> ExecutedParse {
        let version = try await Self.reportedVersionOffCallerExecutor(
            executableURL: prepared.parserSnapshot.executableURL)
        try Self.validateReportedVersion(version, manifest: prepared.parserSnapshot.manifest)
        let parserIdentity = Self.identity(
            manifest: prepared.parserSnapshot.manifest,
            reportedVersion: version
        )

        progress?(.parsing)
        // The child says how far through the source it is; the source's size
        // is already known, so the parse -- the longest single stage of a cold
        // open -- reports a real fraction instead of a spinner. The scanner is
        // fed from the pipe's callback queue, so it lives behind a lock.
        let scanner = Mutex(TraceStreamerProgressScanner())
        let sourceByteCount = prepared.sourceByteCount
        var stdoutObserver: (@Sendable (Data) -> Void)?
        if let progress {
            stdoutObserver = { (chunk: Data) in
                let text = String(decoding: chunk, as: UTF8.self)
                guard let bytes = scanner.withLock({ scanner in
                    scanner.consume(text)
                }) else { return }
                progress(
                    TraceLoadingProgress(
                        stage: .parsing,
                        completed: bytes,
                        total: sourceByteCount
                    )
                )
            }
        }
        let outcome = try await Self.runOffCallerExecutor(
            executable: prepared.parserSnapshot.executableURL,
            arguments: Self.invocationArguments(
                source: prepared.sourceSnapshotURL,
                output: prepared.outputURL
            ),
            processDidLaunchHook: processDidLaunchHook,
            stdoutObserver: stdoutObserver
        )
        try Self.validateProcessOutcome(outcome, outputURL: prepared.outputURL)

        let finalized = try await Self.finalizeAndPromote(
            prepared: prepared,
            parserIdentity: parserIdentity,
            finalizationHook: finalizationHook,
            ownedIdentityProbeHook: ownedIdentityProbeHook,
            ownedRemovalHook: ownedRemovalHook,
            progress: progress,
            prepareDatabase: prepareDatabase
        )

        return ExecutedParse(
            parsed: ParsedTrace(
                databaseURL: prepared.destinationURL,
                metadataSidecarURL: prepared.destinationMetadataURL,
                parser: parserIdentity,
                sourceSHA256: prepared.sourceSHA256,
                sourceByteCount: prepared.sourceByteCount,
                databasePreparation: finalized.preparation
            ),
            ownedReadyFiles: finalized.ownedReadyFiles
        )
    }

    static func validateProcessOutcome(_ outcome: Outcome, outputURL: URL) throws {
        let statusDiagnostic = Self.boundedFileDiagnostic(
            at: URL(filePath: outputURL.path + ".ohos.ts")
        )
        if outcome.cancelled {
            throw ArkTraceError(
                code: .cancelled,
                stage: .parsing,
                message: "Trace parsing was cancelled",
                retryable: true,
                details: outcome.escalatedToSIGKILL
                    ? ["termination": "sigkillAfterGrace"]
                    : ["termination": "sigterm"]
            )
        }
        guard outcome.exitStatus == 0 else {
            throw ArkTraceError(
                code: .traceParseFailed,
                stage: .parsing,
                message: "trace_streamer exited with a failure status",
                details: Self.diagnosticDetails(
                    outcome: outcome,
                    status: statusDiagnostic,
                    exitStatus: outcome.exitStatus
                )
            )
        }
        guard Self.isRegularNonSymlinkFile(at: outputURL),
            Self.hasSQLiteHeader(at: outputURL)
        else {
            throw ArkTraceError(
                code: .traceParseFailed,
                stage: .parsing,
                message: "trace_streamer exited 0 but produced no valid SQLite database",
                details: Self.diagnosticDetails(
                    outcome: outcome,
                    status: statusDiagnostic,
                    exitStatus: outcome.exitStatus
                )
            )
        }
    }

    static func invocationArguments(source: URL, output: URL) -> [String] {
        [source.path, "-e", output.path, "-nm"]
    }

    // MARK: - Immutable input preparation

    private struct ParserSnapshot: Sendable {
        let directory: URL
        let executableURL: URL
        let manifest: TraceStreamerManifest
    }

    private struct PreparedParse: Sendable {
        let destinationURL: URL
        let destinationMetadataURL: URL
        let destinationClaimURL: URL
        let workDirectory: URL
        let outputURL: URL
        let outputMetadataURL: URL
        let sourceSnapshotURL: URL
        let sourceSHA256: String
        let sourceByteCount: Int64
        let verifiedSourceFileSnapshot: SourceFileSnapshot?
        let parserSnapshot: ParserSnapshot
    }

    private struct ExecutedParse: Sendable {
        let parsed: ParsedTrace
        let ownedReadyFiles: [OwnedFile]
    }

    private struct FinalizedDatabase: Sendable {
        let preparation: TraceDatabasePreparationResult
        let ownedReadyFiles: [OwnedFile]
    }

    /// Serializes cancellation against the single atomic promotion. If
    /// cancellation wins, promotion cannot start. If rename wins, a later
    /// cancellation barrier can identify and remove only this owned output.
    private final class PromotionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var promotedFiles: [OwnedFile] = []

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        func promote(_ operation: () throws -> [OwnedFile]) throws {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { throw CancellationError() }
            promotedFiles = try operation()
        }

        var ownedPromotedFiles: [OwnedFile] {
            lock.lock()
            defer { lock.unlock() }
            return promotedFiles
        }
    }

    private struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    private struct SourceFileSnapshot: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let byteCount: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let statusChangeSeconds: Int64
        let statusChangeNanoseconds: Int64
    }

    private enum FileIdentityProbe: Sendable {
        case regular(FileIdentity)
        case nonRegular
        case absent
        case inaccessible
    }

    private enum PathEntryStatus: Equatable {
        case absent
        case present
        case inaccessible
    }

    private struct OwnedFile: Sendable {
        let url: URL
        let identity: FileIdentity
    }

    private static func finalizeAndPromote(
        prepared: PreparedParse,
        parserIdentity: TraceParserIdentity,
        finalizationHook: (@Sendable () -> Void)?,
        ownedIdentityProbeHook: (@Sendable (URL) throws -> Void)?,
        ownedRemovalHook: (@Sendable (URL) throws -> Void)?,
        progress: TraceProgressHandler?,
        prepareDatabase: @escaping TraceDatabasePreparer
    ) async throws -> FinalizedDatabase {
        let gate = PromotionGate()
        let task = Task.detached {
            try Task.checkCancellation()
            let databasePreparation = try await prepareDatabase(prepared.outputURL, progress)
            try Self.validate(databasePreparation: databasePreparation)
            try Task.checkCancellation()
            try Self.verify(snapshot: prepared.parserSnapshot)
            try Task.checkCancellation()

            if let expected = prepared.verifiedSourceFileSnapshot {
                guard try Self.sourceFileSnapshot(at: prepared.sourceSnapshotURL)
                    == expected
                else { throw Self.sourceChanged() }
            } else {
                let sourceAfterParse: (sha256: String, byteCount: Int64)
                do {
                    sourceAfterParse = try Self.sha256AndSize(
                        at: prepared.sourceSnapshotURL
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as ArkTraceError {
                    throw error
                } catch {
                    throw Self.snapshotIOFailure(reason: "verifySourceSnapshot")
                }
                guard sourceAfterParse.sha256 == prepared.sourceSHA256,
                    sourceAfterParse.byteCount == prepared.sourceByteCount
                else {
                    throw Self.sourceChanged()
                }
            }
            finalizationHook?()
            try Task.checkCancellation()

            try Self.writeMetadataSidecar(
                at: prepared.outputMetadataURL,
                parser: parserIdentity,
                sourceSHA256: prepared.sourceSHA256,
                sourceByteCount: prepared.sourceByteCount,
                databasePreparation: databasePreparation
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o400],
                ofItemAtPath: prepared.outputURL.path
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o400],
                ofItemAtPath: prepared.outputMetadataURL.path
            )
            try Self.synchronizeFile(at: prepared.outputURL)
            try Self.synchronizeFile(at: prepared.outputMetadataURL)
            try Self.synchronizeDirectory(at: prepared.workDirectory)
            try Task.checkCancellation()

            try gate.promote {
                guard !Self.pathEntryExists(prepared.destinationURL),
                    !Self.pathEntryExists(prepared.destinationMetadataURL)
                else {
                    throw Self.destinationUnavailable(reason: "occupied")
                }
                var owned: [OwnedFile] = []
                do {
                    let metadataIdentity = try Self.ownedFile(
                        at: prepared.outputMetadataURL
                    ).identity
                    let databaseIdentity = try Self.ownedFile(
                        at: prepared.outputURL
                    ).identity
                    try FileManager.default.moveItem(
                        at: prepared.outputMetadataURL,
                        to: prepared.destinationMetadataURL
                    )
                    owned.append(
                        OwnedFile(
                            url: prepared.destinationMetadataURL,
                            identity: metadataIdentity
                        )
                    )
                    try FileManager.default.moveItem(
                        at: prepared.outputURL,
                        to: prepared.destinationURL
                    )
                    owned.append(
                        OwnedFile(url: prepared.destinationURL, identity: databaseIdentity)
                    )
                    try Self.synchronizeDirectory(
                        at: prepared.destinationURL.deletingLastPathComponent()
                    )
                    return owned
                } catch {
                    do {
                        try Self.removeOwnedFiles(
                            owned,
                            identityProbeHook: ownedIdentityProbeHook,
                            preRemovalHook: ownedRemovalHook
                        )
                    } catch {
                        throw Self.cleanupFailure(
                            stage: .parsing,
                            reason: "readyRollbackFailed"
                        )
                    }
                    throw Self.destinationUnavailable(reason: "promotionFailed")
                }
            }
            return databasePreparation
        }

        do {
            return try await withTaskCancellationHandler {
                let databasePreparation = try await task.value
                try Task.checkCancellation()
                return FinalizedDatabase(
                    preparation: databasePreparation,
                    ownedReadyFiles: gate.ownedPromotedFiles
                )
            } onCancel: {
                gate.cancel()
                task.cancel()
            }
        } catch {
            let promotedFiles = gate.ownedPromotedFiles
            if !promotedFiles.isEmpty {
                do {
                    try await removeOwnedFilesOffCallerExecutor(
                        promotedFiles,
                        identityProbeHook: ownedIdentityProbeHook,
                        preRemovalHook: ownedRemovalHook
                    )
                } catch {
                    throw cleanupFailure(stage: .parsing, reason: "readyRollbackFailed")
                }
            }
            if isCleanupFailure(error) { throw error }
            if error is CancellationError || Task.isCancelled {
                throw cancelled(stage: .parsing)
            }
            throw error
        }
    }

    private static func prepareParse(
        source: URL,
        sourceIsImmutableSnapshot: Bool,
        verifiedSource: (sha256: String, byteCount: Int64)?,
        destination: URL,
        configuredExecutableURL: URL,
        configuredManifestURL: URL?,
        preparationChunkHook: (@Sendable () -> Void)?,
        cleanupRemovalHook: (@Sendable (URL) throws -> Void)?
    ) throws -> PreparedParse {
        do {
            return try prepareParseUnchecked(
                source: source,
                sourceIsImmutableSnapshot: sourceIsImmutableSnapshot,
                verifiedSource: verifiedSource,
                destination: destination,
                configuredExecutableURL: configuredExecutableURL,
                configuredManifestURL: configuredManifestURL,
                preparationChunkHook: preparationChunkHook,
                cleanupRemovalHook: cleanupRemovalHook
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ArkTraceError {
            throw error
        } catch {
            throw snapshotIOFailure(reason: "prepareStaging")
        }
    }

    private static func prepareParseUnchecked(
        source: URL,
        sourceIsImmutableSnapshot: Bool,
        verifiedSource: (sha256: String, byteCount: Int64)?,
        destination: URL,
        configuredExecutableURL: URL,
        configuredManifestURL: URL?,
        preparationChunkHook: (@Sendable () -> Void)?,
        cleanupRemovalHook: (@Sendable (URL) throws -> Void)?
    ) throws -> PreparedParse {
        try Task.checkCancellation()
        guard source.isFileURL, destination.isFileURL else {
            throw destinationUnavailable(reason: "invalidURL")
        }
        let fm = FileManager.default
        // Input symlinks are allowed for developer ergonomics, but are
        // resolved exactly once to a regular readable target. Only the private
        // copy made from that canonical target is hashed and parsed. Output
        // files and Ready databases reject symlinks unconditionally.
        let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL
        let sourceAttributes = try? fm.attributesOfItem(atPath: canonicalSource.path)
        guard sourceAttributes?[.type] as? FileAttributeType == .typeRegular else {
            throw ArkTraceError(
                code: .traceFileNotFound,
                stage: .preparing,
                message: "Trace file does not exist or is not a regular file"
            )
        }
        guard fm.isReadableFile(atPath: canonicalSource.path) else {
            throw ArkTraceError(
                code: .traceFileUnreadable,
                stage: .preparing,
                message: "Trace file is not readable"
            )
        }

        let destinationName = destination.lastPathComponent
        guard !destinationName.isEmpty, destinationName != ".", destinationName != ".." else {
            throw destinationUnavailable(reason: "invalidName")
        }
        let destinationParent = destination.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
        let parentAttributes = try? fm.attributesOfItem(atPath: destinationParent.path)
        guard parentAttributes?[.type] as? FileAttributeType == .typeDirectory else {
            throw destinationUnavailable(reason: "parentUnavailable")
        }
        let canonicalDestination = destinationParent.appending(path: destinationName)
        let destinationMetadata = URL(filePath: canonicalDestination.path + ".arktrace.json")
        guard canonicalDestination != canonicalSource else {
            throw destinationUnavailable(reason: "sameAsSource")
        }
        guard !pathEntryExists(canonicalDestination), !pathEntryExists(destinationMetadata) else {
            throw destinationUnavailable(reason: "alreadyExists")
        }

        let claimURL = destinationParent.appending(path: ".\(destinationName).arktrace-claim", directoryHint: .notDirectory)
        var createdClaim = false
        do {
            try Data().write(to: claimURL, options: .withoutOverwriting)
            createdClaim = true
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: claimURL.path)
            try Task.checkCancellation()
        } catch {
            if createdClaim {
                do {
                    try removeStagingItems(
                        [claimURL],
                        removalHook: cleanupRemovalHook
                    )
                } catch {
                    throw cleanupFailure(stage: .preparing, reason: "stagingCleanupFailed")
                }
            }
            if error is CancellationError { throw error }
            throw destinationUnavailable(reason: "inUse")
        }

        var workDirectory: URL?
        do {
            guard !pathEntryExists(canonicalDestination) else {
                throw destinationUnavailable(reason: "alreadyExists")
            }
            let directory = destinationParent.appending(path: ".arktrace-parser-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            workDirectory = directory
            try Task.checkCancellation()

            let parserSnapshot = try makeParserSnapshot(
                configuredExecutableURL: configuredExecutableURL,
                configuredManifestURL: configuredManifestURL,
                parentDirectory: directory,
                useParentDirectory: true,
                cleanupRemovalHook: cleanupRemovalHook
            )
            // A caller that already materialised an immutable snapshot (the
            // content-addressed cache does, pinned to the hash it keyed on)
            // gets parsed from those exact bytes. Copying them a second time
            // doubled both the peak staging footprint and the bytes moved for
            // every cache miss, on traces that reach hundreds of megabytes.
            let sourceSnapshotURL: URL
            if sourceIsImmutableSnapshot {
                sourceSnapshotURL = canonicalSource
            } else {
                sourceSnapshotURL = directory.appending(path: "source.trace")
                try copyRegularFileCancellable(
                    from: canonicalSource,
                    to: sourceSnapshotURL,
                    permissions: 0o400,
                    chunkHook: preparationChunkHook,
                    cleanupRemovalHook: cleanupRemovalHook
                )
            }
            guard isRegularNonSymlinkFile(at: sourceSnapshotURL) else {
                throw ArkTraceError(
                    code: .traceFileUnreadable,
                    stage: .preparing,
                    message: "Trace snapshot is not a regular file"
                )
            }
            let verifiedSourceFileSnapshot: SourceFileSnapshot?
            let sourceIdentity: (sha256: String, byteCount: Int64)
            if let verifiedSource {
                guard sourceIsImmutableSnapshot else {
                    throw destinationUnavailable(reason: "unverifiedSource")
                }
                let snapshot = try sourceFileSnapshot(at: sourceSnapshotURL)
                guard snapshot.byteCount == verifiedSource.byteCount else {
                    throw sourceChanged()
                }
                verifiedSourceFileSnapshot = snapshot
                sourceIdentity = verifiedSource
            } else {
                verifiedSourceFileSnapshot = nil
                sourceIdentity = try sha256AndSize(at: sourceSnapshotURL)
            }
            return PreparedParse(
                destinationURL: canonicalDestination,
                destinationMetadataURL: destinationMetadata,
                destinationClaimURL: claimURL,
                workDirectory: directory,
                outputURL: directory.appending(path: "output.partial.sqlite"),
                outputMetadataURL: directory.appending(path: "output.partial.sqlite.arktrace.json"),
                sourceSnapshotURL: sourceSnapshotURL,
                sourceSHA256: sourceIdentity.sha256,
                sourceByteCount: sourceIdentity.byteCount,
                verifiedSourceFileSnapshot: verifiedSourceFileSnapshot,
                parserSnapshot: parserSnapshot
            )
        } catch {
            do {
                try removeStagingItems(
                    [workDirectory, claimURL].compactMap { $0 },
                    removalHook: cleanupRemovalHook
                )
            } catch {
                throw cleanupFailure(stage: .preparing, reason: "stagingCleanupFailed")
            }
            throw error
        }
    }

    private static func makeParserSnapshot(
        configuredExecutableURL: URL,
        configuredManifestURL: URL?,
        parentDirectory: URL,
        useParentDirectory: Bool = false,
        cleanupRemovalHook: (@Sendable (URL) throws -> Void)?
    ) throws -> ParserSnapshot {
        do {
            return try makeParserSnapshotUnchecked(
                configuredExecutableURL: configuredExecutableURL,
                configuredManifestURL: configuredManifestURL,
                parentDirectory: parentDirectory,
                useParentDirectory: useParentDirectory,
                cleanupRemovalHook: cleanupRemovalHook
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ArkTraceError {
            throw error
        } catch {
            throw unavailable(reason: "snapshotIO")
        }
    }

    private static func makeParserSnapshotUnchecked(
        configuredExecutableURL: URL,
        configuredManifestURL: URL?,
        parentDirectory: URL,
        useParentDirectory: Bool,
        cleanupRemovalHook: (@Sendable (URL) throws -> Void)?
    ) throws -> ParserSnapshot {
        try Task.checkCancellation()
        let fm = FileManager.default
        let canonicalExecutable = configuredExecutableURL
            .resolvingSymlinksInPath().standardizedFileURL
        let attributes = try? fm.attributesOfItem(atPath: canonicalExecutable.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular else {
            throw unavailable(reason: "notRegular")
        }
        guard fm.isExecutableFile(atPath: canonicalExecutable.path) else {
            throw unavailable(reason: "notExecutable")
        }
        let manifestURL = (configuredManifestURL
            ?? canonicalExecutable.deletingLastPathComponent()
                .appending(path: "manifest.json"))
            .resolvingSymlinksInPath().standardizedFileURL
        let manifest = try TraceStreamerManifest.load(from: manifestURL)

        let directory: URL
        if useParentDirectory {
            directory = parentDirectory
        } else {
            directory = parentDirectory.appending(path: ".arktrace-identity-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        }

        do {
            let executableSnapshot = directory.appending(path: "trace_streamer")
            try copyRegularFileCancellable(
                from: canonicalExecutable,
                to: executableSnapshot,
                permissions: 0o500,
                cleanupRemovalHook: cleanupRemovalHook
            )
            try validate(manifest: manifest, executableURL: executableSnapshot)
            return ParserSnapshot(
                directory: directory,
                executableURL: executableSnapshot,
                manifest: manifest
            )
        } catch {
            if !useParentDirectory {
                do {
                    try removeStagingItems(
                        [directory],
                        removalHook: cleanupRemovalHook
                    )
                } catch {
                    throw cleanupFailure(stage: .preparing, reason: "identityCleanupFailed")
                }
            }
            throw error
        }
    }

    // MARK: - Process execution

    struct BoundedDiagnostic: Sendable {
        let data: Data
        let observedByteCount: Int
        let truncated: Bool
    }

    struct Outcome: Sendable {
        let exitStatus: Int32
        let cancelled: Bool
        let escalatedToSIGKILL: Bool
        let stdout: BoundedDiagnostic
        let stderr: BoundedDiagnostic
    }

    private final class ProcessBox: @unchecked Sendable {
        private enum State {
            case notStarted
            case running(pid_t)
            case terminating(pid_t)
            case killing(pid_t)
            case exited
        }

        private let lock = NSLock()
        private let process: Process
        private let terminationGracePeriod: TimeInterval
        private var cancellationRequested = false
        private var escalatedToSIGKILL = false
        private var state: State = .notStarted
        private var escalationWorkItem: DispatchWorkItem?

        init(_ process: Process, terminationGracePeriod: TimeInterval) {
            self.process = process
            self.terminationGracePeriod = max(0, terminationGracePeriod)
        }

        func runIfNotCancelled() throws {
            lock.lock()
            defer { lock.unlock() }
            guard !cancellationRequested else { throw CancellationError() }
            try process.run()
            state = .running(process.processIdentifier)
        }

        func cancel() {
            lock.lock()
            cancellationRequested = true
            guard case .running(let pid) = state, process.isRunning else {
                lock.unlock()
                return
            }
            state = .terminating(pid)
            process.terminate()

            let workItem = DispatchWorkItem { [weak self] in
                self?.escalateIfStillRunning(pid: pid)
            }
            escalationWorkItem = workItem
            lock.unlock()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + terminationGracePeriod,
                execute: workItem
            )
        }

        func waitUntilExit() -> Int32 {
            process.waitUntilExit()
            lock.lock()
            state = .exited
            escalationWorkItem?.cancel()
            escalationWorkItem = nil
            let status = process.terminationStatus
            lock.unlock()
            return status
        }

        var wasCancellationRequested: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancellationRequested
        }

        var didEscalateToSIGKILL: Bool {
            lock.lock()
            defer { lock.unlock() }
            return escalatedToSIGKILL
        }

        private func escalateIfStillRunning(pid: pid_t) {
            lock.lock()
            defer { lock.unlock() }
            guard case .terminating(let expectedPID) = state,
                expectedPID == pid,
                process.processIdentifier == pid,
                process.isRunning
            else {
                return
            }
            state = .killing(pid)
            if Darwin.kill(pid, SIGKILL) == 0 {
                escalatedToSIGKILL = true
            }
        }
    }

    /// Bounded sink so a chatty parser can neither block on a full pipe nor
    /// grow memory without limit.
    final class BoundedPipeSink: @unchecked Sendable {
        private let condition = NSCondition()
        private var buffer = Data()
        private let capacity: Int
        private var observedByteCount = 0
        private var truncated = false
        private var acceptsReadabilityCallbacks = true
        private var activeReadabilityCallbacks = 0
        let pipe = Pipe()

        /// Called with every chunk as it arrives, for a caller that wants to
        /// read the stream live rather than only its bounded tail.
        private let observer: (@Sendable (Data) -> Void)?

        init(capacity: Int = 65_536, observer: (@Sendable (Data) -> Void)? = nil) {
            self.capacity = capacity
            self.observer = observer
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                self?.consumeAvailableData(from: handle)
            }
        }

        func finish() {
            stopReadabilityHandler(waitForActiveCallback: false)
        }

        /// Stops the asynchronous reader, waits for any in-flight callback,
        /// then synchronously reads through EOF. Process termination and pipe
        /// delivery happen on different queues, so this barrier preserves a
        /// trailing version line that had not reached the handler yet.
        func finishAndDrainToEOF() -> BoundedDiagnostic {
            let handle = pipe.fileHandleForReading
            stopReadabilityHandler(waitForActiveCallback: true)
            while true {
                let chunk = handle.availableData
                guard !chunk.isEmpty else { break }
                appendBounded(chunk)
            }
            return snapshot()
        }

        func snapshot() -> BoundedDiagnostic {
            condition.lock()
            defer { condition.unlock() }
            return BoundedDiagnostic(
                data: buffer,
                observedByteCount: observedByteCount,
                truncated: truncated
            )
        }

        private func consumeAvailableData(from handle: FileHandle) {
            condition.lock()
            guard acceptsReadabilityCallbacks else {
                condition.unlock()
                return
            }
            activeReadabilityCallbacks += 1
            condition.unlock()

            let chunk = handle.availableData
            var reachedEOF = false
            condition.lock()
            if chunk.isEmpty {
                acceptsReadabilityCallbacks = false
                reachedEOF = true
            } else {
                appendBoundedWhileLocked(chunk)
            }
            activeReadabilityCallbacks -= 1
            condition.broadcast()
            condition.unlock()

            // Outside the lock, and only for real bytes: an observer that
            // reads the stream live must never be able to deadlock the sink
            // that feeds it.
            if !chunk.isEmpty { observer?(chunk) }

            // Leaving the handler installed at EOF can repeatedly schedule an
            // empty callback until the owner observes process termination.
            if reachedEOF { handle.readabilityHandler = nil }
        }

        private func stopReadabilityHandler(waitForActiveCallback: Bool) {
            condition.lock()
            acceptsReadabilityCallbacks = false
            condition.unlock()
            pipe.fileHandleForReading.readabilityHandler = nil

            guard waitForActiveCallback else { return }
            condition.lock()
            while activeReadabilityCallbacks > 0 {
                condition.wait()
            }
            condition.unlock()
        }

        private func appendBounded(_ chunk: Data) {
            condition.lock()
            appendBoundedWhileLocked(chunk)
            condition.unlock()
        }

        private func appendBoundedWhileLocked(_ chunk: Data) {
            let (total, overflow) = observedByteCount.addingReportingOverflow(chunk.count)
            observedByteCount = overflow ? .max : total
            guard buffer.count < capacity else {
                truncated = true
                return
            }
            let remaining = capacity - buffer.count
            buffer.append(chunk.prefix(remaining))
            if chunk.count > remaining {
                truncated = true
            }
        }
    }

    static func run(
        executable: URL,
        arguments: [String],
        diagnosticCapacity: Int = 65_536,
        terminationGracePeriod: TimeInterval = 0.5,
        processDidLaunchHook: (@Sendable (pid_t) -> Void)? = nil,
        stdoutObserver: (@Sendable (Data) -> Void)? = nil
    ) async throws -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // The pinned parser is a local pure transformation. Never let an App,
        // shell, test runner, or injected DYLD_* variable influence child
        // loading or executable selection. The executable is always an
        // immutable private snapshot, so its parent is a trusted writable
        // per-invocation current/TMP directory. Never derive cwd from an
        // arbitrary source argument: literal filenames may contain separators
        // and the parser must not resolve ambient paths through cwd.
        let workingDirectory = executable.deletingLastPathComponent()
        process.currentDirectoryURL = workingDirectory
        process.environment = [
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin",
            "TMPDIR": workingDirectory.path,
        ]
        let stdoutSink = BoundedPipeSink(
            capacity: diagnosticCapacity, observer: stdoutObserver
        )
        let stderrSink = BoundedPipeSink(capacity: diagnosticCapacity)
        process.standardOutput = stdoutSink.pipe
        process.standardError = stderrSink.pipe
        process.standardInput = FileHandle.nullDevice

        let box = ProcessBox(process, terminationGracePeriod: terminationGracePeriod)
        let exitStatus: Int32
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    process.terminationHandler = { _ in continuation.resume() }
                    do {
                        try box.runIfNotCancelled()
                        processDidLaunchHook?(process.processIdentifier)
                    } catch {
                        process.terminationHandler = nil
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                box.cancel()
            }
            // The termination handler has already fired, so this reap returns
            // immediately instead of blocking a cooperative-executor thread
            // for the child's lifetime; it also cancels a pending escalation.
            exitStatus = box.waitUntilExit()
        } catch is CancellationError {
            stdoutSink.finish()
            stderrSink.finish()
            throw ArkTraceError(
                code: .cancelled,
                stage: .parsing,
                message: "Trace parsing was cancelled",
                retryable: true
            )
        } catch {
            stdoutSink.finish()
            stderrSink.finish()
            throw ArkTraceError(
                code: .traceStreamerUnavailable,
                stage: .parsing,
                message: "Failed to launch trace_streamer",
                retryable: true
            )
        }
        let stdout = stdoutSink.finishAndDrainToEOF()
        let stderr = stderrSink.finishAndDrainToEOF()
        return Outcome(
            exitStatus: exitStatus,
            cancelled: box.wasCancellationRequested || Task.isCancelled,
            escalatedToSIGKILL: box.didEscalateToSIGKILL,
            stdout: stdout,
            stderr: stderr
        )
    }

    private static func runOffCallerExecutor(
        executable: URL,
        arguments: [String],
        processDidLaunchHook: (@Sendable (pid_t) -> Void)? = nil,
        stdoutObserver: (@Sendable (Data) -> Void)? = nil
    ) async throws -> Outcome {
        let task = Task.detached {
            try await run(
                executable: executable,
                arguments: arguments,
                processDidLaunchHook: processDidLaunchHook,
                stdoutObserver: stdoutObserver
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func reportedVersion(executableURL: URL) async throws -> String {
        let outcome: Outcome
        do {
            outcome = try await run(
                executable: executableURL,
                arguments: ["--version"],
                diagnosticCapacity: 4_096
            )
        } catch let error as ArkTraceError where error.code == .cancelled {
            throw cancelled(stage: .preparing)
        } catch {
            throw ArkTraceError(
                code: .traceStreamerUnavailable,
                stage: .preparing,
                message: "Failed to launch trace_streamer for --version",
                retryable: true
            )
        }
        guard !outcome.cancelled else { throw cancelled(stage: .preparing) }
        // Pinned TraceStreamer 4.3.7 reports its version and exits 1 for this
        // informational mode. Identity is therefore established by bounded
        // output parsing, not by pretending --version follows parse exit rules.
        let text = (String(data: outcome.stdout.data, encoding: .utf8) ?? "")
            + "\n"
            + (String(data: outcome.stderr.data, encoding: .utf8) ?? "")
        guard let match = text.firstMatch(of: /version\s+([0-9][0-9A-Za-z.\-]*)/) else {
            throw Self.identityMismatch(field: "reportedVersion", reason: "unreported")
        }
        return String(match.1)
    }

    private static func reportedVersionOffCallerExecutor(
        executableURL: URL
    ) async throws -> String {
        let task = Task.detached {
            try await reportedVersion(executableURL: executableURL)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Hashing and file checks

    private static func validate(
        manifest: TraceStreamerManifest, executableURL: URL
    ) throws {
        guard manifest.name == expectedName else {
            throw identityMismatch(field: "name", reason: "mismatch")
        }
        guard manifest.upstreamRepository == expectedUpstreamRepository else {
            throw identityMismatch(field: "upstreamRepository", reason: "mismatch")
        }
        guard manifest.upstreamRevision == expectedUpstreamRevision else {
            throw identityMismatch(field: "upstreamRevision", reason: "mismatch")
        }
        guard manifest.adapterVersion == adapterVersion else {
            throw identityMismatch(field: "adapterVersion", reason: "mismatch")
        }
        guard manifest.buildRecipeVersion == supportedBuildRecipeVersion else {
            throw identityMismatch(field: "buildRecipeVersion", reason: "mismatch")
        }
        guard manifest.architecture == expectedArchitecture else {
            throw identityMismatch(field: "architecture", reason: "unsupported")
        }

        let hash: String
        do {
            hash = try sha256AndSize(at: executableURL).sha256
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw identityMismatch(field: "binarySHA256", reason: "unreadable")
        }
        guard hash == manifest.binarySHA256 else {
            throw identityMismatch(field: "binarySHA256", reason: "mismatch")
        }

        let architecture = try TraceStreamerBinaryInspector.architecture(at: executableURL)
        guard architecture == manifest.architecture else {
            throw identityMismatch(field: "architecture", reason: "mismatch")
        }
    }

    private static func verify(snapshot: ParserSnapshot) throws {
        try validate(manifest: snapshot.manifest, executableURL: snapshot.executableURL)
    }

    private static func validateReportedVersion(
        _ reportedVersion: String,
        manifest: TraceStreamerManifest
    ) throws {
        guard reportedVersion == manifest.reportedVersion else {
            throw identityMismatch(field: "reportedVersion", reason: "mismatch")
        }
    }

    private static func identity(
        manifest: TraceStreamerManifest,
        reportedVersion: String
    ) -> TraceParserIdentity {
        TraceParserIdentity(
            name: manifest.name,
            reportedVersion: reportedVersion,
            binarySHA256: manifest.binarySHA256,
            upstreamRepository: manifest.upstreamRepository,
            upstreamRevision: manifest.upstreamRevision,
            architecture: manifest.architecture,
            adapterVersion: manifest.adapterVersion,
            buildRecipeVersion: manifest.buildRecipeVersion
        )
    }

    private static func sha256AndSize(at url: URL) throws -> (sha256: String, byteCount: Int64) {
        try Task.checkCancellation()
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ArkTraceError(
                code: .traceFileUnreadable,
                stage: .hashing,
                message: "Cannot open file for hashing"
            )
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            let (newTotal, overflow) = total.addingReportingOverflow(Int64(chunk.count))
            guard !overflow else {
                throw ArkTraceError(
                    code: .traceFileUnreadable,
                    stage: .hashing,
                    message: "File is too large to hash"
                )
            }
            total = newTotal
            try Task.checkCancellation()
        }
        let digest = hasher.finalize().lowercaseHexString()
        return (digest, total)
    }

    /// Copies through a private file descriptor in bounded chunks so parent
    /// cancellation can stop large source/parser snapshots promptly. The
    /// destination is created exclusively and removed on every failed copy.
    private static func copyRegularFileCancellable(
        from source: URL,
        to destination: URL,
        permissions: Int,
        chunkHook: (@Sendable () -> Void)? = nil,
        cleanupRemovalHook: (@Sendable (URL) throws -> Void)?
    ) throws {
        try Task.checkCancellation()
        try Data().write(to: destination, options: .withoutOverwriting)
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }

            while true {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: 1 << 20) ?? Data()
                guard !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
                chunkHook?()
                try Task.checkCancellation()
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: destination.path
            )
            try Task.checkCancellation()
        } catch {
            do {
                try removeStagingItems(
                    [destination],
                    removalHook: cleanupRemovalHook
                )
            } catch {
                throw cleanupFailure(stage: .preparing, reason: "stagingCleanupFailed")
            }
            throw error
        }
    }

    private static func hasSQLiteHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
            let header = try? handle.read(upToCount: 16)
        else {
            return false
        }
        try? handle.close()
        return header == Data("SQLite format 3".utf8) + Data([0])
    }

    private static func boundedFileDiagnostic(
        at url: URL,
        capacity: Int = 65_536
    ) -> BoundedDiagnostic? {
        guard isRegularNonSymlinkFile(at: url),
            let handle = try? FileHandle(forReadingFrom: url)
        else {
            return nil
        }
        defer { try? handle.close() }
        let sample = (try? handle.read(upToCount: capacity + 1)) ?? Data()
        return BoundedDiagnostic(
            data: sample.prefix(capacity),
            observedByteCount: sample.count,
            truncated: sample.count > capacity
        )
    }

    private static func diagnosticDetails(
        outcome: Outcome,
        status: BoundedDiagnostic?,
        exitStatus: Int32
    ) -> [String: String] {
        var details = [
            "exitStatus": String(exitStatus),
            "stdoutCapturedBytes": String(outcome.stdout.data.count),
            "stderrCapturedBytes": String(outcome.stderr.data.count),
            "stdoutTruncated": String(outcome.stdout.truncated),
            "stderrTruncated": String(outcome.stderr.truncated),
        ]
        if let status {
            details["statusCapturedBytes"] = String(status.data.count)
            details["statusTruncated"] = String(status.truncated)
        }
        return details
    }

    private static func validate(
        databasePreparation: TraceDatabasePreparationResult
    ) throws {
        let adapter = databasePreparation.schemaAdapterVersion
        guard !adapter.isEmpty, adapter.utf8.count <= 32,
            adapter.utf8.allSatisfy({ byte in
                (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                    || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                    || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                    || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
            }),
            ArkTraceIdentityGrammar.isSHA256(databasePreparation.schemaFingerprint),
            databasePreparation.indexVersion > 0,
            ArkTraceIdentityGrammar.isSHA256(databasePreparation.upstreamDatabaseSHA256),
            databasePreparation.upstreamDatabaseByteCount > 0
        else {
            throw ArkTraceError(
                code: .traceDatabaseInvalid,
                stage: .validating,
                message: "Database preparation returned invalid bounded metadata"
            )
        }
    }

    private static func writeMetadataSidecar(
        at url: URL,
        parser: TraceParserIdentity,
        sourceSHA256: String,
        sourceByteCount: Int64,
        databasePreparation: TraceDatabasePreparationResult
    ) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(
                TraceDatabaseMetadataSidecar(
                    formatVersion: 1,
                    parser: parser,
                    sourceSHA256: sourceSHA256,
                    sourceByteCount: sourceByteCount,
                    databasePreparation: databasePreparation
                )
            )
            guard data.count <= 4_096 else {
                throw stagingFinalizationFailure(reason: "metadataTooLarge")
            }
            try data.write(to: url, options: .withoutOverwriting)
        } catch let error as ArkTraceError {
            throw error
        } catch {
            throw stagingFinalizationFailure(reason: "metadataWrite")
        }
    }

    private static func synchronizeFile(at url: URL) throws {
        let descriptor = unsafe url.path.withCString {
            unsafe Darwin.open($0, O_RDONLY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw stagingFinalizationFailure(reason: "fileSyncOpen")
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw stagingFinalizationFailure(reason: "fileSync")
        }
    }

    private static func synchronizeDirectory(at url: URL) throws {
        let descriptor = unsafe url.path.withCString { unsafe Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else {
            throw stagingFinalizationFailure(reason: "directorySyncOpen")
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw stagingFinalizationFailure(reason: "directorySync")
        }
    }

    private static func fileIdentity(at url: URL) -> FileIdentity? {
        guard case .regular(let identity) = fileIdentityProbe(at: url) else {
            return nil
        }
        return identity
    }

    private static func sourceFileSnapshot(at url: URL) throws -> SourceFileSnapshot {
        let descriptor = unsafe url.path.withCString {
            unsafe Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw snapshotIOFailure(reason: "verifiedSourceOpen")
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard unsafe Darwin.fstat(descriptor, &info) == 0,
            (info.st_mode & S_IFMT) == S_IFREG
        else {
            throw snapshotIOFailure(reason: "verifiedSourceStat")
        }
        return SourceFileSnapshot(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            byteCount: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(info.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    private static func fileIdentityProbe(at url: URL) -> FileIdentityProbe {
        var info = stat()
        let result = unsafe url.path.withCString { unsafe Darwin.lstat($0, &info) }
        guard result == 0 else {
            return errno == ENOENT ? .absent : .inaccessible
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .nonRegular }
        return .regular(
            FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        )
    }

    private static func ownedFile(at url: URL) throws -> OwnedFile {
        guard let identity = fileIdentity(at: url) else {
            throw destinationUnavailable(reason: "promotedFileChanged")
        }
        return OwnedFile(url: url, identity: identity)
    }

    /// Atomically moves the public directory entry to a unique private name
    /// before inspecting or deleting it. This avoids the lstat(path) ->
    /// unlink(path) race: a replacement created at the public path after the
    /// rename is never passed to unlink or recursive Foundation removal.
    private static func removeIfOwned(
        _ file: OwnedFile,
        identityProbeHook: (@Sendable (URL) throws -> Void)?,
        preRemovalHook: (@Sendable (URL) throws -> Void)?
    ) throws {
        let parent = file.url.deletingLastPathComponent()
        var quarantineURL: URL?
        var renameError: Int32 = 0
        for _ in 0..<8 {
            let candidate = parent.appending(path: ".arktrace-rollback-\(UUID().uuidString)", directoryHint: .notDirectory)
            let result = unsafe file.url.path.withCString { sourcePath in
                unsafe candidate.path.withCString { quarantinePath in
                    unsafe Darwin.renameatx_np(
                        AT_FDCWD,
                        sourcePath,
                        AT_FDCWD,
                        quarantinePath,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            if result == 0 {
                quarantineURL = candidate
                break
            }
            renameError = errno
            if renameError == ENOENT { return }
            if renameError != EEXIST { break }
        }
        guard let quarantineURL else {
            throw cleanupFailure(stage: .parsing, reason: "readyQuarantineFailed")
        }

        do {
            try identityProbeHook?(file.url)
        } catch {
            throw cleanupFailure(stage: .parsing, reason: "readyIdentityProbeFailed")
        }

        let shouldRestore: Bool
        switch fileIdentityProbe(at: quarantineURL) {
        case .regular(let identity) where identity == file.identity:
            shouldRestore = false
        case .regular, .nonRegular:
            shouldRestore = true
        case .absent, .inaccessible:
            throw cleanupFailure(stage: .parsing, reason: "readyIdentityProbeFailed")
        }
        if shouldRestore {
            let restoreResult = unsafe quarantineURL.path.withCString { quarantinePath in
                unsafe file.url.path.withCString { destinationPath in
                    unsafe Darwin.renameatx_np(
                        AT_FDCWD,
                        quarantinePath,
                        AT_FDCWD,
                        destinationPath,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard restoreResult == 0 else {
                throw cleanupFailure(stage: .parsing, reason: "replacementRestoreFailed")
            }
            return
        }

        do {
            try preRemovalHook?(file.url)
        } catch {
            throw cleanupFailure(stage: .parsing, reason: "readyRemovalFailed")
        }
        let unlinkResult = unsafe quarantineURL.path.withCString { unsafe Darwin.unlink($0) }
        guard unlinkResult == 0 else {
            throw cleanupFailure(stage: .parsing, reason: "readyRemovalFailed")
        }
    }

    private static func removeOwnedFiles(
        _ files: [OwnedFile],
        identityProbeHook: (@Sendable (URL) throws -> Void)?,
        preRemovalHook: (@Sendable (URL) throws -> Void)?
    ) throws {
        var failed = false
        for file in files.reversed() {
            do {
                try removeIfOwned(
                    file,
                    identityProbeHook: identityProbeHook,
                    preRemovalHook: preRemovalHook
                )
            } catch {
                failed = true
            }
        }
        if failed {
            throw cleanupFailure(stage: .parsing, reason: "readyRollbackFailed")
        }
    }

    private static func removeOwnedFilesOffCallerExecutor(
        _ files: [OwnedFile],
        identityProbeHook: (@Sendable (URL) throws -> Void)?,
        preRemovalHook: (@Sendable (URL) throws -> Void)?
    ) async throws {
        try await Task.detached {
            try removeOwnedFiles(
                files,
                identityProbeHook: identityProbeHook,
                preRemovalHook: preRemovalHook
            )
        }.value
    }

    private static func isRegularNonSymlinkFile(at url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    private static func pathEntryExists(_ url: URL) -> Bool {
        pathEntryStatus(at: url) != .absent
    }

    private static func pathEntryStatus(at url: URL) -> PathEntryStatus {
        var info = stat()
        let result = unsafe url.path.withCString { unsafe Darwin.lstat($0, &info) }
        if result == 0 { return .present }
        return errno == ENOENT ? .absent : .inaccessible
    }

    private static func identityMismatch(field: String, reason: String) -> ArkTraceError {
        ArkTraceError(
            code: .traceStreamerIdentityMismatch,
            stage: .preparing,
            message: "TraceStreamer identity does not match its pinned manifest",
            details: ["field": field, "reason": reason]
        )
    }

    private static func unavailable(reason: String) -> ArkTraceError {
        ArkTraceError(
            code: .traceStreamerUnavailable,
            stage: .preparing,
            message: "Pinned trace_streamer executable is unavailable",
            retryable: true,
            details: ["reason": reason]
        )
    }

    private static func destinationUnavailable(reason: String) -> ArkTraceError {
        ArkTraceError(
            code: .invalidArgument,
            stage: .preparing,
            message: "Parser destination must be a new, exclusively owned file",
            details: ["reason": reason]
        )
    }

    private static func sourceChanged() -> ArkTraceError {
        ArkTraceError(
            code: .traceParseFailed,
            stage: .parsing,
            message: "Trace snapshot changed while it was being parsed",
            details: ["reason": "sourceSnapshotChanged"]
        )
    }

    private static func snapshotIOFailure(reason: String) -> ArkTraceError {
        ArkTraceError(
            code: .traceParseFailed,
            stage: .preparing,
            message: "Unable to prepare private parser staging",
            retryable: true,
            details: ["reason": reason]
        )
    }

    private static func stagingFinalizationFailure(reason: String) -> ArkTraceError {
        ArkTraceError(
            code: .traceParseFailed,
            stage: .indexing,
            message: "Unable to durably prepare the validated database",
            retryable: true,
            details: ["reason": reason]
        )
    }

    private static func cancelled(stage: ArkTraceError.Stage) -> ArkTraceError {
        ArkTraceError(
            code: .cancelled,
            stage: stage,
            message: "Trace parsing was cancelled",
            retryable: true
        )
    }

    private static func cleanupFailure(
        stage: ArkTraceError.Stage,
        reason: String
    ) -> ArkTraceError {
        ArkTraceError(
            code: .traceParseFailed,
            stage: stage,
            message: "Unable to safely clean parser-owned files",
            retryable: true,
            details: ["reason": reason]
        )
    }

    private static func isCleanupFailure(_ error: Error) -> Bool {
        (error as? ArkTraceError)?.isOwnershipCleanupFailure == true
    }

    private static func removeStagingItems(
        _ urls: [URL],
        removalHook: (@Sendable (URL) throws -> Void)?
    ) throws {
        var failed = false
        for url in urls {
            switch pathEntryStatus(at: url) {
            case .absent:
                continue
            case .inaccessible:
                failed = true
                continue
            case .present:
                break
            }
            do {
                try removalHook?(url)
                try FileManager.default.removeItem(at: url)
                if pathEntryStatus(at: url) != .absent { failed = true }
            } catch {
                failed = true
            }
        }
        if failed {
            throw cleanupFailure(stage: .preparing, reason: "stagingCleanupFailed")
        }
    }

    private static func removeOffCallerExecutor(
        _ urls: [URL],
        removalHook: (@Sendable (URL) throws -> Void)?,
        completionHook: (@Sendable () -> Void)? = nil
    ) async throws {
        try await Task.detached {
            let result: Result<Void, Error>
            do {
                try removeStagingItems(urls, removalHook: removalHook)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            completionHook?()
            return try result.get()
        }.value
    }
}
