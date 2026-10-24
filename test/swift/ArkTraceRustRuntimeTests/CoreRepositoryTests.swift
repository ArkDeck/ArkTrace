import ArkTraceCore
import Foundation
import XCTest
@testable import ArkTraceRustRuntime

@MainActor final class CoreRepositoryTests: XCTestCase {
    private func cpuCatalogEnvelope(cpus: [Int64] = [.min, 0, .max]) throws -> Data {
        let quality: [String: Any] = ["status": "ok", "warnings": []]
        return try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "session": 2, "request": 3,
            "body": ["cpus": ["items": cpus.map { ["cpu": $0] }, "truncated": false,
                "capabilityAvailable": true, "dataQuality": quality],
                "activity": ["items": [["processKey": ["ipid": Int64.min]], ["processKey": NSNull()]],
                    "truncated": true, "capabilityAvailable": true, "dataQuality": quality]]])
    }

    func testCPUCatalogPreservesSignedIDsNullableOwnersAndIndependentCoverage() async throws {
        let query = try TraceCPUCatalogQuery(range: .query(startNs: 0, endNs: 1), limit: 3, activityLimit: 2,
            deadline: .now.advanced(by: .seconds(10)))
        let result = try await RustCPUCatalogDecoder.decode(cpuCatalogEnvelope(),
            identity: RustSessionIdentity(engine: 1, session: 2), request: 3, query: query)
        XCTAssertEqual(result.cpus.items.map(\.cpu), [.min, 0, .max])
        XCTAssertFalse(result.cpus.truncated)
        XCTAssertTrue(result.activity.truncated)
        XCTAssertEqual(result.activity.items.map(\.processKey), [ProcessKey(ipid: .min), nil])
    }

    func testCPUCatalogRejectsIdentityOrderBoundsAndWrongProvenance() async throws {
        let query = try TraceCPUCatalogQuery(range: .query(startNs: 0, endNs: 1), limit: 3, activityLimit: 2,
            deadline: .now.advanced(by: .seconds(10)))
        for ids: [Int64] in [[0, 0], [1, 0], [-1, 0, 1, 2]] {
            do {
                _ = try await RustCPUCatalogDecoder.decode(cpuCatalogEnvelope(cpus: ids),
                    identity: RustSessionIdentity(engine: 1, session: 2), request: 3, query: query)
                XCTFail("invalid identity directory was admitted")
            } catch is RustAdmission {}
        }
        do {
            _ = try await RustCPUCatalogDecoder.decode(cpuCatalogEnvelope(),
                identity: RustSessionIdentity(engine: 1, session: 4), request: 3, query: query)
            XCTFail("foreign Session result was admitted")
        } catch is RustAdmission {}
    }

    func testCPUCatalogRejectsFloatingIdentityUnknownFieldsAndZeroOwners() async throws {
        let query = try TraceCPUCatalogQuery(range: .query(startNs: 0, endNs: 1), limit: 3, activityLimit: 2,
            deadline: .now.advanced(by: .seconds(10)))
        let base = try JSONSerialization.jsonObject(with: cpuCatalogEnvelope()) as! [String: Any]
        for mutation in 0..<3 {
            var root = base, body = base["body"] as! [String: Any]
            if mutation == 0 {
                var page = body["cpus"] as! [String: Any]; page["items"] = [["cpu": 1.5]]; body["cpus"] = page
            } else if mutation == 1 {
                body["rawSQL"] = "SELECT 1"
            } else {
                var page = body["activity"] as! [String: Any]; page["items"] = [["processKey": ["ipid": 0]]]; body["activity"] = page
            }
            root["body"] = body
            do {
                _ = try await RustCPUCatalogDecoder.decode(JSONSerialization.data(withJSONObject: root),
                    identity: RustSessionIdentity(engine: 1, session: 2), request: 3, query: query)
                XCTFail("malformed CPU catalog was admitted")
            } catch is RustAdmission {}
        }
    }

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
