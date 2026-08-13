@testable import ArkTraceAnalysis
@testable import ArkTraceCLI
import ArkTraceCore
import Foundation
import XCTest

final class GoldenFixtureTests: XCTestCase {
    func testMachineJSONMatchesCommittedGoldenBytes() async throws {
        for fixture in try goldenCases() {
            let writer = GoldenWriter()
            let application = CLIApplication(
                executor: fixture.executor,
                machineToolProvider: { dynamicGoldenTool }
            )
            let status = await application.run(arguments: fixture.arguments, writer: writer)

            XCTAssertEqual(status, fixture.expectedStatus, fixture.name)
            XCTAssertEqual(writer.stdoutWrites, 1, fixture.name)
            XCTAssertEqual(writer.stderrWrites, 0, fixture.name)

            let actual = try normalizeBuildRevision(writer.stdout)
            XCTAssertFalse(
                String(decoding: actual, as: UTF8.self).contains("/Users/private"),
                "nested machine quality leaked a diagnostic path for \(fixture.name)"
            )
            if ProcessInfo.processInfo.environment["ARKTRACE_UPDATE_MACHINE_GOLDENS"] == "1" {
                let sourceDirectory = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .appendingPathComponent("Fixtures/MachineJSON", isDirectory: true)
                try actual.write(
                    to: sourceDirectory.appendingPathComponent("\(fixture.name).json"),
                    options: .atomic
                )
            }
            guard let resourceURL = Bundle.module.url(
                forResource: fixture.name,
                withExtension: "json",
                subdirectory: "Fixtures/MachineJSON"
            ) else {
                XCTFail("Missing committed golden \(fixture.name).json:\n\(String(decoding: actual, as: UTF8.self))")
                continue
            }
            let expected = try Data(contentsOf: resourceURL)
            XCTAssertEqual(
                actual,
                expected,
                "Machine JSON 1.0 compatibility changed for \(fixture.name):\n"
                    + String(decoding: actual, as: UTF8.self)
            )
        }
    }

    private func goldenCases() throws -> [GoldenCase] {
        var fixtures: [GoldenCase] = []
        for command in ["doctor", "inspect", "summary", "processes", "threads"] {
            let arguments = command == "doctor"
                ? ["--json", command]
                : ["--json", command, "trace"]
            for scenario in ["success", "empty", "truncated"] {
                let scenarioArguments = scenario == "truncated"
                    && ["processes", "threads"].contains(command)
                    ? ["--json", command, "trace", "--limit", "1"]
                    : scenario == "truncated" && command == "doctor"
                        ? ["--json", "--max-rows", "1", "doctor"]
                        : arguments
                fixtures.append(GoldenCase(
                    name: "\(command)-\(scenario)",
                    arguments: scenarioArguments,
                    expectedStatus: 0,
                    executor: GoldenExecutor(payload: try goldenPayload(
                        command: command,
                        scenario: scenario
                    ))
                ))
            }
            fixtures.append(GoldenCase(
                name: "\(command)-error",
                arguments: arguments,
                expectedStatus: 6,
                executor: GoldenErrorExecutor(error: ArkTraceError(
                    code: .queryFailed,
                    stage: .querying,
                    message: "fixture-only caller text",
                    retryable: false
                ))
            ))
        }
        for command in ["query", "context", "analyze"] {
            let arguments: [String]
            switch command {
            case "query":
                arguments = [
                    "--json", "query", "trace", "--view", "slices",
                    "--start-ns", "0", "--end-ns", "1000", "--limit", "1",
                ]
            case "context":
                arguments = [
                    "--json", "context", "trace", "--start-ns", "0",
                    "--end-ns", "1000",
                ]
            default:
                arguments = [
                    "--json", "analyze", "trace", "--kind", "range",
                    "--start-ns", "0", "--end-ns", "1000", "--limit", "1",
                ]
            }
            for scenario in ["success", "empty", "truncated"] {
                fixtures.append(GoldenCase(
                    name: "\(command)-\(scenario)",
                    arguments: arguments,
                    expectedStatus: 0,
                    executor: GoldenExecutor(payload: try goldenPayload(
                        command: command, scenario: scenario
                    ))
                ))
            }
            fixtures.append(GoldenCase(
                name: "\(command)-error",
                arguments: arguments,
                expectedStatus: 6,
                executor: GoldenErrorExecutor(error: ArkTraceError(
                    code: command == "query" ? .queryFailed : .analysisUnsupported,
                    stage: command == "query" ? .querying : .analyzing,
                    message: "fixture-only caller text",
                    retryable: false
                ))
            ))
        }
        fixtures.append(GoldenCase(
            name: "licenses-success",
            arguments: ["--json", "licenses"],
            expectedStatus: 0,
            executor: GoldenExecutor(payload: try goldenPayload(
                command: "doctor", scenario: "success"
            ))
        ))
        fixtures.append(GoldenCase(
            name: "licenses-error",
            arguments: ["--json", "--max-output-bytes", "1024", "licenses"],
            expectedStatus: 7,
            executor: GoldenExecutor(payload: try goldenPayload(
                command: "doctor", scenario: "success"
            ))
        ))
        return fixtures
    }

