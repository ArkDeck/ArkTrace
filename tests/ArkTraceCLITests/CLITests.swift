import ArkTraceAnalysis
import ArkTraceCLIResourceFixtures
import ArkTraceCore
import ArkTraceParser
import Foundation
import XCTest

@testable import ArkTraceCLI

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
        let helpDocument = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: helpWriter.stdoutData) as? [String: Any]
        )
        XCTAssertEqual(helpDocument["schemaVersion"] as? String, "1.0")
        XCTAssertEqual(
            ((helpDocument["request"] as? [String: Any])?["command"] as? String),
            "help"
        )
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
            try CLIArgumentParser().parse(["licenses"]).command,
            .licenses
        )
        XCTAssertThrowsError(try CLIArgumentParser().parse(["licenses", "unexpected"])) {
            XCTAssertEqual(($0 as? ArkTraceError)?.code, .invalidArgument)
        }
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

    func testPhase4CommandsParseClosedTypedRequestsAndCanonicalEchoes() throws {
        let query = try CLIArgumentParser().parse([
            "--json", "--max-rows", "4", "--max-events", "3",
            "query", "trace", "--view", "slices", "--start-ns", "10",
            "--end-ns", "20", "--process-key", "-7", "--thread-key", "-9",
            "--name", "work", "--name-match", "prefix",
            "--min-duration-ns", "2", "--depth", "1", "--limit", "3",
        ])
        let queryFilters = try TraceAgentQueryFilters(
            processKey: ProcessKey(ipid: -7), threadKey: ThreadKey(itid: -9),
            name: "work", nameMatch: .prefix, minimumDurationNs: 2, depth: 1
        )
        XCTAssertEqual(query.command, .query(
            trace: "trace",
            options: CLIQueryOptions(
                view: .slices,
                range: try TraceTimeRange.query(startNs: 10, endNs: 20),
                filters: queryFilters,
                limit: 3
            )
        ))
        let queryEcho = try query.machineRequest()
        XCTAssertEqual(queryEcho.command, "query")
        XCTAssertEqual(queryEcho.parameters["view"], .string("slices"))
        XCTAssertEqual(queryEcho.parameters["processKey"], .int64(-7))
        XCTAssertEqual(queryEcho.parameters["cpu"], .null)

        let context = try CLIArgumentParser().parse([
            "context", "trace", "--timestamp-ns", "5000000",
            "--window-ms", "2", "--pid", "42",
        ])
        let contextFilters = try TraceAgentQueryFilters(pid: 42)
        XCTAssertEqual(context.command, .context(
            trace: "trace",
            options: CLIContextOptions(
                time: .timestamp(
                    timestampNs: 5_000_000,
                    windowBeforeNs: 2_000_000,
                    windowAfterNs: 2_000_000
                ),
                filters: contextFilters
            )
        ))
        let contextEcho = try context.machineRequest()
        XCTAssertEqual(contextEcho.parameters["timestampNs"], .int64(5_000_000))
        XCTAssertEqual(contextEcho.parameters["windowBeforeNs"], .int64(2_000_000))
        XCTAssertEqual(contextEcho.parameters["windowAfterNs"], .int64(2_000_000))
        XCTAssertEqual(contextEcho.parameters["startNs"], .null)
        XCTAssertNil(contextEcho.parameters["windowMs"])

        let analyze = try CLIArgumentParser().parse([
            "analyze", "trace", "--kind", "hot-intervals", "--start-ns", "1",
            "--end-ns", "100", "--thread-key", "-11", "--threshold-ns", "8",
            "--limit", "5",
        ])
        let analysisFilters = try TraceAgentQueryFilters(threadKey: ThreadKey(itid: -11))
        XCTAssertEqual(analyze.command, .analyze(
            trace: "trace",
            options: CLIAnalyzeOptions(
                kind: .hotIntervals,
                range: try TraceTimeRange.query(startNs: 1, endNs: 100),
                filters: analysisFilters,
                thresholdNs: 8,
                limit: 5
            )
        ))
        let analyzeEcho = try analyze.machineRequest()
        XCTAssertEqual(analyzeEcho.parameters["kind"], .string("hot-intervals"))
        XCTAssertEqual(analyzeEcho.parameters["threadKey"], .int64(-11))
    }

    func testPhase4CommandConflictsOverflowAndUnsupportedFiltersFailClosed() {
        let invalid: [[String]] = [
            ["query", "trace", "--view", "unknown", "--start-ns", "1", "--end-ns", "2"],
            ["query", "trace", "--view", "slices", "--start-ns", "1"],
            ["--max-events", "2", "query", "trace", "--view", "slices",
             "--start-ns", "1", "--end-ns", "2", "--limit", "3"],
            ["query", "trace", "--view", "slices", "--start-ns", "1",
             "--end-ns", "2", "--process-key", "0"],
            ["query", "trace", "--view", "slices", "--start-ns", "1",
             "--end-ns", "2", "--cpu", "0"],
            ["context", "trace", "--timestamp-ns", "1", "--window-ms", "1",
             "--start-ns", "0", "--end-ns", "2"],
            ["context", "trace", "--timestamp-ns", "1", "--window-ms",
             String(Int64.max)],
            ["analyze", "trace", "--kind", "cpu", "--cpu", "1"],
            ["analyze", "trace", "--kind", "slices", "--start-ns", "1"],
            ["analyze", "trace", "--kind", "unknown"],
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try CLIArgumentParser().parse(arguments), "\(arguments)") {
                XCTAssertEqual(($0 as? ArkTraceError)?.code, .invalidArgument)
                XCTAssertEqual(($0 as? ArkTraceError)?.stage, .request)
            }
        }
    }

    func testLicensesCommandReturnsBundledReviewedResourcesWithoutExecutingTraceWork() async throws {
        let resourceRoot = ArkTraceCLIResourceFixtures.root
        let inventory = try CLIResourceLocator.$testingRootPath.withValue(resourceRoot.path) {
            try CLILicenseResources.inventoryData()
        }
        let notice = try CLIResourceLocator.$testingRootPath.withValue(resourceRoot.path) {
            try CLILicenseResources.noticeData()
        }
        XCTAssertEqual(notice.count, CLILicenseResources.noticeByteCount)
        let licenseFiles = try CLILicenseResources.verifiedLicenseFiles(
            inventoryData: inventory,
            licenseDirectoryURL: resourceRoot.appending(path: "LICENSES")
        )
        let productLicense = try CLIResourceLocator.$testingRootPath.withValue(resourceRoot.path) {
            try CLILicenseResources.productLicenseData()
        }
        XCTAssertEqual(productLicense.count, 1_078)
        XCTAssertTrue(String(decoding: productLicense, as: UTF8.self).hasPrefix("MIT License\n"))
        let inventoryObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: inventory) as? [String: Any]
        )
        XCTAssertEqual(inventoryObject["formatVersion"] as? Int, 1)
        XCTAssertEqual(
            (inventoryObject["components"] as? [[String: Any]])?.count,
            CLILicenseResources.componentCount
        )
        XCTAssertEqual(
            (inventoryObject["buildTools"] as? [[String: Any]])?.count,
            CLILicenseResources.buildToolCount
        )
        XCTAssertEqual(licenseFiles.count, CLILicenseResources.licenseFileCount)
        XCTAssertEqual(Set(licenseFiles.map(\.resourcePath)).count, licenseFiles.count)

        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "arktrace-license-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for file in licenseFiles {
            try file.data.write(
                to: temporary.appending(path: String(file.resourcePath.dropFirst("LICENSES/".count)))
            )
        }
        let missing = temporary.appending(path: String(try XCTUnwrap(licenseFiles.first).resourcePath.dropFirst("LICENSES/".count)))
        try FileManager.default.removeItem(at: missing)
        XCTAssertThrowsError(try CLILicenseResources.verifiedLicenseFiles(
            inventoryData: inventory, licenseDirectoryURL: temporary
        ))

        for file in licenseFiles {
            try file.data.write(
                to: temporary.appending(path: String(file.resourcePath.dropFirst("LICENSES/".count))),
                options: .atomic
            )
        }
        try Data("undeclared\n".utf8).write(
            to: temporary.appending(path: "unexpected.txt")
        )
        XCTAssertThrowsError(try CLILicenseResources.verifiedLicenseFiles(
            inventoryData: inventory, licenseDirectoryURL: temporary
        ))
        try FileManager.default.removeItem(
            at: temporary.appending(path: "unexpected.txt")
        )

        let ancestorRoot = temporary.deletingLastPathComponent()
            .appending(path: "license-ancestor-\(UUID().uuidString)", directoryHint: .isDirectory)
        let realParent = ancestorRoot.appending(path: "real", directoryHint: .isDirectory)
        let realLicenses = realParent.appending(path: "LICENSES", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: realLicenses, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: ancestorRoot) }
        for file in licenseFiles {
            try file.data.write(
                to: realLicenses.appending(path: String(file.resourcePath.dropFirst("LICENSES/".count)))
            )
        }
        let linkedParent = ancestorRoot.appending(path: "linked", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)
        XCTAssertThrowsError(try CLILicenseResources.verifiedLicenseFiles(
            inventoryData: inventory,
            licenseDirectoryURL: linkedParent.appending(path: "LICENSES")
        ))

        let noticeURL = ancestorRoot.appending(path: "THIRD_PARTY_NOTICES.md")
        try notice.write(to: noticeURL)
        XCTAssertEqual(try CLILicenseResources.noticeData(resourceURL: noticeURL), notice)
        var driftedNotice = notice
        driftedNotice[driftedNotice.startIndex] ^= 1
        try driftedNotice.write(to: noticeURL, options: .atomic)
        XCTAssertThrowsError(try CLILicenseResources.noticeData(resourceURL: noticeURL))
        try Data("drift\n".utf8).write(to: missing)
        XCTAssertThrowsError(try CLILicenseResources.verifiedLicenseFiles(
            inventoryData: inventory, licenseDirectoryURL: temporary
        ))

        let installPrefix = ancestorRoot.appending(path: "install", directoryHint: .isDirectory)
        let installBin = installPrefix.appending(path: "bin", directoryHint: .isDirectory)
        let installShare = installPrefix
            .appending(path: "share", directoryHint: .isDirectory)
            .appending(path: "arktrace", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: installBin, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: installShare, withIntermediateDirectories: true
        )
        let unavailableBundle = ancestorRoot.appending(path: "NoApp.app", directoryHint: .isDirectory)
        let installedRoot = try CLIResourceLocator.productionRoot(
            bundleURL: unavailableBundle,
            executableURL: installBin.appending(path: "arktrace")
        )
        XCTAssertEqual(installedRoot, installShare.resolvingSymlinksInPath().standardizedFileURL)
        let rawRelease = installPrefix.appending(path: "release", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rawRelease, withIntermediateDirectories: true)
        XCTAssertThrowsError(try CLIResourceLocator.productionRoot(
            bundleURL: unavailableBundle,
            executableURL: rawRelease.appending(path: "arktrace")
        ))

        let executor = RecordingExecutor()
        let application = CLIApplication(executor: executor)
        let humanWriter = MemoryWriter()
        let humanStatus = await CLIResourceLocator.$testingRootPath.withValue(resourceRoot.path) {
            await application.run(arguments: ["licenses"], writer: humanWriter)
        }
        XCTAssertEqual(humanStatus, 0)
        XCTAssertTrue(humanWriter.stdoutString.contains("# ArkTrace Product License"))
        XCTAssertTrue(humanWriter.stdoutString.contains("MIT License"))
        XCTAssertTrue(humanWriter.stdoutString.contains("# ArkTrace Third-Party Notices"))
        XCTAssertTrue(humanWriter.stdoutString.contains("# Bundled Third-Party License Files"))
        XCTAssertTrue(humanWriter.stdoutString.contains("LICENSES/trace_streamer-Apache-2.0.txt"))
        XCTAssertEqual(humanWriter.stderrString, "")

        let machineWriter = MemoryWriter()
        let machineStatus = await CLIResourceLocator.$testingRootPath.withValue(resourceRoot.path) {
            await application.run(arguments: ["--json", "licenses"], writer: machineWriter)
        }
        XCTAssertEqual(machineStatus, 0)
        let document = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: machineWriter.stdoutData) as? [String: Any]
        )
        XCTAssertEqual(
            (document["request"] as? [String: Any])?["command"] as? String,
            "licenses"
        )
        let result = try XCTUnwrap(document["result"] as? [String: Any])
        XCTAssertEqual(result["buildToolCount"] as? Int, CLILicenseResources.buildToolCount)
        XCTAssertEqual(result["componentCount"] as? Int, CLILicenseResources.componentCount)
        XCTAssertEqual(result["inventory"] as? String, "license-inventory.json")
        XCTAssertEqual((result["licenseFiles"] as? [[String: Any]])?.count, 18)
        XCTAssertEqual(result["notice"] as? String, "THIRD_PARTY_NOTICES.md")
        XCTAssertEqual(result["productLicense"] as? String, "LICENSE")
        XCTAssertEqual(result["productLicenseBytes"] as? Int, 1_078)
        let executorCallCount = await executor.callCount
        XCTAssertEqual(executorCallCount, 0)
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
        let compact = try CLIMachineEncoder().encode(value, pretty: false, maximumBytes: Int.max)
        XCTAssertEqual(compact, try CLIMachineEncoder().encode(value, pretty: false, maximumBytes: Int.max))
        XCTAssertEqual(String(decoding: compact, as: UTF8.self), #"{"a":"one","z":2}"# + "\n")
        let pretty = try CLIMachineEncoder().encode(value, pretty: true, maximumBytes: Int.max)
        XCTAssertNotEqual(pretty, compact)
        XCTAssertTrue(String(decoding: pretty, as: UTF8.self).contains("\n  \"a\""))
        XCTAssertEqual(try JSONDecoder().decode(Value.self, from: pretty), value)
        XCTAssertThrowsError(try JSONSerialization.jsonObject(with: CLIHumanRenderer().help()))
    }

    func testStderrClippingKeepsCompleteUTF8CharactersAtTheBudgetBoundary() {
        let cases: [(String, Int, String)] = [
            ("aé!", 3, "aé"), ("é…", 2, "é"),
            ("a€!", 4, "a€"), ("a😀!", 5, "a😀"),
            ("aé!", 2, "a"), ("a€!", 3, "a"), ("a😀!", 4, "a"),
            ("é!", 1, ""), ("ascii", 3, "asc"), ("ascii", 5, "ascii"),
            ("é", 8, "é"), ("é", 0, ""), ("", 1, ""),
        ]
        for (input, budget, expected) in cases {
            let writer = MemoryWriter()
            CLIApplication.writeStderrIfFits(Data(input.utf8), maximumBytes: budget, writer: writer)
            XCTAssertEqual(writer.stderrString, expected, "\(input), budget \(budget)")
            XCTAssertLessThanOrEqual(writer.stderrString.utf8.count, budget)
            XCTAssertTrue(writer.stdoutData.isEmpty)
        }
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

    var stdoutData: Data {
        lock.withLock { stdout }
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
