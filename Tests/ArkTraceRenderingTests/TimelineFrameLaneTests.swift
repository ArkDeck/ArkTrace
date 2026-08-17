import ArkTraceCore
@testable import ArkTraceRendering
import XCTest

/// Frame lanes. The requirement with teeth is AT-APP-011: a jank verdict must
/// not be carried by colour alone.
final class TimelineFrameLaneTests: XCTestCase {
    private func frame(
        _ rowID: Int64, kind: TraceFrameKind, vsync: Int64, flag: Int64?
    ) throws -> TraceFrame {
        TraceFrame(
            key: EventKey(table: .frameSlice, rowID: rowID),
            range: try TraceTimeRange(startNs: 100, endNs: 200),
            kind: kind,
            vsync: vsync,
            processKey: ProcessKey(ipid: 1),
            pid: 100,
            processName: "app",
            flag: flag,
            isOpenEnded: false
        )
    }

    /// The label states the verdict in words, so a monochrome or colour-blind
    /// reading still conveys it.
    func testJankIsStatedInWordsNotOnlyColour() throws {
        let janked = try frame(1, kind: .actual, vsync: 900, flag: 1)
        let onTime = try frame(2, kind: .actual, vsync: 901, flag: 2)
        let deadline = try frame(3, kind: .actual, vsync: 902, flag: 3)

        XCTAssertTrue(
            TimelineSnapshotLoader.frameLabel(janked, jankTag: 1).contains("jank"),
            "the label itself must say jank"
        )
        XCTAssertFalse(
            TimelineSnapshotLoader.frameLabel(onTime, jankTag: 0).contains("jank")
        )
        XCTAssertTrue(
            TimelineSnapshotLoader.frameLabel(deadline, jankTag: 3).contains("jank")
        )
        // The Inspector row / accessibility value carries it too.
        XCTAssertEqual(TimelineSnapshotLoader.jankStateText(1), "jank")
        XCTAssertEqual(TimelineSnapshotLoader.jankStateText(3), "jank (deadline missed)")
        XCTAssertEqual(TimelineSnapshotLoader.jankStateText(0), "on time")

        // The label also says which side of the vsync it is, since expected and
        // actual share a lane.
        XCTAssertTrue(
            TimelineSnapshotLoader.frameLabel(
                try frame(4, kind: .expected, vsync: 900, flag: 2), jankTag: 0
            ).contains("expected")
        )
        XCTAssertTrue(
            TimelineSnapshotLoader.frameLabel(onTime, jankTag: 0).contains("actual")
        )
    }

    /// Colour is the second signal and follows upstream's JANK_COLOR.
    func testJankColoursMatchUpstreamTable() {
        // #FF651D for jank_tag 1, #E8BE44 for 3, #42A14D otherwise.
        XCTAssertEqual(
            TimelinePalette.jankColor(tag: 1),
            TimelineColor(red: 0xFF, green: 0x65, blue: 0x1D)
        )
        XCTAssertEqual(
            TimelinePalette.jankColor(tag: 3),
            TimelineColor(red: 0xE8, green: 0xBE, blue: 0x44)
        )
        XCTAssertEqual(
            TimelinePalette.jankColor(tag: 0),
            TimelineColor(red: 0x42, green: 0xA1, blue: 0x4D)
        )
        XCTAssertEqual(
            TimelinePalette.jankColor(tag: 2), TimelinePalette.jankColor(tag: 0),
            "only 1 and 3 are jank; anything else is the normal colour"
        )
    }

    /// Expected sits above its actual frame. The pair key is vsync + process,
    /// because `frame_slice.dst` is NULL throughout real captures.
    func testExpectedAndActualOccupyDistinctRowsOfOneLane() throws {
        let descriptor = TrackDescriptor(
            title: "Frames", source: .frame(ProcessKey(ipid: 1))
        )
        let expected = TimelineDetailPrimitive(
            trackID: descriptor.id,
            eventKey: EventKey(table: .frameSlice, rowID: 1),
            range: try TraceTimeRange(startNs: 100, endNs: 200),
            label: "vsync 900 expected", category: "frame", depth: 0
        )
        let actual = TimelineDetailPrimitive(
            trackID: descriptor.id,
            eventKey: EventKey(table: .frameSlice, rowID: 2),
            range: try TraceTimeRange(startNs: 100, endNs: 200),
            label: "vsync 900 actual · jank", category: "frame", depth: 1, jankTag: 1
        )
        let track = TimelineTrackSnapshot(
            descriptor: descriptor,
            y: 0,
            height: TimelineGeometry.trackHeight(depthRowCount: 2),
            primitives: [.detail(expected), .detail(actual)],
            depthRowCount: 2
        )
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 100, heightPoints: 80, generation: 1
        )
        let expectedFrame = TimelineGeometry.frame(
            for: .detail(expected), in: track, viewport: viewport, backingScale: 2
        )
        let actualFrame = TimelineGeometry.frame(
            for: .detail(actual), in: track, viewport: viewport, backingScale: 2
        )
        // Same time span, different rows: without depth rows they would overlap
        // exactly and the pair would be unreadable.
        XCTAssertEqual(expectedFrame.minX, actualFrame.minX, accuracy: 0.001)
        XCTAssertLessThan(expectedFrame.minY, actualFrame.minY, "expected sits above")
        XCTAssertFalse(expectedFrame.intersects(actualFrame))
    }

    func testFrameTrackAndDensitySourcesAreStable() {
        let source = TimelineTrackSource.frame(ProcessKey(ipid: 7))
        XCTAssertEqual(source.stableID.rawValue, "frame:7")
        XCTAssertEqual(
            TimelineTrackSource.frame(nil).stableID.rawValue, "frame:all"
        )
        guard case .frame(let processKey) = source.densitySource else {
            return XCTFail("frame tracks need a density source for zoomed-out LOD")
        }
        XCTAssertEqual(processKey, ProcessKey(ipid: 7))
    }
}
