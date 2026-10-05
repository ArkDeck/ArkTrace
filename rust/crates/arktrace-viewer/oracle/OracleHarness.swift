// Appended only to a cache copy of the current TimelineRenderingTests.swift.
// All expected geometry/hit/interaction/load results call original methods.
extension TimelineRenderingTests {
    private struct ParallelViewport: Decodable, Sendable {
        let range: TraceTimeRange
        let widthPoints: Double
        let heightPoints: Double
        let verticalOffsetPoints: Double
        let generation: UInt64
        func value() throws -> TimelineViewport {
            try TimelineViewport(range: range, widthPoints: widthPoints, heightPoints: heightPoints,
                verticalOffsetPoints: verticalOffsetPoints, generation: generation)
        }
    }
    private struct ParallelDescriptor: Decodable, Sendable {
        let source: TraceDensitySource
        let isCollapsed: Bool
        let showsNestedDepth: Bool
        func value() -> TrackDescriptor {
            let translated: TimelineTrackSource
            switch source {
            case .cpu(let id): translated = .cpu(id)
            case .threadState(let id): translated = .threadState(id)
            case .namedSlice(let id): translated = .namedSlice(id)
            case .cpuCounter(let id, let cpu): translated = .cpuCounter(filterID: id, cpu: cpu)
            case .processCounter(let id, let process): translated = .processCounter(filterID: id, processKey: process)
            case .frame(let process): translated = .frame(process)
            }
            return TrackDescriptor(title: "oracle", source: translated, isCollapsed: isCollapsed, showsNestedDepth: showsNestedDepth)
        }
    }
    private struct ParallelDetail: Decodable {
        let eventKey: EventKey
        let range: TraceTimeRange
        let depth: Int
        let style: String
        let isOpenEnded: Bool
        func value(track: TimelineTrackID) -> TimelinePrimitive {
            // Semantic style->actual category adapter only, not the z-order
            // or hit formula: TimelineNSView chooses those from real category.
            let category: String?
            switch style {
            case "running": category = "cpu"
            case "runnable": category = "runnable"
            case "blocked": category = "blocked"
            case "sleeping": category = "sleeping"
            case "counter": category = "counter"
            default: category = nil
            }
            let inspector = TraceEventInspector(key: eventKey, type: .namedSlice, name: nil, range: range,
                semanticDurationNs: isOpenEnded ? nil : range.durationNs, isOpenEnded: isOpenEnded,
                processKey: nil, threadKey: nil, pid: nil, tid: nil, cpu: nil, processName: nil, threadName: nil,
                category: category, state: nil, value: nil, unit: nil)
            return .detail(TimelineDetailPrimitive(trackID: track, eventKey: eventKey, range: range,
                category: category, inspector: inspector, depth: depth))
        }
    }
    private struct ParallelPrimitive: Decodable {
        let kind: String
        let detail: ParallelDetail?
        let bucket: TraceDensityBucket?
        func value(track: TimelineTrackID) throws -> TimelinePrimitive {
            if kind == "detail", let detail { return detail.value(track: track) }
            if kind == "density", let bucket { return .density(TimelineDensityPrimitive(trackID: track, bucket: bucket)) }
            throw CocoaError(.coderInvalidValue)
        }
    }
    private struct ParallelTrack: Decodable {
        let descriptor: ParallelDescriptor
        let y: Double
        let height: Double
        let depthRowCount: Int
        let primitives: [ParallelPrimitive]
        func value() throws -> TimelineTrackSnapshot {
            let descriptor = descriptor.value()
            return TimelineTrackSnapshot(descriptor: descriptor, y: y, height: height,
                primitives: try primitives.map { try $0.value(track: descriptor.id) }, depthRowCount: depthRowCount)
        }
    }
    private struct ParallelPoint: Decodable { let x: Double; let y: Double; var value: CGPoint { CGPoint(x: x, y: y) } }
    private struct ParallelPan: Decodable { let points: Double; let bounds: TraceTimeRange }
    private struct ParallelZoom: Decodable { let anchorNs: Int64; let scale: Double; let bounds: TraceTimeRange }
    private struct ParallelSelection: Decodable { let range: TraceTimeRange; let points: [ParallelPoint] }
    private struct ParallelGeometry: Decodable {
        let name: String
        let viewport: ParallelViewport
        let tracks: [ParallelTrack]
        let backingScale: Double
        let times: [Int64]
        let xs: [Double]
        let points: [ParallelPoint]
        let pans: [ParallelPan]
        let zooms: [ParallelZoom]
        let selections: [ParallelSelection]
        let resolutionTimeNs: Int64
    }
    private static func object<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
    }
    private static func frameObject(_ frame: CGRect) -> [String: Double] {
        ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
    }
    @MainActor
    func testParallelViewerGeometryOracle() throws {
        let inputPath = try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_VIEWER_ORACLE_INPUT"])
        let outputPath = try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_VIEWER_ORACLE_OUTPUT"])
        let vectors = try JSONDecoder().decode([ParallelGeometry].self, from: Data(contentsOf: URL(fileURLWithPath: inputPath)))
        let hitScale = NSScreen.main?.backingScaleFactor ?? 2
        var results: [[String: Any]] = []
        for v in vectors {
            let viewport = try v.viewport.value(); let tracks = try v.tracks.map { try $0.value() }
            let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: viewport.widthPoints, height: viewport.heightPoints))
            view.snapshot = TimelineSnapshot(viewport: viewport, tracks: tracks, generation: viewport.generation, dataQuality: TraceDataQuality())
            let frames = tracks.map { t in t.primitives.map { p -> Any in
                guard TimelineGeometry.isVisible(p, in: viewport) else { return NSNull() }
                return Self.frameObject(TimelineGeometry.frame(for: p, in: t, viewport: viewport, backingScale: v.backingScale))
            } }
            let visible = tracks.map { t in t.primitives.map { TimelineGeometry.isVisible($0, in: viewport) } }
            let hits = try v.points.map { p -> [String: Any] in
                let detail: Any = try view.event(at: p.value).map(Self.object) ?? NSNull()
                let density: Any
                if let hit = view.densityBand(at: p.value) {
                    density = ["trackID": hit.trackID.rawValue, "bucket": try Self.object(hit.bucket), "timeNs": hit.timeNs]
                } else { density = NSNull() }
                return ["detail": detail, "density": density]
            }
            let pans = try v.pans.map { p -> [String: Any] in
                let delta = viewport.nanosecondDelta(forPoints: p.points)
                return ["deltaNs": delta, "range": try Self.object(TimelineInteraction.pan(range: viewport.range, deltaNs: delta, within: p.bounds))]
            }
            let zooms = try v.zooms.map { z in try Self.object(TimelineInteraction.zoom(range: viewport.range, anchorNs: z.anchorNs, scale: z.scale, within: z.bounds)) }
            let selections = v.selections.map { s in s.points.map { p -> Any in
                switch TimelineGeometry.selectionEndpoint(at: p.value, selection: s.range, viewport: viewport) {
                case .start: return "start"
                case .end: return "end"
                case nil: return NSNull()
                }
            } }
            let resolution: Any = try TimelineSnapshotLoader.resolution(at: v.resolutionTimeNs, among: tracks.flatMap(\.primitives)).map { try Self.object($0.eventKey) } ?? NSNull()
            results.append(["name": v.name, "viewport": try Self.object(viewport), "frames": frames, "visible": visible,
                "xCoordinates": v.times.map { Double(TimelineGeometry.x(for: $0, viewport: viewport)) },
                "times": v.xs.map { TimelineGeometry.time(forX: $0, viewport: viewport) }, "hitScale": Double(hitScale), "hits": hits,
                "pans": pans, "zooms": zooms, "selectionEndpoints": selections, "resolution": resolution])
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        XCTAssertEqual(results.count, vectors.count)
    }
}

