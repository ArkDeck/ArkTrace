import ArkTraceCore
import Foundation

public struct CLIApplication: Sendable {
    struct LicenseSnapshot: Sendable {
        let notice: Data
        let productLicense: Data
        let files: [CLIVerifiedLicenseFile]

        static func load() throws -> LicenseSnapshot {
            let inventory = try CLILicenseResources.inventoryData()
            return LicenseSnapshot(
                notice: try CLILicenseResources.noticeData(),
                productLicense: try CLILicenseResources.productLicenseData(),
                files: try CLILicenseResources.verifiedLicenseFiles(
                    inventoryData: inventory
                )
            )
        }
    }

    private let parser: CLIArgumentParser
    private let renderer: CLIHumanRenderer
    private let machineEncoder: CLIMachineEncoder
    private let executor: any CLICommandExecuting
    private let machineToolProvider: @Sendable () throws -> CLIMachineTool
    private let licenseProvider: @Sendable () throws -> LicenseSnapshot
    private let deadlineClock: CLIDeadlineClock
    private let beforeSuccessCommit: (@Sendable () -> Void)?
    private let beforeEncoding: (@Sendable () async throws -> Void)?

    public init(
        parser: CLIArgumentParser = CLIArgumentParser(),
        renderer: CLIHumanRenderer = CLIHumanRenderer(),
        machineEncoder: CLIMachineEncoder = CLIMachineEncoder(),
        executor: any CLICommandExecuting = CLIProductionCommandExecutor()
    ) {
        self.parser = parser
        self.renderer = renderer
        self.machineEncoder = machineEncoder
        self.executor = executor
        machineToolProvider = Self.resolveCurrentMachineTool
        licenseProvider = LicenseSnapshot.load
        deadlineClock = .continuous
        beforeSuccessCommit = nil
        beforeEncoding = nil
    }

    init(
        parser: CLIArgumentParser = CLIArgumentParser(),
        renderer: CLIHumanRenderer = CLIHumanRenderer(),
        machineEncoder: CLIMachineEncoder = CLIMachineEncoder(),
        executor: any CLICommandExecuting = CLIUnavailableCommandExecutor(),
        machineToolProvider: @escaping @Sendable () throws -> CLIMachineTool,
        licenseProvider: @escaping @Sendable () throws -> LicenseSnapshot = LicenseSnapshot.load,
        deadlineClock: CLIDeadlineClock = .continuous,
        beforeSuccessCommit: (@Sendable () -> Void)? = nil,
        beforeEncoding: (@Sendable () async throws -> Void)? = nil
    ) {
        self.parser = parser
        self.renderer = renderer
        self.machineEncoder = machineEncoder
        self.executor = executor
        self.machineToolProvider = machineToolProvider
        self.licenseProvider = licenseProvider
        self.deadlineClock = deadlineClock
        self.beforeSuccessCommit = beforeSuccessCommit
        self.beforeEncoding = beforeEncoding
    }

    @discardableResult
    public func run(
        arguments: [String],
        writer: any CLIOutputWriting
    ) async -> Int32 {
        // Deadline expiries report the lifecycle stage they actually
        // interrupted; the executor advances this marker at phase boundaries.
        await CLIOperationStage.$active.withValue(CLIOperationStage(.request)) {
            await runCore(arguments: arguments, writer: writer)
        }
    }

