@testable import ArkTraceAnalysis
@testable import ArkTraceCLI
import ArkTraceCLIResourceFixtures
import ArkTraceCore
@testable import ArkTraceRuntime
import ArkTraceStore
import Foundation
import XCTest

final class ProductionCommandExecutorTests: XCTestCase {
    func testLicensesDeadlineCancelsAndDrainsFailingResourcePreparation() async throws {
        let deadlineClock = ManualCLIDeadlineClock()
        let barrier = BlockingLicenseProvider()
        let application = CLIApplication(
            machineToolProvider: {
                try CLIMachineTool(
                    name: ArkTraceCLITool.name,
                    version: ArkTraceCLITool.version,
                    buildRevision: String(repeating: "a", count: 64)
                )
            },
            licenseProvider: { try barrier.load() },
            deadlineClock: deadlineClock.clock
        )
        let writer = TestOutputWriter()
        let operation = Task {
            await application.run(
                arguments: ["--json", "--timeout-ms", "5000", "licenses"],
                writer: writer
            )
        }
        await barrier.waitUntilReached()
        deadlineClock.expire()
        let status = await operation.value
        XCTAssertEqual(status, 7)
        XCTAssertTrue(barrier.finished)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: writer.stdout) as? [String: Any]
        )
        XCTAssertEqual(
            (object["error"] as? [String: Any])?["code"] as? String,
            "QUERY_TIMEOUT"
        )
    }

    func testCLITimeoutDrainsCacheRollbackBeforeReturning() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let parserURL = repositoryRoot
            .appendingPathComponent("ThirdParty/TraceStreamer/macx/trace_streamer")
        let fixtureURL = repositoryRoot
            .appendingPathComponent("Fixtures/traces/zlib.htrace")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cli-timeout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CLIStoragePaths(
            stagingDirectory: root.appendingPathComponent("staging", isDirectory: true),
            cacheDirectory: root.appendingPathComponent("cache", isDirectory: true)
        )
        let barrier = BlockingCachePromotionBarrier()
        let deadlineClock = ManualCLIDeadlineClock()
        let executor = CLIProductionCommandExecutor(
            sessionOpener: { source, options, storage in
                try await TraceSession.openCached(
                    source: source,
                    parser: options.resolveParser(),
                    stagingDirectory: storage.stagingDirectory,
                    cacheDirectory: storage.cacheDirectory,
                    hooks: TraceCacheTestHooks(afterPromotion: { barrier.pause(at: $0) })
                )
            },
            parserIdentityProvider: { options in
                try await options.resolveParser().identity()
            },
            toolRevisionProvider: { String(repeating: "a", count: 64) },
            storagePathsProvider: { paths },
            selfTestFixtureProvider: { fixtureURL }
        )
        let writer = TestOutputWriter()
        let testedApplication = application(
            executor: executor,
            deadlineClock: deadlineClock.clock
        )
        let operation = Task {
            await testedApplication.run(
                arguments: [
                    "--json", "--timeout-ms", "5000", "--trace-streamer", parserURL.path,
                    "inspect", fixtureURL.path,
                ],
                writer: writer
            )
        }
        guard let promotedURL = await barrier.waitUntilReached(timeout: 30) else {
            operation.cancel()
            barrier.resume()
            _ = await operation.value
            XCTFail("cache promotion was not reached before the test deadline")
            return
        }
        deadlineClock.expire()

        let status = await operation.value
        XCTAssertEqual(status, 7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: promotedURL.path))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: writer.stdout) as? [String: Any]
        )
        XCTAssertNil(object["result"])
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? String, "QUERY_TIMEOUT")
    }

    func testHumanTraceFieldsAreBoundedAndTerminalEscaped() throws {
        let injected = "worker\n\t\u{1B}]0;owned\u{7}\u{202E}"
        let process = TraceProcess(
            key: ProcessKey(ipid: 1),
            pid: 2,
            name: injected + String(repeating: "x", count: 5_000),
            startNs: nil,
            endNs: nil,
            threadCount: nil
        )
        let thread = TraceThread(
            key: ThreadKey(itid: 3),
            processKey: ProcessKey(ipid: 1),
            tid: 4,
            pid: 2,
            name: injected,
            processName: nil,
            startNs: nil,
            endNs: nil,
            isMainThread: nil
        )
        let summary = TraceSummary(
            range: try TraceTimeRange.query(startNs: 0, endNs: 1),
            durationNs: 1,
            cpuCount: nil,
            processCount: 0,
            threadCount: 0,
            cpuSliceCount: nil,
            threadStateCount: nil,
            namedSliceCount: nil,
            counterSeriesCount: nil,
            eventCountBySource: [TraceEventSourceCount(source: injected, count: 1)],
            capabilities: TraceCapabilities(
                cpuScheduling: false,
                threadStates: false,
                namedSlices: false,
                cpuCounters: false,
                processCounters: false
            ),
            schemaFingerprint: String(repeating: "d", count: 64),
            dataQuality: TraceDataQuality(),
            truncatedSections: []
        )

        let rendered = [
            CLIHumanRenderer.processes(BoundedPage(items: [process], truncated: false)),
            CLIHumanRenderer.threads(BoundedPage(items: [thread], truncated: false)),
            CLIHumanRenderer.summary(summary),
            CLIHumanRenderer.doctor(
                BoundedPage(items: [], truncated: false),
                details: CLIHumanDoctorDetails(
                    toolVersion: "0.1.0",
                    toolBuildRevision: nil,
                    operatingSystem: injected,
                    architecture: "arm64",
                    parserLocation: "/tmp/\(injected)",
                    parserIdentity: nil,
                    sqlite: TraceSQLiteRuntimeInfo.current,
                    cacheLocation: "/tmp/cache/\(injected)",
                    cacheWritable: true,
                    cacheFreeBytes: 1,
                    schemaAdapterVersion: "2"
                )
            ),
        ].compactMap { String(data: $0, encoding: .utf8) }

        XCTAssertEqual(rendered.count, 4)
        for output in rendered {
            XCTAssertFalse(output.contains("\u{1B}"))
            XCTAssertFalse(output.contains("\u{7}"))
            XCTAssertFalse(output.contains("\u{202E}"))
            XCTAssertTrue(output.contains(#"\u{A}\u{9}\u{1B}"#))
            XCTAssertTrue(output.contains(#"\u{7}\u{202E}"#))
        }
        XCTAssertLessThan(rendered[0].utf8.count, 4_200)
        XCTAssertTrue(rendered[0].contains("…"))
    }

    func testRealFixtureRunsAllEightCommandsInHumanAndMachineModes() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let parserURL = repositoryRoot
            .appendingPathComponent("ThirdParty/TraceStreamer/macx/trace_streamer")
        let fixtureURL = repositoryRoot
            .appendingPathComponent("Fixtures/traces/zlib.htrace")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: parserURL.path))
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: fixtureURL.path))
        let bundledFixtureURL = try CLIResourceLocator.$testingRootPath.withValue(
            ArkTraceCLIResourceFixtures.root.path
        ) {
            try CLIProductionCommandExecutor.bundledSelfTestFixture()
        }
        XCTAssertEqual(try Data(contentsOf: bundledFixtureURL), try Data(contentsOf: fixtureURL))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-real-cli-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CLIStoragePaths(
            stagingDirectory: root.appendingPathComponent("staging"),
            cacheDirectory: root.appendingPathComponent("cache")
        )
        let executor = CLIProductionCommandExecutor(
            sessionOpener: { source, options, storage in
                let parser = try options.resolveParser()
                let policy: TraceSessionStoragePolicy = options.noCache
                    ? .ephemeral
                    : .contentAddressed(cacheDirectory: storage.cacheDirectory)
                return try await TraceSession.open(
                    source: source,
                    parser: parser,
                    stagingDirectory: storage.stagingDirectory,
                    storagePolicy: policy
                )
            },
            parserIdentityProvider: { options in
                try await options.resolveParser().identity()
            },
            toolRevisionProvider: { String(repeating: "a", count: 64) },
            storagePathsProvider: { paths },
            selfTestFixtureProvider: { bundledFixtureURL }
        )
        let commands: [[String]] = [
            ["doctor", "--self-test"],
            ["inspect", fixtureURL.path],
            ["summary", fixtureURL.path],
            ["processes", fixtureURL.path, "--limit", "2"],
            ["threads", fixtureURL.path, "--limit", "2"],
            [
                "query", fixtureURL.path, "--view", "slices",
                "--start-ns", "0", "--end-ns", "1", "--limit", "2",
            ],
            [
                "context", fixtureURL.path, "--start-ns", "0", "--end-ns", "1",
            ],
            [
                "analyze", fixtureURL.path, "--kind", "range",
                "--start-ns", "0", "--end-ns", "1", "--limit", "2",
            ],
        ]

        for command in commands {
            let globals = ["--trace-streamer", parserURL.path]
            let machine = TestOutputWriter()
            let machineStatus = await application(executor: executor).run(
                arguments: ["--json"] + globals + command,
                writer: machine
            )
            XCTAssertEqual(machineStatus, 0, command.joined(separator: " "))
            let document = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: machine.stdout) as? [String: Any]
            )
            XCTAssertNotNil(document["result"], command.joined(separator: " "))
            XCTAssertNil(document["error"], command.joined(separator: " "))
            XCTAssertFalse(String(decoding: machine.stdout, as: UTF8.self).contains(fixtureURL.path))
            XCTAssertTrue(machine.stderr.isEmpty)

            let human = TestOutputWriter()
            let humanStatus = await application(executor: executor).run(
                arguments: globals + command,
                writer: human
            )
            XCTAssertEqual(humanStatus, 0, command.joined(separator: " "))
            XCTAssertFalse(human.stdout.isEmpty)
            XCTAssertTrue(human.stderr.isEmpty)
        }
    }

    func testEightProductionCommandsSupportHumanAndMachineOutput() async throws {
        let environment = try CommandEnvironment()
        let executor = environment.executor()
        let commands: [([String], String)] = [
            (["doctor"], "ArkTrace doctor"),
            (["inspect", "/Users/private/source.htrace"], "Trace SHA-256:"),
            (["summary", "/Users/private/source.htrace"], "Processes:"),
            ([
                "processes", "/Users/private/source.htrace", "--pid", "42",
                "--name", "worker", "--limit", "1",
            ], "IPID\tPID"),
            ([
                "threads", "/Users/private/source.htrace", "--pid", "42",
                "--tid", "43", "--name", "worker-thread", "--limit", "1",
            ], "ITID\tIPID"),
            ([
                "query", "/Users/private/source.htrace", "--view", "slices",
                "--start-ns", "0", "--end-ns", "100", "--limit", "1",
            ], "View: slices"),
            ([
                "context", "/Users/private/source.htrace", "--start-ns", "0",
                "--end-ns", "100",
            ], "CPU slices:"),
            ([
                "analyze", "/Users/private/source.htrace", "--kind", "range",
                "--start-ns", "0", "--end-ns", "100", "--limit", "1",
            ], "Analysis: range"),
        ]

        for (arguments, humanNeedle) in commands {
            let human = TestOutputWriter()
            let humanStatus = await application(executor: executor).run(
                arguments: arguments,
                writer: human
            )
            XCTAssertEqual(humanStatus, 0, arguments.joined(separator: " "))
            XCTAssertTrue(
                String(decoding: human.stdout, as: UTF8.self).contains(humanNeedle),
                arguments.joined(separator: " ")
            )
            XCTAssertTrue(human.stderr.isEmpty)

            let machine = TestOutputWriter()
            let machineStatus = await application(executor: executor).run(
                arguments: ["--json"] + arguments,
                writer: machine
            )
            XCTAssertEqual(machineStatus, 0, arguments.joined(separator: " "))
            XCTAssertTrue(machine.stderr.isEmpty)
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: machine.stdout) as? [String: Any]
            )
            XCTAssertNotNil(object["result"])
            XCTAssertNil(object["error"])
            XCTAssertFalse(
                String(decoding: machine.stdout, as: UTF8.self)
                    .contains("/Users/private/source.htrace")
            )
        }

        let sessions = environment.registry.sessions
        XCTAssertEqual(sessions.count, 14)
        for session in sessions {
            let closeCount = await session.closeCount
            XCTAssertEqual(closeCount, 1)
        }
    }

    func testFiltersRangesLimitsAndSelfTestReachTheBoundSession() async throws {
        let environment = try CommandEnvironment()
        let executor = environment.executor()

        let summaryWriter = TestOutputWriter()
        let summaryStatus = await application(executor: executor).run(
            arguments: [
                "--json", "--max-rows", "7", "--max-events", "3",
                "--timeout-ms", "500",
                "summary", "trace", "--start-ns", "10", "--end-ns", "90",
            ],
            writer: summaryWriter
        )
        XCTAssertEqual(summaryStatus, 0)
        let summarySession = try XCTUnwrap(environment.registry.sessions.last)
        let capturedSummaryRequest = await summarySession.summaryRequest
        let summaryRequest = try XCTUnwrap(capturedSummaryRequest)
        XCTAssertEqual(summaryRequest.range, try TraceTimeRange.query(startNs: 10, endNs: 90))
        XCTAssertEqual(summaryRequest.maximumRowsPerSection, 7)
        XCTAssertEqual(summaryRequest.maximumEventsPerSection, 3)
        XCTAssertEqual(summaryRequest.timeout, .milliseconds(500))

        let processWriter = TestOutputWriter()
        let processStatus = await application(executor: executor).run(
            arguments: [
                "--json", "processes", "trace", "--pid", "42",
                "--name", "worker", "--limit", "1",
            ],
            writer: processWriter
        )
        XCTAssertEqual(processStatus, 0)
        let processSession = try XCTUnwrap(environment.registry.sessions.last)
        let capturedProcessQuery = await processSession.processQuery
        let processQuery = try XCTUnwrap(capturedProcessQuery)
        XCTAssertEqual(processQuery.pid, 42)
        XCTAssertEqual(processQuery.name, "worker")
        XCTAssertEqual(processQuery.limit, 1)
        XCTAssertNotNil(processQuery.deadline)

        let emptyWriter = TestOutputWriter()
        let emptyStatus = await application(executor: executor).run(
            arguments: ["--json", "processes", "trace", "--name", "missing"],
            writer: emptyWriter
        )
        XCTAssertEqual(emptyStatus, 0)
        let emptyObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: emptyWriter.stdout) as? [String: Any]
        )
        XCTAssertEqual(
            ((emptyObject["result"] as? [String: Any])?["items"] as? [Any])?.count,
            0
        )

        let threadWriter = TestOutputWriter()
        let threadStatus = await application(executor: executor).run(
            arguments: [
                "--json", "threads", "trace", "--process-key", "101",
                "--thread-key", "202", "--name", "worker-thread", "--limit", "1",
            ],
            writer: threadWriter
        )
        XCTAssertEqual(threadStatus, 0)
        let threadSession = try XCTUnwrap(environment.registry.sessions.last)
        let capturedThreadQuery = await threadSession.threadQuery
        let threadQuery = try XCTUnwrap(capturedThreadQuery)
        XCTAssertEqual(threadQuery.processKey, ProcessKey(ipid: 101))
        XCTAssertEqual(threadQuery.threadKey, ThreadKey(itid: 202))
        XCTAssertEqual(threadQuery.name, "worker-thread")
        XCTAssertEqual(threadQuery.limit, 1)
        XCTAssertNotNil(threadQuery.deadline)

        let queryWriter = TestOutputWriter()
        let queryStatus = await application(executor: executor).run(
            arguments: [
                "--json", "--max-events", "3", "--timeout-ms", "500",
                "query", "trace", "--view", "slices", "--start-ns", "10",
                "--end-ns", "90", "--process-key", "-101", "--name", "work",
                "--name-match", "prefix", "--limit", "2",
            ],
            writer: queryWriter
        )
        XCTAssertEqual(queryStatus, 0)
        let querySession = try XCTUnwrap(environment.registry.sessions.last)
        let capturedAgentRequest = await querySession.agentRequest
        let agentRequest = try XCTUnwrap(capturedAgentRequest)
        XCTAssertEqual(agentRequest.view, .slices)
        XCTAssertEqual(agentRequest.range, try TraceTimeRange.query(startNs: 10, endNs: 90))
        XCTAssertEqual(agentRequest.filters.processKey, ProcessKey(ipid: -101))
        XCTAssertEqual(agentRequest.filters.name, "work")
        XCTAssertEqual(agentRequest.filters.nameMatch, .prefix)
        XCTAssertEqual(agentRequest.limit, 2)
        XCTAssertEqual(agentRequest.timeout, .milliseconds(500))

        let contextWriter = TestOutputWriter()
        let contextStatus = await application(executor: executor).run(
            arguments: [
                "--json", "--max-rows", "7", "--max-events", "3",
                "--max-output-bytes", "4096", "--timeout-ms", "500",
                "context", "trace", "--timestamp-ns", "50", "--window-ms", "1",
                "--pid", "42",
            ],
            writer: contextWriter
        )
        // The symmetric window clips to the full 0...100 test trace.
        XCTAssertEqual(contextStatus, 0)
        let contextSession = try XCTUnwrap(environment.registry.sessions.last)
        let capturedContextRequest = await contextSession.contextRequest
        let contextRequest = try XCTUnwrap(capturedContextRequest)
        XCTAssertEqual(contextRequest.filters.pid, 42)
        XCTAssertEqual(contextRequest.maximumEvents, 3)
        XCTAssertEqual(contextRequest.maximumRows, 7)
        XCTAssertEqual(contextRequest.maximumOutputBytes, 4_096)
        XCTAssertEqual(contextRequest.timeout, .milliseconds(500))

        let analysisWriter = TestOutputWriter()
        let analysisStatus = await application(executor: executor).run(
            arguments: [
                "--json", "--max-events", "3", "--timeout-ms", "500",
                "analyze", "trace", "--kind", "hot-intervals", "--start-ns", "10",
                "--end-ns", "90", "--thread-key", "-202", "--threshold-ns", "7",
                "--limit", "2",
            ],
            writer: analysisWriter
        )
        XCTAssertEqual(analysisStatus, 0)
        let analysisSession = try XCTUnwrap(environment.registry.sessions.last)
        let capturedAnalysisRequest = await analysisSession.analysisRequest
        let analysisRequest = try XCTUnwrap(capturedAnalysisRequest)
        XCTAssertEqual(analysisRequest.range, try TraceTimeRange.query(startNs: 10, endNs: 90))
        XCTAssertEqual(analysisRequest.filters.threadKey, ThreadKey(itid: -202))
        XCTAssertEqual(analysisRequest.maximumCPUSlices, 3)
        XCTAssertEqual(analysisRequest.minimumLongSliceDurationNs, 7)
        XCTAssertEqual(analysisRequest.hotIntervalLimit, 2)
        XCTAssertEqual(analysisRequest.timeout, .milliseconds(500))

        let doctorWriter = TestOutputWriter()
        let doctorStatus = await application(executor: executor).run(
            arguments: ["--json", "doctor", "--self-test"],
            writer: doctorWriter
        )
        XCTAssertEqual(doctorStatus, 0)
        let doctorObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: doctorWriter.stdout) as? [String: Any]
        )
        let checks = try XCTUnwrap(
            (doctorObject["result"] as? [String: Any])?["checks"] as? [[String: Any]]
        )
        XCTAssertEqual(checks.last?["code"] as? String, "selfTest")
        XCTAssertEqual(checks.last?["status"] as? String, "ok")
        let doctorSession = try XCTUnwrap(environment.registry.sessions.last)
        let doctorCloseCount = await doctorSession.closeCount
        XCTAssertEqual(doctorCloseCount, 1)
        XCTAssertEqual(environment.registry.options.last?.noCache, true)

        try environment.installCacheSymlink()
        let unhealthyWriter = TestOutputWriter()
        let unhealthyStatus = await application(executor: executor).run(
            arguments: ["--json", "doctor"],
            writer: unhealthyWriter
        )
        XCTAssertEqual(unhealthyStatus, 5)
        let unhealthyObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: unhealthyWriter.stdout) as? [String: Any]
        )
        XCTAssertEqual(
            (unhealthyObject["error"] as? [String: Any])?["code"] as? String,
            "TRACE_CACHE_CORRUPT"
        )
    }

    func testContextRetentionBudgetsTheCompleteMachineEnvelope() async throws {
        let environment = try CommandEnvironment()
        environment.registry.setNearBudgetContext(true)

        let humanWriter = TestOutputWriter()
        let humanStatus = await application(executor: environment.executor()).run(
            arguments: [
                "--max-output-bytes", "4096",
                "context", "trace", "--start-ns", "0", "--end-ns", "100",
            ],
            writer: humanWriter
        )
        XCTAssertEqual(humanStatus, 0)
        XCTAssertLessThanOrEqual(humanWriter.stdout.count, 4_096)
        XCTAssertTrue(humanWriter.stderr.isEmpty)
        XCTAssertTrue(String(decoding: humanWriter.stdout, as: UTF8.self).contains("Processes: 6"))
        let humanSession = try XCTUnwrap(environment.registry.sessions.last)
        let humanRequests = await humanSession.contextRequests
        XCTAssertEqual(humanRequests.count, 1)
        XCTAssertEqual(humanRequests.first?.maximumOutputBytes, 4_096)

        for pretty in [false, true] {
            let maximumBytes = pretty ? 6_000 : 4_096
            let writer = TestOutputWriter()
            var arguments = ["--json"]
            if pretty { arguments.append("--pretty") }
            arguments += [
                "--max-output-bytes", String(maximumBytes),
                "context", "trace", "--start-ns", "0", "--end-ns", "100",
            ]
            let status = await application(executor: environment.executor()).run(
                arguments: arguments,
                writer: writer
            )
            XCTAssertEqual(status, 0, "pretty=\(pretty)")
            XCTAssertLessThanOrEqual(writer.stdout.count, maximumBytes)
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: writer.stdout) as? [String: Any]
            )
            XCTAssertNotNil(object["trace"])
            XCTAssertNotNil(object["provenance"])
            XCTAssertNotNil((object["result"] as? [String: Any])?["summary"])
            let session = try XCTUnwrap(environment.registry.sessions.last)
            let requests = await session.contextRequests
            XCTAssertGreaterThan(requests.count, 1)
            XCTAssertEqual(requests.first?.maximumOutputBytes, maximumBytes)
            XCTAssertLessThan(
                try XCTUnwrap(requests.last?.maximumOutputBytes), maximumBytes
            )
        }
    }

    func testThreadCommandPreservesReusedPIDTIDInternalIdentities() async throws {
        let environment = try CommandEnvironment()
        let writer = TestOutputWriter()
        let status = await application(executor: environment.executor()).run(
            arguments: [
                "--json", "threads", "trace", "--pid", "42", "--tid", "43",
                "--limit", "2",
            ],
            writer: writer
        )

        XCTAssertEqual(status, 0)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: writer.stdout) as? [String: Any]
        )
        let items = try XCTUnwrap(
            (object["result"] as? [String: Any])?["items"] as? [[String: Any]]
        )
        XCTAssertEqual(items.compactMap { $0["pid"] as? Int64 }, [42, 42])
        XCTAssertEqual(items.compactMap { $0["tid"] as? Int64 }, [43, 43])
        XCTAssertEqual(items.compactMap { $0["key"] as? Int64 }, [202, 203])
    }

    func testOperationOrCleanupFailureCannotReturnSuccess() async throws {
        let environment = try CommandEnvironment()
        environment.registry.setCloseError(ArkTraceError(
            code: .traceParseFailed,
            stage: .openingDatabase,
            message: "injected close failure",
            retryable: true,
            details: ["reason": "sessionCleanupFailed"]
        ))
        let writer = TestOutputWriter()
        let status = await application(executor: environment.executor()).run(
            arguments: ["--json", "inspect", "trace"],
            writer: writer
        )

        XCTAssertEqual(status, 4)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: writer.stdout) as? [String: Any]
        )
        XCTAssertNil(object["result"])
        XCTAssertEqual(
            (object["error"] as? [String: Any])?["code"] as? String,
            "TRACE_PARSE_FAILED"
        )
    }

    func testDoctorGenericSelfTestFailureUsesStableParseError() async throws {
        let environment = try CommandEnvironment()
        let executor = environment.executor(selfTestFixtureProvider: {
            throw CocoaError(.fileReadUnknown)
        })
        let writer = TestOutputWriter()

        let status = await application(executor: executor).run(
            arguments: ["--json", "doctor", "--self-test"],
            writer: writer
        )

        XCTAssertEqual(status, 4)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: writer.stdout) as? [String: Any]
        )
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "TRACE_PARSE_FAILED")
        XCTAssertEqual(error["stage"] as? String, "parsing")
    }

    private func application(
        executor: CLIProductionCommandExecutor,
        deadlineClock: CLIDeadlineClock = .continuous
    ) -> CLIApplication {
        CLIApplication(
            executor: executor,
            machineToolProvider: {
                try CLIMachineTool(
                    name: ArkTraceCLITool.name,
                    version: ArkTraceCLITool.version,
                    buildRevision: String(repeating: "a", count: 64)
                )
            },
            deadlineClock: deadlineClock
        )
    }
}

