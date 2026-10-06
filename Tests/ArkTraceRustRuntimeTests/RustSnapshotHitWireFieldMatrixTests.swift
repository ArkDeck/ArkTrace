import ArkTraceCore
@testable import ArkTraceRustRuntime
import CArkTrace
import Foundation
import XCTest

/// Unit/codec conformance only: the records are constructed here, never returned by FFI.
final class RustSnapshotHitWireFieldMatrixTests: XCTestCase {
    private enum Expected {
        case none, detail(EventKey), density(RustDensitySource, TraceTimeRange, Int64), invalidBuffer
    }
    private struct Case {
        let name: String
        let record: ArkTraceSnapshotHit
        let expected: Expected
    }
    private func base(_ kind: UInt32) -> ArkTraceSnapshotHit {
        var r=ArkTraceSnapshotHit();r.struct_size=80;r.kind=kind;return r
    }
    private func density(_ kind:UInt32, flags:UInt32=0, value:Int64=0,
        filter:Int64=0, owner:Int64=0, start:Int64=9_007_199_254_740_993,
        end:Int64=9_007_199_254_741_003, time:Int64=9_007_199_254_741_003) -> ArkTraceSnapshotHit {
        var r=base(UInt32(ARKTRACE_HIT_DENSITY));r.source_kind=kind;r.flags=flags
        r.source_value=value;r.filter_id=filter;r.owner_value=owner
        r.bucket_start_ns=start;r.bucket_end_ns=end;r.time_ns=time;return r
    }
    private func cases() throws -> [Case] {
        let bucket=try TraceTimeRange.query(startNs:9_007_199_254_740_993,endNs:9_007_199_254_741_003)
        let end:Int64=9_007_199_254_741_003;let big:Int64=9_007_199_254_740_993
        let owned=UInt32(ARKTRACE_TRACK_OWNER);var rows:[Case]=[Case(name:"none-clean",record:base(UInt32(ARKTRACE_HIT_NONE)),expected:.none)]
        let tables:[(UInt32,TraceEventTable,Int64)]=[
            (UInt32(ARKTRACE_TABLE_SCHED_SLICE),.schedSlice,0),
            (UInt32(ARKTRACE_TABLE_THREAD_STATE),.threadState,big),
            (UInt32(ARKTRACE_TABLE_CALLSTACK),.callstack,-1),
            (UInt32(ARKTRACE_TABLE_MEASURE),.measure,Int64.max),
            (UInt32(ARKTRACE_TABLE_PROCESS_MEASURE),.processMeasure,Int64.min),
            (UInt32(ARKTRACE_TABLE_FRAME_SLICE),.frameSlice,big+1)]
        for (tag,table,row) in tables {var r=base(UInt32(ARKTRACE_HIT_DETAIL));r.event_table=tag;r.row_id=row;rows.append(Case(name:"detail-"+table.rawValue,record:r,expected:.detail(EventKey(table:table,rowID:row))))}
        let sources:[(String,ArkTraceSnapshotHit,RustDensitySource)]=[
            ("cpu-zero",density(UInt32(ARKTRACE_SOURCE_CPU)),.cpu(0)),
            ("thread-large",density(UInt32(ARKTRACE_SOURCE_THREAD_STATE),value:big),.threadState(ThreadKey(itid:big))),
            ("named-nil",density(UInt32(ARKTRACE_SOURCE_NAMED_SLICE)),.namedSlice(nil)),
            ("named-some-zero",density(UInt32(ARKTRACE_SOURCE_NAMED_SLICE),flags:owned),.namedSlice(ThreadKey(itid:0))),
            ("cpu-counter-nil",density(UInt32(ARKTRACE_SOURCE_CPU_COUNTER),filter:big),.cpuCounter(filterID:big,cpu:nil)),
            ("cpu-counter-some-zero",density(UInt32(ARKTRACE_SOURCE_CPU_COUNTER),flags:owned,filter:big),.cpuCounter(filterID:big,cpu:0)),
            ("process-counter-nil",density(UInt32(ARKTRACE_SOURCE_PROCESS_COUNTER),filter:big+1),.processCounter(filterID:big+1,processKey:nil)),
            ("process-counter-some-zero",density(UInt32(ARKTRACE_SOURCE_PROCESS_COUNTER),flags:owned,filter:big+1),.processCounter(filterID:big+1,processKey:ProcessKey(ipid:0))),
            ("frame-nil",density(UInt32(ARKTRACE_SOURCE_FRAME)),.frame(processKey:nil)),
            ("frame-some-zero",density(UInt32(ARKTRACE_SOURCE_FRAME),flags:owned),.frame(processKey:ProcessKey(ipid:0))),
            ("frame-large-owner",density(UInt32(ARKTRACE_SOURCE_FRAME),flags:owned,owner:big+7),.frame(processKey:ProcessKey(ipid:big+7)))]
        for (name,r,source) in sources {rows.append(Case(name:name,record:r,expected:.density(source,bucket,end)))}
        // All none payload fields, reserved, size and unknown kind independently polluted.
        let mutations:[(String,(inout ArkTraceSnapshotHit)->Void)]=[
            ("none-size",{$0.struct_size=79}),("unknown-kind",{$0.kind=99}),
            ("none-table",{$0.event_table=1}),("none-source",{$0.source_kind=1}),
            ("none-flags",{$0.flags=1}),("reserved",{$0.reserved=1}),
            ("none-row",{$0.row_id=1}),("none-value",{$0.source_value=1}),
            ("none-filter",{$0.filter_id=1}),("none-owner",{$0.owner_value=1}),
            ("none-start",{$0.bucket_start_ns=1}),("none-end",{$0.bucket_end_ns=1}),
            ("none-time",{$0.time_ns=1})]
        for (name,mutate) in mutations {var r=base(UInt32(ARKTRACE_HIT_NONE));mutate(&r);rows.append(Case(name:name,record:r,expected:.invalidBuffer))}
        var detail=base(UInt32(ARKTRACE_HIT_DETAIL));detail.event_table=99
        rows.append(Case(name:"detail-unknown-table",record:detail,expected:.invalidBuffer))
        detail.event_table=UInt32(ARKTRACE_TABLE_CALLSTACK);detail.source_kind=1;detail.time_ns=1
        rows.append(Case(name:"detail-foreign-source-and-bucket",record:detail,expected:.invalidBuffer))
        let badDensity:[(String,(inout ArkTraceSnapshotHit)->Void)]=[
            ("density-unknown-source",{$0.source_kind=99}),
            ("density-unknown-flags",{$0.flags=0x80000000}),
            ("density-inactive-event",{$0.event_table=1;$0.row_id=1}),
            ("density-empty-bucket",{$0.bucket_end_ns=$0.bucket_start_ns}),
            ("density-negative-bucket",{$0.bucket_start_ns = -1;$0.bucket_end_ns=10;$0.time_ns=0}),
            ("density-time-before",{$0.time_ns=$0.bucket_start_ns-1}),
            ("density-time-after",{$0.time_ns=$0.bucket_end_ns+1})]
        for (name,mutate) in badDensity {var r=density(UInt32(ARKTRACE_SOURCE_NAMED_SLICE));mutate(&r);rows.append(Case(name:name,record:r,expected:.invalidBuffer))}
        XCTAssertEqual(rows.count,40);return rows
    }
    private static func object<T:Encodable>(_ v:T) throws -> Any {
        try JSONSerialization.jsonObject(with:JSONEncoder().encode(v))
    }
    private static func raw(_ r:ArkTraceSnapshotHit) -> [String:Any] {
        // The authoritative header has13 fields/80 bytes; no invented fourteenth field.
        ["struct_size":r.struct_size,"kind":r.kind,"event_table":r.event_table,
         "source_kind":r.source_kind,"flags":r.flags,"reserved":r.reserved,
         "row_id":r.row_id,"source_value":r.source_value,"filter_id":r.filter_id,
         "owner_value":r.owner_value,"bucket_start_ns":r.bucket_start_ns,
         "bucket_end_ns":r.bucket_end_ns,"time_ns":r.time_ns]
    }
    private static func expected(_ e:Expected) throws -> [String:Any] {
        switch e {
        case .none:return ["kind":"none"]
        case .detail(let key):return ["kind":"detail","eventKey":try object(key)]
        case .density(let source,let bucket,let time):return ["kind":"density","source":try object(source),"bucket":try object(bucket),"timeNs":time]
        case .invalidBuffer:return ["error":"RustAdmission.invalidBuffer"]
        }
    }
    func testStrictTypedWireFieldMatrix() throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(12));XCTAssertEqual(MemoryLayout<ArkTraceSnapshotHit>.size,80)
        var output:[[String:Any]]=[];var matched=0
        for row in try cases() {
            let expected=try Self.expected(row.expected);let actual:[String:Any]
            do {
                let value=try RustSnapshot.decodeHit(row.record)
                switch value {
                case nil:actual=["kind":"none"]
                case .detail(let key):actual=["kind":"detail","eventKey":try Self.object(key)]
                case .density(let source,let bucket,let time):actual=["kind":"density","source":try Self.object(source),"bucket":try Self.object(bucket),"timeNs":time]
                }
            } catch {
                if let error=error as? RustAdmission,error == .invalidBuffer {actual=["error":"RustAdmission.invalidBuffer"]}
                else {actual=["unexpectedErrorType":String(reflecting:type(of:error)),"description":String(describing:error)]}
            }
            let equal=NSDictionary(dictionary:actual).isEqual(to:expected)
            if equal {matched+=1};XCTAssertTrue(equal,row.name+" exact typed expected mismatch")
            output.append(["case":row.name,"raw":Self.raw(row.record),"expected":expected,"actual":actual,"matched":equal])
            XCTAssertLessThan(ContinuousClock.now,deadline)
        }
        let data=try JSONSerialization.data(withJSONObject:["unitCodecOnly":true,"actualCaseCount":output.count,"exactMatched":matched,"structBytes":80,"fieldCount":13,"cases":output],options:[.sortedKeys,.withoutEscapingSlashes]);XCTAssertLessThan(data.count,65536)
        if let path=ProcessInfo.processInfo.environment["ARKTRACE_N28_MATRIX_OUTPUT"] {try data.write(to:URL(fileURLWithPath:path),options:.atomic)}
        print("N28_HIT_CODEC actual=\(output.count) matched=\(matched) fields=13 bytes=80 unit-only")
        XCTAssertLessThan(ContinuousClock.now,deadline)
    }
}
