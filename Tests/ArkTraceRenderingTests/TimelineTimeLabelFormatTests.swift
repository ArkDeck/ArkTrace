import Foundation
import XCTest

@testable import ArkTraceRendering

/// The canvas time labels migrated from `String(format: "%.3f")` to a shared
/// `FloatingPointFormatStyle`. These tests pin the migration contract: POSIX
/// decimal point, exactly three fraction digits, and no grouping separator,
/// regardless of the user's locale.
final class TimelineTimeLabelFormatTests: XCTestCase {
    private let style = FloatingPointFormatStyle<Double>(
        locale: Locale(identifier: "en_US_POSIX")
    )
    .precision(.fractionLength(3))
    .grouping(.never)

    func testStyleMatchesLegacyPrintfRendering() {
        let samples: [Double] = [
            0.001, 0.5, 1.0, 1.2345, 45.998941664, 999.9994, 3_600.25, 86_400.0,
        ]
        for value in samples {
            XCTAssertEqual(
                style.format(value),
                String(format: "%.3f", value),
                "FormatStyle output drifted from the fixed %.3f contract for \(value)"
            )
        }
    }

    func testNoGroupingSeparatorForLargeSecondValues() {
        XCTAssertEqual(style.format(3_600.0), "3600.000")
        XCTAssertEqual(style.format(1_234_567.891), "1234567.891")
    }

    func testPosixDecimalPointIsLocaleIndependent() {
        // The style pins en_US_POSIX explicitly, so a German-locale process
        // must not switch the canvas labels to a decimal comma.
        XCTAssertFalse(style.format(1.5).contains(","))
        XCTAssertEqual(style.format(1.5), "1.500")
    }
}
