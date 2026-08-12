import ArkTraceCore
import CoreFoundation
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
        try encode(value, pretty: pretty, maximumBytes: Int.max)
    }

    /// Fully materializes and validates one canonical UTF-8 document before
    /// the caller attempts stdout. The byte budget includes the final newline.
    public func encode<T: Encodable>(
        _ value: T,
        pretty: Bool,
        maximumBytes: Int
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(UInt8(ascii: "\n"))
        try validateDocument(data, maximumBytes: maximumBytes)
        return data
    }

    /// Validates one JSON object before the single stdout commit. Privacy is
    /// enforced by typed envelope/result fields plus forbidden semantic keys;
    /// arbitrary result strings are data and are never guessed to be paths or
    /// SQL from their spelling.
    public func validateDocument(_ data: Data, maximumBytes: Int) throws {
        guard maximumBytes >= 0, data.count <= maximumBytes else {
            throw ArkTraceError(
                code: .outputLimitExceeded,
                stage: .encoding,
                message: "Machine output exceeds its byte budget",
                retryable: true,
                details: [
                    "maximumBytes": String(max(0, maximumBytes)),
                    "requiredBytes": String(data.count),
                ]
            )
        }
        guard !data.isEmpty, String(data: data, encoding: .utf8) != nil,
            let object = try? JSONSerialization.jsonObject(with: data),
            object is [String: Any]
        else {
            throw Self.encodingFailure(reason: "invalidDocument")
        }
        try Self.validateJSONValue(object, key: nil)
    }

    private static func validateJSONValue(_ value: Any, key: String?) throws {
        if let object = value as? [String: Any] {
            for (childKey, childValue) in object {
                guard !Self.isForbiddenPrivacyKey(childKey) else {
                    throw encodingFailure(reason: "forbiddenField")
                }
                try validateJSONValue(childValue, key: childKey)
            }
            return
        }
        if let array = value as? [Any] {
            for child in array { try validateJSONValue(child, key: key) }
            return
        }
        if let key, key.hasSuffix("Ns"), !(value is NSNull) {
            guard let number = value as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID(),
                !CFNumberIsFloatType(number),
                Int64(number.stringValue) != nil
            else {
                throw encodingFailure(reason: "nonIntegerNanoseconds")
            }
        }
    }

    private static func isForbiddenPrivacyKey(_ key: String) -> Bool {
        let value = key.lowercased()
        return value == "path" || value.hasSuffix("path")
            || value == "sql" || value.contains("rawsql")
            || value == "environment" || value.contains("environmentdump")
            || value == "stderr" || value.contains("parserlog")
    }

    private static func encodingFailure(reason: String) -> ArkTraceError {
        ArkTraceError(
            code: .internalError,
            stage: .encoding,
            message: "Machine output violates the encoding contract",
            details: ["reason": reason]
        )
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
    /// Human-only presentation bytes. In `--json` mode the application ignores
    /// these bytes and encodes `machinePayload` itself.
    public let stdout: Data
    public let stderr: Data
    public let machinePayload: CLIMachineCommandPayload?

    public init(
        stdout: Data = Data(),
        stderr: Data = Data()
    ) {
        self.stdout = stdout
        self.stderr = stderr
        machinePayload = nil
    }

    init(
        stdout: Data = Data(),
        stderr: Data = Data(),
        machinePayload: CLIMachineCommandPayload
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.machinePayload = machinePayload
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
            stage: .analyzing,
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
