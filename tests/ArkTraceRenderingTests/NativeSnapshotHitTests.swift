#if ARKTRACE_NATIVE_RUNTIME && ARKTRACE_RUST_PROCESS_FIXTURES
import AppKit
import ArkTraceCore
@testable import ArkTraceRustRuntime
@testable import ArkTraceRendering
import Foundation
import XCTest

final class NativeSnapshotHitTests: XCTestCase, @unchecked Sendable {
    private struct Input: Decodable, Sendable {
        let source: String
        let helper: String
        let parser: String
        let helperSHA256: String
        let parserIdentity: TraceParserIdentity
        let runtimeRoot: String
    }
    @MainActor private final class Window: NSWindow {
        var scale: CGFloat = 1
        override var backingScaleFactor: CGFloat { scale }
    }
    private struct Observations: Codable, Sendable {
        var pointCount = 0
        var detailHits = 0
        var densityHits = 0
        var misses = 0
        var loadingDisplays = 0
    }
    @MainActor private static func compare(_ snapshots: [TimelineSnapshot]) throws -> Observations {
        var observations = Observations()
        for retained in snapshots {
            XCTAssertNotNil(retained.nativeHitOwner)
            let vp = retained.viewport
            let changed = try TimelineViewport(range: TraceTimeRange.query(
                startNs: vp.range.startNs + vp.range.durationNs / 4, endNs: vp.range.endNs),
                widthPoints: vp.widthPoints / 2, heightPoints: vp.heightPoints + 20,
                verticalOffsetPoints: 10, generation: vp.generation + 100)
            for display in [retained, retained.displaying(viewport: changed, isLoading: true)] {
                if display.isLoading { observations.loadingDisplays += 1 }
                XCTAssertNotNil(display.nativeHitOwner)
                let legacy = try JSONDecoder().decode(TimelineSnapshot.self, from: JSONEncoder().encode(display))
                XCTAssertNil(legacy.nativeHitOwner)
                for scale in [CGFloat(1), CGFloat(2)] {
                    let frame = CGRect(x: 0, y: 0, width: display.viewport.widthPoints, height: display.viewport.heightPoints)
                    let nativeView = TimelineNSView(frame: frame); nativeView.snapshot = display
                    let swiftView = TimelineNSView(frame: frame); swiftView.snapshot = legacy
                    let windows = [Window(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false),
                        Window(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)]
                    windows[0].scale = scale; windows[1].scale = scale
                    windows[0].contentView = nativeView; windows[1].contentView = swiftView
                    defer { windows.forEach { $0.contentView = nil } }
                    var points = [CGPoint(x: -1, y: 34), CGPoint(x: 0, y: 21), CGPoint(x: frame.maxX + 1, y: 34)]
                    for track in display.tracks {
                        let row = TimelineGeometry.trackFrame(track)
                        for primitive in track.primitives {
                            let p = TimelineGeometry.frame(for: primitive, in: track, viewport: display.viewport, backingScale: scale)
                            points += [CGPoint(x: p.midX, y: p.midY), CGPoint(x: max(0, p.minX - 1), y: p.midY),
                                CGPoint(x: max(0, p.minX - 1.0001), y: p.midY), CGPoint(x: p.maxX, y: p.midY),
                                CGPoint(x: p.midX, y: row.minY), CGPoint(x: p.midX, y: row.maxY)]
                        }
                    }
                    for point in points {
                        let nativeEvent = nativeView.event(at: point)
                        let swiftEvent = swiftView.event(at: point)
                        let nativeDensity = nativeView.densityBand(at: point)
                        let swiftDensity = swiftView.densityBand(at: point)
                        XCTAssertEqual(nativeEvent, swiftEvent, "display \(display.generation) scale \(scale) point \(point)")
                        XCTAssertEqual(nativeDensity, swiftDensity, "display \(display.generation) scale \(scale) point \(point)")
                        observations.pointCount += 1
                        if nativeEvent != nil { observations.detailHits += 1 }
                        if nativeDensity != nil { observations.densityHits += 1 }
                        if nativeEvent == nil && nativeDensity == nil { observations.misses += 1 }
                    }
                }
            }
        }
        XCTAssertGreaterThan(observations.detailHits, 0); XCTAssertGreaterThan(observations.densityHits, 0)
        XCTAssertGreaterThan(observations.misses, 0)
        return observations
    }
    // Release ARC holders synchronously before flushing queued native cleanup.
    private final class Held: @unchecked Sendable {
        var scenes: [TimelineSnapshot] = []
        var direct: RustSnapshot?
        @inline(never) func clear() { scenes.removeAll(); direct = nil }
        @inline(never) func rejectInvalidDisplay(_ viewport: RustViewport) throws {
            let value = try XCTUnwrap(direct)
            XCTAssertThrowsError(try value.hit(atX: .nan, y: 34, viewport: viewport, backingScale: 1)) {
                XCTAssertEqual($0 as? RustAdmission, .invalidInput)
            }
        }
        @inline(never) func rulerMiss(_ viewport: RustViewport) throws {
            XCTAssertNil(try XCTUnwrap(direct).hit(atX: 0, y: 0, viewport: viewport, backingScale: 2))
        }
    }
    func testActualNativeHitMatchesCurrentSwiftCopyAndSurvivesEngineRelease() async throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_NATIVE_HIT_INPUT"]
            ?? ProcessInfo.processInfo.environment["ARKTRACE_NATIVE_OWNERSHIP_INPUT"])
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(filePath: path)))
        let namespace = URL(filePath: input.runtimeRoot).appendingPathComponent("retained-hit-canvas")
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let engine = try await RustEngine.createDevelopmentFixture(.developmentFixture(namespace: namespace,
            helper: URL(filePath: input.helper), parser: URL(filePath: input.parser), helperSHA256: input.helperSHA256,
            parserIdentity: input.parserIdentity))
        let session = try await engine.open(URL(filePath: input.source), format: .htrace, timeoutMilliseconds: 8_000)
        let repository = try await RustTraceRepository.create(session: session, sourceFormat: .htrace, operationTimeoutMilliseconds: 5_000)
        let metadata = try await repository.metadata()
        let viewport = try TimelineViewport(range: TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs),
            widthPoints: 800, heightPoints: 600, generation: 1)
        let descriptor = TrackDescriptor(title: "named slices", source: .namedSlice(ThreadKey(itid: 1)))
        let held = Held()
        for preference in [TimelineDetailPreference.detail, .density] {
            let request = try ViewportRequest(viewport: viewport, tracks: [descriptor], pixelWidth: 800,
                generation: viewport.generation, preference: preference, maximumPrimitives: 128,
                deadline: .now.advanced(by: .seconds(15)))
            let loaded = try await NativeTimelineSnapshot.load(request, repository: repository)
            held.scenes.append(try XCTUnwrap(loaded))
        }
        let wire = RustViewport(range: viewport.range, widthPoints: viewport.widthPoints,
            heightPoints: viewport.heightPoints, verticalOffsetPoints: viewport.verticalOffsetPoints, generation: viewport.generation)
        held.direct = try await repository.snapshot(RustViewportQuery(request: RustViewportRequest(viewport: wire,
            tracks: [RustTrack(source: .namedSlice(ThreadKey(itid: 1)))], pixelWidth: 800, generation: 1,
            preference: .detail, maximumPrimitives: 128), backingScale: 1, deadline: .now.advanced(by: .seconds(15))))
        try held.rejectInvalidDisplay(wire)
        let before = try await Self.compare(held.scenes)
        let storage = RustEngine.developmentColdStorageCounts()
        let nativeBytes = try await engine.retainedResultBytes()
        let again = try await Self.compare(held.scenes)
        XCTAssertEqual(again.pointCount, before.pointCount)
        XCTAssertEqual(RustEngine.developmentColdStorageCounts().bytes, storage.bytes)
        XCTAssertEqual(RustEngine.developmentColdStorageCounts().owners, storage.owners)
        let afterHitBytes = try await engine.retainedResultBytes(); XCTAssertEqual(afterHitBytes, nativeBytes)
        try await repository.close(); try await engine.shutdown(); try await RustCleanup.flush()
        let released = try await Self.compare(held.scenes)
        XCTAssertEqual(released.pointCount, before.pointCount)
        // The direct public SDK owner also remains valid after Engine release.
        try held.rulerMiss(wire)
        held.clear(); try await RustCleanup.flush()
        XCTAssertEqual(RustEngine.developmentColdStorageCounts().bytes, 0)
        XCTAssertEqual(RustEngine.developmentColdStorageCounts().owners, 0)
        // No post-release native zero-byte telemetry claim: Engine is gone.
        let transcript: [String: Any] = ["actualEngineOpens": 1, "actualNativeTimelineLoads": 2,
            "actualDirectSDKLoads": 1, "comparisonRuns": 3, "pointsPerRun": before.pointCount,
            "detailHitsPerRun": before.detailHits, "densityHitsPerRun": before.densityHits,
            "missesPerRun": before.misses, "loadingDisplaysPerRun": before.loadingDisplays,
            "nativeHitAfterEngineRelease": true, "independentSwiftDatabaseBackend": false,
            "noNewRetainedCreditDuringHits": true, "GUIAcceptance": false]
        if let output = ProcessInfo.processInfo.environment["ARKTRACE_NATIVE_HIT_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: transcript, options: [.sortedKeys, .prettyPrinted])
                .write(to: URL(filePath: output), options: .atomic)
        }
    }
}
#endif
