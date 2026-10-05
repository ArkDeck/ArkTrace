import AppKit
import ArkTraceCore
@testable import ArkTraceRendering
import XCTest

/// New current-loader oracle; repository supplies DTOs and never derives labels,
/// Inspector fields, geometry or colors. MAIN target: ArkTraceRenderingTests.
final class HotWireRenderFactsCanonicalTests: XCTestCase, @unchecked Sendable {
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
            return TraceEventPage(items: input.slices, truncated: false)
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
    private static var fixtures: URL {
        if let path = ProcessInfo.processInfo.environment["ARKTRACE_N21R1_FIXTURES"] {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("rust/crates/arktrace-viewer/tests/fixtures/hot-wire-render-facts")
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
                    let color = TimelineDetailPalette.color(for: d)
                    row.merge(["kind":"detail", "eventKey":try object(d.eventKey),
                        "range":try object(d.range), "label":try optional(d.label),
                        "category":try optional(d.category), "depth":d.depth, "jankTag":d.jankTag,
                        "inspector":try inspector(d.inspector),
                        "colorRGB":["red":Int(color.red),"green":Int(color.green),"blue":Int(color.blue)]]) { _,v in v }
                case .density(let d):
                    XCTAssertNil(primitive.selectableEventKey)
                    let color = TimelineDensityPalette.color(for: d.bucket, fallback: TimelinePalette.greyColor)
                    row.merge(["kind":"density", "bucket":try object(d.bucket),
                        "colorRGB":["red":Int(color.red),"green":Int(color.green),"blue":Int(color.blue)]]) { _,v in v }
                }
                return row
            }
        }
    }
    private func canonical(_ name: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf:
            Self.fixtures.appendingPathComponent(name+"-input.json")))
        XCTAssertEqual(input.group, name)
        let v = input.viewport
        let viewport = try TimelineViewport(range:v.range,widthPoints:v.widthPoints,
            heightPoints:v.heightPoints,verticalOffsetPoints:v.verticalOffsetPoints,generation:v.generation)
        let sources: [TimelineTrackSource]
        switch name {
        case "named-slices": sources = [.namedSlice(ThreadKey(itid: 0))]
        case "frames": sources = [.frame(ProcessKey(ipid: 0))]
        default: sources = [.cpuCounter(filterID: 0, cpu: 0), .processCounter(filterID: 0, processKey: ProcessKey(ipid: 0))]
        }
        let tracks = sources.map { TrackDescriptor(title:"N21",source:$0) }
        let calls = Calls()
        let repository = Repository(input: input, calls: calls)
        let loaded = try await TimelineSnapshotLoader().load(
            ViewportRequest(viewport:viewport,tracks:tracks,pixelWidth:174,generation:v.generation,
                preference:.detail,maximumPrimitives:8,deadline:deadline),repository:repository)
        let snapshot = try XCTUnwrap(loaded)
        let details = try Self.facts(snapshot, scale:input.backingScale)
        XCTAssertEqual(details.count, name == "counters" ? 4 : 3)
        XCTAssertEqual(details.first?["eventKey"] as? NSDictionary,
            try Self.object(name == "named-slices" ? input.slices[0].key : name == "frames" ? input.frames[0].key : input.counters[0].samples[0].key) as? NSDictionary)
        var result: [String:Any] = ["group":name,"actualEntry":"TimelineSnapshotLoader.load",
            "detailFacts":details,"trackLayout":snapshot.tracks.map {
                ["trackID":$0.descriptor.id.rawValue,"y":$0.y,"height":$0.height,"depthRows":$0.depthRowCount,
                    "layoutDoubleBits":[String($0.y.bitPattern),String($0.height.bitPattern)]] as [String:Any]
            },"viewport":try Self.object(snapshot.viewport),
            "viewportDoubleBits":[snapshot.viewport.nsPerPoint,snapshot.viewport.widthPoints,snapshot.viewport.heightPoints,snapshot.viewport.verticalOffsetPoints].map { String($0.bitPattern) },
            "actualLoaderCalls":name == "named-slices" ? 2 : 1]
        if name == "named-slices" {
            let densityLoaded = try await TimelineSnapshotLoader().load(
                ViewportRequest(viewport:viewport,tracks:tracks,pixelWidth:174,generation:v.generation,
                    preference:.density,maximumPrimitives:8,deadline:deadline),repository:repository)
            let density = try XCTUnwrap(densityLoaded)
            result["densityFacts"] = try Self.facts(density, scale:input.backingScale)
            result["densityTrackLayout"] = density.tracks.map {
                ["trackID":$0.descriptor.id.rawValue,"y":$0.y,"height":$0.height,"depthRows":$0.depthRowCount,
                    "layoutDoubleBits":[String($0.y.bitPattern),String($0.height.bitPattern)]] as [String:Any]
            }
            XCTAssertEqual(density.primitiveCount,1)
        } else { result["densityFacts"] = [[String:Any]](); result["densityTrackLayout"] = [[String:Any]]() }
        let counts = await calls.snapshot()
        XCTAssertEqual(counts["cpuCatalog", default: 0],0)
        result["actualRepositoryCalls"] = counts
        result["actualCpuCatalogCalls"] = counts["cpuCatalog", default: 0]
        let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys,.withoutEscapingSlashes])
        XCTAssertLessThan(output.count,32768)
        if ProcessInfo.processInfo.environment["ARKTRACE_N21R1_BOOTSTRAP"] != "1" {
            let expected = try Data(contentsOf: Self.fixtures.appendingPathComponent(name+"-swift.json"))
            XCTAssertEqual(try JSONSerialization.jsonObject(with:output) as? NSDictionary,
                try JSONSerialization.jsonObject(with:expected) as? NSDictionary)
        }
        if let root = ProcessInfo.processInfo.environment["ARKTRACE_N21R1_SWIFT_OUTPUT"] {
            try output.write(to: URL(fileURLWithPath:root).appendingPathComponent(name+".json"),options:.atomic)
        }
        XCTAssertLessThan(ContinuousClock.now,deadline)
        print("N21R1_SWIFT_CANONICAL \(name) \(details.count) \(output.count)")
    }
    func testNamedSlicesCurrentLoaderFacts() async throws { try await canonical("named-slices") }
    func testFramesCurrentLoaderFacts() async throws { try await canonical("frames") }
    func testCountersCurrentLoaderFacts() async throws { try await canonical("counters") }
}
