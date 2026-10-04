import ArkTraceCore
import Darwin
import Foundation
import XCTest
@testable import ArkTraceRustRuntime

@MainActor final class BatchDeadlineTests: XCTestCase {
    func testSystemEpochConversionKeepsSignedExtremesAndSubnanoseconds() throws {
        let epoch = ContinuousClock().systemEpoch
        for parts: (Int64, Int64) in [(0, 0), (0, 1), (0, -1), (1, 999_999_999_999_999_999),
            (-1, -999_999_999_999_999_999), (.max, 0), (.min, 0)] {
            let instant = epoch.advanced(by: Duration(secondsComponent: parts.0, attosecondsComponent: parts.1))
            let wire = RustWireContinuousDeadline(instant)
            XCTAssertEqual(wire.seconds, parts.0); XCTAssertEqual(wire.attoseconds, parts.1)
        }
    }

    func testInstalledSwiftClockEpochMatchesNativeContinuousClockRead() throws {
        let epoch = ContinuousClock().systemEpoch
        for _ in 0..<128 {
            var before = timespec(), after = timespec()
            let a = unsafe clock_gettime(CLOCK_MONOTONIC_RAW, &before)
            let parts = epoch.duration(to: .now).components
            let b = unsafe clock_gettime(CLOCK_MONOTONIC_RAW, &after)
            XCTAssertEqual(a, 0); XCTAssertEqual(b, 0)
            let first = (Int64(before.tv_sec), Int64(before.tv_nsec) * 1_000_000_000)
            let current = (parts.seconds, parts.attoseconds)
            let last = (Int64(after.tv_sec), Int64(after.tv_nsec) * 1_000_000_000)
            XCTAssertTrue(first <= current && current <= last)
        }
    }

    func testAbsoluteWirePartsDoNotChangeAcrossHostEncodingDelay() async throws {
        let epoch = ContinuousClock().systemEpoch
        let instants = [epoch.advanced(by: .nanoseconds(1)), .now.advanced(by: .seconds(60))]
        let query = RustBatchQuery(threads: [RustThreadQuery(limit: 1), RustThreadQuery(limit: 2), RustThreadQuery(limit: 3)])
        let deadlines = RustBatchDeadlines(threads: [instants[0], nil, instants[1]])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(RustWireBatchDeadlines(deadlines, query: query))
        await Task.yield()
        let after = try encoder.encode(RustWireBatchDeadlines(deadlines, query: query))
        XCTAssertEqual(before, after)
        let object = try JSONSerialization.jsonObject(with: before) as! [String: Any]
        XCTAssertEqual(object["clock"] as? String, "hostContinuousEpochV1")
        let values = object["threads"] as! [Any]
        XCTAssertTrue(values[1] is NSNull)
        XCTAssertEqual((values[0] as! [String: Int64])["attoseconds"], 1_000_000_000)
    }

    func testDeadlineArraysMustPairWithEveryFamilyAndKeepThirtyTwoSlots() throws {
        let deadline = ContinuousClock.now
        for count in [1, 32] {
            let query = RustBatchQuery(threads: Array(repeating: RustThreadQuery(limit: 1), count: count))
            _ = try RustWireBatchDeadlines(RustBatchDeadlines(threads: Array(repeating: nil, count: count)), query: query)
            XCTAssertThrowsError(try RustWireBatchDeadlines(RustBatchDeadlines(threads: Array(repeating: deadline, count: count - 1)), query: query))
            XCTAssertThrowsError(try RustWireBatchDeadlines(RustBatchDeadlines(cpuSlices: [deadline], threads: Array(repeating: nil, count: count)), query: query))
        }
        for count in [0, 33] {
            XCTAssertThrowsError(try RustWireBatchDeadlines(RustBatchDeadlines(threads: Array(repeating: nil, count: count)),
                query: RustBatchQuery(threads: Array(repeating: RustThreadQuery(limit: 1), count: count))))
        }
    }

    func testCoreBatchMappingPreservesFiltersLimitsAndOriginalDeadlineSlots() throws {
        let range = try TraceTimeRange.query(startNs: 1, endNs: .max)
        let epoch = ContinuousClock().systemEpoch
        let deadlines = (0..<8).map { epoch.advanced(by: .nanoseconds(Int64($0))) }
        let process = ProcessKey(ipid: .min), thread = ThreadKey(itid: .max)
        let batch = try TraceRepositoryEventBatch(cpuSlices: [CpuSliceQuery(range: range, cpu: .min,
            processKey: process, pid: .max, threadKey: thread, tid: .min, limit: 1, deadline: deadlines[0])],
            threadStates: [ThreadStateQuery(range: range, cpu: .max, processKey: process, pid: .min,
                threadKey: thread, tid: .max, rawState: "e\u{301}😀", state: .running, limit: 2, deadline: deadlines[1])],
            slices: [TraceSliceQuery(range: range, processKey: process, pid: .max, threadKey: thread, tid: .min,
                name: .prefix("e\u{301}😀"), minimumDurationNs: 0, depth: .max, includesArgumentSet: true, limit: 3, deadline: deadlines[2])],
            counters: [CounterQuery(range: range, scope: .process, filterID: .min, processKey: process, pid: .max,
                name: .contains("e\u{301}😀"), limit: 4, deadline: deadlines[3])],
            counterSeries: [CounterSeriesQuery(range: range, deadline: deadlines[4])],
            densities: [TraceDensityQuery(range: range, source: .processCounter(filterID: .min, processKey: process), bucketCount: 7, deadline: deadlines[5])],
            threads: [ThreadQuery(processKey: process, pid: .max, threadKey: thread, tid: .min,
                name: "e\u{301}😀", nameMatch: .prefix, limit: 8, deadline: deadlines[6]), ThreadQuery(limit: 9, deadline: nil)])
        let mapped = RustCoreBatchQuery(batch)
        XCTAssertEqual(mapped.query.cpuSlices[0].processKey, .min); XCTAssertEqual(mapped.query.cpuSlices[0].tid, .min)
        XCTAssertEqual(mapped.query.threadStates[0].threadKey, .max); XCTAssertEqual(mapped.query.threadStates[0].rawState, "e\u{301}😀")
        XCTAssertEqual(mapped.query.slices[0].nameMatch, .prefix); XCTAssertTrue(mapped.query.slices[0].includesArgumentSet)
        XCTAssertEqual(mapped.query.slices[0].minimumDurationNs, 0); XCTAssertEqual(mapped.query.slices[0].depth, .max)
        XCTAssertEqual(mapped.query.counters[0].scope, .process); XCTAssertEqual(mapped.query.counters[0].nameMatch, .contains)
        XCTAssertEqual(mapped.query.counterSeries[0].limit, 1_000)
        XCTAssertEqual(mapped.query.densities[0].bucketCount, 7); XCTAssertEqual(mapped.query.threads[0].nameMatch, .prefix)
        XCTAssertEqual(mapped.query.threads[1].limit, 9)
        let wire = try RustWireBatchDeadlines(mapped.deadlines, query: mapped.query)
        XCTAssertEqual([wire.cpuSlices[0], wire.threadStates[0], wire.slices[0], wire.counters[0], wire.counterSeries[0],
            wire.densities[0], wire.threads[0]!].map(\.attoseconds), (0..<7).map { Int64($0) * 1_000_000_000 })
        XCTAssertNil(wire.threads[1])
    }
}
