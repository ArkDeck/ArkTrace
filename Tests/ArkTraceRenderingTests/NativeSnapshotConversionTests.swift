#if ARKTRACE_NATIVE_RUNTIME
import ArkTraceCore
import ArkTraceRustRuntime
@testable import ArkTraceRendering
import CArkTrace
import XCTest

final class NativeSnapshotConversionTests: XCTestCase {
    private func input() throws -> (ViewportRequest, ArkTraceViewportRecord, ArkTraceTrackRecord, ArkTracePrimitiveRecord, [UInt8]) {
        let range = try TraceTimeRange.query(startNs: 0, endNs: 100)
        let viewport = try TimelineViewport(range: range, widthPoints: 200, heightPoints: 80, generation: 1)
        let request = try ViewportRequest(viewport: viewport, tracks: [TrackDescriptor(title: "CPU 0", source: .cpu(0))],
            pixelWidth: 400, generation: 1, maximumPrimitives: 10, deadline: .now.advanced(by: .seconds(10)))
        var wire = ArkTraceViewportRecord()
        wire.start_ns = 0; wire.end_ns = 100; wire.width_points = 200; wire.height_points = 80
        wire.ns_per_point = 0.5; wire.generation = 1; wire.source_generation = 1; wire.backing_scale = 2
        var track = ArkTraceTrackRecord()
        track.source_kind = UInt32(ARKTRACE_SOURCE_CPU); track.id_length = 5
        track.flags = UInt32(ARKTRACE_TRACK_NESTED)
        track.depth_rows = 1; track.height = 28; track.primitive_count = 1
        var p = ArkTracePrimitiveRecord()
        p.kind = UInt32(ARKTRACE_PRIMITIVE_DETAIL); p.event_table = UInt32(ARKTRACE_TABLE_SCHED_SLICE)
        p.event_kind = 1; p.row_id = Int64.max; p.end_ns = 10; p.semantic_duration_ns = 10
        p.flags = UInt32(ARKTRACE_FLAG_RENDER_FACTS | ARKTRACE_FLAG_COLOR | ARKTRACE_FLAG_SEMANTIC_DURATION
            | ARKTRACE_FLAG_NAME | ARKTRACE_FLAG_LABEL | ARKTRACE_FLAG_PROCESS_KEY | ARKTRACE_FLAG_THREAD_KEY
            | ARKTRACE_FLAG_PID | ARKTRACE_FLAG_CPU | ARKTRACE_FLAG_PRIORITY | ARKTRACE_FLAG_FRAME | ARKTRACE_FLAG_VISIBLE)
        p.color_rgb = 0xabcdef; p.process_key = 0; p.thread_key = Int64.max; p.pid = 0; p.cpu = 0
        p.priority = Int64.min; p.name_offset = 5; p.name_length = 4; p.label_offset = 5; p.label_length = 4
        p.x = 2; p.y = 3; p.width = 20; p.height = 22
        return (request,wire,track,p,Array("cpu:0🦀".utf8))
    }
    private func convert(_ request: ViewportRequest, _ viewport: ArkTraceViewportRecord,
        _ track: ArkTraceTrackRecord, _ primitive: ArkTracePrimitiveRecord, _ strings: [UInt8]) throws -> TimelineSnapshot {
        try [track].withUnsafeBufferPointer { tracks in
            try [primitive].withUnsafeBufferPointer { primitives in
                try [ArkTraceQualityRecord]().withUnsafeBufferPointer { quality in
                    try strings.withUnsafeBufferPointer { strings in
                        try NativeTimelineSnapshot.convert(request, viewport: viewport, qualityStatus: UInt32(ARKTRACE_QUALITY_STATUS_OK),
                            tracks: Span(_unsafeElements: tracks), primitives: Span(_unsafeElements: primitives),
                            quality: Span(_unsafeElements: quality), strings: Span(_unsafeElements: strings))
                    }
                }
            }
        }
    }
    func testExactInt64NullableZeroUTF8AndNativeGeometryReachRenderer() throws {
        let (request,wire,track,p,strings) = try input()
        let snapshot = try convert(request,wire,track,p,strings)
        guard case .detail(let detail) = snapshot.tracks[0].primitives[0], let inspector = detail.inspector else { return XCTFail("detail Inspector absent") }
        XCTAssertEqual(detail.label,"🦀")
        XCTAssertEqual(inspector.name,"🦀")
        XCTAssertEqual(inspector.key.rowID,Int64.max)
        XCTAssertEqual(inspector.processKey,ProcessKey(ipid: 0))
        XCTAssertEqual(inspector.threadKey,ThreadKey(itid: Int64.max))
        XCTAssertEqual(inspector.pid,0); XCTAssertNil(inspector.tid)
        XCTAssertEqual(inspector.priority,Int64.min)
        XCTAssertEqual(TimelineGeometry.frame(for: .detail(detail), in: snapshot.tracks[0], viewport: request.viewport, backingScale: 2),CGRect(x: 2,y: 3,width: 20,height: 22))
        XCTAssertEqual(detail.projection?.color,TimelineColor(red: 0xab,green: 0xcd,blue: 0xef))
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertFalse(String(decoding: encoded,as: UTF8.self).contains("projection"))
        XCTAssertEqual(try JSONDecoder().decode(TimelineSnapshot.self,from: encoded),snapshot)
    }
    func testOpenDurationRemainsNilAndEmptyNameRemainsPresent() throws {
        let (request,wire,track,base,strings) = try input()
        var p=base; p.flags &= ~UInt32(ARKTRACE_FLAG_SEMANTIC_DURATION)
        p.flags |= UInt32(ARKTRACE_FLAG_OPEN_ENDED); p.semantic_duration_ns=0; p.name_length=0
        let snapshot=try convert(request,wire,track,p,strings)
        guard case .detail(let detail)=snapshot.tracks[0].primitives[0], let inspector=detail.inspector else {return XCTFail("detail absent")}
        XCTAssertEqual(inspector.name,""); XCTAssertNil(inspector.semanticDurationNs)
        XCTAssertTrue(inspector.isOpenEnded); XCTAssertFalse(inspector.isInstant)
    }
    func testMalformedFieldsFailWithoutPublishingPartialScene() throws {
        let (request,wire,track,base,strings)=try input()
        for mutate in [
            { (p: inout ArkTracePrimitiveRecord) in p.flags &= ~UInt32(ARKTRACE_FLAG_RENDER_FACTS) },
            { (p: inout ArkTracePrimitiveRecord) in p.event_table=UInt32(ARKTRACE_TABLE_CALLSTACK) },
            { (p: inout ArkTracePrimitiveRecord) in p.label_offset=UInt32.max },
            { (p: inout ArkTracePrimitiveRecord) in p.unit_length=1 },
            { (p: inout ArkTracePrimitiveRecord) in p.flags |= 0x80000000 },
            { (p: inout ArkTracePrimitiveRecord) in p.width = .nan },
        ] {
            var p=base; mutate(&p); XCTAssertThrowsError(try convert(request,wire,track,p,strings))
        }
        var invalidUTF8=strings; invalidUTF8[5]=0xff
        XCTAssertThrowsError(try convert(request,wire,track,base,invalidUTF8))
        var stale=wire; stale.source_generation=0
        XCTAssertThrowsError(try convert(request,stale,track,base,strings))
    }
    func testViewportWireCarriesOriginalContinuousDeadlineAndExplicitNil() throws {
        let range=try TraceTimeRange.query(startNs: 0,endNs: 100)
        let request=RustViewportRequest(viewport: RustViewport(range: range,widthPoints: 200,heightPoints: 80,verticalOffsetPoints: 0,generation: 1),tracks: [],pixelWidth: 400,generation: 1)
        let original=ContinuousClock.now.advanced(by: .seconds(4))
        for deadline in [original,nil] {
            let query=RustViewportQuery(request: request,backingScale: 2,deadline: deadline)
            let fields=try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(query)) as? [String:Any])
            XCTAssertEqual(fields["clock"] as? String,"hostContinuousEpochV1")
            if let deadline {
                let parts=ContinuousClock().systemEpoch.duration(to: deadline).components
                let value=try XCTUnwrap(fields["deadline"] as? [String:NSNumber])
                XCTAssertEqual(value["seconds"]?.int64Value,parts.seconds)
                XCTAssertEqual(value["attoseconds"]?.int64Value,parts.attoseconds)
            } else {XCTAssertTrue(fields["deadline"] is NSNull)}
        }
    }
}
#endif
