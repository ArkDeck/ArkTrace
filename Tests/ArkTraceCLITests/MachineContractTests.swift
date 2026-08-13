import ArkTraceAnalysis
@testable import ArkTraceCLI
import ArkTraceCore
import Dispatch
import Foundation
import XCTest

final class MachineContractTests: XCTestCase {
    func testGlobalDeadlineCancelsExecutionWithoutPartialJSON() async throws {
        let executor = CancellableSuspendedExecutor(
            payload: try commandPayload(command: "inspect", scenario: "success")
        )
        let writer = ContractWriter()
        let application = CLIApplication(
            executor: executor,
            machineToolProvider: { fixtureMachineTool }
        )
        let clock = ContinuousClock()
        let started = clock.now
        let operation = Task {
            await application.run(
                arguments: ["--json", "--timeout-ms", "100", "inspect", "trace"],
                writer: writer
            )
        }
        XCTAssertEqual(executor.entered.wait(timeout: .now() + 5), .success)

        let status = await operation.value
        let elapsed = started.duration(to: clock.now)

        XCTAssertEqual(status, 7)
        XCTAssertLessThan(elapsed, .seconds(2))
        XCTAssertEqual(executor.finished.wait(timeout: .now()), .success)
        XCTAssertEqual(writer.stdoutWrites, 1)
        XCTAssertEqual(writer.stderrWrites, 0)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: writer.stdout) as? [String: Any]
        )
        XCTAssertNil(object["result"])
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? String, "QUERY_TIMEOUT")
    }

    func testCancellationDrainsExecutionAndEmitsOneTypedDocument() async throws {
        let executor = CancellableSuspendedExecutor(
            payload: try commandPayload(command: "inspect", scenario: "success")
        )
        let writer = ContractWriter()
        let application = CLIApplication(
            executor: executor,
            machineToolProvider: { fixtureMachineTool }
        )
        let operation = Task {
            await application.run(arguments: ["--json", "inspect", "trace"], writer: writer)
        }
        XCTAssertEqual(executor.entered.wait(timeout: .now() + 5), .success)

        operation.cancel()
        let status = await operation.value

        XCTAssertEqual(status, 8)
        XCTAssertEqual(executor.finished.wait(timeout: .now()), .success)
        XCTAssertEqual(writer.stdoutWrites, 1)
        XCTAssertEqual(writer.stderrWrites, 0)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: writer.stdout) as? [String: Any]
        )
        XCTAssertNil(object["result"])
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? String, "CANCELLED")

        for arguments in [["--unknown"], ["--json", "--unknown"]] {
            let malformedWriter = ContractWriter()
            let malformedOperation = Task {
                while !Task.isCancelled { await Task.yield() }
                return await application.run(arguments: arguments, writer: malformedWriter)
            }
            malformedOperation.cancel()
            let malformedStatus = await malformedOperation.value
            XCTAssertEqual(
                malformedStatus,
                8,
                "parent cancellation must outrank malformed argv"
            )
        }
    }

    func testCleanupFailureOverridesDeadlineAndParentCancellation() async throws {
        let cleanupError = ArkTraceError(
            code: .traceParseFailed,
            stage: .openingDatabase,
            message: "Injected session cleanup failure",
            retryable: true,
            details: ["reason": "sessionCleanupFailed"]
        )

        let timeoutExecutor = CleanupFailureOnCancellationExecutor(error: cleanupError)
        let timeoutWriter = ContractWriter()
        let timeoutStatus = await CLIApplication(
            executor: timeoutExecutor,
            machineToolProvider: { fixtureMachineTool }
        ).run(
            arguments: ["--json", "--timeout-ms", "100", "inspect", "trace"],
            writer: timeoutWriter
        )

        XCTAssertEqual(timeoutStatus, 4)
        XCTAssertEqual(timeoutExecutor.finished.wait(timeout: .now()), .success)
        let timeoutObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: timeoutWriter.stdout) as? [String: Any]
        )
        XCTAssertEqual(
            (timeoutObject["error"] as? [String: Any])?["code"] as? String,
            "TRACE_PARSE_FAILED"
        )
        XCTAssertEqual(
            ((timeoutObject["error"] as? [String: Any])?["details"] as? [String: String])?["reason"],
            "sessionCleanupFailed"
        )

        let cancellationExecutor = CleanupFailureOnCancellationExecutor(error: cleanupError)
        let cancellationWriter = ContractWriter()
        let operation = Task {
            await CLIApplication(
                executor: cancellationExecutor,
                machineToolProvider: { fixtureMachineTool }
            ).run(arguments: ["--json", "inspect", "trace"], writer: cancellationWriter)
        }
        XCTAssertEqual(cancellationExecutor.entered.wait(timeout: .now() + 5), .success)
        operation.cancel()

        let cancellationStatus = await operation.value
        XCTAssertEqual(cancellationStatus, 4)
        XCTAssertEqual(cancellationExecutor.finished.wait(timeout: .now()), .success)
        let cancellationObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: cancellationWriter.stdout) as? [String: Any]
        )
        XCTAssertEqual(
            (cancellationObject["error"] as? [String: Any])?["code"] as? String,
            "TRACE_PARSE_FAILED"
        )
        XCTAssertEqual(
            ((cancellationObject["error"] as? [String: Any])?["details"] as? [String: String])?["reason"],
            "sessionCleanupFailed"
        )

        let impostor = ArkTraceError(
            code: .queryFailed,
            stage: .querying,
            message: "Not an ownership cleanup failure",
            details: ["reason": "sessionCleanupFailed"]
        )
        let impostorExecutor = CleanupFailureOnCancellationExecutor(error: impostor)
        let impostorWriter = ContractWriter()
        let impostorStatus = await CLIApplication(
            executor: impostorExecutor,
            machineToolProvider: { fixtureMachineTool }
        ).run(
            arguments: ["--json", "--timeout-ms", "100", "inspect", "trace"],
            writer: impostorWriter
        )
        XCTAssertEqual(impostorStatus, 7, "a reason token cannot spoof cleanup priority")
        let impostorObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: impostorWriter.stdout) as? [String: Any]
        )
        XCTAssertEqual(
            (impostorObject["error"] as? [String: Any])?["code"] as? String,
            "QUERY_TIMEOUT"
        )
    }

    func testDeadlineIncludesEncodingAndHumanOutputBudget() async throws {
        let usageWriter = ContractWriter()
        let usageStatus = await CLIApplication(
            executor: FixedExecutor(),
            machineToolProvider: {
                Thread.sleep(forTimeInterval: 0.15)
                return fixtureMachineTool
            }
        ).run(
            arguments: [
                "--json", "--timeout-ms", "100", "--timeout-ms", "100",
                "inspect", "trace",
            ],
            writer: usageWriter
        )
        XCTAssertEqual(usageStatus, 2, "invalid syntax has priority over execution deadline")
        let usageObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: usageWriter.stdout) as? [String: Any]
        )
        XCTAssertEqual(
            (usageObject["error"] as? [String: Any])?["code"] as? String,
            "INVALID_ARGUMENT"
        )

        let identityWriter = ContractWriter()
        let identityStatus = await CLIApplication(
            executor: FixedExecutor(
                machinePayload: try commandPayload(command: "inspect", scenario: "success")
            ),
            machineToolProvider: {
                Thread.sleep(forTimeInterval: 0.15)
                return fixtureMachineTool
            }
        ).run(
            arguments: ["--json", "--timeout-ms", "100", "inspect", "trace"],
            writer: identityWriter
        )
        XCTAssertEqual(identityStatus, 7, "tool provenance work is inside the command deadline")
        XCTAssertTrue(identityWriter.stdout.isEmpty)
        XCTAssertTrue(String(decoding: identityWriter.stderr, as: UTF8.self).contains(
            "QUERY_TIMEOUT"
        ))

        let failingIdentityWriter = ContractWriter()
        let failingIdentityStatus = await CLIApplication(
            executor: FixedExecutor(
                machinePayload: try commandPayload(command: "inspect", scenario: "success")
            ),
            machineToolProvider: {
                Thread.sleep(forTimeInterval: 0.15)
                throw ArkTraceError(
                    code: .internalError,
                    stage: .hashing,
                    message: "Injected executable identity failure"
                )
            }
        ).run(
            arguments: ["--json", "--timeout-ms", "100", "inspect", "trace"],
            writer: failingIdentityWriter
        )
        XCTAssertEqual(
            failingIdentityStatus,
            7,
            "an expired invocation overrides a delayed provenance failure"
        )
        XCTAssertTrue(failingIdentityWriter.stdout.isEmpty)
        XCTAssertTrue(String(decoding: failingIdentityWriter.stderr, as: UTF8.self).contains(
            "QUERY_TIMEOUT"
        ))

        let cooperativeProvider = CooperativeMachineToolProvider()
        let cooperativeWriter = ContractWriter()
        let cooperativeStatus = await CLIApplication(
            executor: FixedExecutor(
                machinePayload: try commandPayload(command: "inspect", scenario: "success")
            ),
            machineToolProvider: { try cooperativeProvider.resolve() }
        ).run(
            arguments: ["--json", "--timeout-ms", "100", "inspect", "trace"],
            writer: cooperativeWriter
        )
        XCTAssertEqual(cooperativeStatus, 7)
        XCTAssertEqual(cooperativeProvider.cancelled.wait(timeout: .now()), .success)
        XCTAssertEqual(cooperativeProvider.finished.wait(timeout: .now()), .success)
        XCTAssertTrue(cooperativeWriter.stdout.isEmpty)

        let delayedFailureWriter = ContractWriter()
        let delayedFailureStatus = await CLIApplication(
            executor: DelayedFailureExecutor(),
            machineToolProvider: { fixtureMachineTool }
        ).run(
            arguments: ["--json", "--timeout-ms", "100", "inspect", "trace"],
            writer: delayedFailureWriter
        )
        XCTAssertEqual(delayedFailureStatus, 7)
        let delayedFailureObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: delayedFailureWriter.stdout) as? [String: Any]
        )
        XCTAssertEqual(
            (delayedFailureObject["error"] as? [String: Any])?["code"] as? String,
            "QUERY_TIMEOUT"
        )

        let hugeNumericArgument = String(repeating: "9", count: 16 * 1_024 + 1)
        let boundedHint = CLIArgumentParser.machinePresentationHint([
            "--json", "--timeout-ms", hugeNumericArgument,
        ])
        XCTAssertEqual(boundedHint.timeoutMs, CLILimits.defaultTimeoutMs)
        let excessivePrefix = Array(repeating: "padding", count: 257) + ["summary"]
        XCTAssertEqual(CLIMachineRequest.hint(for: excessivePrefix).command, "unknown")

        let encodingEntered = DispatchSemaphore(value: 0)
        let payload = try commandPayload(command: "inspect", scenario: "success")
        let machineWriter = ContractWriter()
        let application = CLIApplication(
            executor: FixedExecutor(machinePayload: payload),
            machineToolProvider: { fixtureMachineTool },
            beforeEncoding: {
                encodingEntered.signal()
                try await Task.sleep(for: .seconds(5))
            }
        )
        let operation = Task {
            await application.run(
                arguments: ["--json", "--timeout-ms", "100", "inspect", "trace"],
                writer: machineWriter
            )
        }
        XCTAssertEqual(encodingEntered.wait(timeout: .now() + 5), .success)
        let timeoutStatus = await operation.value
        XCTAssertEqual(timeoutStatus, 7)
        XCTAssertEqual(machineWriter.stdoutWrites, 1)
        let timeoutObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: machineWriter.stdout) as? [String: Any]
        )
        XCTAssertEqual(
            (timeoutObject["error"] as? [String: Any])?["code"] as? String,
            "QUERY_TIMEOUT"
        )

        let humanWriter = ContractWriter()
        let oversized = CLIApplication(
            executor: FixedExecutor(
                stdout: Data(repeating: UInt8(ascii: "x"), count: 800),
                stderr: Data(repeating: UInt8(ascii: "y"), count: 300)
            ),
            machineToolProvider: { fixtureMachineTool }
        )
        let outputStatus = await oversized.run(
            arguments: ["--max-output-bytes", "1024", "inspect", "trace"],
            writer: humanWriter
        )
        XCTAssertEqual(outputStatus, 7)
        XCTAssertEqual(humanWriter.stdoutWrites, 0)
        XCTAssertTrue(String(decoding: humanWriter.stderr, as: UTF8.self).contains(
            "OUTPUT_LIMIT_EXCEEDED"
        ))
    }

    func testSignalMonitorCancelsOnceThenAllowsForcedExit() throws {
        let state = SignalTestState()
        let monitor = CLISignalMonitor(
            onFirstSignal: { state.recordCancellation() },
            onSecondSignal: { signal in state.recordForced(signal) }
        )

        monitor.receiveForTesting(SIGINT)
        XCTAssertEqual(state.cancellations, 1)
        XCTAssertTrue(state.forced.isEmpty)
        monitor.receiveForTesting(SIGTERM)
        XCTAssertEqual(state.cancellations, 1)
        XCTAssertEqual(state.forced, [SIGTERM])
        monitor.receiveForTesting(SIGINT)
        XCTAssertEqual(state.forced, [SIGTERM])

        let lifecycleMonitors = (0..<2).map { _ in
            CLISignalMonitor(onFirstSignal: {}, onSecondSignal: { _ in })
        }
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            let lifecycleMonitor = lifecycleMonitors[index % lifecycleMonitors.count]
            if (index / lifecycleMonitors.count).isMultiple(of: 2) {
                try? lifecycleMonitor.start()
            } else {
                lifecycleMonitor.stop()
            }
        }
        lifecycleMonitors.forEach { $0.stop() }

        let installedSignal = DispatchSemaphore(value: 0)
        let installWindowMonitor = CLISignalMonitor(
            onFirstSignal: { installedSignal.signal() },
            onSecondSignal: { _ in }
        )
        try installWindowMonitor.start(beforeSourceActivation: {
            _ = Darwin.kill(Darwin.getpid(), SIGINT)
            waitForPendingProcessSignal()
        })
        XCTAssertTrue(CLISignalMonitor.hasPendingSignal)
        XCTAssertEqual(
            installedSignal.wait(timeout: .now() + 5),
            .success,
            "a signal captured before Dispatch activation must not be lost"
        )
        installWindowMonitor.stop()
    }

    func testCancellationAtFinalSuccessBoundaryCannotCommitSuccess() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writer = ContractWriter()
        let payload = try commandPayload(command: "summary", scenario: "success")
        let application = CLIApplication(
            executor: FixedExecutor(machinePayload: payload),
            machineToolProvider: { fixtureMachineTool },
            beforeSuccessCommit: {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
        )

        let operation = Task {
            await application.run(arguments: ["--json", "summary", "trace"], writer: writer)
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        operation.cancel()
        release.signal()

        let status = await operation.value
        XCTAssertEqual(status, 8)
        XCTAssertEqual(writer.stdoutWrites, 1)
        XCTAssertEqual(writer.stderrWrites, 0)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: writer.stdout) as? [String: Any]
        )
        XCTAssertNil(object["result"])
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? String, "CANCELLED")

        let deliveryEntered = DispatchSemaphore(value: 0)
        let releaseDelivery = DispatchSemaphore(value: 0)
        let pendingObserved = LockedFlag()
        let signalWriter = ContractWriter()
        let signalMonitor = CLISignalMonitor(
            onFirstSignal: {},
            onSecondSignal: { _ in },
            beforeDelivery: {
                deliveryEntered.signal()
                _ = releaseDelivery.wait(timeout: .now() + 5)
            }
        )
        try signalMonitor.start()
        let signalApplication = CLIApplication(
            executor: FixedExecutor(machinePayload: payload),
            machineToolProvider: { fixtureMachineTool },
            beforeSuccessCommit: {
                _ = Darwin.kill(Darwin.getpid(), SIGINT)
                waitForPendingProcessSignal()
                pendingObserved.set(CLISignalMonitor.hasPendingSignal)
            }
        )
        let signalStatus = await signalApplication.run(
            arguments: ["--json", "summary", "trace"],
            writer: signalWriter
        )

        XCTAssertEqual(deliveryEntered.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(pendingObserved.value)
        XCTAssertEqual(signalStatus, 8, "captured signal must linearize before success commit")
        let signalObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: signalWriter.stdout) as? [String: Any]
        )
        XCTAssertNil(signalObject["result"])
        XCTAssertEqual(
            (signalObject["error"] as? [String: Any])?["code"] as? String,
            "CANCELLED"
        )
        releaseDelivery.signal()
        signalMonitor.stop()
    }

    func testCancellationWhileDiagnosticWriterBlocksCannotCommitSuccess() async throws {
        let writer = BlockingDiagnosticWriter()
        let application = CLIApplication(
            executor: FixedExecutor(
                stdout: Data("stale success\n".utf8),
                stderr: Data(repeating: UInt8(ascii: "d"), count: 1_000)
            ),
            machineToolProvider: { fixtureMachineTool }
        )

        let operation = Task {
            await application.run(
                arguments: ["--max-output-bytes", "1024", "summary", "trace"],
                writer: writer
            )
        }
        XCTAssertEqual(writer.entered.wait(timeout: .now() + 5), .success)
        operation.cancel()
        writer.release.signal()

        let status = await operation.value
        XCTAssertEqual(status, 8)
        XCTAssertEqual(writer.stdoutWrites, 0)
        XCTAssertFalse(String(decoding: writer.stderr, as: UTF8.self).contains("stale success"))
        XCTAssertLessThanOrEqual(writer.stderr.count, 1_024)
        XCTAssertEqual(writer.stderr.count, 1_000)
    }

    func testSchemaVersionUsesMajorMinorAndMajorCompatibility() throws {
        XCTAssertEqual(CLIMachineSchemaVersion.current.stringValue, "1.0")
        XCTAssertTrue(try CLIMachineSchemaVersion("1.99").isCompatible(with: .current))
        XCTAssertFalse(try CLIMachineSchemaVersion("2.0").isCompatible(with: .current))
        for invalid in ["1", "01.0", "1.00", "1.-1", "1.0.0", "1000.0"] {
            XCTAssertThrowsError(try CLIMachineSchemaVersion(invalid), "value: \(invalid)")
        }
        for (name, version, revision) in [
            ("other", ArkTraceCLITool.version, String(repeating: "f", count: 64)),
            (ArkTraceCLITool.name, "999", String(repeating: "f", count: 64)),
            (ArkTraceCLITool.name, ArkTraceCLITool.version, "forged"),
            (ArkTraceCLITool.name, ArkTraceCLITool.version, String(repeating: "F", count: 64)),
        ] {
            XCTAssertThrowsError(try CLIMachineTool(
                name: name,
                version: version,
                buildRevision: revision
            ))
        }
    }

    func testSuccessGoldenHasExplicitNullsIntegerTimesTypedQualityAndProvenance() throws {
        struct Result: Codable, Sendable {
            let emptyRows: [Int]
            let unknownNs: Int64?

            private enum CodingKeys: String, CodingKey { case emptyRows; case unknownNs }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(emptyRows, forKey: .emptyRows)
                if let unknownNs { try container.encode(unknownNs, forKey: .unknownNs) }
                else { try container.encodeNil(forKey: .unknownNs) }
            }
        }

        let metadata = fixtureMetadata(quality: TraceDataQuality(issues: [
            TraceDataQualityIssue(
                category: .probeTruncated,
                scope: "thread.start_ts",
                message: "probe incomplete"
            ),
            TraceDataQualityIssue(
                category: .clampedValue,
                scope: "process.start_ts",
                count: 2,
                message: "display clamped"
            ),
            TraceDataQualityIssue(
                category: .droppedValue,
                scope: "stat.source",
                count: 3,
                message: "value dropped"
            ),
            TraceDataQualityIssue(
                category: .referentialIntegrity,
                scope: "thread.ipid",
                count: 1,
                message: "reference unavailable"
            ),
        ]))
        let envelope = CLIMachineSuccessEnvelope(
            tool: fixtureMachineTool,
            trace: try CLIMachineTrace(metadata: metadata),
            request: try CLIMachineRequest(
                command: "summary",
                parameters: ["startNs": .int64(Int64.max), "endNs": .null]
            ),
            limits: CLIMachineLimits(try CLILimits()),
            result: Result(emptyRows: [], unknownNs: nil),
            dataQuality: try CLIMachineDataQuality(metadata.dataQuality),
            truncation: try CLIMachineTruncation(sections: ["threads", "processes", "threads"]),
            provenance: try CLIMachineProvenance(
                parser: metadata.parser,
                preparation: fixturePreparation()
            )
        )
        let encoded = try CLIMachineEncoder().encode(
            envelope,
            pretty: false,
            maximumBytes: 64 * 1_024
        )
        let expected = #"{"dataQuality":{"status":"warnings","warnings":[{"category":"clampedValue","count":2,"message":null,"scope":"process.start_ts"},{"category":"droppedValue","count":3,"message":null,"scope":"stat.source"},{"category":"probeTruncated","count":null,"message":null,"scope":"thread.start_ts"},{"category":"referentialIntegrity","count":1,"message":null,"scope":"thread.ipid"}]},"limits":{"maxEvents":10000,"maxOutputBytes":8388608,"maxRows":10000,"timeoutMs":30000},"provenance":{"indexSchemaVersion":1,"parserAdapterVersion":"1","parserBuildRecipeVersion":"1","schemaAdapterVersion":"2","upstreamDatabaseByteCount":4096,"upstreamDatabaseSha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},"request":{"command":"summary","parameters":{"endNs":null,"startNs":9223372036854775807}},"result":{"emptyRows":[],"unknownNs":null},"schemaVersion":"1.0","tool":{"buildRevision":"abc123","name":"arktrace","version":"0.1.0"},"trace":{"byteCount":1234,"durationNs":9223372036854775807,"parser":{"binarySha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","name":"trace_streamer","upstreamRevision":"revision","version":"4.3.7"},"schemaFingerprint":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"truncation":{"sections":["processes","threads"],"truncated":true}}"# + "\n"
        XCTAssertEqual(
            String(decoding: encoded, as: UTF8.self),
            expected.replacingOccurrences(
                of: "abc123",
                with: fixtureMachineTool.buildRevision
            ).replacingOccurrences(
                of: "\"upstreamRevision\":\"revision\"",
                with: "\"upstreamRevision\":\"\(String(repeating: "e", count: 40))\""
            )
        )
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("e+"))
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"truncated\":true"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("\"error\""))

        let repeated = try CLIMachineEncoder().encode(
            envelope,
            pretty: false,
            maximumBytes: 64 * 1_024
        )
        XCTAssertEqual(encoded, repeated)
    }

    func testEmptyResultIsSuccessfulAndNotTruncated() throws {
        let envelope = CLIMachineSuccessEnvelope(
            tool: fixtureMachineTool,
            trace: nil,
            request: try CLIMachineRequest(command: "processes"),
            limits: CLIMachineLimits(try CLILimits()),
            result: CLIJSONValue.object(["items": .array([])]),
            dataQuality: try CLIMachineDataQuality(TraceDataQuality()),
            truncation: try CLIMachineTruncation(),
            provenance: nil
        )
        let data = try CLIMachineEncoder().encode(envelope, pretty: false, maximumBytes: 8_192)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(object["error"])
        XCTAssertEqual(
            ((object["truncation"] as? [String: Any])?["truncated"] as? Bool),
            false
        )
        XCTAssertEqual(
            ((((object["result"] as? [String: Any])?["items"] as? [Any])?.count)),
            0
        )
    }

    func testMachineErrorUsesCanonicalMessageSafeDetailsAndStableFields() throws {
        let sourcePath = "/Users/secret/trace.sqlite"
        let error = ArkTraceError(
            code: .traceSchemaUnsupported,
            stage: .validating,
            message: "unsafe \(sourcePath) SELECT * FROM process",
            retryable: false,
            details: [
                "missingCapability": "cpuScheduling",
                "sourcePath": sourcePath,
                "rawSQL": "SELECT * FROM process",
                "relationship": "failure: SELECT * FROM secret",
                "reason": "unsupported",
            ]
        )
        let envelope = CLIMachineErrorEnvelope(
            tool: fixtureMachineTool,
            request: try CLIMachineRequest(command: "inspect"),
            error: error
        )
        let data = try CLIMachineEncoder().encode(envelope, pretty: false, maximumBytes: 8_192)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(
            text,
            (#"{"error":{"code":"TRACE_SCHEMA_UNSUPPORTED","details":{"missingCapability":"cpuScheduling","reason":"unsupported"},"message":"The parsed trace schema is not supported.","retryable":false,"stage":"validating"},"request":{"command":"inspect","parameters":{}},"schemaVersion":"1.0","tool":{"buildRevision":"abc123","name":"arktrace","version":"0.1.0"}}"# + "\n")
                .replacingOccurrences(of: "abc123", with: fixtureMachineTool.buildRevision)
        )
        XCTAssertFalse(text.contains(sourcePath))
        XCTAssertFalse(text.contains("SELECT"))
    }

    func testEveryMachineErrorKeepsSpecifiedStageAndRetryability() {
        let contract: [(ArkTraceError.Code, ArkTraceError.Stage, Bool)] = [
            (.invalidArgument, .request, false),
            (.traceFileNotFound, .preparing, false),
            (.traceFileUnreadable, .preparing, false),
            (.traceFormatUnsupported, .parsing, false),
            (.traceStreamerUnavailable, .preparing, true),
            (.traceStreamerIdentityMismatch, .preparing, false),
            (.traceParseFailed, .parsing, false),
            (.traceSchemaUnsupported, .validating, false),
            (.traceDatabaseInvalid, .validating, false),
            (.traceCacheCorrupt, .cacheLookup, true),
            (.queryFailed, .querying, false),
            (.queryTimeout, .querying, true),
            (.queryLimitExceeded, .querying, true),
            (.outputLimitExceeded, .encoding, true),
            (.analysisUnsupported, .analyzing, false),
            (.cancelled, .analyzing, true),
            (.internalError, .encoding, false),
        ]
        XCTAssertEqual(contract.count, ArkTraceError.Code.allCases.count)
        for (code, stage, retryable) in contract {
            let machine = CLIMachineError(ArkTraceError(
                code: code,
                stage: stage,
                message: "caller text is not the machine contract",
                retryable: retryable
            ))
            XCTAssertEqual(machine.code, code)
            XCTAssertEqual(machine.stage, stage)
            XCTAssertEqual(machine.retryable, retryable)
            XCTAssertFalse(machine.message.isEmpty)
        }
    }

    func testUnavailableExecutorUsesSpecifiedAnalysisErrorPolicy() async {
        do {
            _ = try await CLIUnavailableCommandExecutor().execute(
                try! CLIArgumentParser().parse(["inspect", "trace"])
            )
            XCTFail("expected unsupported error")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .analysisUnsupported)
            XCTAssertEqual(error.stage, .analyzing)
            XCTAssertFalse(error.retryable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEveryPhase2CommandHasSuccessEmptyTruncatedAndTypedErrorGolden() async throws {
        let commands: [[String]] = [
            ["--json", "doctor"],
            ["--json", "inspect", "trace"],
            ["--json", "summary", "trace"],
            ["--json", "processes", "trace"],
            ["--json", "threads", "trace"],
        ]
        for arguments in commands {
            let invocation = try CLIArgumentParser().parse(arguments)
            let request = try invocation.machineRequest()
            let scenarios = ["success", "empty", "truncated"]
            for scenario in scenarios {
                let scenarioArguments = scenario == "truncated"
                    && ["processes", "threads"].contains(request.command)
                    ? ["--json", request.command, "trace", "--limit", "1"]
                    : scenario == "truncated" && request.command == "doctor"
                        ? ["--json", "--max-rows", "1", "doctor"]
                        : arguments
                let payload = try commandPayload(command: request.command, scenario: scenario)
                let writer = ContractWriter()
                let status = await machineApplication(
                    executor: FixedExecutor(machinePayload: payload)
                ).run(
                    arguments: scenarioArguments,
                    writer: writer
                )
                XCTAssertEqual(status, 0, "\(request.command) \(scenario)")
                XCTAssertEqual(writer.stderrWrites, 0)
                let first = writer.stdout
                let repeatedWriter = ContractWriter()
                let repeatedStatus = await machineApplication(
                    executor: FixedExecutor(machinePayload: payload)
                ).run(arguments: scenarioArguments, writer: repeatedWriter)
                XCTAssertEqual(repeatedStatus, 0)
                XCTAssertEqual(first, repeatedWriter.stdout)
                let object = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: first) as? [String: Any]
                )
                XCTAssertNotNil(object["result"])
                XCTAssertNil(object["error"])
                XCTAssertEqual(
                    (object["truncation"] as? [String: Any])?["truncated"] as? Bool,
                    scenario == "truncated"
                )
            }

            let errorWriter = ContractWriter()
            let status = await machineApplication(
                executor: ErrorExecutor(error: ArkTraceError(
                    code: .queryFailed,
                    stage: .querying,
                    message: "query failed"
                ))
            ).run(arguments: arguments, writer: errorWriter)
            XCTAssertEqual(status, 6, "\(request.command) typed error")
            let errorGolden = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: errorWriter.stdout) as? [String: Any]
            )
            XCTAssertEqual(
                ((errorGolden["request"] as? [String: Any])?["command"] as? String),
                request.command
            )
            XCTAssertEqual(
                ((errorGolden["error"] as? [String: Any])?["code"] as? String),
                "QUERY_FAILED"
            )
        }
    }

    func testMachineApplicationWritesOneJSONDocumentAndNoStderr() async throws {
        let executor = FixedExecutor(machinePayload: try commandPayload(
            command: "inspect",
            scenario: "success"
        ))
        let writer = ContractWriter()
        let status = await machineApplication(executor: executor).run(
            arguments: ["--json", "inspect", "trace"],
            writer: writer
        )
        XCTAssertEqual(status, 0)
        XCTAssertEqual(writer.stdoutWrites, 1)
        XCTAssertEqual(writer.stderrWrites, 0)
        XCTAssertEqual(writer.stdout.last, UInt8(ascii: "\n"))
        XCTAssertTrue(String(decoding: writer.stdout, as: UTF8.self).hasPrefix("{\"dataQuality\":"))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: writer.stdout) as? [String: Any]
        )
        XCTAssertEqual(
            ((object["result"] as? [String: Any])?["cacheHit"] as? Bool),
            true
        )
    }

    func testExecutorCannotBypassMachineEnvelopeContract() async throws {
        let typedError = try CLIMachineEncoder().encode(
            CLIMachineErrorEnvelope(
                tool: fixtureMachineTool,
                request: try CLIMachineRequest(command: "inspect"),
                error: ArkTraceError(code: .queryFailed, stage: .querying, message: "failed")
            ),
            pretty: false,
            maximumBytes: 8_192
        )
        for invalid in [
            Data("{\"result\":{}}".utf8),
            Data("{\"schemaVersion\":\"2.0\",\"result\":{}}".utf8),
            Data("{\"schemaVersion\":\"1.0\",\"result\":{},\"error\":{}}".utf8),
            typedError,
        ] {
            let writer = ContractWriter()
            let status = await machineApplication(
                executor: FixedExecutor(stdout: invalid)
            ).run(
                arguments: ["--json", "inspect", "trace"],
                writer: writer
            )
            XCTAssertEqual(status, 9)
            XCTAssertEqual(writer.stdoutWrites, 1)
            XCTAssertEqual(writer.stderrWrites, 0)
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: writer.stdout) as? [String: Any]
            )
            XCTAssertEqual(
                ((object["error"] as? [String: Any])?["code"] as? String),
                "INTERNAL_ERROR"
            )
        }
    }

    func testMachineErrorIsSingleStdoutDocumentWithTypedExitAndNoPath() async throws {
        let writer = ContractWriter()
        let status = await machineApplication(executor: ErrorExecutor(error: ArkTraceError(
                code: .traceFileNotFound,
                stage: .preparing,
                message: "missing /Users/private.trace"
            ))).run(
                arguments: ["--json", "inspect", "/Users/private.trace"],
                writer: writer
            )
        XCTAssertEqual(status, 3)
        XCTAssertEqual(writer.stdoutWrites, 1)
        XCTAssertEqual(writer.stderrWrites, 0)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: writer.stdout) as? [String: Any]
        )
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "TRACE_FILE_NOT_FOUND")
        XCTAssertFalse(String(decoding: writer.stdout, as: UTF8.self).contains("/Users"))
    }

    func testMachineUsageErrorCanChooseJSONBeforeFullParsing() async throws {
        let writer = ContractWriter()
        let status = await machineApplication().run(
            arguments: ["--json", "--pretty", "inspect"],
            writer: writer
        )
        XCTAssertEqual(status, 2)
        XCTAssertEqual(writer.stdoutWrites, 1)
        XCTAssertEqual(writer.stderrWrites, 0)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: writer.stdout) as? [String: Any]
        )
        XCTAssertEqual(
            ((object["error"] as? [String: Any])?["code"] as? String),
            "INVALID_ARGUMENT"
        )
        XCTAssertEqual(
            ((object["request"] as? [String: Any])?["command"] as? String),
            "inspect"
        )
        XCTAssertTrue(String(decoding: writer.stdout, as: UTF8.self).contains("\n  \"error\""))
    }

    func testOutputBudgetBoundaryNeverWritesPartialJSON() async throws {
        let envelope = CLIMachineErrorEnvelope(
            tool: fixtureMachineTool,
            request: try CLIMachineRequest(command: "inspect"),
            error: ArkTraceError(code: .internalError, stage: .encoding, message: "unsafe")
        )
        let full = try CLIMachineEncoder().encode(envelope, pretty: false, maximumBytes: 8_192)
        XCTAssertNoThrow(try CLIMachineEncoder().validateDocument(full, maximumBytes: full.count))
        XCTAssertThrowsError(
            try CLIMachineEncoder().validateDocument(full, maximumBytes: full.count - 1)
        ) { error in
            XCTAssertEqual((error as? ArkTraceError)?.code, .outputLimitExceeded)
        }

        let oversizedPayload = try CLIMachineCommandPayload.processes(
            metadata: fixtureMetadata(),
            preparation: fixturePreparation(),
            page: BoundedPage(items: [TraceProcess(
                key: ProcessKey(ipid: 1),
                pid: 1,
                name: String(repeating: "x", count: 2_000),
                startNs: nil,
                endNs: nil,
                threadCount: nil
            )], truncated: false)
        )
        let writer = ContractWriter()
        let status = await machineApplication(
            executor: FixedExecutor(machinePayload: oversizedPayload)
        ).run(
            arguments: ["--json", "--max-output-bytes", "1024", "processes", "trace"],
            writer: writer
        )
        XCTAssertEqual(status, 7)
        XCTAssertEqual(writer.stdoutWrites, 1)
        XCTAssertLessThanOrEqual(writer.stdout.count, 1_024)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: writer.stdout) as? [String: Any]
        )
        XCTAssertEqual(
            ((object["error"] as? [String: Any])?["code"] as? String),
            "OUTPUT_LIMIT_EXCEEDED"
        )

        let oversizedErrorWriter = ContractWriter()
        let oversizedErrorStatus = await machineApplication(executor: ErrorExecutor(error:
            ArkTraceError(code: .queryFailed, stage: .querying, message: "failed")
        )).run(
            arguments: [
                "--json", "--max-output-bytes", "1024", "processes", "trace",
                "--name", String(repeating: "n", count: 1_000),
            ],
            writer: oversizedErrorWriter
        )
        XCTAssertEqual(oversizedErrorStatus, 7)
        XCTAssertEqual(oversizedErrorWriter.stdoutWrites, 1)
        XCTAssertEqual(oversizedErrorWriter.stderrWrites, 0)
        let minimumError = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: oversizedErrorWriter.stdout)
                as? [String: Any]
        )
        XCTAssertEqual(
            ((minimumError["error"] as? [String: Any])?["code"] as? String),
            "OUTPUT_LIMIT_EXCEEDED"
        )
        XCTAssertLessThanOrEqual(oversizedErrorWriter.stdout.count, 1_024)

        XCTAssertThrowsError(
            try CLIMachineEncoder().encode(envelope, pretty: false, maximumBytes: 1)
        ) { error in
            XCTAssertEqual((error as? ArkTraceError)?.code, .outputLimitExceeded)
        }
    }

    func testValidatorRejectsPrivacyFieldsAndNonIntegerNanoseconds() throws {
        for document in [
            #"{"sourcePath":"/Users/private"}"#,
            #"{"rawSQL":"SELECT * FROM process"}"#,
            #"{"environment":{"HOME":"/Users/private"}}"#,
            #"{"durationNs":1.5}"#,
            #"{"durationNs":"1"}"#,
        ] {
            XCTAssertThrowsError(
                try CLIMachineEncoder().validateDocument(
                    Data((document + "\n").utf8), maximumBytes: 8_192
                ),
                "document: \(document)"
            )
        }
        for legitimateTraceData in [
            #"{"name":"/system/bin/app"}"#,
            #"{"name":"SELECT worker"}"#,
            #"{"name":"prefix /Users/private"}"#,
        ] {
            XCTAssertNoThrow(
                try CLIMachineEncoder().validateDocument(
                    Data((legitimateTraceData + "\n").utf8), maximumBytes: 8_192
                )
            )
        }
    }

    func testMachineQualityKeepsProbeTruncationDistinctFromRealAnomalies() throws {
        let encoded = try CLIMachineEncoder().encode(
            CLIMachineDataQuality(TraceDataQuality(issues: [
                TraceDataQualityIssue(category: .probeTruncated, scope: "thread.start_ts"),
                TraceDataQualityIssue(category: .invalidValue, scope: "stat.count"),
                TraceDataQualityIssue(category: .clampedValue, scope: "process.start_ts"),
                TraceDataQualityIssue(category: .droppedValue, scope: "stat.source"),
                TraceDataQualityIssue(category: .referentialIntegrity, scope: "thread.ipid"),
            ])),
            pretty: false,
            maximumBytes: 8_192
        )
        let text = String(decoding: encoded, as: UTF8.self)
        for category in TraceDataQualityIssue.Category.allCases where category != .unclassified {
            XCTAssertTrue(text.contains("\"category\":\"\(category.rawValue)\""))
        }
        XCTAssertThrowsError(
            try CLIMachineDataQuality(TraceDataQuality(warnings: ["legacy warning"]))
        ) { error in
            let typed = error as? ArkTraceError
            XCTAssertEqual(typed?.code, .internalError)
            XCTAssertEqual(typed?.stage, .encoding)
        }
    }
}

