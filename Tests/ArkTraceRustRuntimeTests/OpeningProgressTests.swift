import ArkTraceCore
import XCTest
@testable import ArkTraceRustRuntime

final class OpeningProgressTests: XCTestCase {
    func testCoarseOpeningCodesKeepUnavailableFractionsAbsent() throws {
        XCTAssertNil(try RustOpeningProgress.decode(0))
        let expected: [TraceLoadingStage] = [.hashing, .preparing, .parsing, .indexing, .validating, .preparing, .preparing, .ready]
        for (index, stage) in expected.enumerated() {
            let progress = try XCTUnwrap(RustOpeningProgress.decode(UInt32(index + 1)))
            XCTAssertEqual(progress.stage, stage)
            XCTAssertNil(progress.fraction)
        }
    }
    func testUnknownProgressIsRejectedInsteadOfShowingAFalseStage() {
        XCTAssertThrowsError(try RustOpeningProgress.decode(9)) { XCTAssertEqual($0 as? RustAdmission, .invalidBuffer) }
        XCTAssertThrowsError(try RustOpeningProgress.decode(UInt32.max)) { XCTAssertEqual($0 as? RustAdmission, .invalidBuffer) }
    }
}
