import ArkTraceCore
@testable import ArkTraceRustRuntime
import CArkTrace
import Foundation
import XCTest

final class RustSnapshotHitTests: XCTestCase {
    private func density(_ source: UInt32, flags: UInt32 = 0, value: Int64 = 0,
        filter: Int64 = 0, owner: Int64 = 0) -> ArkTraceSnapshotHit {
        var result = ArkTraceSnapshotHit()
        result.struct_size = UInt32(MemoryLayout<ArkTraceSnapshotHit>.size)
        result.kind = UInt32(ARKTRACE_HIT_DENSITY); result.source_kind = source
        result.flags = flags; result.source_value = value; result.filter_id = filter; result.owner_value = owner
        result.bucket_start_ns = 9_007_199_254_740_993
        result.bucket_end_ns = result.bucket_start_ns + 10; result.time_ns = result.bucket_end_ns
        return result
    }
    func testTypedSourcesPreserveZeroOwnerPresenceAndExactInt64() throws {
        let present = UInt32(ARKTRACE_TRACK_OWNER)
        let cases: [(ArkTraceSnapshotHit, RustDensitySource)] = [
            (density(UInt32(ARKTRACE_SOURCE_CPU), value: 0), .cpu(0)),
            (density(UInt32(ARKTRACE_SOURCE_THREAD_STATE), value: Int64.max), .threadState(ThreadKey(itid: Int64.max))),
            (density(UInt32(ARKTRACE_SOURCE_NAMED_SLICE)), .namedSlice(nil)),
            (density(UInt32(ARKTRACE_SOURCE_NAMED_SLICE), flags: present, value: 0), .namedSlice(ThreadKey(itid: 0))),
            (density(UInt32(ARKTRACE_SOURCE_CPU_COUNTER), filter: Int64.max), .cpuCounter(filterID: Int64.max, cpu: nil)),
            (density(UInt32(ARKTRACE_SOURCE_CPU_COUNTER), flags: present, filter: Int64.max, owner: 0), .cpuCounter(filterID: Int64.max, cpu: 0)),
            (density(UInt32(ARKTRACE_SOURCE_PROCESS_COUNTER), filter: Int64.max), .processCounter(filterID: Int64.max, processKey: nil)),
            (density(UInt32(ARKTRACE_SOURCE_PROCESS_COUNTER), flags: present, filter: Int64.max, owner: 0), .processCounter(filterID: Int64.max, processKey: ProcessKey(ipid: 0))),
            (density(UInt32(ARKTRACE_SOURCE_FRAME)), .frame(processKey: nil)),
            (density(UInt32(ARKTRACE_SOURCE_FRAME), flags: present, owner: 0), .frame(processKey: ProcessKey(ipid: 0)))
        ]
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        for (record, expected) in cases {
            guard case .density(let source, let bucket, let time) = try RustSnapshot.decodeHit(record) else {
                return XCTFail("density lost")
            }
            XCTAssertEqual(try encoder.encode(source), try encoder.encode(expected))
            XCTAssertEqual(bucket.startNs, record.bucket_start_ns); XCTAssertEqual(bucket.endNs, record.bucket_end_ns)
            XCTAssertEqual(time, record.time_ns)
        }
        for table in [TraceEventTable.schedSlice, .threadState, .callstack, .measure, .processMeasure, .frameSlice].enumerated() {
            var record = ArkTraceSnapshotHit(); record.struct_size = UInt32(MemoryLayout<ArkTraceSnapshotHit>.size)
            record.kind = UInt32(ARKTRACE_HIT_DETAIL); record.event_table = UInt32(table.offset + 1); record.row_id = Int64.max
            guard case .detail(let key) = try RustSnapshot.decodeHit(record) else { return XCTFail("detail lost") }
            XCTAssertEqual(key, EventKey(table: table.element, rowID: Int64.max))
        }
    }
    func testRejectsForeignPayloadFieldsAndMalformedRecords() throws {
        var none = ArkTraceSnapshotHit(); none.struct_size = UInt32(MemoryLayout<ArkTraceSnapshotHit>.size)
        XCTAssertNil(try RustSnapshot.decodeHit(none))
        let mutations: [(inout ArkTraceSnapshotHit) -> Void] = [
            { $0.struct_size = 0 }, { $0.kind = 99 }, { $0.event_table = 1 }, { $0.source_kind = 1 },
            { $0.flags = 1 }, { $0.reserved = 1 }, { $0.row_id = 1 }, { $0.source_value = 1 },
            { $0.filter_id = 1 }, { $0.owner_value = 1 }, { $0.bucket_start_ns = 1 },
            { $0.bucket_end_ns = 1 }, { $0.time_ns = 1 }
        ]
        for mutate in mutations {
            var invalid = none; mutate(&invalid)
            XCTAssertThrowsError(try RustSnapshot.decodeHit(invalid)) { XCTAssertEqual($0 as? RustAdmission, .invalidBuffer) }
        }
        let valid = density(UInt32(ARKTRACE_SOURCE_NAMED_SLICE))
        let densityMutations: [(inout ArkTraceSnapshotHit) -> Void] = [
            { $0.flags = 1 }, { $0.source_kind = 99 }, { $0.event_table = 1 }, { $0.row_id = 1 },
            { $0.source_value = 1 }, { $0.filter_id = 1 }, { $0.owner_value = 1 },
            { $0.bucket_start_ns = -1 },
            { $0.bucket_end_ns = $0.bucket_start_ns }, { $0.time_ns = $0.bucket_start_ns - 1 },
            { $0.time_ns = $0.bucket_end_ns + 1 }
        ]
        for mutate in densityMutations {
            var invalid = valid; mutate(&invalid)
            XCTAssertThrowsError(try RustSnapshot.decodeHit(invalid)) { XCTAssertEqual($0 as? RustAdmission, .invalidBuffer) }
        }
        var detail = none; detail.kind = UInt32(ARKTRACE_HIT_DETAIL); detail.event_table = 99
        XCTAssertThrowsError(try RustSnapshot.decodeHit(detail))
        detail.event_table = 1; detail.time_ns = 1
        XCTAssertThrowsError(try RustSnapshot.decodeHit(detail))
    }
}
