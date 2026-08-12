import ArkTraceCLI
import ArkTraceCore
import ArkTraceParser
import Foundation
import XCTest

final class CLITests: XCTestCase {
    func testHelpAndVersionShortCircuitExecutionAndTraceParsing() async throws {
        let executor = RecordingExecutor()
        let application = CLIApplication(executor: executor)

        let helpWriter = MemoryWriter()
        let helpStatus = await application.run(
            arguments: ["--json", "--pretty", "inspect", "/does/not/exist", "--help"],
            writer: helpWriter
        )
        XCTAssertEqual(helpStatus, 0)
        XCTAssertTrue(helpWriter.stdoutString.hasPrefix("Usage: arktrace"))
        XCTAssertTrue(helpWriter.stdoutString.hasSuffix("--version  --help\n"))
        XCTAssertEqual(helpWriter.stderrString, "")

        let versionWriter = MemoryWriter()
        let versionStatus = await application.run(
            arguments: ["--version", "summary", "/does/not/exist"],
            writer: versionWriter
        )
        XCTAssertEqual(versionStatus, 0)
        XCTAssertEqual(versionWriter.stdoutString, "arktrace 0.1.0\n")
        XCTAssertEqual(versionWriter.stderrString, "")
        let helpVersionCallCount = await executor.callCount
        XCTAssertEqual(helpVersionCallCount, 0)
    }

    func testHelpAndVersionConflictIsStableUsageError() async {
        let writer = MemoryWriter()
        let status = await CLIApplication().run(
            arguments: ["--help", "--version"],
            writer: writer
        )
        XCTAssertEqual(status, 2)
        XCTAssertEqual(writer.stdoutString, "")
        XCTAssertEqual(
            writer.stderrString,
            "error: INVALID_ARGUMENT: --help and --version cannot be combined\n"
        )
    }

    func testHelpAndVersionStillValidateGlobalSyntax() async {
        let cases = [
            ["--help", "--help"],
            ["-h", "--help"],
            ["--version", "--version"],
            ["--help", "--pretty"],
            ["--help", "--unknown"],
            ["--version", "--timeout-ms", "99"],
            ["inspect", "trace", "--unknown", "--help"],
        ]
        for arguments in cases {
            let writer = MemoryWriter()
            let status = await CLIApplication().run(arguments: arguments, writer: writer)
            XCTAssertEqual(status, 2, "arguments: \(arguments)")
            XCTAssertEqual(writer.stdoutString, "", "arguments: \(arguments)")
            XCTAssertTrue(
                writer.stderrString.hasPrefix("error: INVALID_ARGUMENT:"),
                "arguments: \(arguments)"
            )
        }

        let terminatedWriter = MemoryWriter()
        let terminatedStatus = await CLIApplication().run(
            arguments: ["--help", "--", "--unknown"],
            writer: terminatedWriter
        )
        XCTAssertEqual(terminatedStatus, 0)
        XCTAssertTrue(terminatedWriter.stdoutString.hasPrefix("Usage: arktrace"))
    }

    func testGlobalOptionsAndSummaryRangeParseCanonically() throws {
        let invocation = try CLIArgumentParser().parse([
            "--json", "--pretty", "--timeout-ms", "100", "--max-rows", "5",
            "--max-events", "6", "--max-output-bytes", "1024",
            "--trace-streamer", "/tmp/trace_streamer", "--no-cache",
            "summary", "fixture.trace", "--start-ns", "1", "--end-ns", "2",
        ])

        XCTAssertTrue(invocation.options.json)
        XCTAssertTrue(invocation.options.pretty)
        XCTAssertTrue(invocation.options.noCache)
        XCTAssertEqual(invocation.options.limits, try CLILimits(
            timeoutMs: 100,
            maxRows: 5,
            maxEvents: 6,
            maxOutputBytes: 1_024
        ))
        XCTAssertEqual(invocation.options.traceStreamerURL?.path, "/tmp/trace_streamer")
        XCTAssertEqual(
            invocation.command,
            .summary(trace: "fixture.trace", range: try TraceTimeRange.query(startNs: 1, endNs: 2))
        )
    }

