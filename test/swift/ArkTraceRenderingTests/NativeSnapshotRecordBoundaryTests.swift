#if ARKTRACE_NATIVE_RUNTIME
import ArkTraceCore
import ArkTraceRustRuntime
@testable import ArkTraceRendering
import CArkTrace
import CoreGraphics
import Foundation
import XCTest

final class NativeSnapshotRecordBoundaryTests: XCTestCase {
    private struct Fixture {
        var request: ViewportRequest
        var viewport: ArkTraceViewportRecord
        var tracks: [ArkTraceTrackRecord]
        var primitives: [ArkTracePrimitiveRecord]
        var quality: [ArkTraceQualityRecord] = []
        var strings: [UInt8]
        var qualityStatus = UInt32(ARKTRACE_QUALITY_STATUS_OK)
        mutating func text(_ value: String) -> (UInt32, UInt32) {
            let offset = UInt32(strings.count)
            strings.append(contentsOf: value.utf8)
            return (offset, UInt32(value.utf8.count))
        }
    }
    private struct Counts {
        var variants = 0
        var calls = 0
        var rejections = 0
        var recoveries = 0
    }
    private func actualABI() {
        var value = ArkTraceAbiIdentity()
        XCTAssertEqual(arktrace_abi_identity(&value, UInt64(MemoryLayout<ArkTraceAbiIdentity>.size)), UInt32(ARKTRACE_STATUS_OK))
        XCTAssertEqual(value.abi_version, 2)
        XCTAssertEqual(ARKTRACE_ABI_VERSION, 2)
    }
    private func fixture(ownerZero: Bool = false, maximum: Int = 6) throws -> Fixture {
        // Explicit ABI2 input fixtures. Serialization only; expected conversion
        // comes from the actual converter, never an alternate implementation.
        let specs: [(TimelineTrackSource, UInt32, Int64, Int64, Int64, Bool, UInt32, UInt32)] = [
            (.cpu(0), UInt32(ARKTRACE_SOURCE_CPU), 0, 0, 0, false, UInt32(ARKTRACE_TABLE_SCHED_SLICE), 1),
            (.threadState(ThreadKey(itid: 0)), UInt32(ARKTRACE_SOURCE_THREAD_STATE), 0, 0, 0, false, UInt32(ARKTRACE_TABLE_THREAD_STATE), 2),
            (.namedSlice(ownerZero ? ThreadKey(itid: 0) : nil), UInt32(ARKTRACE_SOURCE_NAMED_SLICE), 0, 0, 0, ownerZero, UInt32(ARKTRACE_TABLE_CALLSTACK), 3),
            (.cpuCounter(filterID: 0, cpu: ownerZero ? 0 : nil), UInt32(ARKTRACE_SOURCE_CPU_COUNTER), 0, 0, 0, ownerZero, UInt32(ARKTRACE_TABLE_MEASURE), 4),
            (.processCounter(filterID: 0, processKey: ownerZero ? ProcessKey(ipid: 0) : nil), UInt32(ARKTRACE_SOURCE_PROCESS_COUNTER), 0, 0, 0, ownerZero, UInt32(ARKTRACE_TABLE_PROCESS_MEASURE), 4),
            (.frame(ownerZero ? ProcessKey(ipid: 0) : nil), UInt32(ARKTRACE_SOURCE_FRAME), 0, 0, 0, ownerZero, UInt32(ARKTRACE_TABLE_FRAME_SLICE), 5),
        ]
        let range = try TraceTimeRange.query(startNs: 0, endNs: 100)
        let viewport = try TimelineViewport(range: range, widthPoints: 200, heightPoints: 300, generation: 1)
        var descriptors: [TrackDescriptor] = []
        var tracks: [ArkTraceTrackRecord] = []
        var primitives: [ArkTracePrimitiveRecord] = []
        var strings: [UInt8] = []
        for (index, spec) in specs.enumerated() {
            if index == 1 || index == 5 {
                descriptors.append(TrackDescriptor(title: "hidden", source: .cpu(Int64(index + 90)), isCollapsed: true))
            }
            let nested = index.isMultiple(of: 2)
            let descriptor = TrackDescriptor(title: "source \(index)", source: spec.0, showsNestedDepth: nested)
            descriptors.append(descriptor)
            var track = ArkTraceTrackRecord()
            track.source_kind = spec.1; track.source_value = spec.2; track.filter_id = spec.3; track.owner_value = spec.4
            track.flags = (nested ? UInt32(ARKTRACE_TRACK_NESTED) : 0) | (spec.5 ? UInt32(ARKTRACE_TRACK_OWNER) : 0)
            track.id_offset = UInt32(strings.count); track.id_length = UInt32(descriptor.id.rawValue.utf8.count)
            strings.append(contentsOf: descriptor.id.rawValue.utf8)
            track.y = Double(index * 28); track.height = 28; track.depth_rows = 1
            track.primitive_start = UInt32(index); track.primitive_count = 1
            tracks.append(track)
            var p = ArkTracePrimitiveRecord()
            p.kind = UInt32(ARKTRACE_PRIMITIVE_DETAIL); p.track_index = UInt32(index)
            p.event_table = spec.6; p.event_kind = spec.7; p.row_id = 37
            p.end_ns = 10; p.semantic_duration_ns = 10
            p.flags = UInt32(ARKTRACE_FLAG_COLOR | ARKTRACE_FLAG_RENDER_FACTS | ARKTRACE_FLAG_SEMANTIC_DURATION)
            p.color_rgb = 0xabcdef
            primitives.append(p)
        }
        let request = try ViewportRequest(viewport: viewport, tracks: descriptors, pixelWidth: 400,
            generation: 1, maximumPrimitives: maximum, deadline: .now.advanced(by: .seconds(10)))
        var wire = ArkTraceViewportRecord()
        wire.end_ns = 100; wire.width_points = 200; wire.height_points = 300
        wire.ns_per_point = 0.5; wire.generation = 1; wire.source_generation = 1; wire.backing_scale = 2
        return Fixture(request: request, viewport: wire, tracks: tracks, primitives: primitives, strings: strings)
    }
    private func convert(_ f: Fixture) throws -> TimelineSnapshot {
        try f.tracks.withUnsafeBufferPointer { tracks in
            try f.primitives.withUnsafeBufferPointer { primitives in
                try f.quality.withUnsafeBufferPointer { quality in
                    try f.strings.withUnsafeBufferPointer { strings in
                        try NativeTimelineSnapshot.convert(f.request, viewport: f.viewport, qualityStatus: f.qualityStatus,
                            tracks: Span(_unsafeElements: tracks), primitives: Span(_unsafeElements: primitives),
                            quality: Span(_unsafeElements: quality), strings: Span(_unsafeElements: strings))
                    }
                }
            }
        }
    }
    private func accept(_ f: Fixture, _ counts: inout Counts) throws -> TimelineSnapshot {
        counts.variants += 1; counts.calls += 1
        return try convert(f)
    }
    private func reject(_ bad: Fixture, fresh: Fixture, _ counts: inout Counts,
        file: StaticString = #filePath, line: UInt = #line) throws {
        counts.variants += 1; counts.calls += 1
        var partial: TimelineSnapshot?
        do { partial = try convert(bad); XCTFail("invalid record set accepted", file: file, line: line) }
        catch { XCTAssertEqual(error as? RustAdmission, .invalidBuffer, file: file, line: line); counts.rejections += 1 }
        XCTAssertNil(partial, file: file, line: line)
        counts.calls += 1
        let recovered = try convert(fresh)
        XCTAssertEqual(recovered.tracks.map(\.descriptor.id), fresh.request.tracks.filter { !$0.isCollapsed }.map(\.id), file: file, line: line)
        counts.recoveries += 1
    }
    private func emit(_ name: String, _ counts: Counts) throws {
        XCTAssertLessThanOrEqual(counts.variants, 128)
        XCTAssertEqual(counts.rejections, counts.recoveries)
        let data = try JSONSerialization.data(withJSONObject: ["group": name, "variants": counts.variants,
            "actualConvertCalls": counts.calls, "actualInvalidBufferRejections": counts.rejections,
            "freshRecoveries": counts.recoveries, "actualSDKABI": 2, "actualABIIdentityCalls": 1], options: [.sortedKeys])
        print("A26CASE " + String(decoding: data, as: UTF8.self))
    }

