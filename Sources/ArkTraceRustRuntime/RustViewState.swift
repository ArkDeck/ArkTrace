import ArkTraceCore

/// Caller-owned inputs. IDs, colors, order and duplicates retain format-1
/// semantics. Bounds are checked before the SDK allocates encoded bytes.
public struct RustViewStateFlag: Sendable {
    public let id: Int64
    public let timestampNs: Int64
    public let label: String
    public let colorIndex: Int64
    public init(id: Int64, timestampNs: Int64, label: String, colorIndex: Int64) {
        self.id = id; self.timestampNs = timestampNs; self.label = label; self.colorIndex = colorIndex
    }
}

public struct RustViewStateMark: Sendable {
    public let id: Int64
    public let range: TraceTimeRange
    public let label: String
    public let colorIndex: Int64
    public let isPersistent: Bool
    public init(id: Int64, range: TraceTimeRange, label: String, colorIndex: Int64, isPersistent: Bool) {
        self.id = id; self.range = range; self.label = label; self.colorIndex = colorIndex; self.isPersistent = isPersistent
    }
}

public struct RustViewStateDocument: Sendable {
    public let traceSHA256: String
    public let flags: [RustViewStateFlag]
    public let marks: [RustViewStateMark]
    public let favoriteTrackIDs: [String]?
    public init(traceSHA256: String, flags: [RustViewStateFlag], marks: [RustViewStateMark], favoriteTrackIDs: [String]? = nil) {
        self.traceSHA256 = traceSHA256; self.flags = flags; self.marks = marks; self.favoriteTrackIDs = favoriteTrackIDs
    }
}

public enum RustViewStateRead: Sendable {
    case sessionScoped, missing, preserved
    case restored(RustViewStateView)
}

/// Preserved means no mutation was committed. The caller must keep this
/// distinct from saved/removed when presenting persistence failures.
public enum RustViewStateWrite: String, Sendable, Decodable {
    case sessionScoped, saved, removed, preserved
}

struct RustPackedViewFlag: Sendable {
    let id: Int64
    let timestampNs: Int64
    let label: Range<Int>
    let colorIndex: Int64
}
struct RustPackedViewMark: Sendable {
    let id: Int64
    let range: TraceTimeRange
    let label: Range<Int>
    let colorIndex: Int64
    let isPersistent: Bool
}
struct RustPackedViewFavorite: Sendable {
    let text: Range<Int>
}
final class RustViewStateLease: Sendable {
    let flags: [RustPackedViewFlag]
    let marks: [RustPackedViewMark]
    let favorites: [RustPackedViewFavorite]?
    let hash: Range<Int>
    let text: RustTextStorage
    let identity: RustSessionIdentity
    init(flags: [RustPackedViewFlag], marks: [RustPackedViewMark], favorites: [RustPackedViewFavorite]?,
         hash: Range<Int>, text: RustTextStorage, identity: RustSessionIdentity) {
        self.flags = flags; self.marks = marks; self.favorites = favorites
        self.hash = hash; self.text = text; self.identity = identity
    }
}

/// Packed arrays and UTF-8 share one credit. Views remain readable after the
/// request, session and Engine close; explicit String copies belong to callers.
public struct RustViewStateView: Sendable {
    private let lease: RustViewStateLease
    init(_ lease: RustViewStateLease) { self.lease = lease }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var retainedStorageBytes: Int { lease.text.credit.bytes }
    public var traceSHA256: RustOwnedText { RustOwnedText(storage: lease.text, range: lease.hash) }
    public var flagCount: Int { lease.flags.count }
    public var markCount: Int { lease.marks.count }
    /// nil preserves an absent/null legacy favorites field.
    public var favoriteTrackCount: Int? { lease.favorites?.count }
    public func flag(at index: Int) -> RustViewStateFlagRecord {
        precondition(lease.flags.indices.contains(index))
        return RustViewStateFlagRecord(lease: lease, index: index)
    }
    public func mark(at index: Int) -> RustViewStateMarkRecord {
        precondition(lease.marks.indices.contains(index))
        return RustViewStateMarkRecord(lease: lease, index: index)
    }
    public func favoriteTrackID(at index: Int) -> RustOwnedText {
        precondition(lease.favorites?.indices.contains(index) == true)
        return RustOwnedText(storage: lease.text, range: lease.favorites![index].text)
    }
}
public struct RustViewStateFlagRecord: Sendable {
    private let lease: RustViewStateLease
    private let index: Int
    init(lease: RustViewStateLease, index: Int) { self.lease = lease; self.index = index }
    private var value: RustPackedViewFlag { lease.flags[index] }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var id: Int64 { value.id }
    public var timestampNs: Int64 { value.timestampNs }
    public var colorIndex: Int64 { value.colorIndex }
    public var label: RustOwnedText { RustOwnedText(storage: lease.text, range: value.label) }
}
public struct RustViewStateMarkRecord: Sendable {
    private let lease: RustViewStateLease
    private let index: Int
    init(lease: RustViewStateLease, index: Int) { self.lease = lease; self.index = index }
    private var value: RustPackedViewMark { lease.marks[index] }
    public var sessionIdentity: RustSessionIdentity { lease.identity }
    public var id: Int64 { value.id }
    public var range: TraceTimeRange { value.range }
    public var colorIndex: Int64 { value.colorIndex }
    public var isPersistent: Bool { value.isPersistent }
    public var label: RustOwnedText { RustOwnedText(storage: lease.text, range: value.label) }
}
