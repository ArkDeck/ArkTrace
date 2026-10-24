import ArkTraceCore
import Foundation
import XCTest

@testable import ArkTraceAppSupport

final class SelectedEventArgumentLookupTests: XCTestCase {
    private func event(_ start: Int64, _ end: Int64) throws -> TraceEventInspector {
        TraceEventInspector(key: EventKey(table: .callstack, rowID: 7), type: .namedSlice,
            name: nil, range: try TraceTimeRange(startNs: start, endNs: end),
            semanticDurationNs: end - start, isOpenEnded: false,
            processKey: nil, threadKey: ThreadKey(itid: -3), pid: nil, tid: nil,
            cpu: nil, processName: nil, threadName: nil, category: nil,
            state: nil, value: nil, unit: nil)
    }

    func testMaximumInstantDoesNotOverflowOrInventAQueryWindow() throws {
        XCTAssertThrowsError(try SelectedEventArgumentLookup(event: event(.max, .max),
            deadline: .now.advanced(by: .seconds(5)))) {
            XCTAssertEqual($0 as? SelectedEventArgumentLookup.Unqueryable, .noRepresentableUpperBound)
        }
    }

    func testRepresentableInstantWindowsAndMaximumEndPreserveSemantics() throws {
        for (start, end, expectedEnd) in [(Int64(0), Int64(0), Int64(1)),
                                        (Int64.max - 1, Int64.max - 1, Int64.max),
                                        (Int64.max - 2, Int64.max, Int64.max)] {
            let lookup = try SelectedEventArgumentLookup(event: event(start, end),
                deadline: .now.advanced(by: .seconds(5)))
            XCTAssertEqual(lookup.sliceQuery.range,
                try TraceTimeRange.query(startNs: start, endNs: expectedEnd))
            XCTAssertTrue(lookup.sliceQuery.range.intersects(query: lookup.sliceQuery.range))
        }
    }
}