    private func runCore(
        arguments: [String],
        writer: any CLIOutputWriting
    ) async -> Int32 {
        let invocationStart = deadlineClock.now()
        var invocation: CLIInvocation?
        let machineHint = CLIArgumentParser.machinePresentationHint(arguments)
        let operationDeadline = invocationStart.advanced(
            by: .milliseconds(machineHint.timeoutMs)
        )
        var machineStdoutCommitAttempted = false
        var committedStderrBytes = 0
        var machineTool: CLIMachineTool?
        do {
            let parsedInvocation: CLIInvocation
            do {
                parsedInvocation = try parser.parse(arguments)
            } catch {
                let parsingError = error
                // A parent cancellation (including a signal recorded before
                // the operation Task was installed) outranks malformed argv.
                // Deliberately do not check the wall-clock deadline here:
                // invalid syntax remains a usage error when only time elapsed.
                try Self.checkCancellation()
                // A malformed request remains a usage error. Resolve the
                // required machine tool identity only to encode that error;
                // the request's deadline does not turn invalid syntax into a
                // timeout before parsing has established an invocation.
                if machineHint.json {
                    do {
                        machineTool = try machineToolProvider()
                    } catch {
                        try Self.checkCancellation()
                        throw error
                    }
                }
                try Self.checkCancellation()
                throw parsingError
            }
            invocation = parsedInvocation
            if parsedInvocation.options.json {
                do {
                    machineTool = try await CLIOperationDeadline.run(
                        deadline: operationDeadline,
                        clock: deadlineClock
                    ) {
                        try machineToolProvider()
                    }
                } catch {
                    // Provenance hashing/read failures are still bounded by
                    // the invocation-wide deadline. Check before exposing the
                    // provider error so an expired request has stable timeout
                    // (or cancellation) priority on both success and failure.
                    try CLIOperationDeadline.check(operationDeadline, clock: deadlineClock)
                    throw error
                }
                try CLIOperationDeadline.check(operationDeadline, clock: deadlineClock)
            }
            switch parsedInvocation.command {
            case .help:
                if parsedInvocation.options.json {
                    let output = try machineUtilityOutput(
                        invocation: parsedInvocation,
                        tool: try requiredMachineTool(machineTool),
                        result: .object([
                            "commands": .array([
                                "doctor", "inspect", "summary", "processes", "threads",
                                "query", "context", "analyze", "licenses",
                            ].map(CLIJSONValue.string)),
                            "usage": .string("arktrace [global-options] <command> [command-options]"),
                        ])
                    )
                    beforeSuccessCommit?()
                    try CLIOperationDeadline.check(operationDeadline, clock: deadlineClock)
                    machineStdoutCommitAttempted = true
                    try writer.writeStdout(output)
                } else {
                    let output = renderer.help()
                    try Self.validateOutputBudget(
                        stdout: output,
                        stderr: Data(),
                        maximumBytes: parsedInvocation.options.limits.maxOutputBytes
                    )
                    beforeSuccessCommit?()
                    try CLIOperationDeadline.check(operationDeadline, clock: deadlineClock)
                    try writer.writeStdout(output)
                }
            case .version:
                if parsedInvocation.options.json {
                    let output = try machineUtilityOutput(
                        invocation: parsedInvocation,
                        tool: try requiredMachineTool(machineTool),
                        result: .object([
                            "name": .string(ArkTraceCLITool.name),
                            "version": .string(ArkTraceCLITool.version),
                            "buildRevision": .string(try requiredMachineTool(machineTool).buildRevision),
                        ])
                    )
                    beforeSuccessCommit?()
                    try CLIOperationDeadline.check(operationDeadline, clock: deadlineClock)
                    machineStdoutCommitAttempted = true
                    try writer.writeStdout(output)
                } else {
                    let output = renderer.version()
                    try Self.validateOutputBudget(
                        stdout: output,
                        stderr: Data(),
                        maximumBytes: parsedInvocation.options.limits.maxOutputBytes
                    )
                    beforeSuccessCommit?()
                    try CLIOperationDeadline.check(operationDeadline, clock: deadlineClock)
                    try writer.writeStdout(output)
                }
            case .licenses:
                let capturedMachineTool = machineTool
                let output = try await CLIOperationDeadline.run(
                    deadline: operationDeadline,
                    clock: deadlineClock
                ) {
                    let snapshot = try licenseProvider()
                    try Self.checkCancellation()
                    if parsedInvocation.options.json {
                        return try machineUtilityOutput(
                            invocation: parsedInvocation,
                            tool: try requiredMachineTool(capturedMachineTool),
                            result: .object([
                                "buildToolCount": .int64(Int64(CLILicenseResources.buildToolCount)),
                                "componentCount": .int64(Int64(CLILicenseResources.componentCount)),
                                "inventory": .string("license-inventory.json"),
                                "licenseFiles": .array(snapshot.files.map { file in
                                    .object([
                                        "byteCount": .int64(Int64(file.byteCount)),
                                        "licenseExpression": .string(file.licenseExpression),
                                        "owner": .string(file.owner),
                                        "resource": .string(file.resourcePath),
                                        "sha256": .string(file.sha256),
                                    ])
                                }),
                                "notice": .string("THIRD_PARTY_NOTICES.md"),
                                "productLicense": .string("LICENSE"),
                                "productLicenseBytes": .int64(Int64(snapshot.productLicense.count)),
                            ])
                        )
                    }
                    var human = Data("# ArkTrace Product License\n\n".utf8)
                    human.append(snapshot.productLicense)
                    human.append(Data("\n# ArkTrace Third-Party Notices\n\n".utf8))
                    human.append(snapshot.notice)
                    human.append(Data("\n# Bundled Third-Party License Files\n".utf8))
                    for file in snapshot.files {
                        try Self.checkCancellation()
                        human.append(Data("\n## \(file.owner) — \(file.licenseExpression)\n".utf8))
                        human.append(Data("Resource: \(file.resourcePath)\n\n".utf8))
                        human.append(file.data)
                        if human.last != UInt8(ascii: "\n") {
                            human.append(UInt8(ascii: "\n"))
                        }
                    }
                    try Self.validateOutputBudget(
                        stdout: human,
                        stderr: Data(),
                        maximumBytes: parsedInvocation.options.limits.maxOutputBytes
                    )
                    return human
                }
                beforeSuccessCommit?()
                try CLIOperationDeadline.check(operationDeadline, clock: deadlineClock)
                if parsedInvocation.options.json { machineStdoutCommitAttempted = true }
                try writer.writeStdout(output)
            default:
                let capturedMachineTool = machineTool
                let prepared = try await CLIOperationDeadline.run(
                    deadline: operationDeadline,
                    clock: deadlineClock
                ) {
                    let output = try await CLIMachineExecutionContext.$tool.withValue(
                        capturedMachineTool
                    ) {
                        try await executor.execute(parsedInvocation)
                    }
                    if let payload = output.machinePayload {
                        try payload.validate(for: parsedInvocation)
                    }
                    if let beforeEncoding { try await beforeEncoding() }
                    try Self.checkCancellation()
                    CLIOperationStage.active?.set(.encoding)
                    let stdout: Data
                    if parsedInvocation.options.json {
                        guard let payload = output.machinePayload else {
                            throw ArkTraceError(
                                code: .internalError,
                                stage: .encoding,
                                message: "Command executor omitted its typed machine payload",
                                details: ["reason": "missingTypedPayload"]
                            )
                        }
                        stdout = try machineEncoder.encode(
                            payload.envelope(
                                for: parsedInvocation,
                                tool: try requiredMachineTool(capturedMachineTool)
                            ),
                            pretty: parsedInvocation.options.pretty,
                            maximumBytes: parsedInvocation.options.limits.maxOutputBytes
                        )
                    } else {
                        stdout = output.stdout
                    }
                    try Self.validateOutputBudget(
                        stdout: stdout,
                        stderr: output.stderr,
                        maximumBytes: parsedInvocation.options.limits.maxOutputBytes
                    )
                    try Self.checkCancellation()
                    return CLIPreparedOutput(stdout: stdout, stderr: output.stderr)
                }
                beforeSuccessCommit?()
                try CLIOperationDeadline.check(operationDeadline, clock: deadlineClock)
                if !prepared.stderr.isEmpty {
                    try writer.writeStderr(prepared.stderr)
                    committedStderrBytes = prepared.stderr.count
                }
                // A synchronous writer can block after the success payload was
                // prepared. Treat completion of the diagnostic write as a new
                // cancellation boundary before committing stdout.
                try CLIOperationDeadline.check(operationDeadline, clock: deadlineClock)
                if !prepared.stdout.isEmpty {
                    machineStdoutCommitAttempted = parsedInvocation.options.json
                    try writer.writeStdout(prepared.stdout)
                }
            }
            return 0
        } catch let error as ArkTraceError {
            let emitted = emit(
                error: error,
                arguments: arguments,
                invocation: invocation,
                machineHint: machineHint,
                machineTool: machineTool,
                machineStdoutCommitAttempted: machineStdoutCommitAttempted,
                committedOutputBytes: committedStderrBytes,
                writer: writer
            )
            return CLIExitStatus.status(for: emitted)
        } catch is CancellationError {
            let error = ArkTraceError(
                code: .cancelled,
                stage: .request,
                message: "CLI operation was cancelled",
                retryable: true
            )
            let emitted = emit(
                error: error,
                arguments: arguments,
                invocation: invocation,
                machineHint: machineHint,
                machineTool: machineTool,
                machineStdoutCommitAttempted: machineStdoutCommitAttempted,
                committedOutputBytes: committedStderrBytes,
                writer: writer
            )
            return CLIExitStatus.status(for: emitted)
        } catch {
            let typed = ArkTraceError(
                code: .internalError,
                stage: .request,
                message: "CLI operation failed internally"
            )
            let emitted = emit(
                error: typed,
                arguments: arguments,
                invocation: invocation,
                machineHint: machineHint,
                machineTool: machineTool,
                machineStdoutCommitAttempted: machineStdoutCommitAttempted,
                committedOutputBytes: committedStderrBytes,
                writer: writer
            )
            return CLIExitStatus.status(for: emitted)
        }
    }

