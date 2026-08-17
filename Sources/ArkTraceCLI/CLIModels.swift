import ArkTraceAnalysis
import ArkTraceCore
import ArkTraceParser
import Foundation

package enum ArkTraceCLITool {
    package static let name = ArkTraceProduct.commandName
    package static let version = ArkTraceProduct.version
}

package struct CLILimits: Equatable, Sendable {
    package static let defaultTimeoutMs: Int64 = 30_000
    package static let defaultMaxRows = 10_000
    package static let defaultMaxEvents = 10_000
    package static let defaultMaxOutputBytes = 8 * 1_024 * 1_024

    package let timeoutMs: Int64
    package let maxRows: Int
    package let maxEvents: Int
    package let maxOutputBytes: Int

    package init(
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

package struct CLIGlobalOptions: Equatable, Sendable {
    package let json: Bool
    package let pretty: Bool
    package let limits: CLILimits
    package let traceStreamerURL: URL?
    package let noCache: Bool

    package init(
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
    package func resolveParser(
        using resolver: TraceStreamerResolver = TraceStreamerResolver()
    ) throws -> TraceStreamerProcessParser {
        try resolver.resolve(explicitExecutableURL: traceStreamerURL)
    }
}

package enum CLICommand: Equatable, Sendable {
    case help
    case version
    case licenses
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
    case query(trace: String, options: CLIQueryOptions)
    case context(trace: String, options: CLIContextOptions)
    case analyze(trace: String, options: CLIAnalyzeOptions)
}

package struct CLIQueryOptions: Equatable, Sendable {
    package let view: TraceAgentQueryView
    package let range: TraceTimeRange
    package let filters: TraceAgentQueryFilters
    package let limit: Int

    package init(
        view: TraceAgentQueryView,
        range: TraceTimeRange,
        filters: TraceAgentQueryFilters,
        limit: Int
    ) {
        self.view = view
        self.range = range
        self.filters = filters
        self.limit = limit
    }
}

package struct CLIContextOptions: Equatable, Sendable {
    package let time: TraceContextTimeSelection
    package let filters: TraceAgentQueryFilters

    package init(time: TraceContextTimeSelection, filters: TraceAgentQueryFilters) {
        self.time = time
        self.filters = filters
    }
}

package enum CLIAnalyzeKind: String, Codable, CaseIterable, Hashable, Sendable {
    case cpu
    case scheduling
    case slices
    case range
    case hotIntervals = "hot-intervals"
}

package struct CLIAnalyzeOptions: Equatable, Sendable {
    package let kind: CLIAnalyzeKind
    package let range: TraceTimeRange?
    package let filters: TraceAgentQueryFilters
    package let thresholdNs: Int64
    package let limit: Int

    package init(
        kind: CLIAnalyzeKind,
        range: TraceTimeRange?,
        filters: TraceAgentQueryFilters,
        thresholdNs: Int64,
        limit: Int
    ) {
        self.kind = kind
        self.range = range
        self.filters = filters
        self.thresholdNs = thresholdNs
        self.limit = limit
    }
}

package struct CLIInvocation: Equatable, Sendable {
    package let options: CLIGlobalOptions
    package let command: CLICommand

    package init(options: CLIGlobalOptions, command: CLICommand) {
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