    func testSixSourcesOwnersAndContinuousPrimitivePartitions() throws {
        actualABI(); var counts = Counts()
        let base = try fixture()
        let snapshot = try accept(base, &counts)
        XCTAssertEqual(snapshot.tracks.count, 6)
        XCTAssertEqual(snapshot.tracks.map(\.descriptor.source), base.request.tracks.filter { !$0.isCollapsed }.map(\.source))
        XCTAssertEqual(snapshot.tracks.map(\.descriptor.showsNestedDepth), [true, false, true, false, true, false])
        let expectedTables: [TraceEventTable] = [.schedSlice, .threadState, .callstack, .measure, .processMeasure, .frameSlice]
        let keys = try snapshot.tracks.enumerated().map { index, track -> EventKey in
            XCTAssertEqual(track.primitives.count, 1)
            let key = try XCTUnwrap(track.primitives[0].selectableEventKey)
            XCTAssertEqual(key.table, expectedTables[index]); XCTAssertEqual(key.rowID, 37)
            return key
        }
        XCTAssertEqual(Set(keys).count, 6)
        let zero = try fixture(ownerZero: true)
        let zeroSnapshot = try accept(zero, &counts)
        for i in 2..<6 {
            XCTAssertNotEqual(zeroSnapshot.tracks[i].descriptor.id, snapshot.tracks[i].descriptor.id)
            XCTAssertNotEqual(zero.tracks[i].flags & UInt32(ARKTRACE_TRACK_OWNER), base.tracks[i].flags & UInt32(ARKTRACE_TRACK_OWNER))
        }
        for index in 0..<6 {
            let changes: [(inout ArkTraceTrackRecord) -> Void] = [
                { $0.source_kind = 0 }, { $0.source_value += 1 }, { $0.filter_id += 1 }, { $0.owner_value += 1 },
                { $0.flags ^= UInt32(ARKTRACE_TRACK_OWNER) }, { $0.flags ^= UInt32(ARKTRACE_TRACK_NESTED) },
            ]
            for change in changes { var bad = base; change(&bad.tracks[index]); try reject(bad, fresh: base, &counts) }
        }
        let partitions: [(inout Fixture) -> Void] = [
            { $0.tracks[1].primitive_start = 0 }, { $0.tracks[1].primitive_start = 2 },
            { $0.tracks[1].primitive_count = 0 }, { $0.tracks[1].primitive_count = 100 },
            { $0.primitives[3].track_index = 2 }, { $0.primitives.append($0.primitives[5]) },
            { $0.tracks.swapAt(0, 1) }, { $0.tracks.append($0.tracks[0]) },
            { $0.tracks[2].id_offset = $0.tracks[0].id_offset; $0.tracks[2].id_length = $0.tracks[0].id_length },
            { $0.tracks[0].y = 1 }, { $0.tracks[1].y = 0 },
            { $0.tracks[0].flags |= UInt32(ARKTRACE_TRACK_COLLAPSED) },
        ]
        for change in partitions { var bad = base; change(&bad); try reject(bad, fresh: base, &counts) }
        for height in [0.0, -1.0, Double.nan, Double.infinity] {
            var bad = base; bad.tracks[0].height = height; try reject(bad, fresh: base, &counts)
        }
        try emit("source_partition", counts)
    }

