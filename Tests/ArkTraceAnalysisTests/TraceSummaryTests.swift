import ArkTraceAnalysis
import ArkTraceCore
import XCTest

final class TraceSummaryTests: XCTestCase {
    private actor RepositoryStub: TraceRepositoryProtocol {
        let traceMetadata: TraceMetadata
        let facts: TraceSummaryFacts
        let metadataDelay: Duration?
        let metadataBusyWait: Duration?
        let timeoutAfterCancellation: Bool
        private(set) var requests: [TraceSummaryQuery] = []
        private(set) var metadataFinished = false

        init(
            metadata: TraceMetadata,
            facts: TraceSummaryFacts,
            metadataDelay: Duration? = nil,
            metadataBusyWait: Duration? = nil,
            timeoutAfterCancellation: Bool = false
        ) {
            self.traceMetadata = metadata
            self.facts = facts
            self.metadataDelay = metadataDelay
            self.metadataBusyWait = metadataBusyWait
            self.timeoutAfterCancellation = timeoutAfterCancellation
        }

        func metadata() async throws -> TraceMetadata {
            if let metadataBusyWait {
                let end = ContinuousClock.now.advanced(by: metadataBusyWait)
                while ContinuousClock.now < end {}
            }
            if let metadataDelay { try await Task.sleep(for: metadataDelay) }
            metadataFinished = true
            return traceMetadata
        }

        func processes(_ query: ProcessQuery) async throws -> BoundedPage<TraceProcess> {
            BoundedPage(items: [], truncated: false)
        }

        func threads(_ query: ThreadQuery) async throws -> BoundedPage<TraceThread> {
            BoundedPage(items: [], truncated: false)
        }

        func summaryFacts(_ query: TraceSummaryQuery) async throws -> TraceSummaryFacts {
            requests.append(query)
            if timeoutAfterCancellation {
                while !Task.isCancelled { await Task.yield() }
                throw ArkTraceError(
                    code: .queryTimeout,
                    stage: .querying,
                    message: "injected concurrent timeout",
                    retryable: true
                )
            }
            try Task.checkCancellation()
            return facts
        }

        func capturedRequests() -> [TraceSummaryQuery] { requests }
    }

    private static let parser = TraceParserIdentity(
        name: "trace_streamer",
        reportedVersion: "4.3.7",
        binarySHA256: String(repeating: "a", count: 64),
        upstreamRepository: "https://example.invalid/upstream.git",
        upstreamRevision: String(repeating: "b", count: 40),
        architecture: "arm64",
        adapterVersion: "1",
        buildRecipeVersion: "1"
    )

    private func metadata(
        capabilities: TraceCapabilities = TraceCapabilities(
            cpuScheduling: true,
            threadStates: true,
            namedSlices: true,
            cpuCounters: true,
            processCounters: false
        ),
        warnings: [String] = ["bounded warning"]
    ) -> TraceMetadata {
        TraceMetadata(
            traceSHA256: String(repeating: "c", count: 64),
            sourceByteCount: 123,
            durationNs: 1_000,
            sourceFormat: "htrace",
            parser: Self.parser,
            schemaFingerprint: String(repeating: "d", count: 64),
            capabilities: capabilities,
            dataQuality: TraceDataQuality(warnings: warnings)
        )
    }

    private func facts(
        supported: Bool = true,
        truncated: Bool = false
    ) -> TraceSummaryFacts {
        TraceSummaryFacts(
            cpuCount: supported ? TraceBoundedCount(value: 4, truncated: false) : nil,
            processCount: TraceBoundedCount(value: 5, truncated: truncated),
            threadCount: TraceBoundedCount(value: 8, truncated: false),
            cpuSliceCount: supported
                ? TraceBoundedCount(value: 13, truncated: false) : nil,
            threadStateCount: supported
                ? TraceBoundedCount(value: 21, truncated: true) : nil,
            namedSliceCount: supported
                ? TraceBoundedCount(value: 34, truncated: false) : nil,
            counterSeriesCount: supported
                ? TraceBoundedCount(value: 2, truncated: false) : nil,
            eventCountBySource: supported
                ? TraceEventSourceCounts(
                    items: [
                        TraceEventSourceCount(source: "trace", count: 55),
                        TraceEventSourceCount(source: "ftrace", count: 34),
                    ],
                    truncated: false
                ) : nil
        )
    }

