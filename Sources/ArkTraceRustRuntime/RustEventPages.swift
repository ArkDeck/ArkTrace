import ArkTraceCore

final class RustEventLease<Record: Sendable>: Sendable {
    let records: [Record]
    let quality: [RustPackedQuality]
    let text: RustTextStorage
    let truncated: Bool
    let capabilityAvailable: Bool
    let identity: RustSessionIdentity

    init(records: [Record], quality: [RustPackedQuality], text: RustTextStorage,
         truncated: Bool, capabilityAvailable: Bool, identity: RustSessionIdentity) {
        self.records = records; self.quality = quality; self.text = text
        self.truncated = truncated; self.capabilityAvailable = capabilityAvailable; self.identity = identity
    }

    func string(_ range: Range<Int>?) -> RustOwnedText? {
        range.map { RustOwnedText(storage: text, range: $0) }
    }
}

/// Immutable bounded event results. Page copies, record views, sample views,
/// and UTF-8 views share one credit. Capacity accounting includes every nested
/// sample array; fixed owner overhead is policy accounting, not allocator/RSS.
public struct RustEventPage<Record: Sendable>: Sendable {
    private let record: @Sendable (Int) -> Record
    private let quality: [RustPackedQuality]
    private let text: RustTextStorage
    public let count: Int
    public let truncated: Bool
    public let capabilityAvailable: Bool
    public let sessionIdentity: RustSessionIdentity

    init<Packed>(_ lease: RustEventLease<Packed>, record: @escaping @Sendable (RustEventLease<Packed>, Int) -> Record) {
        self.record = { record(lease, $0) }
        quality = lease.quality; text = lease.text; count = lease.records.count
        truncated = lease.truncated; capabilityAvailable = lease.capabilityAvailable; sessionIdentity = lease.identity
    }

    public var retainedStorageBytes: Int { text.credit.bytes }
    public var qualityIssueCount: Int { quality.count }
    public subscript(index: Int) -> Record {
        precondition((0..<count).contains(index))
        return record(index)
    }
    public func qualityIssue(at index: Int) -> RustDirectoryQualityIssue {
        precondition(quality.indices.contains(index))
        return RustDirectoryQualityIssue(text: text, value: quality[index])
    }
}

public struct RustCounterSamples: Sendable {
    private let lease: RustEventLease<RustPackedCounter>
    private let index: Int
    init(lease: RustEventLease<RustPackedCounter>, index: Int) { self.lease = lease; self.index = index }
    public var count: Int { lease.records[index].samples.count }
    public subscript(sample: Int) -> RustCounterSampleRecord {
        precondition(lease.records[index].samples.indices.contains(sample))
        return RustCounterSampleRecord(lease: lease, group: index, sample: sample)
    }
}

public struct RustCounterSampleRecord: Sendable {
    private let lease: RustEventLease<RustPackedCounter>
    private let group: Int
    private let sample: Int
    init(lease: RustEventLease<RustPackedCounter>, group: Int, sample: Int) {
        self.lease = lease; self.group = group; self.sample = sample
    }
    private var packed: RustPackedCounterSample { lease.records[group].samples[sample] }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var key: EventKey { packed.key }
    public var timestampNs: Int64 { packed.timestampNs }
    public var value: Int64 { packed.value }
    public var durationNs: Int64? { packed.durationNs }
}
