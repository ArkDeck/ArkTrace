import ArkTraceCore
import CArkTrace
import Foundation

public enum RustSnapshotHitMode: UInt32, Sendable {
    case detail = 1, density = 2, any = 3
}

public enum RustSnapshotHit: Sendable {
    case detail(EventKey)
    case density(source: RustDensitySource, bucket: TraceTimeRange, timeNs: Int64)
}

extension RustSnapshot {
    /// Pure bounded hit over this retained scene, using the current display.
    /// Owner lifetime is independent of the producing Engine. No IO or polling.
    public func hit(atX x: Double, y: Double, viewport: RustViewport,
        backingScale: Double, mode: RustSnapshotHitMode = .any) throws -> RustSnapshotHit? {
        try withExtendedLifetime(self) {
            var display = ArkTraceViewportRecord()
            display.start_ns = viewport.range.startNs
            display.end_ns = viewport.range.endNs
            display.ns_per_point = Double(viewport.range.durationNs) / viewport.widthPoints
            display.width_points = viewport.widthPoints
            display.height_points = viewport.heightPoints
            display.vertical_offset_points = viewport.verticalOffsetPoints
            display.generation = viewport.generation
            display.source_generation = self.viewport.source_generation
            display.backing_scale = backingScale
            var output = ArkTraceSnapshotHit()
            try unsafe checkAdmission(arktrace_snapshot_hit(retainedOwner, mode.rawValue,
                &display, UInt64(MemoryLayout<ArkTraceViewportRecord>.size), x, y,
                &output, UInt64(MemoryLayout<ArkTraceSnapshotHit>.size)))
            return try Self.decodeHit(output)
        }
    }

    static func decodeHit(_ value: ArkTraceSnapshotHit) throws -> RustSnapshotHit? {
        guard value.struct_size == MemoryLayout<ArkTraceSnapshotHit>.size, value.reserved == 0 else {
            throw RustAdmission.invalidBuffer
        }
        let noSource = value.source_kind == 0 && value.flags == 0 && value.source_value == 0
            && value.filter_id == 0 && value.owner_value == 0
        let noBucket = value.bucket_start_ns == 0 && value.bucket_end_ns == 0 && value.time_ns == 0
        switch value.kind {
        case UInt32(ARKTRACE_HIT_NONE):
            guard value.event_table == 0, value.row_id == 0, noSource, noBucket else { throw RustAdmission.invalidBuffer }
            return nil
        case UInt32(ARKTRACE_HIT_DETAIL):
            guard noSource, noBucket else { throw RustAdmission.invalidBuffer }
            let table: TraceEventTable = switch value.event_table {
            case UInt32(ARKTRACE_TABLE_SCHED_SLICE): .schedSlice
            case UInt32(ARKTRACE_TABLE_THREAD_STATE): .threadState
            case UInt32(ARKTRACE_TABLE_CALLSTACK): .callstack
            case UInt32(ARKTRACE_TABLE_MEASURE): .measure
            case UInt32(ARKTRACE_TABLE_PROCESS_MEASURE): .processMeasure
            case UInt32(ARKTRACE_TABLE_FRAME_SLICE): .frameSlice
            default: throw RustAdmission.invalidBuffer
            }
            return .detail(EventKey(table: table, rowID: value.row_id))
        case UInt32(ARKTRACE_HIT_DENSITY):
            guard value.event_table == 0, value.row_id == 0,
                value.flags & ~UInt32(ARKTRACE_TRACK_OWNER) == 0,
                value.bucket_start_ns >= 0,
                value.bucket_start_ns < value.bucket_end_ns,
                value.bucket_start_ns <= value.time_ns, value.time_ns <= value.bucket_end_ns else { throw RustAdmission.invalidBuffer }
            let owned = value.flags & UInt32(ARKTRACE_TRACK_OWNER) != 0
            let source: RustDensitySource
            switch value.source_kind {
            case UInt32(ARKTRACE_SOURCE_CPU):
                guard !owned, value.filter_id == 0, value.owner_value == 0 else { throw RustAdmission.invalidBuffer }
                source = .cpu(value.source_value)
            case UInt32(ARKTRACE_SOURCE_THREAD_STATE):
                guard !owned, value.filter_id == 0, value.owner_value == 0 else { throw RustAdmission.invalidBuffer }
                source = .threadState(ThreadKey(itid: value.source_value))
            case UInt32(ARKTRACE_SOURCE_NAMED_SLICE):
                guard value.filter_id == 0, value.owner_value == 0, owned || value.source_value == 0 else { throw RustAdmission.invalidBuffer }
                source = .namedSlice(owned ? ThreadKey(itid: value.source_value) : nil)
            case UInt32(ARKTRACE_SOURCE_CPU_COUNTER):
                guard value.source_value == 0, owned || value.owner_value == 0 else { throw RustAdmission.invalidBuffer }
                source = .cpuCounter(filterID: value.filter_id, cpu: owned ? value.owner_value : nil)
            case UInt32(ARKTRACE_SOURCE_PROCESS_COUNTER):
                guard value.source_value == 0, owned || value.owner_value == 0 else { throw RustAdmission.invalidBuffer }
                source = .processCounter(filterID: value.filter_id, processKey: owned ? ProcessKey(ipid: value.owner_value) : nil)
            case UInt32(ARKTRACE_SOURCE_FRAME):
                guard value.source_value == 0, value.filter_id == 0, owned || value.owner_value == 0 else { throw RustAdmission.invalidBuffer }
                source = .frame(processKey: owned ? ProcessKey(ipid: value.owner_value) : nil)
            default: throw RustAdmission.invalidBuffer
            }
            return .density(source: source, bucket: try TraceTimeRange.query(startNs: value.bucket_start_ns,
                endNs: value.bucket_end_ns), timeNs: value.time_ns)
        default: throw RustAdmission.invalidBuffer
        }
    }
}
