import ArkTraceCore
@testable import ArkTraceRendering
import AppKit
import SwiftUI
import XCTest

final class TimelineRenderingTests: XCTestCase {
    private actor DensityRepository: TraceRepositoryProtocol {
        let eventCount: Int64
        let delay: Duration?
        let counterPage: TraceEventPage<CounterSeries>?
        let slicePage: TraceEventPage<TraceSlice>?
        private var requestedDensitySources: [TraceDensitySource] = []

        init(
            eventCount: Int64,
            delay: Duration? = nil,
            counterPage: TraceEventPage<CounterSeries>? = nil,
            slicePage: TraceEventPage<TraceSlice>? = nil
        ) {
            self.eventCount = eventCount
            self.delay = delay
            self.counterPage = counterPage
            self.slicePage = slicePage
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
                            occupiedNs: nil, utilization: nil, dominant: nil
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
                    dominant: nil
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
        func slices(_ query: TraceSliceQuery) async throws -> TraceEventPage<TraceSlice> {
            guard let slicePage else { return .unavailable }
            let filtered = slicePage.items.filter {
                (query.eventKey == nil || $0.key == query.eventKey)
                    && (query.threadKey == nil || $0.threadKey == query.threadKey)
            }
            return TraceEventPage(
                items: Array(filtered.prefix(query.limit)),
                truncated: filtered.count > query.limit,
                dataQuality: slicePage.dataQuality
            )
        }
    }
    func testDetailBudgetContract() {
        XCTAssertEqual(ViewportRequest.detailBudget(pixelWidth: 1), 2_000)
        XCTAssertEqual(ViewportRequest.detailBudget(pixelWidth: 1_000), 8_000)
        XCTAssertEqual(ViewportRequest.detailBudget(pixelWidth: 10_000), 20_000)
    }

    @MainActor
    func testGeometryAndHitTestingUseSameFrameAndDensityCarriesNoEventKey() throws {
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
                    dominant: nil
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
        let rendered = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rendered)
        let frame = TimelineGeometry.frame(
            for: detail, in: track, viewport: viewport, backingScale: 2
        )
        XCTAssertEqual(view.event(at: CGPoint(x: frame.midX, y: frame.midY)), key)
        let densityFrame = TimelineGeometry.frame(
            for: density, in: track, viewport: viewport, backingScale: 2
        )
        let densityPoint = CGPoint(x: densityFrame.midX, y: densityFrame.midY)
        XCTAssertNil(view.event(at: densityPoint))
        // A bucket names no event, so the press is reported for the host to
        // resolve instead of answered from the snapshot.
        XCTAssertEqual(view.densityBand(at: densityPoint)?.bucket.startNs, 1_500)
        XCTAssertEqual(TimelineGeometry.time(forX: 25, viewport: viewport), 1_250)
        XCTAssertEqual(TimelineGeometry.x(for: 1_250, viewport: viewport), 25, accuracy: 0.001)
    }

