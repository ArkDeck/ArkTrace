import AppKit
import ArkTraceCore
@testable import ArkTraceRendering
import XCTest

/// The annotation key cluster and the ruler gesture. Exercised through real
/// synthesized events because the binding *is* the contract: upstream uses
/// bare `,`/`.` to scroll a flag back into view, Ctrl variants to jump, and
/// `m` / `Shift+m` for transient vs kept marks.
final class TimelineAnnotationKeyTests: XCTestCase {
    @MainActor
    private func makeView() throws -> TimelineNSView {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 2_000, endNs: 3_000),
            widthPoints: 100,
            heightPoints: 60,
            generation: 7
        )
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 100, height: 60))
        view.snapshot = TimelineSnapshot(
            viewport: viewport,
            tracks: [
                TimelineTrackSnapshot(
                    descriptor: TrackDescriptor(title: "CPU 0", source: .cpu(0)),
                    y: 0, height: 28, primitives: []
                )
            ],
            generation: viewport.generation,
            dataQuality: TraceDataQuality()
        )
        view.interactionBounds = try TraceTimeRange.query(startNs: 0, endNs: 10_000)
        return view
    }

    private func keyDown(
        _ characters: String, modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: 0
            )
        )
    }

    @MainActor
    func testAnnotationKeysMapToTheirUpstreamCommands() throws {
        let view = try makeView()
        var commands: [TimelineAnnotationCommand] = []
        view.onAnnotationCommand = { commands.append($0) }

        view.keyDown(with: try keyDown(","))
        view.keyDown(with: try keyDown("."))
        view.keyDown(with: try keyDown(",", modifiers: .control))
        view.keyDown(with: try keyDown(".", modifiers: .control))
        view.keyDown(with: try keyDown("[", modifiers: .control))
        view.keyDown(with: try keyDown("]", modifiers: .control))
        view.keyDown(with: try keyDown("m"))
        view.keyDown(with: try keyDown("m", modifiers: .shift))

        XCTAssertEqual(
            commands,
            [
                .scrollNearestFlagIntoView,
                .scrollNearestFlagIntoView,
                .previousFlag,
                .nextFlag,
                .previousMark,
                .nextMark,
                .createMark(isPersistent: false),
                .createMark(isPersistent: true),
            ]
        )
    }

    /// DESIGN §14.3: a ⌘-modified key belongs to the menu. ⌘M must reach Minimize
    /// rather than being swallowed as "create mark", and bare `[`/`]` must keep
    /// their existing zoom-to-selection meaning.
    @MainActor
    func testCommandModifiedKeysAndBareBracketsAreNotAnnotationKeys() throws {
        let view = try makeView()
        var commands: [TimelineAnnotationCommand] = []
        var zoomSelectionCount = 0
        view.onAnnotationCommand = { commands.append($0) }
        view.onZoomSelection = { zoomSelectionCount += 1 }

        view.keyDown(with: try keyDown("m", modifiers: .command))
        view.keyDown(with: try keyDown(",", modifiers: .command))
        XCTAssertTrue(commands.isEmpty, "⌘ keys belong to the menu")

        // Zoom-to-selection only acts when there is a selection to zoom to.
        view.selection = try TraceTimeRange.query(startNs: 2_100, endNs: 2_400)
        view.keyDown(with: try keyDown("["))
        view.keyDown(with: try keyDown("]"))
        XCTAssertTrue(commands.isEmpty, "bare brackets stay zoom-to-selection")
        XCTAssertEqual(zoomSelectionCount, 2)
    }

    /// Upstream places a flag by clicking the ruler. The ruler carries no
    /// events, so the gesture cannot be confused with selecting one.
    @MainActor
    func testRulerClickCreatesAFlagAndTrackClickDoesNot() throws {
        let view = try makeView()
        var created: [Int64] = []
        var selectedEvents: [EventKey?] = []
        view.onCreateFlag = { created.append($0) }
        view.onSelectEvent = { selectedEvents.append($0) }

        // x = 50 of 100 points over 2000…3000 ns is 2500 ns.
        view.mouseDown(
            with: try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: CGPoint(x: 50, y: 60 - 5),
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1
                )
            )
        )
        XCTAssertEqual(created, [2_500])
        XCTAssertTrue(selectedEvents.isEmpty, "a ruler click is not an event click")

        // Below the ruler the click is an ordinary selection gesture again.
        view.mouseDown(
            with: try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: CGPoint(x: 50, y: 10),
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1
                )
            )
        )
        XCTAssertEqual(created, [2_500], "no second flag")
        XCTAssertEqual(selectedEvents, [nil])
    }
}