    func testLimitBoundariesAndPrettyCombinationAreValidated() throws {
        XCTAssertNoThrow(try CLILimits(
            timeoutMs: 120_000,
            maxRows: 100_000,
            maxEvents: 100_000,
            maxOutputBytes: 64 * 1_024 * 1_024
        ))
        for arguments in [
            ["--timeout-ms", "99", "inspect", "trace"],
            ["--max-rows", "100001", "inspect", "trace"],
            ["--max-events", "0", "inspect", "trace"],
            ["--max-output-bytes", "1023", "inspect", "trace"],
            ["--pretty", "inspect", "trace"],
        ] {
            XCTAssertThrowsError(try CLIArgumentParser().parse(arguments)) { error in
                XCTAssertEqual((error as? ArkTraceError)?.code, .invalidArgument)
            }
        }
    }

    func testDeveloperOverrideRequiresAbsolutePathAndStillUsesPinnedIdentityValidation() async throws {
        XCTAssertThrowsError(try CLIArgumentParser().parse([
            "--trace-streamer", "relative/parser", "doctor",
        ])) { error in
            XCTAssertEqual((error as? ArkTraceError)?.code, .invalidArgument)
        }

        let invocation = try CLIArgumentParser().parse([
            "--trace-streamer", "/definitely/missing/trace_streamer", "doctor",
        ])
        let parser = try invocation.options.resolveParser()
        do {
            _ = try await parser.identity()
            XCTFail("identity verification unexpectedly accepted a missing override")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .traceStreamerUnavailable)
        }
    }

    func testCommandFiltersAndDefaultLimitsParse() throws {
        XCTAssertEqual(
            try CLIArgumentParser().parse(["doctor", "--self-test"]).command,
            .doctor(selfTest: true)
        )
        XCTAssertEqual(
            try CLIArgumentParser().parse(["inspect", "trace"]).command,
            .inspect(trace: "trace")
        )
        XCTAssertEqual(
            try CLIArgumentParser().parse([
                "processes", "trace", "--pid", "7", "--name", "app", "--limit", "3",
            ]).command,
            .processes(trace: "trace", pid: 7, name: "app", limit: 3)
        )
        XCTAssertEqual(
            try CLIArgumentParser().parse([
                "threads", "trace", "--process-key", "9", "--thread-key", "11",
                "--name", "worker", "--limit", "4",
            ]).command,
            .threads(
                trace: "trace",
                processKey: 9,
                pid: nil,
                threadKey: 11,
                tid: nil,
                name: "worker",
                limit: 4
            )
        )
        XCTAssertEqual(
            try CLIArgumentParser().parse(["processes", "trace"]).command,
            .processes(trace: "trace", pid: nil, name: nil, limit: 10_000)
        )
    }

    func testTerminatorAllowsTraceOperandBeginningWithDashes() throws {
        XCTAssertEqual(
            try CLIArgumentParser().parse(["--", "inspect", "trace"]).command,
            .inspect(trace: "trace")
        )
        XCTAssertEqual(
            try CLIArgumentParser().parse(["inspect", "--", "--help"]).command,
            .inspect(trace: "--help")
        )
        XCTAssertEqual(
            try CLIArgumentParser().parse(["summary", "--", "--trace"]).command,
            .summary(trace: "--trace", range: nil)
        )
    }

    func testUnknownMissingDuplicateAndConflictingOptionsAreUsageErrors() {
        let cases = [
            ["mystery", "trace"],
            ["inspect"],
            ["summary", "trace", "--start-ns", "1"],
            ["processes", "trace", "--pid"],
            ["processes", "trace", "--pid", "1", "--pid", "2"],
            ["threads", "trace", "--process-key", "1", "--pid", "2"],
            ["threads", "trace", "--thread-key", "1", "--tid", "2"],
            ["inspect", "trace", "--unknown"],
        ]
        for arguments in cases {
            XCTAssertThrowsError(try CLIArgumentParser().parse(arguments)) { error in
                let typed = error as? ArkTraceError
                XCTAssertEqual(typed?.code, .invalidArgument, "arguments: \(arguments)")
                XCTAssertEqual(typed?.stage, .request, "arguments: \(arguments)")
            }
        }
    }

    func testUsageErrorMessagesAndDetailsAreStable() {
        assertUsageError(
            ["--mystery", "inspect", "trace"],
            message: "Unknown option",
            details: ["option": "--mystery"]
        )
        assertUsageError(
            ["processes", "trace", "--pid"],
            message: "Option requires a value",
            details: ["option": "--pid"]
        )
        assertUsageError(
            ["--json", "--json", "inspect", "trace"],
            message: "Option may only be specified once",
            details: ["option": "--json"]
        )
        assertUsageError(
            ["threads", "trace", "--process-key", "1", "--pid", "2"],
            message: "--process-key and --pid are mutually exclusive",
            details: [:]
        )
    }

    func testGlobalOptionDuplicatesAndLocalLimitCeilingAreRejected() {
        for arguments in [
            ["--json", "--json", "inspect", "trace"],
            ["--max-rows", "2", "processes", "trace", "--limit", "3"],
            ["--trace-streamer", "/tmp/a", "--trace-streamer", "/tmp/b", "doctor"],
        ] {
            XCTAssertThrowsError(try CLIArgumentParser().parse(arguments)) { error in
                XCTAssertEqual((error as? ArkTraceError)?.code, .invalidArgument)
            }
        }
    }

    func testArgumentBudgetsFailClosedWithBoundedDetails() {
        let excessiveCount = Array(repeating: "x", count: 257)
        XCTAssertThrowsError(try CLIArgumentParser().parse(excessiveCount)) { error in
            XCTAssertTrue((error as? ArkTraceError)?.details.isEmpty == true)
        }
        let huge = String(repeating: "x", count: 16 * 1_024 + 1)
        XCTAssertThrowsError(try CLIArgumentParser().parse([huge])) { error in
            XCTAssertTrue((error as? ArkTraceError)?.details.isEmpty == true)
        }
        let unknown = String(repeating: "x", count: 1_000)
        XCTAssertThrowsError(try CLIArgumentParser().parse([unknown])) { error in
            XCTAssertLessThanOrEqual((error as? ArkTraceError)?.details["command"]?.count ?? 999, 128)
        }
    }

    func testApplicationUsesInjectedWriterAndExecutorWithoutContamination() async {
        let executor = RecordingExecutor(output: CLICommandOutput(
            stdout: Data("result\n".utf8),
            stderr: Data("diagnostic\n".utf8)
        ))
        let writer = MemoryWriter()
        let status = await CLIApplication(executor: executor).run(
            arguments: ["inspect", "trace"],
            writer: writer
        )
        XCTAssertEqual(status, 0)
        XCTAssertEqual(writer.stdoutString, "result\n")
        XCTAssertEqual(writer.stderrString, "diagnostic\n")
        let callCount = await executor.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testApplicationMapsTypedCancellationAndInternalWriterFailure() async {
        let cancelledWriter = MemoryWriter()
        let cancelledStatus = await CLIApplication(executor: ThrowingExecutor(
            error: ArkTraceError(
                code: .cancelled,
                stage: .querying,
                message: "cancelled",
                retryable: true
            )
        )).run(arguments: ["inspect", "trace"], writer: cancelledWriter)
        XCTAssertEqual(cancelledStatus, 8)
        XCTAssertEqual(cancelledWriter.stdoutString, "")
        XCTAssertEqual(cancelledWriter.stderrString, "error: CANCELLED: cancelled\n")

        let writerStatus = await CLIApplication(executor: RecordingExecutor(
            output: CLICommandOutput(stdout: Data("x".utf8))
        )).run(arguments: ["inspect", "trace"], writer: FailingWriter())
        XCTAssertEqual(writerStatus, 9)
    }

    func testExitStatusMapsEveryStableFamily() {
        let expected: [(ArkTraceError.Code, Int32)] = [
            (.invalidArgument, 2),
            (.traceFileNotFound, 3), (.traceFileUnreadable, 3), (.traceFormatUnsupported, 3),
            (.traceStreamerUnavailable, 4), (.traceStreamerIdentityMismatch, 4),
            (.traceParseFailed, 4),
            (.traceSchemaUnsupported, 5), (.traceDatabaseInvalid, 5), (.traceCacheCorrupt, 5),
            (.queryFailed, 6), (.analysisUnsupported, 6),
            (.queryTimeout, 7), (.queryLimitExceeded, 7), (.outputLimitExceeded, 7),
            (.cancelled, 8), (.internalError, 9),
        ]
        XCTAssertEqual(expected.count, ArkTraceError.Code.allCases.count)
        for (code, status) in expected {
            XCTAssertEqual(CLIExitStatus.status(for: typedError(code)), status)
        }
    }

    func testMachineEncodingIsDeterministicAndSeparateFromHumanRendering() throws {
        struct Value: Codable, Equatable { let z: Int; let a: String }
        let value = Value(z: 2, a: "one")
        let compact = try CLIMachineEncoder().encode(value, pretty: false)
        XCTAssertEqual(compact, try CLIMachineEncoder().encode(value, pretty: false))
        XCTAssertEqual(String(decoding: compact, as: UTF8.self), #"{"a":"one","z":2}"#)
        let pretty = try CLIMachineEncoder().encode(value, pretty: true)
        XCTAssertTrue(String(decoding: pretty, as: UTF8.self).contains("\n"))
        XCTAssertNotEqual(pretty, CLIHumanRenderer().help())
    }

    private func assertUsageError(
        _ arguments: [String],
        message: String,
        details: [String: String]
    ) {
        XCTAssertThrowsError(try CLIArgumentParser().parse(arguments)) { error in
            let typed = error as? ArkTraceError
            XCTAssertEqual(typed?.code, .invalidArgument)
            XCTAssertEqual(typed?.stage, .request)
            XCTAssertEqual(typed?.message, message)
            XCTAssertEqual(typed?.details, details)
        }
    }
}

private func typedError(_ code: ArkTraceError.Code) -> ArkTraceError {
    ArkTraceError(code: code, stage: .request, message: "test")
}

private final class MemoryWriter: CLIOutputWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    var stdoutString: String {
        lock.withLock { String(decoding: stdout, as: UTF8.self) }
    }

    var stderrString: String {
        lock.withLock { String(decoding: stderr, as: UTF8.self) }
    }

    func writeStdout(_ data: Data) {
        lock.withLock { stdout.append(data) }
    }

    func writeStderr(_ data: Data) {
        lock.withLock { stderr.append(data) }
    }
}

private actor RecordingExecutor: CLICommandExecuting {
    private(set) var callCount = 0
    private let output: CLICommandOutput

    init(output: CLICommandOutput = CLICommandOutput()) {
        self.output = output
    }

    func execute(_ invocation: CLIInvocation) async throws -> CLICommandOutput {
        callCount += 1
        return output
    }
}

private struct ThrowingExecutor: CLICommandExecuting {
    let error: ArkTraceError

    func execute(_ invocation: CLIInvocation) async throws -> CLICommandOutput {
        throw error
    }
}

private struct FailingWriter: CLIOutputWriting {
    func writeStdout(_ data: Data) throws { throw WriterError() }
    func writeStderr(_ data: Data) throws { throw WriterError() }
}

private struct WriterError: Error {}