    @MainActor
    func testOverlappingDetailHitUsesTheSameClosedStyleZOrderAsDrawing() throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 100, heightPoints: 80, generation: 2
        )
        let descriptor = TrackDescriptor(title: "CPU 0", source: .cpu(0))
        let accentKey = EventKey(table: .schedSlice, rowID: 1)
        let runningKey = EventKey(table: .schedSlice, rowID: 2)
        func detail(_ key: EventKey, category: String) throws -> TimelinePrimitive {
            .detail(TimelineDetailPrimitive(
                trackID: descriptor.id,
                eventKey: key,
                range: try TraceTimeRange(startNs: 100, endNs: 900),
                label: nil,
                category: category
            ))
        }
        // Snapshot order alone would put running on top. The renderer batches
        // by its closed style order, where accent is drawn last, so hit testing
        // must use that same visual order.
        let track = TimelineTrackSnapshot(
            descriptor: descriptor, y: 0, height: 28,
            primitives: [
                try detail(accentKey, category: "unknown"),
                try detail(runningKey, category: "running"),
            ]
        )
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
        view.snapshot = TimelineSnapshot(
            viewport: viewport, tracks: [track], generation: 2,
            dataQuality: TraceDataQuality()
        )
        let rendered = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rendered)
        let frame = TimelineGeometry.frame(
            for: track.primitives[0], in: track, viewport: viewport, backingScale: 2
        )
        XCTAssertEqual(view.event(at: CGPoint(x: frame.midX, y: frame.midY)), accentKey)
    }

    @MainActor
    func testTimelineKeyboardAndVoiceOverContractUsesBoundedRealEvents() throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 100,
            heightPoints: 100,
            generation: 42
        )
        let firstTrack = TrackDescriptor(title: "CPU 0", source: .cpu(0))
        let secondTrack = TrackDescriptor(
            title: "Worker thread", source: .threadState(ThreadKey(itid: 9))
        )
        let keys = [
            EventKey(table: .schedSlice, rowID: 1),
            EventKey(table: .schedSlice, rowID: 2),
            EventKey(table: .threadState, rowID: 3),
        ]
        func detail(
            _ key: EventKey,
            track: TrackDescriptor,
            start: Int64,
            name: String
        ) throws -> TimelinePrimitive {
            let range = try TraceTimeRange(startNs: start, endNs: start + 50)
            return .detail(
                TimelineDetailPrimitive(
                    trackID: track.id,
                    eventKey: key,
                    range: range,
                    label: name,
                    category: "running",
                    inspector: TraceEventInspector(
                        key: key,
                        type: key.table == .threadState ? .threadState : .cpuSlice,
                        name: name,
                        range: range,
                        semanticDurationNs: 50,
                        isOpenEnded: false,
                        processKey: ProcessKey(ipid: 4),
                        threadKey: ThreadKey(itid: 9),
                        pid: 40,
                        tid: 90,
                        cpu: key.table == .threadState ? nil : 0,
                        processName: "app",
                        threadName: "worker",
                        category: "running",
                        state: nil,
                        value: nil,
                        unit: nil
                    )
                )
            )
        }
        let snapshot = TimelineSnapshot(
            viewport: viewport,
            tracks: [
                TimelineTrackSnapshot(
                    descriptor: firstTrack, y: 0, height: 28,
                    primitives: [
                        try detail(keys[0], track: firstTrack, start: 100, name: "first"),
                        try detail(keys[1], track: firstTrack, start: 300, name: "second"),
                    ]
                ),
                TimelineTrackSnapshot(
                    descriptor: secondTrack, y: 28, height: 28,
                    primitives: [
                        try detail(keys[2], track: secondTrack, start: 310, name: "state")
                    ]
                ),
            ],
            generation: viewport.generation,
            dataQuality: TraceDataQuality()
        )
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.interactionBounds = try TraceTimeRange.query(startNs: 0, endNs: 2_000)
        var valueChangedCount = 0
        view.snapshot = snapshot
        view.selection = try TraceTimeRange.query(startNs: 250, endNs: 500)
        view.accessibilityValueChangedHook = { valueChangedCount += 1 }
        var selected: EventKey?
        var viewportIntents: [TimelineViewportIntent] = []
        var zoomedSelection = false
        var reset = false
        view.onSelectEvent = { selected = $0 }
        view.onViewportIntent = { viewportIntents.append($0) }
        view.onZoomSelection = { zoomedSelection = true }
        view.onResetViewport = { reset = true }

        view.performKeyboardCommand(.nextEvent)
        XCTAssertEqual(view.focusedEventKey, keys[0])
        XCTAssertEqual(valueChangedCount, 1)
        view.selectedEventKey = keys[0]
        XCTAssertEqual(valueChangedCount, 2)
        view.selectedEventKey = keys[0]
        XCTAssertEqual(valueChangedCount, 2)
        view.snapshot = snapshot
        XCTAssertEqual(valueChangedCount, 2)
        view.performKeyboardCommand(.nextEvent)
        XCTAssertEqual(view.focusedEventKey, keys[1])
        XCTAssertEqual(valueChangedCount, 3)
        view.performKeyboardCommand(.nextTrack)
        XCTAssertEqual(view.focusedEventKey, keys[2])
        XCTAssertEqual(view.focusedTrackID, secondTrack.id)
        XCTAssertEqual(valueChangedCount, 4)
        view.performKeyboardCommand(.selectFocusedEvent)
        XCTAssertEqual(selected, keys[2])
        XCTAssertEqual(valueChangedCount, 5)
        view.selection = try TraceTimeRange.query(startNs: 250, endNs: 500)
        XCTAssertEqual(valueChangedCount, 6)
        view.performKeyboardCommand(.panForward)
        view.performKeyboardCommand(.zoomIn)
        XCTAssertEqual(viewportIntents.count, 2)
        if case .panPoints(let points, let source) = viewportIntents[0] {
            XCTAssertEqual(points, 10, accuracy: 0.001)
            XCTAssertEqual(source, viewport)
        } else { XCTFail("Option-Left must produce bounded pan") }
        if case .zoom(let anchor, let scale, let source) = viewportIntents[1] {
            XCTAssertEqual(anchor, 375)
            XCTAssertEqual(scale, 0.5)
            XCTAssertEqual(source, viewport)
        } else { XCTFail("Plus must prefer the selected-range midpoint") }
        view.performKeyboardCommand(.zoomSelection)
        view.performKeyboardCommand(.resetViewport)
        XCTAssertTrue(zoomedSelection)
        XCTAssertTrue(reset)

        let value = try XCTUnwrap(view.accessibilityValue() as? String)
        XCTAssertTrue(value.contains("focused track Worker thread"))
        XCTAssertTrue(value.contains("selected event thread_state 3"))
        XCTAssertTrue(value.contains("selected range"))
        XCTAssertTrue(value.contains("process app"))
        XCTAssertEqual(view.accessibilityChildren()?.count, 0)
        let actions = try XCTUnwrap(view.accessibilityCustomActions())
        XCTAssertEqual(
            actions.map(\.name),
            [
                "Previous track",
                "Pan forward", "Zoom in", "Zoom out",
                "Select focused event", "Zoom selected range", "Reset viewport",
                "Clear selection",
            ]
        )
        XCTAssertGreaterThanOrEqual(
            TimelineAccessibilityLayout.minimumTargetPoints, 24
        )
        XCTAssertGreaterThanOrEqual(
            TimelineAccessibilityLayout.primaryToolbarTargetPoints, 40
        )

        view.performKeyboardCommand(.clearSelection)
        XCTAssertEqual(valueChangedCount, 7)
        XCTAssertNil(view.focusedEventKey)
        XCTAssertNil(view.selectedEventKey)
        XCTAssertNil(view.selection)
        XCTAssertNil(selected)
        view.performKeyboardCommand(.clearSelection)
        XCTAssertEqual(valueChangedCount, 7)

        XCTAssertTrue(view.performKeyboardCommand(.selectFocusedEvent))
        XCTAssertEqual(valueChangedCount, 8)
        XCTAssertTrue(view.performKeyboardCommand(.clearSelection))
        XCTAssertEqual(valueChangedCount, 9)

        let committedRange = try TraceTimeRange.query(startNs: 100, endNs: 200)
        view.selection = committedRange
        XCTAssertEqual(valueChangedCount, 10)
        view.selection = committedRange
        XCTAssertEqual(valueChangedCount, 10)
        view.selection = nil
        XCTAssertEqual(valueChangedCount, 11)
        view.selection = nil
        XCTAssertEqual(valueChangedCount, 11)
    }

    /// A thousand differently-named events must still collapse into a handful
    /// of batched fills, and the batch must be built once per snapshot
    /// generation rather than once per redraw. The palette is closed, so
    /// per-event colors cannot degrade this into a fill call per event.
    @MainActor
    func testDetailRenderingUsesClosedPaletteBucketsAndStableSnapshotCache() throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 10_000),
            widthPoints: 500,
            heightPoints: 80,
            generation: 73
        )
        let descriptor = TrackDescriptor(title: "CPU 0", source: .cpu(0))
        let primitives = try (0..<1_000).map { index -> TimelinePrimitive in
            let start = Int64(index * 10)
            // The names have to differ in letters, not only in digits: upstream
            // strips digits precisely so that `ipc::41` and `ipc::42` share a
            // color, and a digits-only fixture would prove nothing here.
            let suffix = String(UnicodeScalar(UInt8(97 + index % 26)))
            return .detail(
                TimelineDetailPrimitive(
                    trackID: descriptor.id,
                    eventKey: EventKey(table: .schedSlice, rowID: Int64(index + 1)),
                    range: try TraceTimeRange(startNs: start, endNs: start + 8),
                    label: "slice-\(suffix) \(index)",
                    category: "unknown-category-\(index)"
                )
            )
        }
        func snapshot(generation: UInt64) throws -> TimelineSnapshot {
            TimelineSnapshot(
                viewport: try TimelineViewport(
                    range: viewport.range,
                    widthPoints: viewport.widthPoints,
                    heightPoints: viewport.heightPoints,
                    generation: generation
                ),
                tracks: [
                    TimelineTrackSnapshot(
                        descriptor: descriptor,
                        y: 0,
                        height: 28,
                        primitives: primitives
                    )
                ],
                generation: generation,
                dataQuality: TraceDataQuality()
            )
        }

        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 500, height: 80))
        var detailBuilds: [Int] = []
        view.pathCacheBuildHook = { kind, bucketCount in
            if kind == "detail" { detailBuilds.append(bucketCount) }
        }
        let first = try snapshot(generation: 73)
        view.snapshot = first
        let firstBitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: firstBitmap)
        XCTAssertEqual(detailBuilds.count, 1, "one path build per snapshot generation")
        let buckets = try XCTUnwrap(detailBuilds.first)
        XCTAssertGreaterThan(buckets, 1, "differently named events must not share one fill")
        XCTAssertLessThanOrEqual(
            buckets,
            TimelinePalette.funcColors.count,
            "the palette is closed, so the fills stay bounded by it"
        )

        view.snapshot = first
        view.selectedEventKey = EventKey(table: .schedSlice, rowID: 1)
        let secondBitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: secondBitmap)
        XCTAssertEqual(detailBuilds, [buckets], "a selection redraw must reuse the cache")

        view.snapshot = try snapshot(generation: 74)
        let thirdBitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: thirdBitmap)
        XCTAssertEqual(detailBuilds, [buckets, buckets])
    }

    /// The point of the upstream palette: identity decides the color. Two
    /// events with the same name match, events with different names generally
    /// do not, and a redraw never invents a new color for the same event.
    @MainActor
    func testEventFillsFollowIdentityAcrossTracks() throws {
        let names = [
            "binder transaction", "H:RSMainThread::DoComposition", "ashmem_alloc",
            "render_service", "Choreographer#doFrame",
        ]
        let colors = try names.map { name -> TimelineColor in
            TimelineDetailPalette.color(
                for: TimelineDetailPrimitive(
                    trackID: TimelineTrackID(rawValue: "named-slice:1"),
                    eventKey: EventKey(table: .callstack, rowID: 1),
                    range: try TraceTimeRange(startNs: 0, endNs: 10),
                    label: name,
                    category: "slice"
                )
            )
        }
        // The same name on another track, another row and another time still
        // resolves to the same fill.
        for (index, name) in names.enumerated() {
            let elsewhere = TimelineDetailPalette.color(
                for: TimelineDetailPrimitive(
                    trackID: TimelineTrackID(rawValue: "named-slice:987"),
                    eventKey: EventKey(table: .callstack, rowID: 4_242),
                    range: try TraceTimeRange(startNs: 900_000, endNs: 900_010),
                    label: name,
                    category: "other-category"
                )
            )
            XCTAssertEqual(elsewhere, colors[index], "\(name) must keep its color")
        }
        XCTAssertGreaterThan(
            Set(colors).count, 1, "distinct slice names must not collapse to one color"
        )
    }

    /// A source with no per-event identity upstream — a counter series, or any
    /// bucket whose dominant row could not be read — keeps the old encoding and
    /// falls back to the owning track's identity color, so an overview of
    /// several such tracks is still readable as separate tracks.
    @MainActor
    func testDensityBandsAreColoredPerTrack() throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 100,
            heightPoints: 120,
            generation: 5
        )
        let descriptors = (0..<4).map { TrackDescriptor(title: "CPU \($0)", source: .cpu(Int64($0))) }
        let distinctTrackColors = Set(
            descriptors.map { TimelinePalette.trackIdentityColor($0.id.rawValue) }
        )
        XCTAssertEqual(
            distinctTrackColors.count, descriptors.count,
            "four CPU tracks must not share an identity color"
        )
        let tracks = try descriptors.enumerated().map { index, descriptor in
            TimelineTrackSnapshot(
                descriptor: descriptor,
                y: Double(index * 28),
                height: 28,
                primitives: [
                    .density(
                        TimelineDensityPrimitive(
                            trackID: descriptor.id,
                            bucket: TraceDensityBucket(
                                range: try TraceTimeRange.query(startNs: 0, endNs: 1_000),
                                // Same count on every track, so any batch
                                // separation comes from the color, not intensity.
                                eventCount: 64,
                                occupiedNs: nil,
                                utilization: nil,
                                dominant: nil
                            )
                        )
                    )
                ]
            )
        }
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 100, height: 120))
        var densityBuckets: [Int] = []
        view.pathCacheBuildHook = { kind, count in
            if kind == "density" { densityBuckets.append(count) }
        }
        view.snapshot = TimelineSnapshot(
            viewport: viewport,
            tracks: tracks,
            generation: viewport.generation,
            dataQuality: TraceDataQuality()
        )
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertEqual(
            densityBuckets, [descriptors.count],
            "one fill per track color, and only one build"
        )
    }

    /// An aggregate band and the events inside it resolve to the same fill, so
    /// zooming in sharpens the picture instead of repainting it — and a process
    /// or a function keeps the colour it has in SmartPerf Host.
    @MainActor
    func testDensityBandsBorrowTheDominantEventsFill() throws {
        let fallback = TimelinePalette.trackIdentityColor("named-slice:7")
        func band(_ dominant: TraceDensityIdentity?) throws -> TimelineColor {
            TimelineDensityPalette.color(
                for: TraceDensityBucket(
                    range: try TraceTimeRange.query(startNs: 0, endNs: 1_000),
                    eventCount: 8,
                    occupiedNs: nil,
                    utilization: nil,
                    dominant: dominant
                ),
                fallback: fallback
            )
        }
        let name = "H:RSMainThread::DoComposition"
        XCTAssertEqual(try band(.name(name)), TimelinePalette.color(forSliceName: name))
        XCTAssertEqual(
            try band(.processOrThread(7_437)),
            TimelinePalette.color(forProcessOrThreadID: 7_437)
        )
        XCTAssertEqual(
            try band(.threadState("Running")), TimelinePalette.stateColor(raw: "Running")
        )
        XCTAssertEqual(try band(.jank(1)), TimelinePalette.jankColor(tag: 1))
        XCTAssertEqual(try band(nil), fallback, "only an unidentified bucket falls back")
    }

    /// Density is carried by the height of a band, not by its alpha: a busy
    /// bucket is a taller block in the same colour, where it used to be a
    /// darker wash of the window background in a colour belonging to neither
    /// the trace nor the palette.
    @MainActor
    func testDensityIntensityChangesHeightAndNotColor() throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 100,
            heightPoints: 80,
            generation: 5
        )
        let descriptor = TrackDescriptor(
            title: "main", source: .namedSlice(ThreadKey(itid: 1))
        )
        func render(eventCount: Int64) throws -> NSBitmapImageRep {
            let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
            view.snapshot = TimelineSnapshot(
                viewport: viewport,
                tracks: [
                    TimelineTrackSnapshot(
                        descriptor: descriptor,
                        y: 0,
                        height: 28,
                        primitives: [
                            .density(
                                TimelineDensityPrimitive(
                                    trackID: descriptor.id,
                                    bucket: TraceDensityBucket(
                                        range: try TraceTimeRange.query(
                                            startNs: 0, endNs: 1_000
                                        ),
                                        eventCount: eventCount,
                                        occupiedNs: nil,
                                        utilization: nil,
                                        dominant: .name("draw")
                                    )
                                )
                            )
                        ]
                    )
                ],
                generation: viewport.generation,
                dataQuality: TraceDataQuality()
            )
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap
        }
        // Intensity 1 against intensity 7: the band is bottom-anchored, so the
        // sparse one covers the lower sample point only.
        let sparse = try render(eventCount: 2)
        let busy = try render(eventCount: 1_024)
        let scale = CGFloat(sparse.pixelsWide) / 100
        func pixel(_ bitmap: NSBitmapImageRep, y: CGFloat) -> NSColor? {
            bitmap.colorAt(x: Int(50 * scale), y: Int(y * scale))
        }
        let low = TimelineGeometry.rulerHeight + 21
        let high = TimelineGeometry.rulerHeight + 8
        XCTAssertEqual(
            pixel(sparse, y: low), pixel(busy, y: low),
            "a busier bucket must not change the colour of the band"
        )
        XCTAssertNotEqual(
            pixel(sparse, y: high), pixel(busy, y: high),
            "it must change how much of the row the band fills"
        )
    }

    /// Scrolling a long trace must cost what the strip shows, not what the
    /// document holds.
    ///
    /// The whole track stack is one tall view inside a scroll view, so every
    /// scroll frame arrives as a small dirty rect. One path per paint key
    /// spanning every track made CoreGraphics walk the entire trace to fill
    /// that strip, and the cost of a scroll frame grew with the number of
    /// visible lanes — on a real capture with a few hundred lanes that is the
    /// difference between a smooth scroll and a stuttering one.
    @MainActor
    func testScrollStripDrawsFarFewerFillsThanTheWholeDocument() throws {
        let trackCount = 120
        let rowHeight = 28.0
        let width = 600.0
        let documentHeight = Double(trackCount) * rowHeight + TimelineGeometry.rulerHeight
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 120_000),
            widthPoints: width,
            heightPoints: 800,
            generation: 9
        )
        let tracks = try (0..<trackCount).map { index in
            let descriptor = TrackDescriptor(
                title: "thread \(index)", source: .namedSlice(ThreadKey(itid: Int64(index)))
            )
            let primitives = try (0..<12).map { slot in
                TimelinePrimitive.detail(
                    TimelineDetailPrimitive(
                        trackID: descriptor.id,
                        eventKey: EventKey(table: .callstack, rowID: Int64(index * 12 + slot)),
                        range: try TraceTimeRange(
                            startNs: Int64(slot) * 10_000, endNs: Int64(slot) * 10_000 + 6_000
                        ),
                        label: "slice \(slot)",
                        category: "slice"
                    )
                )
            }
            return TimelineTrackSnapshot(
                descriptor: descriptor,
                y: Double(index) * rowHeight,
                height: rowHeight,
                primitives: primitives
            )
        }
        let view = TimelineNSView(
            frame: CGRect(x: 0, y: 0, width: width, height: documentHeight)
        )
        var fills: [String: Int] = [:]
        view.fillBatchHook = { kind, count in fills[kind] = count }
        view.snapshot = TimelineSnapshot(
            viewport: viewport, tracks: tracks,
            generation: viewport.generation, dataQuality: TraceDataQuality()
        )
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(documentHeight),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return XCTFail("no drawing context")
        }
        func draw(_ rect: CGRect) -> Int {
            fills.removeAll()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.saveGState()
            context.cgContext.clip(to: rect)
            view.draw(rect)
            context.cgContext.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
            return fills["detail"] ?? 0
        }
        let whole = draw(view.bounds)
        let strip = draw(CGRect(x: 0, y: 900, width: width, height: 40))
        XCTAssertGreaterThan(strip, 0, "a strip over populated tracks still fills")
        XCTAssertLessThan(
            strip * 3, whole,
            "a scroll strip must not pay for the whole document (strip=\(strip), whole=\(whole))"
        )
        // The bands a strip touches are the bands its own rows live in.
        XCTAssertEqual(
            TimelineNSView.bands(covering: CGRect(x: 0, y: 900, width: width, height: 40)),
            TimelineNSView.band(for: 900)...TimelineNSView.band(for: 940)
        )
    }

    /// A row that straddles a band boundary must be painted from either side of
    /// it. Banding is an internal bookkeeping detail; it may never turn into a
    /// seam the user can see while scrolling.
    @MainActor
    func testRowsCrossingABandBoundaryAreDrawnFromBothSides() throws {
        let boundary = TimelineNSView.pathBandHeight
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 200,
            heightPoints: 400,
            generation: 4
        )
        let descriptor = TrackDescriptor(
            title: "straddler", source: .namedSlice(ThreadKey(itid: 1))
        )
        // A tall row centred on the boundary, so its fill starts in one band
        // and ends in the next.
        let track = TimelineTrackSnapshot(
            descriptor: descriptor,
            y: Double(boundary - TimelineGeometry.rulerHeight - 40),
            height: 80,
            primitives: [
                .detail(
                    TimelineDetailPrimitive(
                        trackID: descriptor.id,
                        eventKey: EventKey(table: .callstack, rowID: 1),
                        range: try TraceTimeRange(startNs: 0, endNs: 1_000),
                        label: nil,
                        category: "slice"
                    )
                )
            ]
        )
        let view = TimelineNSView(
            frame: CGRect(x: 0, y: 0, width: 200, height: Double(boundary) + 200)
        )
        var fills: [String: Int] = [:]
        view.fillBatchHook = { kind, count in fills[kind] = count }
        view.snapshot = TimelineSnapshot(
            viewport: viewport, tracks: [track],
            generation: viewport.generation, dataQuality: TraceDataQuality()
        )
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: Int(boundary) + 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return XCTFail("no drawing context")
        }
        func fillCount(in rect: CGRect) -> Int {
            fills.removeAll()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.saveGState()
            context.cgContext.clip(to: rect)
            view.draw(rect)
            context.cgContext.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
            return fills["detail"] ?? 0
        }
        XCTAssertGreaterThan(
            fillCount(in: CGRect(x: 0, y: boundary - 20, width: 200, height: 10)), 0,
            "the half above the boundary still paints"
        )
        XCTAssertGreaterThan(
            fillCount(in: CGRect(x: 0, y: boundary + 10, width: 200, height: 10)), 0,
            "and so does the half below it"
        )
    }

    /// The hover tracking area is built once and then left alone.
    ///
    /// AppKit calls `updateTrackingAreas()` on every geometry change, which
    /// inside a scroll view means every frame of every scroll. Removing and
    /// re-adding the area each time left the window's tracking regions
    /// permanently invalid, paid for by a recursive walk of the whole window's
    /// view tree per display cycle. Building it once is only correct because
    /// `.inVisibleRect` makes the area follow the visible rect on its own and
    /// ignore the rect it was given, so both halves are asserted together.
    @MainActor
    func testTheHoverTrackingAreaIsBuiltOnceAndFollowsTheVisibleRect() throws {
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        view.updateTrackingAreas()
        let area = try XCTUnwrap(view.trackingAreas.first)
        XCTAssertEqual(view.trackingAreas.count, 1)
        XCTAssertTrue(
            area.options.contains(.inVisibleRect),
            "an area that did not follow the visible rect would have to be rebuilt"
        )
        // What a scroll does: change the geometry, over and over.
        view.setFrameSize(NSSize(width: 200, height: 4_000))
        view.updateTrackingAreas()
        view.updateTrackingAreas()
        XCTAssertEqual(view.trackingAreas.count, 1)
        XCTAssertIdentical(view.trackingAreas.first, area, "the very same area")
    }

    /// SwiftUI re-applies every stored property on any state change in the
    /// window, so the same snapshot arrives at the canvas again and again --
    /// during a scroll, many times a second. A generation is the identity of a
    /// rendered frame, so an unchanged one would draw the same pixels: it must
    /// not ask for a redraw at all.
    ///
    /// The view is hosted in a window because that is where AppKit records the
    /// request, and `display()` is how the test consumes one: off-screen it
    /// clears the flag without painting, which is all this needs. The last
    /// third is the control -- a new generation still asks -- so the guard
    /// cannot pass by making the canvas inert.
    @MainActor
    func testReapplyingTheSameSnapshotAsksForNoRedraw() throws {
        func snapshot(generation: UInt64) throws -> TimelineSnapshot {
            let viewport = try TimelineViewport(
                range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
                widthPoints: 200,
                heightPoints: 80,
                generation: generation
            )
            let descriptor = TrackDescriptor(
                title: "main", source: .namedSlice(ThreadKey(itid: 1))
            )
            return TimelineSnapshot(
                viewport: viewport,
                tracks: [
                    TimelineTrackSnapshot(
                        descriptor: descriptor, y: 0, height: 28,
                        primitives: [
                            .detail(
                                TimelineDetailPrimitive(
                                    trackID: descriptor.id,
                                    eventKey: EventKey(table: .callstack, rowID: 1),
                                    range: try TraceTimeRange(startNs: 100, endNs: 900),
                                    label: "work",
                                    category: "slice"
                                )
                            )
                        ]
                    )
                ],
                generation: generation,
                dataQuality: TraceDataQuality()
            )
        }
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(view)

        let first = try snapshot(generation: 1)
        view.snapshot = first
        XCTAssertTrue(view.needsDisplay, "the first snapshot is a frame to draw")
        view.display()
        XCTAssertFalse(view.needsDisplay, "the request was consumed")

        // What SwiftUI does on any state change in the window: the same value,
        // assigned again.
        view.snapshot = first
        XCTAssertFalse(
            view.needsDisplay, "an unchanged generation draws the same pixels"
        )

        view.snapshot = try snapshot(generation: 2)
        XCTAssertTrue(view.needsDisplay, "a new generation is a new frame")
    }

    /// A zoom or a pan must land on screen in the frame it was pressed in.
    /// The loading generation carries the viewport the user asked for and the
    /// primitives already in hand, so drawing it rescales what is there;
    /// drawing the previous generation instead -- which is what this did --
    /// left `W` and `S` doing visibly nothing until a query came back.
    @MainActor
    func testAPendingViewportIsDrawnBeforeItsQueryReturns() throws {
        let wide = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 200, heightPoints: 80, generation: 1
        )
        let descriptor = TrackDescriptor(title: "CPU 0", source: .cpu(0))
        let key = EventKey(table: .schedSlice, rowID: 7)
        let track = TimelineTrackSnapshot(
            descriptor: descriptor, y: 0, height: 28,
            primitives: [
                .detail(
                    TimelineDetailPrimitive(
                        trackID: descriptor.id,
                        eventKey: key,
                        range: try TraceTimeRange(startNs: 400, endNs: 600),
                        label: "worker"
                    )
                )
            ]
        )
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        view.snapshot = TimelineSnapshot(
            viewport: wide, tracks: [track], generation: 1, dataQuality: TraceDataQuality()
        )
        let body = TimelineGeometry.rulerHeight + 8
        // 400…600 ns of 0…1000 is x 80…120, so x 190 is well clear of it.
        XCTAssertEqual(view.event(at: CGPoint(x: 100, y: body)), key)
        XCTAssertNil(view.event(at: CGPoint(x: 190, y: body)))

        // `W`: the viewport narrows to the event's own range while the query
        // for it is still in flight, and the event now spans the whole width.
        let zoomed = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 400, endNs: 600),
            widthPoints: 200, heightPoints: 80, generation: 2
        )
        view.snapshot = TimelineSnapshot(
            viewport: zoomed, tracks: [track], generation: 2,
            dataQuality: TraceDataQuality(), isLoading: true
        )
        XCTAssertEqual(
            view.event(at: CGPoint(x: 190, y: body)), key,
            "the pending viewport is what the frame draws and hit-tests"
        )
    }

    /// The other half of drawing a carried-over generation: its primitives are
    /// mostly outside the new viewport, and `x(for:viewport:)` clamps rather
    /// than dropping, so without a range test they would pile up against the
    /// edges as a wall of minimum-width slivers -- and be hit-testable there.
    @MainActor
    func testPrimitivesOutsideTheViewportAreNeitherDrawnNorHitTested() throws {
        let descriptor = TrackDescriptor(title: "CPU 0", source: .cpu(0))
        let track = TimelineTrackSnapshot(
            descriptor: descriptor, y: 0, height: 28,
            primitives: [
                .detail(
                    TimelineDetailPrimitive(
                        trackID: descriptor.id,
                        eventKey: EventKey(table: .schedSlice, rowID: 7),
                        range: try TraceTimeRange(startNs: 100, endNs: 300),
                        label: "worker"
                    )
                )
            ]
        )
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        var frames: [Int] = []
        view.labelRenderHook = { drawn, _ in frames.append(drawn) }
        view.snapshot = TimelineSnapshot(
            viewport: try TimelineViewport(
                range: TraceTimeRange.query(startNs: 800, endNs: 1_000),
                widthPoints: 200, heightPoints: 80, generation: 2
            ),
            tracks: [track],
            generation: 2,
            dataQuality: TraceDataQuality(),
            isLoading: true
        )
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertEqual(frames, [0], "an event outside the viewport draws no label")
        let body = TimelineGeometry.rulerHeight + 8
        XCTAssertNil(
            view.event(at: CGPoint(x: 0.5, y: body)),
            "and is not hit-testable against the edge it would have clamped to"
        )
    }

    /// The claim `isOpaque` makes, checked rather than asserted: every pixel of
    /// a redrawn rect is painted by the view. It is what lets the clip view
    /// copy the screen and redraw only the strip a scroll exposed.
    @MainActor
    func testTheViewPaintsEveryPixelItClaimsToOwn() throws {
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 60, height: 40))
        XCTAssertTrue(view.isOpaque)
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 40,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )
        )
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Ink the whole surface with something the view never draws, so any
        // pixel it leaves alone stands out.
        context.cgContext.setFillColor(NSColor.magenta.cgColor)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        view.draw(view.bounds)
        context.cgContext.flush()
        NSGraphicsContext.restoreGraphicsState()
        for point in [(0, 0), (59, 0), (0, 39), (59, 39), (30, 20)] {
            let color = try XCTUnwrap(bitmap.colorAt(x: point.0, y: point.1))
            XCTAssertLessThan(
                abs(color.redComponent - color.greenComponent), 0.2,
                "pixel \(point) was left transparent: magenta shows through"
            )
        }
    }

    /// Scrolling exposes a strip, and a strip must cost a strip. Labels are
    /// the one thing a frame pays for per primitive -- CoreGraphics throws the
    /// fills outside the dirty rect away for the price of a path traversal,
    /// but a string outside it is laid out and rendered in full first -- so a
    /// zoomed-in trace used to redraw every label it had in order to fill a
    /// forty-point strip, and scrolling crawled.
    @MainActor
    func testAStripRedrawDrawsOnlyTheLabelsInsideIt() throws {
        let trackCount = 6
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 200,
            heightPoints: Double(trackCount) * 28 + TimelineGeometry.rulerHeight,
            generation: 1
        )
        let tracks = try (0..<trackCount).map { index in
            let descriptor = TrackDescriptor(title: "CPU \(index)", source: .cpu(Int64(index)))
            return TimelineTrackSnapshot(
                descriptor: descriptor,
                y: Double(index) * 28,
                height: 28,
                primitives: [
                    .detail(
                        TimelineDetailPrimitive(
                            trackID: descriptor.id,
                            eventKey: EventKey(table: .schedSlice, rowID: Int64(index + 1)),
                            range: try TraceTimeRange(startNs: 100, endNs: 900),
                            label: "worker \(index)"
                        )
                    )
                ]
            )
        }
        let view = TimelineNSView(
            frame: CGRect(x: 0, y: 0, width: 200, height: viewport.heightPoints)
        )
        var drawn: [Int] = []
        view.labelRenderHook = { drawnLabels, _ in drawn.append(drawnLabels) }
        view.snapshot = TimelineSnapshot(
            viewport: viewport, tracks: tracks, generation: 1, dataQuality: TraceDataQuality()
        )
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertEqual(drawn, [trackCount], "a whole-view redraw draws every label")

        drawn.removeAll()
        let strip = TimelineGeometry.trackFrame(tracks[2])
        view.cacheDisplay(in: strip, to: bitmap)
        XCTAssertEqual(
            drawn, [1],
            "a strip covering one track draws that track's label and no others"
        )
    }

    /// The layout outlives the frame that paid for it, and one name shared by
    /// many events is laid out once: a trace repeats its function names
    /// thousands of times, and text layout is what a frame cannot afford.
    @MainActor
    func testLabelLayoutIsSharedByNameAndSurvivesTheFrame() throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 200,
            heightPoints: 50,
            generation: 1
        )
        let descriptor = TrackDescriptor(title: "CPU 0", source: .cpu(0))
        let labels = ["render", "render", "render", "layout"]
        let primitives = try labels.enumerated().map { index, label in
            TimelinePrimitive.detail(
                TimelineDetailPrimitive(
                    trackID: descriptor.id,
                    eventKey: EventKey(table: .schedSlice, rowID: Int64(index + 1)),
                    range: try TraceTimeRange(
                        startNs: Int64(index) * 250, endNs: Int64(index) * 250 + 249
                    ),
                    label: label
                )
            )
        }
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 200, height: 50))
        var frames: [(drawn: Int, laidOut: Int)] = []
        view.labelRenderHook = { frames.append((drawn: $0, laidOut: $1)) }
        view.snapshot = TimelineSnapshot(
            viewport: viewport,
            tracks: [
                TimelineTrackSnapshot(
                    descriptor: descriptor, y: 0, height: 28, primitives: primitives
                )
            ],
            generation: 1,
            dataQuality: TraceDataQuality()
        )
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.drawn, 4, "every event wide enough carries its label")
        XCTAssertEqual(
            frames.first?.laidOut, 2,
            "one layout per distinct name, not one per event"
        )

        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertEqual(frames.last?.drawn, 4)
        XCTAssertEqual(frames.last?.laidOut, 0, "a second frame lays out nothing")
    }

    @MainActor
    func testAccessibilityActionsExposeOnlyCommandsThatCanChangeState() throws {
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
        XCTAssertEqual(view.accessibilityCustomActions()?.count, 0)
        XCTAssertFalse(view.performKeyboardCommand(.clearSelection))
        XCTAssertFalse(view.performKeyboardCommand(.zoomSelection))

        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 100,
            heightPoints: 80,
            generation: 90
        )
        let descriptor = TrackDescriptor(title: "Empty", source: .cpu(0))
        view.snapshot = TimelineSnapshot(
            viewport: viewport,
            tracks: [
                TimelineTrackSnapshot(
                    descriptor: descriptor, y: 0, height: 28, primitives: []
                )
            ],
            generation: viewport.generation,
            dataQuality: TraceDataQuality()
        )
        view.onViewportIntent = { _ in }
        view.onResetViewport = {}
        view.interactionBounds = viewport.range
        XCTAssertEqual(
            view.accessibilityCustomActions()?.map(\.name),
            ["Zoom in"]
        )
        XCTAssertFalse(view.performKeyboardCommand(.selectFocusedEvent))
        XCTAssertFalse(view.performKeyboardCommand(.zoomSelection))

        let minimumViewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1),
            widthPoints: 100, heightPoints: 80, generation: 91
        )
        view.snapshot = TimelineSnapshot(
            viewport: minimumViewport,
            tracks: [TimelineTrackSnapshot(
                descriptor: descriptor, y: 0, height: 28, primitives: []
            )],
            generation: minimumViewport.generation,
            dataQuality: TraceDataQuality()
        )
        view.interactionBounds = minimumViewport.range
        XCTAssertEqual(view.accessibilityCustomActions()?.map(\.name), [])
        XCTAssertFalse(view.performKeyboardCommand(.panBackward))
        XCTAssertFalse(view.performKeyboardCommand(.panForward))
        XCTAssertFalse(view.performKeyboardCommand(.zoomIn))
        XCTAssertFalse(view.performKeyboardCommand(.zoomOut))
        XCTAssertFalse(view.performKeyboardCommand(.resetViewport))
    }

    @MainActor
    func testHostedTimelineRestoresRealWindowFirstResponderAndTabOrder() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        let timeline = TimelineNSView(frame: NSRect(x: 0, y: 40, width: 480, height: 200))
        timeline.setAccessibilityIdentifier("arktrace.timeline")
        let search = NSSearchField(frame: NSRect(x: 0, y: 0, width: 240, height: 32))
        container.addSubview(timeline)
        container.addSubview(search)
        window.contentView = container
        timeline.nextKeyView = search
        search.nextKeyView = timeline

        XCTAssertTrue(window.makeFirstResponder(search))
        XCTAssertTrue(window.firstResponder === search.currentEditor() || window.firstResponder === search)
        timeline.requestKeyboardFocus()
        XCTAssertTrue(window.firstResponder === timeline)
        XCTAssertTrue(timeline.nextValidKeyView === search)
        XCTAssertTrue(search.nextValidKeyView === timeline)
        XCTAssertEqual(timeline.accessibilityIdentifier(), "arktrace.timeline")
    }

    @MainActor
    func testHostedSwiftUIControlsHaveNonOverlappingMinimumHitFrames() {
        let recorder = HostedTargetFrameRecorder()
        let hosting = NSHostingView(rootView: HostedTargetFixture(recorder: recorder))
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 80)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let frames = recorder.frames
        XCTAssertEqual(Set(frames.keys), ["open", "toggle", "search"])
        for frame in frames.values {
            XCTAssertGreaterThanOrEqual(
                frame.width, TimelineAccessibilityLayout.minimumTargetPoints
            )
            XCTAssertGreaterThanOrEqual(
                frame.height, TimelineAccessibilityLayout.minimumTargetPoints
            )
        }
        let ordered = frames.values.sorted { $0.minX < $1.minX }
        for pair in zip(ordered, ordered.dropFirst()) {
            XCTAssertFalse(pair.0.intersects(pair.1))
        }
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

    func testPanDeltaSaturatesAndRejectsNonFinitePointDeltas() throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: .max),
            widthPoints: 128,
            heightPoints: 80,
            generation: 1
        )
        // AppKit supplies the point delta. A non-finite value is not a pan and
        // must not reach the Int64 conversion: NaN compares false against both
        // saturation bounds, so an unguarded conversion would trap.
        XCTAssertEqual(viewport.nanosecondDelta(forPoints: .nan), 0)
        XCTAssertEqual(viewport.nanosecondDelta(forPoints: .signalingNaN), 0)
        XCTAssertEqual(viewport.nanosecondDelta(forPoints: .infinity), .max)
        XCTAssertEqual(viewport.nanosecondDelta(forPoints: -.infinity), .min)
        XCTAssertEqual(viewport.nanosecondDelta(forPoints: 0), 0)

        let fine = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 100,
            heightPoints: 80,
            generation: 2
        )
        XCTAssertEqual(fine.nanosecondDelta(forPoints: 10), 100)
        XCTAssertEqual(fine.nanosecondDelta(forPoints: -10), -100)
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

    func testPanAndCursorAnchoredZoomAreOverflowSafe() throws {
        let bounds = try TraceTimeRange.query(startNs: 0, endNs: .max)
        let range = try TraceTimeRange.query(
            startNs: 1_000_000_000,
            endNs: 5_000_000_000
        )
        XCTAssertEqual(
            try TimelineInteraction.pan(range: range, deltaNs: .min, within: bounds)
                .startNs,
            0
        )
        let right = try TimelineInteraction.pan(
            range: range, deltaNs: .max, within: bounds
        )
        XCTAssertEqual(right.endNs, .max)

        let anchor: Int64 = 2_000_000_000
        let zoomed = try TimelineInteraction.zoom(
            range: range,
            anchorNs: anchor,
            scale: 0.25,
            within: bounds
        )
        XCTAssertEqual(zoomed.durationNs, 1_000_000_000)
        let oldFraction = Double(anchor - range.startNs) / Double(range.durationNs)
        let newFraction = Double(anchor - zoomed.startNs) / Double(zoomed.durationNs)
        XCTAssertEqual(oldFraction, newFraction, accuracy: 0.000_001)
        XCTAssertEqual(
            try TimelineInteraction.zoom(
                range: bounds, anchorNs: .max, scale: 20, within: bounds
            ),
            bounds
        )
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
        let inspectors = snapshot?.tracks.first?.primitives.compactMap { primitive in
            if case .detail(let detail) = primitive { return detail.inspector }
            return nil
        }
        XCTAssertEqual(inspectors?.map(\.semanticDurationNs), [100, nil])
        XCTAssertEqual(inspectors?.map(\.isOpenEnded), [false, true])
    }

    func testFocusedNamedSliceIsReservedBeyondOrdinaryDetailPrefix() async throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 100,
            heightPoints: 80,
            generation: 7
        )
        let thread = ThreadKey(itid: 9)
        var rows: [TraceSlice] = []
        for row in 1...3 {
            let rowID = Int64(row)
            let startNs = rowID * 10
            rows.append(try TraceSlice(
                key: EventKey(table: .callstack, rowID: Int64(row)),
                range: TraceTimeRange(startNs: startNs, endNs: startNs + 5),
                threadKey: thread,
                processKey: ProcessKey(ipid: 4),
                pid: 40,
                tid: 90,
                processName: "app",
                threadName: "worker",
                name: "slice \(rowID)",
                category: "work",
                depth: 0,
                parentEventKey: nil,
                isAsync: false,
                isOpenEnded: false
            ))
        }
        let focused = rows[2].key
        let request = try ViewportRequest(
            viewport: viewport,
            tracks: [TrackDescriptor(title: "worker", source: .namedSlice(thread))],
            pixelWidth: 100,
            generation: viewport.generation,
            preference: .detail,
            maximumPrimitives: 2,
            focusedEventKey: focused,
            deadline: ContinuousClock.now.advanced(by: .seconds(5))
        )
        let snapshot = try await TimelineSnapshotLoader().load(
            request,
            repository: DensityRepository(
                eventCount: 3,
                slicePage: TraceEventPage(items: rows, truncated: false)
            )
        )
        let keys = snapshot?.tracks.first?.primitives.compactMap { primitive in
            primitive.selectableEventKey
        }
        XCTAssertEqual(keys?.first, focused)
        XCTAssertTrue(keys?.contains(focused) == true)
        XCTAssertEqual(snapshot?.tracks.first?.primitives.first.flatMap {
            if case .detail(let detail) = $0 { return detail.inspector?.processName }
            return nil
        }, "app")
    }

    func testAutomaticCounterLODReusesBoundedDensityCandidate() async throws {
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
        XCTAssertEqual(requestedSources, [source])
    }

    func testExplicitDetailRequestSkipsTheDensityEstimateEntirely() async throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 100, endNs: 500),
            widthPoints: 100,
            heightPoints: 80,
            generation: 9
        )
        let slice = TraceSlice(
            key: EventKey(table: .callstack, rowID: 3),
            range: try TraceTimeRange(startNs: 150, endNs: 250),
            threadKey: ThreadKey(itid: 1),
            processKey: nil,
            name: "revealed",
            category: nil,
            depth: nil,
            parentEventKey: nil,
            isAsync: false,
            isOpenEnded: false
        )
        let repository = DensityRepository(
            eventCount: 1,
            slicePage: TraceEventPage(items: [slice], truncated: false)
        )
        let request = try ViewportRequest(
            viewport: viewport,
            tracks: [
                TrackDescriptor(title: "thread 1", source: .namedSlice(ThreadKey(itid: 1)))
            ],
            pixelWidth: 100,
            generation: viewport.generation,
            preference: .detail,
            maximumPrimitives: 20,
            deadline: ContinuousClock.now.advanced(by: .seconds(5))
        )
        let snapshot = try await TimelineSnapshotLoader().load(
            request, repository: repository
        )

        // Density is the LOD estimate. A caller that already asked for detail
        // -- search reveal does -- used to pay for the aggregate anyway and
        // then discard it, doubling the indexed scans per visible track.
        let requestedSources = await repository.densitySources()
        XCTAssertEqual(requestedSources, [], "detail mode must not estimate")
        XCTAssertEqual(snapshot?.tracks.first?.primitives.count, 1)
        XCTAssertTrue(
            snapshot?.tracks.first?.primitives.allSatisfy {
                if case .detail = $0 { return true }
                return false
            } == true
        )
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

    /// Visible track count is a UI property; the repository event batch caps at
    /// `maximumQueryCount`. A trace with many counter series has more visible
    /// tracks than that cap, and the density prefetch must chunk rather than
    /// fail the whole viewport -- otherwise the window shows "Trace unavailable".
    func testDensityPrefetchChunksBeyondTheEventBatchQueryCap() async throws {
        let trackCount = TraceRepositoryEventBatch.maximumQueryCount * 2 + 1
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000_000),
            widthPoints: 100,
            heightPoints: 2_000,
            generation: 7
        )
        let request = try ViewportRequest(
            viewport: viewport,
            tracks: (0..<trackCount).map {
                TrackDescriptor(
                    title: "Counter \($0)",
                    source: .processCounter(
                        filterID: Int64($0), processKey: ProcessKey(ipid: 1)
                    )
                )
            },
            pixelWidth: 100,
            generation: 7,
            preference: .density,
            maximumPrimitives: trackCount * 4,
            deadline: ContinuousClock.now.advanced(by: .seconds(5))
        )
        let snapshot = try await TimelineSnapshotLoader().load(
            request, repository: DensityRepository(eventCount: 1_000_000)
        )
        XCTAssertEqual(snapshot?.tracks.count, trackCount)
        // Each track kept its own density result rather than being shifted by a
        // chunk boundary.
        XCTAssertTrue(snapshot?.tracks.allSatisfy { !$0.primitives.isEmpty } == true)
    }

    /// Upstream labels a CPU slice with its process and thread
    /// (`ProcedureWorkerCPU.ts:282-320`), not a bare TID. Each name is
    /// optional, so the fallback chain has to keep producing something
    /// identifying -- and must never produce an empty label.
    func testCPUSliceLabelFallsBackThroughProcessThreadAndTID() {
        XCTAssertEqual(
            TimelineSnapshotLoader.cpuSliceLabel(
                processName: "render_service", threadName: "RSRenderThread", tid: 645
            ),
            "render_service · RSRenderThread [645]"
        )
        XCTAssertEqual(
            TimelineSnapshotLoader.cpuSliceLabel(
                processName: "render_service", threadName: nil, tid: 645
            ),
            "render_service [645]"
        )
        XCTAssertEqual(
            TimelineSnapshotLoader.cpuSliceLabel(
                processName: nil, threadName: "RSRenderThread", tid: 645
            ),
            "RSRenderThread [645]"
        )
        XCTAssertEqual(
            TimelineSnapshotLoader.cpuSliceLabel(
                processName: nil, threadName: nil, tid: 645
            ),
            "TID 645"
        )
        // An empty stored name is not an identifying name.
        XCTAssertEqual(
            TimelineSnapshotLoader.cpuSliceLabel(
                processName: "", threadName: "", tid: 645
            ),
            "TID 645"
        )
        // Nothing to say at all yields no label rather than a blank one.
        XCTAssertNil(
            TimelineSnapshotLoader.cpuSliceLabel(
                processName: nil, threadName: nil, tid: nil
            )
        )
        XCTAssertEqual(
            TimelineSnapshotLoader.cpuSliceLabel(
                processName: "render_service", threadName: "RSRenderThread", tid: nil
            ),
            "render_service · RSRenderThread"
        )
    }

    /// Depth splits a named-slice track into rows (upstream
    /// `ProcedureWorkerFunc.ts:237` `depth * 18 + 3`). The invariant that
    /// matters is AT-RENDER-003: the frame the renderer draws and the frame
    /// hit-testing uses come from one function, so a click on a nested slice
    /// selects that slice and not the one drawn above or below it.
    @MainActor
    func testNestedDepthRowsAreDistinctAndHitTestMatchesTheDrawnFrame() throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 1_000, endNs: 2_000),
            widthPoints: 100,
            heightPoints: 200,
            generation: 1
        )
        let descriptor = TrackDescriptor(
            title: "main", source: .namedSlice(ThreadKey(itid: 1))
        )
        // Nested calls: the child is fully inside the parent, so only depth
        // separates them. Without depth rows they would overlap exactly.
        func slice(_ rowID: Int64, _ depth: Int) throws -> TimelinePrimitive {
            .detail(
                TimelineDetailPrimitive(
                    trackID: descriptor.id,
                    eventKey: EventKey(table: .callstack, rowID: rowID),
                    range: try TraceTimeRange(startNs: 1_200, endNs: 1_800),
                    label: "frame",
                    category: "slice",
                    depth: depth
                )
            )
        }
        let primitives = [try slice(1, 0), try slice(2, 1), try slice(3, 2)]
        let rowCount = 3
        let track = TimelineTrackSnapshot(
            descriptor: descriptor,
            y: 0,
            height: TimelineGeometry.trackHeight(depthRowCount: rowCount),
            primitives: primitives,
            depthRowCount: rowCount
        )
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 100, height: 200))
        view.snapshot = TimelineSnapshot(
            viewport: viewport,
            tracks: [track],
            generation: 1,
            dataQuality: TraceDataQuality()
        )

        var frames: [CGRect] = []
        for (index, primitive) in primitives.enumerated() {
            let frame = TimelineGeometry.frame(
                for: primitive, in: track, viewport: viewport, backingScale: 2
            )
            frames.append(frame)
            guard case .detail(let detail) = primitive else { return XCTFail() }
            // The drawn frame is what hit-testing resolves, within the 1 point
            // AT-RENDER-003 allows.
            XCTAssertEqual(
                view.event(at: CGPoint(x: frame.midX, y: frame.midY)),
                detail.eventKey,
                "depth \(index) frame is not its own hit target"
            )
        }
        // Rows are disjoint and ordered top to bottom.
        XCTAssertEqual(frames.map(\.minY), frames.map(\.minY).sorted())
        for (shallow, deep) in zip(frames, frames.dropFirst()) {
            XCTAssertFalse(shallow.intersects(deep))
            XCTAssertEqual(deep.minY, shallow.maxY, accuracy: 0.001)
        }
        // Every row stays inside the track it belongs to.
        let trackFrame = TimelineGeometry.trackFrame(track)
        for frame in frames {
            XCTAssertGreaterThanOrEqual(frame.minY, trackFrame.minY)
            XCTAssertLessThanOrEqual(frame.maxY, trackFrame.maxY)
        }
    }

    /// End-to-end through the real loader: a nested call stack has to arrive as
    /// per-depth rows with a track tall enough to hold them, and flattening the
    /// track has to put everything back on one row without losing slices.
    func testLoaderBuildsDepthRowsAndFlatteningReturnsToOneBand() async throws {
        let threadKey = ThreadKey(itid: 1)
        // A 5-deep stack, each level nested inside the previous one.
        let slices = try (0..<5).map { depth in
            TraceSlice(
                key: EventKey(table: .callstack, rowID: Int64(depth) + 1),
                range: try TraceTimeRange(
                    startNs: 100 + Int64(depth) * 10,
                    endNs: 900 - Int64(depth) * 10
                ),
                threadKey: threadKey,
                processKey: ProcessKey(ipid: 1),
                pid: 1, tid: 100, processName: "p", threadName: "t",
                name: "frame\(depth)", category: "slice", depth: Int64(depth),
                parentEventKey: nil, isAsync: false, isOpenEnded: false
            )
        }
        let repository = DensityRepository(
            eventCount: 5,
            slicePage: TraceEventPage(items: slices, truncated: false)
        )
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 400,
            heightPoints: 400,
            generation: 1
        )

        func snapshot(showsNestedDepth: Bool, generation: UInt64) async throws
            -> TimelineTrackSnapshot
        {
            let request = try ViewportRequest(
                viewport: try TimelineViewport(
                    range: viewport.range,
                    widthPoints: 400,
                    heightPoints: 400,
                    generation: generation
                ),
                tracks: [
                    TrackDescriptor(
                        title: "t",
                        source: .namedSlice(threadKey),
                        showsNestedDepth: showsNestedDepth
                    )
                ],
                pixelWidth: 400,
                generation: generation,
                preference: .detail,
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
            let loaded = try await TimelineSnapshotLoader().load(
                request, repository: repository
            )
            return try XCTUnwrap(loaded?.tracks.first)
        }

        let expanded = try await snapshot(showsNestedDepth: true, generation: 1)
        XCTAssertEqual(expanded.depthRowCount, 5)
        XCTAssertEqual(
            expanded.height, TimelineGeometry.trackHeight(depthRowCount: 5)
        )
        XCTAssertGreaterThan(expanded.height, 28)
        let depths = expanded.primitives.compactMap { primitive -> Int? in
            guard case .detail(let detail) = primitive else { return nil }
            return detail.depth
        }
        XCTAssertEqual(depths.sorted(), [0, 1, 2, 3, 4])
        // Distinct rows: the staircase, not one solid band.
        let rows = Set(
            expanded.primitives.map {
                TimelineGeometry.frame(
                    for: $0, in: expanded, viewport: viewport, backingScale: 2
                ).minY
            }
        )
        XCTAssertEqual(rows.count, 5)

        let flattened = try await snapshot(showsNestedDepth: false, generation: 2)
        XCTAssertEqual(flattened.depthRowCount, 1)
        XCTAssertEqual(flattened.height, 28)
        // Flattening changes layout only -- every slice is still present.
        XCTAssertEqual(flattened.primitives.count, expanded.primitives.count)
        let flattenedRows = Set(
            flattened.primitives.map {
                TimelineGeometry.frame(
                    for: $0, in: flattened, viewport: viewport, backingScale: 2
                ).minY
            }
        )
        XCTAssertEqual(flattenedRows.count, 1)
    }

    /// DESIGN §13.5 / AT-RENDER-008: fill batches are bounded by the palette,
    /// not by event count. Depth multiplies how many primitives a single track
    /// can hold, so the bound has to survive a deep stack too — batching keys
    /// on colour, and depth deliberately does not reach the colour.
    @MainActor
    func testDeepStackKeepsFillBatchesBoundedByThePalette() throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 20_000),
            widthPoints: 500,
            heightPoints: 800,
            generation: 91
        )
        let descriptor = TrackDescriptor(
            title: "deep", source: .namedSlice(ThreadKey(itid: 1))
        )
        let rowCount = 16
        // 20k primitives spread over 16 depth rows, with many distinct names.
        let primitives = try (0..<20_000).map { index in
            TimelinePrimitive.detail(
                TimelineDetailPrimitive(
                    trackID: descriptor.id,
                    eventKey: EventKey(table: .callstack, rowID: Int64(index) + 1),
                    range: try TraceTimeRange(
                        startNs: Int64(index % 1_000) * 20,
                        endNs: Int64(index % 1_000) * 20 + 10
                    ),
                    label: "slice-\(index)",
                    category: "slice",
                    depth: index % rowCount
                )
            )
        }
        let track = TimelineTrackSnapshot(
            descriptor: descriptor,
            y: 0,
            height: TimelineGeometry.trackHeight(depthRowCount: rowCount),
            primitives: primitives,
            depthRowCount: rowCount
        )
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 500, height: 800))
        var detailBuilds: [Int] = []
        view.pathCacheBuildHook = { kind, bucketCount in
            if kind == "detail" { detailBuilds.append(bucketCount) }
        }
        view.snapshot = TimelineSnapshot(
            viewport: viewport,
            tracks: [track],
            generation: 91,
            dataQuality: TraceDataQuality()
        )
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertEqual(detailBuilds.count, 1, "one path build per snapshot generation")
        let buckets = try XCTUnwrap(detailBuilds.first)
        XCTAssertLessThanOrEqual(
            buckets,
            TimelinePalette.funcColors.count,
            "20k primitives over 16 depth rows must still batch by palette size"
        )
    }

    /// A track with no nesting has to keep the geometry it had before depth
    /// existed, otherwise every CPU, thread-state and counter lane shifts.
    func testSingleDepthTrackGeometryIsUnchanged() throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 1_000, endNs: 2_000),
            widthPoints: 100,
            heightPoints: 80,
            generation: 1
        )
        let descriptor = TrackDescriptor(title: "CPU 0", source: .cpu(0))
        let primitive = TimelinePrimitive.detail(
            TimelineDetailPrimitive(
                trackID: descriptor.id,
                eventKey: EventKey(table: .schedSlice, rowID: 1),
                range: try TraceTimeRange(startNs: 1_250, endNs: 1_500)
            )
        )
        let track = TimelineTrackSnapshot(
            descriptor: descriptor, y: 0, height: 28, primitives: [primitive]
        )
        XCTAssertEqual(TimelineGeometry.trackHeight(depthRowCount: 1), 28)
        let frame = TimelineGeometry.frame(
            for: primitive, in: track, viewport: viewport, backingScale: 2
        )
        XCTAssertEqual(frame.minY, TimelineGeometry.rulerHeight + 3, accuracy: 0.001)
        XCTAssertEqual(frame.height, 22, accuracy: 0.001)
    }

    /// `callstack.depth` is optional in the schema. When it is absent the
    /// loader yields depth 0 for every slice, which must render as one solid
    /// band with no reserved-but-empty rows underneath it.
    func testAbsentDepthCollapsesToASingleBandWithoutGaps() throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 100,
            heightPoints: 80,
            generation: 1
        )
        let descriptor = TrackDescriptor(
            title: "main", source: .namedSlice(ThreadKey(itid: 1))
        )
        let primitives = try (1...3).map { rowID in
            TimelinePrimitive.detail(
                TimelineDetailPrimitive(
                    trackID: descriptor.id,
                    eventKey: EventKey(table: .callstack, rowID: Int64(rowID)),
                    range: try TraceTimeRange(
                        startNs: Int64(rowID) * 100, endNs: Int64(rowID) * 100 + 50
                    )
                )
            )
        }
        let track = TimelineTrackSnapshot(
            descriptor: descriptor,
            y: 0,
            height: TimelineGeometry.trackHeight(depthRowCount: 1),
            primitives: primitives,
            depthRowCount: 1
        )
        XCTAssertEqual(track.height, 28)
        for primitive in primitives {
            let frame = TimelineGeometry.frame(
                for: primitive, in: track, viewport: viewport, backingScale: 2
            )
            XCTAssertEqual(frame.minY, TimelineGeometry.rulerHeight + 3, accuracy: 0.001)
            XCTAssertEqual(frame.height, 22, accuracy: 0.001)
        }
    }

    /// A depth deeper than the track reserved rows for is drawn on the last
    /// row. Letting it fall outside the track would make it unhittable, since
    /// hit-testing first requires the point to be inside the track frame.
    func testDepthBeyondReservedRowsClampsInsideTheTrack() throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 100,
            heightPoints: 200,
            generation: 1
        )
        let descriptor = TrackDescriptor(
            title: "main", source: .namedSlice(ThreadKey(itid: 1))
        )
        let deep = TimelinePrimitive.detail(
            TimelineDetailPrimitive(
                trackID: descriptor.id,
                eventKey: EventKey(table: .callstack, rowID: 9),
                range: try TraceTimeRange(startNs: 100, endNs: 900),
                depth: 99
            )
        )
        let track = TimelineTrackSnapshot(
            descriptor: descriptor,
            y: 0,
            height: TimelineGeometry.trackHeight(depthRowCount: 2),
            primitives: [deep],
            depthRowCount: 2
        )
        let frame = TimelineGeometry.frame(
            for: deep, in: track, viewport: viewport, backingScale: 2
        )
        let trackFrame = TimelineGeometry.trackFrame(track)
        XCTAssertLessThanOrEqual(frame.maxY, trackFrame.maxY)
        XCTAssertEqual(
            frame.minY,
            TimelineGeometry.rulerHeight + 3 + TimelineGeometry.depthRowSpan,
            accuracy: 0.001
        )
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

@MainActor
private final class HostedTargetFrameRecorder {
    var frames: [String: CGRect] = [:]
}

private struct HostedTargetFixture: View {
    @State private var enabled = true
    @State private var query = ""
    let recorder: HostedTargetFrameRecorder

    var body: some View {
        HStack(spacing: 12) {
            Button("Open") {}
                .arktraceAccessibleTarget()
                .background(frameProbe("open"))
            Toggle("Track", isOn: $enabled)
                .toggleStyle(.checkbox)
                .arktraceAccessibleTarget()
                .background(frameProbe("toggle"))
            TextField("Search", text: $query)
                .arktraceAccessibleTarget()
                .background(frameProbe("search"))
        }
        .padding(8)
        .coordinateSpace(name: "target-host")
    }

    private func frameProbe(_ identifier: String) -> some View {
        GeometryReader { proxy in
            Color.clear.onAppear {
                recorder.frames[identifier] = proxy.frame(in: .named("target-host"))
            }
        }
    }
}