    private func density(_ base: Fixture) -> Fixture {
        var f = base
        f.primitives[0].kind = UInt32(ARKTRACE_PRIMITIVE_DENSITY)
        f.primitives[0].flags = UInt32(ARKTRACE_FLAG_COLOR)
        f.primitives[0].event_count = 1
        return f
    }
    func testDensityFlagsDominantAndMachineQualityMatrix() throws {
        actualABI(); var counts = Counts()
        let base = try fixture(); let dense = density(base)
        let dominant: [(UInt32, TraceDensityIdentity?)] = [
            (0, nil), (UInt32(ARKTRACE_DOMINANT_IDENTITY), .processOrThread(0)),
            (UInt32(ARKTRACE_DOMINANT_NAME), .name("worker")),
            (UInt32(ARKTRACE_DOMINANT_THREAD_STATE), .threadState("R")),
            (UInt32(ARKTRACE_DOMINANT_JANK), .jank(0)),
        ]
        for (kind, expected) in dominant {
            var f = dense; f.primitives[0].dominant_kind = kind
            if kind == ARKTRACE_DOMINANT_NAME || kind == ARKTRACE_DOMINANT_THREAD_STATE {
                let value = kind == ARKTRACE_DOMINANT_NAME ? "worker" : "R"
                (f.primitives[0].text_offset, f.primitives[0].text_length) = f.text(value)
            }
            let snapshot = try accept(f, &counts)
            XCTAssertNil(snapshot.tracks[0].primitives[0].selectableEventKey)
            guard case .density(let result) = snapshot.tracks[0].primitives[0] else { return XCTFail("density absent") }
            XCTAssertEqual(result.bucket.dominant, expected)
            XCTAssertNil(result.bucket.occupiedNs); XCTAssertNil(result.bucket.utilization)
        }
        var zero = dense
        zero.primitives[0].event_count = 0
        zero.primitives[0].flags |= UInt32(ARKTRACE_FLAG_OCCUPANCY | ARKTRACE_FLAG_UTILIZATION)
        let zeroSnapshot = try accept(zero, &counts)
        guard case .density(let z) = zeroSnapshot.tracks[0].primitives[0] else { return XCTFail("density absent") }
        XCTAssertEqual(z.bucket.eventCount, 0); XCTAssertEqual(z.bucket.occupiedNs, 0); XCTAssertEqual(z.bucket.utilization, 0)
        let badDensity: [(inout ArkTracePrimitiveRecord) -> Void] = [
            { $0.event_count = -1 }, { $0.end_ns = $0.start_ns }, { $0.dominant_kind = 99 },
            { $0.flags |= UInt32(ARKTRACE_FLAG_OCCUPANCY); $0.occupied_ns = -1 },
            { $0.flags |= UInt32(ARKTRACE_FLAG_UTILIZATION); $0.utilization = -1 },
            { $0.flags |= UInt32(ARKTRACE_FLAG_UTILIZATION); $0.utilization = .nan },
            { $0.flags |= UInt32(ARKTRACE_FLAG_UTILIZATION); $0.utilization = .infinity },
            { $0.flags |= UInt32(ARKTRACE_FLAG_RENDER_FACTS) }, { $0.flags |= UInt32(ARKTRACE_FLAG_SEMANTIC_DURATION) },
            { $0.flags |= UInt32(ARKTRACE_FLAG_OPEN_ENDED) },
        ]
        for change in badDensity { var bad = dense; change(&bad.primitives[0]); try reject(bad, fresh: dense, &counts) }
        for flag in [UInt32(ARKTRACE_FLAG_OCCUPANCY), UInt32(ARKTRACE_FLAG_UTILIZATION)] {
            var bad = base; bad.primitives[2].flags |= flag; try reject(bad, fresh: base, &counts)
        }
        for (index, category) in TraceDataQualityIssue.Category.allCases.enumerated() {
            var f = base; var q = ArkTraceQualityRecord(); q.category = UInt32(index + 1)
            if index.isMultiple(of: 2) { q.flags = UInt32(ARKTRACE_QUALITY_COUNT); q.count = 0 }
            f.quality = [q]; f.qualityStatus = UInt32(ARKTRACE_QUALITY_STATUS_WARNINGS)
            let snapshot = try accept(f, &counts)
            XCTAssertEqual(snapshot.dataQuality.issues[0].category, category)
            XCTAssertEqual(snapshot.dataQuality.issues[0].count, index.isMultiple(of: 2) ? 0 : nil)
        }
        var scopes = base
        let allowed = TraceDataQualityScope.machineAllowed.sorted()
        for scope in allowed {
            var q = ArkTraceQualityRecord(); q.category = UInt32(ARKTRACE_QUALITY_INVALID_VALUE); q.flags = UInt32(ARKTRACE_QUALITY_SCOPE)
            (q.scope_offset, q.scope_length) = scopes.text(scope); scopes.quality.append(q)
        }
        scopes.qualityStatus = UInt32(ARKTRACE_QUALITY_STATUS_WARNINGS)
        XCTAssertEqual(try accept(scopes, &counts).dataQuality.issues.compactMap(\.scope), allowed)
        var goodQuality = base; var q = ArkTraceQualityRecord(); q.category = UInt32(ARKTRACE_QUALITY_INVALID_VALUE)
        goodQuality.quality = [q]; goodQuality.qualityStatus = UInt32(ARKTRACE_QUALITY_STATUS_WARNINGS)
        let badQuality: [(inout Fixture) -> Void] = [
            { $0.quality[0].category = 0 }, { $0.quality[0].category = 8 }, { $0.quality[0].flags = 4 },
            { $0.quality[0].flags = UInt32(ARKTRACE_QUALITY_COUNT); $0.quality[0].count = -1 },
            { let t = $0.text("private.unapproved.scope"); $0.quality[0].flags = UInt32(ARKTRACE_QUALITY_SCOPE); $0.quality[0].scope_offset = t.0; $0.quality[0].scope_length = t.1 },
            { $0.qualityStatus = UInt32(ARKTRACE_QUALITY_STATUS_OK) }, { $0.qualityStatus = 99 },
        ]
        for change in badQuality { var bad = goodQuality; change(&bad); try reject(bad, fresh: goodQuality, &counts) }
        var warningsWithoutRecords = base; warningsWithoutRecords.qualityStatus = UInt32(ARKTRACE_QUALITY_STATUS_WARNINGS)
        try reject(warningsWithoutRecords, fresh: base, &counts)
        try emit("density_quality", counts)
    }

