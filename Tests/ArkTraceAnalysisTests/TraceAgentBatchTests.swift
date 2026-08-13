@testable import ArkTraceAnalysis
import ArkTraceCore
import Foundation
import XCTest

final class TraceAgentBatchTests: XCTestCase {
    private final class ByteCountBarrier: @unchecked Sendable {
        let reached = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var used = false

        func waitOnce() {
            lock.lock()
            let shouldWait = !used
            used = true
            lock.unlock()
            guard shouldWait else { return }
            reached.signal()
            release.wait()
        }
    }

    private actor Repository: TraceRepositoryProtocol {
        let traceMetadata: TraceMetadata
        let processRows: [TraceProcess]
        let threadRows: [TraceThread]
        let cpuRows: [CpuSlice]
        let stateRows: [ThreadStateInterval]
        let sliceRows: [TraceSlice]
        let counterRows: [CounterSeries]
        let hideBroadDirectories: Bool
        let metadataDelay: Duration?
        let metadataFails: Bool
        let metadataIgnoresCancellation: Bool
        private(set) var cpuCallCount = 0
        private(set) var lastCounterPID: Int64?
        private(set) var lastCounterName: CounterNameFilter?

        init(
            durationNs: Int64 = 1_000,
            capabilities: TraceCapabilities = TraceCapabilities(
                cpuScheduling: true, threadStates: true, namedSlices: true,
                cpuCounters: true, processCounters: true
            ),
            processes: [TraceProcess] = [],
            threads: [TraceThread] = [],
            cpuSlices: [CpuSlice] = [],
            states: [ThreadStateInterval] = [],
            slices: [TraceSlice] = [],
            counters: [CounterSeries] = [],
            hideBroadDirectories: Bool = false,
            metadataDelay: Duration? = nil,
            metadataFails: Bool = false,
            metadataIgnoresCancellation: Bool = false
        ) {
            traceMetadata = Self.metadata(durationNs: durationNs, capabilities: capabilities)
            processRows = processes
            threadRows = threads
            cpuRows = cpuSlices
            stateRows = states
            sliceRows = slices
            counterRows = counters
            self.hideBroadDirectories = hideBroadDirectories
            self.metadataDelay = metadataDelay
            self.metadataFails = metadataFails
            self.metadataIgnoresCancellation = metadataIgnoresCancellation
        }

        func metadata() async throws -> TraceMetadata {
            if let metadataDelay {
                if metadataIgnoresCancellation { try? await Task.sleep(for: metadataDelay) }
                else { try await Task.sleep(for: metadataDelay) }
            }
            if metadataFails {
                throw ArkTraceError(
                    code: .traceDatabaseInvalid,
                    stage: .validating,
                    message: "Injected metadata failure"
                )
            }
            return traceMetadata
        }

        func processes(_ query: ProcessQuery) async throws -> BoundedPage<TraceProcess> {
            if hideBroadDirectories, query.processKey == nil { return BoundedPage(items: [], truncated: false) }
            let rows = processRows.filter {
                (query.processKey == nil || $0.key == query.processKey)
                    && (query.pid == nil || $0.pid == query.pid)
            }
            return BoundedPage(
                items: Array(rows.prefix(query.limit)),
                truncated: rows.count > query.limit
            )
        }

        func threads(_ query: ThreadQuery) async throws -> BoundedPage<TraceThread> {
            if hideBroadDirectories, query.threadKey == nil { return BoundedPage(items: [], truncated: false) }
            let rows = threadRows.filter {
                (query.processKey == nil || $0.processKey == query.processKey)
                    && (query.threadKey == nil || $0.key == query.threadKey)
                    && (query.pid == nil || $0.pid == query.pid)
                    && (query.tid == nil || $0.tid == query.tid)
            }
            return BoundedPage(
                items: Array(rows.prefix(query.limit)),
                truncated: rows.count > query.limit
            )
        }

        func summaryFacts(_ query: TraceSummaryQuery) async throws -> TraceSummaryFacts {
            TraceSummaryFacts(
                cpuCount: TraceBoundedCount(
                    value: Int64(Set(cpuRows.map(\.cpu)).count), truncated: false
                ),
                processCount: TraceBoundedCount(value: Int64(processRows.count), truncated: false),
                threadCount: TraceBoundedCount(value: Int64(threadRows.count), truncated: false),
                cpuSliceCount: TraceBoundedCount(value: Int64(cpuRows.count), truncated: false),
                threadStateCount: TraceBoundedCount(value: Int64(stateRows.count), truncated: false),
                namedSliceCount: TraceBoundedCount(value: Int64(sliceRows.count), truncated: false),
                counterSeriesCount: TraceBoundedCount(
                    value: Int64(counterRows.count), truncated: false
                ),
                eventCountBySource: nil
            )
        }

        func cpuSlices(_ query: CpuSliceQuery) async throws -> TraceEventPage<CpuSlice> {
            cpuCallCount += 1
            guard traceMetadata.capabilities.cpuScheduling else { return .unavailable }
            let rows = cpuRows.filter {
                $0.range.intersects(query: query.range)
                    && (query.cpu == nil || $0.cpu == query.cpu)
                    && (query.processKey == nil || $0.processKey == query.processKey)
                    && (query.pid == nil || $0.pid == query.pid)
                    && (query.threadKey == nil || $0.threadKey == query.threadKey)
                    && (query.tid == nil || $0.tid == query.tid)
            }
            return TraceEventPage(
                items: Array(rows.prefix(query.limit)),
                truncated: rows.count > query.limit
            )
        }

        func threadStates(
            _ query: ThreadStateQuery
        ) async throws -> TraceEventPage<ThreadStateInterval> {
            guard traceMetadata.capabilities.threadStates else { return .unavailable }
            let rows = stateRows.filter {
                $0.range.intersects(query: query.range)
                    && (query.cpu == nil || $0.cpu == query.cpu)
                    && (query.processKey == nil || $0.processKey == query.processKey)
                    && (query.pid == nil || $0.pid == query.pid)
                    && (query.threadKey == nil || $0.threadKey == query.threadKey)
                    && (query.tid == nil || $0.tid == query.tid)
                    && (query.rawState == nil || $0.state == query.rawState)
                    && (query.state == nil || $0.normalizedState == query.state)
            }
            return TraceEventPage(
                items: Array(rows.prefix(query.limit)),
                truncated: rows.count > query.limit
            )
        }

        func slices(_ query: TraceSliceQuery) async throws -> TraceEventPage<TraceSlice> {
            guard traceMetadata.capabilities.namedSlices else { return .unavailable }
            let rows = sliceRows.filter {
                $0.range.intersects(query: query.range)
                    && (query.processKey == nil || $0.processKey == query.processKey)
                    && (query.pid == nil || $0.pid == query.pid)
                    && (query.threadKey == nil || $0.threadKey == query.threadKey)
                    && (query.tid == nil || $0.tid == query.tid)
                    && (query.minimumDurationNs == nil
                        || $0.range.durationNs >= query.minimumDurationNs!)
                    && (query.depth == nil || $0.depth == query.depth)
                    && Self.matches($0.name, query.name)
            }
            return TraceEventPage(
                items: Array(rows.prefix(query.limit)),
                truncated: rows.count > query.limit
            )
        }

        func counters(_ query: CounterQuery) async throws -> TraceEventPage<CounterSeries> {
            lastCounterPID = query.pid
            lastCounterName = query.name
            guard traceMetadata.capabilities.cpuCounters
                    || traceMetadata.capabilities.processCounters
            else { return .unavailable }
            let rows = counterRows.compactMap { series -> CounterSeries? in
                guard (query.filterID == nil || series.filterID == query.filterID),
                    (query.cpu == nil || series.cpu == query.cpu),
                    (query.processKey == nil || series.processKey == query.processKey),
                    (query.pid == nil || series.pid == query.pid),
                    Self.matches(series.name, query.name)
                else { return nil }
                let samples = series.samples.filter { sample in
                    let end: Int64
                    if let duration = sample.durationNs, duration >= 0 {
                        let (candidate, overflow) = sample.timestampNs
                            .addingReportingOverflow(duration)
                        end = overflow ? traceMetadata.durationNs
                            : min(traceMetadata.durationNs, candidate)
                    } else {
                        end = traceMetadata.durationNs
                    }
                    let event = try! TraceTimeRange(startNs: sample.timestampNs, endNs: end)
                    return event.intersects(query: query.range)
                }
                guard !samples.isEmpty else { return nil }
                return CounterSeries(
                    filterID: series.filterID, name: series.name, scope: series.scope,
                    cpu: series.cpu, processKey: series.processKey, pid: series.pid,
                    processName: series.processName, unit: series.unit, samples: samples
                )
            }
            let count = rows.reduce(0) { $0 + $1.samples.count }
            var remaining = query.limit
            var output: [CounterSeries] = []
            for series in rows where remaining > 0 {
                let samples = Array(series.samples.prefix(remaining))
                output.append(
                    CounterSeries(
                        filterID: series.filterID, name: series.name, scope: series.scope,
                        cpu: series.cpu, processKey: series.processKey, pid: series.pid,
                        processName: series.processName, unit: series.unit, samples: samples
                    )
                )
                remaining -= samples.count
            }
            return TraceEventPage(items: output, truncated: count > query.limit)
        }

        func capturedCounterFilter() -> (Int64?, String?) {
            let text: String?
            switch lastCounterName {
            case .exact(let value), .prefix(let value), .contains(let value): text = value
            case nil: text = nil
            }
            return (lastCounterPID, text)
        }

        func capturedCPUCallCount() -> Int { cpuCallCount }

        private static func metadata(
            durationNs: Int64,
            capabilities: TraceCapabilities
        ) -> TraceMetadata {
            TraceMetadata(
                traceSHA256: String(repeating: "a", count: 64),
                sourceByteCount: 100,
                durationNs: durationNs,
                sourceFormat: "htrace",
                parser: TraceParserIdentity(
                    name: "parser", reportedVersion: "1",
                    binarySHA256: String(repeating: "b", count: 64),
                    upstreamRepository: "https://example.invalid/repo",
                    upstreamRevision: String(repeating: "c", count: 40),
                    architecture: "arm64", adapterVersion: "1", buildRecipeVersion: "1"
                ),
                schemaFingerprint: String(repeating: "d", count: 64),
                capabilities: capabilities,
                dataQuality: TraceDataQuality()
            )
        }

        private static func matches(_ value: String, _ filter: TraceSliceNameFilter?) -> Bool {
            guard let filter else { return true }
            switch filter {
            case .exact(let text): return value == text
            case .prefix(let text): return value.hasPrefix(text)
            case .contains(let text): return value.contains(text)
            }
        }

        private static func matches(_ value: String, _ filter: CounterNameFilter?) -> Bool {
            guard let filter else { return true }
            switch filter {
            case .exact(let text): return value == text
            case .prefix(let text): return value.hasPrefix(text)
            case .contains(let text): return value.contains(text)
            }
        }
    }

