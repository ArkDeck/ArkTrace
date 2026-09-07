import AppKit
import ArkTraceCore
@testable import ArkTraceRendering
import XCTest

/// Pressing a density band.
///
/// Below the detail budget a track is drawn as buckets, and a bucket is an
/// aggregate: it names no event, so the canvas cannot answer a press out of the
/// snapshot the way it does for a slice. It reports the press instead, and the
/// host resolves the real event there. That exchange is what these tests pin —
/// the hit the canvas reports, the gesture that produces it, and the event the
/// store is asked for.
final class TimelineDensitySelectionTests: XCTestCase {
    /// 0…1000 ns across 200 points, so one point is 5 ns. Four 250 ns buckets.
    @MainActor
    private func makeView() throws -> (TimelineNSView, TimelineTrackSnapshot) {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 200,
            heightPoints: 80,
            generation: 1
        )
        let descriptor = TrackDescriptor(title: "CPU 0", source: .cpu(0))
        let primitives = try (0..<4).map { index in
            TimelinePrimitive.density(
                TimelineDensityPrimitive(
                    trackID: descriptor.id,
                    bucket: TraceDensityBucket(
                        range: try TraceTimeRange.query(
                            startNs: Int64(index) * 250, endNs: Int64(index + 1) * 250
                        ),
                        // A quiet bucket, so the drawn band is a fraction of
                        // the row: the press still has to find it.
                        eventCount: 1,
                        occupiedNs: nil,
                        utilization: nil,
                        dominant: nil
                    )
                )
            )
        }
        let track = TimelineTrackSnapshot(
            descriptor: descriptor, y: 0, height: 28, primitives: primitives
        )
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        view.snapshot = TimelineSnapshot(
            viewport: viewport,
            tracks: [track],
            generation: 1,
            dataQuality: TraceDataQuality()
        )
        view.interactionBounds = try TraceTimeRange.query(startNs: 0, endNs: 1_000)
        return (view, track)
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

    /// The whole track row answers, not just the drawn band. Intensity is
    /// carried by a band's height, so a quiet bucket is a couple of points
    /// tall; if only those points were pressable the tracks with the least on
    /// them would be the hardest to inspect, and no target would clear
    /// AT-APP-011's 24 point floor.
    @MainActor
    func testTheWholeRowIsTheTargetAndTheBucketUnderThePointerAnswers() throws {
        let (view, track) = try makeView()
        let row = TimelineGeometry.trackFrame(track)
        for y in [row.minY + 1, row.midY, row.maxY - 1] {
            let hit = try XCTUnwrap(view.densityBand(at: CGPoint(x: 110, y: y)))
            XCTAssertEqual(hit.trackID, track.descriptor.id)
            XCTAssertEqual(hit.bucket.startNs, 500)
            XCTAssertEqual(hit.bucket.endNs, 750)
            XCTAssertEqual(hit.timeNs, 550)
        }
        XCTAssertNil(
            view.densityBand(at: CGPoint(x: 110, y: row.maxY + 4)),
            "below the track there is no band to press"
        )
        // Density carries no event of its own; that is the whole reason the
        // press has to be resolved elsewhere.
        XCTAssertNil(view.event(at: CGPoint(x: 110, y: row.midY)))
    }

    /// A press that does not move is a click. A press that moves is a range
    /// drag, and stays one: at a zoom where whole tracks are drawn as bands
    /// there is barely any empty canvas left to start a range from, so
    /// selecting on the press itself would cost the range gesture outright.
    @MainActor
    func testAClickSelectsTheBandAndADragStillSweepsARange() throws {
        let (view, track) = try makeView()
        var hits: [TimelineDensityHit] = []
        var ranges: [TraceTimeRange?] = []
        view.onSelectDensityBand = { hits.append($0) }
        view.onSelectRange = { ranges.append($0) }
        let press = CGPoint(x: 110, y: TimelineGeometry.trackFrame(track).midY)

        view.mouseDown(with: try mouse(.leftMouseDown, viewPoint: press))
        XCTAssertTrue(hits.isEmpty, "the press alone decides nothing")
        view.mouseUp(with: try mouse(.leftMouseUp, viewPoint: press))
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.timeNs, 550)
        XCTAssertNil(view.selection, "a click leaves no range behind")

