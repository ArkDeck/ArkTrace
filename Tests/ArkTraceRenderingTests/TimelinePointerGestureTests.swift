import AppKit
import ArkTraceCore
@testable import ArkTraceRendering
import XCTest

/// The two pointer gestures P7-T12 closes: a modified scroll wheel zooms
/// (AUDIT G14) and a range selection's edges can be dragged one at a time
/// (AUDIT G13). Both are exercised through the real event entry points,
/// because for a gesture the binding *is* the contract.
final class TimelinePointerGestureTests: XCTestCase {
    /// 0…1000 ns across 200 points, so one point is 5 ns and the arithmetic in
    /// the assertions stays readable.
    @MainActor
    private func makeView(withEvents: Bool = false) throws -> (TimelineNSView, EventKey) {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 200,
            heightPoints: 80,
            generation: 3
        )
        let descriptor = TrackDescriptor(
            title: "main", source: .namedSlice(ThreadKey(itid: 1))
        )
        // Wide enough to sit under both selection edges below.
        let key = EventKey(table: .callstack, rowID: 1)
        let range = try TraceTimeRange(startNs: 200, endNs: 600)
        let primitives: [TimelinePrimitive] = withEvents
            ? [
                .detail(
                    TimelineDetailPrimitive(
                        trackID: descriptor.id,
                        eventKey: key,
                        range: range,
                        label: "wide",
                        category: "slice",
                        inspector: nil
                    )
                )
            ]
            : []
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        view.snapshot = TimelineSnapshot(
            viewport: viewport,
            tracks: [
                TimelineTrackSnapshot(
                    descriptor: descriptor, y: 0, height: 28, primitives: primitives
                )
            ],
            generation: viewport.generation,
            dataQuality: TraceDataQuality()
        )
        view.interactionBounds = try TraceTimeRange.query(startNs: 0, endNs: 1_000)
        return (view, key)
    }

    /// `location:` is in window coordinates, which are unflipped; the view is
    /// flipped, so a view y of `v` arrives as `height - v`.
    private func mouse(
        _ type: NSEvent.EventType, viewPoint: CGPoint, height: CGFloat = 80
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                location: CGPoint(x: viewPoint.x, y: height - viewPoint.y),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            )
        )
    }

    // MARK: - G14: wheel zoom

    /// Unmodified scrolling is untouched: horizontal pans by the raw delta it
    /// always used, vertical falls through to the enclosing scroll view.
    func testUnmodifiedScrollingKeepsPanningAndPassingThrough() {
        XCTAssertEqual(
            TimelineScrollGesture.resolve(
                deltaX: -12, deltaY: 0, hasPreciseDeltas: true, zooms: false
            ),
            .pan(points: -12)
        )
        XCTAssertEqual(
            TimelineScrollGesture.resolve(
                deltaX: 0, deltaY: 40, hasPreciseDeltas: true, zooms: false
            ),
            .passThrough,
            "vertical scrolling belongs to the scroll view"
        )
        // A legacy wheel's line units must not be rescaled on the pan path:
        // that would silently make every existing wheel pan much longer.
        XCTAssertEqual(
            TimelineScrollGesture.resolve(
                deltaX: 3, deltaY: 0, hasPreciseDeltas: false, zooms: false
            ),
            .pan(points: 3)
        )
    }

    /// The gesture upstream binds to `Ctrl + Scroll wheel`.
    func testModifiedVerticalScrollingZoomsInTheUpstreamDirection() throws {
        guard case .zoom(let inScale) = TimelineScrollGesture.resolve(
            deltaX: 0, deltaY: 20, hasPreciseDeltas: true, zooms: true
        ) else { return XCTFail("a modified vertical scroll must zoom") }
        XCTAssertLessThan(inScale, 1, "scrolling up narrows the viewport")

        guard case .zoom(let outScale) = TimelineScrollGesture.resolve(
            deltaX: 0, deltaY: -20, hasPreciseDeltas: true, zooms: true
        ) else { return XCTFail("a modified vertical scroll must zoom") }
        XCTAssertGreaterThan(outScale, 1, "scrolling down widens it")
        XCTAssertEqual(inScale * outScale, 1, accuracy: 1e-12, "the step is symmetric")

        // A wheel detent is one line, not one point: it has to be worth a
        // visible step on its own.
        guard case .zoom(let detent) = TimelineScrollGesture.resolve(
            deltaX: 0, deltaY: 1, hasPreciseDeltas: false, zooms: true
        ) else { return XCTFail("a wheel detent must zoom") }
        XCTAssertLessThan(detent, 0.95)
        XCTAssertGreaterThan(detent, 0.7)

        // A flung trackpad cannot teleport the viewport.
        guard case .zoom(let flung) = TimelineScrollGesture.resolve(
            deltaX: 0, deltaY: 9_000, hasPreciseDeltas: true, zooms: true
        ) else { return XCTFail("a large scroll must still zoom") }
        XCTAssertEqual(flung, exp(-TimelineScrollGesture.maximumZoomExponent), accuracy: 1e-12)

        // A modified *horizontal* scroll is still a pan, not an accidental zoom.
        XCTAssertEqual(
            TimelineScrollGesture.resolve(
                deltaX: -8, deltaY: 0, hasPreciseDeltas: true, zooms: true
            ),
            .pan(points: -8)
        )
    }

    /// End to end through `scrollWheel(with:)`: ⌥ and ⌃ both zoom, and the
    /// anchor is the pointer — the same anchor `magnify(with:)` uses.
    @MainActor
    func testScrollWheelWithOptionOrControlZoomsAboutThePointer() throws {
        for modifier in [CGEventFlags.maskAlternate, .maskControl] {
            let (view, _) = try makeView()
            var intents: [TimelineViewportIntent] = []
            view.onViewportIntent = { intents.append($0) }
            let cgEvent = try XCTUnwrap(
                CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel,
                    wheelCount: 1, wheel1: 30, wheel2: 0, wheel3: 0
                )
            )
            cgEvent.flags = modifier
            // 150 of 200 points over 0…1000 ns is 750 ns.
            cgEvent.location = CGPoint(x: 150, y: 40)
            view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cgEvent)))

            guard case .zoom(let anchorNs, let scale, _) = try XCTUnwrap(intents.first)
            else { return XCTFail("a modified scroll must produce a zoom intent") }
            XCTAssertEqual(anchorNs, 750, "the pointer is the anchor")
            XCTAssertLessThan(scale, 1)
        }
    }

    /// The regression the modifier check could cause: a bare wheel must keep
    /// behaving exactly as before.
    @MainActor
    func testBareScrollWheelStillPansAndNeverZooms() throws {
        let (view, _) = try makeView()
        var intents: [TimelineViewportIntent] = []
        view.onViewportIntent = { intents.append($0) }
        let cgEvent = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 2, wheel1: 0, wheel2: 24, wheel3: 0
            )
        )
        view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cgEvent)))
        guard case .panPoints(let points, _) = try XCTUnwrap(intents.first) else {
            return XCTFail("a bare horizontal wheel pans")
        }
        XCTAssertNotEqual(points, 0)
    }

    // MARK: - G13: draggable selection endpoints

    /// AT-APP-011: each handle is at least 24 points wide, and the two never
    /// overlap — not even when the selection is narrower than one handle.
    func testEndpointHitAreasAreLargeEnoughAndNeverOverlap() throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 200, heightPoints: 80, generation: 1
        )
        let floor = TimelineAccessibilityLayout.minimumTargetPoints
        let body = TimelineGeometry.rulerHeight + 1

        // A comfortably wide selection: 250…500 ns is x 50…100.
        let wide = try TraceTimeRange.query(startNs: 250, endNs: 500)
        func endpoint(_ x: CGFloat, _ selection: TraceTimeRange) -> TimelineSelectionEndpoint? {
            TimelineGeometry.selectionEndpoint(
                at: CGPoint(x: x, y: body), selection: selection, viewport: viewport
            )
        }
        XCTAssertEqual(endpoint(50 - floor / 2, wide), .start)
        XCTAssertEqual(endpoint(50 + floor / 2, wide), .start)
        XCTAssertNil(endpoint(50 - floor / 2 - 0.5, wide), "the handle is bounded")
        XCTAssertEqual(endpoint(100 - floor / 2, wide), .end)
        XCTAssertEqual(endpoint(100 + floor / 2, wide), .end)
        XCTAssertNil(endpoint(75, wide), "the middle of a selection is not a handle")

        // A selection narrower than one handle: 400…420 ns is x 80…84, and the
        // midpoint at 82 becomes the boundary so both keep a full 24 points
        // by extending outward.
        let narrow = try TraceTimeRange.query(startNs: 400, endNs: 420)
        XCTAssertEqual(endpoint(82 - floor, narrow), .start)
        XCTAssertEqual(endpoint(80, narrow), .start, "its own edge is inside it")
        XCTAssertEqual(endpoint(82, narrow), .start, "the boundary resolves one way")
        XCTAssertEqual(endpoint(82.5, narrow), .end)
        XCTAssertEqual(endpoint(84, narrow), .end, "its own edge is inside it")
        XCTAssertEqual(endpoint(82 + floor, narrow), .end)
        XCTAssertNil(endpoint(82 + floor + 0.5, narrow))

        // Vertically the handle is the whole track body, so 24×24 holds; the
        // ruler is not part of it, because a ruler click places a flag.
        XCTAssertNil(
            TimelineGeometry.selectionEndpoint(
                at: CGPoint(x: 50, y: TimelineGeometry.rulerHeight - 1),
                selection: wide, viewport: viewport
            )
        )
    }

    /// The gap G13 names: dragging an edge moves *that* edge and leaves the
    /// other one where it was.
    @MainActor
    func testDraggingAnEndpointMovesOnlyThatEndpoint() throws {
        let (view, _) = try makeView()
        var ranges: [TraceTimeRange?] = []
        view.onSelectRange = { ranges.append($0) }
        view.selection = try TraceTimeRange.query(startNs: 250, endNs: 500)

        // Press on the left edge (x 50) and drag to x 20, i.e. 100 ns.
        view.mouseDown(with: try mouse(.leftMouseDown, viewPoint: CGPoint(x: 52, y: 40)))
        view.mouseDragged(with: try mouse(.leftMouseDragged, viewPoint: CGPoint(x: 20, y: 40)))
        XCTAssertEqual(view.selection?.startNs, 100)
        XCTAssertEqual(view.selection?.endNs, 500, "the far edge did not move")

        // Continuing past the anchor swaps which edge is which, rather than
        // stopping the drag dead.
        view.mouseDragged(with: try mouse(.leftMouseDragged, viewPoint: CGPoint(x: 150, y: 40)))
        XCTAssertEqual(view.selection?.startNs, 500)
        XCTAssertEqual(view.selection?.endNs, 750)
        view.mouseUp(with: try mouse(.leftMouseUp, viewPoint: CGPoint(x: 150, y: 40)))
        XCTAssertNil(view.dragMode)
        XCTAssertEqual(ranges.last??.startNs, 500)
        XCTAssertEqual(ranges.last??.endNs, 750)
    }

    /// The other edge of the same behaviour: pressing anywhere that is not a
    /// handle still sweeps out a fresh range from the press point.
    @MainActor
    func testPressingAwayFromAHandleStillSweepsANewRange() throws {
        let (view, _) = try makeView()
        view.selection = try TraceTimeRange.query(startNs: 250, endNs: 500)

        // x 75 is the middle of the selection, 25 points from either edge.
        view.mouseDown(with: try mouse(.leftMouseDown, viewPoint: CGPoint(x: 75, y: 40)))
        view.mouseDragged(with: try mouse(.leftMouseDragged, viewPoint: CGPoint(x: 90, y: 40)))
        XCTAssertEqual(view.selection?.startNs, 375, "a new range, anchored at the press")
        XCTAssertEqual(view.selection?.endNs, 450)
    }

    /// Handles only exist while a selection does, so nothing about event
    /// selection changes when there is no range.
    @MainActor
    func testWithoutASelectionAPressStillSelectsTheEventUnderIt() throws {
        let (view, key) = try makeView(withEvents: true)
        var selected: [EventKey?] = []
        view.onSelectEvent = { selected.append($0) }

        // x 50 is 250 ns, inside the 200…600 ns slice.
        view.mouseDown(with: try mouse(.leftMouseDown, viewPoint: CGPoint(x: 50, y: 40)))
        XCTAssertEqual(selected, [key])
        XCTAssertNil(view.dragMode, "an event press is not a drag")

        // With a selection whose edge lands on the same slice, the edge wins:
        // that column is the price of a grabbable handle, and it is bounded to
        // 24 points around an edge the user placed.
        view.selection = try TraceTimeRange.query(startNs: 250, endNs: 500)
        selected.removeAll()
        view.mouseDown(with: try mouse(.leftMouseDown, viewPoint: CGPoint(x: 50, y: 40)))
        XCTAssertTrue(selected.isEmpty, "the press grabbed the handle")
        XCTAssertNotNil(view.dragMode)
    }

    /// The resize cursor has to appear exactly where the press grabs, or the
    /// affordance lies. Both meet AT-APP-011's 24×24 floor.
    @MainActor
    func testTheResizeCursorRegionsMatchWhatAPressActuallyGrabs() throws {
        let (view, _) = try makeView()
        XCTAssertTrue(
            view.selectionHandleCursorRects().isEmpty, "no selection, no handles"
        )
        let selection = try TraceTimeRange.query(startNs: 250, endNs: 500)
        view.selection = selection
        let rects = view.selectionHandleCursorRects()
        XCTAssertEqual(rects.count, 2)
        let source = try XCTUnwrap(view.snapshot)
        for rect in rects {
            XCTAssertGreaterThanOrEqual(
                rect.width, TimelineAccessibilityLayout.minimumTargetPoints
            )
            XCTAssertGreaterThanOrEqual(
                rect.height, TimelineAccessibilityLayout.minimumTargetPoints
            )
            XCTAssertEqual(rect.minY, TimelineGeometry.rulerHeight, "never over the ruler")
            for x in [rect.minX + 0.5, rect.midX, rect.maxX - 0.5] {
                XCTAssertNotNil(
                    TimelineGeometry.selectionEndpoint(
                        at: CGPoint(x: x, y: rect.midY),
                        selection: selection,
                        viewport: source.viewport
                    ),
                    "the cursor promises a handle at \(x); the press must grab one"
                )
            }
        }
    }

    /// Drag feedback is a shape change, not a colour change (AT-APP-011), and
    /// it must not cost a batched-path rebuild (AT-RENDER-008).
    @MainActor
    func testEndpointHoverRedrawsWithoutRebuildingTheBatchedPaths() throws {
        let (view, _) = try makeView(withEvents: true)
        view.selection = try TraceTimeRange.query(startNs: 250, endNs: 500)
        var detailBuilds = 0
        view.pathCacheBuildHook = { kind, _ in if kind == "detail" { detailBuilds += 1 } }
        func render() throws {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return
        }
        try render()
        XCTAssertEqual(detailBuilds, 1)

        let away = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: away)
        view.updateHoveredSelectionEndpoint(at: CGPoint(x: 50, y: 40))
        XCTAssertEqual(view.hoveredSelectionEndpoint, .start)
        let over = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: over)
        XCTAssertNotEqual(
            away.representation(using: .png, properties: [:]),
            over.representation(using: .png, properties: [:]),
            "the handle must visibly change under the pointer"
        )

        for x in stride(from: CGFloat(20), through: 120, by: 4) {
            view.updateHoveredSelectionEndpoint(at: CGPoint(x: x, y: 40))
            try render()
        }
        XCTAssertEqual(
            detailBuilds, 1,
            "endpoint hover is an overlay: it must not rebuild any fill batch"
        )
    }
}
