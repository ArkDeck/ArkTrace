import ArkTraceCore

/// A density color identity is an attribute, never a selectable event key.
public enum RustDensityIdentity: Sendable {
    case processOrThread(Int64)
    case name(RustOwnedText)
    case threadState(RustOwnedText)
    case jank(Int64)
}

/// Immutable sparse density buckets. Bucket, identity-text and quality views
/// retain the whole bounded result credit after session close or shutdown.
public struct RustDensityResult: Sendable {
    private let lease: RustEventLease<RustPackedDensityBucket>
    init(_ lease: RustEventLease<RustPackedDensityBucket>) { self.lease = lease }
    public var count: Int { lease.records.count }
    public var capabilityAvailable: Bool { lease.capabilityAvailable }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var retainedStorageBytes: Int { lease.text.credit.bytes }
    public var qualityIssueCount: Int { lease.quality.count }
    public subscript(index: Int) -> RustDensityBucketRecord {
        precondition(lease.records.indices.contains(index))
        return RustDensityBucketRecord(lease: lease, index: index)
    }
    public func qualityIssue(at index: Int) -> RustDirectoryQualityIssue {
        precondition(lease.quality.indices.contains(index))
        return RustDirectoryQualityIssue(text: lease.text, value: lease.quality[index])
    }
}

public struct RustDensityBucketRecord: Sendable {
    private let lease: RustEventLease<RustPackedDensityBucket>
    private let index: Int
    init(lease: RustEventLease<RustPackedDensityBucket>, index: Int) { self.lease = lease; self.index = index }
    private var packed: RustPackedDensityBucket { lease.records[index] }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var range: TraceTimeRange { packed.range }
    public var eventCount: Int64 { packed.eventCount }
    public var occupiedNs: Int64? { packed.occupiedNs }
    public var utilization: Double? { packed.utilization }
    public var dominant: RustDensityIdentity? {
        switch packed.dominant {
        case .processOrThread(let value): return .processOrThread(value)
        case .name(let range): return .name(RustOwnedText(storage: lease.text, range: range))
        case .threadState(let range): return .threadState(RustOwnedText(storage: lease.text, range: range))
        case .jank(let value): return .jank(value)
        case nil: return nil
        }
    }
}