    func testExactRecordCountsDepthRowsAndVisibilityBoundary() throws {
        actualABI(); var counts = Counts()
        let base = try fixture(maximum: 6)
        XCTAssertEqual(try accept(base, &counts).tracks.flatMap(\.primitives).count, base.request.maximumPrimitives)
        var excess = base
        var extra = excess.primitives[5]; extra.row_id = 38
        excess.primitives.append(extra); excess.tracks[5].primitive_count = 2
        try reject(excess, fresh: base, &counts)
        var exactQuality = base
        exactQuality.quality = (0..<4096).map { index in
            var q = ArkTraceQualityRecord(); q.category = UInt32(ARKTRACE_QUALITY_INVALID_VALUE)
            q.flags = UInt32(ARKTRACE_QUALITY_COUNT); q.count = Int64(index); return q
        }
        exactQuality.qualityStatus = UInt32(ARKTRACE_QUALITY_STATUS_WARNINGS)
        XCTAssertEqual(try accept(exactQuality, &counts).dataQuality.issues.count, 4096)
        var overQuality = exactQuality; var extraQuality = overQuality.quality[0]; extraQuality.count = 4096
        overQuality.quality.append(extraQuality)
        try reject(overQuality, fresh: exactQuality, &counts)
        var depth32 = base; depth32.tracks[2].depth_rows = 32
        XCTAssertEqual(try accept(depth32, &counts).tracks[2].depthRowCount, 32)
        XCTAssertEqual(try accept(base, &counts).tracks[2].depthRowCount, 1)
        for rows in [UInt32(0), UInt32(33)] { var bad = base; bad.tracks[2].depth_rows = rows; try reject(bad, fresh: base, &counts) }
        let noFrame = density(base)
        let invisible = try accept(noFrame, &counts)
        guard case .density(let invisibleDensity) = invisible.tracks[0].primitives[0] else { return XCTFail("density absent") }
        XCTAssertNil(invisibleDensity.projection?.frame)
        var frame = noFrame
        frame.primitives[0].flags |= UInt32(ARKTRACE_FLAG_FRAME | ARKTRACE_FLAG_VISIBLE)
        frame.primitives[0].x = 1; frame.primitives[0].y = 2; frame.primitives[0].width = 3; frame.primitives[0].height = 4
        let framed = try accept(frame, &counts)
        guard case .density(let visibleDensity) = framed.tracks[0].primitives[0] else { return XCTFail("density absent") }
        XCTAssertEqual(visibleDensity.projection?.frame, CGRect(x: 1, y: 2, width: 3, height: 4))
        var missingVisible = frame; missingVisible.primitives[0].flags &= ~UInt32(ARKTRACE_FLAG_VISIBLE)
        try reject(missingVisible, fresh: frame, &counts)
        try emit("record_bounds", counts)
    }
}
#endif
