import AppKit
import ArkTraceCore
@testable import ArkTraceRendering
import XCTest

/// SmartPerf Host's navigation cluster, exercised through real synthesized key
/// events rather than the command boundary, because the binding itself is the
/// contract: `W`/`S` zoom about the pointer, `A`/`D` pan, `[`/`]` alias the
/// zoom-to-selection key.
final class TimelineNavigationKeyTests: XCTestCase {
    /// 100 points wide over 2000…3000 ns, so one point is exactly 10 ns and an
    /// anchor is readable straight off the pointer's x. The viewport sits in the
    /// middle of the trace bounds on purpose: at either edge a pan in that
    /// direction is correctly refused, which would hide a broken binding.
    @MainActor
    private func makeView() throws -> (TimelineNSView, TimelineViewport) {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 2_000, endNs: 3_000),
            widthPoints: 100,
            heightPoints: 60,
            generation: 7
        )
        let descriptor = TrackDescriptor(title: "CPU 0", source: .cpu(0))
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 100, height: 60))
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
        view.interactionBounds = try TraceTimeRange.query(startNs: 0, endNs: 10_000)
        return (view, viewport)
    }

    private func keyDown(_ characters: String, modifiers: NSEvent.ModifierFlags = []) throws
        -> NSEvent
    {
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
                // Not an arrow key; the letter branch is selected by character.
                keyCode: 0
            )
        )
    }

    /// The focus indicator follows the input, not the focus.
    ///
    /// A trace opens with the keyboard already on the canvas, so a rule of
    /// "focused, therefore ringed" framed every trace the moment it appeared,
    /// and a border around the whole timeline reads as "all of this is
    /// selected". Keyboard use turns it on and the pointer turns it off, the
    /// way `:focus-visible` behaves on the web.
    @MainActor
    func testTheFocusIndicatorFollowsKeyboardUseRatherThanFocus() throws {
        let (view, _) = try makeView()
        var announced: [Bool] = []
        view.onKeyboardFocusVisibleChange = { announced.append($0) }
        XCTAssertFalse(
            view.keyboardFocusIsVisible,
            "a canvas nobody has typed on advertises nothing"
        )

        view.keyDown(with: try keyDown("d"))
        XCTAssertTrue(view.keyboardFocusIsVisible)
        XCTAssertEqual(announced, [true])

        let press = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: CGPoint(x: 50, y: 20),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            )
        )
        view.mouseDown(with: press)
        XCTAssertFalse(view.keyboardFocusIsVisible, "the pointer takes it back")
        XCTAssertEqual(announced, [true, false])

        // Only changes are announced: the host redraws a border on each one.
        view.mouseDown(with: press)
        XCTAssertEqual(announced, [true, false])
    }

    @MainActor
    func testWasdKeysProduceBoundedZoomAndPanIntents() throws {
        let (view, viewport) = try makeView()
        var intents: [TimelineViewportIntent] = []
        view.onViewportIntent = { intents.append($0) }
        // Pointer at 80 points -> 2800 ns in this viewport.
        view.updatePointerLocation(CGPoint(x: 80, y: 30))

        view.keyDown(with: try keyDown("w"))
        view.keyDown(with: try keyDown("s"))
        view.keyDown(with: try keyDown("a"))
        view.keyDown(with: try keyDown("d"))
        guard intents.count == 4 else {
            return XCTFail("expected one intent per key, got \(intents.count)")
        }

        guard case .zoom(let inAnchor, let inScale, let inSource) = intents[0] else {
            return XCTFail("W must zoom in")
        }
        XCTAssertEqual(inAnchor, 2_800, "W zooms about the pointer, not the viewport center")
        XCTAssertEqual(inScale, 0.5)
        XCTAssertEqual(inSource, viewport)

        guard case .zoom(let outAnchor, let outScale, _) = intents[1] else {
            return XCTFail("S must zoom out")
        }
        XCTAssertEqual(outAnchor, 2_800)
        XCTAssertEqual(outScale, 2.0)

        guard case .panPoints(let backward, _) = intents[2] else {
            return XCTFail("A must pan backward")
        }
        XCTAssertEqual(backward, -10, accuracy: 0.001, "10% of a 100-point viewport")

        guard case .panPoints(let forward, _) = intents[3] else {
            return XCTFail("D must pan forward")
        }
        XCTAssertEqual(forward, 10, accuracy: 0.001)
    }

    /// The pointer only anchors while it is over the timeline. Off the canvas,
    /// `W` has to fall back to the same anchor chain `+` uses instead of
    /// zooming about a stale position.
    @MainActor
    func testPointerAnchorIsIgnoredWhenThePointerIsAway() throws {
        let (view, _) = try makeView()
        var intents: [TimelineViewportIntent] = []
        view.onViewportIntent = { intents.append($0) }

        view.updatePointerLocation(CGPoint(x: 80, y: 30))
        view.updatePointerLocation(nil)
        view.performKeyboardCommand(.zoomInAtPointer)
        guard case .zoom(let centered, _, _) = try XCTUnwrap(intents.first) else {
            return XCTFail("expected a zoom intent")
        }
        XCTAssertEqual(centered, 2_500, "falls back to the viewport midpoint")

        // A pointer outside the view's bounds is not an anchor either.
        view.updatePointerLocation(CGPoint(x: 400, y: 30))
        view.performKeyboardCommand(.zoomInAtPointer)
        guard case .zoom(let outside, _, _) = try XCTUnwrap(intents.last) else {
            return XCTFail("expected a zoom intent")
        }
        XCTAssertEqual(outside, 2_500)

        // A selection still outranks the fallback center, as with `+`.
        view.selection = try TraceTimeRange.query(startNs: 2_100, endNs: 2_300)
        view.performKeyboardCommand(.zoomInAtPointer)
        guard case .zoom(let selected, _, _) = try XCTUnwrap(intents.last) else {
            return XCTFail("expected a zoom intent")
        }
        XCTAssertEqual(selected, 2_200)
    }

    @MainActor
    func testPointerLeavingTheTimelineDropsTheAnchor() throws {
        let (view, _) = try makeView()
        var intents: [TimelineViewportIntent] = []
        view.onViewportIntent = { intents.append($0) }
        view.updatePointerLocation(CGPoint(x: 80, y: 30))
        guard
            let exit = NSEvent.enterExitEvent(
                with: .mouseExited,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                trackingNumber: 0,
                userData: nil
            )
        else { return XCTFail("could not synthesize a mouse-exited event") }
        view.mouseExited(with: exit)

        view.performKeyboardCommand(.zoomInAtPointer)
        guard case .zoom(let anchor, _, _) = try XCTUnwrap(intents.first) else {
            return XCTFail("expected a zoom intent")
        }
        XCTAssertEqual(anchor, 2_500)
    }

    /// `+` / `-` keep their existing anchor chain — the pointer anchor is a
    /// property of the WASD cluster, not a change to the older bindings.
    @MainActor
    func testPlusAndMinusKeepTheirExistingAnchor() throws {
        let (view, _) = try makeView()
        var intents: [TimelineViewportIntent] = []
        view.onViewportIntent = { intents.append($0) }
        view.updatePointerLocation(CGPoint(x: 80, y: 30))

        view.keyDown(with: try keyDown("+"))
        guard case .zoom(let anchor, let scale, _) = try XCTUnwrap(intents.first) else {
            return XCTFail("+ must zoom in")
        }
        XCTAssertEqual(anchor, 2_500)
        XCTAssertEqual(scale, 0.5)
    }

    /// Upstream binds `[` and `]` to the same zoom-to-selection action as `F`.
    @MainActor
    func testBracketKeysAliasZoomToSelection() throws {
        let (view, _) = try makeView()
        var zoomed = 0
        view.onZoomSelection = { zoomed += 1 }
        view.selection = try TraceTimeRange.query(startNs: 2_100, endNs: 2_300)

        view.keyDown(with: try keyDown("f"))
        view.keyDown(with: try keyDown("["))
        view.keyDown(with: try keyDown("]"))
        XCTAssertEqual(zoomed, 3)
    }

    /// The timeline must not swallow a Command-modified letter; ⌘W belongs to
    /// Close Window.
    @MainActor
    func testCommandModifiedLettersAreNotTimelineNavigation() throws {
        let (view, _) = try makeView()
        var intents: [TimelineViewportIntent] = []
        view.onViewportIntent = { intents.append($0) }
        view.updatePointerLocation(CGPoint(x: 80, y: 30))

        // Put the view in a window so the unhandled event has a real responder
        // chain to fall off, rather than terminating on a detached view.
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView?.addSubview(view)

        view.keyDown(with: try keyDown("w", modifiers: .command))
        XCTAssertTrue(intents.isEmpty, "⌘W must not zoom the timeline")

        view.keyDown(with: try keyDown("w"))
        XCTAssertEqual(intents.count, 1, "unmodified W still zooms")
    }

    /// A pointer-anchored zoom is still refused when it would not move the
    /// viewport, so assistive technology and the key path agree.
    @MainActor
    func testPointerZoomIsRefusedWhenAlreadyAtTheBound() throws {
        let (view, viewport) = try makeView()
        var intents: [TimelineViewportIntent] = []
        view.onViewportIntent = { intents.append($0) }
        view.interactionBounds = viewport.range

        XCTAssertFalse(view.performKeyboardCommand(.zoomOutAtPointer))
        XCTAssertTrue(intents.isEmpty)
    }
}
