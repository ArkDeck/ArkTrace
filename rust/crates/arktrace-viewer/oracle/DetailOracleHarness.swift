// Appended after OracleHarness.swift in the cache copy only.
extension TimelineRenderingTests {
    private struct DetailOracleVector: Decodable, Sendable {
        let name: String
        let source: TraceDensitySource
        let range: TraceTimeRange
        let showsNestedDepth: Bool
        let cpu: [CpuSlice]
        let threadStates: [ThreadStateInterval]
        let slices: [TraceSlice]
        let counters: [CounterSeries]
        let frames: [TraceFrame]
        let truncated: Bool
        let capabilityAvailable: Bool
    }
    private actor DetailOracleRepository: TraceRepositoryProtocol {
    func cpuCatalog(_ query: TraceCPUCatalogQuery) async throws -> TraceCPUCatalog { .unavailable }

        let vector: DetailOracleVector
        init(_ vector: DetailOracleVector) { self.vector = vector }
        func page<T: Sendable>(_ items: [T]) -> TraceEventPage<T> {
            TraceEventPage(items: items, truncated: vector.truncated, capabilityAvailable: vector.capabilityAvailable)
        }
        func metadata() async throws -> TraceMetadata { try await DensityRepository(eventCount: 0).metadata() }
        func processes(_ query: ProcessQuery) async throws -> BoundedPage<TraceProcess> { BoundedPage(items: [], truncated: false) }
        func threads(_ query: ThreadQuery) async throws -> BoundedPage<TraceThread> { BoundedPage(items: [], truncated: false) }
        func summaryFacts(_ query: TraceSummaryQuery) async throws -> TraceSummaryFacts { throw CancellationError() }
        func cpuSlices(_ query: CpuSliceQuery) async throws -> TraceEventPage<CpuSlice> { page(vector.cpu) }
        func threadStates(_ query: ThreadStateQuery) async throws -> TraceEventPage<ThreadStateInterval> { page(vector.threadStates) }
        func slices(_ query: TraceSliceQuery) async throws -> TraceEventPage<TraceSlice> { page(vector.slices) }
        func counters(_ query: CounterQuery) async throws -> TraceEventPage<CounterSeries> { page(vector.counters) }
        func frames(_ query: TraceFrameQuery) async throws -> TraceEventPage<TraceFrame> { page(vector.frames) }
    }
    @MainActor
    func testActualDetailDTOOracle() async throws {
        let input = try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_VIEWER_ORACLE_INPUT"])
        let output = try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_VIEWER_ORACLE_OUTPUT"])
        let vectors = try JSONDecoder().decode([DetailOracleVector].self, from: Data(contentsOf: URL(fileURLWithPath: input)))
        var results: [[String: Any]] = []
        for v in vectors {
            let viewport = try TimelineViewport(range: v.range, widthPoints: 200, heightPoints: 1000, generation: 1)
            let descriptor = ParallelDescriptor(source: v.source, isCollapsed: false, showsNestedDepth: v.showsNestedDepth).value()
            let request = try ViewportRequest(viewport: viewport, tracks: [descriptor], pixelWidth: 400,
                generation: 1, preference: .detail, deadline: ContinuousClock.now.advanced(by: .seconds(5)))
            let loaded = try await TimelineSnapshotLoader().load(request, repository: DetailOracleRepository(v))
            let snapshot = try XCTUnwrap(loaded)
            let track = try XCTUnwrap(snapshot.tracks.first)
            let details = try track.primitives.map { p -> [String: Any] in
                guard case .detail(let d) = p else { throw CocoaError(.coderInvalidValue) }
                return ["eventKey": try Self.object(d.eventKey), "range": try Self.object(d.range), "depth": d.depth,
                    "style": TimelineNSView.detailOracleStyleName(d.category), "isOpenEnded": d.inspector?.isOpenEnded ?? false]
            }
            let qualityFacts = snapshot.dataQuality.issues.map { issue -> [String: Any] in
                ["category": issue.category.rawValue, "scope": issue.scope ?? NSNull(), "count": issue.count.map { $0 as Any } ?? NSNull()]
            }
            results.append(["name": v.name, "details": details, "depthRowCount": track.depthRowCount, "height": track.height, "qualityFacts": qualityFacts])
        }
        try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
            .write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
