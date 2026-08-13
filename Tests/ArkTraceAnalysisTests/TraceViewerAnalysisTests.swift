import ArkTraceAnalysis
import ArkTraceCore
import XCTest

final class TraceViewerAnalysisTests: XCTestCase {
    private actor Repository: TraceRepositoryProtocol {
        let traceMetadata: TraceMetadata
        let processRows: [TraceProcess]
        let threadRows: [TraceThread]
        let sliceRows: [TraceSlice]
        let cpuRows: [CpuSlice]
        let cpuDelay: Duration?
        private(set) var processQueries: [ProcessQuery] = []
        private(set) var threadQueries: [ThreadQuery] = []

        init(
            processes: [TraceProcess] = [],
            threads: [TraceThread] = [],
            slices: [TraceSlice] = [],
            cpuSlices: [CpuSlice] = [],
            cpuDelay: Duration? = nil
        ) {
            traceMetadata = TraceMetadata(
                traceSHA256: String(repeating: "a", count: 64),
                sourceByteCount: 1,
                durationNs: 1_000,
                sourceFormat: "htrace",
                parser: TraceParserIdentity(
                    name: "parser", reportedVersion: "1",
                    binarySHA256: String(repeating: "b", count: 64),
                    upstreamRepository: "https://example.invalid/repo",
                    upstreamRevision: String(repeating: "c", count: 40),
                    architecture: "arm64", adapterVersion: "1",
                    buildRecipeVersion: "1"
                ),
                schemaFingerprint: String(repeating: "d", count: 64),
                capabilities: TraceCapabilities(
                    cpuScheduling: true, threadStates: true, namedSlices: true,
                    cpuCounters: false, processCounters: false
                ),
                dataQuality: TraceDataQuality()
            )
            processRows = processes
            threadRows = threads
            sliceRows = slices
            cpuRows = cpuSlices
            self.cpuDelay = cpuDelay
        }

        func metadata() async throws -> TraceMetadata { traceMetadata }

        func processes(_ query: ProcessQuery) async throws -> BoundedPage<TraceProcess> {
            processQueries.append(query)
            let filtered = processRows.filter {
                (query.pid == nil || $0.pid == query.pid)
                    && Self.matches($0.name, query.name, query.nameMatch)
            }
            return BoundedPage(
                items: Array(filtered.prefix(query.limit)),
                truncated: filtered.count > query.limit
            )
        }

        func threads(_ query: ThreadQuery) async throws -> BoundedPage<TraceThread> {
            threadQueries.append(query)
            let filtered = threadRows.filter {
                (query.tid == nil || $0.tid == query.tid)
                    && Self.matches($0.name, query.name, query.nameMatch)
            }
            return BoundedPage(
                items: Array(filtered.prefix(query.limit)),
                truncated: filtered.count > query.limit
            )
        }

        func summaryFacts(_ query: TraceSummaryQuery) async throws -> TraceSummaryFacts {
            throw CancellationError()
        }

        func slices(_ query: TraceSliceQuery) async throws -> TraceEventPage<TraceSlice> {
            let needle: String?
            if case .contains(let value)? = query.name { needle = value } else { needle = nil }
            let filtered = sliceRows.filter { slice in
                (needle.map { slice.name.localizedCaseInsensitiveContains($0) } ?? true)
                    && (query.eventKey == nil || slice.key == query.eventKey)
                    && (query.threadKey == nil || slice.threadKey == query.threadKey)
                    && (query.minimumDurationNs == nil
                        || slice.range.durationNs >= query.minimumDurationNs!)
            }
            return TraceEventPage(
                items: Array(filtered.prefix(query.limit)),
                truncated: filtered.count > query.limit
            )
        }

        func cpuSlices(_ query: CpuSliceQuery) async throws -> TraceEventPage<CpuSlice> {
            if let cpuDelay { try await Task.sleep(for: cpuDelay) }
            return TraceEventPage(
                items: Array(cpuRows.prefix(query.limit)),
                truncated: cpuRows.count > query.limit
            )
        }

        func capturedNameMatches() -> ([TraceDirectoryNameMatch], [TraceDirectoryNameMatch]) {
            (processQueries.map(\.nameMatch), threadQueries.map(\.nameMatch))
        }

        private static func matches(
            _ candidate: String?,
            _ filter: String?,
            _ mode: TraceDirectoryNameMatch
        ) -> Bool {
            guard let filter else { return true }
            guard let candidate else { return false }
            switch mode {
            case .exact: return candidate == filter
            case .prefix: return candidate.hasPrefix(filter)
            case .contains: return candidate.contains(filter)
            }
        }
    }