    private func normalizeBuildRevision(_ data: Data) throws -> Data {
        let text = String(decoding: data, as: UTF8.self)
        let needle = "\"buildRevision\":\"\(dynamicGoldenRevision)\""
        let replacement = "\"buildRevision\":\"\(normalizedGoldenRevision)\""
        let pieces = text.components(separatedBy: needle)
        guard pieces.count == 2 else {
            throw ArkTraceError(
                code: .internalError,
                stage: .encoding,
                message: "Golden output did not contain exactly one build revision"
            )
        }
        return Data(pieces.joined(separator: replacement).utf8)
    }
}

private struct GoldenCase {
    let name: String
    let arguments: [String]
    let expectedStatus: Int32
    let executor: any CLICommandExecuting
}

private let dynamicGoldenRevision = String(repeating: "a", count: 64)
private let normalizedGoldenRevision = String(repeating: "f", count: 64)
private let dynamicGoldenTool = try! CLIMachineTool(
    name: ArkTraceCLITool.name,
    version: ArkTraceCLITool.version,
    buildRevision: dynamicGoldenRevision
)

private func goldenPayload(
    command: String,
    scenario: String
) throws -> CLIMachineCommandPayload {
    let hasItem = scenario != "empty"
    let truncated = scenario == "truncated"
    switch command {
    case "doctor":
        return try .doctor(
            selfTest: false,
            checks: BoundedPage(
                items: hasItem ? [try CLIMachineDoctorCheck(
                    code: truncated ? "tool" : "sqlite",
                    name: truncated ? "ArkTrace tool" : "SQLite",
                    status: .ok
                )] : [],
                truncated: truncated
            )
        )
    case "inspect":
        let metadata = goldenMetadata(
            capabilities: scenario == "empty" ? goldenEmptyCapabilities : goldenCapabilities,
            quality: truncated ? TraceDataQuality(issues: [
                TraceDataQualityIssue(category: .probeTruncated, scope: "thread.start_ts"),
            ]) : TraceDataQuality()
        )
        return try .inspect(
            metadata: metadata,
            preparation: goldenPreparation(),
            cacheHit: hasItem
        )
    case "summary":
        let metadata = goldenMetadata()
        return try .summary(
            metadata: metadata,
            preparation: goldenPreparation(),
            summary: TraceSummary(
                range: try TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs),
                durationNs: metadata.durationNs,
                cpuCount: hasItem ? 1 : 0,
                processCount: hasItem ? 1 : 0,
                threadCount: hasItem ? 1 : 0,
                cpuSliceCount: hasItem ? 1 : 0,
                threadStateCount: hasItem ? 1 : 0,
                namedSliceCount: hasItem ? 1 : 0,
                counterSeriesCount: hasItem ? 1 : 0,
                eventCountBySource: hasItem
                    ? [TraceEventSourceCount(source: "sched_slice", count: 1)]
                    : [],
                capabilities: metadata.capabilities,
                schemaFingerprint: metadata.schemaFingerprint,
                dataQuality: metadata.dataQuality,
                truncatedSections: truncated ? [.threadStateCount] : []
            )
        )
    case "processes":
        return try .processes(
            metadata: goldenMetadata(),
            preparation: goldenPreparation(),
            page: BoundedPage(
                items: hasItem ? [TraceProcess(
                    key: ProcessKey(ipid: 101),
                    pid: 42,
                    name: "worker",
                    startNs: nil,
                    endNs: 1_000,
                    threadCount: 1
                )] : [],
                truncated: truncated
            )
        )
    case "threads":
        return try .threads(
            metadata: goldenMetadata(),
            preparation: goldenPreparation(),
            page: BoundedPage(
                items: hasItem ? [TraceThread(
                    key: ThreadKey(itid: 202),
                    processKey: ProcessKey(ipid: 101),
                    tid: 43,
                    pid: 42,
                    name: "worker-thread",
                    processName: "worker",
                    startNs: 5,
                    endNs: nil,
                    isMainThread: false
                )] : [],
                truncated: truncated
            )
        )
    case "query":
        let range = try TraceTimeRange.query(startNs: 0, endNs: 1_000)
        let item = TraceSlice(
            key: EventKey(table: .callstack, rowID: 303),
            range: try TraceTimeRange.query(startNs: 10, endNs: 20),
            threadKey: ThreadKey(itid: 202),
            processKey: ProcessKey(ipid: 101),
            pid: 42,
            tid: 43,
            processName: "worker",
            threadName: "worker-thread",
            name: "work",
            category: nil,
            depth: 1,
            parentEventKey: nil,
            isAsync: false,
            isOpenEnded: false
        )
        return try .query(
            metadata: goldenMetadata(),
            preparation: goldenPreparation(),
            result: TraceAgentQueryResult(
                view: .slices,
                range: range,
                capabilityAvailable: true,
                truncated: truncated,
                dataQuality: goldenMetadata().dataQuality,
                slices: hasItem ? [item] : []
            )
        )
    case "context":
        return try .context(
            metadata: goldenMetadata(),
            preparation: goldenPreparation(),
            context: try goldenContext(hasItem: hasItem, truncated: truncated)
        )
    case "analyze":
        return try .analyze(
            kind: .range,
            metadata: goldenMetadata(),
            preparation: goldenPreparation(),
            analysis: try goldenAnalysis(hasItem: hasItem, truncated: truncated)
        )
    default:
        throw ArkTraceError(
            code: .internalError,
            stage: .encoding,
            message: "Unknown golden command"
        )
    }
}

