/// Identity of the parser that produced a derived database (AT-PARSE-002).
/// Machine output must never expose absolute paths; identity is hash/version based.
public struct TraceParserIdentity: Hashable, Codable, Sendable {
    public let name: String
    public let reportedVersion: String
    public let binarySHA256: String
    public let upstreamRepository: String
    public let upstreamRevision: String
    public let architecture: String
    public let adapterVersion: String
    public let buildRecipeVersion: String

    public init(
        name: String,
        reportedVersion: String,
        binarySHA256: String,
        upstreamRepository: String,
        upstreamRevision: String,
        architecture: String,
        adapterVersion: String,
        buildRecipeVersion: String
    ) {
        self.name = name
        self.reportedVersion = reportedVersion
        self.binarySHA256 = binarySHA256
        self.upstreamRepository = upstreamRepository
        self.upstreamRevision = upstreamRevision
        self.architecture = architecture
        self.adapterVersion = adapterVersion
        self.buildRecipeVersion = buildRecipeVersion
    }
}

/// Capability set established by schema introspection (DESIGN §9.1).
public struct TraceCapabilities: Hashable, Codable, Sendable {
    public let cpuScheduling: Bool
    public let threadStates: Bool
    public let namedSlices: Bool
    public let cpuCounters: Bool
    public let processCounters: Bool

    public init(
        cpuScheduling: Bool,
        threadStates: Bool,
        namedSlices: Bool,
        cpuCounters: Bool,
        processCounters: Bool
    ) {
        self.cpuScheduling = cpuScheduling
        self.threadStates = threadStates
        self.namedSlices = namedSlices
        self.cpuCounters = cpuCounters
        self.processCounters = processCounters
    }
}

/// Stable machine-readable quality evidence. Consumers branch on `category`;
/// `message` is only supplemental human context and is never the semantic key.
public struct TraceDataQualityIssue: Hashable, Codable, Sendable {
    public enum Category: String, Codable, Sendable, CaseIterable {
        case probeTruncated
        case invalidValue
        case clampedValue
        case droppedValue
        case referentialIntegrity
        /// A typed field or aggregate is intentionally unavailable for this
        /// result even though the surrounding capability is usable.
        case unavailableValue
        /// Compatibility category for library callers that still supply only
        /// a human warning. Production Store/Analysis paths use specific kinds.
        case unclassified
    }

    public let category: Category
    public let scope: String?
    public let count: Int64?
    public let message: String?

    public init(
        category: Category,
        scope: String? = nil,
        count: Int64? = nil,
        message: String? = nil
    ) {
        self.category = category
        self.scope = scope
        self.count = count
        self.message = message
    }
}

/// Closed machine-facing vocabulary for quality scopes emitted by ArkTrace.
/// Store and presentation boundaries share this fact source so a new typed
/// warning cannot silently become an encoding failure.
package enum TraceDataQualityScope {
    public static let machineAllowed: Set<String> = [
        "process.start_ts", "process.end_ts", "process.lifecycle",
        "process.name",
        "thread.start_ts", "thread.end_ts", "thread.ipid", "thread.lifecycle",
        "thread.name", "thread.processName",
        "sched_slice.ts", "sched_slice.dur", "sched_slice.cpu",
        "sched_slice.value", "sched_slice.identity", "sched_slice.overlap",
        "thread_state.ts", "thread_state.dur", "thread_state.cpu",
        "thread_state.value", "thread_state.identity", "thread_state.state",
        "callstack.ts", "callstack.dur", "callstack.depth",
        "callstack.parent_id", "callstack.cookie", "callstack.value",
        "callstack.identity",
        "measure.ts", "measure.filter_id", "measure.value", "measure.dur",
        "measure.optional",
        // Process counter samples come from `process_measure`, so quality
        // evidence about them names that table rather than `measure` -- which
        // on a real capture is empty and would misdirect the reader.
        "process_measure.ts", "process_measure.filter_id",
        "process_measure.value", "process_measure.dur",
        "process_measure.optional",
        "cpu_measure_filter.id", "cpu_measure_filter.name",
        "cpu_measure_filter.cpu", "cpu_measure_filter.unit",
        "process_measure_filter.id", "process_measure_filter.name",
        "process_measure_filter.ipid", "process_measure_filter.unit",
        "stat", "stat.count", "stat.source", "stat.event_name", "stat.stat_type",
        "timeline.density.occupancy", "timeline.density.dominantThread",
        "timeline.counter",
        "timeline.counter.duration",
    ]

    public static func eventValue(table: String) -> String {
        "\(table).value"
    }

    public static func eventIdentity(table: String) -> String {
        "\(table).identity"
    }
}

