import Foundation
import XCTest
@testable import ArkTraceRustRuntime

@MainActor
final class JSONShapeTests: XCTestCase {
    private func check(_ raw: String, rejection: RustAdmission? = nil) {
        let pool = RustRetainedStorage(maximumBytes: 1024 * 1024, maximumOwners: 4)
        do {
            try RustJSONShape.validate(Data(raw.utf8), staging: pool)
            XCTAssertNil(rejection, "malformed JSON was admitted")
        } catch { XCTAssertEqual(error as? RustAdmission, rejection) }
        XCTAssertEqual(pool.retainedBytes, 0); XCTAssertEqual(pool.retainedOwners, 0)
    }
    func testValidJSONGrammarEscapesNumbersAndNestedContainers() {
        check(#" {"a": [true,false,null,-1.25e+2,0,1E-2,{"b":"quote\"slash\\unicode\u0061"}],"\u0063":{}} "#)
    }
    func testDuplicateDecodedKeysAtEachDepthReject() {
        for raw in [#"{"a":1,"a":2}"#, #"{"a":[{"b":1,"\u0062":2}]}"#, #"{"a":{"b":{"c":1,"c":2}}}"#] {
            check(raw, rejection: .invalidBuffer)
        }
    }
    func testMalformedTokensTrailingBytesAndTruncatedContainersReject() {
        for raw in ["", "{}true", "[01]", "[-]", "[1.]", "[1e+]", "[tru]", "[1,]", "{\"a\":1,}", "[", #"["bad\q"]"#, #"["bad\u00xz"]"#, "{\"a\":\"line\n\"}"] {
            check(raw, rejection: .invalidBuffer)
        }
    }
    func testDepthKeyMemberAndNumberAdmissionCapsRejectWithRefund() {
        check(String(repeating: "[", count: 34) + "0" + String(repeating: "]", count: 34), rejection: .outputLimit)
        check("{\"" + String(repeating: "x", count: 256) + "\":0}", rejection: .outputLimit)
        check("{" + (0..<33).map { "\"k\($0)\":0" }.joined(separator: ",") + "}", rejection: .outputLimit)
        check("[" + String(repeating: "1", count: 129) + "]", rejection: .outputLimit)
    }
}