    func testFullSummaryCarriesTraceEvidenceAndStableTruncation() async throws {
        let repository = RepositoryStub(metadata: metadata(), facts: facts(truncated: true))
        let result = try await TraceSummaryEngine(repository: repository).summarize(
            try TraceSummaryRequest(maximumRowsPerSection: 100)
        )

        XCTAssertEqual(result.range, try TraceTimeRange.query(startNs: 0, endNs: 1_000))
        XCTAssertEqual(result.durationNs, 1_000)
        XCTAssertEqual(result.cpuCount, 4)
        XCTAssertEqual(result.processCount, 5)
        XCTAssertEqual(result.threadCount, 8)
        XCTAssertEqual(result.cpuSliceCount, 13)
        XCTAssertEqual(result.threadStateCount, 21)
        XCTAssertEqual(result.namedSliceCount, 34)
        XCTAssertEqual(result.counterSeriesCount, 2)
        XCTAssertEqual(result.eventCountBySource, [
            TraceEventSourceCount(source: "ftrace", count: 34),
            TraceEventSourceCount(source: "trace", count: 55)
        ])
        XCTAssertEqual(result.schemaFingerprint, String(repeating: "d", count: 64))
        XCTAssertEqual(result.dataQuality.status, .warnings)
        XCTAssertEqual(result.truncatedSections, [.processCount, .threadStateCount])
        let captured = await repository.capturedRequests()
        let request = try XCTUnwrap(captured.first)
        XCTAssertNil(request.range)
        XCTAssertEqual(request.maximumRowsPerSection, 100)
    }

    func testEventSourcesUseRawUTF8IdentityAndOrdering() async throws {
        let composed = "\u{00e9}"
        let decomposed = "e\u{0301}"
        let base = facts()
        let unicodeFacts = TraceSummaryFacts(
            cpuCount: base.cpuCount,
            processCount: base.processCount,
            threadCount: base.threadCount,
            cpuSliceCount: base.cpuSliceCount,
            threadStateCount: base.threadStateCount,
            namedSliceCount: base.namedSliceCount,
            counterSeriesCount: base.counterSeriesCount,
            eventCountBySource: TraceEventSourceCounts(
                items: [
                    TraceEventSourceCount(source: composed, count: 7),
                    TraceEventSourceCount(source: decomposed, count: 11),
                ],
                truncated: false
            )
        )
        let repository = RepositoryStub(
            metadata: metadata(),
            facts: unicodeFacts
        )

        let result = try await TraceSummaryEngine(repository: repository).summarize(
            try TraceSummaryRequest()
        )

        XCTAssertEqual(result.eventCountBySource?.map(\.source), [decomposed, composed])
        XCTAssertEqual(result.eventCountBySource?.map(\.count), [11, 7])
    }

    func testRangeSummaryUsesRangeDurationAndForwardsExactRange() async throws {
        let range = try TraceTimeRange.query(startNs: 100, endNs: 250)
        let repository = RepositoryStub(metadata: metadata(), facts: facts())
        let result = try await TraceSummaryEngine(repository: repository).summarize(
            try TraceSummaryRequest(range: range)
        )
        XCTAssertEqual(result.range, range)
        XCTAssertEqual(result.durationNs, 150)
        let captured = await repository.capturedRequests()
        XCTAssertEqual(captured.first?.range, range)
    }

