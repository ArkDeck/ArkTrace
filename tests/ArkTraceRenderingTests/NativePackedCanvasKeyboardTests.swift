#if ARKTRACE_NATIVE_RUNTIME
import AppKit
import ArkTraceCore
import ArkTraceRustRuntime
import CArkTrace
@testable import ArkTraceRendering
import XCTest

final class NativePackedCanvasKeyboardTests: XCTestCase, @unchecked Sendable {
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
            value.ns_per_point = try NativePackedCanvasKeyboardTests.double(ns_per_point_bits)
            value.width_points = try NativePackedCanvasKeyboardTests.double(width_points_bits)
            value.height_points = try NativePackedCanvasKeyboardTests.double(height_points_bits)
            value.vertical_offset_points = try NativePackedCanvasKeyboardTests.double(vertical_offset_points_bits)
            value.generation = generation
            value.source_generation = source_generation
            value.backing_scale = try NativePackedCanvasKeyboardTests.double(backing_scale_bits)
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
            value.y = try NativePackedCanvasKeyboardTests.double(y_bits)
            value.height = try NativePackedCanvasKeyboardTests.double(height_bits)
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
            value.x = try NativePackedCanvasKeyboardTests.double(x_bits)
            value.y = try NativePackedCanvasKeyboardTests.double(y_bits)
            value.width = try NativePackedCanvasKeyboardTests.double(width_bits)
            value.height = try NativePackedCanvasKeyboardTests.double(height_bits)
            value.event_count = event_count
            value.occupied_ns = occupied_ns
            value.utilization = try NativePackedCanvasKeyboardTests.double(utilization_bits)
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
    private struct View: Decodable, Sendable {
        let range: TraceTimeRange
        let widthPoints: Double
        let heightPoints: Double
        let verticalOffsetPoints: Double
        let generation: UInt64
    }
    private struct Input: Decodable, Sendable {
        let group: String
        let viewport: View
        let backingScale: Double
        let slices: [TraceSlice]
        let frames: [TraceFrame]
        let counters: [CounterSeries]
        let densityBuckets: [TraceDensityBucket]
    }
    private actor Calls {
        var counts: [String:Int] = [:]
        func hit(_ name: String) { counts[name, default: 0] += 1 }
        func snapshot() -> [String:Int] { counts }
    }
    private struct Repository: TraceRepositoryProtocol {
        let input: Input
        let calls: Calls
        func metadata() async throws -> TraceMetadata {
            TraceMetadata(traceSHA256: String(repeating: "a", count: 64), sourceByteCount: 1,
                durationNs: 1000, sourceFormat: "synthetic", parser: TraceParserIdentity(
                    name: "fixture", reportedVersion: "1", binarySHA256: String(repeating: "b", count: 64),
                    upstreamRepository: "https://example.invalid/", upstreamRevision: String(repeating: "c", count: 40),
                    architecture: "arm64", adapterVersion: "1", buildRecipeVersion: "1"),
                schemaFingerprint: String(repeating: "d", count: 64),
                capabilities: TraceCapabilities(cpuScheduling: true, threadStates: true,
                    namedSlices: true, cpuCounters: true, processCounters: true), dataQuality: TraceDataQuality())
        }
        func processes(_ query: ProcessQuery) async throws -> BoundedPage<TraceProcess> {
            BoundedPage(items: [], truncated: false)
        }
        func threads(_ query: ThreadQuery) async throws -> BoundedPage<TraceThread> {
            BoundedPage(items: [], truncated: false)
        }
        func cpuCatalog(_ query: TraceCPUCatalogQuery) async throws -> TraceCPUCatalog {
            await calls.hit("cpuCatalog")
            throw CancellationError()
        }
        func summaryFacts(_ query: TraceSummaryQuery) async throws -> TraceSummaryFacts {
            throw CancellationError()
        }
        func slices(_ query: TraceSliceQuery) async throws -> TraceEventPage<TraceSlice> {
            await calls.hit("slices")
            XCTAssertEqual(query.threadKey, ThreadKey(itid: 0))
            return TraceEventPage(items: input.slices.filter { $0.range.endNs >= query.range.startNs && $0.range.startNs <= query.range.endNs }, truncated: false)
        }
        func frames(_ query: TraceFrameQuery) async throws -> TraceEventPage<TraceFrame> {
            await calls.hit("frames")
            XCTAssertEqual(query.processKey, ProcessKey(ipid: 0))
            return TraceEventPage(items: input.frames, truncated: false, dataQuality: TraceDataQuality(issues:[TraceDataQualityIssue(category:.invalidValue,scope:"timeline.frame",count:0)]))
        }
        func counters(_ query: CounterQuery) async throws -> TraceEventPage<CounterSeries> {
            await calls.hit("counters")
            return TraceEventPage(items: input.counters.filter { $0.scope == query.scope }, truncated: false)
        }
        func density(_ query: TraceDensityQuery) async throws -> TraceDensityResult {
            await calls.hit("density")
            return TraceDensityResult(buckets: input.densityBuckets)
        }
    }
    private static var fixtures:URL {
        if let path=ProcessInfo.processInfo.environment["ARKTRACE_N24_FIXTURES"] {return URL(fileURLWithPath:path)}
        return URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("rust/crates/arktrace-viewer/tests/fixtures/packed-wire-native-conversion")
    }
    private static func encoded<T:Encodable>(_ value:T) throws -> Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try encoder.encode(value)
    }
    private struct Action:Codable {
        let name:String;let keyCode:UInt16;let characters:String;let option:Bool
        init(_ name:String,_ code:UInt16,_ characters:String,option:Bool=false) {self.name=name;keyCode=code;self.characters=characters;self.option=option}
    }
    private enum Intent:Codable {
        case pan(pointsDoubleBits:String,source:TimelineViewport)
        case zoom(anchorNs:Int64,scaleDoubleBits:String,source:TimelineViewport)
        init(_ intent:TimelineViewportIntent) {
            switch intent {
            case .panPoints(let points,let source):self = .pan(pointsDoubleBits:String(points.bitPattern),source:source)
            case .zoom(let anchor,let scale,let source):self = .zoom(anchorNs:anchor,scaleDoubleBits:String(scale.bitPattern),source:source)
            }
        }
    }
    private enum Callback:Codable {
        case focusVisible(Bool),event(EventKey?),range(TraceTimeRange?),viewport(Intent)
    }
    private struct State:Codable {
        let phase:String;let action:Action;let focusedEventKey:EventKey?;let focusedTrackID:String?
        let selectedEventKey:EventKey?;let selection:TraceTimeRange?;let keyboardFocusVisible:Bool
        let focusedRange:TraceTimeRange?;let focusedInspector:TraceEventInspector?;let focusedLabelUTF8:[UInt8]?
        let displayedSelectableKeys:[EventKey];let callbacks:[Callback]
    }
    private struct Violation:Codable {
        let phase:String;let action:String;let activatedUnavailableKey:EventKey;let displayedSelectableKeys:[EventKey]
    }
    private struct SceneTrace:Codable {let variant:String;let states:[State]}
    private struct Trace:Codable {let scenes:[SceneTrace];let transitions:[State];let actualKeyEvents:Int;let violations:[Violation]}
    private struct Pair {let variant:String;let native:TimelineSnapshot;let reference:TimelineSnapshot}
    @MainActor private final class Canvas {
        let view:TimelineNSView;var callbacks:[Callback]=[];var actualKeyEvents=0;var violations:[Violation]=[]
        init(_ snapshot:TimelineSnapshot) throws {
            view=TimelineNSView(frame:CGRect(x:0,y:0,width:snapshot.viewport.widthPoints,height:snapshot.viewport.heightPoints));view.snapshot=snapshot
            view.interactionBounds=try TraceTimeRange.query(startNs:max(0,snapshot.viewport.range.startNs-1000),endNs:snapshot.viewport.range.endNs+1000)
            view.onSelectEvent={ [weak self] in self?.callbacks.append(.event($0)) }
            view.onSelectRange={ [weak self] in self?.callbacks.append(.range($0)) }
            view.onKeyboardFocusVisibleChange={ [weak self] in self?.callbacks.append(.focusVisible($0)) }
            view.onViewportIntent={ [weak self] in self?.callbacks.append(.viewport(Intent($0))) }
        }
        func key(_ action:Action,phase:String) throws -> State {
            let event=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:action.option ? .option : [],timestamp:0,windowNumber:0,context:nil,characters:action.characters,charactersIgnoringModifiers:action.characters,isARepeat:false,keyCode:action.keyCode))
            let before=callbacks.count;actualKeyEvents+=1;view.keyDown(with:event)
            let selectable=view.snapshot?.tracks.flatMap(\.primitives).compactMap(\.selectableEventKey) ?? []
            for callback in callbacks.dropFirst(before) {
                if case .event(let key)=callback,let key,!selectable.contains(key) {violations.append(Violation(phase:phase,action:action.name,activatedUnavailableKey:key,displayedSelectableKeys:selectable))}
            }
            let focused=view.snapshot?.tracks.flatMap(\.primitives).compactMap { item -> TimelineDetailPrimitive? in
                if case .detail(let d)=item,d.eventKey==view.focusedEventKey {return d};return nil
            }.first
            return State(phase:phase,action:action,focusedEventKey:view.focusedEventKey,focusedTrackID:view.focusedTrackID?.rawValue,selectedEventKey:view.selectedEventKey,selection:view.selection,keyboardFocusVisible:view.keyboardFocusIsVisible,focusedRange:focused?.range,focusedInspector:focused?.inspector,focusedLabelUTF8:focused?.label.map {Array($0.utf8)},displayedSelectableKeys:selectable,callbacks:callbacks)
        }
    }
    private static let detailActions:[Action]=[
        Action("Right",124,"\u{f703}"),Action("Right",124,"\u{f703}"),Action("Left",123,"\u{f702}"),
        Action("Down",125,"\u{f701}"),Action("Up",126,"\u{f700}"),Action("Return",0,"\r"),Action("Escape",0,"\u{1b}"),
        Action("Option-Right",124,"\u{f703}",option:true),Action("Plus",0,"+")
    ]
    private static let densityActions:[Action]=[Action("Right",124,"\u{f703}"),Action("Return",0,"\r"),Action("Escape",0,"\u{1b}")]
    private static func convert(_ wire:Wire,request:ViewportRequest) throws -> TimelineSnapshot {
        let viewport=try wire.viewport.record(),tracks=try wire.tracks.map {try $0.record()},primitives=try wire.primitives.map {try $0.record()},quality=try wire.quality.map {try $0.record()}
        return try tracks.withUnsafeBufferPointer { t in try primitives.withUnsafeBufferPointer { p in try quality.withUnsafeBufferPointer { q in try wire.strings.withUnsafeBufferPointer { s in
            try NativeTimelineSnapshot.convert(request,viewport:viewport,qualityStatus:wire.qualityStatus,tracks:Span(_unsafeElements:t),primitives:Span(_unsafeElements:p),quality:Span(_unsafeElements:q),strings:Span(_unsafeElements:s))
        }}}}
    }
    @MainActor private static func scene(_ canvas:Canvas,variant:String) throws -> SceneTrace {
        let actions=variant == "density" ? densityActions : detailActions
        let states=try actions.map {try canvas.key($0,phase:variant)}
        XCTAssertTrue(states.allSatisfy(\.keyboardFocusVisible))
        if variant == "density" {
            XCTAssertTrue(states.allSatisfy {$0.focusedEventKey==nil && $0.selectedEventKey==nil && $0.displayedSelectableKeys.isEmpty})
        } else {
            XCTAssertTrue(states.prefix(6).contains {$0.focusedInspector != nil})
            XCTAssertTrue(canvas.callbacks.contains {if case .viewport=$0{return true};return false})
            XCTAssertNil(states[6].focusedEventKey);XCTAssertNil(states[6].focusedTrackID);XCTAssertNil(states[6].selectedEventKey)
        }
        return SceneTrace(variant:variant,states:states)
    }
    @MainActor private static func transitions(_ canvas:Canvas,clipped:TimelineSnapshot,density:TimelineSnapshot) throws -> [State] {
        var states=[try canvas.key(Action("Right",124,"\u{f703}"),phase:"detail before replacement")]
        // New generation wrappers retain only the actual current converted/loaded primitives; no additional paired scenes or hand-created records.
        canvas.view.snapshot=TimelineSnapshot(viewport:clipped.viewport,tracks:clipped.tracks,generation:clipped.generation+1,dataQuality:clipped.dataQuality)
        states.append(try canvas.key(Action("Right",124,"\u{f703}"),phase:"current clipped replaces detail"))
        states.append(try canvas.key(Action("Return",0,"\r"),phase:"current clipped activation"))
        XCTAssertNotNil(states[1].focusedRange);XCTAssertTrue(states[1].displayedSelectableKeys.contains(try XCTUnwrap(states[1].focusedEventKey)))
        canvas.view.snapshot=TimelineSnapshot(viewport:density.viewport,tracks:density.tracks,generation:density.generation+2,dataQuality:density.dataQuality)
        states.append(try canvas.key(Action("Right",124,"\u{f703}"),phase:"current density replaces clipped"))
        states.append(try canvas.key(Action("Return",0,"\r"),phase:"current density activation"))
        states.append(try canvas.key(Action("Escape",0,"\u{1b}"),phase:"current density clear"))
        XCTAssertTrue(states[4].displayedSelectableKeys.isEmpty)
        return states
    }
    @MainActor private func group(_ name:String) async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(15));let decoder=JSONDecoder()
        let input=try decoder.decode(Input.self,from:Data(contentsOf:Self.fixtures.appendingPathComponent(name+"-input.json")))
        let packet=try decoder.decode(Packed.self,from:Data(contentsOf:Self.fixtures.appendingPathComponent(name+"-packed.json")));XCTAssertEqual(packet.group,name);XCTAssertEqual(packet.schema,"N22PackedWire1")
        let sources:[TimelineTrackSource]=name == "named-slices" ? [.namedSlice(ThreadKey(itid:0))] : name == "frames" ? [.frame(ProcessKey(ipid:0))] : [.cpuCounter(filterID:0,cpu:0),.processCounter(filterID:0,processKey:ProcessKey(ipid:0))]
        let tracks=sources.map {TrackDescriptor(title:"N24",source:$0)};let calls=Calls();let repository=Repository(input:input,calls:calls)
        var pairs:[Pair]=[]
        for scene in packet.scenes {
            let v=input.viewport;let range=scene.variant == "clipped" ? try TraceTimeRange.query(startNs:v.range.startNs+30,endNs:v.range.endNs) : v.range
            let viewport=try TimelineViewport(range:range,widthPoints:v.widthPoints,heightPoints:v.heightPoints,verticalOffsetPoints:v.verticalOffsetPoints,generation:v.generation)
            let request=try ViewportRequest(viewport:viewport,tracks:tracks,pixelWidth:174,generation:v.generation,preference:scene.variant == "density" ? .density : .detail,maximumPrimitives:8,deadline:deadline)
            let native=try Self.convert(scene.wire,request:request),loaded=try await TimelineSnapshotLoader().load(request,repository:repository)
            pairs.append(Pair(variant:scene.variant,native:native,reference:try XCTUnwrap(loaded)))
        }
        XCTAssertEqual(pairs.count,name == "named-slices" ? 3 : 1)
        var ns:[SceneTrace]=[],rs:[SceneTrace]=[],nc=0,rc=0,nv:[Violation]=[],rv:[Violation]=[]
        var nd:Canvas?,rd:Canvas?
        for pair in pairs {
            let n=try Canvas(pair.native),r=try Canvas(pair.reference)
            ns.append(try Self.scene(n,variant:pair.variant));rs.append(try Self.scene(r,variant:pair.variant))
            nc+=n.actualKeyEvents;rc+=r.actualKeyEvents;nv+=n.violations;rv+=r.violations
            if name == "named-slices" && pair.variant=="detail" {nd=n;rd=r}
        }
        var nt:[State]=[],rt:[State]=[]
        if name == "named-slices" {
            let clip=try XCTUnwrap(pairs.first {$0.variant=="clipped"}),density=try XCTUnwrap(pairs.first {$0.variant=="density"}),n=try XCTUnwrap(nd),r=try XCTUnwrap(rd)
            let oldN=n.actualKeyEvents,oldR=r.actualKeyEvents
            nt=try Self.transitions(n,clipped:clip.native,density:density.native);rt=try Self.transitions(r,clipped:clip.reference,density:density.reference)
            nc+=n.actualKeyEvents-oldN;rc+=r.actualKeyEvents-oldR;nv+=n.violations;rv+=r.violations
        }
        let native=Trace(scenes:ns,transitions:nt,actualKeyEvents:nc,violations:nv),reference=Trace(scenes:rs,transitions:rt,actualKeyEvents:rc,violations:rv)
        let nb=try Self.encoded(native),rb=try Self.encoded(reference);let equal=nb==rb
        let report:[String:Any]=["group":name,"actualConvertCalls":pairs.count,"actualCurrentLoaderCalls":pairs.count,"actualPairedScenes":pairs.count,"actualNativeKeyEvents":nc,"actualReferenceKeyEvents":rc,"actualKeyEvents":nc+rc,"actualRepositoryCalls":await calls.snapshot(),"native":try JSONSerialization.jsonObject(with:nb),"reference":try JSONSerialization.jsonObject(with:rb),"exactTranscriptUTF8BytesEqual":equal,"nativeViolationCount":nv.count,"referenceViolationCount":rv.count,"actualRustPackCalls":0,"actualNativeLoadEngineCalls":0,"actualAccessibilityMethodOrActionCases":0,"actualAppWindowGUICases":0]
        let out=try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.withoutEscapingSlashes]);XCTAssertLessThanOrEqual(out.count,65536)
        if let path=ProcessInfo.processInfo.environment["ARKTRACE_N24_OUTPUT"] {try out.write(to:URL(fileURLWithPath:path).appendingPathComponent(name+".json"),options:.atomic)}
        XCTAssertTrue(equal,"actual native/reference keyboard transcript differs; reports retained")
        XCTAssertTrue(nv.isEmpty && rv.isEmpty,"current density Return activated a key absent from displayed selectable primitives; bounded native/reference evidence retained")
        XCTAssertLessThanOrEqual(nc+rc,name == "named-slices" ? 54 : 18);XCTAssertLessThan(ContinuousClock.now,deadline)
        print("N24_ACTUAL_KEYBOARD \(name) \(pairs.count) \(nc+rc) \(equal) \(nv.count+rv.count)")
    }
    @MainActor func testNamedSlicesNativeCanvasKeyboard() async throws {try await group("named-slices")}
    @MainActor func testFramesNativeCanvasKeyboard() async throws {try await group("frames")}
    @MainActor func testCountersNativeCanvasKeyboard() async throws {try await group("counters")}
}
#endif
