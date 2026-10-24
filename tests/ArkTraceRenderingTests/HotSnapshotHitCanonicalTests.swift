import AppKit
import ArkTraceCore
@testable import ArkTraceRendering
import XCTest

/// New current-loader oracle; repository supplies DTOs and never derives labels,
/// Inspector fields, geometry or colors. MAIN target: ArkTraceRenderingTests.
final class HotSnapshotHitCanonicalTests: XCTestCase, @unchecked Sendable {
    /// Explicit scale keeps the offscreen oracle independent of host displays.
    /// The production NSView still obtains its scale from its actual window.
    @MainActor private final class OracleWindow: NSWindow {
        var oracleScale: CGFloat = 2
        override var backingScaleFactor: CGFloat { oracleScale }
    }
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
            return TraceEventPage(items: input.frames, truncated: false)
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

    private static var fixtures: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["ARKTRACE_N27_FIXTURES"] ?? URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("rust/crates/arktrace-viewer/tests/fixtures/hot-snapshot-hit").path) }
    private static func object<T: Encodable>(_ v:T) throws -> Any { try JSONSerialization.jsonObject(with:JSONEncoder().encode(v)) }
    @MainActor private func canonical(_ name:String) async throws {
        let deadline = ContinuousClock.now.advanced(by:.seconds(12))
        let input = try JSONDecoder().decode(Input.self,from:Data(contentsOf:Self.fixtures.appendingPathComponent(name+"-input.json")))
        let sources:[TimelineTrackSource] = name == "named-slices" ? [.namedSlice(ThreadKey(itid:0))] : name == "frames" ? [.frame(ProcessKey(ipid:0))] : [.cpuCounter(filterID:0,cpu:0),.processCounter(filterID:0,processKey:ProcessKey(ipid:0))]
        let calls=Calls(); let repository=Repository(input:input,calls:calls)
        var scenes:[[String:Any]]=[]
        for variant in name == "named-slices" ? ["detail","density","clipped","stale"] : ["detail"] {
            let v=input.viewport
            let range = variant == "clipped" ? try TraceTimeRange(startNs:v.range.startNs+30,endNs:v.range.endNs) : v.range
            let viewport=try TimelineViewport(range:range,widthPoints:v.widthPoints,heightPoints:v.heightPoints,verticalOffsetPoints:v.verticalOffsetPoints,generation:v.generation)
            let loaded=try await TimelineSnapshotLoader().load(ViewportRequest(viewport:viewport,tracks:sources.map { TrackDescriptor(title:"N27",source:$0) },pixelWidth:174,generation:v.generation,preference:variant == "density" ? .density : .detail,maximumPrimitives:8,deadline:deadline),repository:repository)
            let retained=try XCTUnwrap(loaded)
            let display = variant == "stale"
                ? try TimelineViewport(range: TraceTimeRange.query(startNs: v.range.startNs + 30, endNs: v.range.endNs),
                    widthPoints: v.widthPoints / 2, heightPoints: v.heightPoints + 20,
                    verticalOffsetPoints: v.verticalOffsetPoints + 10, generation: v.generation + 1)
                : viewport
            let snapshot = TimelineSnapshot(viewport: display, tracks: retained.tracks,
                generation: display.generation, dataQuality: retained.dataQuality, isLoading: variant == "stale")
            let scene={ () throws -> [String:Any] in
                let view=TimelineNSView(frame:CGRect(x:0,y:0,width:display.widthPoints,height:display.heightPoints));view.snapshot=snapshot
                let window = OracleWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.oracleScale = variant == "stale" ? 1 : CGFloat(input.backingScale)
                window.contentView = view
                defer { window.contentView = nil }
                let scale=unsafe view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
                XCTAssertEqual(scale, window.oracleScale)
                let track=try XCTUnwrap(snapshot.tracks.first);let primitive=try XCTUnwrap(track.primitives.first)
                let f=TimelineGeometry.frame(for:primitive,in:track,viewport:snapshot.viewport,backingScale:scale)
                let row=TimelineGeometry.trackFrame(track)
                let points=[CGPoint(x:f.midX,y:f.midY),CGPoint(x:max(0,f.minX-1),y:f.midY),CGPoint(x:max(0,f.minX-1.0001),y:f.midY),CGPoint(x:f.midX,y:row.minY),CGPoint(x:f.midX,y:row.maxY),CGPoint(x:f.midX,y:21),CGPoint(x:-1,y:f.midY),CGPoint(x:display.widthPoints,y:f.midY),CGPoint(x:display.widthPoints+1,y:f.midY)]
                var rows:[[String:Any]]=[]
                for p in points {
                    let event=view.event(at:p);let density=view.densityBand(at:p)
                    let hit:Any
                    if let event { hit=["kind":"detail","eventKey":try Self.object(event)] as [String:Any] }
                    else if let density {
                        let actual=try XCTUnwrap(snapshot.tracks.first { $0.descriptor.id == density.trackID })
                        hit=["kind":"density","trackID":density.trackID.rawValue,"source":try Self.object(actual.descriptor.source),"bucket":try Self.object(density.bucket),"timeNs":density.timeNs] as [String:Any]
                    } else { hit=NSNull() }
                    rows.append(["x":Double(p.x),"y":Double(p.y),"pointBits":[String(Double(p.x).bitPattern),String(Double(p.y).bitPattern)],"hit":hit])
                }
                let frames=snapshot.tracks.flatMap { t in t.primitives.map { p in
                    let f=TimelineGeometry.frame(for:p,in:t,viewport:snapshot.viewport,backingScale:scale)
                    return [Double(f.minX),Double(f.minY),Double(f.width),Double(f.height)].map { String($0.bitPattern) }
                } }
                return ["variant":variant,"displayViewport":try Self.object(display),"backingScaleBits":String(Double(scale).bitPattern),"frames":frames,"points":rows,"directEventCalls":9,"directDensityCalls":9,"actualNSViews":1]
            }
            scenes.append(try scene())
        }
        let output=try JSONSerialization.data(withJSONObject:["group":name,"scenes":scenes,"actualLoaderCalls":scenes.count,"actualRepositoryCalls":await calls.snapshot()],options:[.sortedKeys,.withoutEscapingSlashes])
        XCTAssertLessThan(output.count,65536)
        let path=Self.fixtures.appendingPathComponent(name+"-swift.json")
        if ProcessInfo.processInfo.environment["ARKTRACE_N27_BOOTSTRAP"] == "1" { try output.write(to:path,options:.atomic) }
        else { XCTAssertEqual(try JSONSerialization.jsonObject(with:output) as? NSDictionary,try JSONSerialization.jsonObject(with:Data(contentsOf:path)) as? NSDictionary) }
        XCTAssertLessThan(ContinuousClock.now,deadline)
        print("N27_SWIFT \(name) loaders=\(scenes.count) points=\(scenes.count*9) event+density=\(scenes.count*18)")
    }
    func testNamedSlices() async throws { try await canonical("named-slices") }
    func testFrames() async throws { try await canonical("frames") }
    func testCounters() async throws { try await canonical("counters") }
}
