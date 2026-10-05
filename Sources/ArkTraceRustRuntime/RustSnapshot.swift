import CArkTrace
import Foundation

/// One immutable retained scene. MainActor rendering reads safe borrowed spans;
/// it performs neither FFI polling nor JSON decoding and owns no native memory.
@safe
private final class SnapshotLease: @unchecked Sendable {
    let view: ArkTraceSnapshotView
    init(_ view: ArkTraceSnapshotView) { unsafe self.view = view }
    deinit {
        let owner = unsafe view.owner
        RustCleanup.schedule { try await releaseResultOwner(owner) }
    }
}

public struct RustSnapshot: Sendable {
    private let lease: SnapshotLease
    init(_ view: ArkTraceSnapshotView) throws {
        guard unsafe view.struct_size == UInt32(MemoryLayout<ArkTraceSnapshotView>.size),
            unsafe view.retained_bytes <= 256 * 1024 * 1024, unsafe view.owner != 0, unsafe view.format_version == ARKTRACE_SNAPSHOT_FORMAT_VERSION, unsafe view.track_count <= 10_000,
            unsafe view.primitive_count <= 20_000, unsafe view.quality_count <= 4096,
            unsafe view.string_bytes <= 16 * 1024 * 1024, unsafe view.reserved == 0,
            unsafe view.quality_status == ARKTRACE_QUALITY_STATUS_OK || view.quality_status == ARKTRACE_QUALITY_STATUS_WARNINGS,
            unsafe (view.track_count == 0 || view.tracks != nil),
            unsafe (view.primitive_count == 0 || view.primitives != nil),
            unsafe (view.quality_count == 0 || view.quality != nil),
            unsafe (view.string_bytes == 0 || view.strings != nil) else { throw RustAdmission.invalidBuffer }
        lease = unsafe SnapshotLease(view)
    }
    public var viewport: ArkTraceViewportRecord { unsafe lease.view.viewport }
    public var qualityStatus: UInt32 { unsafe lease.view.quality_status }
    public var retainedBytes: UInt64 { unsafe lease.view.retained_bytes }
    public var trackCount: Int { unsafe Int(lease.view.track_count) }
    public var primitiveCount: Int { unsafe Int(lease.view.primitive_count) }
    public var qualityCount: Int { unsafe Int(lease.view.quality_count) }
    public var stringByteCount: Int { unsafe Int(lease.view.string_bytes) }
    /// Callback spans cannot be returned or captured by escaping closures.
    /// No experimental lifetime feature or unsafe caller annotation is needed.
    public func withRecords<R>(_ body: (Span<ArkTraceTrackRecord>, Span<ArkTracePrimitiveRecord>, Span<ArkTraceQualityRecord>, Span<UInt8>) throws -> R) rethrows -> R {
        try withExtendedLifetime(self) {
            // Local buffers give each Span a lexical borrow and preserve the
            // native nil/zero representation of empty record or string pools.
            let trackBuffer = unsafe UnsafeBufferPointer(start: lease.view.tracks, count: trackCount)
            let primitiveBuffer = unsafe UnsafeBufferPointer(start: lease.view.primitives, count: primitiveCount)
            let qualityBuffer = unsafe UnsafeBufferPointer(start: lease.view.quality, count: qualityCount)
            let stringBuffer = unsafe UnsafeBufferPointer(start: lease.view.strings, count: stringByteCount)
            let tracks = unsafe Span(_unsafeElements: trackBuffer)
            let primitives = unsafe Span(_unsafeElements: primitiveBuffer)
            let quality = unsafe Span(_unsafeElements: qualityBuffer)
            let strings = unsafe Span(_unsafeElements: stringBuffer)
            return try body(tracks, primitives, quality, strings)
        }
    }
}
