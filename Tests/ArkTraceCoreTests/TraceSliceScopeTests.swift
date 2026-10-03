import XCTest
@testable import ArkTraceCore

final class TraceSliceScopeTests: XCTestCase {
    func testCounterFamilyCanBeSelectedWithoutAnOptionalOwner() throws {
        let range = try TraceTimeRange.query(startNs: 0, endNs: 1_000)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        XCTAssertNil(try CounterQuery(range: range, deadline: deadline).scope)
        XCTAssertEqual(try CounterQuery(range: range, scope: .cpu, deadline: deadline).scope, .cpu)
        XCTAssertEqual(try CounterQuery(range: range, scope: .process, deadline: deadline).scope, .process)
        XCTAssertThrowsError(try CounterQuery(range: range, scope: .cpu, processKey: ProcessKey(ipid: 1), deadline: deadline))
        XCTAssertThrowsError(try CounterQuery(range: range, scope: .cpu, pid: 1, deadline: deadline))
        XCTAssertThrowsError(try CounterQuery(range: range, scope: .process, cpu: 1, deadline: deadline))
    }
    func testUnattributedScopeKeepsGeneralDefaultAndRejectsIdentityFilters() throws {
        let range = try TraceTimeRange.query(startNs: 0, endNs: 1_000)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        XCTAssertFalse(try TraceSliceQuery(range: range, deadline: deadline).unattributedOnly)
        XCTAssertTrue(try TraceSliceQuery(range: range, unattributedOnly: true, deadline: deadline).unattributedOnly)
        let key = EventKey(table: .callstack, rowID: 1)
        XCTAssertNoThrow(try TraceSliceQuery(range: range, eventKey: key, unattributedOnly: true, deadline: deadline))
        XCTAssertThrowsError(try TraceSliceQuery(range: range, processKey: ProcessKey(ipid: 1), unattributedOnly: true, deadline: deadline))
        XCTAssertThrowsError(try TraceSliceQuery(range: range, pid: 1, unattributedOnly: true, deadline: deadline))
        XCTAssertThrowsError(try TraceSliceQuery(range: range, threadKey: ThreadKey(itid: 1), unattributedOnly: true, deadline: deadline))
        XCTAssertThrowsError(try TraceSliceQuery(range: range, tid: 1, unattributedOnly: true, deadline: deadline))
    }
}