private func goldenContext(hasItem: Bool, truncated: Bool) throws -> TraceContext {
    let metadata = goldenMetadata()
    let range = try TraceTimeRange.query(startNs: 0, endNs: 1_000)
    let process = TraceProcess(
        key: ProcessKey(ipid: 101), pid: 42, name: "worker",
        startNs: nil, endNs: 1_000, threadCount: 1
    )
    let thread = TraceThread(
        key: ThreadKey(itid: 202), processKey: ProcessKey(ipid: 101),
        tid: 43, pid: 42, name: "worker-thread", processName: "worker",
        startNs: 5, endNs: nil, isMainThread: false
    )
    let slice = CpuSlice(
        key: EventKey(table: .schedSlice, rowID: 1),
        range: try TraceTimeRange.query(startNs: 10, endNs: 20),
        cpu: 0, threadKey: ThreadKey(itid: 202), processKey: ProcessKey(ipid: 101),
        tid: 43, pid: 42, threadName: "worker-thread", processName: "worker",
        endState: nil, priority: nil, isOpenEnded: false
    )
    let returned = hasItem ? 1 : 0
    let status = TraceContextSectionStatus(
        returnedCount: returned, matchedCount: returned, truncated: false
    )
    let cpuStatus = TraceContextSectionStatus(
        returnedCount: returned,
        matchedCount: truncated ? nil : returned,
        truncated: truncated
    )
    return TraceContext(
        range: range,
        processes: hasItem ? [process] : [],
        threads: hasItem ? [thread] : [],
        cpuSlices: hasItem ? [slice] : [],
        threadStates: [], slices: [], counters: [],
        summary: TraceSummary(
            range: range,
            durationNs: range.durationNs,
            cpuCount: hasItem ? 1 : 0,
            processCount: hasItem ? 1 : 0,
            threadCount: hasItem ? 1 : 0,
            cpuSliceCount: hasItem ? 1 : 0,
            threadStateCount: 0,
            namedSliceCount: 0,
            counterSeriesCount: 0,
            eventCountBySource: hasItem
                ? [TraceEventSourceCount(source: "sched_slice", count: 1)] : [],
            capabilities: metadata.capabilities,
            schemaFingerprint: metadata.schemaFingerprint,
            dataQuality: metadata.dataQuality,
            truncatedSections: []
        ),
        dataQuality: metadata.dataQuality,
        truncation: TraceContextTruncation(
            processes: status, threads: status, cpuSlices: cpuStatus,
            threadStates: .init(returnedCount: 0, matchedCount: 0, truncated: false),
            slices: .init(returnedCount: 0, matchedCount: 0, truncated: false),
            counters: .init(returnedCount: 0, matchedCount: 0, truncated: false),
            summary: .init(returnedCount: 1, matchedCount: 1, truncated: false),
            referenceOmittedByBudget: false
        )
    )
}

