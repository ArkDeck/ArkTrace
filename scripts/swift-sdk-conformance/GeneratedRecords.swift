// Generated test-only projections; do not edit.
import CArkTrace
import Foundation
struct ProbeViewportRecord: Codable, Sendable {
    let start_ns: Int64
    let end_ns: Int64
    let ns_per_point: Double
    let width_points: Double
    let height_points: Double
    let vertical_offset_points: Double
    let generation: UInt64
    let source_generation: UInt64
    let backing_scale: Double
    init(_ record: ArkTraceViewportRecord) {
        start_ns = record.start_ns
        end_ns = record.end_ns
        ns_per_point = record.ns_per_point
        width_points = record.width_points
        height_points = record.height_points
        vertical_offset_points = record.vertical_offset_points
        generation = record.generation
        source_generation = record.source_generation
        backing_scale = record.backing_scale
    }
}
struct ProbeTrackRecord: Codable, Sendable {
    let source_kind: UInt32
    let flags: UInt32
    let source_value: Int64
    let filter_id: Int64
    let owner_value: Int64
    let id_offset: UInt32
    let id_length: UInt32
    let y: Double
    let height: Double
    let depth_rows: UInt32
    let primitive_start: UInt32
    let primitive_count: UInt32
    let reserved: UInt32
    init(_ record: ArkTraceTrackRecord) {
        source_kind = record.source_kind
        flags = record.flags
        source_value = record.source_value
        filter_id = record.filter_id
        owner_value = record.owner_value
        id_offset = record.id_offset
        id_length = record.id_length
        y = record.y
        height = record.height
        depth_rows = record.depth_rows
        primitive_start = record.primitive_start
        primitive_count = record.primitive_count
        reserved = record.reserved
    }
}
struct ProbePrimitiveRecord: Codable, Sendable {
    let kind: UInt32
    let flags: UInt32
    let track_index: UInt32
    let event_table: UInt32
    let style: UInt32
    let reserved_header: UInt32
    let depth: Int64
    let row_id: Int64
    let start_ns: Int64
    let end_ns: Int64
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let event_count: Int64
    let occupied_ns: Int64
    let utilization: Double
    let dominant_kind: UInt32
    let text_offset: UInt32
    let text_length: UInt32
    let reserved: UInt32
    let dominant_value: Int64
    init(_ record: ArkTracePrimitiveRecord) {
        kind = record.kind
        flags = record.flags
        track_index = record.track_index
        event_table = record.event_table
        style = record.style
        reserved_header = record.reserved_header
        depth = record.depth
        row_id = record.row_id
        start_ns = record.start_ns
        end_ns = record.end_ns
        x = record.x
        y = record.y
        width = record.width
        height = record.height
        event_count = record.event_count
        occupied_ns = record.occupied_ns
        utilization = record.utilization
        dominant_kind = record.dominant_kind
        text_offset = record.text_offset
        text_length = record.text_length
        reserved = record.reserved
        dominant_value = record.dominant_value
    }
}
struct ProbeQualityRecord: Codable, Sendable {
    let category: UInt32
    let flags: UInt32
    let scope_offset: UInt32
    let scope_length: UInt32
    let count: Int64
    init(_ record: ArkTraceQualityRecord) {
        category = record.category
        flags = record.flags
        scope_offset = record.scope_offset
        scope_length = record.scope_length
        count = record.count
    }
}
