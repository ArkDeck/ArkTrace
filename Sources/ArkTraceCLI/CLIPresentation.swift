import ArkTraceAnalysis
import ArkTraceCore
import ArkTraceStore
import CoreFoundation
import Foundation

struct CLIHumanDoctorDetails: Sendable {
    let toolVersion: String
    let toolBuildRevision: String?
    let operatingSystem: String
    let architecture: String
    let parserLocation: String
    let parserIdentity: TraceParserIdentity?
    let sqlite: TraceSQLiteRuntimeInfo
    let cacheLocation: String
    let cacheWritable: Bool
    let cacheFreeBytes: UInt64
    let schemaAdapterVersion: String
}

package struct CLIHumanRenderer: Sendable {
    private static let maximumTerminalFieldBytes = 4_096

    package init() {}

    package func help() -> Data {
        Data(
            ("""
            Usage: arktrace [global-options] <command> [command-options]

            Commands:
              licenses
              doctor [--self-test]
              inspect <trace>
              summary <trace> [--start-ns <n> --end-ns <n>]
              processes <trace> [--pid <pid>] [--name <text>] [--limit <n>]
              threads <trace> [filters] [--limit <n>]
              query <trace> --view <view> --start-ns <n> --end-ns <n> [filters]
              context <trace> (--timestamp-ns <n> --window-ms <n> |
                               --start-ns <n> --end-ns <n>) [filters]
              analyze <trace> --kind <kind> [--start-ns <n> --end-ns <n>]

            Global options:
              --json  --pretty  --timeout-ms <n>
              --max-rows <n>  --max-events <n>  --max-output-bytes <n>
              --trace-streamer <absolute-path>  --no-cache
              --version  --help
            """ + "\n").utf8
        )
    }

    package func version() -> Data {
        Data("\(ArkTraceCLITool.name) \(ArkTraceCLITool.version)\n".utf8)
    }

    package func error(_ error: ArkTraceError) -> Data {
        Data("error: \(error.code.rawValue): \(error.message)\n".utf8)
    }

    static func doctor(
        _ page: BoundedPage<CLIMachineDoctorCheck>,
        details: CLIHumanDoctorDetails
    ) -> Data {
        var lines = [
            "ArkTrace doctor",
            "Tool: \(terminalField(details.toolVersion)) build "
                + "\(details.toolBuildRevision.map(terminalField) ?? "unavailable")",
            "OS: \(terminalField(details.operatingSystem))",
            "Architecture: \(terminalField(details.architecture))",
            "TraceStreamer path: \(terminalField(details.parserLocation))",
        ]
        if let parser = details.parserIdentity {
            lines += [
                "TraceStreamer identity: \(terminalField(parser.reportedVersion)) "
                    + "\(terminalField(parser.upstreamRevision))",
                "TraceStreamer SHA-256: \(terminalField(parser.binarySHA256))",
                "TraceStreamer architecture: \(terminalField(parser.architecture))",
            ]
        }
        lines += [
            "SQLite: \(terminalField(details.sqlite.version)) "
                + "threadSafe=\(details.sqlite.isThreadSafe)",
            "Cache: \(terminalField(details.cacheLocation)) writable=\(details.cacheWritable)"
                + " freeBytes=\(details.cacheFreeBytes)",
            "Schema adapter: \(terminalField(details.schemaAdapterVersion))",
        ]
        lines += page.items.map {
            "[\(terminalField($0.status.rawValue))] \(terminalField($0.name))"
        }
        if page.truncated { lines.append("… checks truncated") }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static func inspect(_ snapshot: CLIMachineTraceSnapshot) -> Data {
        let metadata = snapshot.metadata
        let capabilities = [
            ("cpuScheduling", metadata.capabilities.cpuScheduling),
            ("threadStates", metadata.capabilities.threadStates),
            ("namedSlices", metadata.capabilities.namedSlices),
            ("cpuCounters", metadata.capabilities.cpuCounters),
            ("processCounters", metadata.capabilities.processCounters),
        ].filter(\.1).map(\.0).joined(separator: ",")
        return Data(([
            "Trace SHA-256: \(metadata.traceSHA256)",
            "Bytes: \(metadata.sourceByteCount)",
            "Duration ns: \(metadata.durationNs)",
            "Parser: \(metadata.parser.name) \(metadata.parser.reportedVersion)",
            "Schema: \(metadata.schemaFingerprint)",
            "Capabilities: \(capabilities.isEmpty ? "none" : capabilities)",
            "Data quality: \(metadata.dataQuality.status.rawValue)",
            "Cache hit: \(snapshot.cacheHit ? "yes" : "no")",
        ].joined(separator: "\n") + "\n").utf8)
    }

    static func summary(_ summary: TraceSummary) -> Data {
        func value(_ value: Int64?) -> String { value.map(String.init) ?? "unavailable" }
        var lines = [
            "Range ns: [\(summary.range.startNs), \(summary.range.endNs))",
            "Duration ns: \(summary.durationNs)",
            "CPUs: \(value(summary.cpuCount))",
            "Processes: \(summary.processCount)",
            "Threads: \(summary.threadCount)",
            "CPU slices: \(value(summary.cpuSliceCount))",
            "Thread states: \(value(summary.threadStateCount))",
            "Named slices: \(value(summary.namedSliceCount))",
            "Counter series: \(value(summary.counterSeriesCount))",
        ]
        if let counts = summary.eventCountBySource {
            lines += counts.map {
                "Event source \(terminalField($0.source)): \($0.count)"
            }
        }
        if !summary.truncatedSections.isEmpty {
            lines.append(
                "Truncated: " + summary.truncatedSections.map(\.rawValue).joined(separator: ",")
            )
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static func processes(_ page: BoundedPage<TraceProcess>) -> Data {
        var lines = ["IPID\tPID\tNAME\tSTART_NS\tEND_NS\tTHREADS"]
        lines += page.items.map {
            "\($0.key.ipid)\t\($0.pid)\t\($0.name.map(terminalField) ?? "-")\t"
                + "\($0.startNs.map(String.init) ?? "-")\t"
                + "\($0.endNs.map(String.init) ?? "-")\t"
                + "\($0.threadCount.map(String.init) ?? "-")"
        }
        if page.truncated { lines.append("… processes truncated") }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static func threads(_ page: BoundedPage<TraceThread>) -> Data {
        var lines = ["ITID\tIPID\tPID\tTID\tNAME\tSTART_NS\tEND_NS\tMAIN"]
        lines += page.items.map {
            "\($0.key.itid)\t\($0.processKey?.ipid.description ?? "-")\t"
                + "\($0.pid.map(String.init) ?? "-")\t\($0.tid)\t"
                + "\($0.name.map(terminalField) ?? "-")\t"
                + "\($0.startNs.map(String.init) ?? "-")\t"
                + "\($0.endNs.map(String.init) ?? "-")\t"
                + "\($0.isMainThread.map(String.init) ?? "-")"
        }
        if page.truncated { lines.append("… threads truncated") }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static func query(
        _ result: TraceAgentQueryResult,
        maximumBytes: Int
    ) throws -> Data {
        var output = try BoundedHumanOutput(maximumBytes: maximumBytes)
        try output.append("View: \(result.view.rawValue)")
        try output.append("Range ns: [\(result.range.startNs), \(result.range.endNs))")
        try output.append("Capability available: \(result.capabilityAvailable)")
        switch result.view {
        case .cpuSlices:
            for item in result.cpuSlices {
                try output.append(
                    "\(item.startNs)\t\(item.endNs)\tcpu=\(item.cpu)\tevent="
                        + "\(item.key.table.rawValue):\(item.key.rowID)"
                )
            }
        case .threadStates:
            for item in result.threadStates {
                try output.append(
                    "\(item.startNs)\t\(item.endNs)\tstate="
                        + "\(terminalField(item.state))\tevent="
                        + "\(item.key.table.rawValue):\(item.key.rowID)"
                )
            }
        case .slices:
            for item in result.slices {
                try output.append(
                    "\(item.startNs)\t\(item.endNs)\tname="
                        + "\(terminalField(item.name))\tevent="
                        + "\(item.key.table.rawValue):\(item.key.rowID)"
                )
            }
        case .counters:
            for item in result.counters {
                try output.append(
                    "\(item.sample.timestampNs)\tvalue=\(item.sample.value)\tname="
                        + "\(terminalField(item.name))\tevent="
                        + "\(item.sample.key.table.rawValue):\(item.sample.key.rowID)"
                )
            }
        }
        if result.truncated { try output.append("… result truncated") }
        return output.data
    }

    static func context(
        _ context: TraceContext,
        maximumBytes: Int
    ) throws -> Data {
        var output = try BoundedHumanOutput(maximumBytes: maximumBytes)
        try output.append("Range ns: [\(context.range.startNs), \(context.range.endNs))")
        try output.append("Processes: \(context.processes.count)")
        try output.append("Threads: \(context.threads.count)")
        try output.append("CPU slices: \(context.cpuSlices.count)")
        try output.append("Thread states: \(context.threadStates.count)")
        try output.append("Named slices: \(context.slices.count)")
        try output.append(
            "Counter samples: \(context.counters.reduce(0) { $0 + $1.samples.count })"
        )
        try output.append("Data quality: \(context.dataQuality.status.rawValue)")
        try output.append("Truncated: \(context.truncation.truncated)")
        return output.data
    }

    static func analyze(
        _ kind: CLIAnalyzeKind,
        _ analysis: TraceDeterministicAnalysis,
        maximumBytes: Int
    ) throws -> Data {
        var output = try BoundedHumanOutput(maximumBytes: maximumBytes)
        try output.append("Analysis: \(kind.rawValue)")
        try output.append("Range ns: [\(analysis.range.startNs), \(analysis.range.endNs))")
        switch kind {
        case .cpu:
            for item in analysis.cpuUtilization {
                try output.append(
                    "cpu=\(item.cpu) runningNs=\(item.occupiedNs) "
                        + "rawRunningNs=\(item.rawRunningNs) slices=\(item.sliceCount)"
                )
            }
        case .scheduling:
            try output.append("Supported: \(analysis.schedulingLatency.supported)")
            try output.append("Count: \(analysis.schedulingLatency.count)")
            if let percentiles = analysis.schedulingLatency.percentiles {
                try output.append(
                    "p50=\(percentiles.p50Ns) p90=\(percentiles.p90Ns) "
                        + "p95=\(percentiles.p95Ns) p99=\(percentiles.p99Ns) "
                        + "max=\(percentiles.maxNs)"
                )
            }
        case .slices:
            for item in analysis.longSlices {
                try output.append(
                    "durationNs=\(item.range.durationNs) name=\(terminalField(item.name)) event=\(item.key.table.rawValue):\(item.key.rowID)"
                )
            }
        case .range:
            try output.append("CPUs: \(analysis.cpuUtilization.count)")
            try output.append("Top processes: \(analysis.topProcesses.count)")
            try output.append("Top threads: \(analysis.topThreads.count)")
            try output.append("State rows: \(analysis.threadStateDistribution.count)")
            try output.append("Long slices: \(analysis.longSlices.count)")
        case .hotIntervals:
            for item in analysis.hotIntervals {
                try output.append(
                    "[\(item.range.startNs),\(item.range.endNs)) score="
                        + "\(item.score.total) cpuBusyNs=\(item.score.cpuBusyNs)"
                )
            }
        }
        try output.append("Data quality: \(analysis.dataQuality.status.rawValue)")
        return output.data
    }

    /// Trace strings are data, not terminal markup. Render control and format
    /// scalars visibly and cap each expanded field so a single hostile value
    /// cannot create an unbounded intermediate human-output row.
    private static func terminalField(_ value: String) -> String {
        var rendered = ""
        var byteCount = 0
        let ellipsis = "…"
        let contentLimit = maximumTerminalFieldBytes - ellipsis.utf8.count

        for scalar in value.unicodeScalars {
            let component: String
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                component = "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            default:
                component = String(scalar)
            }
            let componentBytes = component.utf8.count
            guard byteCount + componentBytes <= contentLimit else {
                rendered += ellipsis
                return rendered
            }
            rendered += component
            byteCount += componentBytes
        }
        return rendered
    }

    private struct BoundedHumanOutput {
        private(set) var data = Data()
        let maximumBytes: Int

        init(maximumBytes: Int) throws {
            guard maximumBytes >= 0 else {
                throw ArkTraceError(
                    code: .outputLimitExceeded,
                    stage: .encoding,
                    message: "Human output exceeds its byte budget",
                    retryable: true
                )
            }
            self.maximumBytes = maximumBytes
        }

        mutating func append(_ line: String) throws {
            let bytes = Data((line + "\n").utf8)
            guard bytes.count <= maximumBytes - data.count else {
                throw ArkTraceError(
                    code: .outputLimitExceeded,
                    stage: .encoding,
                    message: "Human output exceeds its byte budget",
                    retryable: true,
                    details: ["maximumBytes": String(maximumBytes)]
                )
            }
            data.append(bytes)
        }
    }
}

/// Encoding policy is separate from human rendering. P2-T04 supplies the
/// versioned envelope models; this utility already fixes deterministic key
/// ordering and optional pretty formatting without writing to stdout itself.
package struct CLIMachineEncoder: Sendable {
    package init() {}


    /// Fully materializes and validates one canonical UTF-8 document before
    /// the caller attempts stdout. The byte budget includes the final newline.
    package func encode<T: Encodable>(
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
    package func validateDocument(_ data: Data, maximumBytes: Int) throws {
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

package protocol CLIOutputWriting: Sendable {
    func writeStdout(_ data: Data) throws
    func writeStderr(_ data: Data) throws
}

package struct CLIFileOutputWriter: CLIOutputWriting {
    package init() {}

    package func writeStdout(_ data: Data) throws {
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    package func writeStderr(_ data: Data) throws {
        try FileHandle.standardError.write(contentsOf: data)
    }
}

package struct CLICommandOutput: Sendable {
    /// Human-only presentation bytes. In `--json` mode the application ignores
    /// these bytes and encodes `machinePayload` itself.
    package let stdout: Data
    package let stderr: Data
    package let machinePayload: CLIMachineCommandPayload?

    package init(
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

package protocol CLICommandExecuting: Sendable {
    func execute(_ invocation: CLIInvocation) async throws -> CLICommandOutput
}

package struct CLIUnavailableCommandExecutor: CLICommandExecuting {
    package init() {}

    package func execute(_ invocation: CLIInvocation) async throws -> CLICommandOutput {
        throw ArkTraceError(
            code: .analysisUnsupported,
            stage: .analyzing,
            message: "This command is not available in the current CLI slice"
        )
    }
}

package enum CLIExitStatus {
    package static func status(for error: ArkTraceError) -> Int32 {
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
