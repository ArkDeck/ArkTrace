/// Stable internal process identity (AT-ID-001).
/// `ipid` is TraceStreamer's internal process key; PID is an attribute and may be reused.
public struct ProcessKey: Hashable, Codable, Sendable {
    public let ipid: Int64

    public init(ipid: Int64) {
        self.ipid = ipid
    }
}

/// Stable internal thread identity (AT-ID-002).
public struct ThreadKey: Hashable, Codable, Sendable {
    public let itid: Int64

    public init(itid: Int64) {
        self.itid = itid
    }
}

/// Source table of a selectable event (AT-ID-003).
public enum TraceEventTable: String, Codable, Sendable {
    case schedSlice = "sched_slice"
    case threadState = "thread_state"
    case callstack = "callstack"
    case measure = "measure"
}

/// Event identity: stable within one parser/cache identity (AT-ID-003).
public struct EventKey: Hashable, Codable, Sendable {
    public let table: TraceEventTable
    public let rowID: Int64

    public init(table: TraceEventTable, rowID: Int64) {
        self.table = table
        self.rowID = rowID
    }
}
