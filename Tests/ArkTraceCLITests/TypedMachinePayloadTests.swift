@testable import ArkTraceAnalysis
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
            databaseURL: URL(filePath: "/dev/null"),
            metadataSidecarURL: URL(filePath: "/dev/null"),
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

    func testPhase4PayloadCannotDriftFromFiltersOrGlobalLimits() throws {
        let range = try TraceTimeRange.query(startNs: 0, endNs: 100)
        let invocationFilters = try TraceAgentQueryFilters(cpu: 0)
        let mismatchedQuery = try CLIMachineCommandPayload.query(
            bound: CLIMachineBoundTraceResult(
                snapshot: testSnapshot(
                    metadata: metadata,
                    preparation: preparation,
                    cacheHit: false
                ),
                value: TraceAgentQueryResult(
                    view: .cpuSlices,
                    range: range,
                    filters: try TraceAgentQueryFilters(cpu: 1),
                    capabilityAvailable: true,
                    truncated: false,
                    dataQuality: TraceDataQuality(),
                    cpuSlices: []
                )
            )
        )
        let queryInvocation = try CLIArgumentParser().parse([
            "--json", "query", "trace", "--view", "cpu-slices",
            "--start-ns", "0", "--end-ns", "100", "--cpu", "0", "--limit", "1",
        ])
        guard case .query(_, let queryOptions) = queryInvocation.command else {
            return XCTFail("expected query invocation")
        }
        XCTAssertEqual(queryOptions.filters, invocationFilters)
        assertRequestPayloadMismatch {
            _ = try mismatchedQuery.envelope(for: queryInvocation, tool: tool)
        }

        func status(_ count: Int) -> TraceContextSectionStatus {
            TraceContextSectionStatus(
                returnedCount: count,
                matchedCount: count,
                truncated: false
            )
        }
        func truncation(
            processes: Int = 0,
            threads: Int = 0,
            cpuSlices: Int = 0,
            slices: Int = 0
        ) -> TraceContextTruncation {
            TraceContextTruncation(
                processes: status(processes),
                threads: status(threads),
                cpuSlices: status(cpuSlices),
                threadStates: status(0),
                slices: status(slices),
                counters: status(0),
                summary: status(1),
                referenceOmittedByBudget: false
            )
        }
        let summary = TraceSummary(
            range: range,
            durationNs: range.durationNs,
            cpuCount: 0,
            processCount: 0,
            threadCount: 0,
            cpuSliceCount: 0,
            threadStateCount: 0,
            namedSliceCount: 0,
            counterSeriesCount: 0,
            eventCountBySource: [],
            capabilities: metadata.capabilities,
            schemaFingerprint: metadata.schemaFingerprint,
            dataQuality: metadata.dataQuality,
            truncatedSections: []
        )
        let firstProcess = TraceProcess(
            key: ProcessKey(ipid: 1),
            pid: 1,
            name: nil,
            startNs: nil,
            endNs: nil,
            threadCount: nil
        )
        let firstThread = TraceThread(
            key: ThreadKey(itid: 1),
            processKey: ProcessKey(ipid: 1),
            tid: 1,
            pid: 1,
            name: nil,
            processName: nil,
            startNs: nil,
            endNs: nil,
            isMainThread: nil
        )
        let rowOversized = TraceContext(
            range: range,
            processes: [firstProcess],
            threads: [firstThread],
            cpuSlices: [],
            threadStates: [],
            slices: [],
            counters: [],
            summary: summary,
            dataQuality: metadata.dataQuality,
            truncation: truncation(processes: 1, threads: 1)
        )
        let firstSlice = CpuSlice(
            key: EventKey(table: .schedSlice, rowID: 1),
            range: try TraceTimeRange.query(startNs: 1, endNs: 2),
            cpu: 0,
            threadKey: nil,
            processKey: nil,
            tid: nil,
            pid: nil,
            threadName: nil,
            processName: nil,
            endState: nil,
            priority: nil,
            isOpenEnded: false
        )
        let namedSlice = TraceSlice(
            key: EventKey(table: .callstack, rowID: 3),
            range: try TraceTimeRange.query(startNs: 3, endNs: 4),
            threadKey: nil,
            processKey: nil,
            pid: nil,
            tid: nil,
            processName: nil,
            threadName: nil,
            name: "slice",
            category: nil,
            depth: nil,
            parentEventKey: nil,
            isAsync: false,
            isOpenEnded: false
        )
        let eventOversized = TraceContext(
            range: range,
            processes: [],
            threads: [],
            cpuSlices: [firstSlice],
            threadStates: [],
            slices: [namedSlice],
            counters: [],
            summary: summary,
            dataQuality: metadata.dataQuality,
            truncation: truncation(cpuSlices: 1, slices: 1)
        )
        let mismatchedSummary = TraceSummary(
            range: try TraceTimeRange.query(startNs: 1, endNs: 100),
            durationNs: 99,
            cpuCount: 0,
            processCount: 0,
            threadCount: 0,
            cpuSliceCount: 0,
            threadStateCount: 0,
            namedSliceCount: 0,
            counterSeriesCount: 0,
            eventCountBySource: [],
            capabilities: metadata.capabilities,
            schemaFingerprint: metadata.schemaFingerprint,
            dataQuality: metadata.dataQuality,
            truncatedSections: []
        )
        XCTAssertThrowsError(try CLIMachineCommandPayload.context(
            bound: CLIMachineBoundTraceResult(
                snapshot: testSnapshot(
                    metadata: metadata, preparation: preparation, cacheHit: false
                ),
                value: TraceContext(
                    range: range,
                    processes: [], threads: [], cpuSlices: [], threadStates: [],
                    slices: [], counters: [], summary: mismatchedSummary,
                    dataQuality: metadata.dataQuality,
                    truncation: truncation()
                )
            )
        )) { error in
            XCTAssertEqual(
                (error as? ArkTraceError)?.details["reason"],
                "contextSummaryMismatch"
            )
        }
        let contextInvocation = try CLIArgumentParser().parse([
            "--json", "--max-rows", "1", "--max-events", "1",
            "context", "trace", "--start-ns", "0", "--end-ns", "100",
        ])
        var rowOversizedPayload: CLIMachineCommandPayload?
        for context in [rowOversized, eventOversized] {
            let payload = try CLIMachineCommandPayload.context(
                bound: CLIMachineBoundTraceResult(
                    snapshot: testSnapshot(
                        metadata: metadata,
                        preparation: preparation,
                        cacheHit: false
                    ),
                    value: context
                )
            )
            assertRequestPayloadMismatch {
                _ = try payload.envelope(for: contextInvocation, tool: tool)
            }
            if context.processes.count == 1 { rowOversizedPayload = payload }
        }

        let emptyAnalysisStatus = TraceAnalysisSectionStatus(
            returnedCount: 0, matchedCount: 0, truncated: false
        )
        let oneAnalysisStatus = TraceAnalysisSectionStatus(
            returnedCount: 1, matchedCount: 1, truncated: false
        )
        let analysisParameters = TraceDeterministicAnalysisParameters(
            filters: .none,
            maximumCPUSlices: 1,
            maximumProcessSlices: 1,
            maximumThreadSlices: 1,
            maximumStateIntervals: 1,
            maximumNamedSlices: 1,
            maximumSchedulingEvents: 1,
            maximumHotEvents: 1,
            topProcessLimit: 1,
            topThreadLimit: 1,
            longSliceLimit: 1,
            schedulingSampleLimit: 1,
            hotIntervalLimit: 1,
            hotBucketCount: 100,
            minimumLongSliceDurationNs: 0,
            timeoutSeconds: 30,
            timeoutAttoseconds: 0
        )
        let oversizedAnalysis = TraceDeterministicAnalysis(
            kind: .deterministicBatch,
            parameters: analysisParameters,
            range: range,
            cpuUtilization: [TraceCPUUtilization(
                cpu: 0, rawRunningNs: 1, occupiedNs: 1,
                sliceCount: 1, utilization: 0.01
            )],
            topProcesses: [TraceRunningProcess(
                processKey: ProcessKey(ipid: 1), pid: 1, name: nil,
                runningNs: 1, shareOfOneCPU: 0.01, sliceCount: 1
            )],
            topThreads: [], longSlices: [], threadStateDistribution: [],
            schedulingLatency: TraceSchedulingLatencyResult(
                supported: false, unsupportedReason: .capabilityUnavailable,
                count: 0, percentiles: nil, topSamples: [], truncated: false
            ),
            hotIntervals: [],
            sections: TraceDeterministicAnalysisSections(
                cpuUtilization: oneAnalysisStatus,
                topProcesses: oneAnalysisStatus,
                topThreads: emptyAnalysisStatus,
                longSlices: emptyAnalysisStatus,
                threadStateDistribution: emptyAnalysisStatus,
                schedulingLatency: emptyAnalysisStatus,
                hotIntervals: emptyAnalysisStatus
            ),
            dataQuality: metadata.dataQuality
        )
        let analysisInvocation = try CLIArgumentParser().parse([
            "--json", "--max-rows", "1", "--max-events", "1",
            "analyze", "trace", "--kind", "range",
            "--start-ns", "0", "--end-ns", "100", "--limit", "1",
        ])
        let analysisPayload = try CLIMachineCommandPayload.analyze(
            kind: .range,
            bound: CLIMachineBoundTraceResult(
                snapshot: testSnapshot(
                    metadata: metadata, preparation: preparation, cacheHit: false
                ),
                value: oversizedAnalysis
            )
        )
        assertRequestPayloadMismatch {
            _ = try analysisPayload.envelope(for: analysisInvocation, tool: tool)
        }

        let humanQueryInvocation = try CLIArgumentParser().parse([
            "query", "trace", "--view", "cpu-slices",
            "--start-ns", "0", "--end-ns", "100", "--cpu", "0", "--limit", "1",
        ])
        let humanContextInvocation = try CLIArgumentParser().parse([
            "--max-rows", "1", "--max-events", "1",
            "context", "trace", "--start-ns", "0", "--end-ns", "100",
        ])
        let humanAnalysisInvocation = try CLIArgumentParser().parse([
            "--max-rows", "1", "--max-events", "1",
            "analyze", "trace", "--kind", "range",
            "--start-ns", "0", "--end-ns", "100", "--limit", "1",
        ])
        for (payload, invocation) in [
            (mismatchedQuery, humanQueryInvocation),
            (try XCTUnwrap(rowOversizedPayload), humanContextInvocation),
            (analysisPayload, humanAnalysisInvocation),
        ] {
            assertRequestPayloadMismatch {
                try payload.validate(for: invocation)
            }
        }
    }

    func testSummaryPayloadUsesIndependentRowAndEventLimits() throws {
        func makeSummary(cpuSlices: Int64) -> TraceSummary {
            TraceSummary(
                range: try! TraceTimeRange.query(startNs: 0, endNs: 100),
                durationNs: 100,
                cpuCount: 3,
                processCount: 7,
                threadCount: 7,
                cpuSliceCount: cpuSlices,
                threadStateCount: 3,
                namedSliceCount: 3,
                counterSeriesCount: 3,
                eventCountBySource: [
                    TraceEventSourceCount(source: "a", count: 1),
                    TraceEventSourceCount(source: "b", count: 1),
                    TraceEventSourceCount(source: "c", count: 1),
                ],
                capabilities: metadata.capabilities,
                schemaFingerprint: metadata.schemaFingerprint,
                dataQuality: metadata.dataQuality,
                truncatedSections: []
            )
        }
        let invocation = try CLIArgumentParser().parse([
            "--json", "--max-rows", "7", "--max-events", "3",
            "summary", "trace",
        ])
        let valid = try CLIMachineCommandPayload.summary(
            metadata: metadata,
            preparation: preparation,
            summary: makeSummary(cpuSlices: 3)
        )
        XCTAssertNoThrow(try valid.envelope(for: invocation, tool: tool))

        let oversized = try CLIMachineCommandPayload.summary(
            metadata: metadata,
            preparation: preparation,
            summary: makeSummary(cpuSlices: 4)
        )
        XCTAssertThrowsError(try oversized.envelope(for: invocation, tool: tool)) { error in
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

    private func assertRequestPayloadMismatch(
        _ operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            let typed = error as? ArkTraceError
            XCTAssertEqual(typed?.code, .internalError, file: file, line: line)
            XCTAssertEqual(typed?.stage, .encoding, file: file, line: line)
            XCTAssertEqual(
                typed?.details["reason"],
                "requestPayloadMismatch",
                file: file,
                line: line
            )
        }
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
            databaseURL: URL(filePath: "/dev/null"),
            metadataSidecarURL: URL(filePath: "/dev/null"),
            parser: metadata.parser,
            sourceSHA256: metadata.traceSHA256,
            sourceByteCount: metadata.sourceByteCount,
            databasePreparation: preparation
        ),
        metadata: metadata,
        cacheHit: cacheHit
    )
}
