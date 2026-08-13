import ArkTraceCore
import Foundation

public struct CLIApplication: Sendable {
    private let parser: CLIArgumentParser
    private let renderer: CLIHumanRenderer
    private let machineEncoder: CLIMachineEncoder
    private let executor: any CLICommandExecuting
    private let machineToolProvider: @Sendable () throws -> CLIMachineTool
    private let beforeSuccessCommit: (@Sendable () -> Void)?

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
        beforeSuccessCommit = nil
    }

    init(
        parser: CLIArgumentParser = CLIArgumentParser(),
        renderer: CLIHumanRenderer = CLIHumanRenderer(),
        machineEncoder: CLIMachineEncoder = CLIMachineEncoder(),
        executor: any CLICommandExecuting = CLIUnavailableCommandExecutor(),
        machineToolProvider: @escaping @Sendable () throws -> CLIMachineTool,
        beforeSuccessCommit: (@Sendable () -> Void)? = nil
    ) {
        self.parser = parser
        self.renderer = renderer
        self.machineEncoder = machineEncoder
        self.executor = executor
        self.machineToolProvider = machineToolProvider
        self.beforeSuccessCommit = beforeSuccessCommit
    }

    @discardableResult
    public func run(
        arguments: [String],
        writer: any CLIOutputWriting
    ) async -> Int32 {
        var invocation: CLIInvocation?
        let machineHint = CLIArgumentParser.machinePresentationHint(arguments)
        var machineStdoutCommitAttempted = false
        var machineTool: CLIMachineTool?
        do {
            if machineHint.json {
                machineTool = try machineToolProvider()
            }
            let parsedInvocation = try parser.parse(arguments)
            invocation = parsedInvocation
            switch parsedInvocation.command {
            case .help:
                if parsedInvocation.options.json {
                    let output = try machineUtilityOutput(
                        invocation: parsedInvocation,
                        tool: try requiredMachineTool(machineTool),
                        result: .object([
                            "commands": .array([
                                "doctor", "inspect", "summary", "processes", "threads",
                            ].map(CLIJSONValue.string)),
                            "usage": .string("arktrace [global-options] <command> [command-options]"),
                        ])
                    )
                    beforeSuccessCommit?()
                    try Task.checkCancellation()
                    machineStdoutCommitAttempted = true
                    try writer.writeStdout(output)
                } else {
                    beforeSuccessCommit?()
                    try Task.checkCancellation()
                    try writer.writeStdout(renderer.help())
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
                    try Task.checkCancellation()
                    machineStdoutCommitAttempted = true
                    try writer.writeStdout(output)
                } else {
                    beforeSuccessCommit?()
                    try Task.checkCancellation()
                    try writer.writeStdout(renderer.version())
                }
            default:
                let output = try await executor.execute(parsedInvocation)
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
                            tool: try requiredMachineTool(machineTool)
                        ),
                        pretty: parsedInvocation.options.pretty,
                        maximumBytes: parsedInvocation.options.limits.maxOutputBytes
                    )
                } else {
                    stdout = output.stdout
                }
                beforeSuccessCommit?()
                try Task.checkCancellation()
                if !output.stderr.isEmpty { try writer.writeStderr(output.stderr) }
                // A synchronous writer can block after the success payload was
                // prepared. Treat completion of the diagnostic write as a new
                // cancellation boundary before committing stdout.
                try Task.checkCancellation()
                if !stdout.isEmpty {
                    machineStdoutCommitAttempted = parsedInvocation.options.json
                    try writer.writeStdout(stdout)
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
        machineHint: (json: Bool, pretty: Bool, maximumOutputBytes: Int),
        machineTool: CLIMachineTool?,
        machineStdoutCommitAttempted: Bool,
        writer: any CLIOutputWriting
    ) -> ArkTraceError {
        let error = error.normalizedForPublicContract()
        guard machineHint.json, !machineStdoutCommitAttempted,
            let machineTool
        else {
            try? writer.writeStderr(renderer.error(error))
            return error
        }
        let request = (try? invocation?.machineRequest())
            ?? CLIMachineRequest.hint(for: arguments)
        let maximumBytes = invocation?.options.limits.maxOutputBytes
            ?? machineHint.maximumOutputBytes
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
                try? writer.writeStderr(renderer.error(outputLimit))
            }
            return outputLimit
        } catch {
            let fallback = ArkTraceError(
                code: .internalError,
                stage: .encoding,
                message: "Machine error output failed"
            )
            try? writer.writeStderr(renderer.error(fallback))
            return fallback
        }
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
}