private func commandPayload(
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
        let metadata = fixtureMetadata(
            capabilities: scenario == "empty" ? emptyCapabilities : fixtureCapabilities,
            quality: truncated ? TraceDataQuality(issues: [
                TraceDataQualityIssue(category: .probeTruncated, scope: "thread.start_ts"),
            ]) : TraceDataQuality()
        )
        return try .inspect(
            metadata: metadata,
            preparation: fixturePreparation(),
            cacheHit: hasItem
        )
    case "summary":
        let metadata = fixtureMetadata()
        return try .summary(
            metadata: metadata,
            preparation: fixturePreparation(),
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
                eventCountBySource: hasItem ? [
                    TraceEventSourceCount(source: "sched_slice", count: 1),
                ] : [],
                capabilities: metadata.capabilities,
                schemaFingerprint: metadata.schemaFingerprint,
                dataQuality: metadata.dataQuality,
                truncatedSections: truncated ? [.threadStateCount] : []
            )
        )
    case "processes":
        return try .processes(
            metadata: fixtureMetadata(),
            preparation: fixturePreparation(),
            page: BoundedPage(
                items: hasItem ? [TraceProcess(
                    key: ProcessKey(ipid: 1),
                    pid: 1,
                    name: "worker",
                    startNs: nil,
                    endNs: nil,
                    threadCount: nil
                )] : [],
                truncated: truncated
            )
        )
    case "threads":
        return try .threads(
            metadata: fixtureMetadata(),
            preparation: fixturePreparation(),
            page: BoundedPage(
                items: hasItem ? [TraceThread(
                    key: ThreadKey(itid: 1),
                    processKey: ProcessKey(ipid: 1),
                    tid: 1,
                    pid: 1,
                    name: "worker",
                    processName: "process",
                    startNs: nil,
                    endNs: nil,
                    isMainThread: true
                )] : [],
                truncated: truncated
            )
        )
    default:
        throw ArkTraceError(
            code: .internalError,
            stage: .encoding,
            message: "Unknown test command"
        )
    }
}