/// Data-quality signal carried by results instead of being logged away (AT-QUERY-008).
public struct TraceDataQuality: Hashable, Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ok
        case warnings
    }

    public let status: Status
    public let warnings: [String]
    public let issues: [TraceDataQualityIssue]

    public init() {
        self.init(warnings: [], issues: [])
    }

    public init(warnings: [String]) {
        self.init(warnings: warnings, issues: [])
    }

    public init(issues: [TraceDataQualityIssue]) {
        self.init(warnings: [], issues: issues)
    }

    public init(
        warnings: [String],
        issues: [TraceDataQualityIssue]
    ) {
        var seenIssues: Set<TraceDataQualityIssue> = []
        var combined = issues.filter { seenIssues.insert($0).inserted }
        var representedMessages = Set(issues.compactMap(\.message))
        for warning in warnings where representedMessages.insert(warning).inserted {
            combined.append(
                TraceDataQualityIssue(
                    category: .unclassified,
                    message: warning
                )
            )
        }
        self.status = combined.isEmpty ? .ok : .warnings
        var seenMessages: Set<String> = []
        self.warnings = combined.compactMap(\.message).filter {
            seenMessages.insert($0).inserted
        }
        self.issues = combined
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case warnings
        case issues
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        let issues = try container.decodeIfPresent(
            [TraceDataQualityIssue].self,
            forKey: .issues
        ) ?? []
        self.init(warnings: warnings, issues: issues)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(warnings, forKey: .warnings)
        try container.encode(issues, forKey: .issues)
    }
}

public struct TraceMetadata: Codable, Sendable {
    public let traceSHA256: String
    public let sourceByteCount: Int64
    public let durationNs: Int64
    public let sourceFormat: String?
    public let parser: TraceParserIdentity
    public let schemaFingerprint: String
    public let capabilities: TraceCapabilities
    public let dataQuality: TraceDataQuality

    public init(
        traceSHA256: String,
        sourceByteCount: Int64,
        durationNs: Int64,
        sourceFormat: String?,
        parser: TraceParserIdentity,
        schemaFingerprint: String,
        capabilities: TraceCapabilities,
        dataQuality: TraceDataQuality
    ) {
        self.traceSHA256 = traceSHA256
        self.sourceByteCount = sourceByteCount
        self.durationNs = durationNs
        self.sourceFormat = sourceFormat
        self.parser = parser
        self.schemaFingerprint = schemaFingerprint
        self.capabilities = capabilities
        self.dataQuality = dataQuality
    }
}

package struct TraceProcess: Codable, Sendable, Hashable {
    public let key: ProcessKey
    public let pid: Int64
    public let name: String?
    public let startNs: Int64?
    public let endNs: Int64?
    public let threadCount: Int?

    public init(
        key: ProcessKey,
        pid: Int64,
        name: String?,
        startNs: Int64?,
        endNs: Int64?,
        threadCount: Int?
    ) {
        self.key = key
        self.pid = pid
        self.name = name
        self.startNs = startNs
        self.endNs = endNs
        self.threadCount = threadCount
    }

    private enum CodingKeys: String, CodingKey {
        case key, pid, name, startNs, endNs, threadCount
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(key, forKey: .key)
        try values.encode(pid, forKey: .pid)
        try values.encodeNullable(name, forKey: .name)
        try values.encodeNullable(startNs, forKey: .startNs)
        try values.encodeNullable(endNs, forKey: .endNs)
        try values.encodeNullable(threadCount, forKey: .threadCount)
    }
}

package struct TraceThread: Codable, Sendable, Hashable {
    public let key: ThreadKey
    public let processKey: ProcessKey?
    public let tid: Int64
    public let pid: Int64?
    public let name: String?
    public let processName: String?
    public let startNs: Int64?
    public let endNs: Int64?
    public let isMainThread: Bool?

    public init(
        key: ThreadKey,
        processKey: ProcessKey?,
        tid: Int64,
        pid: Int64?,
        name: String?,
        processName: String?,
        startNs: Int64?,
        endNs: Int64?,
        isMainThread: Bool?
    ) {
        self.key = key
        self.processKey = processKey
        self.tid = tid
        self.pid = pid
        self.name = name
        self.processName = processName
        self.startNs = startNs
        self.endNs = endNs
        self.isMainThread = isMainThread
    }

    private enum CodingKeys: String, CodingKey {
        case key, processKey, tid, pid, name, processName
        case startNs, endNs, isMainThread
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(key, forKey: .key)
        try values.encodeNullable(processKey, forKey: .processKey)
        try values.encode(tid, forKey: .tid)
        try values.encodeNullable(pid, forKey: .pid)
        try values.encodeNullable(name, forKey: .name)
        try values.encodeNullable(processName, forKey: .processName)
        try values.encodeNullable(startNs, forKey: .startNs)
        try values.encodeNullable(endNs, forKey: .endNs)
        try values.encodeNullable(isMainThread, forKey: .isMainThread)
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeNullable<T: Encodable>(
        _ value: T?,
        forKey key: Key
    ) throws {
        if let value { try encode(value, forKey: key) }
        else { try encodeNil(forKey: key) }
    }
}
