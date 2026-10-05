#if ARKTRACE_NATIVE_RUNTIME
import ArkTraceCore
import ArkTraceRustRuntime
@testable import ArkTraceRendering
import CArkTrace
import Foundation
import XCTest

final class NativeStringPoolAdmissionTests: XCTestCase {
    private struct Slice {
        var offset: UInt32
        var length: UInt32
    }
    private struct Fixture {
        var request: ViewportRequest
        var viewport: ArkTraceViewportRecord
        var tracks: [ArkTraceTrackRecord]
        var primitives: [ArkTracePrimitiveRecord]
        var quality: [ArkTraceQualityRecord]
        var strings: [UInt8]

        mutating func append(_ bytes: [UInt8]) -> Slice {
            let result = Slice(offset: UInt32(strings.count), length: UInt32(bytes.count))
            strings.append(contentsOf: bytes)
            return result
        }
    }
    private struct Counts {
        var calls = 0
        var rejections = 0
        var recoveries = 0
        var matrix: [[String: String]] = []
    }
    private enum Target: String, CaseIterable {
        case trackID, label, qualityScope
    }
    private enum Slot: String, CaseIterable {
        case label, category, name, processName, threadName, inspectorCategory, state, unit

        var flag: UInt32 {
            switch self {
            case .label: UInt32(ARKTRACE_FLAG_LABEL)
            case .category: UInt32(ARKTRACE_FLAG_CATEGORY)
            case .name: UInt32(ARKTRACE_FLAG_NAME)
            case .processName: UInt32(ARKTRACE_FLAG_PROCESS_NAME)
            case .threadName: UInt32(ARKTRACE_FLAG_THREAD_NAME)
            case .inspectorCategory: UInt32(ARKTRACE_FLAG_INSPECTOR_CATEGORY)
            case .state: UInt32(ARKTRACE_FLAG_STATE)
            case .unit: UInt32(ARKTRACE_FLAG_UNIT)
            }
        }
        func write(_ slice: Slice, present: Bool = true, into p: inout ArkTracePrimitiveRecord) {
            if present { p.flags |= flag } else { p.flags &= ~flag }
            switch self {
            case .label: p.label_offset = slice.offset; p.label_length = slice.length
            case .category: p.category_offset = slice.offset; p.category_length = slice.length
            case .name: p.name_offset = slice.offset; p.name_length = slice.length
            case .processName: p.process_name_offset = slice.offset; p.process_name_length = slice.length
            case .threadName: p.thread_name_offset = slice.offset; p.thread_name_length = slice.length
            case .inspectorCategory: p.inspector_category_offset = slice.offset; p.inspector_category_length = slice.length
            case .state: p.state_offset = slice.offset; p.state_length = slice.length
            case .unit: p.unit_offset = slice.offset; p.unit_length = slice.length
            }
        }
        func value(in detail: TimelineDetailPrimitive) -> String? {
            switch self {
            case .label: detail.label
            case .category: detail.category
            case .name: detail.inspector?.name
            case .processName: detail.inspector?.processName
            case .threadName: detail.inspector?.threadName
            case .inspectorCategory: detail.inspector?.category
            case .state: detail.inspector?.state
            case .unit: detail.inspector?.unit
            }
        }
    }

