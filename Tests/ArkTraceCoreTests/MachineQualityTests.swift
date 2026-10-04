import ArkTraceCore
import Foundation
import XCTest

final class MachineQualityTests: XCTestCase {
    func testMachineFactsStripProsePreserveOrderMultiplicityNullsAndRoundTrip() throws {
        let first = TraceDataQualityIssue(category: .invalidValue, scope: "process.name", count: .max, message: "/private/user/prose")
        let nils = TraceDataQualityIssue(category: .unavailableValue)
        let quality = try TraceDataQuality(machineIssues: [first, nils, first])
        XCTAssertEqual(quality.status, .warnings); XCTAssertEqual(quality.warnings, [])
        XCTAssertEqual(quality.issues.map(\.category), [.invalidValue, .unavailableValue, .invalidValue])
        XCTAssertEqual(quality.issues[0].count, .max); XCTAssertNil(quality.issues[1].scope); XCTAssertNil(quality.issues[1].count)
        XCTAssertTrue(quality.issues.allSatisfy { $0.message == nil })
        let encoded = try JSONEncoder().encode(quality)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("/private/user/prose"))
        XCTAssertEqual(try JSONDecoder().decode(TraceDataQuality.self, from: encoded), quality)
        XCTAssertEqual(try TraceDataQuality(machineIssues: []).status, .ok)
    }

    func testInvalidMachineVocabularyOrNegativeCountIsRejectedWithoutLeakingInput() throws {
        for issue in [TraceDataQualityIssue(category: .unclassified),
                      TraceDataQualityIssue(category: .invalidValue, scope: "/private/user/scope"),
                      TraceDataQualityIssue(category: .invalidValue, count: -1)] {
            XCTAssertThrowsError(try TraceDataQuality(machineIssues: [issue])) { error in
                XCTAssertEqual((error as? ArkTraceError)?.code, .invalidArgument)
                XCTAssertEqual((error as? ArkTraceError)?.stage, .request)
                XCTAssertFalse(String(describing: error).contains("/private/user/scope"))
            }
        }
    }

    func testStoredStructuredEvidenceIsNotDeduplicatedWhenMergingLegacyProse() throws {
        let raw = #"{"status":"warnings","warnings":["represented","legacy","legacy"],"issues":[{"category":"invalidValue","scope":"process.name","count":1,"message":"represented"},{"category":"invalidValue","scope":"process.name","count":1,"message":"represented"}]}"#
        let quality = try JSONDecoder().decode(TraceDataQuality.self, from: Data(raw.utf8))
        XCTAssertEqual(quality.issues.count, 3)
        XCTAssertEqual(quality.issues[0], quality.issues[1])
        XCTAssertEqual(quality.issues[2].category, .unclassified)
        XCTAssertEqual(quality.warnings, ["represented", "legacy"])
        XCTAssertEqual(try JSONDecoder().decode(TraceDataQuality.self, from: JSONEncoder().encode(quality)), quality)
        // Existing explicit legacy construction still performs its documented merge.
        XCTAssertEqual(TraceDataQuality(issues: [quality.issues[0], quality.issues[0]]).issues.count, 1)
    }

    func testSummaryExplicitQualityKeepsMachineEvidenceAndExistingConstructorKeepsLegacyMerge() throws {
        let issue = TraceDataQualityIssue(category: .invalidValue, scope: "process.lifecycle", count: 1)
        let quality = try TraceDataQuality(machineIssues: [issue, issue])
        let facts = TraceSummaryFacts(cpuCount: nil, processCount: TraceBoundedCount(value: 0, truncated: true),
            threadCount: TraceBoundedCount(value: 0, truncated: false), cpuSliceCount: nil, threadStateCount: nil,
            namedSliceCount: nil, counterSeriesCount: nil, eventCountBySource: nil, dataQuality: quality)
        XCTAssertEqual(facts.qualityIssues, [issue, issue]); XCTAssertEqual(facts.warnings, [])
        XCTAssertEqual(try JSONDecoder().decode(TraceSummaryFacts.self, from: JSONEncoder().encode(facts)), facts)
        let legacy = TraceSummaryFacts(cpuCount: nil, processCount: facts.processCount, threadCount: facts.threadCount,
            cpuSliceCount: nil, threadStateCount: nil, namedSliceCount: nil, counterSeriesCount: nil, eventCountBySource: nil,
            qualityIssues: [issue, issue])
        XCTAssertEqual(legacy.qualityIssues, [issue])
    }
}
