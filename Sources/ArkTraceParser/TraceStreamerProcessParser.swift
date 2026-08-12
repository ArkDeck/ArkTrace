import ArkTraceCore
import CryptoKit
import Darwin
import Foundation

/// Runs a pinned TraceStreamer executable as a child process (DESIGN §8).
///
/// Invocation is `Process.executableURL + arguments[]`, never a shell
/// (AT-PARSE-003). `-nm` keeps user paths out of the exported database
/// (AT-PARSE-004). Cancellation terminates the child process and never
/// promotes partial output (AT-PARSE-009).
public struct TraceStreamerProcessParser: TraceParser {
    public static let expectedName = "trace_streamer"
    public static let expectedUpstreamRepository =
        "https://gitcode.com/openharmony/developtools_smartperf_host.git"
    public static let expectedUpstreamRevision =
        "447a0a49a7b3b914d6e9bd00648ba5a340f6fbf6"
    public static let expectedArchitecture = "arm64"
    public static let adapterVersion = "1"
    public static let supportedBuildRecipeVersion = "1"

    private let configuredExecutableURL: URL
    private let configuredManifestURL: URL?
    private let finalizationHook: (@Sendable () -> Void)?

    /// Construction records configuration only. All filesystem access,
    /// manifest decoding, hashing, and Mach-O inspection happens from the
    /// async methods so a resolver can be used safely by MainActor code.
    public init(executableURL: URL, manifestURL: URL? = nil) throws {
        try self.init(
            executableURL: executableURL,
            manifestURL: manifestURL,
            finalizationHook: nil
        )
    }

    /// Internal synchronization hook used by deterministic cancellation tests.
    init(
        executableURL: URL,
        manifestURL: URL? = nil,
        finalizationHook: (@Sendable () -> Void)?
    ) throws {
        guard executableURL.isFileURL, manifestURL?.isFileURL != false else {
            throw Self.unavailable(reason: "invalidURL")
        }
        self.configuredExecutableURL = executableURL.standardizedFileURL
        self.configuredManifestURL = manifestURL?.standardizedFileURL
        self.finalizationHook = finalizationHook
    }

    public func identity() async throws -> TraceParserIdentity {
        let configuredExecutableURL = configuredExecutableURL
        let configuredManifestURL = configuredManifestURL
        let snapshot = try await Task.detached {
            try Self.makeParserSnapshot(
                configuredExecutableURL: configuredExecutableURL,
                configuredManifestURL: configuredManifestURL,
                parentDirectory: FileManager.default.temporaryDirectory
            )
        }.value
        let result: Result<TraceParserIdentity, Error>
        do {
            let version = try await Self.reportedVersionOffCallerExecutor(
                executableURL: snapshot.executableURL)
            try Self.validateReportedVersion(version, manifest: snapshot.manifest)
            try await Task.detached { try Self.verify(snapshot: snapshot) }.value
            result = .success(Self.identity(manifest: snapshot.manifest, reportedVersion: version))
        } catch {
            result = .failure(error)
        }
        await Self.removeOffCallerExecutor([snapshot.directory])
        return try result.get()
    }

    public func parse(
        source: URL,
        destination: URL,
        progress: TraceProgressHandler?,
        prepareDatabase: @escaping TraceDatabasePreparer
    ) async throws -> ParsedTrace {
        progress?(.preparing)
        let configuredExecutableURL = configuredExecutableURL
        let configuredManifestURL = configuredManifestURL
        progress?(.hashing)
        let prepared = try await Task.detached {
            try Self.prepareParse(
                source: source,
                destination: destination,
                configuredExecutableURL: configuredExecutableURL,
                configuredManifestURL: configuredManifestURL
            )
        }.value
        progress?(.cacheLookup)
        let result: Result<ParsedTrace, Error>
        do {
            result = .success(
                try await Self.execute(
                    prepared: prepared,
                    finalizationHook: finalizationHook,
                    progress: progress,
                    prepareDatabase: prepareDatabase
                )
            )
        } catch {
            result = .failure(error)
        }
        await Self.removeOffCallerExecutor([
            prepared.workDirectory,
            prepared.destinationClaimURL,
        ])
        return try result.get()
    }

    private static func execute(
        prepared: PreparedParse,
        finalizationHook: (@Sendable () -> Void)?,
        progress: TraceProgressHandler?,
        prepareDatabase: @escaping TraceDatabasePreparer
    ) async throws -> ParsedTrace {
        let version = try await Self.reportedVersionOffCallerExecutor(
            executableURL: prepared.parserSnapshot.executableURL)
        try Self.validateReportedVersion(version, manifest: prepared.parserSnapshot.manifest)
        let parserIdentity = Self.identity(
            manifest: prepared.parserSnapshot.manifest,
            reportedVersion: version
        )

        progress?(.parsing)
        let outcome = try await Self.runOffCallerExecutor(
            executable: prepared.parserSnapshot.executableURL,
            arguments: Self.invocationArguments(
                source: prepared.sourceSnapshotURL,
                output: prepared.outputURL
            )
        )
        try Self.validateProcessOutcome(outcome, outputURL: prepared.outputURL)

        let databasePreparation = try await Self.finalizeAndPromote(
            prepared: prepared,
            parserIdentity: parserIdentity,
            finalizationHook: finalizationHook,
            progress: progress,
            prepareDatabase: prepareDatabase
        )

        return ParsedTrace(
            databaseURL: prepared.destinationURL,
            metadataSidecarURL: prepared.destinationMetadataURL,
            parser: parserIdentity,
            sourceSHA256: prepared.sourceSHA256,
            sourceByteCount: prepared.sourceByteCount,
            databasePreparation: databasePreparation
        )
    }

