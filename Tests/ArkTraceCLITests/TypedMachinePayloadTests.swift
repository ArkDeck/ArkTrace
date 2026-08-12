import ArkTraceAnalysis
@testable import ArkTraceCLI
import ArkTraceCore
import Foundation
import XCTest

final class TypedMachinePayloadTests: XCTestCase {
    func testEachPhase2CommandEncodesAnExactTypedResult() throws {
        let process = TraceProcess(
            key: ProcessKey(ipid: 7),
            pid: 42,
            name: nil,
            startNs: 10,
            endNs: nil,
            threadCount: nil
        )
        let thread = TraceThread(
            key: ThreadKey(itid: 9),
            processKey: nil,
            tid: 77,
            pid: nil,
            name: nil,
            processName: nil,
            startNs: nil,
            endNs: 90,
            isMainThread: nil
        )
        let cases: [([String], CLIMachineCommandPayload, Set<String>)] = [
            (
                ["--json", "doctor"],
                try .doctor(
                    selfTest: false,
                    checks: [try CLIMachineDoctorCheck(
                        code: "sqlite",
                        name: "SQLite",
                        status: .ok
                    )]
                ),
                ["checks", "selfTest"]
            ),
            (
                ["--json", "inspect", "trace"],
                try .inspect(
                    metadata: metadata,
                    preparation: preparation,
                    cacheHit: true
                ),
                ["cacheHit", "capabilities", "indexSchemaVersion"]
            ),
            (
                ["--json", "summary", "trace"],
                try .summary(
                    metadata: metadata,
                    preparation: preparation,
                    summary: summary
                ),
                [
                    "range", "durationNs", "cpuCount", "processCount", "threadCount",
                    "cpuSliceCount", "threadStateCount", "namedSliceCount",
                    "counterSeriesCount", "eventCountBySource", "capabilities",
                ]
            ),
            (
                ["--json", "processes", "trace", "--limit", "1"],
                try .processes(
                    metadata: metadata,
                    preparation: preparation,
                    page: BoundedPage(items: [process], truncated: true)
                ),
                ["items"]
            ),
            (
                ["--json", "threads", "trace", "--limit", "1"],
                try .threads(
                    metadata: metadata,
                    preparation: preparation,
                    page: BoundedPage(items: [thread], truncated: true)
                ),
                ["items"]
            ),
        ]

        for (arguments, payload, resultKeys) in cases {
            let invocation = try CLIArgumentParser().parse(arguments)
            let data = try CLIMachineEncoder().encode(
                payload.envelope(for: invocation, tool: tool),
                pretty: false,
                maximumBytes: 64 * 1_024
            )
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            let result = try XCTUnwrap(object["result"] as? [String: Any])
            XCTAssertEqual(Set(result.keys), resultKeys)
            XCTAssertEqual(Set(object.keys), [
                "schemaVersion", "tool", "trace", "request", "limits", "result",
                "dataQuality", "truncation", "provenance",
            ])
        }
    }

    func testProcessAndThreadUnknownValuesEncodeAsExplicitNull() throws {
        let process = TraceProcess(
            key: ProcessKey(ipid: Int64.min),
            pid: Int64.max,
            name: nil,
            startNs: nil,
            endNs: nil,
            threadCount: nil
        )
        let thread = TraceThread(
            key: ThreadKey(itid: Int64.max),
            processKey: nil,
            tid: Int64.min,
            pid: nil,
            name: nil,
            processName: nil,
            startNs: nil,
            endNs: nil,
            isMainThread: nil
        )
        let processObject = try resultObject(
            .processes(
                metadata: metadata,
                preparation: preparation,
                page: BoundedPage(items: [process], truncated: false)
            ),
            arguments: ["--json", "processes", "trace", "--limit", "1"]
        )
        let threadObject = try resultObject(
            .threads(
                metadata: metadata,
                preparation: preparation,
                page: BoundedPage(items: [thread], truncated: false)
            ),
            arguments: ["--json", "threads", "trace", "--limit", "1"]
        )
        let processItem = try XCTUnwrap((processObject["items"] as? [[String: Any]])?.first)
        let threadItem = try XCTUnwrap((threadObject["items"] as? [[String: Any]])?.first)
        for key in ["name", "startNs", "endNs", "threadCount"] {
            XCTAssertTrue(processItem[key] is NSNull, "process.\(key)")
        }
        for key in [
            "processKey", "pid", "name", "processName", "startNs", "endNs",
            "isMainThread",
        ] {
            XCTAssertTrue(threadItem[key] is NSNull, "thread.\(key)")
        }
        XCTAssertEqual((processItem["key"] as? NSNumber)?.int64Value, Int64.min)
        XCTAssertEqual((threadItem["key"] as? NSNumber)?.int64Value, Int64.max)
    }

