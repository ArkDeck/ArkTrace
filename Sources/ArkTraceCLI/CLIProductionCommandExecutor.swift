import ArkTraceAnalysis
import ArkTraceCore
import ArkTraceParser
import ArkTraceRuntime
import ArkTraceStore
import Darwin
import Foundation

protocol CLIManagedTraceSession: CLIMachineTraceSession {
    func cliClose() async throws
}

extension TraceSession: CLIManagedTraceSession {
    func cliClose() async throws {
        try await close()
    }
}

/// Production implementation for the Phase 2 command surface. Every trace
/// command opens one `TraceSession`, derives human and machine output from the
/// same bound result, and closes the session before returning to the writer.
package struct CLIProductionCommandExecutor: CLICommandExecuting, @unchecked Sendable {
    typealias SessionOpener = @Sendable (
        URL, CLIGlobalOptions, CLIStoragePaths
    ) async throws -> any CLIManagedTraceSession
    typealias ParserIdentityProvider = @Sendable (
        CLIGlobalOptions
    ) async throws -> TraceParserIdentity
    typealias ToolRevisionProvider = @Sendable () throws -> String
    typealias StoragePathsProvider = @Sendable () throws -> CLIStoragePaths
    typealias SelfTestFixtureProvider = @Sendable () throws -> URL

    private let sessionOpener: SessionOpener
    private let parserIdentityProvider: ParserIdentityProvider
    private let toolRevisionProvider: ToolRevisionProvider
    private let storagePathsProvider: StoragePathsProvider
    private let selfTestFixtureProvider: SelfTestFixtureProvider

    package init() {
        sessionOpener = Self.openProductionSession
        parserIdentityProvider = { options in
            try await options.resolveParser().identity()
        }
        toolRevisionProvider = {
            try CLIExecutableIdentityResolver.current().resolveBuildRevision()
        }
        storagePathsProvider = Self.defaultStoragePaths
        selfTestFixtureProvider = Self.bundledSelfTestFixture
    }

    init(
        sessionOpener: @escaping SessionOpener,
        parserIdentityProvider: @escaping ParserIdentityProvider,
        toolRevisionProvider: @escaping ToolRevisionProvider = {
            try CLIExecutableIdentityResolver.current().resolveBuildRevision()
        },
        storagePathsProvider: @escaping StoragePathsProvider,
        selfTestFixtureProvider: @escaping SelfTestFixtureProvider
    ) {
        self.sessionOpener = sessionOpener
        self.parserIdentityProvider = parserIdentityProvider
        self.toolRevisionProvider = toolRevisionProvider
        self.storagePathsProvider = storagePathsProvider
        self.selfTestFixtureProvider = selfTestFixtureProvider
    }

    package func execute(_ invocation: CLIInvocation) async throws -> CLICommandOutput {
        let operationDeadline = ContinuousClock.now.advanced(
            by: .milliseconds(invocation.options.limits.timeoutMs)
        )
        switch invocation.command {
        case .doctor(let selfTest):
            return try await doctor(invocation: invocation, selfTest: selfTest)
        case .inspect(let trace):
            return try await withSession(trace: trace, options: invocation.options) { session in
                CLIOperationStage.active?.set(.querying)
                let snapshot = try await session.cliInspectSnapshot()
                CLIOperationStage.active?.set(.encoding)
                let payload = try CLIMachineCommandPayload.inspect(snapshot: snapshot)
                return CLICommandOutput(
                    stdout: CLIHumanRenderer.inspect(snapshot),
                    machinePayload: payload
                )
            }
        case .summary(_, let range):
            let trace = try traceOperand(invocation.command)
            let request = try TraceSummaryRequest(
                range: range,
                maximumRowsPerSection: invocation.options.limits.maxRows,
                maximumEventsPerSection: invocation.options.limits.maxEvents,
                timeout: .milliseconds(invocation.options.limits.timeoutMs)
            )
            return try await withSession(trace: trace, options: invocation.options) { session in
                CLIOperationStage.active?.set(.analyzing)
                let bound = try await session.cliSummary(request)
                CLIOperationStage.active?.set(.encoding)
                let payload = try CLIMachineCommandPayload.summary(bound: bound)
                return CLICommandOutput(
                    stdout: CLIHumanRenderer.summary(bound.value),
                    machinePayload: payload
                )
            }
        case .processes(let trace, let pid, let name, let limit):
            let query = try ProcessQuery(
                pid: pid,
                name: name,
                limit: limit,
                deadline: operationDeadline
            )
            return try await withSession(trace: trace, options: invocation.options) { session in
                CLIOperationStage.active?.set(.querying)
                let bound = try await session.cliProcesses(query)
                CLIOperationStage.active?.set(.encoding)
                let payload = try CLIMachineCommandPayload.processes(bound: bound)
                return CLICommandOutput(
                    stdout: CLIHumanRenderer.processes(bound.value),
                    machinePayload: payload
                )
            }
        case .threads(
            let trace, let processKey, let pid, let threadKey, let tid, let name, let limit
        ):
            let query = try ThreadQuery(
                processKey: processKey.map(ProcessKey.init(ipid:)),
                pid: pid,
                threadKey: threadKey.map(ThreadKey.init(itid:)),
                tid: tid,
                name: name,
                limit: limit,
                deadline: operationDeadline
            )
            return try await withSession(trace: trace, options: invocation.options) { session in
                CLIOperationStage.active?.set(.querying)
                let bound = try await session.cliThreads(query)
                CLIOperationStage.active?.set(.encoding)
                let payload = try CLIMachineCommandPayload.threads(bound: bound)
                return CLICommandOutput(
                    stdout: CLIHumanRenderer.threads(bound.value),
                    machinePayload: payload
                )
            }
        case .query(let trace, let options):
            let request = try TraceAgentQueryRequest(
                view: options.view,
                range: options.range,
                filters: options.filters,
                limit: options.limit,
                timeout: .milliseconds(invocation.options.limits.timeoutMs)
            )
            return try await withSession(trace: trace, options: invocation.options) { session in
                CLIOperationStage.active?.set(.querying)
                let bound = try await session.cliAgentQuery(request)
                CLIOperationStage.active?.set(.encoding)
                return CLICommandOutput(
                    stdout: try CLIHumanRenderer.query(
                        bound.value,
                        maximumBytes: invocation.options.limits.maxOutputBytes
                    ),
                    machinePayload: try CLIMachineCommandPayload.query(bound: bound)
                )
            }
        case .context(let trace, let options):
            let request = try TraceContextRequest(
                time: options.time,
                filters: options.filters,
                maximumEvents: invocation.options.limits.maxEvents,
                maximumRows: invocation.options.limits.maxRows,
                maximumOutputBytes: invocation.options.limits.maxOutputBytes,
                timeout: .milliseconds(invocation.options.limits.timeoutMs)
            )
            return try await withSession(trace: trace, options: invocation.options) { session in
                CLIOperationStage.active?.set(.analyzing)
                let bound = try await Self.envelopeFittedContext(
                    request,
                    invocation: invocation,
                    session: session
                )
                CLIOperationStage.active?.set(.encoding)
                return CLICommandOutput(
                    stdout: try CLIHumanRenderer.context(
                        bound.value,
                        maximumBytes: invocation.options.limits.maxOutputBytes
                    ),
                    machinePayload: try CLIMachineCommandPayload.context(bound: bound)
                )
            }
        case .analyze(let trace, let options):
            return try await withSession(trace: trace, options: invocation.options) { session in
                CLIOperationStage.active?.set(.analyzing)
                let snapshot = try await session.cliInspectSnapshot()
                let range = try options.range ?? TraceTimeRange.query(
                    startNs: 0, endNs: snapshot.metadata.durationNs
                )
                let eventBudget = invocation.options.limits.maxEvents
                let request = try TraceDeterministicAnalysisRequest(
                    range: range,
                    filters: options.filters,
                    maximumCPUSlices: eventBudget,
                    maximumProcessSlices: eventBudget,
                    maximumThreadSlices: eventBudget,
                    maximumStateIntervals: eventBudget,
                    maximumNamedSlices: eventBudget,
                    maximumSchedulingEvents: eventBudget,
                    maximumHotEvents: eventBudget,
                    topProcessLimit: options.limit,
                    topThreadLimit: options.limit,
                    longSliceLimit: options.limit,
                    schedulingSampleLimit: options.limit,
                    hotIntervalLimit: options.limit,
                    minimumLongSliceDurationNs: options.thresholdNs,
                    timeout: .milliseconds(invocation.options.limits.timeoutMs)
                )
                let sourceBound = try await session.cliAnalyze(request)
                let bound = CLIMachineBoundTraceResult(
                    snapshot: sourceBound.snapshot,
                    value: try sourceBound.value.retainingRows(
                        maximumRows: invocation.options.limits.maxRows
                    )
                )
                CLIOperationStage.active?.set(.encoding)
                return CLICommandOutput(
                    stdout: try CLIHumanRenderer.analyze(
                        options.kind, bound.value,
                        maximumBytes: invocation.options.limits.maxOutputBytes
                    ),
                    machinePayload: try CLIMachineCommandPayload.analyze(
                        kind: options.kind, bound: bound
                    )
                )
            }
        case .help, .version, .licenses:
            throw ArkTraceError(
                code: .internalError,
                stage: .request,
                message: "Utility command reached the trace executor",
                details: ["reason": "requestPayloadMismatch"]
            )
        }
    }

    private static func envelopeFittedContext(
        _ initialRequest: TraceContextRequest,
        invocation: CLIInvocation,
        session: any CLIManagedTraceSession
    ) async throws -> CLIMachineBoundTraceResult<TraceContext> {
        guard invocation.options.json else {
            return try await session.cliContext(initialRequest)
        }
        guard let tool = CLIMachineExecutionContext.tool else {
            throw ArkTraceError(
                code: .internalError,
                stage: .encoding,
                message: "Machine tool identity is unavailable during Context retention",
                details: ["reason": "missingToolIdentity"]
            )
        }

        let maximumBytes = invocation.options.limits.maxOutputBytes
        let encoder = CLIMachineEncoder()
        var request = initialRequest
        var priorRawByteCount: Int?
        var lastRequiredByteCount = maximumBytes + 1

        // The first pass normally fits. Near the output boundary, use the
        // measured full envelope overage to tighten the domain byte limit and
        // let TraceContextBuilder re-run its deterministic retention policy.
        // A small fixed attempt cap prevents a non-conforming test/session
        // implementation from turning this into an unbounded retry loop.
        for _ in 0..<16 {
            try Task.checkCancellation()
            let bound = try await session.cliContext(request)
            let payload = try CLIMachineCommandPayload.context(bound: bound)
            // Unbounded on purpose: this loop measures the full envelope and
            // enforces `maximumBytes` itself to drive the retention retry.
            let document = try encoder.encode(
                payload.envelope(for: invocation, tool: tool),
                pretty: invocation.options.pretty,
                maximumBytes: Int.max
            )
            lastRequiredByteCount = document.count
            if document.count <= maximumBytes { return bound }

            let rawByteCount = try bound.value.encoded(maximumBytes: Int.max).count
            let overage = document.count - maximumBytes
            let (candidateLimit, underflow) = rawByteCount.subtractingReportingOverflow(
                overage
            )
            let nextLimit = min(request.maximumOutputBytes - 1, candidateLimit)
            guard !underflow,
                nextLimit >= 1_024,
                nextLimit < request.maximumOutputBytes,
                priorRawByteCount != rawByteCount
            else {
                throw contextEnvelopeLimitFailure(
                    maximumBytes: maximumBytes,
                    requiredBytes: document.count
                )
            }
            priorRawByteCount = rawByteCount
            request = try TraceContextRequest(
                time: request.time,
                filters: request.filters,
                maximumEvents: request.maximumEvents,
                maximumRows: request.maximumRows,
                maximumOutputBytes: nextLimit,
                timeout: request.timeout
            )
        }
        throw contextEnvelopeLimitFailure(
            maximumBytes: maximumBytes,
            requiredBytes: lastRequiredByteCount
        )
    }

    private static func contextEnvelopeLimitFailure(
        maximumBytes: Int,
        requiredBytes: Int
    ) -> ArkTraceError {
        ArkTraceError(
            code: .outputLimitExceeded,
            stage: .encoding,
            message: "The minimum Context machine envelope exceeds its byte budget",
            retryable: true,
            details: [
                "maximumBytes": String(maximumBytes),
                "requiredBytes": String(requiredBytes),
            ]
        )
    }

    private func doctor(
        invocation: CLIInvocation,
        selfTest: Bool
    ) async throws -> CLICommandOutput {
        try Task.checkCancellation()
        let paths = try storagePathsProvider()
        var firstFailure: ArkTraceError?
        let toolRevision: String?
        do {
            toolRevision = try toolRevisionProvider()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ArkTraceError where error.code == .cancelled {
            throw error
        } catch {
            toolRevision = nil
            firstFailure = Self.doctorFailure(
                error,
                fallback: ArkTraceError(
                    code: .internalError,
                    stage: .encoding,
                    message: "The ArkTrace executable identity is unavailable",
                    details: ["reason": "executableReadFailed"]
                )
            )
        }
        var checks: [CLIMachineDoctorCheck] = [
            try Self.doctorCheck(code: "tool", status: toolRevision == nil ? .failed : .ok),
            try Self.doctorCheck(code: "os", status: .ok),
            try Self.doctorCheck(
                code: "architecture",
                status: Self.isSupportedArchitecture ? .ok : .failed
            ),
        ]
        if !Self.isSupportedArchitecture {
            firstFailure = firstFailure ?? ArkTraceError(
                code: .analysisUnsupported,
                stage: .analyzing,
                message: "The current architecture is not supported"
            )
        }

        let parserIdentity: TraceParserIdentity?
        do {
            parserIdentity = try await parserIdentityProvider(invocation.options)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ArkTraceError where error.code == .cancelled {
            throw error
        } catch {
            parserIdentity = nil
            firstFailure = firstFailure ?? Self.doctorFailure(
                error,
                fallback: ArkTraceError(
                    code: .traceStreamerUnavailable,
                    stage: .preparing,
                    message: "Pinned trace_streamer identity is unavailable",
                    retryable: true
                )
            )
        }
        checks.append(try Self.doctorCheck(
            code: "parserManifest",
            status: parserIdentity == nil ? .failed : .ok
        ))
        checks.append(try Self.doctorCheck(
            code: "parserIdentity",
            status: parserIdentity == nil ? .failed : .ok
        ))

        let sqlite = TraceSQLiteRuntimeInfo.current
        let sqliteHealthy = !sqlite.version.isEmpty && sqlite.isThreadSafe
        checks.append(try Self.doctorCheck(
            code: "sqlite",
            status: sqliteHealthy ? .ok : .failed
        ))
        if !sqliteHealthy {
            firstFailure = firstFailure ?? ArkTraceError(
                code: .analysisUnsupported,
                stage: .analyzing,
                message: "The SQLite runtime is not supported"
            )
        }
        let cache = Self.cacheFacts(paths.cacheDirectory)
        let cacheStatus: CLIMachineDoctorStatus = !cache.isWritable
            ? .failed
            : cache.freeBytes == 0 ? .warning : .ok
        checks.append(try Self.doctorCheck(
            code: "cache",
            status: cacheStatus
        ))
        if cacheStatus == .failed {
            firstFailure = firstFailure ?? ArkTraceError(
                code: .traceCacheCorrupt,
                stage: .cacheLookup,
                message: "The trace cache location is not usable",
                retryable: true,
                details: ["reason": "cacheIO"]
            )
        }
        let schemaHealthy = !TraceDatabaseStagingPreparer.schemaAdapterVersion.isEmpty
        checks.append(try Self.doctorCheck(
            code: "schemaAdapter",
            status: schemaHealthy ? .ok : .failed
        ))
        if !schemaHealthy {
            firstFailure = firstFailure ?? ArkTraceError(
                code: .internalError,
                stage: .analyzing,
                message: "The schema adapter identity is unavailable",
                details: ["reason": "unsupported"]
            )
        }

        if selfTest {
            let status: CLIMachineDoctorStatus
            do {
                let fixture = try selfTestFixtureProvider()
                let selfTestOptions = try CLIGlobalOptions(
                    json: invocation.options.json,
                    pretty: invocation.options.pretty,
                    limits: invocation.options.limits,
                    traceStreamerURL: invocation.options.traceStreamerURL,
                    noCache: true
                )
                _ = try await withSession(
                    trace: fixture.path,
                    options: selfTestOptions
                ) { session in
                    let request = try TraceSummaryRequest(
                        maximumRowsPerSection: invocation.options.limits.maxRows,
                        maximumEventsPerSection: invocation.options.limits.maxEvents,
                        timeout: .milliseconds(invocation.options.limits.timeoutMs)
                    )
                    let bound = try await session.cliSummary(request)
                    guard bound.value.schemaFingerprint == bound.snapshot.metadata.schemaFingerprint
                    else {
                        // Stage must stay within the package contract's
                        // allowed set for TRACE_DATABASE_INVALID; .analyzing
                        // would be rewritten to INTERNAL_ERROR at the
                        // boundary, masking this diagnostic (exit 9, not 5).
                        throw ArkTraceError(
                            code: .traceDatabaseInvalid,
                            stage: .querying,
                            message: "Self-test summary provenance is inconsistent"
                        )
                    }
                }
                status = .ok
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ArkTraceError where error.code == .cancelled {
                throw error
            } catch {
                status = .failed
                firstFailure = firstFailure ?? Self.doctorFailure(
                    error,
                    fallback: ArkTraceError(
                        code: .traceParseFailed,
                        stage: .parsing,
                        message: "The bundled trace self-test failed",
                        retryable: false
                    )
                )
            }
            checks.append(try Self.doctorCheck(code: "selfTest", status: status))
        }

        try Task.checkCancellation()
        if let firstFailure { throw firstFailure }
        let limit = invocation.options.limits.maxRows
        let page = BoundedPage(
            items: Array(checks.prefix(limit)),
            truncated: checks.count > limit
        )
        let payload = try CLIMachineCommandPayload.doctor(
            selfTest: selfTest,
            checks: page
        )
        return CLICommandOutput(
            stdout: CLIHumanRenderer.doctor(
                page,
                details: CLIHumanDoctorDetails(
                    toolVersion: ArkTraceCLITool.version,
                    toolBuildRevision: toolRevision,
                    operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                    architecture: Self.architectureName,
                    parserLocation: Self.parserLocation(for: invocation.options),
                    parserIdentity: parserIdentity,
                    sqlite: sqlite,
                    cacheLocation: paths.cacheDirectory.path,
                    cacheWritable: cache.isWritable,
                    cacheFreeBytes: cache.freeBytes,
                    schemaAdapterVersion: TraceDatabaseStagingPreparer.schemaAdapterVersion
                )
            ),
            machinePayload: payload
        )
    }

    private func withSession<Value: Sendable>(
        trace: String,
        options: CLIGlobalOptions,
        operation: (any CLIManagedTraceSession) async throws -> Value
    ) async throws -> Value {
        let paths = try storagePathsProvider()
        let source = URL(filePath: trace).standardizedFileURL
        // Session opening spans hashing, cache lookup, and the exporter
        // parse; a deadline expiry anywhere in it is attributed to parsing.
        CLIOperationStage.active?.set(.parsing)
        let session = try await sessionOpener(source, options, paths)
        let value: Value
        do {
            value = try await operation(session)
        } catch {
            let operationError = error
            try await session.cliClose()
            throw operationError
        }
        try await session.cliClose()
        try Task.checkCancellation()
        return value
    }

    private static func openProductionSession(
        source: URL,
        options: CLIGlobalOptions,
        paths: CLIStoragePaths
    ) async throws -> any CLIManagedTraceSession {
        let parser = try options.resolveParser()
        let policy: TraceSessionStoragePolicy = options.noCache
            ? .ephemeral
            : .contentAddressed(cacheDirectory: paths.cacheDirectory)
        return try await TraceSession.open(
            source: source,
            parser: parser,
            stagingDirectory: paths.stagingDirectory,
            storagePolicy: policy
        )
    }

    private static func defaultStoragePaths() throws -> CLIStoragePaths {
        guard let root = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw ArkTraceError(
                code: .internalError,
                stage: .preparing,
                message: "The user cache directory is unavailable",
                details: ["reason": "parentUnavailable"]
            )
        }
        let productRoot = root.appending(path: "com.arktrace.ArkTrace", directoryHint: .isDirectory)
        return CLIStoragePaths(
            stagingDirectory: productRoot.appending(path: "staging", directoryHint: .isDirectory),
            cacheDirectory: productRoot.appending(path: "traces", directoryHint: .isDirectory)
        )
    }

    static func bundledSelfTestFixture() throws -> URL {
        guard let root = try? CLIResourceLocator.productionRoot() else {
            throw ArkTraceError(
                code: .internalError,
                stage: .preparing,
                message: "The bundled self-test trace is unavailable",
                details: ["reason": "unavailable"]
            )
        }
        return root.appending(path: "zlib.htrace", directoryHint: .notDirectory)
    }

    private static func doctorCheck(
        code: String,
        status: CLIMachineDoctorStatus
    ) throws -> CLIMachineDoctorCheck {
        let names: [String: String] = [
            "tool": "ArkTrace tool",
            "os": "Operating system",
            "architecture": "Architecture",
            "parserManifest": "Parser manifest",
            "parserIdentity": "Parser identity",
            "sqlite": "SQLite",
            "cache": "Trace cache",
            "schemaAdapter": "Schema adapter",
            "selfTest": "End-to-end self-test",
        ]
        guard let name = names[code] else {
            throw ArkTraceError(
                code: .internalError,
                stage: .analyzing,
                message: "Doctor check definition is invalid",
                details: ["reason": "unknownDoctorCheck"]
            )
        }
        return try CLIMachineDoctorCheck(code: code, name: name, status: status)
    }

    private static func doctorFailure(
        _ error: any Error,
        fallback: ArkTraceError
    ) -> ArkTraceError {
        (error as? ArkTraceError) ?? fallback
    }

    private static func cacheFacts(_ url: URL) -> (isWritable: Bool, freeBytes: UInt64) {
        var candidate = url.standardizedFileURL
        for _ in 0..<16 {
            var info = stat()
            let probe = unsafe candidate.path.withCString { unsafe Darwin.lstat($0, &info) }
            if probe == 0 {
                let attributes = try? FileManager.default.attributesOfFileSystem(
                    forPath: candidate.path
                )
                let freeBytes = (attributes?[.systemFreeSize] as? NSNumber)?.uint64Value
                guard (info.st_mode & S_IFMT) == S_IFDIR,
                    unsafe Darwin.access(candidate.path, W_OK | X_OK) == 0,
                    let freeBytes
                else { return (false, 0) }
                return (true, freeBytes)
            }
            guard errno == ENOENT else { return (false, 0) }
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { return (false, 0) }
            candidate = parent
        }
        return (false, 0)
    }

    private static func parserLocation(for options: CLIGlobalOptions) -> String {
        if let explicit = options.traceStreamerURL { return explicit.path }
        let resolver = TraceStreamerResolver()
        let appCandidate = TraceStreamerResolver.appBundleExecutableURL(
            bundleURL: resolver.appBundleURL
        )
        if FileManager.default.fileExists(atPath: appCandidate.path) {
            return appCandidate.path
        }
        if let executable = resolver.cliExecutableURL,
            let candidate = TraceStreamerResolver.cliLibexecURL(cliExecutableURL: executable),
            FileManager.default.fileExists(atPath: candidate.path)
        {
            return candidate.path
        }
        return "unavailable"
    }

    private static var isSupportedArchitecture: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    private static var architectureName: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unsupported"
        #endif
    }

    private func traceOperand(_ command: CLICommand) throws -> String {
        guard case .summary(let trace, _) = command else {
            throw ArkTraceError(
                code: .internalError,
                stage: .request,
                message: "Trace operand is unavailable",
                details: ["reason": "requestPayloadMismatch"]
            )
        }
        return trace
    }
}

struct CLIStoragePaths: Sendable {
    let stagingDirectory: URL
    let cacheDirectory: URL
}
