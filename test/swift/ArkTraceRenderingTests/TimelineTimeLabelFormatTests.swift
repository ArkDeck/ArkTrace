import ArkTraceCore
import Foundation
import XCTest

@testable import ArkTraceRendering

/// Exercise the formatter through the tooltip the canvas actually displays,
/// rather than recreating a Foundation style in the test.
@MainActor
final class TimelineTimeLabelFormatTests: XCTestCase {
    private func tooltip(durationNs: Int64) throws -> String {
        let key = EventKey(table: .callstack, rowID: 1)
        let range = try TraceTimeRange.query(startNs: 0, endNs: max(1, durationNs))
        let inspector = TraceEventInspector(
            key: key, type: .namedSlice, name: "worker", range: range,
            semanticDurationNs: durationNs, isOpenEnded: false,
            processKey: nil, threadKey: nil, pid: nil, tid: nil, cpu: nil,
            processName: nil, threadName: nil, category: nil, state: nil,
            value: nil, unit: nil
        )
        return try XCTUnwrap(TimelineNSView.tooltipText(for: TimelineDetailPrimitive(
            trackID: TimelineTrackID(rawValue: "named-slice:1"),
            eventKey: key, range: range, label: "worker", inspector: inspector
        )))
    }

    func testProductUnitsAndFractionsMatchLegacyPrintfRendering() throws {
        XCTAssertEqual(try tooltip(durationNs: 0), "worker · 0 ns")
        XCTAssertEqual(try tooltip(durationNs: 999), "worker · 999 ns")
        let samples: [(Int64, Double, String)] = [
            (1_000, 1_000, "µs"), (1_234, 1_000, "µs"),
            (1_000_000, 1_000_000, "ms"), (1_234_500, 1_000_000, "ms"),
            (45_998_941, 1_000_000, "ms"), (999_999_400, 1_000_000, "ms"),
            (1_000_000_000, 1_000_000_000, "s"),
            (3_600_250_000_000, 1_000_000_000, "s"),
            (86_400_000_000_000, 1_000_000_000, "s"),
        ]
        for (nanoseconds, divisor, unit) in samples {
            let legacy = String(format: "%.3f", Double(nanoseconds) / divisor)
            XCTAssertEqual(try tooltip(durationNs: nanoseconds), "worker · \(legacy) \(unit)")
        }
    }

    func testNoGroupingSeparatorForLargeSecondValues() throws {
        XCTAssertEqual(try tooltip(durationNs: 3_600_000_000_000), "worker · 3600.000 s")
        XCTAssertEqual(try tooltip(durationNs: 1_234_567_891_000_000), "worker · 1234567.891 s")
    }

    func testProductTooltipUsesPosixDecimalPoint() throws {
        let text = try tooltip(durationNs: 1_500_000)
        XCTAssertFalse(text.contains(","))
        XCTAssertEqual(text, "worker · 1.500 ms")
    }
}