private func goldenAnalysis(
    hasItem: Bool,
    truncated: Bool
) throws -> TraceDeterministicAnalysis {
    let metadata = goldenMetadata()
    let range = try TraceTimeRange.query(startNs: 0, endNs: 1_000)
    let filters = TraceAgentQueryFilters.none
    let cpu = TraceCPUUtilization(
        cpu: 0, rawRunningNs: 10, occupiedNs: 10,
        sliceCount: 1, utilization: 0.01
    )
    let empty = TraceAnalysisSectionStatus(
        returnedCount: 0, matchedCount: 0, truncated: false
    )
    let cpuStatus = TraceAnalysisSectionStatus(
        returnedCount: hasItem ? 1 : 0,
        matchedCount: truncated ? nil : (hasItem ? 1 : 0),
        truncated: truncated
    )
    return TraceDeterministicAnalysis(
        kind: .deterministicBatch,
        parameters: TraceDeterministicAnalysisParameters(
            filters: filters,
            maximumCPUSlices: 10_000,
            maximumProcessSlices: 10_000,
            maximumThreadSlices: 10_000,
            maximumStateIntervals: 10_000,
            maximumNamedSlices: 10_000,
            maximumSchedulingEvents: 10_000,
            maximumHotEvents: 10_000,
            topProcessLimit: 1,
            topThreadLimit: 1,
            longSliceLimit: 1,
            schedulingSampleLimit: 1,
            hotIntervalLimit: 1,
            hotBucketCount: 100,
            minimumLongSliceDurationNs: 0,
            timeoutSeconds: 30,
            timeoutAttoseconds: 0
        ),
        range: range,
        cpuUtilization: hasItem ? [cpu] : [],
        topProcesses: [], topThreads: [], longSlices: [],
        threadStateDistribution: [],
        schedulingLatency: TraceSchedulingLatencyResult(
            supported: false,
            unsupportedReason: .capabilityUnavailable,
            count: 0,
            percentiles: nil,
            topSamples: [],
            truncated: false
        ),
        hotIntervals: [],
        sections: TraceDeterministicAnalysisSections(
            cpuUtilization: cpuStatus,
            topProcesses: empty,
            topThreads: empty,
            longSlices: empty,
            threadStateDistribution: empty,
            schedulingLatency: empty,
            hotIntervals: empty
        ),
        dataQuality: metadata.dataQuality
    )
}

private let goldenCapabilities = TraceCapabilities(
    cpuScheduling: true,
    threadStates: true,
    namedSlices: true,
    cpuCounters: true,
    processCounters: false
)

private let goldenEmptyCapabilities = TraceCapabilities(
    cpuScheduling: false,
    threadStates: false,
    namedSlices: false,
    cpuCounters: false,
    processCounters: false
)