private let fixtureMachineTool = try! CLIMachineTool(
    name: ArkTraceCLITool.name,
    version: ArkTraceCLITool.version,
    buildRevision: String(repeating: "f", count: 64)
)

private func machineApplication(
    executor: any CLICommandExecuting = CLIUnavailableCommandExecutor()
) -> CLIApplication {
    CLIApplication(
        executor: executor,
        machineToolProvider: { fixtureMachineTool }
    )
}

private let fixtureCapabilities = TraceCapabilities(
    cpuScheduling: true,
    threadStates: true,
    namedSlices: true,
    cpuCounters: true,
    processCounters: false
)

private let emptyCapabilities = TraceCapabilities(
    cpuScheduling: false,
    threadStates: false,
    namedSlices: false,
    cpuCounters: false,
    processCounters: false
)

private func fixtureMetadata(
    capabilities: TraceCapabilities = fixtureCapabilities,
    quality: TraceDataQuality = TraceDataQuality()
) -> TraceMetadata {
    TraceMetadata(
        traceSHA256: String(repeating: "a", count: 64),
        sourceByteCount: 1_234,
        durationNs: Int64.max,
        sourceFormat: nil,
        parser: TraceParserIdentity(
            name: "trace_streamer",
            reportedVersion: "4.3.7",
            binarySHA256: String(repeating: "b", count: 64),
            upstreamRepository: "https://example.invalid/repository",
            upstreamRevision: String(repeating: "e", count: 40),
            architecture: "arm64",
            adapterVersion: "1",
            buildRecipeVersion: "1"
        ),
        schemaFingerprint: String(repeating: "d", count: 64),
        capabilities: capabilities,
        dataQuality: quality
    )
}