    func testClosedAgentViewsAreStableBoundedAndCapabilityAware() async throws {
        let processA = process(1, pid: 42)
        let processB = process(2, pid: 42)
        let threadA = thread(11, process: processA.key, tid: 7, pid: 42)
        let threadB = thread(12, process: processB.key, tid: 7, pid: 42)
        let cpu = [
            cpuSlice(
                2, 200, 250, cpu: 1, process: processB.key, thread: threadB.key,
                pid: 42, tid: 7
            ),
            cpuSlice(
                1, 100, 150, cpu: 0, process: processA.key, thread: threadA.key,
                pid: 42, tid: 7
            ),
            cpuSlice(
                3, 250, 250, cpu: 0, process: processA.key, thread: threadA.key,
                pid: 42, tid: 7
            ),
        ]
        let states = [
            state(4, 120, 180, thread: threadA.key, process: processA.key, raw: "Running"),
            state(5, 180, 210, thread: threadB.key, process: processB.key, raw: "Sleeping"),
        ]
        let slices = [
            slice(6, 140, 220, thread: threadA.key, process: processA.key, name: "sql%_literal"),
            slice(7, 220, 240, thread: threadB.key, process: processB.key, name: "other"),
        ]
        let counters = [
            counterSeries(process: processA.key, pid: 42),
            CounterSeries(
                filterID: 1, name: "cpu", scope: .cpu,
                cpu: 0, processKey: nil, unit: "cycles",
                samples: [
                    CounterSample(
                        key: EventKey(table: .measure, rowID: 40),
                        timestampNs: 100, value: 9, durationNs: 0
                    )
                ]
            ),
        ]
        let repository = Repository(
            processes: [processA, processB], threads: [threadA, threadB],
            cpuSlices: cpu, states: states, slices: slices, counters: counters
        )
        let engine = TraceAgentQueryEngine(repository: repository)
        let range = try TraceTimeRange.query(startNs: 100, endNs: 300)

        let cpuResult = try await engine.query(
            TraceAgentQueryRequest(
                view: .cpuSlices, range: range,
                filters: try TraceAgentQueryFilters(pid: 42, tid: 7), limit: 2
            )
        )
        XCTAssertEqual(cpuResult.cpuSlices.map(\.key.rowID), [1, 2])
        XCTAssertTrue(cpuResult.truncated)
        XCTAssertEqual(Set(cpuResult.cpuSlices.compactMap(\.processKey)), [processA.key, processB.key])
        let instantBoundary = try await engine.query(
            TraceAgentQueryRequest(
                view: .cpuSlices,
                range: TraceTimeRange.query(startNs: 250, endNs: 251)
            )
        )
        XCTAssertEqual(
            instantBoundary.cpuSlices.map(\.key.rowID),
            [3],
            "the duration ending at query start must not touch-match; the instant must match"
        )

        let stateResult = try await engine.query(
            TraceAgentQueryRequest(
                view: .threadStates, range: range,
                filters: try TraceAgentQueryFilters(cpu: 0, rawState: "Running")
            )
        )
        XCTAssertEqual(stateResult.threadStates.map(\.key.rowID), [4])
        let truncatedStates = try await engine.query(
            TraceAgentQueryRequest(view: .threadStates, range: range, limit: 1)
        )
        XCTAssertTrue(truncatedStates.truncated)

        let matchingSlice = try await engine.query(
            TraceAgentQueryRequest(
                view: .slices, range: range,
                filters: try TraceAgentQueryFilters(name: "sql%", nameMatch: .prefix),
                limit: 1
            )
        )
        XCTAssertEqual(matchingSlice.slices.map(\.key.rowID), [6])
        let truncatedSlices = try await engine.query(
            TraceAgentQueryRequest(view: .slices, range: range, limit: 1)
        )
        XCTAssertTrue(truncatedSlices.truncated)

        let injection = "sql%_' OR 1=1 --"
        let emptySlices = try await engine.query(
            TraceAgentQueryRequest(
                view: .slices, range: range,
                filters: try TraceAgentQueryFilters(name: injection, nameMatch: .exact)
            )
        )
        XCTAssertTrue(emptySlices.slices.isEmpty)

        let counterResult = try await engine.query(
            TraceAgentQueryRequest(
                view: .counters, range: range,
                filters: try TraceAgentQueryFilters(
                    pid: 42, name: injection, nameMatch: .contains
                )
            )
        )
        XCTAssertTrue(counterResult.counters.isEmpty)
        let captured = await repository.capturedCounterFilter()
        XCTAssertEqual(captured.0, 42)
        XCTAssertEqual(captured.1, injection)

        let matchingCounter = try await engine.query(
            TraceAgentQueryRequest(
                view: .counters, range: range,
                filters: try TraceAgentQueryFilters(
                    pid: 42, name: "memory", nameMatch: .exact
                ),
                limit: 1
            )
        )
        XCTAssertEqual(matchingCounter.counters.map(\.sample.key.rowID), [30])
        XCTAssertTrue(matchingCounter.truncated)

        let globallyOrderedCounters = try await engine.query(
            TraceAgentQueryRequest(view: .counters, range: range, limit: 3)
        )
        XCTAssertEqual(
            globallyOrderedCounters.counters.map(\.sample.key.rowID),
            [40, 30, 31],
            "counter events must preserve the global timestamp/EventKey prefix"
        )

        let emptyCPU = try await engine.query(
            TraceAgentQueryRequest(
                view: .cpuSlices, range: range,
                filters: try TraceAgentQueryFilters(pid: 999)
            )
        )
        XCTAssertTrue(emptyCPU.cpuSlices.isEmpty)
        let emptyState = try await engine.query(
            TraceAgentQueryRequest(
                view: .threadStates, range: range,
                filters: try TraceAgentQueryFilters(rawState: "Missing")
            )
        )
        XCTAssertTrue(emptyState.threadStates.isEmpty)

        let unavailable = try await TraceAgentQueryEngine(
            repository: Repository(
                capabilities: TraceCapabilities(
                    cpuScheduling: false, threadStates: false, namedSlices: false,
                    cpuCounters: false, processCounters: false
                )
            )
        ).query(TraceAgentQueryRequest(view: .slices, range: range))
        XCTAssertFalse(unavailable.capabilityAvailable)
        XCTAssertTrue(unavailable.slices.isEmpty)
    }

