import ArkTraceCore
import Foundation

public struct CLIApplication: Sendable {
    private let parser: CLIArgumentParser
    private let renderer: CLIHumanRenderer
    private let executor: any CLICommandExecuting

    public init(
        parser: CLIArgumentParser = CLIArgumentParser(),
        renderer: CLIHumanRenderer = CLIHumanRenderer(),
        executor: any CLICommandExecuting = CLIUnavailableCommandExecutor()
    ) {
        self.parser = parser
        self.renderer = renderer
        self.executor = executor
    }

    @discardableResult
    public func run(
        arguments: [String],
        writer: any CLIOutputWriting
    ) async -> Int32 {
        do {
            let invocation = try parser.parse(arguments)
            switch invocation.command {
            case .help:
                try writer.writeStdout(renderer.help())
            case .version:
                try writer.writeStdout(renderer.version())
            default:
                let output = try await executor.execute(invocation)
                if !output.stdout.isEmpty { try writer.writeStdout(output.stdout) }
                if !output.stderr.isEmpty { try writer.writeStderr(output.stderr) }
            }
            return 0
        } catch let error as ArkTraceError {
            try? writer.writeStderr(renderer.error(error))
            return CLIExitStatus.status(for: error)
        } catch is CancellationError {
            let error = ArkTraceError(
                code: .cancelled,
                stage: .request,
                message: "CLI operation was cancelled",
                retryable: true
            )
            try? writer.writeStderr(renderer.error(error))
            return 8
        } catch {
            let typed = ArkTraceError(
                code: .internalError,
                stage: .request,
                message: "CLI operation failed internally"
            )
            try? writer.writeStderr(renderer.error(typed))
            return 9
        }
    }
}
