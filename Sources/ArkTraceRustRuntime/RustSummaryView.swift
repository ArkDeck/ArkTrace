import ArkTraceCore

struct RustPackedSummaryCount: Sendable {
    let value: Int64
    let truncated: Bool
}
struct RustPackedSummarySource: Sendable {
    let source: Range<Int>
    let count: Int64
}
struct RustPackedSummary: Sendable {
    let cpu, cpuSlices, threadStates, namedSlices, counterSeries: RustPackedSummaryCount?
    let processes, threads: RustPackedSummaryCount
    let sources: [RustPackedSummarySource]?
    let sourcesTruncated: Bool
    let quality: [RustPackedQuality]
}
final class RustSummaryLease: Sendable {
    let value: RustPackedSummary
    let text: RustTextStorage
    let identity: RustSessionIdentity
    init(value: RustPackedSummary, text: RustTextStorage, identity: RustSessionIdentity) {
        self.value = value; self.text = text; self.identity = identity
    }
}

/// Immutable query facts. Counts, source collections, records and text retain
/// one shared SDK reservation; there is no public String/array materialization.
/// Query quality remains separate from the trace's opening quality.
public struct RustSummaryView: Sendable {
    private let lease: RustSummaryLease
    init(_ lease: RustSummaryLease) { self.lease = lease }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var retainedStorageBytes: Int { lease.text.credit.bytes }
    private func count(_ value: RustPackedSummaryCount?) -> RustSummaryCountView? {
        value.map { RustSummaryCountView(lease: lease, value: $0) }
    }
    public var cpuCount: RustSummaryCountView? { count(lease.value.cpu) }
    public var processCount: RustSummaryCountView { RustSummaryCountView(lease: lease, value: lease.value.processes) }
    public var threadCount: RustSummaryCountView { RustSummaryCountView(lease: lease, value: lease.value.threads) }
    public var cpuSliceCount: RustSummaryCountView? { count(lease.value.cpuSlices) }
    public var threadStateCount: RustSummaryCountView? { count(lease.value.threadStates) }
    public var namedSliceCount: RustSummaryCountView? { count(lease.value.namedSlices) }
    public var counterSeriesCount: RustSummaryCountView? { count(lease.value.counterSeries) }
    public var eventCountBySource: RustSummarySourcesView? {
        lease.value.sources.map { RustSummarySourcesView(lease: lease, records: $0) }
    }
    public var qualityIssueCount: Int { lease.value.quality.count }
    public func qualityIssue(at index: Int) -> RustDirectoryQualityIssue {
        precondition(lease.value.quality.indices.contains(index))
        return RustDirectoryQualityIssue(text: lease.text, value: lease.value.quality[index])
    }
}

public struct RustSummaryCountView: Sendable {
    private let lease: RustSummaryLease
    private let packed: RustPackedSummaryCount
    init(lease: RustSummaryLease, value: RustPackedSummaryCount) { self.lease = lease; self.packed = value }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var value: Int64 { packed.value }
    public var truncated: Bool { packed.truncated }
}

/// A nil collection means the native source counts are unavailable. An empty
/// collection is an available result with no sampled received-stat sources.
public struct RustSummarySourcesView: Sendable {
    private let lease: RustSummaryLease
    private let records: [RustPackedSummarySource]
    init(lease: RustSummaryLease, records: [RustPackedSummarySource]) { self.lease = lease; self.records = records }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var count: Int { records.count }
    public var truncated: Bool { lease.value.sourcesTruncated }
    public subscript(index: Int) -> RustSummarySourceRecord {
        precondition(records.indices.contains(index))
        return RustSummarySourceRecord(lease: lease, value: records[index])
    }
}

public struct RustSummarySourceRecord: Sendable {
    private let lease: RustSummaryLease
    private let value: RustPackedSummarySource
    init(lease: RustSummaryLease, value: RustPackedSummarySource) { self.lease = lease; self.value = value }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var source: RustOwnedText { RustOwnedText(storage: lease.text, range: value.source) }
    public var count: Int64 { value.count }
}
