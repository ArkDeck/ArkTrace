import ArkTraceAnalysis
import ArkTraceCore
import Foundation

package struct CLIArgumentParser: Sendable {
    static let maximumArgumentCount = 256
    static let maximumArgumentBytes = 16 * 1_024

    package init() {}

    /// Safe mode hint used only to choose the error presentation when full
    /// parsing fails. It never reads a trace or resolves a path.
    package static func requestsJSON(_ arguments: [String]) -> Bool {
        machinePresentationHint(arguments).json
    }

    static func machinePresentationHint(
        _ arguments: [String]
    ) -> (json: Bool, pretty: Bool, maximumOutputBytes: Int, timeoutMs: Int64) {
        var json = false
        var pretty = false
        var maximumOutputBytes = CLILimits.defaultMaxOutputBytes
        var timeoutMs = CLILimits.defaultTimeoutMs
        var index = 0
        let bounded = boundedPresentationArguments(arguments)
        while index < bounded.count {
            let token = bounded[index]
            guard isWithinArgumentByteBudget(token) else {
                index += 1
                continue
            }
            if token == "--" { break }
            if token == "--json" { json = true }
            if token == "--pretty" { pretty = true }
            if token == "--max-output-bytes", index + 1 < bounded.count,
                isWithinArgumentByteBudget(bounded[index + 1]),
                let value = Int(bounded[index + 1]),
                (1_024...(64 * 1_024 * 1_024)).contains(value)
            {
                maximumOutputBytes = value
                index += 1
            }
            if token == "--timeout-ms", index + 1 < bounded.count,
                isWithinArgumentByteBudget(bounded[index + 1]),
                let value = Int64(bounded[index + 1]),
                (100...120_000).contains(value)
            {
                timeoutMs = value
                index += 1
            }
            index += 1
        }
        return (json, pretty && json, maximumOutputBytes, timeoutMs)
    }

    static func boundedPresentationArguments(_ arguments: [String]) -> ArraySlice<String> {
        arguments.prefix(maximumArgumentCount + 1)
    }

    static func isWithinArgumentByteBudget(_ argument: String) -> Bool {
        argument.utf8.prefix(maximumArgumentBytes + 1).count <= maximumArgumentBytes
    }

    package func parse(_ arguments: [String]) throws -> CLIInvocation {
        guard arguments.count <= Self.maximumArgumentCount,
            arguments.allSatisfy(Self.isWithinArgumentByteBudget)
        else {
            throw CLIParsing.invalid("CLI argument budget was exceeded")
        }

        var json = false
        var pretty = false
        var noCache = false
        var hasHelp = false
        var hasVersion = false
        var timeoutMs = CLILimits.defaultTimeoutMs
        var maxRows = CLILimits.defaultMaxRows
        var maxEvents = CLILimits.defaultMaxEvents
        var maxOutputBytes = CLILimits.defaultMaxOutputBytes
        var traceStreamerURL: URL?
        var seen: Set<String> = []
        var remaining: [String] = []
        var terminatorReached = false
        var index = 0

        while index < arguments.count {
            let token = arguments[index]
            if terminatorReached {
                remaining.append(token)
                index += 1
                continue
            }
            if token == "--" {
                terminatorReached = true
                remaining.append(token)
                index += 1
                continue
            }
            switch token {
            case "--help", "-h":
                try markOnce("--help", seen: &seen)
                hasHelp = true
            case "--version":
                try markOnce(token, seen: &seen)
                hasVersion = true
            case "--json":
                try markOnce(token, seen: &seen)
                json = true
            case "--pretty":
                try markOnce(token, seen: &seen)
                pretty = true
            case "--no-cache":
                try markOnce(token, seen: &seen)
                noCache = true
            case "--timeout-ms":
                try markOnce(token, seen: &seen)
                timeoutMs = try int64Value(after: token, in: arguments, index: &index)
            case "--max-rows":
                try markOnce(token, seen: &seen)
                maxRows = try intValue(after: token, in: arguments, index: &index)
            case "--max-events":
                try markOnce(token, seen: &seen)
                maxEvents = try intValue(after: token, in: arguments, index: &index)
            case "--max-output-bytes":
                try markOnce(token, seen: &seen)
                maxOutputBytes = try intValue(after: token, in: arguments, index: &index)
            case "--trace-streamer":
                try markOnce(token, seen: &seen)
                let path = try stringValue(after: token, in: arguments, index: &index)
                guard path.utf8.count <= 4_096,
                    (path as NSString).isAbsolutePath
                else {
                    throw CLIParsing.invalid("--trace-streamer requires an absolute path")
                }
                traceStreamerURL = URL(filePath: path).standardizedFileURL
            default:
                if remaining.isEmpty, token.hasPrefix("-") {
                    throw CLIParsing.invalid(
                        "Unknown option",
                        details: ["option": boundedToken(token)]
                    )
                }
                remaining.append(token)
            }
            index += 1
        }

        guard !(hasHelp && hasVersion) else {
            throw CLIParsing.invalid("--help and --version cannot be combined")
        }

        let limits = try CLILimits(
            timeoutMs: timeoutMs,
            maxRows: maxRows,
            maxEvents: maxEvents,
            maxOutputBytes: maxOutputBytes
        )
        let options = try CLIGlobalOptions(
            json: json,
            pretty: pretty,
            limits: limits,
            traceStreamerURL: traceStreamerURL,
            noCache: noCache
        )
        if hasHelp || hasVersion {
            try validateActionTail(remaining)
            return CLIInvocation(options: options, command: hasHelp ? .help : .version)
        }
        // A leading `--` terminated option parsing for the entire invocation;
        // the command name still dispatches, but every later token is an
        // operand — never re-parsed as an option (docs/CLI.md).
        var optionsTerminated = false
        if remaining.first == "--" {
            remaining.removeFirst()
            optionsTerminated = true
        }
        let command = try parseCommand(
            remaining,
            limits: limits,
            optionsTerminated: optionsTerminated
        )
        return CLIInvocation(options: options, command: command)
    }

    /// Help/version skip command operand validation and all trace access, but
    /// still reject option-looking tokens which were not recognized as valid
    /// global syntax before the explicit `--` terminator.
    private func validateActionTail(_ arguments: [String]) throws {
        for token in arguments {
            if token == "--" { return }
            if token.hasPrefix("-") {
                throw CLIParsing.invalid(
                    "Unknown option",
                    details: ["option": boundedToken(token)]
                )
            }
        }
    }

    private func parseCommand(
        _ arguments: [String],
        limits: CLILimits,
        optionsTerminated: Bool = false
    ) throws -> CLICommand {
        guard let name = arguments.first else {
            throw CLIParsing.invalid("A command is required")
        }
        let tail = Array(arguments.dropFirst())
        switch name {
        case "licenses":
            var positionals: [String] = []
            try parseLocal(tail, optionsTerminated: optionsTerminated) { _, _, _ in
                false
            } positional: { positionals.append($0) }
            guard positionals.isEmpty else {
                throw CLIParsing.invalid("licenses does not accept operands")
            }
            return .licenses
        case "doctor":
            var selfTest = false
            var seen: Set<String> = []
            var positionals: [String] = []
            try parseLocal(tail, optionsTerminated: optionsTerminated) { option, _, _ in
                guard option == "--self-test" else { return false }
                try markOnce(option, seen: &seen)
                selfTest = true
                return true
            } positional: { positionals.append($0) }
            guard positionals.isEmpty else {
                throw CLIParsing.invalid("doctor does not accept a trace operand")
            }
            return .doctor(selfTest: selfTest)
        case "inspect":
            var positionals: [String] = []
            try parseLocal(tail, optionsTerminated: optionsTerminated) { _, _, _ in
                false
            } positional: { positionals.append($0) }
            return .inspect(trace: try exactlyOneTrace(positionals, command: name))
        case "summary":
            return try parseSummary(tail, optionsTerminated: optionsTerminated)
        case "processes":
            return try parseProcesses(
                tail,
                globalMaxRows: limits.maxRows,
                optionsTerminated: optionsTerminated
            )
        case "threads":
            return try parseThreads(
                tail,
                globalMaxRows: limits.maxRows,
                optionsTerminated: optionsTerminated
            )
        case "query":
            return try parseQuery(tail, limits: limits, optionsTerminated: optionsTerminated)
        case "context":
            return try parseContext(tail, limits: limits, optionsTerminated: optionsTerminated)
        case "analyze":
            return try parseAnalyze(tail, limits: limits, optionsTerminated: optionsTerminated)
        default:
            throw CLIParsing.invalid(
                "Unknown command",
                details: ["command": boundedToken(name)]
            )
        }
    }

    private func parseQuery(
        _ arguments: [String],
        limits: CLILimits,
        optionsTerminated: Bool
    ) throws -> CLICommand {
        var view: TraceAgentQueryView?
        var start: Int64?
        var end: Int64?
        var filter = ParsedAgentFilters()
        var limit = min(limits.maxRows, limits.maxEvents)
        var seen: Set<String> = []
        var positionals: [String] = []
        try parseLocal(arguments, optionsTerminated: optionsTerminated) { option, values, index in
            switch option {
            case "--view":
                try markOnce(option, seen: &seen)
                let raw = try stringValue(after: option, in: values, index: &index)
                view = try queryView(raw)
            case "--start-ns":
                try markOnce(option, seen: &seen)
                start = try int64Value(after: option, in: values, index: &index)
            case "--end-ns":
                try markOnce(option, seen: &seen)
                end = try int64Value(after: option, in: values, index: &index)
            case "--limit":
                try markOnce(option, seen: &seen)
                limit = try localEventLimit(
                    after: option, in: values, index: &index,
                    maximum: min(limits.maxRows, limits.maxEvents)
                )
            default:
                return try parseAgentFilter(
                    option, values: values, index: &index, seen: &seen, filter: &filter
                )
            }
            return true
        } positional: { positionals.append($0) }
        guard let view, let start, let end else {
            throw CLIParsing.invalid("query requires --view, --start-ns, and --end-ns")
        }
        let range = try TraceTimeRange.query(startNs: start, endNs: end)
        let filters = try filter.value()
        _ = try TraceAgentQueryRequest(
            view: view, range: range, filters: filters, limit: limit
        )
        let options = CLIQueryOptions(
            view: view,
            range: range,
            filters: filters,
            limit: limit
        )
        return .query(
            trace: try exactlyOneTrace(positionals, command: "query"),
            options: options
        )
    }

    private func parseContext(
        _ arguments: [String],
        limits: CLILimits,
        optionsTerminated: Bool
    ) throws -> CLICommand {
        var timestamp: Int64?
        var windowMs: Int64?
        var start: Int64?
        var end: Int64?
        var filter = ParsedAgentFilters()
        var seen: Set<String> = []
        var positionals: [String] = []
        try parseLocal(arguments, optionsTerminated: optionsTerminated) { option, values, index in
            switch option {
            case "--timestamp-ns":
                try markOnce(option, seen: &seen)
                timestamp = try nonnegativeInt64(after: option, in: values, index: &index)
            case "--window-ms":
                try markOnce(option, seen: &seen)
                windowMs = try nonnegativeInt64(after: option, in: values, index: &index)
            case "--start-ns":
                try markOnce(option, seen: &seen)
                start = try int64Value(after: option, in: values, index: &index)
            case "--end-ns":
                try markOnce(option, seen: &seen)
                end = try int64Value(after: option, in: values, index: &index)
            default:
                return try parseAgentFilter(
                    option, values: values, index: &index, seen: &seen, filter: &filter
                )
            }
            return true
        } positional: { positionals.append($0) }
        let time: TraceContextTimeSelection
        if let timestamp, let windowMs, start == nil, end == nil {
            let (windowNs, overflow) = windowMs.multipliedReportingOverflow(by: 1_000_000)
            guard !overflow, windowNs > 0 else {
                throw CLIParsing.invalid("--window-ms is outside the supported nanosecond range")
            }
            time = .timestamp(
                timestampNs: timestamp,
                windowBeforeNs: windowNs,
                windowAfterNs: windowNs
            )
        } else if let start, let end, timestamp == nil, windowMs == nil {
            time = .range(try TraceTimeRange.query(startNs: start, endNs: end))
        } else {
            throw CLIParsing.invalid(
                "context requires exactly one timestamp/window or start/end range"
            )
        }
        return .context(
            trace: try exactlyOneTrace(positionals, command: "context"),
            options: CLIContextOptions(time: time, filters: try filter.value())
        )
    }

    private func parseAnalyze(
        _ arguments: [String],
        limits: CLILimits,
        optionsTerminated: Bool
    ) throws -> CLICommand {
        var kind: CLIAnalyzeKind?
        var start: Int64?
        var end: Int64?
        var threshold: Int64 = 0
        var limit = min(1_000, min(limits.maxRows, limits.maxEvents))
        var filter = ParsedAgentFilters()
        var seen: Set<String> = []
        var positionals: [String] = []
        try parseLocal(arguments, optionsTerminated: optionsTerminated) { option, values, index in
            switch option {
            case "--kind":
                try markOnce(option, seen: &seen)
                let raw = try stringValue(after: option, in: values, index: &index)
                guard let value = CLIAnalyzeKind(rawValue: raw) else {
                    throw CLIParsing.invalid("Unknown analysis kind")
                }
                kind = value
            case "--start-ns":
                try markOnce(option, seen: &seen)
                start = try int64Value(after: option, in: values, index: &index)
            case "--end-ns":
                try markOnce(option, seen: &seen)
                end = try int64Value(after: option, in: values, index: &index)
            case "--threshold-ns":
                try markOnce(option, seen: &seen)
                threshold = try nonnegativeInt64(after: option, in: values, index: &index)
            case "--limit":
                try markOnce(option, seen: &seen)
                limit = try localEventLimit(
                    after: option, in: values, index: &index,
                    maximum: min(1_000, min(limits.maxRows, limits.maxEvents))
                )
            default:
                return try parseAgentFilter(
                    option, values: values, index: &index, seen: &seen, filter: &filter
                )
            }
            return true
        } positional: { positionals.append($0) }
        guard let kind, (start == nil) == (end == nil) else {
            throw CLIParsing.invalid("analyze requires --kind and a complete optional range")
        }
        let range = try start.map { start in
            try TraceTimeRange.query(startNs: start, endNs: end!)
        }
        let analysisFilters = try filter.value()
        guard analysisFilters.cpu == nil, analysisFilters.rawState == nil,
            analysisFilters.normalizedState == nil, analysisFilters.name == nil,
            analysisFilters.minimumDurationNs == nil, analysisFilters.depth == nil,
            analysisFilters.counterFilterID == nil
        else {
            throw CLIParsing.invalid("analyze only accepts process/thread identity filters")
        }
        return .analyze(
            trace: try exactlyOneTrace(positionals, command: "analyze"),
            options: CLIAnalyzeOptions(
                kind: kind, range: range, filters: analysisFilters,
                thresholdNs: threshold, limit: limit
            )
        )
    }

    private struct ParsedAgentFilters {
        var cpu: Int64?
        var processKey: Int64?
        var pid: Int64?
        var threadKey: Int64?
        var tid: Int64?
        var rawState: String?
        var normalizedState: TraceThreadState?
        var name: String?
        var nameMatch: TraceAgentTextMatch = .exact
        var minimumDurationNs: Int64?
        var depth: Int64?
        var counterFilterID: Int64?

        func value() throws -> TraceAgentQueryFilters {
            guard processKey == nil || pid == nil else {
                throw CLIParsing.invalid("--process-key and --pid are mutually exclusive")
            }
            guard threadKey == nil || tid == nil else {
                throw CLIParsing.invalid("--thread-key and --tid are mutually exclusive")
            }
            return try TraceAgentQueryFilters(
                cpu: cpu,
                processKey: processKey.map(ProcessKey.init(ipid:)), pid: pid,
                threadKey: threadKey.map(ThreadKey.init(itid:)), tid: tid,
                rawState: rawState, normalizedState: normalizedState,
                name: name, nameMatch: nameMatch,
                minimumDurationNs: minimumDurationNs, depth: depth,
                counterFilterID: counterFilterID
            )
        }
    }

    private func parseAgentFilter(
        _ option: String,
        values: [String],
        index: inout Int,
        seen: inout Set<String>,
        filter: inout ParsedAgentFilters
    ) throws -> Bool {
        switch option {
        case "--cpu":
            try markOnce(option, seen: &seen)
            filter.cpu = try nonnegativeInt64(after: option, in: values, index: &index)
        case "--process-key":
            try markOnce(option, seen: &seen)
            filter.processKey = try stableKeyValue(after: option, in: values, index: &index)
        case "--pid":
            try markOnce(option, seen: &seen)
            filter.pid = try nonnegativeInt64(after: option, in: values, index: &index)
        case "--thread-key":
            try markOnce(option, seen: &seen)
            filter.threadKey = try stableKeyValue(after: option, in: values, index: &index)
        case "--tid":
            try markOnce(option, seen: &seen)
            filter.tid = try nonnegativeInt64(after: option, in: values, index: &index)
        case "--raw-state":
            try markOnce(option, seen: &seen)
            filter.rawState = try boundedAgentText(after: option, in: values, index: &index)
        case "--state":
            try markOnce(option, seen: &seen)
            let raw = try stringValue(after: option, in: values, index: &index)
            guard let value = TraceThreadState(rawValue: raw) else {
                throw CLIParsing.invalid("Unknown normalized thread state")
            }
            filter.normalizedState = value
        case "--name":
            try markOnce(option, seen: &seen)
            filter.name = try boundedAgentText(after: option, in: values, index: &index)
        case "--name-match":
            try markOnce(option, seen: &seen)
            let raw = try stringValue(after: option, in: values, index: &index)
            guard let value = TraceAgentTextMatch(rawValue: raw) else {
                throw CLIParsing.invalid("Unknown name match mode")
            }
            filter.nameMatch = value
        case "--min-duration-ns":
            try markOnce(option, seen: &seen)
            filter.minimumDurationNs = try nonnegativeInt64(
                after: option, in: values, index: &index
            )
        case "--depth":
            try markOnce(option, seen: &seen)
            filter.depth = try nonnegativeInt64(after: option, in: values, index: &index)
        case "--filter-id":
            try markOnce(option, seen: &seen)
            filter.counterFilterID = try int64Value(after: option, in: values, index: &index)
        default:
            return false
        }
        return true
    }

    private func queryView(_ raw: String) throws -> TraceAgentQueryView {
        switch raw {
        case "cpu-slices": .cpuSlices
        case "thread-states": .threadStates
        case "slices": .slices
        case "counters": .counters
        default: throw CLIParsing.invalid("Unknown query view")
        }
    }

    private func parseSummary(
        _ arguments: [String],
        optionsTerminated: Bool = false
    ) throws -> CLICommand {
        var start: Int64?
        var end: Int64?
        var seen: Set<String> = []
        var positionals: [String] = []
        try parseLocal(arguments, optionsTerminated: optionsTerminated) { option, values, index in
            switch option {
            case "--start-ns":
                try markOnce(option, seen: &seen)
                start = try int64Value(after: option, in: values, index: &index)
            case "--end-ns":
                try markOnce(option, seen: &seen)
                end = try int64Value(after: option, in: values, index: &index)
            default:
                return false
            }
            return true
        } positional: { positionals.append($0) }
        let trace = try exactlyOneTrace(positionals, command: "summary")
        guard (start == nil) == (end == nil) else {
            throw CLIParsing.invalid("--start-ns and --end-ns must be provided together")
        }
        let range: TraceTimeRange?
        if let start, let end {
            range = try TraceTimeRange.query(startNs: start, endNs: end)
        } else {
            range = nil
        }
        return .summary(trace: trace, range: range)
    }

    private func parseProcesses(
        _ arguments: [String],
        globalMaxRows: Int,
        optionsTerminated: Bool = false
    ) throws -> CLICommand {
        var pid: Int64?
        var name: String?
        var limit = globalMaxRows
        var seen: Set<String> = []
        var positionals: [String] = []
        try parseLocal(arguments, optionsTerminated: optionsTerminated) { option, values, index in
            switch option {
            case "--pid":
                try markOnce(option, seen: &seen)
                pid = try nonnegativeInt64(after: option, in: values, index: &index)
            case "--name":
                try markOnce(option, seen: &seen)
                name = try boundedText(after: option, in: values, index: &index)
            case "--limit":
                try markOnce(option, seen: &seen)
                limit = try localLimit(after: option, in: values, index: &index, maximum: globalMaxRows)
            default:
                return false
            }
            return true
        } positional: { positionals.append($0) }
        return .processes(
            trace: try exactlyOneTrace(positionals, command: "processes"),
            pid: pid,
            name: name,
            limit: limit
        )
    }

    private func parseThreads(
        _ arguments: [String],
        globalMaxRows: Int,
        optionsTerminated: Bool = false
    ) throws -> CLICommand {
        var processKey: Int64?
        var pid: Int64?
        var threadKey: Int64?
        var tid: Int64?
        var name: String?
        var limit = globalMaxRows
        var seen: Set<String> = []
        var positionals: [String] = []
        try parseLocal(arguments, optionsTerminated: optionsTerminated) { option, values, index in
            switch option {
            case "--process-key":
                try markOnce(option, seen: &seen)
                processKey = try stableKeyValue(after: option, in: values, index: &index)
            case "--pid":
                try markOnce(option, seen: &seen)
                pid = try nonnegativeInt64(after: option, in: values, index: &index)
            case "--thread-key":
                try markOnce(option, seen: &seen)
                threadKey = try stableKeyValue(after: option, in: values, index: &index)
            case "--tid":
                try markOnce(option, seen: &seen)
                tid = try nonnegativeInt64(after: option, in: values, index: &index)
            case "--name":
                try markOnce(option, seen: &seen)
                name = try boundedText(after: option, in: values, index: &index)
            case "--limit":
                try markOnce(option, seen: &seen)
                limit = try localLimit(after: option, in: values, index: &index, maximum: globalMaxRows)
            default:
                return false
            }
            return true
        } positional: { positionals.append($0) }
        guard processKey == nil || pid == nil else {
            throw CLIParsing.invalid("--process-key and --pid are mutually exclusive")
        }
        guard threadKey == nil || tid == nil else {
            throw CLIParsing.invalid("--thread-key and --tid are mutually exclusive")
        }
        return .threads(
            trace: try exactlyOneTrace(positionals, command: "threads"),
            processKey: processKey,
            pid: pid,
            threadKey: threadKey,
            tid: tid,
            name: name,
            limit: limit
        )
    }

    private func parseLocal(
        _ arguments: [String],
        optionsTerminated: Bool = false,
        option: (String, [String], inout Int) throws -> Bool,
        positional: (String) -> Void
    ) throws {
        var index = 0
        var terminatorReached = optionsTerminated
        while index < arguments.count {
            let token = arguments[index]
            if token == "--", !terminatorReached {
                terminatorReached = true
            } else if token.hasPrefix("--"), !terminatorReached {
                guard try option(token, arguments, &index) else {
                    throw CLIParsing.invalid(
                        "Unknown option",
                        details: ["option": boundedToken(token)]
                    )
                }
            } else {
                positional(token)
            }
            index += 1
        }
    }

    private func exactlyOneTrace(_ values: [String], command: String) throws -> String {
        guard values.count == 1, !values[0].isEmpty else {
            throw CLIParsing.invalid("\(command) requires exactly one trace operand")
        }
        return values[0]
    }

    private func markOnce(_ option: String, seen: inout Set<String>) throws {
        guard seen.insert(option).inserted else {
            throw CLIParsing.invalid(
                "Option may only be specified once",
                details: ["option": boundedToken(option)]
            )
        }
    }

    private func stringValue(
        after option: String, in arguments: [String], index: inout Int
    ) throws -> String {
        let next = index + 1
        guard next < arguments.count, !arguments[next].hasPrefix("--") else {
            throw CLIParsing.invalid(
                "Option requires a value",
                details: ["option": boundedToken(option)]
            )
        }
        index = next
        return arguments[next]
    }

    private func int64Value(
        after option: String, in arguments: [String], index: inout Int
    ) throws -> Int64 {
        let raw = try stringValue(after: option, in: arguments, index: &index)
        guard let value = Int64(raw) else {
            throw CLIParsing.invalid(
                "Option requires an Int64 value",
                details: ["option": boundedToken(option)]
            )
        }
        return value
    }

    private func intValue(
        after option: String, in arguments: [String], index: inout Int
    ) throws -> Int {
        let raw = try stringValue(after: option, in: arguments, index: &index)
        guard let value = Int(raw) else {
            throw CLIParsing.invalid(
                "Option requires an integer value",
                details: ["option": boundedToken(option)]
            )
        }
        return value
    }

    private func nonnegativeInt64(
        after option: String, in arguments: [String], index: inout Int
    ) throws -> Int64 {
        let value = try int64Value(after: option, in: arguments, index: &index)
        guard value >= 0 else {
            throw CLIParsing.invalid("Identity and PID/TID filters must be nonnegative")
        }
        return value
    }

    private func stableKeyValue(
        after option: String, in arguments: [String], index: inout Int
    ) throws -> Int64 {
        let value = try int64Value(after: option, in: arguments, index: &index)
        guard value != 0 else {
            throw CLIParsing.invalid("Stable identity 0 is the absent sentinel")
        }
        return value
    }

    private func boundedAgentText(
        after option: String, in arguments: [String], index: inout Int
    ) throws -> String {
        let value = try stringValue(after: option, in: arguments, index: &index)
        guard !value.isEmpty, value.utf8.count <= 256 else {
            throw CLIParsing.invalid("Agent text filter must contain 1...256 UTF-8 bytes")
        }
        return value
    }

    private func boundedText(
        after option: String, in arguments: [String], index: inout Int
    ) throws -> String {
        let value = try stringValue(after: option, in: arguments, index: &index)
        guard !value.isEmpty, value.utf8.count <= 4_096 else {
            throw CLIParsing.invalid("Text filter must contain 1...4096 UTF-8 bytes")
        }
        return value
    }

    private func localLimit(
        after option: String,
        in arguments: [String],
        index: inout Int,
        maximum: Int
    ) throws -> Int {
        let value = try intValue(after: option, in: arguments, index: &index)
        guard value >= 1, value <= maximum else {
            throw CLIParsing.invalid("--limit must be within 1...global maxRows")
        }
        return value
    }

    private func localEventLimit(
        after option: String,
        in arguments: [String],
        index: inout Int,
        maximum: Int
    ) throws -> Int {
        let value = try intValue(after: option, in: arguments, index: &index)
        guard value >= 1, value <= maximum else {
            throw CLIParsing.invalid("--limit exceeds the effective row/event bound")
        }
        return value
    }

    private func boundedToken(_ token: String) -> String {
        String(token.unicodeScalars.prefix(128)).replacingOccurrences(of: "\n", with: " ")
    }
}
