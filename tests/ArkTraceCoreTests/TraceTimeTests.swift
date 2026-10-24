import XCTest

@testable import ArkTraceCore

final class TraceTimeTests: XCTestCase {
    func testEventRangeValidation() throws {
        XCTAssertNoThrow(try TraceTimeRange(startNs: 0, endNs: 10))
        XCTAssertNoThrow(try TraceTimeRange(startNs: 5, endNs: 5), "instant events are valid")
        XCTAssertThrowsError(try TraceTimeRange(startNs: -1, endNs: 10))
        XCTAssertThrowsError(try TraceTimeRange(startNs: 10, endNs: 5))
    }

    func testQueryRangeRejectsDegenerate() throws {
        XCTAssertNoThrow(try TraceTimeRange.query(startNs: 0, endNs: 1))
        XCTAssertThrowsError(try TraceTimeRange.query(startNs: 5, endNs: 5)) { error in
            guard let error = error as? ArkTraceError else { return XCTFail("wrong error type") }
            XCTAssertEqual(error.code, .invalidArgument)
        }
    }

    // AT-TIME-004 / AC-AT-006: half-open intersection, touching boundaries do
    // not intersect.
    func testHalfOpenIntersection() throws {
        let query = try TraceTimeRange.query(startNs: 100, endNs: 200)

        XCTAssertTrue(try TraceTimeRange(startNs: 150, endNs: 160).intersects(query: query))
        XCTAssertTrue(try TraceTimeRange(startNs: 50, endNs: 101).intersects(query: query))
        XCTAssertTrue(try TraceTimeRange(startNs: 199, endNs: 300).intersects(query: query))
        XCTAssertFalse(
            try TraceTimeRange(startNs: 50, endNs: 100).intersects(query: query),
            "event ending exactly at query start does not intersect")
        XCTAssertFalse(
            try TraceTimeRange(startNs: 200, endNs: 300).intersects(query: query),
            "event starting exactly at query end does not intersect")
    }

    // AT-TIME-006 / AC-AT-017: instant events.
    func testInstantIntersection() throws {
        let query = try TraceTimeRange.query(startNs: 100, endNs: 200)

        XCTAssertTrue(try TraceTimeRange(startNs: 100, endNs: 100).intersects(query: query))
        XCTAssertTrue(try TraceTimeRange(startNs: 150, endNs: 150).intersects(query: query))
        XCTAssertFalse(
            try TraceTimeRange(startNs: 200, endNs: 200).intersects(query: query),
            "instant at query end is excluded by the half-open rule")
        XCTAssertFalse(try TraceTimeRange(startNs: 99, endNs: 99).intersects(query: query))
    }

    func testInstantContributesZeroOverlap() throws {
        let range = try TraceTimeRange.query(startNs: 0, endNs: 1000)
        let instant = try TraceTimeRange(startNs: 500, endNs: 500)
        XCTAssertTrue(instant.isInstant)
        XCTAssertEqual(instant.clippedOverlapNs(with: range), 0)
    }

    func testClippedOverlap() throws {
        let range = try TraceTimeRange.query(startNs: 100, endNs: 200)
        XCTAssertEqual(try TraceTimeRange(startNs: 0, endNs: 300).clippedOverlapNs(with: range), 100)
        XCTAssertEqual(try TraceTimeRange(startNs: 150, endNs: 300).clippedOverlapNs(with: range), 50)
        XCTAssertEqual(try TraceTimeRange(startNs: 0, endNs: 50).clippedOverlapNs(with: range), 0)
    }

    func testErrorCodeRawValuesAreStable() {
        XCTAssertEqual(ArkTraceError.Code.traceParseFailed.rawValue, "TRACE_PARSE_FAILED")
        XCTAssertEqual(ArkTraceError.Code.traceSchemaUnsupported.rawValue, "TRACE_SCHEMA_UNSUPPORTED")
        XCTAssertEqual(ArkTraceError.Code.queryLimitExceeded.rawValue, "QUERY_LIMIT_EXCEEDED")
        XCTAssertEqual(ArkTraceError.Code.cancelled.rawValue, "CANCELLED")
    }

    func testTypedDataQualityPreservesLegacyWarningsWithoutDuplicatingMessages() throws {
        let issue = TraceDataQualityIssue(
            category: .clampedValue,
            scope: "process.start_ts",
            count: 2,
            message: "two values clamped"
        )
        let quality = TraceDataQuality(
            warnings: ["two values clamped", "legacy warning"],
            issues: [issue]
        )
        XCTAssertEqual(quality.status, .warnings)
        XCTAssertEqual(quality.warnings, ["two values clamped", "legacy warning"])
        XCTAssertEqual(quality.issues, [
            issue,
            TraceDataQualityIssue(category: .unclassified, message: "legacy warning"),
        ])

        let encoded = try JSONEncoder().encode(quality)
        XCTAssertEqual(try JSONDecoder().decode(TraceDataQuality.self, from: encoded), quality)
    }

    func testLegacyDataQualityJSONDecodesFailClosedAsUnclassified() throws {
        let data = Data(#"{"status":"warnings","warnings":["legacy"]}"#.utf8)
        let decoded = try JSONDecoder().decode(TraceDataQuality.self, from: data)
        XCTAssertEqual(decoded.status, .warnings)
        XCTAssertEqual(decoded.issues, [
            TraceDataQualityIssue(category: .unclassified, message: "legacy")
        ])
    }
}
