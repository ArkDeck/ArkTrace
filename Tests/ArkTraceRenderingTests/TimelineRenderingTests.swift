import ArkTraceCore
import ArkTraceRendering
import XCTest

final class TimelineRenderingTests: XCTestCase {
    private actor DensityRepository: TraceRepositoryProtocol {
        let eventCount: Int64
        let delay: Duration?
        let counterPage: TraceEventPage<CounterSeries>?
        private var requestedDensitySources: [TraceDensitySource] = []

        init(
            eventCount: Int64,
            delay: Duration? = nil,
            counterPage: TraceEventPage<CounterSeries>? = nil
        ) {
            self.eventCount = eventCount
            self.delay = delay
            self.counterPage = counterPage
        }

        func metadata() async throws -> TraceMetadata { throw CancellationError() }
        func processes(_ query: ProcessQuery) async throws -> BoundedPage<TraceProcess> {
            BoundedPage(items: [], truncated: false)
        }
        func threads(_ query: ThreadQuery) async throws -> BoundedPage<TraceThread> {
            BoundedPage(items: [], truncated: false)
        }
        func summaryFacts(_ query: TraceSummaryQuery) async throws -> TraceSummaryFacts {
            throw CancellationError()
        }
        func density(_ query: TraceDensityQuery) async throws -> TraceDensityResult {
            requestedDensitySources.append(query.source)
            if let delay { try await Task.sleep(for: delay) }
            if query.bucketCount == 1 {
                return TraceDensityResult(
                    buckets: [
                        TraceDensityBucket(
                            range: query.range, eventCount: eventCount,
                            occupiedNs: nil, utilization: nil, dominantThreadKey: nil
                        )
                    ]
                )
            }
            let width = max(1, query.range.durationNs / Int64(query.bucketCount))
            let buckets = try (0..<query.bucketCount).map { index in
                let start = query.range.startNs + Int64(index) * width
                let end = index == query.bucketCount - 1
                    ? query.range.endNs : min(query.range.endNs, start + width)
                return TraceDensityBucket(
                    range: try TraceTimeRange.query(startNs: start, endNs: end),
                    eventCount: 1,
                    occupiedNs: nil,
                    utilization: nil,
                    dominantThreadKey: nil
                )
            }
            return TraceDensityResult(buckets: buckets)
        }
        func densitySources() -> [TraceDensitySource] {
            requestedDensitySources
        }
        func counters(_ query: CounterQuery) async throws -> TraceEventPage<CounterSeries> {
            counterPage ?? .unavailable
        }
    }
    func testDetailBudgetContract() {
        XCTAssertEqual(ViewportRequest.detailBudget(pixelWidth: 1), 2_000)
        XCTAssertEqual(ViewportRequest.detailBudget(pixelWidth: 1_000), 8_000)
        XCTAssertEqual(ViewportRequest.detailBudget(pixelWidth: 10_000), 20_000)
    }