    func testEmptyAndTruncatedPagesStaySuccessfulAndTyped() throws {
        let empty = try encodedObject(
            .processes(
                metadata: metadata,
                preparation: preparation,
                page: BoundedPage(items: [], truncated: false)
            ),
            arguments: ["--json", "processes", "trace", "--limit", "1"]
        )
        XCTAssertEqual(
            (((empty["result"] as? [String: Any])?["items"] as? [Any])?.count),
            0
        )
        XCTAssertEqual(
            ((empty["truncation"] as? [String: Any])?["truncated"] as? Bool),
            false
        )
        XCTAssertNil(empty["error"])

        let truncated = try encodedObject(
            .threads(
                metadata: metadata,
                preparation: preparation,
                page: BoundedPage(items: [TraceThread(
                    key: ThreadKey(itid: 1),
                    processKey: nil,
                    tid: 1,
                    pid: nil,
                    name: nil,
                    processName: nil,
                    startNs: nil,
                    endNs: nil,
                    isMainThread: nil
                )], truncated: true)
            ),
            arguments: ["--json", "threads", "trace", "--limit", "1"]
        )
        XCTAssertEqual(
            ((truncated["truncation"] as? [String: Any])?["sections"] as? [String]),
            ["threads"]
        )
    }

    func testStatAggregateMayExceedSummaryRowBudget() throws {
        let aggregate = Int64(CLILimits.defaultMaxRows) + 1
        let value = TraceSummary(
            range: try TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs),
            durationNs: metadata.durationNs,
            cpuCount: 0,
            processCount: 0,
            threadCount: 0,
            cpuSliceCount: 0,
            threadStateCount: 0,
            namedSliceCount: 0,
            counterSeriesCount: 0,
            eventCountBySource: [TraceEventSourceCount(
                source: "received",
                count: aggregate
            )],
            capabilities: metadata.capabilities,
            schemaFingerprint: metadata.schemaFingerprint,
            dataQuality: metadata.dataQuality,
            truncatedSections: []
        )
        let result = try resultObject(
            .summary(metadata: metadata, preparation: preparation, summary: value),
            arguments: ["--json", "summary", "trace"]
        )
        let item = try XCTUnwrap(
            (result["eventCountBySource"] as? [[String: Any]])?.first
        )
        XCTAssertEqual((item["count"] as? NSNumber)?.int64Value, aggregate)
    }

    func testPayloadRejectsInconsistentDomainEvidenceAndRequest() throws {
        let mismatchedPreparation = TraceDatabasePreparationResult(
            schemaAdapterVersion: preparation.schemaAdapterVersion,
            schemaFingerprint: String(repeating: "e", count: 64),
            indexVersion: preparation.indexVersion,
            upstreamDatabaseSHA256: preparation.upstreamDatabaseSHA256,
            upstreamDatabaseByteCount: preparation.upstreamDatabaseByteCount
        )
        XCTAssertThrowsError(try CLIMachineCommandPayload.inspect(
            metadata: metadata,
            preparation: mismatchedPreparation,
            cacheHit: false
        )) { error in
            XCTAssertEqual((error as? ArkTraceError)?.stage, .encoding)
        }

        let inconsistentSummary = TraceSummary(
            range: try! TraceTimeRange.query(startNs: 0, endNs: 100),
            durationNs: 100,
            cpuCount: nil,
            processCount: 0,
            threadCount: 0,
            cpuSliceCount: nil,
            threadStateCount: nil,
            namedSliceCount: nil,
            counterSeriesCount: nil,
            eventCountBySource: nil,
            capabilities: metadata.capabilities,
            schemaFingerprint: String(repeating: "e", count: 64),
            dataQuality: TraceDataQuality(),
            truncatedSections: []
        )
        XCTAssertThrowsError(try CLIMachineCommandPayload.summary(
            metadata: metadata,
            preparation: preparation,
            summary: inconsistentSummary
        ))

        let doctor = try CLIMachineCommandPayload.doctor(selfTest: false, checks: [])
        let inspectInvocation = try CLIArgumentParser().parse(["--json", "inspect", "trace"])
        XCTAssertThrowsError(try doctor.envelope(for: inspectInvocation, tool: tool))
    }

    func testSummaryCapabilityNullabilityAndSourceIdentityFailClosed() throws {
        let unsupported = TraceCapabilities(
            cpuScheduling: false,
            threadStates: false,
            namedSlices: false,
            cpuCounters: false,
            processCounters: false
        )
        let unsupportedMetadata = TraceMetadata(
            traceSHA256: metadata.traceSHA256,
            sourceByteCount: metadata.sourceByteCount,
            durationNs: metadata.durationNs,
            sourceFormat: nil,
            parser: metadata.parser,
            schemaFingerprint: metadata.schemaFingerprint,
            capabilities: unsupported,
            dataQuality: TraceDataQuality()
        )
        let mismatched = TraceSummary(
            range: try TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs),
            durationNs: metadata.durationNs,
            cpuCount: 1,
            processCount: 0,
            threadCount: 0,
            cpuSliceCount: nil,
            threadStateCount: nil,
            namedSliceCount: nil,
            counterSeriesCount: nil,
            eventCountBySource: nil,
            capabilities: unsupported,
            schemaFingerprint: metadata.schemaFingerprint,
            dataQuality: TraceDataQuality(),
            truncatedSections: [.cpuCount]
        )
        XCTAssertThrowsError(try CLIMachineCommandPayload.summary(
            metadata: unsupportedMetadata,
            preparation: preparation,
            summary: mismatched
        ))

        let duplicateSources = TraceSummary(
            range: try TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs),
            durationNs: metadata.durationNs,
            cpuCount: 0,
            processCount: 0,
            threadCount: 0,
            cpuSliceCount: 0,
            threadStateCount: 0,
            namedSliceCount: 0,
            counterSeriesCount: 0,
            eventCountBySource: [
                TraceEventSourceCount(source: "received", count: 1),
                TraceEventSourceCount(source: "received", count: 2),
            ],
            capabilities: metadata.capabilities,
            schemaFingerprint: metadata.schemaFingerprint,
            dataQuality: metadata.dataQuality,
            truncatedSections: []
        )
        XCTAssertThrowsError(try CLIMachineCommandPayload.summary(
            metadata: metadata,
            preparation: preparation,
            summary: duplicateSources
        ))

        let binaryDistinctUnicode = TraceSummary(
            range: duplicateSources.range,
            durationNs: duplicateSources.durationNs,
            cpuCount: duplicateSources.cpuCount,
            processCount: duplicateSources.processCount,
            threadCount: duplicateSources.threadCount,
            cpuSliceCount: duplicateSources.cpuSliceCount,
            threadStateCount: duplicateSources.threadStateCount,
            namedSliceCount: duplicateSources.namedSliceCount,
            counterSeriesCount: duplicateSources.counterSeriesCount,
            eventCountBySource: [
                TraceEventSourceCount(source: "e\u{301}", count: 1),
                TraceEventSourceCount(source: "é", count: 2),
            ],
            capabilities: duplicateSources.capabilities,
            schemaFingerprint: duplicateSources.schemaFingerprint,
            dataQuality: duplicateSources.dataQuality,
            truncatedSections: []
        )
        XCTAssertNoThrow(try CLIMachineCommandPayload.summary(
            metadata: metadata,
            preparation: preparation,
            summary: binaryDistinctUnicode
        ))
    }

    func testTraceSnapshotRejectsCrossTraceProvenanceEvenWithSameSchema() throws {
        let otherParsed = ParsedTrace(
            databaseURL: URL(fileURLWithPath: "/dev/null"),
            metadataSidecarURL: URL(fileURLWithPath: "/dev/null"),
            parser: metadata.parser,
            sourceSHA256: String(repeating: "9", count: 64),
            sourceByteCount: metadata.sourceByteCount,
            databasePreparation: preparation
        )
        XCTAssertThrowsError(try CLIMachineTraceSnapshot(
            parsed: otherParsed,
            metadata: metadata,
            cacheHit: false
        )) { error in
            XCTAssertEqual((error as? ArkTraceError)?.details["reason"], "sessionProvenanceMismatch")
        }
    }

    func testPayloadCannotExceedInvocationRowLimit() throws {
        let first = TraceProcess(
            key: ProcessKey(ipid: 1),
            pid: 1,
            name: "one",
            startNs: nil,
            endNs: nil,
            threadCount: nil
        )
        let second = TraceProcess(
            key: ProcessKey(ipid: 2),
            pid: 2,
            name: "two",
            startNs: nil,
            endNs: nil,
            threadCount: nil
        )
        let payload = try CLIMachineCommandPayload.processes(
            metadata: metadata,
            preparation: preparation,
            page: BoundedPage(items: [first, second], truncated: false)
        )
        let invocation = try CLIArgumentParser().parse([
            "--json", "processes", "trace", "--limit", "1",
        ])
        XCTAssertThrowsError(try payload.envelope(for: invocation, tool: tool)) { error in
            XCTAssertEqual((error as? ArkTraceError)?.code, .outputLimitExceeded)
            XCTAssertEqual((error as? ArkTraceError)?.stage, .encoding)
        }
    }

    func testMachineErrorDirectConstructionNormalizesInvalidRetryability() {
        let error = CLIMachineError(ArkTraceError(
            code: .traceSchemaUnsupported,
            stage: .validating,
            message: "caller controlled",
            retryable: true
        ))
        XCTAssertEqual(error.code, .internalError)
        XCTAssertEqual(error.stage, .encoding)
        XCTAssertFalse(error.retryable)
        XCTAssertEqual(error.details["reason"], .string("invalidRetryability"))
    }

    func testTypedSupplementalFieldsCannotCarryDiagnosticsOrPaths() {
        XCTAssertThrowsError(try CLIMachineDoctorCheck(
            code: "parser",
            name: "/Users/private/trace_streamer",
            status: .ok
        ))
        let quality = try? CLIMachineDataQuality(TraceDataQuality(issues: [
            TraceDataQualityIssue(
                category: .invalidValue,
                scope: "process.start_ts",
                message: "source /Users/private/trace.htrace"
            ),
        ]))
        XCTAssertNil(quality?.warnings.first?.message)
        XCTAssertThrowsError(try CLIMachineDataQuality(TraceDataQuality(issues: [
            TraceDataQualityIssue(category: .invalidValue, scope: "SELECT.secret"),
        ])))
        XCTAssertThrowsError(try CLIMachineDoctorCheck(
            code: "sqlite",
            name: "SELECT * FROM secret",
            status: .ok
        ))
    }

    private func encodedObject(
        _ payload: CLIMachineCommandPayload,
        arguments: [String]
    ) throws -> [String: Any] {
        let invocation = try CLIArgumentParser().parse(arguments)
        let data = try CLIMachineEncoder().encode(
            payload.envelope(for: invocation, tool: tool),
            pretty: false,
            maximumBytes: 64 * 1_024
        )
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func resultObject(
        _ payload: CLIMachineCommandPayload,
        arguments: [String]
    ) throws -> [String: Any] {
        let object = try encodedObject(payload, arguments: arguments)
        return try XCTUnwrap(object["result"] as? [String: Any])
    }

    private var tool: CLIMachineTool {
        try! CLIMachineTool(
            name: ArkTraceCLITool.name,
            version: ArkTraceCLITool.version,
            buildRevision: String(repeating: "f", count: 64)
        )
    }

    private var metadata: TraceMetadata {
        TraceMetadata(
            traceSHA256: String(repeating: "a", count: 64),
            sourceByteCount: 1_024,
            durationNs: 100,
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
            capabilities: TraceCapabilities(
                cpuScheduling: true,
                threadStates: true,
                namedSlices: true,
                cpuCounters: true,
                processCounters: false
            ),
            dataQuality: TraceDataQuality(issues: [
                TraceDataQualityIssue(
                    category: .probeTruncated,
                    scope: "thread.start_ts"
                ),
            ])
        )
    }

    private var preparation: TraceDatabasePreparationResult {
        TraceDatabasePreparationResult(
            schemaAdapterVersion: "2",
            schemaFingerprint: String(repeating: "d", count: 64),
            indexVersion: 1,
            upstreamDatabaseSHA256: String(repeating: "c", count: 64),
            upstreamDatabaseByteCount: 2_048
        )
    }

    private var summary: TraceSummary {
        TraceSummary(
            range: try! TraceTimeRange.query(startNs: 0, endNs: 100),
            durationNs: 100,
            cpuCount: 1,
            processCount: 1,
            threadCount: 2,
            cpuSliceCount: 3,
            threadStateCount: 1,
            namedSliceCount: 1,
            counterSeriesCount: 1,
            eventCountBySource: nil,
            capabilities: metadata.capabilities,
            schemaFingerprint: metadata.schemaFingerprint,
            dataQuality: metadata.dataQuality,
            truncatedSections: [.threadStateCount]
        )
    }
}