        hits.removeAll()
        view.mouseDown(with: try mouse(.leftMouseDown, viewPoint: press))
        view.mouseDragged(with: try mouse(.leftMouseDragged, viewPoint: CGPoint(x: 150, y: press.y)))
        view.mouseUp(with: try mouse(.leftMouseUp, viewPoint: CGPoint(x: 150, y: press.y)))
        XCTAssertTrue(hits.isEmpty, "the gesture became a range drag")
        XCTAssertEqual(view.selection?.startNs, 550)
        XCTAssertEqual(view.selection?.endNs, 750)
        XCTAssertEqual(ranges.last??.startNs, 550)
    }

    /// A real click is never perfectly still.
    ///
    /// `mouseDragged` decides "did this move?" by comparing the anchor and the
    /// pointer in *nanoseconds*, and the whole viewport maps onto a few hundred
    /// points, so a fraction of a point is already a different nanosecond. On
    /// a real capture zoomed to density one point is tens of microseconds, and
    /// the hand tremor in an ordinary click is a point or two -- which nils the
    /// pending hit and leaves a hairline range behind instead of a selection.
    @MainActor
    func testAClickWithOrdinaryHandTremorIsStillAClick() throws {
        for jitter in [CGFloat(0.25), 0.5, 1, 2] {
            let (view, track) = try makeView()
            var hits: [TimelineDensityHit] = []
            view.onSelectDensityBand = { hits.append($0) }
            let press = CGPoint(x: 110, y: TimelineGeometry.trackFrame(track).midY)
            let release = CGPoint(x: press.x + jitter, y: press.y)
            view.mouseDown(with: try mouse(.leftMouseDown, viewPoint: press))
            view.mouseDragged(with: try mouse(.leftMouseDragged, viewPoint: release))
            view.mouseUp(with: try mouse(.leftMouseUp, viewPoint: release))
            XCTAssertEqual(
                hits.count, 1,
                "a \(jitter) point wobble must not turn a click into a range drag"
            )
            XCTAssertNil(
                view.selection,
                "a \(jitter) point wobble must not leave a range behind"
            )
        }
    }

    /// The mark a resolved press leaves has to land on the block that was
    /// pressed.
    ///
    /// DESIGN §13.5: 「画布按 band 的同一个矩形描边——否则点击只会填满 Inspector，
    /// 时间轴上却看不出选中了哪一桶」. The first implementation outlined the
    /// resolved *event's* range instead, then widened it to a 6 point minimum
    /// about its own centre -- so a press on a 50 point bucket left a 6 point
    /// box floating inside it, aligned with nothing.
    @MainActor
    func testTheResolvedSelectionIsMarkedOnTheBucketNotTheEvent() throws {
        let (view, track) = try makeView()
        let snapshot = try XCTUnwrap(view.snapshot)
        // An event 10 ns long (2 points) inside the 500…750 ns bucket, which
        // spans x 100…150.
        view.selectedEventKey = EventKey(table: .callstack, rowID: 7)
        view.selectedEventLocation = TimelineEventLocation(
            trackID: track.descriptor.id,
            range: try TraceTimeRange.query(startNs: 560, endNs: 570)
        )
        let outline = try XCTUnwrap(
            view.resolvedSelectionOutline(in: snapshot, backingScale: 2)
        )
        let bucket = TimelineGeometry.bandFrame(
            for: try TraceTimeRange.query(startNs: 500, endNs: 750),
            in: track, viewport: snapshot.viewport, backingScale: 2
        )
        XCTAssertEqual(outline, bucket, "the mark belongs on the bucket that answered")
        XCTAssertEqual(outline.minX, 100, accuracy: 0.01)
        XCTAssertEqual(outline.width, 50, accuracy: 0.01)

        // An event spanning two buckets is marked across both, so the mark
        // still covers exactly the blocks it came out of.
        view.selectedEventLocation = TimelineEventLocation(
            trackID: track.descriptor.id,
            range: try TraceTimeRange.query(startNs: 600, endNs: 800)
        )
        let wide = try XCTUnwrap(
            view.resolvedSelectionOutline(in: snapshot, backingScale: 2)
        )
        XCTAssertEqual(wide.minX, 100, accuracy: 0.01)
        XCTAssertEqual(wide.width, 100, accuracy: 0.01, "500…1000 ns is two buckets")
    }

    /// A press on a track drawn in detail is answered by the snapshot, so it
    /// must not also ask the host to resolve one.
    @MainActor
    func testADetailTrackNeverReportsABandPress() throws {
        let viewport = try TimelineViewport(
            range: TraceTimeRange.query(startNs: 0, endNs: 1_000),
            widthPoints: 200, heightPoints: 80, generation: 1
        )
        let descriptor = TrackDescriptor(title: "CPU 0", source: .cpu(0))
        let track = TimelineTrackSnapshot(
            descriptor: descriptor, y: 0, height: 28,
            primitives: [
                .detail(
                    TimelineDetailPrimitive(
                        trackID: descriptor.id,
                        eventKey: EventKey(table: .schedSlice, rowID: 1),
                        range: try TraceTimeRange(startNs: 200, endNs: 600),
                        label: "worker"
                    )
                )
            ]
        )
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        view.snapshot = TimelineSnapshot(
            viewport: viewport, tracks: [track], generation: 1,
            dataQuality: TraceDataQuality()
        )
        var hits: [TimelineDensityHit] = []
        view.onSelectDensityBand = { hits.append($0) }
        let point = CGPoint(x: 80, y: TimelineGeometry.trackFrame(track).midY)
        XCTAssertNil(view.densityBand(at: point))
        view.mouseDown(with: try mouse(.leftMouseDown, viewPoint: point))
        view.mouseUp(with: try mouse(.leftMouseUp, viewPoint: point))
        XCTAssertTrue(hits.isEmpty)
    }

    /// The mark a resolved selection leaves is the rectangle the band it
    /// replaced occupied, so the outline lands on the row the press was made
    /// on rather than a row's worth of padding away from it.
    @MainActor
    func testTheResolvedOutlineSharesTheBandGeometry() throws {
        let (view, track) = try makeView()
        let viewport = try XCTUnwrap(view.snapshot?.viewport)
        let bucket = try XCTUnwrap(track.primitives.first)
        let bandFrame = TimelineGeometry.frame(
            for: bucket, in: track, viewport: viewport, backingScale: 2
        )
        XCTAssertEqual(
            bandFrame,
            TimelineGeometry.bandFrame(
                for: bucket.range, in: track, viewport: viewport, backingScale: 2
            )
        )
        // A resolved event is usually far narrower than a bucket, and a stroke
        // inset into a rectangle that thin would collapse to nothing.
        let instant = TimelineGeometry.bandFrame(
            for: try TraceTimeRange(startNs: 100, endNs: 101),
            in: track, viewport: viewport, backingScale: 2
        )
        XCTAssertLessThan(instant.width, TimelineNSView.resolvedSelectionMinimumWidth)
        XCTAssertEqual(instant.midY, bandFrame.midY)

        let detailTrack = TimelineTrackSnapshot(
            descriptor: track.descriptor, y: track.y, height: track.height, primitives: []
        )
        let snapshot = TimelineSnapshot(
            viewport: viewport, tracks: [detailTrack], generation: 2,
            dataQuality: TraceDataQuality()
        )
        view.selectedEventKey = EventKey(table: .schedSlice, rowID: 1)
        view.selectedEventLocation = TimelineEventLocation(
            trackID: track.descriptor.id,
            range: try TraceTimeRange.query(startNs: 100, endNs: 101)
        )
        let outline = try XCTUnwrap(view.resolvedSelectionOutline(in: snapshot, backingScale: 2))
        XCTAssertEqual(outline.width, TimelineNSView.resolvedSelectionMinimumWidth)
        XCTAssertEqual(outline.midX, instant.midX)
        XCTAssertEqual(outline.minY, instant.minY)
        XCTAssertEqual(outline.height, instant.height)
    }

    /// Ranking a press: anything covering the instant wins, and among those
    /// the longest does — the outer frame of a stack is the one whose colour
    /// the band borrowed, so it is the slice the reader was looking at.
    func testResolutionPrefersCoveringThenLongestThenLowestRow() throws {
        func detail(_ rowID: Int64, _ start: Int64, _ end: Int64) throws -> TimelinePrimitive {
            .detail(
                TimelineDetailPrimitive(
                    trackID: TimelineTrackID(rawValue: "cpu:0"),
                    eventKey: EventKey(table: .callstack, rowID: rowID),
                    range: try TraceTimeRange(startNs: start, endNs: end),
                    label: nil
                )
            )
        }
        let outer = try detail(1, 100, 900)
        let inner = try detail(2, 400, 500)
        let elsewhere = try detail(3, 950, 960)
        XCTAssertEqual(
            TimelineSnapshotLoader.resolution(at: 450, among: [inner, outer, elsewhere])?
                .eventKey.rowID,
            1,
            "both cover the instant, so the longer one answers"
        )
        XCTAssertEqual(
            TimelineSnapshotLoader.resolution(at: 930, among: [outer, elsewhere])?
                .eventKey.rowID,
            3,
            "nothing covers it, so the nearest answers"
        )
        XCTAssertNil(TimelineSnapshotLoader.resolution(at: 450, among: []))
    }

    /// The two queries a press is worth, and no more.
    ///
    /// The instant is asked first because that is what the pointer was aimed
    /// at, and event queries intersect their range, so a one-nanosecond window
    /// still returns whatever covers it. The bucket is only asked when nothing
    /// does — which is the ordinary case on a quiet track, where a band is
    /// drawn across a whole bucket that holds one short slice.
    func testResolveAsksTheInstantFirstAndTheBucketOnlyOnAMiss() async throws {
        let thread = ThreadKey(itid: 1)
        let track = TrackDescriptor(title: "main", source: .namedSlice(thread))
        let repository = SliceRepository(
            slices: [
                try slice(rowID: 1, start: 100, end: 400, name: "covering", thread: thread),
                try slice(rowID: 2, start: 900, end: 910, name: "elsewhere", thread: thread),
            ]
        )
        let loader = TimelineSnapshotLoader()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let bucket = try TraceTimeRange.query(startNs: 0, endNs: 1_000)

        let covered = try await loader.resolveEvent(
            TimelineDensityHit(trackID: track.id, bucket: bucket, timeNs: 200),
            track: track, deadline: deadline, repository: repository
        )
        XCTAssertEqual(covered?.name, "covering")
        let afterCovered = await repository.queriedRanges()
        XCTAssertEqual(
            afterCovered.count, 1,
            "the instant answered it, so the bucket was never asked for"
        )

        let missed = try await loader.resolveEvent(
            TimelineDensityHit(trackID: track.id, bucket: bucket, timeNs: 700),
            track: track, deadline: deadline, repository: repository
        )
        XCTAssertEqual(
            missed?.name, "elsewhere",
            "a press on the empty part of a band still selects what the band is made of"
        )
        let ranges = await repository.queriedRanges()
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges[1].startNs, 700)
        XCTAssertEqual(ranges[1].endNs, 701)
        XCTAssertEqual(ranges[2], bucket)
    }

    private func slice(
        rowID: Int64, start: Int64, end: Int64, name: String, thread: ThreadKey
    ) throws -> TraceSlice {
        TraceSlice(
            key: EventKey(table: .callstack, rowID: rowID),
            range: try TraceTimeRange(startNs: start, endNs: end),
            threadKey: thread,
            processKey: nil,
            name: name,
            category: "slice",
            depth: 0,
            parentEventKey: nil,
            isAsync: false,
            isOpenEnded: false
        )
    }

    /// Returns the slices intersecting the queried range, the way the Store
    /// does, and records what it was asked for.
    private actor SliceRepository: TraceRepositoryProtocol {
        private let slices: [TraceSlice]
        private var ranges: [TraceTimeRange] = []

        init(slices: [TraceSlice]) {
            self.slices = slices
        }

        func queriedRanges() -> [TraceTimeRange] { ranges }

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
            .unavailable
        }
        func eventBatch(
            _ batch: TraceRepositoryEventBatch
        ) async throws -> TraceRepositoryEventBatchResult {
            TraceRepositoryEventBatchResult(
                cpuSlices: [], threadStates: [], slices: [], counters: [], densities: []
            )
        }
        func slices(_ query: TraceSliceQuery) async throws -> TraceEventPage<TraceSlice> {
            ranges.append(query.range)
            let matched = slices.filter {
                $0.range.endNs >= query.range.startNs
                    && $0.range.startNs <= query.range.endNs
                    && (query.eventKey == nil || $0.key == query.eventKey)
            }
            return TraceEventPage(
                items: Array(matched.prefix(query.limit)),
                truncated: matched.count > query.limit
            )
        }
    }
}