private func fixturePreparation() -> TraceDatabasePreparationResult {
    TraceDatabasePreparationResult(
        schemaAdapterVersion: "2",
        schemaFingerprint: String(repeating: "d", count: 64),
        indexVersion: 1,
        upstreamDatabaseSHA256: String(repeating: "c", count: 64),
        upstreamDatabaseByteCount: 4_096
    )
}

private final class ContractWriter: CLIOutputWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var errors = Data()
    private var outputWrites = 0
    private var errorWrites = 0

    var stdout: Data { lock.withLock { output } }
    var stderr: Data { lock.withLock { errors } }
    var stdoutWrites: Int { lock.withLock { outputWrites } }
    var stderrWrites: Int { lock.withLock { errorWrites } }

    func writeStdout(_ data: Data) {
        lock.withLock {
            outputWrites += 1
            output.append(data)
        }
    }

    func writeStderr(_ data: Data) {
        lock.withLock {
            errorWrites += 1
            errors.append(data)
        }
    }
}

private final class BlockingDiagnosticWriter: CLIOutputWriting, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var output = Data()
    private var errors = Data()
    private var outputWriteCount = 0
    private var hasBlocked = false

    var stdoutWrites: Int { lock.withLock { outputWriteCount } }
    var stderr: Data { lock.withLock { errors } }

    func writeStdout(_ data: Data) {
        lock.withLock {
            outputWriteCount += 1
            output.append(data)
        }
    }

    func writeStderr(_ data: Data) {
        let shouldBlock = lock.withLock {
            guard !hasBlocked else { return false }
            hasBlocked = true
            return true
        }
        if shouldBlock {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        lock.withLock { errors.append(data) }
    }
}

