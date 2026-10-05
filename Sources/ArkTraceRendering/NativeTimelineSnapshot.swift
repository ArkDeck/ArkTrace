#if ARKTRACE_NATIVE_RUNTIME
import ArkTraceCore
import ArkTraceRustRuntime
import CArkTrace
import CoreGraphics
import Foundation

package enum NativeTimelineSnapshot {
    @concurrent
    package static func load(_ request: ViewportRequest, repository: RustTraceRepository) async throws -> TimelineSnapshot? {
        precondition(!Thread.isMainThread)
        let tracks = request.tracks.map { track in
            let source: RustDensitySource = switch track.source {
            case .cpu(let v): .cpu(v)
            case .threadState(let v): .threadState(v)
            case .namedSlice(let v): .namedSlice(v)
            case .cpuCounter(let id, let cpu): .cpuCounter(filterID: id, cpu: cpu)
            case .processCounter(let id, let key): .processCounter(filterID: id, processKey: key)
            case .frame(let key): .frame(processKey: key)
            }
            return RustTrack(source: source, isCollapsed: track.isCollapsed, showsNestedDepth: track.showsNestedDepth)
        }
        let viewport = RustViewport(range: request.viewport.range, widthPoints: request.viewport.widthPoints,
            heightPoints: request.viewport.heightPoints, verticalOffsetPoints: request.viewport.verticalOffsetPoints,
            generation: request.generation)
        let preference: RustDetailPreference = switch request.preference { case .automatic: .automatic; case .detail: .detail; case .density: .density }
        let wire = RustViewportQuery(request: RustViewportRequest(viewport: viewport, tracks: tracks,
            pixelWidth: request.pixelWidth, generation: request.generation, preference: preference,
            maximumPrimitives: request.maximumPrimitives, focusedEventKey: request.focusedEventKey),
            backingScale: Double(request.pixelWidth) / request.viewport.widthPoints, deadline: request.deadline)
        guard let native = try await repository.snapshot(wire) else { return nil }
        try Task.checkCancellation()
        let result = try native.withRecords { tracks, primitives, quality, strings in
            let stringsBytes = try stringOccurrences(tracks: tracks, primitives: primitives, quality: quality, strings: strings)
            var reservation = 4096
            reservation += tracks.count * MemoryLayout<TimelineTrackSnapshot>.stride * 2
            reservation += primitives.count * MemoryLayout<TimelinePrimitive>.stride * 2
            reservation += quality.count * MemoryLayout<TraceDataQualityIssue>.stride * 2
            reservation += stringsBytes * 4
            let owner = try RustSnapshotCopyOwner(native: native, maximumCopyBytes: reservation)
            var snapshot = try convert(request, viewport: native.viewport, qualityStatus: native.qualityStatus,
                tracks: tracks, primitives: primitives, quality: quality, strings: strings)
            snapshot.retainNativeProjection(owner)
            return snapshot
        }
        try Task.checkCancellation()
        return result
    }

    private static func stringOccurrences(tracks: Span<ArkTraceTrackRecord>, primitives: Span<ArkTracePrimitiveRecord>,
        quality: Span<ArkTraceQualityRecord>, strings: Span<UInt8>) throws -> Int {
        var total = 0
        func add(_ offset: UInt32, _ length: UInt32) throws {
            guard Int(offset) <= strings.count, Int(length) <= strings.count - Int(offset), length <= 16_384 else { throw RustAdmission.invalidBuffer }
            total += Int(length)
            guard total <= 16 * 1024 * 1024 else { throw RustAdmission.outputLimit }
        }
        for i in 0..<tracks.count { try add(tracks[i].id_offset, tracks[i].id_length) }
        for i in 0..<primitives.count {
            if i % 128 == 0 { try Task.checkCancellation() }
            let p = primitives[i]
            for (offset, length) in [(p.text_offset,p.text_length),(p.label_offset,p.label_length),
                (p.category_offset,p.category_length),(p.name_offset,p.name_length),
                (p.process_name_offset,p.process_name_length),(p.thread_name_offset,p.thread_name_length),
                (p.inspector_category_offset,p.inspector_category_length),(p.state_offset,p.state_length),(p.unit_offset,p.unit_length)] {
                try add(offset,length)
            }
        }
        for i in 0..<quality.count { try add(quality[i].scope_offset,quality[i].scope_length) }
        return total
    }

    package static func convert(_ request: ViewportRequest, viewport: ArkTraceViewportRecord, qualityStatus: UInt32,
        tracks: Span<ArkTraceTrackRecord>, primitives: Span<ArkTracePrimitiveRecord>,
        quality: Span<ArkTraceQualityRecord>, strings: Span<UInt8>) throws -> TimelineSnapshot {
        let expected = request.viewport
        guard viewport.start_ns == expected.range.startNs, viewport.end_ns == expected.range.endNs,
            viewport.generation == request.generation, viewport.source_generation == request.generation,
            viewport.width_points == expected.widthPoints, viewport.height_points == expected.heightPoints,
            viewport.vertical_offset_points == expected.verticalOffsetPoints, viewport.ns_per_point == expected.nsPerPoint,
            viewport.backing_scale.isFinite, viewport.backing_scale > 0,
            tracks.count <= 10_000, primitives.count <= request.maximumPrimitives, quality.count <= 4096 else { throw RustAdmission.invalidBuffer }
        let expanded = request.tracks.filter { !$0.isCollapsed }
        guard tracks.count == expanded.count else { throw RustAdmission.invalidBuffer }
        var output: [TimelineTrackSnapshot] = []
        var cursor = 0
        var y = 0.0
        for index in 0..<tracks.count {
            try Task.checkCancellation()
            let track = tracks[index], descriptor = expanded[index]
            try validateSource(track, descriptor: descriptor)
            guard track.reserved == 0, track.flags & ~(UInt32(ARKTRACE_TRACK_NESTED) | UInt32(ARKTRACE_TRACK_OWNER)) == 0,
                track.primitive_start == cursor, Int(track.primitive_count) <= primitives.count - cursor,
                track.depth_rows >= 1, track.depth_rows <= 32,
                track.y == y, track.height.isFinite, track.height > 0,
                try text(track.id_offset,track.id_length,strings) == descriptor.id.rawValue else { throw RustAdmission.invalidBuffer }
            var items: [TimelinePrimitive] = []
            items.reserveCapacity(Int(track.primitive_count))
            for pi in cursor..<(cursor + Int(track.primitive_count)) {
                let p = primitives[pi]
                guard p.track_index == index, p.reserved_header == 0, p.reserved == 0,
                    p.start_ns >= 0, p.end_ns >= p.start_ns, p.depth >= 0,
                    p.flags & ~UInt32(0x7fffff) == 0,
                    p.flags & UInt32(ARKTRACE_FLAG_COLOR) != 0, p.color_rgb <= 0xffffff else { throw RustAdmission.invalidBuffer }
                let range = try TraceTimeRange(startNs: p.start_ns, endNs: p.end_ns)
                let frame: CGRect?
                if p.flags & UInt32(ARKTRACE_FLAG_FRAME) != 0 {
                    guard p.x.isFinite, p.y.isFinite, p.width.isFinite, p.height.isFinite, p.width > 0, p.height > 0,
                        p.flags & UInt32(ARKTRACE_FLAG_VISIBLE) != 0 else { throw RustAdmission.invalidBuffer }
                    frame = CGRect(x: p.x, y: p.y, width: p.width, height: p.height)
                } else { frame = nil }
                let projection = TimelinePrimitiveProjection(viewport: expected, backingScale: viewport.backing_scale, frame: frame, colorRGB: p.color_rgb)
                if p.kind == ARKTRACE_PRIMITIVE_DETAIL {
                    guard p.flags & UInt32(ARKTRACE_FLAG_RENDER_FACTS) != 0,
                        p.flags & UInt32(ARKTRACE_FLAG_OCCUPANCY | ARKTRACE_FLAG_UTILIZATION) == 0,
                        p.dominant_kind == 0, p.text_offset == 0, p.text_length == 0 else { throw RustAdmission.invalidBuffer }
                    let key = EventKey(table: try table(p.event_table), rowID: p.row_id)
                    let type = try eventType(p.event_kind, table: key.table)
                    func optional(_ flag: UInt32, _ offset: UInt32, _ length: UInt32) throws -> String? {
                        if p.flags & flag == 0 {
                            guard offset == 0, length == 0 else { throw RustAdmission.invalidBuffer }
                            return nil
                        }
                        return try text(offset,length,strings)
                    }
                    func scalar(_ flag: UInt32, _ value: Int64) -> Int64? { p.flags & flag == 0 ? nil : value }
                    let open = p.flags & UInt32(ARKTRACE_FLAG_OPEN_ENDED) != 0
                    let duration = scalar(UInt32(ARKTRACE_FLAG_SEMANTIC_DURATION),p.semantic_duration_ns)
                    guard duration.map({$0 >= 0}) ?? true, open == (duration == nil) else { throw RustAdmission.invalidBuffer }
                    let inspector = TraceEventInspector(key: key, type: type,
                        name: try optional(UInt32(ARKTRACE_FLAG_NAME),p.name_offset,p.name_length), range: range,
                        semanticDurationNs: duration, isOpenEnded: open,
                        processKey: scalar(UInt32(ARKTRACE_FLAG_PROCESS_KEY),p.process_key).map(ProcessKey.init(ipid:)),
                        threadKey: scalar(UInt32(ARKTRACE_FLAG_THREAD_KEY),p.thread_key).map(ThreadKey.init(itid:)),
                        pid: scalar(UInt32(ARKTRACE_FLAG_PID),p.pid), tid: scalar(UInt32(ARKTRACE_FLAG_TID),p.tid), cpu: scalar(UInt32(ARKTRACE_FLAG_CPU),p.cpu),
                        processName: try optional(UInt32(ARKTRACE_FLAG_PROCESS_NAME),p.process_name_offset,p.process_name_length),
                        threadName: try optional(UInt32(ARKTRACE_FLAG_THREAD_NAME),p.thread_name_offset,p.thread_name_length),
                        category: try optional(UInt32(ARKTRACE_FLAG_INSPECTOR_CATEGORY),p.inspector_category_offset,p.inspector_category_length),
                        state: try optional(UInt32(ARKTRACE_FLAG_STATE),p.state_offset,p.state_length), value: scalar(UInt32(ARKTRACE_FLAG_VALUE),p.value),
                        unit: try optional(UInt32(ARKTRACE_FLAG_UNIT),p.unit_offset,p.unit_length), priority: scalar(UInt32(ARKTRACE_FLAG_PRIORITY),p.priority))
                    var detail = TimelineDetailPrimitive(trackID: descriptor.id, eventKey: key, range: range,
                        label: try optional(UInt32(ARKTRACE_FLAG_LABEL),p.label_offset,p.label_length),
                        category: try optional(UInt32(ARKTRACE_FLAG_CATEGORY),p.category_offset,p.category_length),
                        inspector: inspector, depth: Int(p.depth), jankTag: p.jank_tag)
                    detail.projection = projection
                    items.append(.detail(detail))
                } else if p.kind == ARKTRACE_PRIMITIVE_DENSITY {
                    let allowed = UInt32(ARKTRACE_FLAG_COLOR | ARKTRACE_FLAG_VISIBLE | ARKTRACE_FLAG_FRAME | ARKTRACE_FLAG_OCCUPANCY | ARKTRACE_FLAG_UTILIZATION)
                    guard p.event_count >= 0, !range.isInstant, p.flags & ~allowed == 0 else { throw RustAdmission.invalidBuffer }
                    let dominant: TraceDensityIdentity?
                    switch p.dominant_kind {
                    case 0: dominant = nil
                    case ARKTRACE_DOMINANT_IDENTITY: dominant = .processOrThread(p.dominant_value)
                    case ARKTRACE_DOMINANT_NAME: dominant = .name(try text(p.text_offset,p.text_length,strings))
                    case ARKTRACE_DOMINANT_THREAD_STATE: dominant = .threadState(try text(p.text_offset,p.text_length,strings))
                    case ARKTRACE_DOMINANT_JANK: dominant = .jank(p.dominant_value)
                    default: throw RustAdmission.invalidBuffer
                    }
                    let occupied = p.flags & UInt32(ARKTRACE_FLAG_OCCUPANCY) == 0 ? nil : p.occupied_ns
                    let utilization = p.flags & UInt32(ARKTRACE_FLAG_UTILIZATION) == 0 ? nil : p.utilization
                    guard occupied.map({$0 >= 0}) ?? true, utilization.map({$0.isFinite && $0 >= 0}) ?? true else { throw RustAdmission.invalidBuffer }
                    var density = TimelineDensityPrimitive(trackID: descriptor.id, bucket: TraceDensityBucket(range: range, eventCount: p.event_count,
                        occupiedNs: occupied, utilization: utilization, dominant: dominant))
                    density.projection = projection
                    items.append(.density(density))
                } else { throw RustAdmission.invalidBuffer }
            }
            output.append(TimelineTrackSnapshot(descriptor: descriptor, y: track.y, height: track.height, primitives: items, depthRowCount: Int(track.depth_rows)))
            cursor += Int(track.primitive_count); y += track.height
        }
        guard cursor == primitives.count else { throw RustAdmission.invalidBuffer }
        let categories: [TraceDataQualityIssue.Category] = [.probeTruncated,.invalidValue,.clampedValue,.droppedValue,.referentialIntegrity,.unavailableValue,.unclassified]
        var issues: [TraceDataQualityIssue] = []
        for i in 0..<quality.count {
            let q = quality[i]
            guard (1...7).contains(q.category), q.flags & ~UInt32(3) == 0 else { throw RustAdmission.invalidBuffer }
            let scope = q.flags & UInt32(ARKTRACE_QUALITY_SCOPE) == 0 ? nil : try text(q.scope_offset,q.scope_length,strings)
            guard scope.map(TraceDataQualityScope.machineAllowed.contains) ?? true else { throw RustAdmission.invalidBuffer }
            let count = q.flags & UInt32(ARKTRACE_QUALITY_COUNT) == 0 ? nil : q.count
            guard count.map({$0 >= 0}) ?? true else { throw RustAdmission.invalidBuffer }
            issues.append(TraceDataQualityIssue(category: categories[Int(q.category)-1], scope: scope, count: count))
        }
        let dataQuality = TraceDataQuality(issues: issues)
        guard (qualityStatus == ARKTRACE_QUALITY_STATUS_OK && dataQuality.status == .ok)
            || (qualityStatus == ARKTRACE_QUALITY_STATUS_WARNINGS && dataQuality.status == .warnings) else { throw RustAdmission.invalidBuffer }
        return TimelineSnapshot(viewport: expected, tracks: output, generation: request.generation, dataQuality: dataQuality)
    }
    private static func validateSource(_ track: ArkTraceTrackRecord, descriptor: TrackDescriptor) throws {
        let expected: (UInt32, Int64, Int64, Int64, Bool) = switch descriptor.source {
        case .cpu(let cpu): (UInt32(ARKTRACE_SOURCE_CPU),cpu,0,0,false)
        case .threadState(let key): (UInt32(ARKTRACE_SOURCE_THREAD_STATE),key.itid,0,0,false)
        case .namedSlice(let key): (UInt32(ARKTRACE_SOURCE_NAMED_SLICE),key?.itid ?? 0,0,0,key != nil)
        case .cpuCounter(let filter,let cpu): (UInt32(ARKTRACE_SOURCE_CPU_COUNTER),0,filter,cpu ?? 0,cpu != nil)
        case .processCounter(let filter,let key): (UInt32(ARKTRACE_SOURCE_PROCESS_COUNTER),0,filter,key?.ipid ?? 0,key != nil)
        case .frame(let key): (UInt32(ARKTRACE_SOURCE_FRAME),0,0,key?.ipid ?? 0,key != nil)
        }
        guard track.source_kind == expected.0, track.source_value == expected.1,
            track.filter_id == expected.2, track.owner_value == expected.3,
            (track.flags & UInt32(ARKTRACE_TRACK_OWNER) != 0) == expected.4,
            (track.flags & UInt32(ARKTRACE_TRACK_NESTED) != 0) == descriptor.showsNestedDepth else { throw RustAdmission.invalidBuffer }
    }
    private static func text(_ offset: UInt32, _ length: UInt32, _ strings: Span<UInt8>) throws -> String {
        guard length <= 16_384, Int(offset) <= strings.count, Int(length) <= strings.count - Int(offset) else { throw RustAdmission.invalidBuffer }
        let bytes = (Int(offset)..<(Int(offset)+Int(length))).map { strings[$0] }
        guard let text = String(validating: bytes, as: UTF8.self) else { throw RustAdmission.invalidBuffer }
        return text
    }
    private static func table(_ value: UInt32) throws -> TraceEventTable {
        switch value {
        case ARKTRACE_TABLE_SCHED_SLICE: .schedSlice
        case ARKTRACE_TABLE_THREAD_STATE: .threadState
        case ARKTRACE_TABLE_CALLSTACK: .callstack
        case ARKTRACE_TABLE_MEASURE: .measure
        case ARKTRACE_TABLE_PROCESS_MEASURE: .processMeasure
        case ARKTRACE_TABLE_FRAME_SLICE: .frameSlice
        default: throw RustAdmission.invalidBuffer
        }
    }
    private static func eventType(_ value: UInt32, table: TraceEventTable) throws -> TraceInspectorEventType {
        switch (value,table) {
        case (1,.schedSlice): .cpuSlice
        case (2,.threadState): .threadState
        case (3,.callstack): .namedSlice
        case (4,.measure),(4,.processMeasure): .counter
        case (5,.frameSlice): .frame
        default: throw RustAdmission.invalidBuffer
        }
    }
}
#endif