    private func actualABI() {
        var identity = ArkTraceAbiIdentity()
        XCTAssertEqual(arktrace_abi_identity(&identity, UInt64(MemoryLayout<ArkTraceAbiIdentity>.size)), UInt32(ARKTRACE_STATUS_OK))
        XCTAssertEqual(identity.abi_version, 2)
        XCTAssertEqual(ARKTRACE_ABI_VERSION, 2)
    }
    private func fixture(id: String? = nil) throws -> Fixture {
        var descriptor = TrackDescriptor(title: "string admission", source: .namedSlice(ThreadKey(itid: 7)))
        if let id {
            // Exercise the public Codable descriptor with a matching wire ID.
            // Source, flags and geometry stay identical to the legal baseline.
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor)) as? [String: Any])
            object["id"] = ["rawValue": id]
            descriptor = try JSONDecoder().decode(TrackDescriptor.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let range = try TraceTimeRange.query(startNs: 0, endNs: 100)
        let viewport = try TimelineViewport(range: range, widthPoints: 200, heightPoints: 80, generation: 1)
        let request = try ViewportRequest(viewport: viewport, tracks: [descriptor], pixelWidth: 400,
            generation: 1, maximumPrimitives: 4, deadline: .now.advanced(by: .seconds(10)))
        var wire = ArkTraceViewportRecord()
        wire.end_ns = 100; wire.width_points = 200; wire.height_points = 80
        wire.ns_per_point = 0.5; wire.generation = 1; wire.source_generation = 1; wire.backing_scale = 2
        var track = ArkTraceTrackRecord()
        track.source_kind = UInt32(ARKTRACE_SOURCE_NAMED_SLICE); track.source_value = 7
        track.flags = UInt32(ARKTRACE_TRACK_NESTED | ARKTRACE_TRACK_OWNER)
        track.id_length = UInt32(descriptor.id.rawValue.utf8.count)
        track.height = 28; track.depth_rows = 1; track.primitive_count = 1
        var primitive = ArkTracePrimitiveRecord()
        primitive.kind = UInt32(ARKTRACE_PRIMITIVE_DETAIL)
        primitive.event_table = UInt32(ARKTRACE_TABLE_CALLSTACK); primitive.event_kind = 3; primitive.row_id = 37
        primitive.end_ns = 10; primitive.semantic_duration_ns = 10
        primitive.flags = UInt32(ARKTRACE_FLAG_COLOR | ARKTRACE_FLAG_RENDER_FACTS | ARKTRACE_FLAG_SEMANTIC_DURATION)
        primitive.color_rgb = 0xabcdef
        var quality = ArkTraceQualityRecord()
        quality.category = UInt32(ARKTRACE_QUALITY_INVALID_VALUE); quality.flags = UInt32(ARKTRACE_QUALITY_SCOPE)
        quality.scope_offset = track.id_length; quality.scope_length = UInt32("callstack.value".utf8.count)
        return Fixture(request: request, viewport: wire, tracks: [track], primitives: [primitive], quality: [quality],
            strings: Array((descriptor.id.rawValue + "callstack.value").utf8))
    }
    private func assign(_ target: Target, _ slice: Slice, to f: inout Fixture) {
        switch target {
        case .trackID: f.tracks[0].id_offset = slice.offset; f.tracks[0].id_length = slice.length
        case .label: Slot.label.write(slice, into: &f.primitives[0])
        case .qualityScope: f.quality[0].scope_offset = slice.offset; f.quality[0].scope_length = slice.length
        }
    }
    private func convert(_ f: Fixture) throws -> TimelineSnapshot {
        try f.tracks.withUnsafeBufferPointer { tracks in
            try f.primitives.withUnsafeBufferPointer { primitives in
                try f.quality.withUnsafeBufferPointer { quality in
                    try f.strings.withUnsafeBufferPointer { strings in
                        try NativeTimelineSnapshot.convert(f.request, viewport: f.viewport,
                            qualityStatus: UInt32(ARKTRACE_QUALITY_STATUS_WARNINGS),
                            tracks: Span(_unsafeElements: tracks), primitives: Span(_unsafeElements: primitives),
                            quality: Span(_unsafeElements: quality), strings: Span(_unsafeElements: strings))
                    }
                }
            }
        }
    }
    private func detail(_ snapshot: TimelineSnapshot) throws -> TimelineDetailPrimitive {
        XCTAssertEqual(snapshot.tracks.count, 1)
        XCTAssertEqual(snapshot.tracks[0].primitives.count, 1)
        guard case .detail(let value) = snapshot.tracks[0].primitives[0] else {
            throw RustAdmission.invalidBuffer
        }
        return value
    }
    private func accept(_ f: Fixture, name: String, _ counts: inout Counts) throws -> TimelineSnapshot {
        counts.calls += 1
        let snapshot = try convert(f)
        counts.matrix.append(["variant": name, "guard": "accepted", "outcome": "snapshot"])
        return snapshot
    }
    private func reject(_ bad: Fixture, name: String, guardName: String, _ counts: inout Counts,
        file: StaticString = #filePath, line: UInt = #line) throws {
        counts.calls += 1
        var partial: TimelineSnapshot?
        do { partial = try convert(bad); XCTFail("invalid string input accepted", file: file, line: line) }
        catch {
            XCTAssertEqual(error as? RustAdmission, .invalidBuffer, file: file, line: line)
            counts.rejections += 1
        }
        XCTAssertNil(partial, file: file, line: line)
        // Construct new records, request and byte arrays for every recovery;
        // no retained malformed span or alternate converter is reused.
        let fresh = try fixture()
        counts.calls += 1
        let recovered = try convert(fresh)
        let value = try detail(recovered)
        XCTAssertEqual(value.eventKey, EventKey(table: .callstack, rowID: 37), file: file, line: line)
        XCTAssertEqual(recovered.dataQuality.issues.first?.scope, "callstack.value", file: file, line: line)
        for slot in Slot.allCases { XCTAssertNil(slot.value(in: value), file: file, line: line) }
        counts.recoveries += 1
        counts.matrix.append(["variant": name, "guard": guardName, "outcome": "invalidBuffer_then_fresh_snapshot"])
    }
    private func emit(_ group: String, _ counts: Counts) throws {
        XCTAssertEqual(counts.rejections, counts.recoveries)
        XCTAssertLessThanOrEqual(counts.matrix.count, 128)
        let data = try JSONSerialization.data(withJSONObject: ["group": group, "variants": counts.matrix.count,
            "actualConvertCalls": counts.calls, "actualInvalidBufferRejections": counts.rejections,
            "freshRecoveries": counts.recoveries, "actualABIIdentityCalls": 1, "actualSDKABI": 2,
            "guardMatrix": counts.matrix], options: [.sortedKeys])
        print("A27CASE " + String(decoding: data, as: UTF8.self))
    }

    func testUTF8AndOffsetAdmissionAcrossRecordPositions() throws {
        actualABI(); var counts = Counts()
        for (index, value) in ["线程", "e\u{301}", "👩🏽‍💻", "Δοκιμή"].enumerated() {
            var f = try fixture(id: value)
            Slot.label.write(Slice(offset: 0, length: f.tracks[0].id_length), into: &f.primitives[0])
            let snapshot = try accept(f, name: "unicode_shared_track_label_\(index)", &counts)
            XCTAssertEqual(Array(snapshot.tracks[0].descriptor.id.rawValue.utf8), Array(value.utf8))
            XCTAssertEqual(Array(try XCTUnwrap(detail(snapshot).label).utf8), Array(value.utf8))
        }
        let invalid: [(String, [UInt8])] = [
            ("continuation", [0x80]), ("overlong", [0xc0, 0xaf]),
            ("surrogate", [0xed, 0xa0, 0x80]), ("truncated", [0xe2, 0x82]),
            ("beyond_unicode", [0xf4, 0x90, 0x80, 0x80]), ("bad_continuation", [0xc2, 0x41]),
        ]
        for target in Target.allCases {
            for (name, bytes) in invalid {
                var bad = try fixture(); let slice = bad.append(bytes); assign(target, slice, to: &bad)
                try reject(bad, name: "\(target.rawValue)_\(name)", guardName: "text.validatingUTF8", &counts)
            }
            for (name, delta, length) in [("offset_inside_scalar", UInt32(1), UInt32(2)), ("tail_cut", UInt32(0), UInt32(2))] {
                var bad = try fixture(); let slice = bad.append(Array("中".utf8))
                assign(target, Slice(offset: slice.offset + delta, length: length), to: &bad)
                try reject(bad, name: "\(target.rawValue)_\(name)", guardName: "text.validatingUTF8", &counts)
            }
        }
        try emit("utf8_offsets", counts)
    }

    func testAllNullableStringSlotsAndSharedPoolReuse() throws {
        actualABI(); var counts = Counts()
        let absent = try detail(accept(fixture(), name: "all_eight_slots_absent", &counts))
        for slot in Slot.allCases { XCTAssertNil(slot.value(in: absent)) }
        for slot in Slot.allCases {
            var f = try fixture()
            slot.write(Slice(offset: UInt32(f.strings.count), length: 0), into: &f.primitives[0])
            let value = try detail(accept(f, name: "\(slot.rawValue)_present_empty_at_end", &counts))
            XCTAssertEqual(slot.value(in: value), "")
            for other in Slot.allCases where other != slot { XCTAssertNil(other.value(in: value)) }
        }
        var shared = try fixture(); let value = "共享•e\u{301}"
        let initialSize = shared.strings.count; let slice = shared.append(Array(value.utf8))
        for slot in Slot.allCases { slot.write(slice, into: &shared.primitives[0]) }
        XCTAssertEqual(shared.strings.count, initialSize + value.utf8.count)
        let all = try detail(accept(shared, name: "eight_slots_one_shared_multibyte_slice", &counts))
        for slot in Slot.allCases { XCTAssertEqual(Array(try XCTUnwrap(slot.value(in: all)).utf8), Array(value.utf8)) }
        for slot in Slot.allCases {
            for (name, slice) in [("absent_nonzero_offset", Slice(offset: 1, length: 0)), ("absent_nonzero_length", Slice(offset: 0, length: 1))] {
                var bad = try fixture(); slot.write(slice, present: false, into: &bad.primitives[0])
                try reject(bad, name: "\(slot.rawValue)_\(name)", guardName: "detail.optionalAbsentRequiresZeroOffsetAndLength", &counts)
            }
            var outside = try fixture()
            slot.write(Slice(offset: UInt32(outside.strings.count + 1), length: 0), into: &outside.primitives[0])
            try reject(outside, name: "\(slot.rawValue)_present_offset_past_end", guardName: "text.offsetWithinPool", &counts)
            var invalid = try fixture(); let invalidSlice = invalid.append([0x80]); slot.write(invalidSlice, into: &invalid.primitives[0])
            try reject(invalid, name: "\(slot.rawValue)_present_invalid_utf8", guardName: "text.validatingUTF8", &counts)
            var truncated = try fixture()
            slot.write(Slice(offset: UInt32(truncated.strings.count), length: 1), into: &truncated.primitives[0])
            try reject(truncated, name: "\(slot.rawValue)_present_length_past_end", guardName: "text.lengthWithinRemainingPool", &counts)
        }
        try emit("nullable_slots", counts)
    }

    func testByteLimitUInt32BoundsAndPoolEndSemantics() throws {
        actualABI(); var counts = Counts()
        let exact = String(repeating: "é", count: 8192)
        XCTAssertEqual(exact.utf8.count, 16_384); XCTAssertEqual(exact.count, 8192)
        var f = try fixture(); let slice = f.append(Array(exact.utf8))
        for slot in Slot.allCases { slot.write(slice, into: &f.primitives[0]) }
        let all = try detail(accept(f, name: "eight_slots_shared_exact_16384_utf8_bytes", &counts))
        for slot in Slot.allCases { XCTAssertEqual(Array(try XCTUnwrap(slot.value(in: all)).utf8), Array(exact.utf8)) }
        let over = exact + "x"; XCTAssertEqual(over.utf8.count, 16_385)
        for slot in Slot.allCases {
            var bad = try fixture(); let tooLong = bad.append(Array(over.utf8)); slot.write(tooLong, into: &bad.primitives[0])
            try reject(bad, name: "\(slot.rawValue)_16385_utf8_bytes", guardName: "text.lengthAtMost16384Bytes", &counts)
        }
        let trackText = String(repeating: "𐐷", count: 4096)
        let exactTrack = try fixture(id: trackText)
        XCTAssertEqual(exactTrack.tracks[0].id_length, 16_384)
        let trackSnapshot = try accept(exactTrack, name: "track_id_exact_16384_utf8_bytes", &counts)
        XCTAssertEqual(Array(trackSnapshot.tracks[0].descriptor.id.rawValue.utf8), Array(trackText.utf8))
        try reject(fixture(id: trackText + "x"), name: "track_id_16385_utf8_bytes", guardName: "text.lengthAtMost16384Bytes", &counts)
        for (text, name, guardName) in [(exact, "quality_scope_valid_utf8_16384_not_allowlisted", "quality.machineScopeAllowed"),
            (over, "quality_scope_valid_utf8_16385", "text.lengthAtMost16384Bytes")] {
            var bad = try fixture(); let scope = bad.append(Array(text.utf8)); assign(.qualityScope, scope, to: &bad)
            try reject(bad, name: name, guardName: guardName, &counts)
        }
        for target in Target.allCases {
            for (name, slice, guardName) in [("max_offset_zero_length", Slice(offset: .max, length: 0), "text.offsetWithinPool"),
                ("zero_offset_max_length", Slice(offset: 0, length: .max), "text.lengthAtMost16384Bytes")] {
                var bad = try fixture(); assign(target, slice, to: &bad)
                // UInt32.max length also exceeds pool size. Only the first
                // ordered byte-limit guard is claimed, not arithmetic overflow.
                try reject(bad, name: "\(target.rawValue)_\(name)", guardName: guardName, &counts)
            }
        }
        var emptyTrack = try fixture(id: "")
        let end = Slice(offset: UInt32(emptyTrack.strings.count), length: 0)
        assign(.trackID, end, to: &emptyTrack); Slot.unit.write(end, into: &emptyTrack.primitives[0])
        let emptySnapshot = try accept(emptyTrack, name: "track_and_primitive_end_offset_zero_length", &counts)
        XCTAssertEqual(emptySnapshot.tracks[0].descriptor.id.rawValue, "")
        XCTAssertEqual(try detail(emptySnapshot).inspector?.unit, "")
        var emptyQuality = try fixture()
        assign(.qualityScope, Slice(offset: UInt32(emptyQuality.strings.count), length: 0), to: &emptyQuality)
        try reject(emptyQuality, name: "quality_end_zero_length_decodes_empty_not_allowlisted", guardName: "quality.machineScopeAllowed", &counts)
        for target in Target.allCases {
            var bad = try fixture(); assign(target, Slice(offset: UInt32(bad.strings.count), length: 1), to: &bad)
            try reject(bad, name: "\(target.rawValue)_end_offset_nonzero_length", guardName: "text.lengthWithinRemainingPool", &counts)
        }
        var qualityEnd = try fixture(); let allowed = qualityEnd.append(Array("callstack.value".utf8))
        assign(.qualityScope, allowed, to: &qualityEnd)
        Slot.unit.write(Slice(offset: UInt32(qualityEnd.strings.count), length: 0), into: &qualityEnd.primitives[0])
        XCTAssertEqual(Int(allowed.offset + allowed.length), qualityEnd.strings.count)
        let qualitySnapshot = try accept(qualityEnd, name: "quality_allowed_scope_exact_pool_end_with_empty_unit", &counts)
        XCTAssertEqual(qualitySnapshot.dataQuality.issues.first?.scope, "callstack.value")
        XCTAssertEqual(try detail(qualitySnapshot).inspector?.unit, "")
        try emit("byte_and_pool_bounds", counts)
    }
}
#endif
