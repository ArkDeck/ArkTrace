import AppKit
import ArkTraceCore
@testable import ArkTraceRendering
import XCTest

/// Hover is an overlay. The constraint that matters is DESIGN §13.5 /
/// AT-RENDER-008: the batched fills are bounded by the palette and must not
/// become a function of pointer movement. AT-APP-010 additionally rules out
/// per-frame accessibility announcements from hovering.
final class TimelineHoverTests: XCTestCase {
    @MainActor
    private func makeView(names: [String]) throws -> (TimelineNSView, [EventKey]) {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 200,
            heightPoints: 80,
            generation: 5
        )
        let descriptor = TrackDescriptor(
            title: "main", source: .namedSlice(ThreadKey(itid: 1))
        )
        var primitives: [TimelinePrimitive] = []
        var keys: [EventKey] = []
        for (index, name) in names.enumerated() {
            let key = EventKey(table: .callstack, rowID: Int64(index) + 1)
            keys.append(key)
            let range = try TraceTimeRange(
                startNs: Int64(index) * 100, endNs: Int64(index) * 100 + 80
            )
            primitives.append(
                .detail(
                    TimelineDetailPrimitive(
                        trackID: descriptor.id,
                        eventKey: key,
                        range: range,
                        label: name,
                        category: "slice",
                        inspector: TraceEventInspector(
                            key: key, type: .namedSlice, name: name, range: range,
                            semanticDurationNs: 80, isOpenEnded: false,
                            processKey: nil, threadKey: nil, pid: nil, tid: nil,
                            cpu: nil, processName: nil, threadName: nil,
                            category: "slice", state: nil, value: nil, unit: nil
                        )
                    )
                )
            )
        }
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
        return (view, keys)
    }

    @MainActor
    private func render(_ view: TimelineNSView) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
    }

    /// The whole point of the overlay approach: hovering repeatedly must not
    /// rebuild the batched fills.
    @MainActor
    func testRepeatedHoverNeverRebuildsTheDetailPathCache() throws {
        let (view, keys) = try makeView(names: ["a", "b", "a", "c", "a"])
        var detailBuilds = 0
        view.pathCacheBuildHook = { kind, _ in if kind == "detail" { detailBuilds += 1 } }
        view.updatePointerLocation(CGPoint(x: 30, y: 40))
        try render(view)
        XCTAssertEqual(detailBuilds, 1, "the first paint builds the cache once")

        for key in keys + keys.reversed() + keys {
            view.updateHover(key)
            try render(view)
        }
        view.updateHover(nil)
        try render(view)
        XCTAssertEqual(
            detailBuilds, 1,
            "hovering is an overlay: 15 hover changes must not rebuild any batch"
        )
    }

    /// AT-APP-010: high-frequency hover must stay silent.
    @MainActor
    func testHoverPostsNoAccessibilityNotification() throws {
        let (view, keys) = try makeView(names: ["a", "b"])
        var announcements = 0
        view.accessibilityValueChangedHook = { announcements += 1 }
        for key in keys {
            view.updateHover(key)
            try render(view)
        }
        view.updateHover(nil)
        XCTAssertEqual(announcements, 0, "hover must not announce")

        // Selection still does announce -- the silence is specific to hover.
        view.selectedEventKey = keys[0]
        XCTAssertGreaterThan(announcements, 0)
    }

    /// Same-name slices are washed together, so a high-frequency function reads
    /// as one family rather than scattered blocks.
    @MainActor
    func testHoveringWashesEverySliceSharingTheName() throws {
        let (view, keys) = try makeView(names: ["a", "b", "a"])
        view.updatePointerLocation(CGPoint(x: 5, y: 40))
        let before = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: before)

        view.updateHover(keys[0])  // an "a"
        let after = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: after)

        let scale = CGFloat(before.pixelsWide) / view.bounds.width
        func pixel(_ bitmap: NSBitmapImageRep, _ x: CGFloat) -> NSColor? {
            bitmap.colorAt(x: Int(x * scale), y: Int(CGFloat(34) * scale))
        }
        // Slice 0 spans x 0…16, slice 1 spans 20…36, slice 2 spans 40…56.
        XCTAssertNotEqual(pixel(before, 8), pixel(after, 8), "hovered 'a' is washed")
        XCTAssertNotEqual(
            pixel(before, 48), pixel(after, 48),
            "the other 'a' is washed with it"
        )
        XCTAssertEqual(
            pixel(before, 28), pixel(after, 28),
            "'b' has a different name and must be left alone"
        )
    }

    @MainActor
    func testTooltipTextCarriesNameAndDuration() throws {
        let range = try TraceTimeRange(startNs: 0, endNs: 2_000_000)
        let key = EventKey(table: .callstack, rowID: 1)
        let detail = TimelineDetailPrimitive(
            trackID: TimelineTrackID(rawValue: "named-slice:1"),
            eventKey: key,
            range: range,
            label: "H:OnVsyncEvent",
            category: "slice",
            inspector: TraceEventInspector(
                key: key, type: .namedSlice, name: "H:OnVsyncEvent", range: range,
                semanticDurationNs: 2_000_000, isOpenEnded: false,
                processKey: nil, threadKey: nil, pid: nil, tid: nil, cpu: nil,
                processName: nil, threadName: nil, category: "slice",
                state: nil, value: nil, unit: nil
            )
        )
        let text = try XCTUnwrap(TimelineNSView.tooltipText(for: detail))
        XCTAssertTrue(text.contains("H:OnVsyncEvent"))
        XCTAssertTrue(text.contains("2.000 ms"), "duration is readable, got \(text)")

        // An open-ended event says so rather than printing a wrong number.
        let openEnded = TimelineDetailPrimitive(
            trackID: TimelineTrackID(rawValue: "named-slice:1"),
            eventKey: key, range: range, label: "still running", category: "slice",
            inspector: TraceEventInspector(
                key: key, type: .namedSlice, name: "still running", range: range,
                semanticDurationNs: nil, isOpenEnded: true,
                processKey: nil, threadKey: nil, pid: nil, tid: nil, cpu: nil,
                processName: nil, threadName: nil, category: "slice",
                state: nil, value: nil, unit: nil
            )
        )
        XCTAssertEqual(
            TimelineNSView.tooltipText(for: openEnded), "still running · open ended"
        )
    }
}