private final class BlockingLicenseProvider: @unchecked Sendable {
    private let reached = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didFinish = false

    var finished: Bool { lock.withLock { didFinish } }

    func load() throws -> CLIApplication.LicenseSnapshot {
        reached.signal()
        while !Task.isCancelled { usleep(1_000) }
        lock.withLock { didFinish = true }
        throw ArkTraceError(
            code: .internalError,
            stage: .encoding,
            message: "fixture resource failed"
        )
    }

    private func waitBlocking() { reached.wait() }

    func waitUntilReached() async {
        await Task.detached { self.waitBlocking() }.value
    }
}

private final class ManualCLIDeadlineClock: @unchecked Sendable {
    private let lock = NSLock()
    private let base = ContinuousClock.now
    private var expired = false
    private var sleepers: [UUID: CheckedContinuation<Void, any Error>] = [:]

    var clock: CLIDeadlineClock {
        CLIDeadlineClock(
            now: { [self] in
                lock.withLock { expired ? base.advanced(by: .seconds(10)) : base }
            },
            sleepUntil: { [self] _ in try await sleepUntilExpiration() }
        )
    }

    func expire() {
        let continuations = lock.withLock {
            expired = true
            let continuations = Array(sleepers.values)
            sleepers.removeAll(keepingCapacity: false)
            return continuations
        }
        continuations.forEach { $0.resume() }
    }

