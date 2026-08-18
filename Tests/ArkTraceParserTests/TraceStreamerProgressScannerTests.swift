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

    /// Everything else on the stream is not a progress record, and the tail
    /// that never terminates must not become an unbounded buffer fed by a
    /// subprocess.
    func testNonRecordsAreIgnoredAndTheHeldTailIsBounded() {
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
}