extension TimelineRenderingTests {
    private struct ParallelRequest: Decodable, Sendable {
        let viewport: ParallelViewport
        let tracks: [ParallelDescriptor]
        let pixelWidth: Int
        let generation: UInt64
        let preference: TimelineDetailPreference
        let maximumPrimitives: Int?
        let focusedEventKey: EventKey?
        func value() throws -> ViewportRequest {
            try ViewportRequest(viewport: viewport.value(), tracks: tracks.map { $0.value() },
                pixelWidth: pixelWidth, generation: generation, preference: preference,
                maximumPrimitives: maximumPrimitives, focusedEventKey: focusedEventKey,
                deadline: .now.advanced(by: .seconds(60)))
        }
    }
    private struct ParallelPlan: Decodable, Sendable {
        let name: String
        let request: ParallelRequest
        let eventCounts: [Int64]
        let detailDepths: [[Int64]]
        let truncated: [Bool]
        let sourceIssues: [TraceDataQualityIssue]?
    }
    private struct ParallelDensityCall: Encodable, Sendable {
        let source: TraceDensitySource
        let bucketCount: Int
        let range: TraceTimeRange
    }
    private struct ParallelDetailCall: Encodable, Sendable {
        let source: TraceDensitySource
        let limit: Int
    }
    private actor ParallelPlanRepository: TraceRepositoryProtocol {
    func cpuCatalog(_ query: TraceCPUCatalogQuery) async throws -> TraceCPUCatalog { .unavailable }

        let vector: ParallelPlan
        var densityCalls: [ParallelDensityCall] = []
        var detailCalls: [ParallelDetailCall] = []
        var batches: [Int] = []
        init(_ vector: ParallelPlan) { self.vector = vector }
        func index(_ source: TraceDensitySource) throws -> Int {
            try XCTUnwrap(vector.request.tracks.firstIndex { $0.source == source })
        }
        func metadata() async throws -> TraceMetadata {
            try await DensityRepository(eventCount: 0).metadata()
        }
        func processes(_ query: ProcessQuery) async throws -> BoundedPage<TraceProcess> { BoundedPage(items: [], truncated: false) }
        func threads(_ query: ThreadQuery) async throws -> BoundedPage<TraceThread> { BoundedPage(items: [], truncated: false) }
        func summaryFacts(_ query: TraceSummaryQuery) async throws -> TraceSummaryFacts { throw CancellationError() }
        func density(_ query: TraceDensityQuery) async throws -> TraceDensityResult {
            densityCalls.append(ParallelDensityCall(source: query.source, bucketCount: query.bucketCount, range: query.range))
            return TraceDensityResult(buckets: [TraceDensityBucket(range: query.range,
                eventCount: vector.eventCounts[try index(query.source)], occupiedNs: nil, utilization: nil, dominant: nil)])
        }
        func eventBatch(_ batch: TraceRepositoryEventBatch) async throws -> TraceRepositoryEventBatchResult {
            batches.append(batch.densities.count)
            var results: [TraceDensityResult] = []
            for query in batch.densities { results.append(try await density(query)) }
            return TraceRepositoryEventBatchResult(cpuSlices: [], threadStates: [], slices: [], counters: [], densities: results)
        }
        func counters(_ query: CounterQuery) async throws -> TraceEventPage<CounterSeries> {
            detailCalls.append(ParallelDetailCall(source: .processCounter(filterID: query.filterID!, processKey: query.processKey), limit: query.limit))
            return .unavailable
        }
        func cpuSlices(_ query: CpuSliceQuery) async throws -> TraceEventPage<CpuSlice> {
            detailCalls.append(ParallelDetailCall(source: .cpu(query.cpu!), limit: query.limit)); return .unavailable
        }
        func threadStates(_ query: ThreadStateQuery) async throws -> TraceEventPage<ThreadStateInterval> {
            detailCalls.append(ParallelDetailCall(source: .threadState(query.threadKey!), limit: query.limit)); return .unavailable
        }
        func frames(_ query: TraceFrameQuery) async throws -> TraceEventPage<TraceFrame> {
            detailCalls.append(ParallelDetailCall(source: .frame(processKey: query.processKey), limit: query.limit)); return .unavailable
        }
        func slices(_ query: TraceSliceQuery) async throws -> TraceEventPage<TraceSlice> {
            let source = TraceDensitySource.namedSlice(query.threadKey)
            detailCalls.append(ParallelDetailCall(source: source, limit: query.limit))
            let i = try index(source)
            // Supplies a bounded repository page. LOD, fair limits, flattening,
            // row layout and quality facts are all computed by the real loader.
            let all = try vector.detailDepths[i].enumerated().map { offset, depth in
                TraceSlice(key: EventKey(table: .callstack, rowID: Int64(i * 100 + offset + 1)),
                    range: try TraceTimeRange(startNs: Int64(offset * 10), endNs: Int64(offset * 10 + 5)),
                    threadKey: query.threadKey, processKey: nil, name: "oracle", category: nil, depth: depth,
                    parentEventKey: nil, isAsync: false, isOpenEnded: false)
            }
            return TraceEventPage(items: Array(all.prefix(query.limit)),
                truncated: vector.truncated[i] || all.count > query.limit, dataQuality: TraceDataQuality(issues: vector.sourceIssues ?? []))
        }
        func calls() -> ([ParallelDensityCall], [ParallelDetailCall], [Int]) { (densityCalls, detailCalls, batches) }
    }
    @MainActor
    func testParallelViewerPlanOracle() async throws {
        let input = try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_VIEWER_ORACLE_INPUT"])
        let output = try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_VIEWER_ORACLE_OUTPUT"])
        let vectors = try JSONDecoder().decode([ParallelPlan].self, from: Data(contentsOf: URL(fileURLWithPath: input)))
        var results: [[String: Any]] = []
        for v in vectors {
            let request = try v.request.value(); let repository = ParallelPlanRepository(v)
            let loaded = try await TimelineSnapshotLoader().load(request, repository: repository)
            let snapshot = try XCTUnwrap(loaded)
            let (densityCalls, detailCalls, batches) = await repository.calls()
            let tracks = try snapshot.tracks.map { t -> [String: Any] in
                let primitives = try t.primitives.map { p -> [String: Any] in
                    switch p {
                    case .detail(let d): return ["kind": "detail", "eventKey": try Self.object(d.eventKey), "range": try Self.object(d.range), "depth": d.depth]
                    case .density(let d): return ["kind": "density", "bucket": try Self.object(d.bucket)]
                    }
                }
                return ["trackID": t.descriptor.id.rawValue, "y": t.y, "height": t.height, "depthRowCount": t.depthRowCount, "primitives": primitives]
            }
            let sourceFacts = snapshot.dataQuality.issues.filter { !($0.scope?.hasPrefix("timeline.") ?? false) }.map { issue -> [String: Any] in
                ["category": issue.category.rawValue, "scope": issue.scope ?? NSNull(), "count": issue.count.map { $0 as Any } ?? NSNull()]
            }
            let facts = snapshot.dataQuality.issues.filter { $0.scope?.hasPrefix("timeline.") ?? false }.map { issue -> [String: Any] in
                ["category": issue.category.rawValue, "scope": issue.scope ?? NSNull(), "count": issue.count.map { $0 as Any } ?? NSNull()]
            }
            results.append(["name": v.name, "maximumPrimitives": request.maximumPrimitives,
                "densityCalls": try Self.object(densityCalls), "detailCalls": try Self.object(detailCalls), "batches": batches,
                "tracks": tracks, "qualityFacts": facts, "sourceFacts": sourceFacts])
        }
        try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
            .write(to: URL(fileURLWithPath: output), options: .atomic)
        XCTAssertEqual(results.count, vectors.count)
    }
}

