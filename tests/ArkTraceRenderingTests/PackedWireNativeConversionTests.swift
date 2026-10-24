#if ARKTRACE_NATIVE_RUNTIME
import AppKit
import CoreFoundation
import ArkTraceCore
import ArkTraceRustRuntime
import CArkTrace
@testable import ArkTraceRendering
import XCTest

final class PackedWireNativeConversionTests: XCTestCase, @unchecked Sendable {
    private static func double(_ value: String) throws -> Double {
        guard let bits=UInt64(value) else {throw RustAdmission.invalidBuffer}
        return Double(bitPattern: bits)
    }
    private struct ViewportRecordDTO: Decodable {
        let start_ns: Int64
        let end_ns: Int64
        let ns_per_point_bits: String
        let width_points_bits: String
        let height_points_bits: String
        let vertical_offset_points_bits: String
        let generation: UInt64
        let source_generation: UInt64
        let backing_scale_bits: String
        func record() throws -> ArkTraceViewportRecord {
            var value=ArkTraceViewportRecord()
            value.start_ns = start_ns
            value.end_ns = end_ns
            value.ns_per_point = try PackedWireNativeConversionTests.double(ns_per_point_bits)
            value.width_points = try PackedWireNativeConversionTests.double(width_points_bits)
            value.height_points = try PackedWireNativeConversionTests.double(height_points_bits)
            value.vertical_offset_points = try PackedWireNativeConversionTests.double(vertical_offset_points_bits)
            value.generation = generation
            value.source_generation = source_generation
            value.backing_scale = try PackedWireNativeConversionTests.double(backing_scale_bits)
            return value
        }
    }
    private struct TrackRecordDTO: Decodable {
        let source_kind: UInt32
        let flags: UInt32
        let source_value: Int64
        let filter_id: Int64
        let owner_value: Int64
        let id_offset: UInt32
        let id_length: UInt32
        let y_bits: String
        let height_bits: String
        let depth_rows: UInt32
        let primitive_start: UInt32
        let primitive_count: UInt32
        let reserved: UInt32
        func record() throws -> ArkTraceTrackRecord {
            var value=ArkTraceTrackRecord()
            value.source_kind = source_kind
            value.flags = flags
            value.source_value = source_value
            value.filter_id = filter_id
            value.owner_value = owner_value
            value.id_offset = id_offset
            value.id_length = id_length
            value.y = try PackedWireNativeConversionTests.double(y_bits)
            value.height = try PackedWireNativeConversionTests.double(height_bits)
            value.depth_rows = depth_rows
            value.primitive_start = primitive_start
            value.primitive_count = primitive_count
            value.reserved = reserved
            return value
        }
    }
    private struct PrimitiveRecordDTO: Decodable {
        let kind: UInt32
        let flags: UInt32
        let track_index: UInt32
        let event_table: UInt32
        let style: UInt32
        let reserved_header: UInt32
        let depth: Int64
        let row_id: Int64
        let start_ns: Int64
        let end_ns: Int64
        let x_bits: String
        let y_bits: String
        let width_bits: String
        let height_bits: String
        let event_count: Int64
        let occupied_ns: Int64
        let utilization_bits: String
        let dominant_kind: UInt32
        let text_offset: UInt32
        let text_length: UInt32
        let reserved: UInt32
        let dominant_value: Int64
        let event_kind: UInt32
        let color_rgb: UInt32
        let jank_tag: Int64
        let semantic_duration_ns: Int64
        let process_key: Int64
        let thread_key: Int64
        let pid: Int64
        let tid: Int64
        let cpu: Int64
        let value: Int64
        let priority: Int64
        let label_offset: UInt32
        let label_length: UInt32
        let category_offset: UInt32
        let category_length: UInt32
        let name_offset: UInt32
        let name_length: UInt32
        let process_name_offset: UInt32
        let process_name_length: UInt32
        let thread_name_offset: UInt32
        let thread_name_length: UInt32
        let inspector_category_offset: UInt32
        let inspector_category_length: UInt32
        let state_offset: UInt32
        let state_length: UInt32
        let unit_offset: UInt32
        let unit_length: UInt32
        func record() throws -> ArkTracePrimitiveRecord {
            var value=ArkTracePrimitiveRecord()
            value.kind = kind
            value.flags = flags
            value.track_index = track_index
            value.event_table = event_table
            value.style = style
            value.reserved_header = reserved_header
            value.depth = depth
            value.row_id = row_id
            value.start_ns = start_ns
            value.end_ns = end_ns
            value.x = try PackedWireNativeConversionTests.double(x_bits)
            value.y = try PackedWireNativeConversionTests.double(y_bits)
            value.width = try PackedWireNativeConversionTests.double(width_bits)
            value.height = try PackedWireNativeConversionTests.double(height_bits)
            value.event_count = event_count
            value.occupied_ns = occupied_ns
            value.utilization = try PackedWireNativeConversionTests.double(utilization_bits)
            value.dominant_kind = dominant_kind
            value.text_offset = text_offset
            value.text_length = text_length
            value.reserved = reserved
            value.dominant_value = dominant_value
            value.event_kind = event_kind
            value.color_rgb = color_rgb
            value.jank_tag = jank_tag
            value.semantic_duration_ns = semantic_duration_ns
            value.process_key = process_key
            value.thread_key = thread_key
            value.pid = pid
            value.tid = tid
            value.cpu = cpu
            value.value = self.value
            value.priority = priority
            value.label_offset = label_offset
            value.label_length = label_length
            value.category_offset = category_offset
            value.category_length = category_length
            value.name_offset = name_offset
            value.name_length = name_length
            value.process_name_offset = process_name_offset
            value.process_name_length = process_name_length
            value.thread_name_offset = thread_name_offset
            value.thread_name_length = thread_name_length
            value.inspector_category_offset = inspector_category_offset
            value.inspector_category_length = inspector_category_length
            value.state_offset = state_offset
            value.state_length = state_length
            value.unit_offset = unit_offset
            value.unit_length = unit_length
            return value
        }
    }
    private struct QualityRecordDTO: Decodable {
        let category: UInt32
        let flags: UInt32
        let scope_offset: UInt32
        let scope_length: UInt32
        let count: Int64
        func record() throws -> ArkTraceQualityRecord {
            var value=ArkTraceQualityRecord()
            value.category = category
            value.flags = flags
            value.scope_offset = scope_offset
            value.scope_length = scope_length
            value.count = count
            return value
        }
    }
    private struct Wire: Decodable {
        let qualityStatus: UInt32
        let viewport: ViewportRecordDTO
        let tracks: [TrackRecordDTO]
        let primitives: [PrimitiveRecordDTO]
        let quality: [QualityRecordDTO]
        let strings: [UInt8]
    }
    private struct Scene: Decodable { let variant: String; let wire: Wire }
    private struct Packed: Decodable { let schema: String; let group: String; let actualRustPackerCalls: Int; let scenes: [Scene] }
    private struct View: Decodable { let range: TraceTimeRange; let widthPoints: Double; let heightPoints: Double; let verticalOffsetPoints: Double; let generation: UInt64 }
    private struct Input: Decodable { let group: String; let viewport: View; let backingScale: Double }
    private struct OldDetail: Decodable { let eventKey: EventKey; let range: TraceTimeRange; let label: String?; let category: String?; let inspector: TraceEventInspector?; let depth: Int; let jankTag: Int64 }
    private static var fixtures: URL {
        if let path=ProcessInfo.processInfo.environment["ARKTRACE_N22_FIXTURES"] {return URL(fileURLWithPath:path)}
        return URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("rust/crates/arktrace-viewer/tests/fixtures/packed-wire-native-conversion")
    }
    private static var packedDirectory: URL {
        if let path=ProcessInfo.processInfo.environment["ARKTRACE_N22_RUST_OUTPUT"] {return URL(fileURLWithPath:path)}
        return fixtures
    }
    private static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }
    private static func optional<T: Encodable>(_ value: T?) throws -> Any {
        if let value { return try object(value) }
        return NSNull()
    }
    private static func inspector(_ value: TraceEventInspector?) throws -> Any {
        guard let i = value else { return NSNull() }
        // Serialization only: read every fact from the actual loader product.
        return ["key":try object(i.key), "type":i.type.rawValue, "name":try optional(i.name),
            "range":try object(i.range), "semanticDurationNs":try optional(i.semanticDurationNs),
            "isOpenEnded":i.isOpenEnded, "processKey":try optional(i.processKey),
            "threadKey":try optional(i.threadKey), "pid":try optional(i.pid), "tid":try optional(i.tid),
            "cpu":try optional(i.cpu), "processName":try optional(i.processName),
            "threadName":try optional(i.threadName), "category":try optional(i.category),
            "state":try optional(i.state), "value":try optional(i.value), "unit":try optional(i.unit),
            "priority":try optional(i.priority), "isInstant":i.isInstant] as [String:Any]
    }
    private static func facts(_ snapshot: TimelineSnapshot, scale: Double) throws -> [[String:Any]] {
        try snapshot.tracks.flatMap { track in
            try track.primitives.map { primitive in
                let frame = TimelineGeometry.frame(for: primitive, in: track,
                    viewport: snapshot.viewport, backingScale: CGFloat(scale))
                var row: [String:Any] = ["trackID":track.descriptor.id.rawValue,
                    "selectableEventKey":try optional(primitive.selectableEventKey),
                    "isVisible":TimelineGeometry.isVisible(primitive, in: snapshot.viewport),
                    "frameDoubleBits":[Double(frame.minX),Double(frame.minY),Double(frame.width),Double(frame.height)].map { String($0.bitPattern) }]
                switch primitive {
                case .detail(let d):
                    XCTAssertEqual(d.eventKey, d.inspector?.key)
                    let color = try XCTUnwrap(d.projection).color
                    row.merge(["kind":"detail", "eventKey":try object(d.eventKey),
                        "range":try object(d.range), "label":try optional(d.label),
                        "category":try optional(d.category), "depth":d.depth, "jankTag":d.jankTag,
                        "inspector":try inspector(d.inspector),
                        "colorRGB":["red":Int(color.red),"green":Int(color.green),"blue":Int(color.blue)]]) { _,v in v }
                case .density(let d):
                    XCTAssertNil(primitive.selectableEventKey)
                    let color = try XCTUnwrap(d.projection).color
                    row.merge(["kind":"density", "bucket":try object(d.bucket),
                        "colorRGB":["red":Int(color.red),"green":Int(color.green),"blue":Int(color.blue)]]) { _,v in v }
                }
                return row
            }
        }
    }

    private static func layout(_ snapshot: TimelineSnapshot) -> [[String:Any]] {
        snapshot.tracks.map { ["trackID":$0.descriptor.id.rawValue,"y":$0.y,"height":$0.height,"depthRows":$0.depthRowCount,
            "layoutDoubleBits":[String($0.y.bitPattern),String($0.height.bitPattern)]] }
    }
    private static func compare(_ path: String, _ actual: Any, _ expected: Any, _ matched: inout [String], _ missing: inout [[String:Any]]) {
        if let a=actual as? [String:Any], let b=expected as? [String:Any] {
            for key in Set(a.keys).union(b.keys).sorted() {
                if let aa=a[key], let bb=b[key] {compare(path+"."+key,aa,bb,&matched,&missing)}
                else {missing.append(["path":path+"."+key,"reason":"missing field"])}
            }
        } else if let a=actual as? [Any],let b=expected as? [Any] {
            if a.count != b.count {missing.append(["path":path,"reason":"count"])}
            for (i,pair) in zip(a,b).enumerated() {compare(path+"[\(i)]",pair.0,pair.1,&matched,&missing)}
        } else if let a=actual as? String, let b=expected as? String {
            if a.utf8.elementsEqual(b.utf8) {matched.append(path)} else {missing.append(["path":path,"actual":a,"expected":b])}
        } else if let a=actual as? NSNumber,let b=expected as? NSNumber {
            let isDouble=["y","height","nsPerPoint","widthPoints","heightPoints","verticalOffsetPoints"].contains(path.split(separator:".").last.map(String.init) ?? "")
            let ab=CFGetTypeID(a)==CFBooleanGetTypeID(),bb=CFGetTypeID(b)==CFBooleanGetTypeID()
            let integerTypes=["c","s","i","l","q","C","S","I","L","Q"]
            let equal = isDouble ? a.doubleValue.bitPattern == b.doubleValue.bitPattern :
                ab || bb ? ab && bb && a.boolValue == b.boolValue :
                integerTypes.contains(String(cString:a.objCType)) && integerTypes.contains(String(cString:b.objCType)) && a.stringValue == b.stringValue
            if equal {matched.append(path)} else {missing.append(["path":path,"actual":a,"expected":b])}
        } else if actual is NSNull && expected is NSNull {matched.append(path)}
        else {missing.append(["path":path,"reason":"type or value"])}
    }
    private func canonical(_ name: String) throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(8))
        let decoder=JSONDecoder()
        let input=try decoder.decode(Input.self,from:Data(contentsOf:Self.fixtures.appendingPathComponent(name+"-input.json")))
        let raw=try Data(contentsOf:Self.packedDirectory.appendingPathComponent(name+"-packed.json"))
        let packed=try decoder.decode(Packed.self,from:raw);XCTAssertEqual(packed.schema,"N22PackedWire1");XCTAssertEqual(packed.group,name)
        let old=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:Self.fixtures.appendingPathComponent(name+"-swift.json"))) as? [String:Any])
        let sources:[TimelineTrackSource] = name == "named-slices" ? [.namedSlice(ThreadKey(itid:0))] : name == "frames" ? [.frame(ProcessKey(ipid:0))] : [.cpuCounter(filterID:0,cpu:0),.processCounter(filterID:0,processKey:ProcessKey(ipid:0))]
        let descriptors=sources.map {TrackDescriptor(title:"N22",source:$0)}
        var matched:[String]=[],missing:[[String:Any]]=[],outputs:[[String:Any]]=[]
        for scene in packed.scenes {
            let v=input.viewport
            let range = scene.variant == "clipped" ? try TraceTimeRange.query(startNs:v.range.startNs+30,endNs:v.range.endNs) : v.range
            let viewport=try TimelineViewport(range:range,widthPoints:v.widthPoints,heightPoints:v.heightPoints,verticalOffsetPoints:v.verticalOffsetPoints,generation:v.generation)
            let request=try ViewportRequest(viewport:viewport,tracks:descriptors,pixelWidth:174,generation:v.generation,preference:scene.variant == "density" ? .density : .detail,maximumPrimitives:8,deadline:deadline)
            let wire=scene.wire
            let viewportRecord=try wire.viewport.record(),tracks=try wire.tracks.map {try $0.record()},primitives=try wire.primitives.map {try $0.record()},quality=try wire.quality.map {try $0.record()}
            let snapshot=try tracks.withUnsafeBufferPointer { t in
                try primitives.withUnsafeBufferPointer { p in
                    try quality.withUnsafeBufferPointer { q in
                        try wire.strings.withUnsafeBufferPointer { s in
                            try NativeTimelineSnapshot.convert(request,viewport:viewportRecord,qualityStatus:wire.qualityStatus,
                                tracks:Span(_unsafeElements:t),primitives:Span(_unsafeElements:p),quality:Span(_unsafeElements:q),strings:Span(_unsafeElements:s))
                        }
                    }
                }
            }
            let actual:[String:Any] = ["facts":try Self.facts(snapshot,scale:input.backingScale),"trackLayout":Self.layout(snapshot),"viewport":try Self.object(snapshot.viewport),
                "viewportDoubleBits":[snapshot.viewport.nsPerPoint,snapshot.viewport.widthPoints,snapshot.viewport.heightPoints,snapshot.viewport.verticalOffsetPoints].map {String($0.bitPattern)}]
            var expectedRows=try XCTUnwrap(old[scene.variant == "density" ? "densityFacts" : "detailFacts"] as? [[String:Any]])
            let oldLayout=try XCTUnwrap(old[scene.variant == "density" ? "densityTrackLayout" : "trackLayout"] as? [[String:Any]])
            if scene.variant == "clipped" {
                expectedRows=Array(expectedRows.dropFirst())
                let t=try XCTUnwrap(oldLayout.first);let y=try XCTUnwrap(t["y"] as? NSNumber).doubleValue,height=try XCTUnwrap(t["height"] as? NSNumber).doubleValue,depth=try XCTUnwrap(t["depthRows"] as? NSNumber).intValue
                for index in expectedRows.indices {
                    let dto=try decoder.decode(OldDetail.self,from:JSONSerialization.data(withJSONObject:expectedRows[index]))
                    let primitive=TimelinePrimitive.detail(TimelineDetailPrimitive(trackID:descriptors[0].id,eventKey:dto.eventKey,range:dto.range,label:dto.label,category:dto.category,inspector:dto.inspector,depth:dto.depth,jankTag:dto.jankTag))
                    let track=TimelineTrackSnapshot(descriptor:descriptors[0],y:y,height:height,primitives:[primitive],depthRowCount:depth)
                    let f=TimelineGeometry.frame(for:primitive,in:track,viewport:viewport,backingScale:CGFloat(input.backingScale))
                    expectedRows[index]["frameDoubleBits"]=[Double(f.minX),Double(f.minY),Double(f.width),Double(f.height)].map {String($0.bitPattern)}
                    expectedRows[index]["isVisible"]=TimelineGeometry.isVisible(primitive,in:viewport)
                }
                XCTAssertEqual(primitives.first?.x.bitPattern,0)
                XCTAssertLessThan(try XCTUnwrap(primitives.first).start_ns,range.startNs)
            }
            let expected:[String:Any] = ["facts":expectedRows,"trackLayout":oldLayout,"viewport":try Self.object(viewport),
                "viewportDoubleBits":[viewport.nsPerPoint,viewport.widthPoints,viewport.heightPoints,viewport.verticalOffsetPoints].map {String($0.bitPattern)}]
            Self.compare(scene.variant,actual,expected,&matched,&missing)
            if name == "frames" {XCTAssertEqual(snapshot.dataQuality.status,.warnings);XCTAssertEqual(snapshot.dataQuality.issues.count,1);XCTAssertEqual(snapshot.dataQuality.issues[0].category,.invalidValue);XCTAssertEqual(snapshot.dataQuality.issues[0].scope,"timeline.frame");XCTAssertEqual(snapshot.dataQuality.issues[0].count,0)}
            else {XCTAssertEqual(snapshot.dataQuality.status,.ok);XCTAssertTrue(snapshot.dataQuality.issues.isEmpty)}
            outputs.append(["variant":scene.variant,"actualConvertedCanonical":actual,"actualConvertedQuality":try Self.object(snapshot.dataQuality)])
        }
        XCTAssertEqual(packed.scenes.count,name == "named-slices" ? 3 : 1)
        let report:[String:Any] = ["group":name,"actualEntry":"NativeTimelineSnapshot.convert","actualConvertCalls":packed.scenes.count,"actualRustPackerCalls":packed.actualRustPackerCalls,
            "matchedFields":matched,"matchedFieldCount":matched.count,"missingFields":missing,"missingFieldCount":missing.count,"outputs":outputs,"actualOldLoaderCalls":0,"actualFFISDKControllerAppCases":0]
        let data=try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.withoutEscapingSlashes]);XCTAssertLessThanOrEqual(data.count,65536)
        if let directory=ProcessInfo.processInfo.environment["ARKTRACE_N22_SWIFT_OUTPUT"] {try data.write(to:URL(fileURLWithPath:directory).appendingPathComponent(name+".json"),options:.atomic)}
        XCTAssertTrue(missing.isEmpty,"exact current converted canonical mismatch: \(missing)")
        XCTAssertLessThan(ContinuousClock.now,deadline)
        print("N22_ACTUAL_NATIVE_CONVERT \(name) \(packed.scenes.count) \(matched.count) \(missing.count)")
    }
    func testNamedSlicesActualPackedWire() throws {try canonical("named-slices")}
    func testFramesActualPackedWire() throws {try canonical("frames")}
    func testCountersActualPackedWire() throws {try canonical("counters")}
}
#endif