    func testSearchCombinesPIDTIDAndNamesWithStableBound() async throws {
        let repository = Repository(
            processes: [
                TraceProcess(
                    key: ProcessKey(ipid: 2), pid: 42, name: "worker 42",
                    startNs: 0, endNs: 900, threadCount: 1
                ),
            ],
            threads: [
                TraceThread(
                    key: ThreadKey(itid: 3), processKey: ProcessKey(ipid: 2),
                    tid: 42, pid: 42, name: "io-42", processName: "worker 42",
                    startNs: 10, endNs: 800, isMainThread: false
                ),
            ],
            slices: [
                TraceSlice(
                    key: EventKey(table: .callstack, rowID: 9),
                    range: try TraceTimeRange(startNs: 100, endNs: 200),
                    threadKey: ThreadKey(itid: 3), processKey: ProcessKey(ipid: 2),
                    name: "decode 42", category: "work", depth: 0,
                    parentEventKey: nil, isAsync: false, isOpenEnded: false
                ),
            ]
        )
        let result = try await TraceViewerSearchEngine(repository: repository).search(
            TraceViewerSearchRequest(text: "42", limit: 3)
        )
        XCTAssertEqual(result.items.map(\.kind), [.process, .thread, .slice])
        XCTAssertEqual(result.items.last?.eventKey?.rowID, 9)
        XCTAssertFalse(result.truncated)
        let matches = await repository.capturedNameMatches()
        XCTAssertTrue(matches.0.contains(.contains))
        XCTAssertTrue(matches.1.contains(.contains))

        let byInternalIdentity = try await TraceViewerSearchEngine(
            repository: repository
        ).search(TraceViewerSearchRequest(text: "itid:3"))
        XCTAssertEqual(byInternalIdentity.items.map(\.threadKey?.itid), [3])
    }

    func testRangeAnalysisIsBoundedDeterministicAndCancellationAware() async throws {
        let first = CpuSlice(
            key: EventKey(table: .schedSlice, rowID: 1),
            range: try TraceTimeRange(startNs: 100, endNs: 300),
            cpu: 0, threadKey: ThreadKey(itid: 11), processKey: ProcessKey(ipid: 1),
            tid: 111, pid: 1, threadName: "alpha", processName: "p",
            endState: nil, priority: nil, isOpenEnded: false
        )
        let second = CpuSlice(
            key: EventKey(table: .schedSlice, rowID: 2),
            range: try TraceTimeRange(startNs: 300, endNs: 450),
            cpu: 0, threadKey: ThreadKey(itid: 12), processKey: ProcessKey(ipid: 1),
            tid: 112, pid: 1, threadName: "beta", processName: "p",
            endState: nil, priority: nil, isOpenEnded: false
        )
        let range = try TraceTimeRange.query(startNs: 100, endNs: 500)
        let named = [
            TraceSlice(
                key: EventKey(table: .callstack, rowID: 21),
                range: try TraceTimeRange(startNs: 120, endNs: 420),
                threadKey: ThreadKey(itid: 11), processKey: ProcessKey(ipid: 1),
                pid: 1, tid: 111, processName: "p", threadName: "alpha",
                name: "long", category: "work", depth: 0,
                parentEventKey: nil, isAsync: false, isOpenEnded: false
            ),
            TraceSlice(
                key: EventKey(table: .callstack, rowID: 22),
                range: try TraceTimeRange(startNs: 200, endNs: 250),
                threadKey: nil, processKey: nil,
                name: "short", category: nil, depth: nil,
                parentEventKey: nil, isAsync: false, isOpenEnded: false
            ),
        ]
        let result = try await TraceRangeAnalysisEngine(
            repository: Repository(slices: named, cpuSlices: [first, second])
        ).analyze(
            TraceRangeAnalysisRequest(
                range: range, maximumSlices: 2, topThreadLimit: 2,
                longSliceLimit: 2
            )
        )
        XCTAssertEqual(result.cpuUtilization.map(\.occupiedNs), [350])
        XCTAssertEqual(result.cpuUtilization.map(\.rawRunningNs), [350])
        XCTAssertEqual(result.cpuUtilization.map(\.sliceCount), [2])
        XCTAssertEqual(try XCTUnwrap(result.cpuUtilization.first).utilization, 0.875, accuracy: 0.0001)
        XCTAssertEqual(result.topThreads.map(\.threadKey.itid), [11, 12])
        XCTAssertEqual(result.topThreads.map(\.shareOfOneCPU), [0.5, 0.375])
        XCTAssertEqual(result.longSlices.map(\.key.rowID), [21, 22])
        XCTAssertEqual(result.longSlices.first?.name, "long")
        XCTAssertFalse(result.cpuUtilizationTruncated)
        XCTAssertFalse(result.topThreadsTruncated)
        XCTAssertFalse(result.longSlicesTruncated)

        let task = Task {
            try await TraceRangeAnalysisEngine(
                repository: Repository(cpuSlices: [first], cpuDelay: .seconds(5))
            ).analyze(TraceRangeAnalysisRequest(range: range))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled range analysis must not succeed")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .cancelled)
            XCTAssertEqual(error.stage, .analyzing)
        }
    }
}
