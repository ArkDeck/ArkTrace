import ArkTraceCore
@testable import ArkTraceParser
import XCTest

/// The pinned parser reports its own read position; these lock the reading of
/// it, because the progress bar over a minute-long open is only as honest as
/// this scanner.
final class TraceStreamerProgressScannerTests: XCTestCase {
    /// The exact framing the pinned 4.3.7 binary emits: a carriage return on
    /// both sides, a tab after the colon, decimal megabytes.
    func testReadsTheRecordsThePinnedParserActuallyWrites() {
        var scanner = TraceStreamerProgressScanner()
        XCTAssertEqual(scanner.consume("\rLoadingFile:\t1.05 MB\r"), 1_050_000)
        XCTAssertEqual(
            scanner.consume("\rLoadingFile:\t2.10 MB\r\rLoadingFile:\t3.15 MB\r"),
            3_150_000,
            "a chunk carrying several records yields the newest"
        )
        XCTAssertEqual(
            scanner.consume("\rLoadingFile:\t265.03 MB\r"), 265_030_000,
            "the reference capture's final record is its own byte count"
        )
    }

    /// A pipe hands over whatever has arrived, which splits records anywhere.
    func testARecordSplitAcrossChunksIsStillRead() {
        var scanner = TraceStreamerProgressScanner()
        XCTAssertNil(scanner.consume("\rLoadingFi"))
        XCTAssertNil(scanner.consume("le:\t12."), "still no delimiter, still nothing")
        XCTAssertEqual(scanner.consume("58 MB\r"), 12_580_000)
    }

    /// Everything else the parser writes to stdout is not a progress record.
    func testNonRecordsAreIgnored() {
        var scanner = TraceStreamerProgressScanner()
        XCTAssertNil(scanner.consume("ParserDuration:\t1536 ms\r"))
        XCTAssertNil(scanner.consume("LoadingFile:\tnonsense MB\r"))
        XCTAssertNil(
            scanner.consume(String(repeating: "x", count: 8_192)),
            "no delimiter, no record"
        )
        XCTAssertEqual(
            scanner.consume("\rLoadingFile:\t7.00 MB\r"), 7_000_000,
            "and the scanner still reads the next real record"
        )
    }

    /// A child that never emits a delimiter must not be able to grow the held
    /// tail without limit. The drop is only observable through what happens to
    /// a record straddling the limit, so pin it from both sides: at the limit
    /// the split record still completes, one byte past it the tail is gone and
    /// the same record cannot.
    func testAnUnterminatedTailIsDroppedOnceItPassesTheResidualLimit() {
        let head = "LoadingFile:\t7.00"
        let padding = TraceStreamerProgressScanner.residualLimit - head.utf8.count

        var atLimit = TraceStreamerProgressScanner()
        XCTAssertNil(atLimit.consume(String(repeating: "x", count: padding) + head))
        XCTAssertEqual(
            atLimit.consume(" MB\r"), 7_000_000,
            "a tail exactly at the limit is still held, so the record completes"
        )

        var pastLimit = TraceStreamerProgressScanner()
        XCTAssertNil(pastLimit.consume(String(repeating: "x", count: padding + 1) + head))
        XCTAssertNil(
            pastLimit.consume(" MB\r"),
            "one byte past the limit the tail is dropped, so nothing completes"
        )
        XCTAssertEqual(
            pastLimit.consume("\rLoadingFile:\t9.00 MB\r"), 9_000_000,
            "dropping the tail must not wedge the scanner"
        )
    }
}
