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
        let rendered = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rendered)
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

    @MainActor
    func testDetailRenderingUsesClosedStyleBucketsAndStableSnapshotCache() throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 10_000),
            widthPoints: 500,
            heightPoints: 80,
            generation: 73
        )
        let descriptor = TrackDescriptor(title: "CPU 0", source: .cpu(0))
        let primitives = try (0..<1_000).map { index -> TimelinePrimitive in
            let start = Int64(index * 10)
            return .detail(
                TimelineDetailPrimitive(
                    trackID: descriptor.id,
                    eventKey: EventKey(table: .schedSlice, rowID: Int64(index + 1)),
                    range: try TraceTimeRange(startNs: start, endNs: start + 8),
                    label: nil,
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
        XCTAssertEqual(detailBuilds, [1])

        view.snapshot = first
        view.selectedEventKey = EventKey(table: .schedSlice, rowID: 1)
        let secondBitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: secondBitmap)
        XCTAssertEqual(detailBuilds, [1])

        view.snapshot = try snapshot(generation: 74)
        let thirdBitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: thirdBitmap)
        XCTAssertEqual(detailBuilds, [1, 1])
        XCTAssertLessThanOrEqual(detailBuilds.last ?? .max, 6)
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
