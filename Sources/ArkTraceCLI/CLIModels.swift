import ArkTraceCore
import ArkTraceParser
import Foundation

public enum ArkTraceCLITool {
    public static let name = ArkTraceProduct.commandName
    public static let version = ArkTraceProduct.version
}

public struct CLILimits: Equatable, Sendable {
    public static let defaultTimeoutMs: Int64 = 30_000
    public static let defaultMaxRows = 10_000
    public static let defaultMaxEvents = 10_000
    public static let defaultMaxOutputBytes = 8 * 1_024 * 1_024

    public let timeoutMs: Int64
    public let maxRows: Int
    public let maxEvents: Int
    public let maxOutputBytes: Int

    public init(
        timeoutMs: Int64 = defaultTimeoutMs,
        maxRows: Int = defaultMaxRows,
        maxEvents: Int = defaultMaxEvents,
        maxOutputBytes: Int = defaultMaxOutputBytes
    ) throws {
        guard (100...120_000).contains(timeoutMs) else {
            throw CLIParsing.invalid("timeoutMs must be within 100...120000")
        }
        guard (1...100_000).contains(maxRows) else {
            throw CLIParsing.invalid("maxRows must be within 1...100000")
        }
        guard (1...100_000).contains(maxEvents) else {
            throw CLIParsing.invalid("maxEvents must be within 1...100000")
        }
        guard (1_024...(64 * 1_024 * 1_024)).contains(maxOutputBytes) else {
            throw CLIParsing.invalid("maxOutputBytes must be within 1024...67108864")
        }
        self.timeoutMs = timeoutMs
        self.maxRows = maxRows
        self.maxEvents = maxEvents
        self.maxOutputBytes = maxOutputBytes
    }
}

public struct CLIGlobalOptions: Equatable, Sendable {
    public let json: Bool
    public let pretty: Bool
    public let limits: CLILimits
    public let traceStreamerURL: URL?
    public let noCache: Bool

    public init(
        json: Bool,
        pretty: Bool,
        limits: CLILimits,
        traceStreamerURL: URL?,
        noCache: Bool
    ) throws {
        guard !pretty || json else {
            throw CLIParsing.invalid("--pretty requires --json")
        }
        self.json = json
        self.pretty = pretty
        self.limits = limits
        self.traceStreamerURL = traceStreamerURL
        self.noCache = noCache
    }

    /// Reuses the pinned resolver. An explicit developer path is configuration
    /// only here; TraceSession subsequently invokes async identity validation
    /// before parsing any source bytes.
    public func resolveParser(
        using resolver: TraceStreamerResolver = TraceStreamerResolver()
    ) throws -> TraceStreamerProcessParser {
        try resolver.resolve(explicitExecutableURL: traceStreamerURL)
    }
}

public enum CLICommand: Equatable, Sendable {
    case help
    case version
    case doctor(selfTest: Bool)
    case inspect(trace: String)
    case summary(trace: String, range: TraceTimeRange?)
    case processes(trace: String, pid: Int64?, name: String?, limit: Int)
    case threads(
        trace: String,
        processKey: Int64?,
        pid: Int64?,
        threadKey: Int64?,
        tid: Int64?,
        name: String?,
        limit: Int
    )
}

public struct CLIInvocation: Equatable, Sendable {
    public let options: CLIGlobalOptions
    public let command: CLICommand

    public init(options: CLIGlobalOptions, command: CLICommand) {
        self.options = options
        self.command = command
    }
}

enum CLIParsing {
    static func invalid(_ message: String, details: [String: String] = [:]) -> ArkTraceError {
        ArkTraceError(
            code: .invalidArgument,
            stage: .request,
            message: message,
            details: details
        )
    }
}