    func testUnsupportedCapabilityStaysNullInsteadOfZero() async throws {
        let capabilities = TraceCapabilities(
            cpuScheduling: false,
            threadStates: false,
            namedSlices: false,
            cpuCounters: false,
            processCounters: false
        )
        let repository = RepositoryStub(
            metadata: metadata(capabilities: capabilities, warnings: []),
            facts: facts(supported: false)
        )
        let result = try await TraceSummaryEngine(repository: repository).summarize(
            try TraceSummaryRequest()
        )
        XCTAssertNil(result.cpuSliceCount)
        XCTAssertNil(result.cpuCount)
        XCTAssertNil(result.threadStateCount)
        XCTAssertNil(result.namedSliceCount)
        XCTAssertNil(result.counterSeriesCount)
        XCTAssertNil(result.eventCountBySource)
        XCTAssertEqual(result.dataQuality.status, .ok)
        let encoded = try SummaryCanonicalTestEncoder.encode(result)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        for key in [
            "cpuCount", "cpuSliceCount", "threadStateCount", "namedSliceCount",
            "counterSeriesCount", "eventCountBySource",
        ] {
            XCTAssertTrue(object[key] is NSNull, "\(key) must encode as explicit null")
        }
    }

    func testDeterministicEncodingHasStableBytesAndNoTimestamp() async throws {
        let repository = RepositoryStub(metadata: metadata(), facts: facts())
        let engine = TraceSummaryEngine(repository: repository)
        let request = try TraceSummaryRequest()
        let first = try SummaryCanonicalTestEncoder.encode(try await engine.summarize(request))
        let second = try SummaryCanonicalTestEncoder.encode(try await engine.summarize(request))
        XCTAssertEqual(first, second)
        XCTAssertNil(String(decoding: first, as: UTF8.self).range(of: "generated"))
    }

    func testTypedQualityEvidenceMergesDeterministicallyWithoutMessageParsing() async throws {
        let base = metadata(warnings: [])
        let typedMetadata = TraceMetadata(
            traceSHA256: base.traceSHA256,
            sourceByteCount: base.sourceByteCount,
            durationNs: base.durationNs,
            sourceFormat: base.sourceFormat,
            parser: base.parser,
            schemaFingerprint: base.schemaFingerprint,
            capabilities: base.capabilities,
            dataQuality: TraceDataQuality(issues: [
                TraceDataQualityIssue(
                    category: .probeTruncated,
                    scope: "thread.start_ts",
                    message: "probe incomplete"
                )
            ])
        )
        let baseFacts = facts()
        let typedFacts = TraceSummaryFacts(
            cpuCount: baseFacts.cpuCount,
            processCount: baseFacts.processCount,
            threadCount: baseFacts.threadCount,
            cpuSliceCount: baseFacts.cpuSliceCount,
            threadStateCount: baseFacts.threadStateCount,
            namedSliceCount: baseFacts.namedSliceCount,
            counterSeriesCount: baseFacts.counterSeriesCount,
            eventCountBySource: baseFacts.eventCountBySource,
            qualityIssues: [
                TraceDataQualityIssue(
                    category: .referentialIntegrity,
                    scope: "thread.ipid",
                    count: 1,
                    message: "reference unavailable"
                )
            ]
        )
        let result = try await TraceSummaryEngine(
            repository: RepositoryStub(metadata: typedMetadata, facts: typedFacts)
        ).summarize(try TraceSummaryRequest())
        XCTAssertEqual(result.dataQuality.issues.map(\.category), [
            .probeTruncated, .referentialIntegrity,
        ])
        XCTAssertFalse(result.dataQuality.issues.contains { $0.category == .unclassified })
    }

    func testOutOfTraceRangeIsRejectedBeforeStoreQuery() async throws {
        let repository = RepositoryStub(metadata: metadata(), facts: facts())
        do {
            _ = try await TraceSummaryEngine(repository: repository).summarize(
                try TraceSummaryRequest(
                    range: TraceTimeRange.query(startNs: 900, endNs: 1_001)
                )
            )
            XCTFail("range beyond trace duration must be rejected")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertEqual(error.stage, .request)
        }
        let captured = await repository.capturedRequests()
        XCTAssertTrue(captured.isEmpty)
    }