    func testAgentViewRejectsIncompatibleFilterBeforeRepositoryAndOutOfRange() async throws {
        let repository = Repository()
        let engine = TraceAgentQueryEngine(repository: repository)
        let range = try TraceTimeRange.query(startNs: 0, endNs: 100)
        do {
            _ = try await engine.query(
                TraceAgentQueryRequest(
                    view: .cpuSlices, range: range,
                    filters: try TraceAgentQueryFilters(name: "not-a-cpu-filter")
                )
            )
            XCTFail("incompatible filter must fail closed")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertEqual(error.stage, .request)
        }
        let callCount = await repository.capturedCPUCallCount()
        XCTAssertEqual(callCount, 0)

        let invalidRequests: [(TraceAgentQueryView, TraceAgentQueryFilters)] = [
            (.threadStates, try TraceAgentQueryFilters(name: "invalid")),
            (.slices, try TraceAgentQueryFilters(rawState: "invalid")),
            (.counters, try TraceAgentQueryFilters(threadKey: ThreadKey(itid: 1))),
        ]
        for (view, filters) in invalidRequests {
            do {
                _ = try await engine.query(
                    TraceAgentQueryRequest(view: view, range: range, filters: filters)
                )
                XCTFail("each closed view must reject incompatible filters")
            } catch let error as ArkTraceError {
                XCTAssertEqual(error.code, .invalidArgument)
            }
        }

        do {
            _ = try await engine.query(
                TraceAgentQueryRequest(
                    view: .cpuSlices,
                    range: try TraceTimeRange.query(startNs: 999, endNs: 1_001)
                )
            )
            XCTFail("range beyond duration must fail")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .invalidArgument)
        }
    }

    func testAgentCodableRejectsInvalidFiltersAndMixedPayloads() throws {
        let oversizedState = String(repeating: "s", count: 257)
        let invalidFilter = try JSONSerialization.data(withJSONObject: [
            "rawState": oversizedState,
            "nameMatch": "exact",
        ])
        XCTAssertThrowsError(
            try JSONDecoder().decode(TraceAgentQueryFilters.self, from: invalidFilter)
        )
        XCTAssertThrowsError(try TraceAgentQueryFilters(processKey: ProcessKey(ipid: 0)))
        XCTAssertThrowsError(try TraceAgentQueryFilters(threadKey: ThreadKey(itid: 0)))
        XCTAssertNoThrow(try TraceAgentQueryFilters(processKey: ProcessKey(ipid: -1)))
        XCTAssertThrowsError(
            try TraceAgentQueryFilters(nameMatch: .contains)
        )

        for invalidRange in [
            #"{"startNs":-1,"endNs":1}"#,
            #"{"startNs":2,"endNs":1}"#,
        ] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    TraceTimeRange.self, from: Data(invalidRange.utf8)
                )
            )
        }
        let instantRange = try JSONDecoder().decode(
            TraceTimeRange.self,
            from: Data(#"{"startNs":1,"endNs":1}"#.utf8)
        )
        XCTAssertTrue(instantRange.isInstant)
        XCTAssertThrowsError(
            try TraceAgentQueryRequest(view: .cpuSlices, range: instantRange)
        )
        XCTAssertThrowsError(
            try TraceDeterministicAnalysisRequest(range: instantRange)
        )
        XCTAssertThrowsError(
            try TraceContextRequest(time: .range(instantRange))
        )

        let range = try TraceTimeRange.query(startNs: 0, endNs: 10)
        let result = try TraceAgentQueryResult(
            view: .cpuSlices, range: range,
            capabilityAvailable: true, truncated: false,
            dataQuality: TraceDataQuality(), cpuSlices: []
        )
        let encoded = try JSONEncoder().encode(result)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNotNil(object["cpuSlices"])
        XCTAssertNil(object["threadStates"])
        XCTAssertNil(object["slices"])
        XCTAssertNil(object["counters"])

        var mixed = object
        mixed["threadStates"] = []
        let mixedData = try JSONSerialization.data(withJSONObject: mixed)
        XCTAssertThrowsError(
            try JSONDecoder().decode(TraceAgentQueryResult.self, from: mixedData)
        )

        let counter = TraceAgentCounterEvent(
            series: CounterSeries(
                filterID: 1, name: "x", scope: .cpu, cpu: nil,
                processKey: nil, pid: nil, processName: nil, unit: nil,
                samples: []
            ),
            sample: CounterSample(
                key: EventKey(table: .measure, rowID: 1),
                timestampNs: 1, value: 2, durationNs: nil
            )
        )
        let canonical = JSONEncoder()
        canonical.outputFormatting = [.sortedKeys]
        XCTAssertEqual(
            String(decoding: try canonical.encode(counter), as: UTF8.self),
            #"{"cpu":null,"filterID":1,"name":"x","pid":null,"processKey":null,"processName":null,"sample":{"durationNs":null,"key":{"rowID":1,"table":"measure"},"timestampNs":1,"value":2},"scope":"cpu","unit":null}"#
        )
        let nullableProcess = TraceProcess(
            key: ProcessKey(ipid: 1), pid: 10, name: nil,
            startNs: nil, endNs: nil, threadCount: nil
        )
        XCTAssertEqual(
            String(decoding: try canonical.encode(nullableProcess), as: UTF8.self),
            #"{"endNs":null,"key":{"ipid":1},"name":null,"pid":10,"startNs":null,"threadCount":null}"#
        )
        let nullableThread = TraceThread(
            key: ThreadKey(itid: 2), processKey: nil, tid: 20, pid: nil,
            name: nil, processName: nil, startNs: nil, endNs: nil,
            isMainThread: nil
        )
        XCTAssertEqual(
            String(decoding: try canonical.encode(nullableThread), as: UTF8.self),
            #"{"endNs":null,"isMainThread":null,"key":{"itid":2},"name":null,"pid":null,"processKey":null,"processName":null,"startNs":null,"tid":20}"#
        )

        let timestamp = TraceContextTimeSelection.timestamp(
            timestampNs: 10, windowBeforeNs: 2, windowAfterNs: 3
        )
        XCTAssertEqual(
            String(decoding: try canonical.encode(timestamp), as: UTF8.self),
            #"{"timestampNs":10,"windowAfterNs":3,"windowBeforeNs":2}"#
        )
        let contextRange = TraceContextTimeSelection.range(
            try TraceTimeRange.query(startNs: 1, endNs: 2)
        )
        XCTAssertEqual(
            String(decoding: try canonical.encode(contextRange), as: UTF8.self),
            #"{"range":{"endNs":2,"startNs":1}}"#
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TraceContextTimeSelection.self,
                from: Data(
                    #"{"range":{"startNs":1,"endNs":2},"timestampNs":1,"windowBeforeNs":1,"windowAfterNs":1}"#.utf8
                )
            )
        )
    }

    func testAnalysisMachineOptionalsEncodeAsExplicitNulls() async throws {
        let processKey = ProcessKey(ipid: -1)
        let threadKey = ThreadKey(itid: -1)
        let cpu = CpuSlice(
            key: EventKey(table: .schedSlice, rowID: 1),
            range: try TraceTimeRange(startNs: 1, endNs: 2),
            cpu: 0, threadKey: threadKey, processKey: processKey,
            tid: nil, pid: nil, threadName: nil, processName: nil,
            endState: nil, priority: nil, isOpenEnded: false
        )
        let state = ThreadStateInterval(
            key: EventKey(table: .threadState, rowID: 2),
            range: try TraceTimeRange(startNs: 2, endNs: 3),
            threadKey: threadKey, processKey: nil,
            state: "Unknown", normalizedState: nil, cpu: nil, tid: nil, pid: nil,
            processName: nil, threadName: nil, isOpenEnded: false
        )
        let named = TraceSlice(
            key: EventKey(table: .callstack, rowID: 3),
            range: try TraceTimeRange(startNs: 3, endNs: 4),
            threadKey: nil, processKey: nil, pid: nil, tid: nil,
            processName: nil, threadName: nil, name: "x", category: nil,
            depth: nil, parentEventKey: nil, isAsync: false, isOpenEnded: false
        )
        let result = try await TraceDeterministicAnalysisEngine(
            repository: Repository(cpuSlices: [cpu], states: [state], slices: [named])
        ).analyze(
            TraceDeterministicAnalysisRequest(
                range: TraceTimeRange.query(startNs: 0, endNs: 10)
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for value in [
            try JSONSerialization.jsonObject(with: encoder.encode(result.topProcesses[0])),
            try JSONSerialization.jsonObject(with: encoder.encode(result.topThreads[0])),
            try JSONSerialization.jsonObject(with: encoder.encode(result.threadStateDistribution[0])),
            try JSONSerialization.jsonObject(with: encoder.encode(result.longSlices[0])),
        ] {
            let object = try XCTUnwrap(value as? [String: Any])
            XCTAssertTrue(object.values.contains { $0 is NSNull })
        }
    }

    func testDeterministicAnalysisCoversClippingRankingStatesLatencyAndHotBuckets() async throws {
        let processA = process(1, pid: 10)
        let processB = process(2, pid: 20)
        let threadA = thread(11, process: processA.key, tid: 101, pid: 10)
        let threadB = thread(12, process: processB.key, tid: 102, pid: 20)
        let cpu = [
            cpuSlice(1, 0, 150, cpu: 0, process: processA.key, thread: threadA.key),
            cpuSlice(2, 50, 200, cpu: 0, process: processB.key, thread: threadB.key),
            cpuSlice(3, 80, 90, cpu: 1, process: processA.key, thread: threadA.key),
            cpuSlice(4, 120, 120, cpu: 1, process: processA.key, thread: threadA.key),
        ]
        let states = [
            state(10, 60, 80, thread: threadA.key, process: processA.key, raw: "Runnable", normalized: .runnable),
            state(11, 90, 100, thread: threadA.key, process: processA.key, raw: "FutureUnknown"),
        ]
        let named = [
            slice(20, 55, 145, thread: threadA.key, process: processA.key, name: "long"),
            slice(21, 100, 100, thread: threadB.key, process: processB.key, name: "instant"),
        ]
        let request = try TraceDeterministicAnalysisRequest(
            range: TraceTimeRange.query(startNs: 50, endNs: 150),
            hotBucketCount: 4
        )
        let repository = Repository(
            processes: [processA, processB], threads: [threadA, threadB],
            cpuSlices: cpu, states: states, slices: named
        )
        let engine = TraceDeterministicAnalysisEngine(repository: repository)
        let result = try await engine.analyze(request)

        XCTAssertEqual(result.cpuUtilization.map(\.cpu), [0, 1])
        XCTAssertEqual(result.cpuUtilization.first?.rawRunningNs, 200)
        XCTAssertEqual(result.cpuUtilization.first?.occupiedNs, 100)
        XCTAssertTrue(result.dataQuality.issues.contains { $0.scope == "sched_slice.overlap" })
        XCTAssertEqual(result.topProcesses.map(\.processKey.ipid), [1, 2])
        XCTAssertEqual(result.topThreads.map(\.threadKey.itid), [11, 12])
        XCTAssertTrue(result.threadStateDistribution.contains { $0.rawState == "FutureUnknown" })
        XCTAssertEqual(result.longSlices.map(\.key.rowID), [20, 21])
        XCTAssertTrue(result.schedulingLatency.supported)
        XCTAssertEqual(result.schedulingLatency.percentiles?.p50Ns, 20)
        XCTAssertFalse(result.hotIntervals.isEmpty)
        XCTAssertEqual(result.kind, .deterministicBatch)

        let globallyRetained = try result.retainingRows(maximumRows: 1)
        XCTAssertEqual(globallyRetained.cpuUtilization.count, 1)
        XCTAssertEqual(globallyRetained.topProcesses.count, 0)
        XCTAssertEqual(globallyRetained.topThreads.count, 0)
        XCTAssertEqual(globallyRetained.longSlices.count, 0)
        XCTAssertEqual(globallyRetained.threadStateDistribution.count, 0)
        XCTAssertEqual(globallyRetained.schedulingLatency.topSamples.count, 0)
        XCTAssertEqual(globallyRetained.hotIntervals.count, 0)
        XCTAssertEqual(globallyRetained.sections.cpuUtilization.returnedCount, 1)
        XCTAssertTrue(globallyRetained.sections.topProcesses.truncated)
        XCTAssertTrue(globallyRetained.sections.schedulingLatency.truncated)
        let parameterEncoder = JSONEncoder()
        parameterEncoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(
            String(decoding: try parameterEncoder.encode(result.parameters), as: UTF8.self),
            #"{"filters":{"counterFilterID":null,"cpu":null,"depth":null,"minimumDurationNs":null,"name":null,"nameMatch":"exact","normalizedState":null,"pid":null,"processKey":null,"rawState":null,"threadKey":null,"tid":null},"hotBucketCount":4,"hotIntervalLimit":20,"longSliceLimit":20,"maximumCPUSlices":20000,"maximumHotEvents":20000,"maximumNamedSlices":20000,"maximumProcessSlices":20000,"maximumSchedulingEvents":20000,"maximumStateIntervals":20000,"maximumThreadSlices":20000,"minimumLongSliceDurationNs":0,"schedulingSampleLimit":20,"timeoutAttoseconds":0,"timeoutSeconds":30,"topProcessLimit":10,"topThreadLimit":10}"#
        )
        let firstHot = try XCTUnwrap(result.hotIntervals.first)
        XCTAssertEqual(
            firstHot.score.total,
            firstHot.score.cpuBusyNs + firstHot.score.contextSwitchScoreNs
                + firstHot.score.longSliceNs
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let repeated = try await engine.analyze(request)
        XCTAssertEqual(try encoder.encode(result), try encoder.encode(repeated))

        let ambiguousThread = ThreadKey(itid: 50)
        let stateOne = ThreadStateInterval(
            key: EventKey(table: .threadState, rowID: 100),
            range: try TraceTimeRange(startNs: 1, endNs: 2),
            threadKey: ambiguousThread, processKey: ProcessKey(ipid: 2),
            state: "Same", normalizedState: .blocked, cpu: 0,
            tid: 200, pid: 20, processName: nil, threadName: nil,
            isOpenEnded: false
        )
        let stateTwo = ThreadStateInterval(
            key: EventKey(table: .threadState, rowID: 101),
            range: try TraceTimeRange(startNs: 2, endNs: 3),
            threadKey: ambiguousThread, processKey: ProcessKey(ipid: 1),
            state: "Same", normalizedState: .blocked, cpu: 0,
            tid: 100, pid: 10, processName: nil, threadName: nil,
            isOpenEnded: false
        )
        let stateRequest = try TraceDeterministicAnalysisRequest(
            range: TraceTimeRange.query(startNs: 0, endNs: 10)
        )
        let forwardStates = try await TraceDeterministicAnalysisEngine(
            repository: Repository(states: [stateOne, stateTwo])
        ).analyze(stateRequest)
        let reversedStates = try await TraceDeterministicAnalysisEngine(
            repository: Repository(states: [stateTwo, stateOne])
        ).analyze(stateRequest)
        XCTAssertEqual(
            forwardStates.threadStateDistribution.compactMap(\.processKey?.ipid),
            [1, 2]
        )
        XCTAssertEqual(
            try encoder.encode(forwardStates), try encoder.encode(reversedStates)
        )
    }

    func testSchedulingPercentileNearestRankAndUnsupportedAreStable() async throws {
        let process = process(1, pid: 10)
        var cpu: [CpuSlice] = []
        var states: [ThreadStateInterval] = []
        for index in 0..<5 {
            let thread = ThreadKey(itid: Int64(index + 1))
            let latency = Int64([1, 2, 3, 4, 100][index])
            let runnableEnd = Int64(100 + index * 100)
            states.append(
                state(
                    Int64(100 + index), runnableEnd - latency, runnableEnd,
                    thread: thread, process: process.key, raw: "Runnable", normalized: .runnable
                )
            )
            cpu.append(
                cpuSlice(
                    Int64(200 + index), runnableEnd, runnableEnd + 5,
                    cpu: 0, process: process.key, thread: thread
                )
            )
        }
        states.append(
            state(
                999, 600, 610, thread: ThreadKey(itid: 99), process: process.key,
                raw: "Runnable", normalized: .runnable
            )
        )
        cpu.append(
            cpuSlice(
                999, 700, 705, cpu: 0, process: process.key,
                thread: ThreadKey(itid: 99)
            )
        )
        let range = try TraceTimeRange.query(startNs: 0, endNs: 1_000)
        let result = try await TraceDeterministicAnalysisEngine(
            repository: Repository(cpuSlices: cpu, states: states)
        ).analyze(TraceDeterministicAnalysisRequest(range: range))
        XCTAssertEqual(result.schedulingLatency.percentiles?.p50Ns, 3)
        XCTAssertEqual(result.schedulingLatency.percentiles?.p90Ns, 100)
        XCTAssertEqual(result.schedulingLatency.percentiles?.p99Ns, 100)
        XCTAssertEqual(result.schedulingLatency.count, 5)

        let unsupported = try await TraceDeterministicAnalysisEngine(
            repository: Repository(
                capabilities: TraceCapabilities(
                    cpuScheduling: true, threadStates: false, namedSlices: true,
                    cpuCounters: false, processCounters: false
                ),
                cpuSlices: cpu
            )
        ).analyze(TraceDeterministicAnalysisRequest(range: range))
        XCTAssertFalse(unsupported.schedulingLatency.supported)
        XCTAssertEqual(
            unsupported.schedulingLatency.unsupportedReason,
            .capabilityUnavailable
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(
            String(
                decoding: try encoder.encode(unsupported.schedulingLatency),
                as: UTF8.self
            ),
            #"{"count":0,"percentiles":null,"supported":false,"topSamples":[],"truncated":false,"unsupportedReason":"capabilityUnavailable"}"#
        )
    }

    func testHotBucketsUseExactNonDivisibleBoundariesAndCountEachSwitchOnce() async throws {
        let process = process(1, pid: 10)
        let thread = thread(1, process: process.key, tid: 10, pid: 10)
        let result = try await TraceDeterministicAnalysisEngine(
            repository: Repository(
                durationNs: 10,
                cpuSlices: [
                    cpuSlice(1, 5, 6, cpu: 0, process: process.key, thread: thread.key),
                    cpuSlice(2, 1, 9, cpu: 1, process: process.key, thread: thread.key),
                ],
                slices: [
                    slice(3, 5, 6, thread: thread.key, process: process.key, name: "short")
                ]
            )
        ).analyze(
            TraceDeterministicAnalysisRequest(
                range: TraceTimeRange.query(startNs: 0, endNs: 10),
                hotBucketCount: 6,
                minimumLongSliceDurationNs: 2
            )
        )
        let containingFive = try XCTUnwrap(
            result.hotIntervals.first { $0.range.startNs == 4 && $0.range.endNs == 6 }
        )
        XCTAssertEqual(containingFive.cpuSliceCount, 2)
        XCTAssertEqual(containingFive.score.cpuBusyNs, 3)
        XCTAssertEqual(result.hotIntervals.reduce(0) { $0 + $1.namedSliceCount }, 0)
        XCTAssertEqual(
            result.hotIntervals.reduce(0) { $0 + $1.score.contextSwitchCount },
            2,
            "one dispatch must be assigned to exactly one bucket"
        )

        let extreme = try await TraceDeterministicAnalysisEngine(
            repository: Repository(
                durationNs: .max,
                cpuSlices: [
                    cpuSlice(
                        3, Int64.max - 5, Int64.max - 4,
                        cpu: 0, process: process.key, thread: thread.key
                    )
                ]
            )
        ).analyze(
            TraceDeterministicAnalysisRequest(
                range: TraceTimeRange.query(
                    startNs: Int64.max - 10, endNs: Int64.max
                ),
                hotBucketCount: 6
            )
        )
        XCTAssertEqual(
            extreme.hotIntervals.reduce(0) { $0 + $1.score.contextSwitchCount },
            1
        )
    }

    func testAnalysisTruncatedSourcesDoNotClaimExactMatchedCounts() async throws {
        let process = process(1, pid: 10)
        let thread = thread(1, process: process.key, tid: 10, pid: 10)
        let result = try await TraceDeterministicAnalysisEngine(
            repository: Repository(
                cpuSlices: [
                    cpuSlice(1, 1, 2, cpu: 0, process: process.key, thread: thread.key),
                    cpuSlice(2, 2, 3, cpu: 0, process: process.key, thread: thread.key),
                ]
            )
        ).analyze(
            TraceDeterministicAnalysisRequest(
                range: TraceTimeRange.query(startNs: 0, endNs: 10),
                maximumCPUSlices: 1,
                maximumProcessSlices: 1,
                maximumThreadSlices: 1,
                maximumHotEvents: 1
            )
        )
        XCTAssertNil(result.sections.cpuUtilization.matchedCount)
        XCTAssertNil(result.sections.topProcesses.matchedCount)
        XCTAssertNil(result.sections.topThreads.matchedCount)
        XCTAssertNil(result.sections.hotIntervals.matchedCount)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(
            String(
                decoding: try encoder.encode(result.sections.cpuUtilization),
                as: UTF8.self
            ),
            #"{"matchedCount":null,"returnedCount":1,"truncated":true}"#
        )
    }

    func testContextNormalizesWindowBuildsClosureAndProducesIdenticalBytes() async throws {
        let process = process(1, pid: 10)
        let thread = thread(11, process: process.key, tid: 101, pid: 10)
        let repository = Repository(
            processes: [process], threads: [thread],
            cpuSlices: [cpuSlice(1, 90, 110, cpu: 0, process: process.key, thread: thread.key)],
            states: [state(2, 95, 105, thread: thread.key, process: process.key, raw: "Running")],
            slices: [slice(3, 100, 140, thread: thread.key, process: process.key, name: "work")],
            counters: [counterSeries(process: process.key, pid: 10)],
            hideBroadDirectories: true
        )
        let request = try TraceContextRequest(
            time: .timestamp(timestampNs: 100, windowBeforeNs: 200, windowAfterNs: 50),
            maximumEvents: 4, maximumRows: 10,
            maximumOutputBytes: TraceContextRequest.defaultMaximumOutputBytes
        )
        let builder = TraceContextBuilder(repository: repository)
        let first = try await builder.build(request)
        let second = try await builder.build(request)
        XCTAssertEqual(first.range.startNs, 0)
        XCTAssertEqual(first.range.endNs, 150)
        XCTAssertEqual(first.processes.map(\.key), [process.key])
        XCTAssertEqual(first.threads.map(\.key), [thread.key])
        XCTAssertFalse(first.truncation.referenceOmittedByBudget)
        let firstBytes = try first.encoded(
            maximumBytes: TraceContextRequest.defaultMaximumOutputBytes
        )
        XCTAssertEqual(
            firstBytes,
            try second.encoded(maximumBytes: TraceContextRequest.defaultMaximumOutputBytes)
        )
        XCTAssertEqual(try first.encoded(maximumBytes: firstBytes.count), firstBytes)
        XCTAssertThrowsError(try first.encoded(maximumBytes: firstBytes.count - 1))
        for budget in [
            TraceContextRequest.defaultMaximumOutputBytes - 1,
            TraceContextRequest.defaultMaximumOutputBytes,
            TraceContextRequest.defaultMaximumOutputBytes + 1,
        ] {
            let bounded = try await builder.build(
                TraceContextRequest(
                    time: request.time,
                    maximumEvents: request.maximumEvents,
                    maximumRows: request.maximumRows,
                    maximumOutputBytes: budget
                )
            )
            XCTAssertLessThanOrEqual(
                try bounded.encoded(maximumBytes: budget).count,
                budget
            )
        }
        let compactBudget = 4 * 1_024
        let compact = try await builder.build(
            TraceContextRequest(
                time: request.time,
                maximumEvents: request.maximumEvents,
                maximumRows: request.maximumRows,
                maximumOutputBytes: compactBudget
            )
        )
        XCTAssertLessThanOrEqual(
            try compact.encoded(maximumBytes: compactBudget).count,
            compactBudget
        )
    }

    func testContextRetentionUsesActualJSONBytesAtEightMiBBoundary() async throws {
        let target = 8 * 1_024 * 1_024
        let escapedPrefix = "line\n\u{2028}😀\"\\/"
        let largeName = escapedPrefix
            + String(repeating: "x", count: target - (64 * 1_024))
        let event = TraceSlice(
            key: EventKey(table: .callstack, rowID: 1),
            range: try TraceTimeRange(startNs: 1, endNs: 2),
            threadKey: nil, processKey: nil, pid: nil, tid: nil,
            processName: nil, threadName: nil, name: largeName, category: nil,
            depth: nil, parentEventKey: nil, isAsync: false, isOpenEnded: false
        )
        let builder = TraceContextBuilder(
            repository: Repository(durationNs: 10, slices: [event])
        )
        let time = TraceContextTimeSelection.range(
            try TraceTimeRange.query(startNs: 0, endNs: 10)
        )
        let full = try await builder.build(
            TraceContextRequest(
                time: time, maximumEvents: 1, maximumRows: 1,
                maximumOutputBytes: 16 * 1_024 * 1_024
            )
        )
        let fullBytes = try full.encoded(maximumBytes: 16 * 1_024 * 1_024)
        XCTAssertLessThan(abs(fullBytes.count - target), 128 * 1_024)

        let exact = try await builder.build(
            TraceContextRequest(
                time: time, maximumEvents: 1, maximumRows: 1,
                maximumOutputBytes: fullBytes.count
            )
        )
        XCTAssertEqual(exact.slices.map(\.key), [event.key])
        XCTAssertEqual(
            try exact.encoded(maximumBytes: fullBytes.count).count,
            fullBytes.count
        )

        let oneByteShort = try await builder.build(
            TraceContextRequest(
                time: time, maximumEvents: 1, maximumRows: 1,
                maximumOutputBytes: fullBytes.count - 1
            )
        )
        XCTAssertTrue(oneByteShort.slices.isEmpty)
        XCTAssertTrue(oneByteShort.truncation.slices.truncated)
        XCTAssertLessThanOrEqual(
            try oneByteShort.encoded(maximumBytes: fullBytes.count - 1).count,
            fullBytes.count - 1
        )
    }

    func testContextCounterIdentityOrderingAndByteCountCancellationAreDeterministic() async throws {
        let process = process(1, pid: 10)
        func series(pid: Int64, processName: String, rowID: Int64) -> CounterSeries {
            CounterSeries(
                filterID: 1, name: "same", scope: .process,
                cpu: nil, processKey: process.key, pid: pid,
                processName: processName, unit: "bytes",
                samples: [
                    CounterSample(
                        key: EventKey(table: .measure, rowID: rowID),
                        timestampNs: rowID, value: rowID, durationNs: 0
                    )
                ]
            )
        }
        let firstSeries = series(pid: 20, processName: "z", rowID: 2)
        let secondSeries = series(pid: 10, processName: "a", rowID: 1)
        let request = try TraceContextRequest(
            time: .range(TraceTimeRange.query(startNs: 0, endNs: 10)),
            maximumEvents: 2, maximumRows: 2, maximumOutputBytes: 256 * 1_024
        )
        let forward = try await TraceContextBuilder(
            repository: Repository(processes: [process], counters: [firstSeries, secondSeries])
        ).build(request)
        let reversed = try await TraceContextBuilder(
            repository: Repository(processes: [process], counters: [secondSeries, firstSeries])
        ).build(request)
        XCTAssertEqual(forward.counters.map(\.pid), [10, 20])
        XCTAssertEqual(
            try forward.encoded(maximumBytes: request.maximumOutputBytes),
            try reversed.encoded(maximumBytes: request.maximumOutputBytes)
        )

        let hugeName = String(repeating: "cancel\n😀", count: 1_000_000)
        let hugeSlice = TraceSlice(
            key: EventKey(table: .callstack, rowID: 9),
            range: try TraceTimeRange(startNs: 1, endNs: 2),
            threadKey: nil, processKey: nil, pid: nil, tid: nil,
            processName: nil, threadName: nil, name: hugeName, category: nil,
            depth: nil, parentEventKey: nil, isAsync: false, isOpenEnded: false
        )
        let barrier = ByteCountBarrier()
        let task = Task {
            try await TraceContextBuilder(
                repository: Repository(durationNs: 10, slices: [hugeSlice]),
                byteCountHook: { barrier.waitOnce() }
            ).build(
                TraceContextRequest(
                    time: .range(try TraceTimeRange.query(startNs: 0, endNs: 10)),
                    maximumEvents: 1, maximumRows: 1,
                    maximumOutputBytes: 64 * 1_024 * 1_024
                )
            )
        }
        XCTAssertEqual(barrier.reached.wait(timeout: .now() + 5), .success)
        task.cancel()
        barrier.release.signal()
        do {
            _ = try await task.value
            XCTFail("cancellation during exact byte counting must not return Context")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .cancelled)
            XCTAssertEqual(error.stage, .analyzing)
        }
    }

    func testContextReportsSectionAndReferenceTruncationAndMinimumEnvelopeFailure() async throws {
        let process = process(1, pid: 10)
        let thread = thread(11, process: process.key, tid: 101, pid: 10)
        let repository = Repository(
            processes: [process], threads: [thread],
            cpuSlices: [
                cpuSlice(1, 90, 110, cpu: 0, process: process.key, thread: thread.key),
                cpuSlice(2, 110, 130, cpu: 0, process: process.key, thread: thread.key),
            ],
            states: [
                state(3, 90, 105, thread: thread.key, process: process.key, raw: "Running"),
                state(4, 105, 120, thread: thread.key, process: process.key, raw: "Sleeping"),
            ],
            slices: [
                slice(5, 95, 115, thread: thread.key, process: process.key, name: "one"),
                slice(6, 115, 135, thread: thread.key, process: process.key, name: "two"),
            ],
            counters: [counterSeries(process: process.key, pid: 10)],
            hideBroadDirectories: true
        )
        let builder = TraceContextBuilder(repository: repository)
        let context = try await builder.build(
            TraceContextRequest(
                time: .range(TraceTimeRange.query(startNs: 80, endNs: 140)),
                maximumEvents: 1, maximumRows: 1, maximumOutputBytes: 64 * 1_024
            )
        )
        XCTAssertTrue(context.truncation.cpuSlices.truncated)
        XCTAssertTrue(context.truncation.threadStates.truncated)
        XCTAssertTrue(context.truncation.slices.truncated)
        XCTAssertTrue(context.truncation.counters.truncated)
        XCTAssertTrue(context.truncation.referenceOmittedByBudget)
        XCTAssertTrue(context.truncation.truncated)

        do {
            _ = try await builder.build(
                TraceContextRequest(
                    time: .range(TraceTimeRange.query(startNs: 80, endNs: 140)),
                    maximumEvents: 1, maximumRows: 1, maximumOutputBytes: 1_024
                )
            )
            XCTFail("minimum envelope over byte budget must fail")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .outputLimitExceeded)
            XCTAssertEqual(error.stage, .encoding)
        }
    }

    func testContextSeparatesMissingReferencesFromBudgetAndUsesCanonicalDirectoryOrder() async throws {
        let processA = process(1, pid: 20)
        let processB = process(2, pid: 10)
        let processC = process(3, pid: 10)
        let threadA = thread(1, process: processA.key, tid: 7, pid: 20)
        let threadB = thread(2, process: processB.key, tid: 8, pid: 10)
        let threadC = thread(3, process: processC.key, tid: 8, pid: 10)
        let threadWithoutPID = TraceThread(
            key: ThreadKey(itid: 4), processKey: nil, tid: 9, pid: nil,
            name: "unknown", processName: nil,
            startNs: nil, endNs: nil, isMainThread: nil
        )
        let ordered = try await TraceContextBuilder(
            repository: Repository(
                processes: [processA, processC, processB],
                threads: [threadA, threadC, threadB, threadWithoutPID]
            )
        ).build(
            TraceContextRequest(
                time: .range(TraceTimeRange.query(startNs: 0, endNs: 10)),
                maximumEvents: 1, maximumRows: 10,
                maximumOutputBytes: 256 * 1_024
            )
        )
        XCTAssertEqual(ordered.processes.map(\.key.ipid), [2, 3, 1])
        XCTAssertEqual(ordered.threads.map(\.key.itid), [4, 2, 3, 1])
        let orderedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: ordered.encoded(maximumBytes: 256 * 1_024)
            ) as? [String: Any]
        )
        let encodedThreads = try XCTUnwrap(
            orderedObject["threads"] as? [[String: Any]]
        )
        let encodedUnknown = try XCTUnwrap(
            encodedThreads.first { ($0["key"] as? [String: Int64])?["itid"] == 4 }
        )
        for key in [
            "processKey", "pid", "processName", "startNs", "endNs", "isMainThread",
        ] {
            XCTAssertTrue(encodedUnknown[key] is NSNull, "missing explicit null for \(key)")
        }

        let missingProcess = ProcessKey(ipid: 99)
        let missingThread = ThreadKey(itid: 99)
        let missing = try await TraceContextBuilder(
            repository: Repository(
                cpuSlices: [
                    cpuSlice(
                        1, 1, 2, cpu: 0,
                        process: missingProcess, thread: missingThread
                    )
                ],
                hideBroadDirectories: true
            )
        ).build(
            TraceContextRequest(
                time: .range(TraceTimeRange.query(startNs: 0, endNs: 10)),
                maximumEvents: 1, maximumRows: 10,
                maximumOutputBytes: 256 * 1_024
            )
        )
        XCTAssertFalse(missing.truncation.referenceOmittedByBudget)
        XCTAssertTrue(missing.dataQuality.issues.contains {
            $0.category == .referentialIntegrity && $0.count == 2
        })

        let retainedProcess = process(10, pid: 10)
        let laterProcess = process(20, pid: 20)
        let laterThread = thread(20, process: laterProcess.key, tid: 20, pid: 20)
        let processCounter = CounterSeries(
            filterID: 7, name: "first", scope: .process,
            cpu: nil, processKey: retainedProcess.key, pid: 10, unit: nil,
            samples: [
                CounterSample(
                    key: EventKey(table: .measure, rowID: 1),
                    timestampNs: 0, value: 1, durationNs: 0
                )
            ]
        )
        let probePriority = try await TraceContextBuilder(
            repository: Repository(
                processes: [retainedProcess, laterProcess], threads: [laterThread],
                cpuSlices: [
                    cpuSlice(
                        2, 5, 6, cpu: 0,
                        process: laterProcess.key, thread: laterThread.key
                    )
                ],
                counters: [processCounter], hideBroadDirectories: true
            )
        ).build(
            TraceContextRequest(
                time: .range(TraceTimeRange.query(startNs: 0, endNs: 10)),
                maximumEvents: 2, maximumRows: 1,
                maximumOutputBytes: 256 * 1_024
            )
        )
        XCTAssertEqual(probePriority.processes.map(\.key), [retainedProcess.key])
        XCTAssertTrue(probePriority.threads.isEmpty)
        XCTAssertTrue(probePriority.truncation.referenceOmittedByBudget)

        let duplicateProcess = process(30, pid: 30)
        do {
            _ = try await TraceContextBuilder(
                repository: Repository(
                    processes: [
                        duplicateProcess,
                        TraceProcess(
                            key: duplicateProcess.key, pid: 31, name: nil,
                            startNs: nil, endNs: nil, threadCount: nil
                        ),
                    ]
                )
            ).build(
                TraceContextRequest(
                    time: .range(TraceTimeRange.query(startNs: 0, endNs: 10)),
                    maximumEvents: 1, maximumRows: 10,
                    maximumOutputBytes: 256 * 1_024
                )
            )
            XCTFail("duplicate process identity must fail without trapping")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .queryFailed)
            XCTAssertEqual(error.stage, .querying)
        }

        let duplicateThread = thread(30, process: duplicateProcess.key, tid: 30, pid: 30)
        do {
            _ = try await TraceContextBuilder(
                repository: Repository(
                    threads: [
                        duplicateThread,
                        TraceThread(
                            key: duplicateThread.key, processKey: nil, tid: 31,
                            pid: nil, name: nil, processName: nil,
                            startNs: nil, endNs: nil, isMainThread: nil
                        ),
                    ]
                )
            ).build(
                TraceContextRequest(
                    time: .range(TraceTimeRange.query(startNs: 0, endNs: 10)),
                    maximumEvents: 1, maximumRows: 10,
                    maximumOutputBytes: 256 * 1_024
                )
            )
            XCTFail("duplicate thread identity must fail without trapping")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .queryFailed)
            XCTAssertEqual(error.stage, .querying)
        }
    }

    func testContextRetentionUsesOnlyAppliedFiltersAndOpenEndedCounterDuration() async throws {
        let process = process(1, pid: 10)
        let thread = thread(1, process: process.key, tid: 10, pid: 10)
        let cpuPreferred = try await TraceContextBuilder(
            repository: Repository(
                processes: [process], threads: [thread],
                cpuSlices: [
                    cpuSlice(1, 0, 1, cpu: 0, process: process.key, thread: thread.key)
                ],
                slices: [
                    slice(2, 49, 51, thread: thread.key, process: process.key, name: "near")
                ]
            )
        ).build(
            TraceContextRequest(
                time: .timestamp(timestampNs: 50, windowBeforeNs: 50, windowAfterNs: 50),
                filters: TraceAgentQueryFilters(cpu: 0),
                maximumEvents: 1, maximumRows: 10,
                maximumOutputBytes: 256 * 1_024
            )
        )
        XCTAssertEqual(cpuPreferred.cpuSlices.map(\.key.rowID), [1])
        XCTAssertTrue(cpuPreferred.slices.isEmpty)
        let combinedScope = try await TraceContextBuilder(
            repository: Repository(
                processes: [process], threads: [thread],
                cpuSlices: [
                    cpuSlice(1, 0, 1, cpu: 0, process: process.key, thread: thread.key)
                ],
                counters: [counterSeries(process: process.key, pid: 10)]
            )
        ).build(
            TraceContextRequest(
                time: .range(TraceTimeRange.query(startNs: 0, endNs: 100)),
                filters: TraceAgentQueryFilters(cpu: 0, processKey: process.key),
                maximumEvents: 2, maximumRows: 10,
                maximumOutputBytes: 256 * 1_024
            )
        )
        XCTAssertEqual(combinedScope.cpuSlices.map(\.key.rowID), [1])
        XCTAssertTrue(combinedScope.counters.isEmpty)

        let competingDurations = CounterSeries(
            filterID: 1, name: "duration", scope: .process,
            cpu: nil, processKey: process.key, pid: 10, unit: nil,
            samples: [
                CounterSample(
                    key: EventKey(table: .measure, rowID: 10),
                    timestampNs: 0, value: 1, durationNs: nil
                ),
                CounterSample(
                    key: EventKey(table: .measure, rowID: 11),
                    timestampNs: 0, value: 1, durationNs: 0
                )
            ]
        )
        let durationPreferred = try await TraceContextBuilder(
            repository: Repository(
                durationNs: 100, processes: [process], counters: [competingDurations]
            )
        ).build(
            TraceContextRequest(
                time: .timestamp(timestampNs: 50, windowBeforeNs: 50, windowAfterNs: 50),
                maximumEvents: 1, maximumRows: 10,
                maximumOutputBytes: 256 * 1_024
            )
        )
        XCTAssertEqual(
            durationPreferred.counters.flatMap(\.samples).map(\.key.rowID),
            [10]
        )
    }

    func testAgentAnalysisAndContextMapCancellationAndDeadline() async throws {
        let range = try TraceTimeRange.query(startNs: 0, endNs: 10)
        let slow = Repository(metadataDelay: .milliseconds(500))
        let start = ContinuousClock.now

        do {
            _ = try await TraceAgentQueryEngine(repository: slow).query(
                TraceAgentQueryRequest(
                    view: .cpuSlices, range: range, timeout: .milliseconds(100)
                )
            )
            XCTFail("Agent query must honor its deadline")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .queryTimeout)
        }
        XCTAssertLessThan(start.duration(to: ContinuousClock.now), .milliseconds(300))
        do {
            _ = try await TraceAgentQueryEngine(
                repository: Repository(
                    metadataDelay: .milliseconds(500), metadataFails: true,
                    metadataIgnoresCancellation: true
                )
            ).query(
                TraceAgentQueryRequest(
                    view: .cpuSlices, range: range, timeout: .milliseconds(100)
                )
            )
            XCTFail("an ordinary failure after deadline must not mask timeout")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .queryTimeout)
        }
        do {
            _ = try await TraceDeterministicAnalysisEngine(repository: slow).analyze(
                TraceDeterministicAnalysisRequest(range: range, timeout: .milliseconds(100))
            )
            XCTFail("analysis must honor its deadline")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .queryTimeout)
        }
        do {
            _ = try await TraceContextBuilder(repository: slow).build(
                TraceContextRequest(
                    time: .range(range), maximumOutputBytes: 64 * 1_024,
                    timeout: .milliseconds(100)
                )
            )
            XCTFail("context must honor its deadline")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .queryTimeout)
        }

        let cancellationTask = Task {
            try await TraceContextBuilder(
                repository: Repository(metadataDelay: .seconds(1))
            ).build(
                TraceContextRequest(
                    time: .range(range), maximumOutputBytes: 64 * 1_024
                )
            )
        }
        try await Task.sleep(for: .milliseconds(10))
        cancellationTask.cancel()
        do {
            _ = try await cancellationTask.value
            XCTFail("context cancellation must be typed")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .cancelled)
            XCTAssertEqual(error.stage, .analyzing)
        }

        XCTAssertThrowsError(
            try TraceAgentQueryRequest(
                view: .cpuSlices, range: range, timeout: .milliseconds(99)
            )
        )
        XCTAssertThrowsError(
            try TraceDeterministicAnalysisRequest(
                range: range, timeout: .seconds(121)
            )
        )
        XCTAssertThrowsError(
            try TraceContextRequest(
                time: .range(range), timeout: .milliseconds(99)
            )
        )

        let agentCancellation = Task {
            try await TraceAgentQueryEngine(
                repository: Repository(metadataDelay: .seconds(1))
            ).query(TraceAgentQueryRequest(view: .cpuSlices, range: range))
        }
        try await Task.sleep(for: .milliseconds(10))
        agentCancellation.cancel()
        do {
            _ = try await agentCancellation.value
            XCTFail("Agent query cancellation must be typed")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .cancelled)
            XCTAssertEqual(error.stage, .querying)
        }

        let successRaceCancellation = Task {
            try await TraceAgentQueryEngine(
                repository: Repository(
                    metadataDelay: .seconds(1), metadataIgnoresCancellation: true
                )
            ).query(TraceAgentQueryRequest(view: .cpuSlices, range: range))
        }
        try await Task.sleep(for: .milliseconds(10))
        successRaceCancellation.cancel()
        do {
            _ = try await successRaceCancellation.value
            XCTFail("parent cancellation must beat a child success queued during drain")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .cancelled)
            XCTAssertEqual(error.stage, .querying)
        }

        let analysisCancellation = Task {
            try await TraceDeterministicAnalysisEngine(
                repository: Repository(metadataDelay: .seconds(1))
            ).analyze(TraceDeterministicAnalysisRequest(range: range))
        }
        try await Task.sleep(for: .milliseconds(10))
        analysisCancellation.cancel()
        do {
            _ = try await analysisCancellation.value
            XCTFail("analysis cancellation must be typed")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .cancelled)
            XCTAssertEqual(error.stage, .analyzing)
        }
    }

    private func process(_ ipid: Int64, pid: Int64) -> TraceProcess {
        TraceProcess(
            key: ProcessKey(ipid: ipid), pid: pid, name: "p\(ipid)",
            startNs: 0, endNs: 1_000, threadCount: 1
        )
    }

    private func thread(
        _ itid: Int64,
        process: ProcessKey,
        tid: Int64,
        pid: Int64
    ) -> TraceThread {
        TraceThread(
            key: ThreadKey(itid: itid), processKey: process,
            tid: tid, pid: pid, name: "t\(itid)", processName: "p\(process.ipid)",
            startNs: 0, endNs: 1_000, isMainThread: false
        )
    }

    private func cpuSlice(
        _ id: Int64,
        _ start: Int64,
        _ end: Int64,
        cpu: Int64,
        process: ProcessKey,
        thread: ThreadKey,
        pid: Int64? = nil,
        tid: Int64? = nil
    ) -> CpuSlice {
        CpuSlice(
            key: EventKey(table: .schedSlice, rowID: id),
            range: try! TraceTimeRange(startNs: start, endNs: end),
            cpu: cpu, threadKey: thread, processKey: process,
            tid: tid ?? thread.itid + 90, pid: pid ?? process.ipid * 10,
            threadName: "t\(thread.itid)", processName: "p\(process.ipid)",
            endState: nil, priority: nil, isOpenEnded: false
        )
    }

    private func state(
        _ id: Int64,
        _ start: Int64,
        _ end: Int64,
        thread: ThreadKey,
        process: ProcessKey,
        raw: String,
        normalized: TraceThreadState? = nil
    ) -> ThreadStateInterval {
        ThreadStateInterval(
            key: EventKey(table: .threadState, rowID: id),
            range: try! TraceTimeRange(startNs: start, endNs: end),
            threadKey: thread, processKey: process,
            state: raw, normalizedState: normalized,
            cpu: 0, tid: thread.itid + 90, pid: process.ipid * 10,
            processName: "p\(process.ipid)", threadName: "t\(thread.itid)",
            isOpenEnded: false
        )
    }

    private func slice(
        _ id: Int64,
        _ start: Int64,
        _ end: Int64,
        thread: ThreadKey,
        process: ProcessKey,
        name: String
    ) -> TraceSlice {
        TraceSlice(
            key: EventKey(table: .callstack, rowID: id),
            range: try! TraceTimeRange(startNs: start, endNs: end),
            threadKey: thread, processKey: process,
            pid: process.ipid * 10, tid: thread.itid + 90,
            processName: "p\(process.ipid)", threadName: "t\(thread.itid)",
            name: name, category: "work", depth: 0,
            parentEventKey: nil, isAsync: false, isOpenEnded: false
        )
    }

    private func counterSeries(process: ProcessKey, pid: Int64) -> CounterSeries {
        CounterSeries(
            filterID: 5, name: "memory", scope: .process,
            cpu: nil, processKey: process, pid: pid, processName: "p\(process.ipid)",
            unit: "bytes",
            samples: [
                CounterSample(
                    key: EventKey(table: .measure, rowID: 30),
                    timestampNs: 105, value: 1, durationNs: nil
                ),
                CounterSample(
                    key: EventKey(table: .measure, rowID: 31),
                    timestampNs: 125, value: 2, durationNs: 10
                ),
            ]
        )
    }
}
