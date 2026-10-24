import ArkTraceCore
import ArkTraceRendering
import XCTest

final class TimelineAnnotationExtremaTests: XCTestCase {
    func testMaximumFlagRevealBorrowsLastNanosecondWithoutMovingToZero() throws {
        let flag = TimelineFlag(id: .max, timestampNs: .max, label: "end", colorIndex: .max)
        XCTAssertEqual(flag.pointRange, try TraceTimeRange.query(startNs: .max - 1, endNs: .max))
        XCTAssertEqual(flag.timestampNs, .max)
        XCTAssertEqual(TimelineFlag(id: .min, timestampNs: .min, label: "negative", colorIndex: .min).pointRange,
            try TraceTimeRange.query(startNs: 0, endNs: 1))
    }
    func testColorCycleKeepsOrdinaryIndicesAndAdvancesMaximumPaletteColor() {
        XCTAssertEqual(TimelineAnnotationColor.nextIndex(after: .max), 2)
        XCTAssertEqual(TimelineAnnotationColor.nextIndex(after: .min), .min + 1)
        XCTAssertEqual(TimelineAnnotationColor.nextIndex(after: 6), 7)
    }
}
