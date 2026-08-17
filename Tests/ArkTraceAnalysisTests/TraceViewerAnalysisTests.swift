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
        let stateRows: [ThreadStateInterval]
        let cpuDelay: Duration?
        private(set) var processQueries: [ProcessQuery] = []
        private(set) var threadQueries: [ThreadQuery] = []
        private(set) var threadStateQueries: [ThreadStateQuery] = []
        private(set) var cpuSliceQueries: [CpuSliceQuery] = []

        /// The range/limit pairs each engine actually asked for.
        func threadStateQueryShapes() -> [(TraceTimeRange, Int)] {
            threadStateQueries.map { ($0.range, $0.limit) }
        }

        init(
            processes: [TraceProcess] = [],
            threads: [TraceThread] = [],
            slices: [TraceSlice] = [],
            cpuSlices: [CpuSlice] = [],
            threadStates: [ThreadStateInterval] = [],
            cpuDelay: Duration? = nil
        ) {
            stateRows = threadStates
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
            cpuSliceQueries.append(query)
            if let cpuDelay { try await Task.sleep(for: cpuDelay) }
            return TraceEventPage(
                items: Array(cpuRows.prefix(query.limit)),
                truncated: cpuRows.count > query.limit
            )
        }

        func threadStates(
            _ query: ThreadStateQuery
        ) async throws -> TraceEventPage<ThreadStateInterval> {
            threadStateQueries.append(query)
            let filtered = stateRows.filter {
                (query.state == nil || $0.normalizedState == query.state)
                    // Honour the requested range. A double that returns every
                    // row regardless of range cannot notice one caller drifting
                    // off the shared query shape, which is exactly what the
                    // App/CLI equivalence test exists to catch.
                    && $0.range.clippedOverlapNs(with: query.range) > 0
            }
            return TraceEventPage(
                items: Array(filtered.prefix(query.limit)),
                truncated: filtered.count > query.limit
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

    /// DESIGN §4.3 invariant 3: the App's range analysis and the CLI's
    /// deterministic analysis share one Analysis implementation. Both engines
    /// run over the same repository and must report the identical thread state
    /// distribution -- otherwise the App answers a question differently from
    /// `arktrace analyze`.
    func testRangeAndDeterministicAnalysisAgreeOnThreadStateDistribution() async throws {
        let range = try TraceTimeRange.query(startNs: 100, endNs: 500)
        func interval(
            _ rowID: Int64,
            _ startNs: Int64,
            _ endNs: Int64,
            itid: Int64,
            state: String,
            normalized: TraceThreadState?
        ) throws -> ThreadStateInterval {
            ThreadStateInterval(
                key: EventKey(table: .threadState, rowID: rowID),
                range: try TraceTimeRange(startNs: startNs, endNs: endNs),
                threadKey: ThreadKey(itid: itid),
                processKey: ProcessKey(ipid: 1),
                state: state,
                normalizedState: normalized,
                cpu: 0,
                tid: 100 + itid,
                pid: 1,
                processName: "p",
                threadName: "t\(itid)",
                isOpenEnded: false
            )
        }
        // Intervals that clip at both range edges, repeat a state on one
        // thread, and include an unmapped upstream state.
        let states = [
            try interval(1, 50, 200, itid: 11, state: "Running", normalized: .running),
            try interval(2, 200, 260, itid: 11, state: "S", normalized: .sleeping),
            try interval(3, 300, 360, itid: 11, state: "S", normalized: .sleeping),
            try interval(4, 400, 700, itid: 12, state: "R", normalized: .runnable),
            try interval(5, 150, 180, itid: 12, state: "DK", normalized: nil),
        ]
        let repository = Repository(threadStates: states)
        let rangeAnalysis = try await TraceRangeAnalysisEngine(
            repository: repository
        ).analyze(
            TraceRangeAnalysisRequest(range: range, maximumStateIntervals: 20_000)
        )
        let deterministic = try await TraceDeterministicAnalysisEngine(
            repository: repository
        ).analyze(
            TraceDeterministicAnalysisRequest(
                range: range, maximumStateIntervals: 20_000
            )
        )

        XCTAssertFalse(rangeAnalysis.threadStateDistribution.isEmpty)
        XCTAssertEqual(
            rangeAnalysis.threadStateDistribution,
            deterministic.threadStateDistribution
        )
        XCTAssertFalse(rangeAnalysis.threadStateDistributionTruncated)

        // Equal results are not enough: DESIGN §4.3 invariant 3 is that both
        // paths ask the *same bounded question*. Two engines can agree on this
        // fixture while one quietly drifts to a different range or limit, and
        // then disagree on a real trace. Assert the query shapes directly.
        let shapes = await repository.threadStateQueryShapes()
        XCTAssertGreaterThanOrEqual(shapes.count, 2, "each engine reads intervals")
        XCTAssertEqual(
            Set(shapes.map(\.0)), [range],
            "both engines must ask for exactly the requested range"
        )
        XCTAssertEqual(
            Set(shapes.map(\.1)).count, 1,
            "both engines must ask under the same interval budget"
        )
        // Clipped overlap, not raw duration: interval 1 contributes [100,200)
        // and interval 4 contributes [400,500).
        let running = try XCTUnwrap(
            rangeAnalysis.threadStateDistribution.first { $0.rawState == "Running" }
        )
        XCTAssertEqual(running.durationNs, 100)
        XCTAssertEqual(running.intervalCount, 1)
        let sleeping = try XCTUnwrap(
            rangeAnalysis.threadStateDistribution.first { $0.rawState == "S" }
        )
        XCTAssertEqual(sleeping.durationNs, 120)
        XCTAssertEqual(sleeping.intervalCount, 2)
        let runnable = try XCTUnwrap(
            rangeAnalysis.threadStateDistribution.first { $0.rawState == "R" }
        )
        XCTAssertEqual(runnable.durationNs, 100)
        // An upstream state with no ArkTrace mapping keeps its exact text.
        XCTAssertTrue(
            rangeAnalysis.threadStateDistribution.contains {
                $0.rawState == "DK" && $0.normalizedState == nil
            }
        )
    }

    /// A truncated interval page must say so rather than presenting a partial
    /// distribution as complete.
    func testThreadStateDistributionTruncationIsReportedNotSilent() async throws {
        let range = try TraceTimeRange.query(startNs: 0, endNs: 1_000)
        let states = try (1...8).map { index in
            ThreadStateInterval(
                key: EventKey(table: .threadState, rowID: Int64(index)),
                range: try TraceTimeRange(
                    startNs: Int64(index) * 10, endNs: Int64(index) * 10 + 5
                ),
                threadKey: ThreadKey(itid: Int64(index)),
                state: "S",
                normalizedState: .sleeping,
                cpu: nil, tid: nil, pid: nil,
                processName: nil, threadName: nil, isOpenEnded: false
            )
        }
        let analysis = try await TraceRangeAnalysisEngine(
            repository: Repository(threadStates: states)
        ).analyze(
            TraceRangeAnalysisRequest(range: range, maximumStateIntervals: 3)
        )
        XCTAssertTrue(analysis.threadStateDistributionTruncated)
        XCTAssertTrue(analysis.truncated)
        XCTAssertTrue(
            analysis.dataQuality.issues.contains {
                $0.scope == "viewer.range.threadStateDistribution"
                    && $0.category == .probeTruncated
            }
        )
    }

    /// The point of grouping by name: many short calls can outrank one long
    /// one, which `longSlices` cannot show. Totals are clipped to the range and
    /// instants count without contributing time.
    func testSliceNameAggregatesRankTotalCostAndClipToTheRange() async throws {
        let range = try TraceTimeRange.query(startNs: 100, endNs: 500)
        let threadKey = ThreadKey(itid: 7)
        func slice(
            _ rowID: Int64, _ startNs: Int64, _ endNs: Int64, _ name: String
        ) throws -> TraceSlice {
            TraceSlice(
                key: EventKey(table: .callstack, rowID: rowID),
                range: try TraceTimeRange(startNs: startNs, endNs: endNs),
                threadKey: threadKey,
                processKey: ProcessKey(ipid: 1),
                pid: 1, tid: 70, processName: "p", threadName: "t",
                name: name, category: nil, depth: 0,
                parentEventKey: nil, isAsync: false, isOpenEnded: false
            )
        }
        let slices = [
            // One long call: 200ns inside the range.
            try slice(1, 150, 350, "rare"),
            // Four short calls: 4 x 60ns = 240ns, so "frequent" wins on total
            // while losing on any single duration.
            try slice(2, 100, 160, "frequent"),
            try slice(3, 200, 260, "frequent"),
            try slice(4, 300, 360, "frequent"),
            try slice(5, 400, 460, "frequent"),
            // Straddles the end boundary: only [450,500) counts.
            try slice(6, 450, 900, "straddles"),
            // Instant: counted, contributes no time.
            try slice(7, 200, 200, "instant"),
        ]
        let analysis = try await TraceRangeAnalysisEngine(
            repository: Repository(slices: slices)
        ).analyze(TraceRangeAnalysisRequest(range: range))

        let byName = Dictionary(
            uniqueKeysWithValues: analysis.sliceNameAggregates.map { ($0.name, $0) }
        )
        XCTAssertEqual(byName["frequent"]?.totalDurationNs, 240)
        XCTAssertEqual(byName["frequent"]?.occurrences, 4)
        XCTAssertEqual(byName["frequent"]?.averageDurationNs, 60)
        XCTAssertEqual(byName["rare"]?.totalDurationNs, 200)
        XCTAssertEqual(byName["rare"]?.occurrences, 1)
        // Clipped overlap, not raw duration.
        XCTAssertEqual(byName["straddles"]?.totalDurationNs, 50)
        // AT-TIME-006: an instant is an occurrence with no duration.
        XCTAssertEqual(byName["instant"]?.occurrences, 1)
        XCTAssertEqual(byName["instant"]?.totalDurationNs, 0)
        XCTAssertEqual(byName["instant"]?.averageDurationNs, 0)
        // Default order is total descending, so the cheap-but-frequent name
        // outranks the single long one.
        XCTAssertEqual(
            analysis.sliceNameAggregates.map(\.name),
            ["frequent", "rare", "straddles", "instant"]
        )
        // The jump target is the earliest occurrence, in event order.
        XCTAssertEqual(byName["frequent"]?.firstEventKey.rowID, 2)
        XCTAssertEqual(byName["frequent"]?.firstThreadKey, threadKey)
        XCTAssertFalse(analysis.sliceNameAggregatesTruncated)
    }

    /// A bounded reduction must announce itself. Presenting a partial sum as an
    /// exact total is the failure mode this section exists to avoid.
    func testSliceNameAggregateTruncationIsReportedNotSilent() async throws {
        let range = try TraceTimeRange.query(startNs: 0, endNs: 10_000)
        let slices = try (1...40).map { index in
            TraceSlice(
                key: EventKey(table: .callstack, rowID: Int64(index)),
                range: try TraceTimeRange(
                    startNs: Int64(index) * 10, endNs: Int64(index) * 10 + 5
                ),
                threadKey: ThreadKey(itid: 1),
                processKey: nil,
                pid: nil, tid: nil, processName: nil, threadName: nil,
                name: "repeated", category: nil, depth: 0,
                parentEventKey: nil, isAsync: false, isOpenEnded: false
            )
        }
        let analysis = try await TraceRangeAnalysisEngine(
            repository: Repository(slices: slices)
        ).analyze(
            TraceRangeAnalysisRequest(range: range, maximumSlices: 5)
        )
        XCTAssertTrue(analysis.sliceNameAggregatesTruncated)
        XCTAssertEqual(analysis.sliceNameAggregates.first?.occurrences, 5)
        XCTAssertTrue(
            analysis.dataQuality.issues.contains {
                $0.scope == "viewer.range.sliceNameAggregates"
                    && $0.category == .probeTruncated
            }
        )
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
        let repository = Repository(slices: named, cpuSlices: [first, second])
        let result = try await TraceRangeAnalysisEngine(repository: repository).analyze(
            TraceRangeAnalysisRequest(
                range: range, maximumSlices: 2, topThreadLimit: 2,
                longSliceLimit: 2
            )
        )
        // CPU utilization and top threads reduce one scheduling page. A second
        // byte-identical query here is duplicated Store work, not a second budget.
        let issuedCPUQueries = await repository.cpuSliceQueries.count
        XCTAssertEqual(issuedCPUQueries, 1)
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

    /// Upstream's CPU-by-thread sheet has a `cpu${i}` column beside the total.
    /// The split is a regrouping of the page the total already reduced, so the
    /// parts must sum to the whole and clip to the range identically.
    func testTopThreadsSplitTimePerCPUAndTheSplitSumsToTheTotal() async throws {
        let range = try TraceTimeRange.query(startNs: 100, endNs: 500)
        let migrating = ThreadKey(itid: 11)
        let pinned = ThreadKey(itid: 12)
        func slice(
            _ rowID: Int64, _ startNs: Int64, _ endNs: Int64,
            cpu: Int64, thread: ThreadKey
        ) throws -> CpuSlice {
            CpuSlice(
                key: EventKey(table: .schedSlice, rowID: rowID),
                range: try TraceTimeRange(startNs: startNs, endNs: endNs),
                cpu: cpu, threadKey: thread, processKey: ProcessKey(ipid: 1),
                tid: thread.itid, pid: 1, threadName: "t\(thread.itid)",
                processName: "p", endState: nil, priority: nil, isOpenEnded: false
            )
        }
        let analysis = try await TraceRangeAnalysisEngine(
            repository: Repository(
                cpuSlices: [
                    // Migrates: 100 ns on CPU 0, then 60 + 40 ns on CPU 3.
                    try slice(1, 100, 200, cpu: 0, thread: migrating),
                    try slice(2, 200, 260, cpu: 3, thread: migrating),
                    // Straddles the range end: only [460, 500) counts, and it
                    // has to count in the CPU 3 column too.
                    try slice(3, 460, 900, cpu: 3, thread: migrating),
                    try slice(4, 300, 380, cpu: 1, thread: pinned),
                ]
            )
        ).analyze(TraceRangeAnalysisRequest(range: range))

        let byThread = Dictionary(
            uniqueKeysWithValues: analysis.topThreads.map { ($0.threadKey, $0) }
        )
        let migrated = try XCTUnwrap(byThread[migrating])
        XCTAssertEqual(migrated.occupiedNs, 200)
        XCTAssertEqual(
            migrated.cpuBreakdown.map(\.cpu), [0, 3], "ascending by CPU"
        )
        XCTAssertEqual(migrated.cpuBreakdown.map(\.occupiedNs), [100, 100])
        XCTAssertEqual(migrated.cpuBreakdown.map(\.sliceCount), [1, 2])

        let stayed = try XCTUnwrap(byThread[pinned])
        XCTAssertEqual(stayed.cpuBreakdown.map(\.cpu), [1])
        XCTAssertEqual(stayed.cpuBreakdown.first?.occupiedNs, 80)

        for thread in analysis.topThreads {
            XCTAssertEqual(
                thread.cpuBreakdown.reduce(0) { $0 + $1.occupiedNs },
                thread.occupiedNs,
                "the split must account for the whole total"
            )
            XCTAssertEqual(
                thread.cpuBreakdown.reduce(0) { $0 + $1.sliceCount },
                thread.sliceCount
            )
        }
    }
}
