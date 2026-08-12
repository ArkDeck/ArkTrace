import ArkTraceCore
import CryptoKit
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

    public func parse(source: URL, destination: URL) async throws -> ParsedTrace {
        let configuredExecutableURL = configuredExecutableURL
        let configuredManifestURL = configuredManifestURL
        let prepared = try await Task.detached {
            try Self.prepareParse(
                source: source,
                destination: destination,
                configuredExecutableURL: configuredExecutableURL,
                configuredManifestURL: configuredManifestURL
            )
        }.value
        let result: Result<ParsedTrace, Error>
        do {
            result = .success(
                try await Self.execute(
                    prepared: prepared,
                    finalizationHook: finalizationHook
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
        finalizationHook: (@Sendable () -> Void)?
    ) async throws -> ParsedTrace {
        let version = try await Self.reportedVersionOffCallerExecutor(
            executableURL: prepared.parserSnapshot.executableURL)
        try Self.validateReportedVersion(version, manifest: prepared.parserSnapshot.manifest)
        let parserIdentity = Self.identity(
            manifest: prepared.parserSnapshot.manifest,
            reportedVersion: version
        )

        let outcome = try await Self.runOffCallerExecutor(
            executable: prepared.parserSnapshot.executableURL,
            arguments: [
                prepared.sourceSnapshotURL.path,
                "-e", prepared.outputURL.path,
                "-nm",
            ]
        )
        if outcome.cancelled {
            throw ArkTraceError(
                code: .cancelled,
                stage: .parsing,
                message: "Trace parsing was cancelled",
                retryable: true
            )
        }
        guard outcome.exitStatus == 0 else {
            throw ArkTraceError(
                code: .traceParseFailed,
                stage: .parsing,
                message: "trace_streamer exited with a failure status",
                details: ["exitStatus": String(outcome.exitStatus)]
            )
        }
        guard Self.isRegularNonSymlinkFile(at: prepared.outputURL),
            Self.hasSQLiteHeader(at: prepared.outputURL)
        else {
            throw ArkTraceError(
                code: .traceParseFailed,
                stage: .parsing,
                message: "trace_streamer exited 0 but produced no valid SQLite database"
            )
        }

        try await Self.finalizeAndPromote(
            prepared: prepared,
            finalizationHook: finalizationHook
        )

        return ParsedTrace(
            databaseURL: prepared.destinationURL,
            parser: parserIdentity,
            sourceSHA256: prepared.sourceSHA256,
            sourceByteCount: prepared.sourceByteCount
        )
    }

    // MARK: - Immutable input preparation

    private struct ParserSnapshot: Sendable {
        let directory: URL
        let executableURL: URL
        let manifest: TraceStreamerManifest
    }

    private struct PreparedParse: Sendable {
        let destinationURL: URL
        let destinationClaimURL: URL
        let workDirectory: URL
        let outputURL: URL
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
        private var promoted = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        func promote(_ operation: () throws -> Void) throws {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { throw CancellationError() }
            try operation()
            promoted = true
        }

        var didPromote: Bool {
            lock.lock()
            defer { lock.unlock() }
            return promoted
        }
    }

    private static func finalizeAndPromote(
        prepared: PreparedParse,
        finalizationHook: (@Sendable () -> Void)?
    ) async throws {
        let gate = PromotionGate()
        let task = Task.detached {
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

            try gate.promote {
                guard !Self.pathEntryExists(prepared.destinationURL) else {
                    throw Self.destinationUnavailable(reason: "occupied")
                }
                do {
                    try FileManager.default.moveItem(
                        at: prepared.outputURL,
                        to: prepared.destinationURL
                    )
                } catch {
                    throw Self.destinationUnavailable(reason: "promotionFailed")
                }
            }
        }

        do {
            try await withTaskCancellationHandler {
                try await task.value
                try Task.checkCancellation()
            } onCancel: {
                gate.cancel()
                task.cancel()
            }
        } catch {
            if gate.didPromote {
                await removeOffCallerExecutor([prepared.destinationURL])
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
        guard canonicalDestination != canonicalSource else {
            throw destinationUnavailable(reason: "sameAsSource")
        }
        guard !pathEntryExists(canonicalDestination) else {
            throw destinationUnavailable(reason: "alreadyExists")
        }

        let claimURL = destinationParent.appendingPathComponent(
            ".\(destinationName).arktrace-claim",
            isDirectory: false
        )
        do {
            try Data().write(to: claimURL, options: .withoutOverwriting)
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
                destinationClaimURL: claimURL,
                workDirectory: directory,
                outputURL: directory.appendingPathComponent("output.partial.sqlite"),
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

    private struct Outcome {
        let exitStatus: Int32
        let cancelled: Bool
    }

    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var cancellationRequested = false

        init(_ process: Process) {
            self.process = process
        }

        func runIfNotCancelled() throws {
            lock.lock()
            defer { lock.unlock() }
            guard !cancellationRequested else { throw CancellationError() }
            try process.run()
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancellationRequested = true
            if process.isRunning {
                process.terminate()
            }
        }
    }

    /// Bounded sink so a chatty parser can neither block on a full pipe nor
    /// grow memory without limit.
    final class BoundedPipeSink: @unchecked Sendable {
        private let condition = NSCondition()
        private var buffer = Data()
        private let capacity: Int
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
        func finishAndDrainToEOF() -> Data {
            let handle = pipe.fileHandleForReading
            stopReadabilityHandler(waitForActiveCallback: true)
            while true {
                let chunk = handle.availableData
                guard !chunk.isEmpty else { break }
                appendBounded(chunk)
            }
            return snapshot()
        }

        func snapshot() -> Data {
            condition.lock()
            defer { condition.unlock() }
            return buffer
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
            guard buffer.count < capacity else { return }
            buffer.append(chunk.prefix(capacity - buffer.count))
        }
    }

    private static func run(executable: URL, arguments: [String]) async throws -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdoutSink = BoundedPipeSink()
        let stderrSink = BoundedPipeSink()
        process.standardOutput = stdoutSink.pipe
        process.standardError = stderrSink.pipe
        process.standardInput = FileHandle.nullDevice

        let box = ProcessBox(process)
        let exitStatus: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try box.runIfNotCancelled()
                } catch is CancellationError {
                    process.terminationHandler = nil
                    continuation.resume(
                        throwing: ArkTraceError(
                            code: .cancelled,
                            stage: .parsing,
                            message: "Trace parsing was cancelled",
                            retryable: true
                        )
                    )
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(
                        throwing: ArkTraceError(
                            code: .traceStreamerUnavailable,
                            stage: .parsing,
                            message: "Failed to launch trace_streamer",
                            retryable: true
                        )
                    )
                }
            }
        } onCancel: {
            box.cancel()
        }
        stdoutSink.finish()
        stderrSink.finish()
        return Outcome(exitStatus: exitStatus, cancelled: Task.isCancelled)
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
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--version"]
        let sink = BoundedPipeSink(capacity: 4096)
        process.standardOutput = sink.pipe
        process.standardError = sink.pipe
        process.standardInput = FileHandle.nullDevice

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(
                    throwing: ArkTraceError(
                        code: .traceStreamerUnavailable,
                        stage: .preparing,
                        message: "Failed to launch trace_streamer for --version",
                        retryable: true
                    )
                )
            }
        }
        let output = sink.finishAndDrainToEOF()
        let text = String(data: output, encoding: .utf8) ?? ""
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
