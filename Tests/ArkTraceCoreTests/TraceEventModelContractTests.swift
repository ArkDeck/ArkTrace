import Foundation
import XCTest

@testable import ArkTraceCore

final class TraceEventModelContractTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    func testCpuSliceCodableGoldenLocksFieldsAndNullability() throws {
        let populated = CpuSlice(
            key: EventKey(table: .schedSlice, rowID: 1),
            range: try TraceTimeRange(startNs: 10, endNs: 20),
            cpu: 2,
            threadKey: ThreadKey(itid: 3),
            processKey: ProcessKey(ipid: 4),
            tid: 5,
            pid: 6,
            threadName: "worker",
            processName: "app",
            endState: "R",
            priority: 7,
            isOpenEnded: false
        )
        let nullable = CpuSlice(
            key: EventKey(table: .schedSlice, rowID: 8),
            range: try TraceTimeRange(startNs: 30, endNs: 30),
            cpu: 0,
            threadKey: nil,
            processKey: nil,
            tid: nil,
            pid: nil,
            threadName: nil,
            processName: nil,
            endState: nil,
            priority: nil,
            isOpenEnded: true
        )

        try assertGolden(
            [populated, nullable],
            #"[{"cpu":2,"endState":"R","isOpenEnded":false,"key":{"rowID":1,"table":"sched_slice"},"pid":6,"priority":7,"processKey":{"ipid":4},"processName":"app","range":{"endNs":20,"startNs":10},"threadKey":{"itid":3},"threadName":"worker","tid":5},{"cpu":0,"endState":null,"isOpenEnded":true,"key":{"rowID":8,"table":"sched_slice"},"pid":null,"priority":null,"processKey":null,"processName":null,"range":{"endNs":30,"startNs":30},"threadKey":null,"threadName":null,"tid":null}]"#
        )
    }

    func testThreadStateCodableGoldenPreservesRawAndNormalizedState() throws {
        let known = ThreadStateInterval(
            key: EventKey(table: .threadState, rowID: 1),
            range: try TraceTimeRange(startNs: 1, endNs: 2),
            threadKey: ThreadKey(itid: 9),
            processKey: ProcessKey(ipid: 8),
            state: "R+",
            normalizedState: .runnable,
            cpu: 3,
            tid: 10,
            pid: 11,
            processName: "app",
            threadName: "worker",
            isOpenEnded: false
        )
        let unknown = ThreadStateInterval(
            key: EventKey(table: .threadState, rowID: 2),
            range: try TraceTimeRange(startNs: 2, endNs: 4),
            threadKey: ThreadKey(itid: 12),
            state: "vendor-state",
            normalizedState: nil,
            cpu: nil,
            tid: nil,
            pid: nil,
            isOpenEnded: true
        )

        try assertGolden(
            [known, unknown],
            #"[{"cpu":3,"isOpenEnded":false,"key":{"rowID":1,"table":"thread_state"},"normalizedState":"runnable","pid":11,"processKey":{"ipid":8},"processName":"app","range":{"endNs":2,"startNs":1},"state":"R+","threadKey":{"itid":9},"threadName":"worker","tid":10},{"cpu":null,"isOpenEnded":true,"key":{"rowID":2,"table":"thread_state"},"normalizedState":null,"pid":null,"processKey":null,"processName":null,"range":{"endNs":4,"startNs":2},"state":"vendor-state","threadKey":{"itid":12},"threadName":null,"tid":null}]"#
        )
    }

    func testTraceSliceCodableGoldenLocksParentAndAsyncFields() throws {
        let populated = TraceSlice(
            key: EventKey(table: .callstack, rowID: 4),
            range: try TraceTimeRange(startNs: 5, endNs: 9),
            threadKey: ThreadKey(itid: 2),
            processKey: ProcessKey(ipid: 3),
            pid: 4,
            tid: 5,
            processName: "app",
            threadName: "worker",
            name: "slice",
            category: "io",
            depth: 6,
            parentEventKey: EventKey(table: .callstack, rowID: 1),
            isAsync: true,
            isOpenEnded: false
        )
        let nullable = TraceSlice(
            key: EventKey(table: .callstack, rowID: 5),
            range: try TraceTimeRange(startNs: 9, endNs: 9),
            threadKey: nil,
            processKey: nil,
            name: "instant",
            category: nil,
            depth: nil,
            parentEventKey: nil,
            isAsync: false,
            isOpenEnded: false
        )

        try assertGolden(
            [populated, nullable],
            #"[{"category":"io","depth":6,"isAsync":true,"isOpenEnded":false,"key":{"rowID":4,"table":"callstack"},"name":"slice","parentEventKey":{"rowID":1,"table":"callstack"},"pid":4,"processKey":{"ipid":3},"processName":"app","range":{"endNs":9,"startNs":5},"threadKey":{"itid":2},"threadName":"worker","tid":5},{"category":null,"depth":null,"isAsync":false,"isOpenEnded":false,"key":{"rowID":5,"table":"callstack"},"name":"instant","parentEventKey":null,"pid":null,"processKey":null,"processName":null,"range":{"endNs":9,"startNs":9},"threadKey":null,"threadName":null,"tid":null}]"#
        )
    }

    func testCounterCodableGoldenLocksScopeUnitAndOptionalDuration() throws {
        let cpu = CounterSeries(
            filterID: 20,
            name: "cycles",
            scope: .cpu,
            cpu: 1,
            processKey: nil,
            unit: "count",
            samples: [
                CounterSample(
                    key: EventKey(table: .measure, rowID: 7),
                    timestampNs: 100,
                    value: 42,
                    durationNs: 5
                )
            ]
        )
        let process = CounterSeries(
            filterID: 21,
            name: "rss",
            scope: .process,
            cpu: nil,
            processKey: ProcessKey(ipid: 8),
            pid: 80,
            processName: "app",
            unit: nil,
            samples: [
                CounterSample(
                    key: EventKey(table: .measure, rowID: 9),
                    timestampNs: 200,
                    value: 64,
                    durationNs: nil
                )
            ]
        )

        try assertGolden(
            [cpu, process],
            #"[{"cpu":1,"filterID":20,"name":"cycles","pid":null,"processKey":null,"processName":null,"samples":[{"durationNs":5,"key":{"rowID":7,"table":"measure"},"timestampNs":100,"value":42}],"scope":"cpu","unit":"count"},{"cpu":null,"filterID":21,"name":"rss","pid":80,"processKey":{"ipid":8},"processName":"app","samples":[{"durationNs":null,"key":{"rowID":9,"table":"measure"},"timestampNs":200,"value":64}],"scope":"process","unit":null}]"#
        )
    }

    private func assertGolden<T: Codable & Equatable>(
        _ value: T,
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try encoder.encode(value)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), expected, file: file, line: line)
        XCTAssertEqual(try JSONDecoder().decode(T.self, from: data), value, file: file, line: line)
    }
}
