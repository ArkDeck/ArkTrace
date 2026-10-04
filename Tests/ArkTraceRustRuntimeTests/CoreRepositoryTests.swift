import ArkTraceCore
import Foundation
import XCTest
@testable import ArkTraceRustRuntime

@MainActor final class CoreRepositoryTests: XCTestCase {
    func testScalarDirectoryNilIsExplicitAndPreservesEveryFilter() throws {
        let query = RustProcessQuery(processKey: .min, pid: .max, name: "e\u{301}😀", nameMatch: .contains, limit: 100_000)
        let data = try JSONEncoder().encode(RustRequest.queryWithDeadline(RustWireDeadlineQuery(.processes(query), deadline: nil)))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["operation"] as? String, "queryWithDeadline")
        let policy = object["query"] as! [String: Any]
        XCTAssertTrue(policy["deadline"] is NSNull)
        XCTAssertEqual(policy["clock"] as? String, "hostContinuousEpochV1")
        let inner = policy["query"] as! [String: Any], filters = inner["query"] as! [String: Any]
        XCTAssertEqual(inner["operation"] as? String, "processes")
        XCTAssertEqual(filters["processKey"] as? Int64, .min); XCTAssertEqual(filters["pid"] as? Int64, .max)
        XCTAssertEqual(filters["name"] as? String, "e\u{301}😀"); XCTAssertEqual(filters["nameMatch"] as? String, "contains")
        XCTAssertEqual(filters["limit"] as? Int, 100_000)
    }
    func testScalarEpochAndFourTypedOperationsRemainExact() throws {
        let range = try TraceTimeRange.query(startNs: 1, endNs: .max)
        let instant = ContinuousClock().systemEpoch.advanced(by: Duration(secondsComponent: .min, attosecondsComponent: -1))
        let cases: [(String, RustRequest)] = [("processes", .processes(RustProcessQuery())),
            ("summaryFacts", .summaryFacts(RustSummaryQuery(range: range, maximumRowsPerSection: 1, maximumEventsPerSection: 1_000_000))),
            ("frames", .frames(RustFrameQuery(range: range, processKey: .min, limit: 20_000))),
            ("arguments", .arguments(RustArgumentQuery(argSetID: .min, limit: 64)))]
        for (name, query) in cases {
            let data = try JSONEncoder().encode(RustWireDeadlineQuery(query, deadline: instant))
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let epoch = object["deadline"] as! [String: Int64]
            XCTAssertEqual(epoch["seconds"], .min); XCTAssertEqual(epoch["attoseconds"], -1)
            XCTAssertEqual((object["query"] as! [String: Any])["operation"] as? String, name)
        }
    }
    func testAllAdmissionMappingsMeetTypedPublicErrorPolicy() throws {
        for raw in UInt32(1)...13 {
            let error = RustTraceRepository.admissionError(RustAdmission(rawValue: raw)!)
            XCTAssertNil(error.publicContractViolation)
            XCTAssertFalse(error.message.contains("/"))
        }
        XCTAssertEqual(RustTraceRepository.admissionError(.capacity).code, .queryLimitExceeded)
        XCTAssertTrue(RustTraceRepository.admissionError(.cancelled).retryable)
        XCTAssertEqual(RustTraceRepository.admissionError(.outputLimit).code, .outputLimitExceeded)
        XCTAssertEqual(RustTraceRepository.admissionError(.invalidInput).stage, .request)
        XCTAssertEqual(RustTraceRepository.admissionError(.closed).code, .queryFailed)
    }
}
