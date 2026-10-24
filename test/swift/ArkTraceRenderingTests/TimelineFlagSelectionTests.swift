import AppKit
import ArkTraceCore
@testable import ArkTraceRendering
import XCTest

/// Naming a flag where it stands: the ruler press has to find the pennant that
/// is already there instead of stacking a second flag on top of it.
final class TimelineFlagSelectionTests: XCTestCase {
    @MainActor
    private func makeView() throws -> TimelineNSView {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 200, heightPoints: 80, generation: 1
        )
        let descriptor = TrackDescriptor(title: "CPU 0", source: .cpu(0))
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
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
        // 500 ns of 0…1000 across 200 points is x = 100.
        view.annotations = TimelineAnnotations(
            flags: [TimelineFlag(id: 7, timestampNs: 500, label: "Flag 1", colorIndex: 0)]
        )
        return view
    }

    private func mouse(_ type: NSEvent.EventType, viewPoint: CGPoint) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                location: CGPoint(x: viewPoint.x, y: 80 - viewPoint.y),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            )
        )
    }

    @MainActor
    func testTheRulerPressFindsTheFlagStandingThere() throws {
        let view = try makeView()
        let hit = try XCTUnwrap(view.flag(at: CGPoint(x: 102, y: 10)))
        XCTAssertEqual(hit.id, 7)
        XCTAssertEqual(hit.marker.minX, 100, accuracy: 0.001)
        // The pennant is 7 points wide, so the target is widened to AT-APP-011's
        // floor around it -- and stops there.
        XCTAssertNotNil(view.flag(at: CGPoint(x: 92, y: 4)))
        XCTAssertNil(view.flag(at: CGPoint(x: 140, y: 10)))
        // Below the ruler the flag's rule belongs to the tracks, not to it.
        XCTAssertNil(view.flag(at: CGPoint(x: 102, y: 40)))
    }

    @MainActor
    func testPressingAFlagNamesItAndPressingElsewhereCreatesOne() throws {
        let view = try makeView()
        var named: [Int] = []
        var created: [Int64] = []
        view.onSelectFlag = { named.append($0.id) }
        view.onCreateFlag = { created.append($0) }

        let onFlag = CGPoint(x: 102, y: 10)
        view.mouseDown(with: try mouse(.leftMouseDown, viewPoint: onFlag))
        XCTAssertTrue(created.isEmpty, "a flag is already there")
        XCTAssertTrue(named.isEmpty, "the press alone decides nothing")
        view.mouseUp(with: try mouse(.leftMouseUp, viewPoint: onFlag))
        XCTAssertEqual(named, [7])
        XCTAssertTrue(created.isEmpty)

        let bare = CGPoint(x: 160, y: 10)
        view.mouseDown(with: try mouse(.leftMouseDown, viewPoint: bare))
        view.mouseUp(with: try mouse(.leftMouseUp, viewPoint: bare))
        XCTAssertEqual(created.count, 1, "empty ruler still places a flag")
        XCTAssertEqual(named, [7], "and names nothing")
    }
}
