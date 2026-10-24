import AppKit
import ArkTraceCore
@testable import ArkTraceRendering
import XCTest

final class TimelineStaleKeyboardFocusTests: XCTestCase {
    @MainActor
    private func snapshot(_ primitives: [TimelinePrimitive], generation: UInt64,
                          isLoading: Bool = false) throws -> TimelineSnapshot {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 100, heightPoints: 80, generation: generation
        )
        let tracks: [TimelineTrackSnapshot] = isLoading && primitives.isEmpty ? [] : [
            TimelineTrackSnapshot(descriptor: TrackDescriptor(title: "CPU 0", source: .cpu(0)),
                                  y: 0, height: 28, primitives: primitives)
        ]
        return TimelineSnapshot(viewport: viewport, tracks: tracks,
                                generation: generation, dataQuality: TraceDataQuality(), isLoading: isLoading)
    }

    private func detail(_ row: Int64) throws -> TimelinePrimitive {
        .detail(TimelineDetailPrimitive(
            trackID: TrackDescriptor(title: "CPU 0", source: .cpu(0)).id,
            eventKey: EventKey(table: .schedSlice, rowID: row),
            range: try TraceTimeRange(startNs: 100, endNs: 200), label: "event"
        ))
    }

    private func returnKey() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
    }

    @MainActor
    func testReturnDoesNotActivateRemovedDetailInDensityOrEmptySnapshot() throws {
        let key = EventKey(table: .schedSlice, rowID: 1)
        let density = TimelinePrimitive.density(TimelineDensityPrimitive(
            trackID: TrackDescriptor(title: "CPU 0", source: .cpu(0)).id,
            bucket: TraceDensityBucket(
                range: try TraceTimeRange.query(startNs: 0, endNs: 1_000),
                eventCount: 10, occupiedNs: nil, utilization: nil, dominant: nil
            )
        ))
        for replacement in [[density], []] {
            let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
            view.snapshot = try snapshot([detail(1)], generation: 1)
            XCTAssertTrue(view.performKeyboardCommand(.nextEvent))
            XCTAssertEqual(view.focusedEventKey, key)
            view.snapshot = try snapshot(replacement, generation: 2)
            let selection = try TraceTimeRange.query(startNs: 300, endNs: 400)
            view.selection = selection
            var activated: [EventKey?] = []
            var ranges: [TraceTimeRange?] = []
            view.onSelectEvent = { activated.append($0) }
            view.onSelectRange = { ranges.append($0) }
            view.keyDown(with: try returnKey())
            XCTAssertTrue(activated.isEmpty)
            XCTAssertTrue(ranges.isEmpty)
            XCTAssertNil(view.selectedEventKey)
            XCTAssertEqual(view.selection, selection)
        }
    }

    @MainActor
    func testReturnMovesStaleFocusToCurrentDetail() throws {
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
        view.snapshot = try snapshot([detail(1)], generation: 1)
        XCTAssertTrue(view.performKeyboardCommand(.nextEvent))
        view.snapshot = try snapshot([detail(2)], generation: 2)
        var activated: [EventKey?] = []
        view.onSelectEvent = { activated.append($0) }
        view.keyDown(with: try returnKey())
        let current = EventKey(table: .schedSlice, rowID: 2)
        XCTAssertEqual(activated, [current])
        XCTAssertEqual(view.focusedEventKey, current)
        XCTAssertEqual(view.selectedEventKey, current)
    }

    @MainActor
    func testReturnStillActivatesDetailDisplayedWhileLoading() throws {
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
        view.snapshot = try snapshot([detail(1)], generation: 1)
        XCTAssertTrue(view.performKeyboardCommand(.nextEvent))
        view.snapshot = try snapshot([], generation: 2, isLoading: true)
        var activated: [EventKey?] = []
        view.onSelectEvent = { activated.append($0) }
        view.keyDown(with: try returnKey())
        XCTAssertEqual(activated, [EventKey(table: .schedSlice, rowID: 1)])
    }
}