private func goldenMetadata(
    capabilities: TraceCapabilities = goldenCapabilities,
    quality: TraceDataQuality = TraceDataQuality(issues: [
        TraceDataQualityIssue(
            category: .probeTruncated,
            scope: "thread.start_ts",
            message: "/Users/private/probe incomplete"
        ),
    ])
) -> TraceMetadata {
    TraceMetadata(
        traceSHA256: String(repeating: "1", count: 64),
        sourceByteCount: 2_048,
        durationNs: 1_000,
        sourceFormat: nil,
        parser: TraceParserIdentity(
            name: "trace_streamer",
            reportedVersion: "4.3.7",
            binarySHA256: String(repeating: "2", count: 64),
            upstreamRepository: "https://example.invalid/repository",
            upstreamRevision: String(repeating: "3", count: 40),
            architecture: "arm64",
            adapterVersion: "1",
            buildRecipeVersion: "1"
        ),
        schemaFingerprint: String(repeating: "4", count: 64),
        capabilities: capabilities,
        dataQuality: quality
    )
}

private func goldenPreparation() -> TraceDatabasePreparationResult {
    TraceDatabasePreparationResult(
        schemaAdapterVersion: "2",
        schemaFingerprint: String(repeating: "4", count: 64),
        indexVersion: 1,
        upstreamDatabaseSHA256: String(repeating: "5", count: 64),
        upstreamDatabaseByteCount: 4_096
    )
}

private final class GoldenWriter: CLIOutputWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var errors = Data()
    private var outputWriteCount = 0
    private var errorWriteCount = 0

    var stdout: Data { lock.withLock { output } }
    var stderr: Data { lock.withLock { errors } }
    var stdoutWrites: Int { lock.withLock { outputWriteCount } }
    var stderrWrites: Int { lock.withLock { errorWriteCount } }

    func writeStdout(_ data: Data) {
        lock.withLock {
            outputWriteCount += 1
            output.append(data)
        }
    }

    func writeStderr(_ data: Data) {
        lock.withLock {
            errorWriteCount += 1
            errors.append(data)
        }
    }
}

private struct GoldenExecutor: CLICommandExecuting {
    let payload: CLIMachineCommandPayload

    func execute(_ invocation: CLIInvocation) async throws -> CLICommandOutput {
        CLICommandOutput(machinePayload: payload)
    }
}

private struct GoldenErrorExecutor: CLICommandExecuting {
    let error: ArkTraceError

    func execute(_ invocation: CLIInvocation) async throws -> CLICommandOutput {
        throw error
    }
}

private extension CLIMachineCommandPayload {
    static func query(
        metadata: TraceMetadata,
        preparation: TraceDatabasePreparationResult,
        result: TraceAgentQueryResult
    ) throws -> Self {
        try query(bound: CLIMachineBoundTraceResult(
            snapshot: goldenSnapshot(metadata: metadata, preparation: preparation),
            value: result
        ))
    }

    static func context(
        metadata: TraceMetadata,
        preparation: TraceDatabasePreparationResult,
        context value: TraceContext
    ) throws -> Self {
        try Self.context(bound: CLIMachineBoundTraceResult(
            snapshot: goldenSnapshot(metadata: metadata, preparation: preparation),
            value: value
        ))
    }

    static func analyze(
        kind: CLIAnalyzeKind,
        metadata: TraceMetadata,
        preparation: TraceDatabasePreparationResult,
        analysis: TraceDeterministicAnalysis
    ) throws -> Self {
        try analyze(
            kind: kind,
            bound: CLIMachineBoundTraceResult(
                snapshot: goldenSnapshot(metadata: metadata, preparation: preparation),
                value: analysis
            )
        )
    }
}

private func goldenSnapshot(
    metadata: TraceMetadata,
    preparation: TraceDatabasePreparationResult
) throws -> CLIMachineTraceSnapshot {
    try CLIMachineTraceSnapshot(
        parsed: ParsedTrace(
            databaseURL: URL(fileURLWithPath: "/dev/null"),
            metadataSidecarURL: URL(fileURLWithPath: "/dev/null"),
            parser: metadata.parser,
            sourceSHA256: metadata.traceSHA256,
            sourceByteCount: metadata.sourceByteCount,
            databasePreparation: preparation
        ),
        metadata: metadata,
        cacheHit: false
    )
}