    @MainActor
    func testGeometryAndHitTestingUseSameFrameAndDensityIsNotSelectable() throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 1_000, endNs: 2_000),
            widthPoints: 100,
            heightPoints: 80,
            generation: 1
        )
        let descriptor = TrackDescriptor(title: "CPU 0", source: .cpu(0))
        let key = EventKey(table: .schedSlice, rowID: 7)
        let detail = TimelinePrimitive.detail(
            TimelineDetailPrimitive(
                trackID: descriptor.id,
                eventKey: key,
                range: try TraceTimeRange(startNs: 1_250, endNs: 1_500),
                label: "worker"
            )
        )
        let density = TimelinePrimitive.density(
            TimelineDensityPrimitive(
                trackID: descriptor.id,
                bucket: TraceDensityBucket(
                    range: try TraceTimeRange.query(startNs: 1_500, endNs: 1_750),
                    eventCount: 10,
                    occupiedNs: nil,
                    utilization: nil,
                    dominantThreadKey: nil
                )
            )
        )
        let track = TimelineTrackSnapshot(
            descriptor: descriptor, y: 0, height: 28,
            primitives: [detail, density]
        )
        let snapshot = TimelineSnapshot(
            viewport: viewport,
            tracks: [track],
            generation: 1,
            dataQuality: TraceDataQuality()
        )
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
        view.snapshot = snapshot
        let frame = TimelineGeometry.frame(
            for: detail, in: track, viewport: viewport, backingScale: 2
        )
        XCTAssertEqual(view.event(at: CGPoint(x: frame.midX, y: frame.midY)), key)
        let densityFrame = TimelineGeometry.frame(
            for: density, in: track, viewport: viewport, backingScale: 2
        )
        XCTAssertNil(view.event(at: CGPoint(x: densityFrame.midX, y: densityFrame.midY)))
        XCTAssertEqual(TimelineGeometry.time(forX: 25, viewport: viewport), 1_250)
        XCTAssertEqual(TimelineGeometry.x(for: 1_250, viewport: viewport), 25, accuracy: 0.001)
    }

    func testInstantDetailRetainsDomainRangeButDrawsAtLeastOnePhysicalPixel() throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000_000),
            widthPoints: 100,
            heightPoints: 80,
            generation: 2
        )
        let descriptor = TrackDescriptor(title: "Slices", source: .namedSlice(ThreadKey(itid: 1)))
        let range = try TraceTimeRange(startNs: 500_000, endNs: 500_000)
        let primitive = TimelinePrimitive.detail(
            TimelineDetailPrimitive(
                trackID: descriptor.id,
                eventKey: EventKey(table: .callstack, rowID: 1),
                range: range
            )
        )
        let track = TimelineTrackSnapshot(
            descriptor: descriptor, y: 0, height: 28, primitives: [primitive]
        )
        let frame = TimelineGeometry.frame(
            for: primitive, in: track, viewport: viewport, backingScale: 2
        )
        XCTAssertEqual(range.startNs, range.endNs)
        XCTAssertGreaterThanOrEqual(frame.width, 0.5)
    }

    @MainActor
    func testExtremeInt64ViewportEndpointsRoundTripAndRulerDrawsWithoutTrap() throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: .max),
            widthPoints: 128,
            heightPoints: 80,
            generation: 3
        )
        XCTAssertEqual(TimelineGeometry.time(forX: 0, viewport: viewport), 0)
        XCTAssertEqual(TimelineGeometry.time(forX: 128, viewport: viewport), .max)
        XCTAssertEqual(TimelineGeometry.time(forX: 1_000, viewport: viewport), .max)
        XCTAssertEqual(TimelineGeometry.x(for: .max, viewport: viewport), 128)

        let midpoint = TimelineGeometry.time(forX: 64, viewport: viewport)
        XCTAssertGreaterThan(midpoint, 0)
        XCTAssertLessThan(midpoint, Int64.max)
        XCTAssertEqual(
            TimelineGeometry.x(for: midpoint, viewport: viewport),
            64,
            accuracy: 0.001
        )

        let snapshot = TimelineSnapshot(
            viewport: viewport,
            tracks: [],
            generation: viewport.generation,
            dataQuality: TraceDataQuality()
        )
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 128, height: 80))
        view.snapshot = snapshot
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
    }

    func testViewportRejectsNonFiniteNanosecondsPerPoint() throws {
        XCTAssertThrowsError(
            try TimelineViewport(
                range: TraceTimeRange.query(startNs: 0, endNs: .max),
                widthPoints: .leastNonzeroMagnitude,
                heightPoints: 80,
                generation: 4
            )
        ) { error in
            let typed = error as? ArkTraceError
            XCTAssertEqual(typed?.code, .invalidArgument)
            XCTAssertEqual(typed?.stage, .request)
        }
    }

    func testCounterDetailUsesPositiveAndOpenEndedDurations() async throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 100, endNs: 500),
            widthPoints: 100,
            heightPoints: 80,
            generation: 5
        )
        let series = CounterSeries(
            filterID: 7,
            name: "cycles",
            scope: .cpu,
            cpu: 0,
            processKey: nil,
            unit: "cycles",
            samples: [
                CounterSample(
                    key: EventKey(table: .measure, rowID: 1),
                    timestampNs: 150,
                    value: 1,
                    durationNs: 100
                ),
                CounterSample(
                    key: EventKey(table: .measure, rowID: 2),
                    timestampNs: 300,
                    value: 2,
                    durationNs: nil
                ),
            ]
        )
        let request = try ViewportRequest(
            viewport: viewport,
            tracks: [TrackDescriptor(title: "cycles", source: .cpuCounter(filterID: 7, cpu: 0))],
            pixelWidth: 100,
            generation: viewport.generation,
            preference: .detail,
            deadline: ContinuousClock.now.advanced(by: .seconds(5))
        )
        let snapshot = try await TimelineSnapshotLoader().load(
            request,
            repository: DensityRepository(
                eventCount: 2,
                counterPage: TraceEventPage(items: [series], truncated: false)
            )
        )
        let ranges = snapshot?.tracks.first?.primitives.compactMap { primitive in
            if case .detail(let detail) = primitive { return detail.range }
            return nil
        }
        XCTAssertEqual(ranges?.map(\.startNs), [150, 300])
        XCTAssertEqual(ranges?.map(\.endNs), [250, 500])
    }

    func testAutomaticCounterLODUsesCounterDensityEstimate() async throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 100, endNs: 500),
            widthPoints: 100,
            heightPoints: 80,
            generation: 6
        )
        let source = TraceDensitySource.cpuCounter(filterID: 7, cpu: 0)
        let repository = DensityRepository(eventCount: 1_000_000)
        let request = try ViewportRequest(
            viewport: viewport,
            tracks: [
                TrackDescriptor(
                    title: "cycles", source: .cpuCounter(filterID: 7, cpu: 0)
                )
            ],
            pixelWidth: 100,
            generation: viewport.generation,
            preference: .automatic,
            maximumPrimitives: 20,
            deadline: ContinuousClock.now.advanced(by: .seconds(5))
        )
        let snapshot = try await TimelineSnapshotLoader().load(
            request, repository: repository
        )
        XCTAssertTrue(
            snapshot?.tracks.first?.primitives.allSatisfy {
                if case .density = $0 { return true }
                return false
            } == true
        )
        let requestedSources = await repository.densitySources()
        XCTAssertEqual(requestedSources, [source, source])
    }

    func testZoomedOutLoaderUsesBoundedNonSelectableDensity() async throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000_000),
            widthPoints: 100,
            heightPoints: 80,
            generation: 1
        )
        let request = try ViewportRequest(
            viewport: viewport,
            tracks: [TrackDescriptor(title: "CPU 0", source: .cpu(0))],
            pixelWidth: 100,
            generation: 1,
            deadline: ContinuousClock.now.advanced(by: .seconds(5))
        )
        let loader = TimelineSnapshotLoader()
        let snapshot = try await loader.load(
            request, repository: DensityRepository(eventCount: 1_000_000)
        )
        XCTAssertNotNil(snapshot)
        XCTAssertLessThanOrEqual(snapshot?.primitiveCount ?? .max, 200)
        XCTAssertTrue(
            snapshot?.tracks.first?.primitives.allSatisfy {
                $0.selectableEventKey == nil
            } == true
        )
    }

    func testPrimitiveBudgetIsGlobalAcrossTracks() async throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000_000),
            widthPoints: 100,
            heightPoints: 120,
            generation: 4
        )
        let request = try ViewportRequest(
            viewport: viewport,
            tracks: (0..<4).map {
                TrackDescriptor(title: "CPU \($0)", source: .cpu(Int64($0)))
            },
            pixelWidth: 100,
            generation: 4,
            preference: .density,
            maximumPrimitives: 3,
            deadline: ContinuousClock.now.advanced(by: .seconds(5))
        )
        let snapshot = try await TimelineSnapshotLoader().load(
            request, repository: DensityRepository(eventCount: 1_000_000)
        )
        XCTAssertEqual(snapshot?.tracks.count, 4)
        XCTAssertEqual(snapshot?.primitiveCount, 3)
    }

    func testStaleGenerationCompletionIsDiscarded() async throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 100,
            heightPoints: 80,
            generation: 1
        )
        let request = try ViewportRequest(
            viewport: viewport,
            tracks: [TrackDescriptor(title: "CPU 0", source: .cpu(0))],
            pixelWidth: 100,
            generation: 1,
            deadline: ContinuousClock.now.advanced(by: .seconds(5))
        )
        let loader = TimelineSnapshotLoader()
        let task = Task {
            try await loader.load(
                request,
                repository: DensityRepository(
                    eventCount: 1_000_000,
                    delay: .milliseconds(50)
                )
            )
        }
        try await Task.sleep(for: .milliseconds(10))
        await loader.invalidate(through: 2)
        let value = try await task.value
        XCTAssertNil(value)
    }
}