    private func sleepUntilExpiration() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<Void, any Error>? = lock.withLock {
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if expired { return .success(()) }
                    sleepers[id] = continuation
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let continuation = lock.withLock { sleepers.removeValue(forKey: id) }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

private final class BlockingCachePromotionBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let reached = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var promotedURL: URL?

    func pause(at url: URL) {
        lock.withLock { promotedURL = url }
        reached.signal()
        // Do not let the operation race the deadline timer. The production
        // operation itself leaves this hook only after CLIOperationDeadline
        // has actually cancelled its child, proving the subsequent Runtime
        // rollback/drain path rather than a normal successful close.
        while !Task.isCancelled {
            if release.wait(timeout: .now() + 0.01) == .success { return }
        }
    }

    func waitUntilReached(timeout: TimeInterval) async -> URL? {
        let result = await Task.detached { self.waitBlocking(timeout: timeout) }.value
        guard result == .success else { return nil }
        return lock.withLock { promotedURL }
    }

    private func waitBlocking(timeout: TimeInterval) -> DispatchTimeoutResult {
        reached.wait(timeout: .now() + timeout)
    }

    func resume() {
        release.signal()
    }
}

private final class CommandEnvironment: @unchecked Sendable {
    let registry: SessionRegistry
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cli-tests-\(UUID().uuidString)", isDirectory: true)
        registry = try SessionRegistry(snapshot: commandSnapshot(root: root))
    }

