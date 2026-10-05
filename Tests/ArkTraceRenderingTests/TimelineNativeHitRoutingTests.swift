import AppKit
import ArkTraceCore
@testable import ArkTraceRendering
import XCTest

final class TimelineNativeHitRoutingTests: XCTestCase {
    private enum Owner: TimelineNativeHitOwner {
        case value, miss, busy, invalid
        func event(at point: CGPoint, viewport: TimelineViewport, backingScale: Double) throws -> EventKey? {
            switch self {
            case .value: EventKey(table: .callstack, rowID: Int64(viewport.generation))
            case .miss: nil
            case .busy: throw TimelineNativeHitError.busy
            case .invalid: throw CocoaError(.coderReadCorrupt)
            }
        }
        func densityBand(at point: CGPoint, viewport: TimelineViewport, backingScale: Double) throws -> TimelineDensityHit? {
            switch self {
            case .value: TimelineDensityHit(trackID: TimelineTrackID(rawValue: "native"), bucket: viewport.range, timeNs: viewport.range.startNs)
            case .miss: nil
            case .busy: throw TimelineNativeHitError.busy
            case .invalid: throw CocoaError(.coderReadCorrupt)
            }
        }
    }
    private func snapshot(_ owner: Owner?) throws -> TimelineSnapshot {
        let range = try TraceTimeRange.query(startNs: 0, endNs: 1_000)
        let viewport = try TimelineViewport(range: range, widthPoints: 100, heightPoints: 80, generation: 1)
        let descriptor = TrackDescriptor(title: "CPU", source: .cpu(0))
        let detail = TimelinePrimitive.detail(TimelineDetailPrimitive(trackID: descriptor.id,
            eventKey: EventKey(table: .schedSlice, rowID: 99),
            range: try TraceTimeRange(startNs: 100, endNs: 200), label: "legacy"))
        let density = TimelinePrimitive.density(TimelineDensityPrimitive(trackID: descriptor.id,
            bucket: TraceDensityBucket(range: range, eventCount: 1, occupiedNs: nil, utilization: nil, dominant: nil)))
        var result = TimelineSnapshot(viewport: viewport,
            tracks: [TimelineTrackSnapshot(descriptor: descriptor, y: 0, height: 28, primitives: [detail, density])],
            generation: 1, dataQuality: TraceDataQuality())
        if let owner { result.retainNativeProjection(owner) }
        return result
    }
    @MainActor func testNativeResultAndMissDoNotFallThroughToCopiedPrimitives() throws {
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
        let point = CGPoint(x: 15, y: 34)
        view.snapshot = try snapshot(.value)
        XCTAssertEqual(view.event(at: point), EventKey(table: .callstack, rowID: 1))
        XCTAssertEqual(view.densityBand(at: point)?.trackID.rawValue, "native")
        view.snapshot = try snapshot(.miss)
        XCTAssertNil(view.event(at: point)); XCTAssertNil(view.densityBand(at: point))
    }
    @MainActor func testOnlyBusyUsesSwiftFallbackAndInvalidNativeResultFailsClosed() throws {
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
        let point = CGPoint(x: 15, y: 34)
        view.snapshot = try snapshot(.busy)
        XCTAssertEqual(view.event(at: point), EventKey(table: .schedSlice, rowID: 99))
        XCTAssertEqual(view.densityBand(at: point)?.trackID.rawValue, "cpu:0")
        view.snapshot = try snapshot(.invalid)
        XCTAssertNil(view.event(at: point)); XCTAssertNil(view.densityBand(at: point))
    }
    @MainActor func testLoadingDisplayPreservesOwnerAndCodingRemovesIt() throws {
        let original = try snapshot(.value)
        let viewport = try TimelineViewport(range: TraceTimeRange.query(startNs: 300, endNs: 600),
            widthPoints: 50, heightPoints: 100, verticalOffsetPoints: 10, generation: 2)
        let loading = original.displaying(viewport: viewport, isLoading: true)
        XCTAssertNotNil(loading.nativeHitOwner); XCTAssertEqual(loading.tracks, original.tracks)
        let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 50, height: 100)); view.snapshot = loading
        XCTAssertEqual(view.event(at: .zero), EventKey(table: .callstack, rowID: 2))
        XCTAssertEqual(view.densityBand(at: .zero)?.bucket, viewport.range)
        let decoded = try JSONDecoder().decode(TimelineSnapshot.self, from: JSONEncoder().encode(loading))
        XCTAssertNil(decoded.nativeHitOwner); XCTAssertEqual(decoded, loading)
    }
}