    private func machineUtilityOutput(
        invocation: CLIInvocation,
        tool: CLIMachineTool,
        result: CLIJSONValue
    ) throws -> Data {
        let envelope = CLIMachineSuccessEnvelope(
            tool: tool,
            trace: nil,
            request: try invocation.machineRequest(),
            limits: CLIMachineLimits(invocation.options.limits),
            result: result,
            dataQuality: try CLIMachineDataQuality(TraceDataQuality()),
            truncation: try CLIMachineTruncation(),
            provenance: nil
        )
        return try machineEncoder.encode(
            envelope,
            pretty: invocation.options.pretty,
            maximumBytes: invocation.options.limits.maxOutputBytes
        )
    }

    private func emit(
        error: ArkTraceError,
        arguments: [String],
        invocation: CLIInvocation?,
        machineHint: (
            json: Bool,
            pretty: Bool,
            maximumOutputBytes: Int,
            timeoutMs: Int64
        ),
        machineTool: CLIMachineTool?,
        machineStdoutCommitAttempted: Bool,
        committedOutputBytes: Int,
        writer: any CLIOutputWriting
    ) -> ArkTraceError {
        let emittedError: ArkTraceError
        if error.isOwnershipCleanupFailure || !CLISignalMonitor.hasPendingSignal {
            emittedError = error.normalizedForPublicContract()
        } else {
            emittedError = ArkTraceError(
                code: .cancelled,
                stage: error.stage,
                message: "CLI operation was cancelled",
                retryable: true
            )
        }
        let error = emittedError
        let configuredMaximum = invocation?.options.limits.maxOutputBytes
            ?? machineHint.maximumOutputBytes
        let remainingBytes = max(0, configuredMaximum - committedOutputBytes)
        guard machineHint.json, !machineStdoutCommitAttempted,
            let machineTool
        else {
            Self.writeStderrIfFits(
                renderer.error(error),
                maximumBytes: remainingBytes,
                writer: writer
            )
            return error
        }
        let request = (try? invocation?.machineRequest())
            ?? CLIMachineRequest.hint(for: arguments)
        let maximumBytes = remainingBytes
        let envelope = CLIMachineErrorEnvelope(
            tool: machineTool,
            request: request,
            error: error
        )
        do {
            let data = try machineEncoder.encode(
                envelope,
                pretty: invocation?.options.pretty ?? machineHint.pretty,
                maximumBytes: maximumBytes
            )
            try writer.writeStdout(data)
            return error
        } catch let encodingError as ArkTraceError
            where encodingError.code == .outputLimitExceeded
        {
            let outputLimit = ArkTraceError(
                code: .outputLimitExceeded,
                stage: .encoding,
                message: "Machine output exceeds its byte budget",
                retryable: true
            )
            do {
                let minimumEnvelope = CLIMachineErrorEnvelope(
                    tool: machineTool,
                    request: CLIMachineRequest.hint(for: [request.command]),
                    error: outputLimit
                )
                let data = try machineEncoder.encode(
                    minimumEnvelope,
                    pretty: false,
                    maximumBytes: maximumBytes
                )
                try writer.writeStdout(data)
            } catch {
                // stdout remains untouched when even the minimum legal
                // envelope cannot fit or cannot be committed.
                Self.writeStderrIfFits(
                    renderer.error(outputLimit),
                    maximumBytes: remainingBytes,
                    writer: writer
                )
            }
            return outputLimit
        } catch {
            let fallback = ArkTraceError(
                code: .internalError,
                stage: .encoding,
                message: "Machine error output failed"
            )
            Self.writeStderrIfFits(
                renderer.error(fallback),
                maximumBytes: remainingBytes,
                writer: writer
            )
            return fallback
        }
    }