// Test-only adapters exercise the internal bound-result validator without
// reopening independent provenance factories in the production module.
extension CLIMachineCommandPayload {
    static func doctor(
        selfTest: Bool,
        checks: [CLIMachineDoctorCheck]
    ) throws -> Self {
        try doctor(
            selfTest: selfTest,
            checks: BoundedPage(items: checks, truncated: false)
        )
    }

    static func inspect(
        metadata: TraceMetadata,
        preparation: TraceDatabasePreparationResult,
        cacheHit: Bool
    ) throws -> Self {
        try inspect(snapshot: testSnapshot(
            metadata: metadata,
            preparation: preparation,
            cacheHit: cacheHit
        ))
    }

    static func summary(
        metadata: TraceMetadata,
        preparation: TraceDatabasePreparationResult,
        summary: TraceSummary
    ) throws -> Self {
        try Self.summary(bound: CLIMachineBoundTraceResult(
            snapshot: testSnapshot(
                metadata: metadata,
                preparation: preparation,
                cacheHit: false
            ),
            value: summary
        ))
    }

    static func processes(
        metadata: TraceMetadata,
        preparation: TraceDatabasePreparationResult,
        page: BoundedPage<TraceProcess>
    ) throws -> Self {
        try processes(bound: CLIMachineBoundTraceResult(
            snapshot: testSnapshot(
                metadata: metadata,
                preparation: preparation,
                cacheHit: false
            ),
            value: page
        ))
    }

    static func threads(
        metadata: TraceMetadata,
        preparation: TraceDatabasePreparationResult,
        page: BoundedPage<TraceThread>
    ) throws -> Self {
        try threads(bound: CLIMachineBoundTraceResult(
            snapshot: testSnapshot(
                metadata: metadata,
                preparation: preparation,
                cacheHit: false
            ),
            value: page
        ))
    }
}

private func testSnapshot(
    metadata: TraceMetadata,
    preparation: TraceDatabasePreparationResult,
    cacheHit: Bool
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
        cacheHit: cacheHit
    )
}