/// Rendering: annotations must actually reach the canvas, and must not disturb
/// the batched event fills they are drawn over.
final class TimelineAnnotationRenderTests: XCTestCase {
    @MainActor
    private func makeView() throws -> TimelineNSView {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 100,
            heightPoints: 60,
            generation: 3
        )
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 100, height: 60))
        view.snapshot = TimelineSnapshot(
            viewport: viewport,
            tracks: [
                TimelineTrackSnapshot(
                    descriptor: TrackDescriptor(title: "CPU 0", source: .cpu(0)),
                    y: 0, height: 28, primitives: []
                )
            ],
            generation: viewport.generation,
            dataQuality: TraceDataQuality()
        )
        return view
    }

    @MainActor
    private func render(_ view: TimelineNSView) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    @MainActor
    func testFlagsAndMarksAreDrawnAndDoNotRebuildEventBatches() throws {
        let view = try makeView()
        var detailBuilds = 0
        view.pathCacheBuildHook = { kind, _ in if kind == "detail" { detailBuilds += 1 } }
        let plain = try render(view)
        let buildsBeforeAnnotations = detailBuilds

        view.annotations = TimelineAnnotations(
            flags: [
                TimelineFlag(id: 1, timestampNs: 500, label: "half", colorIndex: 0)
            ],
            marks: [
                TimelineMark(
                    id: 2,
                    range: try TraceTimeRange.query(startNs: 700, endNs: 900),
                    label: "region",
                    colorIndex: 1,
                    isPersistent: true
                )
            ]
        )
        let annotated = try render(view)

        // The cached rep is sized in backing pixels, so point coordinates have
        // to be scaled before indexing it.
        let scale = CGFloat(plain.pixelsWide) / view.bounds.width
        func pixel(_ bitmap: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> NSColor? {
            bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))
        }
        XCTAssertNotEqual(
            pixel(plain, 50, 40), pixel(annotated, 50, 40),
            "the flag's rule must reach the canvas"
        )
        XCTAssertNotEqual(
            pixel(plain, 80, 40), pixel(annotated, 80, 40),
            "the mark's band must reach the canvas"
        )
        XCTAssertEqual(
            pixel(plain, 20, 40), pixel(annotated, 20, 40),
            "columns with no annotation must be untouched"
        )
        // Annotations are an overlay: they must not invalidate the batched
        // event fills (DESIGN §13.5 / AT-RENDER-008).
        XCTAssertEqual(
            detailBuilds, buildsBeforeAnnotations,
            "drawing annotations must not rebuild the detail path cache"
        )
    }

    @MainActor
    func testAnnotationsOutsideTheViewportAreNotDrawn() throws {
        let view = try makeView()
        let plain = try render(view)
        view.annotations = TimelineAnnotations(
            flags: [
                TimelineFlag(id: 1, timestampNs: 90_000, label: "far", colorIndex: 0)
            ],
            marks: [
                TimelineMark(
                    id: 2,
                    range: try TraceTimeRange.query(startNs: 50_000, endNs: 60_000),
                    label: "far", colorIndex: 1, isPersistent: true
                )
            ]
        )
        let annotated = try render(view)
        let scale = CGFloat(plain.pixelsWide) / view.bounds.width
        for x in stride(from: CGFloat(2), to: CGFloat(100), by: 7) {
            let px = Int(x * scale)
            let py = Int(CGFloat(40) * scale)
            XCTAssertEqual(
                plain.colorAt(x: px, y: py), annotated.colorAt(x: px, y: py),
                "off-viewport annotations must not paint at x=\(x)"
            )
        }
    }
}