extension TimelineRenderingTests {
    private struct ParallelBoundary: Decodable {
        let name: String
        let viewport: ParallelViewport
        let selection: TraceTimeRange?
        let pressX: Double
        let anchorNs: Int64
        let mode: String
        let dragXs: [Double]
    }
    @MainActor
    func testParallelViewerBoundaryOracle() throws {
        let input = try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_VIEWER_ORACLE_INPUT"])
        let output = try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_VIEWER_ORACLE_OUTPUT"])
        let vectors = try JSONDecoder().decode([ParallelBoundary].self, from: Data(contentsOf: URL(fileURLWithPath: input)))
        var results: [[String: Any]] = []
        for v in vectors {
            let viewport = try v.viewport.value()
            let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: viewport.widthPoints, height: viewport.heightPoints))
            view.snapshot = TimelineSnapshot(viewport: viewport, tracks: [], generation: viewport.generation, dataQuality: TraceDataQuality())
            view.selection = v.selection
            func mouse(_ type: NSEvent.EventType, _ x: Double) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: viewport.heightPoints - 40),
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            view.mouseDown(with: try mouse(.leftMouseDown, v.pressX))
            let selections: [Any] = try v.dragXs.map { x in
                view.mouseDragged(with: try mouse(.leftMouseDragged, x))
                return try view.selection.map(Self.object) ?? NSNull()
            }
            results.append(["name":v.name,"selections":selections,"nonFinitePanDeltas":[
                "nan":viewport.nanosecondDelta(forPoints: .nan),
                "positiveInfinity":viewport.nanosecondDelta(forPoints: .infinity),
                "negativeInfinity":viewport.nanosecondDelta(forPoints: -.infinity)]])
        }
        try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
            .write(to: URL(fileURLWithPath: output), options: .atomic)
        XCTAssertEqual(results.count, vectors.count)
    }
}