    private static func writeStderrIfFits(
        _ data: Data,
        maximumBytes: Int,
        writer: any CLIOutputWriting
    ) {
        guard maximumBytes > 0, !data.isEmpty else { return }
        if data.count <= maximumBytes {
            try? writer.writeStderr(data)
            return
        }
        // Never exit non-zero with no diagnostic anywhere: clip the error
        // line to the remaining budget (on a UTF-8 boundary) instead of
        // silently discarding it.
        var clipped = data.prefix(maximumBytes)
        while let last = clipped.last, (last & 0xC0) == 0x80 {
            clipped = clipped.dropLast()
        }
        if let last = clipped.last, last >= 0xC0 {
            clipped = clipped.dropLast()
        }
        guard !clipped.isEmpty else { return }
        try? writer.writeStderr(Data(clipped))
    }

    private static func checkCancellation() throws {
        try CLISignalMonitor.checkPendingSignal()
        try Task.checkCancellation()
    }

    private static func resolveCurrentMachineTool() throws -> CLIMachineTool {
        let revision = try CLIExecutableIdentityResolver.current().resolveBuildRevision()
        return try CLIMachineTool(
            name: ArkTraceCLITool.name,
            version: ArkTraceCLITool.version,
            buildRevision: revision
        )
    }

    private func requiredMachineTool(_ tool: CLIMachineTool?) throws -> CLIMachineTool {
        guard let tool else {
            throw ArkTraceError(
                code: .internalError,
                stage: .encoding,
                message: "Machine tool identity is unavailable",
                details: ["reason": "missingToolIdentity"]
            )
        }
        return tool
    }

    private static func validateOutputBudget(
        stdout: Data,
        stderr: Data,
        maximumBytes: Int
    ) throws {
        let (combinedBytes, overflow) = stdout.count.addingReportingOverflow(stderr.count)
        guard !overflow, combinedBytes <= maximumBytes else {
            throw ArkTraceError(
                code: .outputLimitExceeded,
                stage: .encoding,
                message: "CLI output exceeds its byte budget",
                retryable: true,
                details: ["maximumBytes": String(maximumBytes)]
            )
        }
    }
}

private struct CLIPreparedOutput: Sendable {
    let stdout: Data
    let stderr: Data
}