private struct FixedExecutor: CLICommandExecuting {
    let stdout: Data
    let stderr: Data
    let machinePayload: CLIMachineCommandPayload?

    init(
        stdout: Data = Data(),
        stderr: Data = Data(),
        machinePayload: CLIMachineCommandPayload? = nil
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.machinePayload = machinePayload
    }

    func execute(_ invocation: CLIInvocation) async throws -> CLICommandOutput {
        if let machinePayload {
            CLICommandOutput(stdout: stdout, stderr: stderr, machinePayload: machinePayload)
        } else {
            CLICommandOutput(stdout: stdout, stderr: stderr)
        }
    }
}

private final class CancellableSuspendedExecutor: CLICommandExecuting, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    private let payload: CLIMachineCommandPayload

    init(payload: CLIMachineCommandPayload) {
        self.payload = payload
    }

    func execute(_ invocation: CLIInvocation) async throws -> CLICommandOutput {
        defer { finished.signal() }
        entered.signal()
        try await Task.sleep(for: .seconds(30))
        return CLICommandOutput(machinePayload: payload)
    }
}

private final class CleanupFailureOnCancellationExecutor: CLICommandExecuting, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    private let error: ArkTraceError

    init(error: ArkTraceError) {
        self.error = error
    }

    func execute(_ invocation: CLIInvocation) async throws -> CLICommandOutput {
        defer { finished.signal() }
        entered.signal()
        do {
            try await Task.sleep(for: .seconds(30))
            throw ArkTraceError(
                code: .internalError,
                stage: .request,
                message: "Cancellation test did not suspend"
            )
        } catch is CancellationError {
            throw error
        }
    }
}