    func executor(
        selfTestFixtureProvider: CLIProductionCommandExecutor.SelfTestFixtureProvider? = nil
    ) -> CLIProductionCommandExecutor {
        CLIProductionCommandExecutor(
            sessionOpener: { [registry] source, options, _ in
                registry.make(source: source, options: options)
            },
            parserIdentityProvider: { _ in commandParserIdentity },
            toolRevisionProvider: { String(repeating: "a", count: 64) },
            storagePathsProvider: { [root] in
                CLIStoragePaths(
                    stagingDirectory: root.appendingPathComponent("staging"),
                    cacheDirectory: root.appendingPathComponent("cache")
                )
            },
            selfTestFixtureProvider: selfTestFixtureProvider ?? { [root] in
                root.appendingPathComponent("fixture.htrace")
            }
        )
    }

    func installCacheSymlink() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let target = root.appendingPathComponent("cache-target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("cache", isDirectory: true),
            withDestinationURL: target
        )
    }
}

private final class SessionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let snapshot: CLIMachineTraceSnapshot
    private var storage: [CommandSessionDouble] = []
    private var capturedOptions: [CLIGlobalOptions] = []
    private var closeError: ArkTraceError?
    private var nearBudgetContext = false

    init(snapshot: CLIMachineTraceSnapshot) throws {
        self.snapshot = snapshot
    }

    var sessions: [CommandSessionDouble] { lock.withLock { storage } }
    var options: [CLIGlobalOptions] { lock.withLock { capturedOptions } }

    func setCloseError(_ error: ArkTraceError?) {
        lock.withLock { closeError = error }
    }


    func setNearBudgetContext(_ enabled: Bool) {
        lock.withLock { nearBudgetContext = enabled }
    }

    func make(source: URL, options: CLIGlobalOptions) -> CommandSessionDouble {
        let configuration = lock.withLock { (closeError, nearBudgetContext) }
        let session = CommandSessionDouble(
            snapshot: snapshot,
            closeError: configuration.0,
            nearBudgetContext: configuration.1
        )
        lock.withLock {
            storage.append(session)
            capturedOptions.append(options)
        }
        return session
    }
}