    static func validateProcessOutcome(_ outcome: Outcome, outputURL: URL) throws {
        let statusDiagnostic = Self.boundedFileDiagnostic(
            at: URL(fileURLWithPath: outputURL.path + ".ohos.ts")
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
        let parserSnapshot: ParserSnapshot
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

    private struct OwnedFile: Sendable {
        let url: URL
        let identity: FileIdentity
    }

    private static func finalizeAndPromote(
        prepared: PreparedParse,
        parserIdentity: TraceParserIdentity,
        finalizationHook: (@Sendable () -> Void)?,
        progress: TraceProgressHandler?,
        prepareDatabase: @escaping TraceDatabasePreparer
    ) async throws -> TraceDatabasePreparationResult {
        let gate = PromotionGate()
        let task = Task.detached {
            try Task.checkCancellation()
            let databasePreparation = try await prepareDatabase(prepared.outputURL, progress)
            try Self.validate(databasePreparation: databasePreparation)
            try Task.checkCancellation()
            try Self.verify(snapshot: prepared.parserSnapshot)
            try Task.checkCancellation()

            let sourceAfterParse: (sha256: String, byteCount: Int64)
            do {
                sourceAfterParse = try Self.sha256AndSize(at: prepared.sourceSnapshotURL)
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
                    for file in owned.reversed() {
                        Self.removeIfOwned(file)
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
                return databasePreparation
            } onCancel: {
                gate.cancel()
                task.cancel()
            }
        } catch {
            let promotedFiles = gate.ownedPromotedFiles
            if !promotedFiles.isEmpty {
                await removeOwnedFilesOffCallerExecutor(promotedFiles)
            }
            if error is CancellationError || Task.isCancelled {
                throw cancelled(stage: .parsing)
            }
            throw error
        }
    }

    private static func prepareParse(
        source: URL,
        destination: URL,
        configuredExecutableURL: URL,
        configuredManifestURL: URL?
    ) throws -> PreparedParse {
        do {
            return try prepareParseUnchecked(
                source: source,
                destination: destination,
                configuredExecutableURL: configuredExecutableURL,
                configuredManifestURL: configuredManifestURL
            )
        } catch let error as ArkTraceError {
            throw error
        } catch {
            throw snapshotIOFailure(reason: "prepareStaging")
        }
    }

    private static func prepareParseUnchecked(
        source: URL,
        destination: URL,
        configuredExecutableURL: URL,
        configuredManifestURL: URL?
    ) throws -> PreparedParse {
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
        let canonicalDestination = destinationParent.appendingPathComponent(destinationName)
        let destinationMetadata = URL(
            fileURLWithPath: canonicalDestination.path + ".arktrace.json"
        )
        guard canonicalDestination != canonicalSource else {
            throw destinationUnavailable(reason: "sameAsSource")
        }
        guard !pathEntryExists(canonicalDestination), !pathEntryExists(destinationMetadata) else {
            throw destinationUnavailable(reason: "alreadyExists")
        }

        let claimURL = destinationParent.appendingPathComponent(
            ".\(destinationName).arktrace-claim",
            isDirectory: false
        )
        do {
            try Data().write(to: claimURL, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: claimURL.path)
        } catch {
            throw destinationUnavailable(reason: "inUse")
        }

        var workDirectory: URL?
        do {
            guard !pathEntryExists(canonicalDestination) else {
                throw destinationUnavailable(reason: "alreadyExists")
            }
            let directory = destinationParent.appendingPathComponent(
                ".arktrace-parser-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            workDirectory = directory

            let parserSnapshot = try makeParserSnapshot(
                configuredExecutableURL: configuredExecutableURL,
                configuredManifestURL: configuredManifestURL,
                parentDirectory: directory,
                useParentDirectory: true
            )
            let sourceSnapshotURL = directory.appendingPathComponent("source.trace")
            try fm.copyItem(at: canonicalSource, to: sourceSnapshotURL)
            try fm.setAttributes(
                [.posixPermissions: 0o400],
                ofItemAtPath: sourceSnapshotURL.path
            )
            guard isRegularNonSymlinkFile(at: sourceSnapshotURL) else {
                throw ArkTraceError(
                    code: .traceFileUnreadable,
                    stage: .preparing,
                    message: "Trace snapshot is not a regular file"
                )
            }
            let sourceIdentity = try sha256AndSize(at: sourceSnapshotURL)
            return PreparedParse(
                destinationURL: canonicalDestination,
                destinationMetadataURL: destinationMetadata,
                destinationClaimURL: claimURL,
                workDirectory: directory,
                outputURL: directory.appendingPathComponent("output.partial.sqlite"),
                outputMetadataURL: directory.appendingPathComponent(
                    "output.partial.sqlite.arktrace.json"
                ),
                sourceSnapshotURL: sourceSnapshotURL,
                sourceSHA256: sourceIdentity.sha256,
                sourceByteCount: sourceIdentity.byteCount,
                parserSnapshot: parserSnapshot
            )
        } catch {
            if let workDirectory { try? fm.removeItem(at: workDirectory) }
            try? fm.removeItem(at: claimURL)
            throw error
        }
    }

    private static func makeParserSnapshot(
        configuredExecutableURL: URL,
        configuredManifestURL: URL?,
        parentDirectory: URL,
        useParentDirectory: Bool = false
    ) throws -> ParserSnapshot {
        do {
            return try makeParserSnapshotUnchecked(
                configuredExecutableURL: configuredExecutableURL,
                configuredManifestURL: configuredManifestURL,
                parentDirectory: parentDirectory,
                useParentDirectory: useParentDirectory
            )
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
        useParentDirectory: Bool
    ) throws -> ParserSnapshot {
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
                .appendingPathComponent("manifest.json"))
            .resolvingSymlinksInPath().standardizedFileURL
        let manifest = try TraceStreamerManifest.load(from: manifestURL)

        let directory: URL
        if useParentDirectory {
            directory = parentDirectory
        } else {
            directory = parentDirectory.appendingPathComponent(
                ".arktrace-identity-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        }

        do {
            let executableSnapshot = directory.appendingPathComponent("trace_streamer")
            try fm.copyItem(at: canonicalExecutable, to: executableSnapshot)
            try fm.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: executableSnapshot.path
            )
            try validate(manifest: manifest, executableURL: executableSnapshot)
            return ParserSnapshot(
                directory: directory,
                executableURL: executableSnapshot,
                manifest: manifest
            )
        } catch {
            if !useParentDirectory { try? fm.removeItem(at: directory) }
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

        init(capacity: Int = 65_536) {
            self.capacity = capacity
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
        terminationGracePeriod: TimeInterval = 0.5
    ) async throws -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdoutSink = BoundedPipeSink(capacity: diagnosticCapacity)
        let stderrSink = BoundedPipeSink(capacity: diagnosticCapacity)
        process.standardOutput = stdoutSink.pipe
        process.standardError = stderrSink.pipe
        process.standardInput = FileHandle.nullDevice

        let box = ProcessBox(process, terminationGracePeriod: terminationGracePeriod)
        let exitStatus: Int32
        do {
            exitStatus = try await withTaskCancellationHandler {
                try box.runIfNotCancelled()
                return box.waitUntilExit()
            } onCancel: {
                box.cancel()
            }
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
        arguments: [String]
    ) async throws -> Outcome {
        let task = Task.detached {
            try await run(executable: executable, arguments: arguments)
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
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (digest, total)
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
            databasePreparation.schemaFingerprint.utf8.count == 64,
            databasePreparation.schemaFingerprint.utf8.allSatisfy({ byte in
                (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                    || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
            }),
            databasePreparation.indexVersion > 0,
            databasePreparation.upstreamDatabaseSHA256.utf8.count == 64,
            databasePreparation.upstreamDatabaseSHA256.utf8.allSatisfy({ byte in
                (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                    || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
            }),
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
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW)
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
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else {
            throw stagingFinalizationFailure(reason: "directorySyncOpen")
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw stagingFinalizationFailure(reason: "directorySync")
        }
    }

    private static func fileIdentity(at url: URL) -> FileIdentity? {
        var info = stat()
        let result = url.path.withCString { Darwin.lstat($0, &info) }
        guard result == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    private static func ownedFile(at url: URL) throws -> OwnedFile {
        guard let identity = fileIdentity(at: url) else {
            throw destinationUnavailable(reason: "promotedFileChanged")
        }
        return OwnedFile(url: url, identity: identity)
    }

    private static func removeIfOwned(_ file: OwnedFile) {
        guard fileIdentity(at: file.url) == file.identity else { return }
        try? FileManager.default.removeItem(at: file.url)
    }

    private static func removeOwnedFilesOffCallerExecutor(_ files: [OwnedFile]) async {
        await Task.detached {
            for file in files.reversed() {
                removeIfOwned(file)
            }
        }.value
    }

    private static func isRegularNonSymlinkFile(at url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    private static func pathEntryExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
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

    private static func removeOffCallerExecutor(_ urls: [URL]) async {
        await Task.detached {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }.value
    }
}