private final class CooperativeMachineToolProvider: @unchecked Sendable {
    let cancelled = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)

    func resolve() throws -> CLIMachineTool {
        defer { finished.signal() }
        while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
        cancelled.signal()
        throw CancellationError()
    }
}

private struct DelayedFailureExecutor: CLICommandExecuting {
    func execute(_ invocation: CLIInvocation) async throws -> CLICommandOutput {
        let end = ContinuousClock.now.advanced(by: .milliseconds(150))
        while ContinuousClock.now < end {}
        throw ArkTraceError(
            code: .queryFailed,
            stage: .querying,
            message: "Injected failure after the command deadline"
        )
    }
}

private final class SignalTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationCount = 0
    private var forcedSignals: [Int32] = []

    var cancellations: Int { lock.withLock { cancellationCount } }
    var forced: [Int32] { lock.withLock { forcedSignals } }

    func recordCancellation() {
        lock.withLock { cancellationCount += 1 }
    }

    func recordForced(_ signal: Int32) {
        lock.withLock { forcedSignals.append(signal) }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool { lock.withLock { storage } }
    func set(_ value: Bool) { lock.withLock { storage = value } }
}

private func waitForPendingProcessSignal() {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !CLISignalMonitor.hasPendingSignal, ContinuousClock.now < deadline {
        _ = Darwin.sched_yield()
    }
}

private struct ErrorExecutor: CLICommandExecuting {
    let error: ArkTraceError
    func execute(_ invocation: CLIInvocation) async throws -> CLICommandOutput { throw error }
}