private actor CommandSessionDouble: CLIManagedTraceSession {
    let snapshot: CLIMachineTraceSnapshot
    let closeError: ArkTraceError?
    private(set) var closeCount = 0
    private(set) var summaryRequest: TraceSummaryRequest?
    private(set) var processQuery: ProcessQuery?
    private(set) var threadQuery: ThreadQuery?
    private(set) var agentRequest: TraceAgentQueryRequest?
    private(set) var contextRequest: TraceContextRequest?
    private(set) var contextRequests: [TraceContextRequest] = []
    private(set) var analysisRequest: TraceDeterministicAnalysisRequest?

    let nearBudgetContext: Bool

    init(
        snapshot: CLIMachineTraceSnapshot,
        closeError: ArkTraceError?,
        nearBudgetContext: Bool = false
    ) {
        self.snapshot = snapshot
        self.closeError = closeError
        self.nearBudgetContext = nearBudgetContext
    }

    func cliInspectSnapshot() async throws -> CLIMachineTraceSnapshot { snapshot }

    func cliSummary(
        _ request: TraceSummaryRequest
    ) async throws -> CLIMachineBoundTraceResult<TraceSummary> {
        summaryRequest = request
        let range = try request.range
            ?? TraceTimeRange.query(startNs: 0, endNs: snapshot.metadata.durationNs)
        return CLIMachineBoundTraceResult(
            snapshot: snapshot,
            value: TraceSummary(
                range: range,
                durationNs: range.durationNs,
                cpuCount: 1,
                processCount: 1,
                threadCount: 1,
                cpuSliceCount: 1,
                threadStateCount: 1,
                namedSliceCount: 1,
                counterSeriesCount: 1,
                eventCountBySource: [TraceEventSourceCount(source: "received", count: 1)],
                capabilities: snapshot.metadata.capabilities,
                schemaFingerprint: snapshot.metadata.schemaFingerprint,
                dataQuality: snapshot.metadata.dataQuality,
                truncatedSections: []
            )
        )
    }

    func cliProcesses(
        _ query: ProcessQuery
    ) async throws -> CLIMachineBoundTraceResult<BoundedPage<TraceProcess>> {
        processQuery = query
        let items: [TraceProcess] = query.name == "missing" ? [] : [TraceProcess(
            key: ProcessKey(ipid: 101),
            pid: 42,
            name: "worker",
            startNs: 0,
            endNs: 100,
            threadCount: 1
        )]
        return CLIMachineBoundTraceResult(
            snapshot: snapshot,
            value: BoundedPage(items: items, truncated: !items.isEmpty && query.limit == 1)
        )
    }

    func cliThreads(
        _ query: ThreadQuery
    ) async throws -> CLIMachineBoundTraceResult<BoundedPage<TraceThread>> {
        threadQuery = query
        let first = TraceThread(
            key: ThreadKey(itid: 202),
            processKey: ProcessKey(ipid: 101),
            tid: 43,
            pid: 42,
            name: "worker-thread",
            processName: "worker",
            startNs: 5,
            endNs: nil,
            isMainThread: false
        )
        let items = query.pid == 42 && query.tid == 43 && query.limit >= 2
            ? [
                first,
                TraceThread(
                    key: ThreadKey(itid: 203),
                    processKey: ProcessKey(ipid: 101),
                    tid: 43,
                    pid: 42,
                    name: "worker-thread-reused",
                    processName: "worker",
                    startNs: 50,
                    endNs: nil,
                    isMainThread: false
                ),
            ]
            : [first]
        return CLIMachineBoundTraceResult(
            snapshot: snapshot,
            value: BoundedPage(items: items, truncated: query.limit == 1)
        )
    }

    func cliAgentQuery(
        _ request: TraceAgentQueryRequest
    ) async throws -> CLIMachineBoundTraceResult<TraceAgentQueryResult> {
        agentRequest = request
        return CLIMachineBoundTraceResult(
            snapshot: snapshot,
            value: try TraceAgentQueryResult(
                view: request.view,
                range: request.range,
                filters: request.filters,
                capabilityAvailable: true,
                truncated: false,
                dataQuality: snapshot.metadata.dataQuality
            )
        )
    }

    func cliContext(
        _ request: TraceContextRequest
    ) async throws -> CLIMachineBoundTraceResult<TraceContext> {
        contextRequest = request
        contextRequests.append(request)
        let range: TraceTimeRange
        switch request.time {
        case .range(let value):
            range = value
        case .timestamp(let timestamp, let before, let after):
            let start = timestamp >= before ? timestamp - before : 0
            let (candidateEnd, overflow) = timestamp.addingReportingOverflow(after)
            range = try TraceTimeRange.query(
                startNs: start,
                endNs: min(snapshot.metadata.durationNs, overflow ? .max : candidateEnd)
            )
        }
        let empty = TraceContextSectionStatus(
            returnedCount: 0, matchedCount: 0, truncated: false
        )
        let processes: [TraceProcess] = nearBudgetContext
            && request.maximumOutputBytes >= 4_096
            ? (0..<6).map { index in
                TraceProcess(
                    key: ProcessKey(ipid: Int64(index + 1)),
                    pid: Int64(index + 1),
                    name: String(repeating: "x", count: 250),
                    startNs: nil,
                    endNs: nil,
                    threadCount: nil
                )
            }
            : []
        let summary = TraceSummary(
            range: range,
            durationNs: range.durationNs,
            cpuCount: 0, processCount: 0, threadCount: 0,
            cpuSliceCount: 0, threadStateCount: 0,
            namedSliceCount: 0, counterSeriesCount: 0,
            eventCountBySource: [],
            capabilities: snapshot.metadata.capabilities,
            schemaFingerprint: snapshot.metadata.schemaFingerprint,
            dataQuality: snapshot.metadata.dataQuality,
            truncatedSections: []
        )
        return CLIMachineBoundTraceResult(
            snapshot: snapshot,
            value: TraceContext(
                range: range,
                filters: request.filters,
                processes: processes, threads: [], cpuSlices: [], threadStates: [],
                slices: [], counters: [], summary: summary,
                dataQuality: snapshot.metadata.dataQuality,
                truncation: TraceContextTruncation(
                    processes: .init(
                        returnedCount: processes.count,
                        matchedCount: processes.count,
                        truncated: nearBudgetContext && processes.isEmpty
                    ), threads: empty, cpuSlices: empty,
                    threadStates: empty, slices: empty, counters: empty,
                    summary: .init(returnedCount: 1, matchedCount: 1, truncated: false),
                    referenceOmittedByBudget: false
                )
            )
        )
    }

    func cliAnalyze(
        _ request: TraceDeterministicAnalysisRequest
    ) async throws -> CLIMachineBoundTraceResult<TraceDeterministicAnalysis> {
        analysisRequest = request
        let timeout = request.timeout.components
        let empty = TraceAnalysisSectionStatus(
            returnedCount: 0, matchedCount: 0, truncated: false
        )
        return CLIMachineBoundTraceResult(
            snapshot: snapshot,
            value: TraceDeterministicAnalysis(
                kind: .deterministicBatch,
                parameters: TraceDeterministicAnalysisParameters(
                    filters: request.filters,
                    maximumCPUSlices: request.maximumCPUSlices,
                    maximumProcessSlices: request.maximumProcessSlices,
                    maximumThreadSlices: request.maximumThreadSlices,
                    maximumStateIntervals: request.maximumStateIntervals,
                    maximumNamedSlices: request.maximumNamedSlices,
                    maximumSchedulingEvents: request.maximumSchedulingEvents,
                    maximumHotEvents: request.maximumHotEvents,
                    topProcessLimit: request.topProcessLimit,
                    topThreadLimit: request.topThreadLimit,
                    longSliceLimit: request.longSliceLimit,
                    schedulingSampleLimit: request.schedulingSampleLimit,
                    hotIntervalLimit: request.hotIntervalLimit,
                    hotBucketCount: request.hotBucketCount,
                    minimumLongSliceDurationNs: request.minimumLongSliceDurationNs,
                    timeoutSeconds: timeout.seconds,
                    timeoutAttoseconds: timeout.attoseconds
                ),
                range: request.range,
                cpuUtilization: [], topProcesses: [], topThreads: [],
                longSlices: [], threadStateDistribution: [],
                schedulingLatency: TraceSchedulingLatencyResult(
                    supported: false,
                    unsupportedReason: .capabilityUnavailable,
                    count: 0, percentiles: nil, topSamples: [], truncated: false
                ),
                hotIntervals: [],
                sections: TraceDeterministicAnalysisSections(
                    cpuUtilization: empty, topProcesses: empty, topThreads: empty,
                    longSlices: empty, threadStateDistribution: empty,
                    schedulingLatency: empty, hotIntervals: empty
                ),
                dataQuality: snapshot.metadata.dataQuality
            )
        )
    }

    func cliClose() async throws {
        closeCount += 1
        if let closeError { throw closeError }
    }
}

