import ArkTraceCore
import Foundation

public struct CLIHumanRenderer: Sendable {
    public init() {}

    public func help() -> Data {
        Data(
            ("""
            Usage: arktrace [global-options] <command> [command-options]

            Commands:
              doctor [--self-test]
              inspect <trace>
              summary <trace> [--start-ns <n> --end-ns <n>]
              processes <trace> [--pid <pid>] [--name <text>] [--limit <n>]
              threads <trace> [filters] [--limit <n>]

            Global options:
              --json  --pretty  --timeout-ms <n>
              --max-rows <n>  --max-events <n>  --max-output-bytes <n>
              --trace-streamer <absolute-path>  --no-cache
              --version  --help
            """ + "\n").utf8
        )
    }

    public func version() -> Data {
        Data("\(ArkTraceCLITool.name) \(ArkTraceCLITool.version)\n".utf8)
    }

    public func error(_ error: ArkTraceError) -> Data {
        Data("error: \(error.code.rawValue): \(error.message)\n".utf8)
    }
}

/// Encoding policy is separate from human rendering. P2-T04 supplies the
/// versioned envelope models; this utility already fixes deterministic key
/// ordering and optional pretty formatting without writing to stdout itself.
public struct CLIMachineEncoder: Sendable {
    public init() {}

    public func encode<T: Encodable>(_ value: T, pretty: Bool) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return try encoder.encode(value)
    }
}

public protocol CLIOutputWriting: Sendable {
    func writeStdout(_ data: Data) throws
    func writeStderr(_ data: Data) throws
}

public struct CLIFileOutputWriter: CLIOutputWriting {
    public init() {}

    public func writeStdout(_ data: Data) throws {
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    public func writeStderr(_ data: Data) throws {
        try FileHandle.standardError.write(contentsOf: data)
    }
}

public struct CLICommandOutput: Sendable {
    public let stdout: Data
    public let stderr: Data

    public init(stdout: Data = Data(), stderr: Data = Data()) {
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CLICommandExecuting: Sendable {
    func execute(_ invocation: CLIInvocation) async throws -> CLICommandOutput
}

public struct CLIUnavailableCommandExecutor: CLICommandExecuting {
    public init() {}

    public func execute(_ invocation: CLIInvocation) async throws -> CLICommandOutput {
        throw ArkTraceError(
            code: .analysisUnsupported,
            stage: .request,
            message: "This command is not available in the current CLI slice"
        )
    }
}

public enum CLIExitStatus {
    public static func status(for error: ArkTraceError) -> Int32 {
        switch error.code {
        case .invalidArgument:
            2
        case .traceFileNotFound, .traceFileUnreadable, .traceFormatUnsupported:
            3
        case .traceStreamerUnavailable, .traceStreamerIdentityMismatch, .traceParseFailed:
            4
        case .traceSchemaUnsupported, .traceDatabaseInvalid, .traceCacheCorrupt:
            5
        case .queryFailed, .analysisUnsupported:
            6
        case .queryTimeout, .queryLimitExceeded, .outputLimitExceeded:
            7
        case .cancelled:
            8
        case .internalError:
            9
        }
    }
}