    func testDegenerateAnalysisRangeIsRejectedAtRequestBoundary() throws {
        let instant = try TraceTimeRange(startNs: 200, endNs: 200)
        XCTAssertThrowsError(try TraceSummaryRequest(range: instant)) { error in
            let typed = error as? ArkTraceError
            XCTAssertEqual(typed?.code, .invalidArgument)
            XCTAssertEqual(typed?.stage, .request)
        }
        XCTAssertThrowsError(
            try TraceSummaryQuery(
                range: instant,
                deadline: ContinuousClock.now.advanced(by: .seconds(1))
            )
        ) { error in
            XCTAssertEqual((error as? ArkTraceError)?.code, .invalidArgument)
        }
    }

    func testSummaryRequestKeepsRowAndEventBudgetsIndependent() throws {
        let request = try TraceSummaryRequest(
            maximumRowsPerSection: 7,
            maximumEventsPerSection: 3
        )
        XCTAssertEqual(request.maximumRowsPerSection, 7)
        XCTAssertEqual(request.maximumEventsPerSection, 3)
        XCTAssertThrowsError(
            try TraceSummaryRequest(
                maximumRowsPerSection: 7,
                maximumEventsPerSection: 1_000_001
            )
        ) { error in
            XCTAssertEqual((error as? ArkTraceError)?.code, .invalidArgument)
        }
    }

    func testMetadataDelayHonorsAnalysisDeadline() async throws {
        let repository = RepositoryStub(
            metadata: metadata(),
            facts: facts(),
            metadataDelay: .seconds(5)
        )
        let started = ContinuousClock.now
        do {
            _ = try await TraceSummaryEngine(repository: repository).summarize(
                try TraceSummaryRequest(timeout: .milliseconds(5))
            )
            XCTFail("expired deadline must fail")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .queryTimeout)
            XCTAssertEqual(error.stage, .analyzing)
            XCTAssertTrue(error.retryable)
        }
        XCTAssertLessThan(started.duration(to: ContinuousClock.now), .seconds(1))
    }

    func testDeadlineDrainsUncooperativeRepositoryBeforeReturning() async throws {
        let repository = RepositoryStub(
            metadata: metadata(),
            facts: facts(),
            metadataBusyWait: .milliseconds(250)
        )
        let started = ContinuousClock.now
        do {
            _ = try await TraceSummaryEngine(repository: repository).summarize(
                try TraceSummaryRequest(timeout: .milliseconds(5))
            )
            XCTFail("deadline must win an uncooperative repository call")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .queryTimeout)
            XCTAssertEqual(error.stage, .analyzing)
        }
        XCTAssertGreaterThanOrEqual(
            started.duration(to: ContinuousClock.now),
            .milliseconds(200)
        )
        let metadataFinished = await repository.metadataFinished
        XCTAssertTrue(metadataFinished)
    }

    func testCancellationIsMappedToTypedAnalysisError() async throws {
        let repository = RepositoryStub(
            metadata: metadata(),
            facts: facts(),
            metadataDelay: .seconds(5)
        )
        let task = Task {
            try await TraceSummaryEngine(repository: repository).summarize(
                try TraceSummaryRequest(timeout: .seconds(30))
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled summary must not succeed")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .cancelled)
            XCTAssertEqual(error.stage, .analyzing)
            XCTAssertTrue(error.retryable)
        }
    }

    func testParentCancellationWinsConcurrentTypedTimeout() async throws {
        let repository = RepositoryStub(
            metadata: metadata(),
            facts: facts(),
            timeoutAfterCancellation: true
        )
        let task = Task {
            try await TraceSummaryEngine(repository: repository).summarize(
                try TraceSummaryRequest(timeout: .seconds(30))
            )
        }
        while (await repository.capturedRequests()).isEmpty { await Task.yield() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("parent cancellation must win over concurrent timeout")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .cancelled)
            XCTAssertEqual(error.stage, .analyzing)
        }
    }
}

/// Encodes a summary with the same canonical configuration the production
/// machine envelope uses ([.sortedKeys, .withoutEscapingSlashes]); the
/// standalone Analysis encoder it replaces asserted bytes no production path
/// ever emitted.
private enum SummaryCanonicalTestEncoder {
    static func encode(_ summary: TraceSummary) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(summary)
    }
}