private final class TestOutputWriter: CLIOutputWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var errors = Data()
    var stdout: Data { lock.withLock { output } }
    var stderr: Data { lock.withLock { errors } }

    func writeStdout(_ data: Data) { lock.withLock { output.append(data) } }
    func writeStderr(_ data: Data) { lock.withLock { errors.append(data) } }
}

private let commandParserIdentity = TraceParserIdentity(
    name: "trace_streamer",
    reportedVersion: "4.3.7",
    binarySHA256: String(repeating: "b", count: 64),
    upstreamRepository: "https://example.invalid/upstream.git",
    upstreamRevision: String(repeating: "c", count: 40),
    architecture: "arm64",
    adapterVersion: "1",
    buildRecipeVersion: "1"
)

private func commandSnapshot(root: URL) throws -> CLIMachineTraceSnapshot {
    let fingerprint = String(repeating: "d", count: 64)
    let sourceSHA = String(repeating: "e", count: 64)
    let preparation = TraceDatabasePreparationResult(
        schemaAdapterVersion: "2",
        schemaFingerprint: fingerprint,
        indexVersion: 1,
        upstreamDatabaseSHA256: String(repeating: "f", count: 64),
        upstreamDatabaseByteCount: 4_096
    )
    let parsed = ParsedTrace(
        databaseURL: root.appendingPathComponent("trace.sqlite"),
        metadataSidecarURL: root.appendingPathComponent("metadata.json"),
        parser: commandParserIdentity,
        sourceSHA256: sourceSHA,
        sourceByteCount: 1_024,
        databasePreparation: preparation
    )
    let metadata = TraceMetadata(
        traceSHA256: sourceSHA,
        sourceByteCount: 1_024,
        durationNs: 100,
        sourceFormat: "htrace",
        parser: commandParserIdentity,
        schemaFingerprint: fingerprint,
        capabilities: TraceCapabilities(
            cpuScheduling: true,
            threadStates: true,
            namedSlices: true,
            cpuCounters: true,
            processCounters: false
        ),
        dataQuality: TraceDataQuality()
    )
    return try CLIMachineTraceSnapshot(
        parsed: parsed,
        metadata: metadata,
        cacheHit: false
    )
}
