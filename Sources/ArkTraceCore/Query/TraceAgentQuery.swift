/// Closed, Agent-facing event views. Adding a view is a versioned contract
/// change; callers cannot name a table, column, SQL fragment, or expression.
package enum TraceAgentQueryView: String, Codable, CaseIterable, Hashable, Sendable {
    case cpuSlices
    case threadStates
    case slices
    case counters
}

package enum TraceAgentTextMatch: String, Codable, Sendable {
    case exact
    case prefix
    case contains
}

/// Superset of the typed filters accepted by the four closed views. The query
/// engine rejects fields that do not belong to the selected view before any
/// repository call is made.
package struct TraceAgentQueryFilters: Hashable, Codable, Sendable {
    public static let none = TraceAgentQueryFilters(empty: ())

    public let cpu: Int64?
    public let processKey: ProcessKey?
    public let pid: Int64?
    public let threadKey: ThreadKey?
    public let tid: Int64?
    public let rawState: String?
    public let normalizedState: TraceThreadState?
    public let name: String?
    public let nameMatch: TraceAgentTextMatch
    public let minimumDurationNs: Int64?
    public let depth: Int64?
    public let counterFilterID: Int64?

    public init(
        cpu: Int64? = nil,
        processKey: ProcessKey? = nil,
        pid: Int64? = nil,
        threadKey: ThreadKey? = nil,
        tid: Int64? = nil,
        rawState: String? = nil,
        normalizedState: TraceThreadState? = nil,
        name: String? = nil,
        nameMatch: TraceAgentTextMatch = .exact,
        minimumDurationNs: Int64? = nil,
        depth: Int64? = nil,
        counterFilterID: Int64? = nil
    ) throws {
        if let rawState, rawState.isEmpty || rawState.utf8.count > 256 {
            throw Self.invalid("rawState must contain 1...256 UTF-8 bytes")
        }
        if let name, name.isEmpty || name.utf8.count > 256 {
            throw Self.invalid("name must contain 1...256 UTF-8 bytes")
        }
        if name == nil, nameMatch != .exact {
            throw Self.invalid("nameMatch requires a name filter")
        }
        if let minimumDurationNs, minimumDurationNs < 0 {
            throw Self.invalid("minimumDurationNs must be non-negative")
        }
        if let depth, depth < 0 {
            throw Self.invalid("depth must be non-negative")
        }
        if processKey?.ipid == 0 {
            throw Self.invalid("processKey 0 is the absent identity sentinel")
        }
        if threadKey?.itid == 0 {
            throw Self.invalid("threadKey 0 is the absent identity sentinel")
        }
        self.cpu = cpu
        self.processKey = processKey
        self.pid = pid
        self.threadKey = threadKey
        self.tid = tid
        self.rawState = rawState
        self.normalizedState = normalizedState
        self.name = name
        self.nameMatch = nameMatch
        self.minimumDurationNs = minimumDurationNs
        self.depth = depth
        self.counterFilterID = counterFilterID
    }

    private init(empty: Void) {
        cpu = nil
        processKey = nil
        pid = nil
        threadKey = nil
        tid = nil
        rawState = nil
        normalizedState = nil
        name = nil
        nameMatch = .exact
        minimumDurationNs = nil
        depth = nil
        counterFilterID = nil
    }

    private static func invalid(_ message: String) -> ArkTraceError {
        ArkTraceError(code: .invalidArgument, stage: .request, message: message)
    }

    private enum CodingKeys: String, CodingKey {
        case cpu, processKey, pid, threadKey, tid, rawState, normalizedState
        case name, nameMatch, minimumDurationNs, depth, counterFilterID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            cpu: values.decodeIfPresent(Int64.self, forKey: .cpu),
            processKey: values.decodeIfPresent(ProcessKey.self, forKey: .processKey),
            pid: values.decodeIfPresent(Int64.self, forKey: .pid),
            threadKey: values.decodeIfPresent(ThreadKey.self, forKey: .threadKey),
            tid: values.decodeIfPresent(Int64.self, forKey: .tid),
            rawState: values.decodeIfPresent(String.self, forKey: .rawState),
            normalizedState: values.decodeIfPresent(
                TraceThreadState.self, forKey: .normalizedState
            ),
            name: values.decodeIfPresent(String.self, forKey: .name),
            nameMatch: values.decodeIfPresent(TraceAgentTextMatch.self, forKey: .nameMatch)
                ?? .exact,
            minimumDurationNs: values.decodeIfPresent(
                Int64.self, forKey: .minimumDurationNs
            ),
            depth: values.decodeIfPresent(Int64.self, forKey: .depth),
            counterFilterID: values.decodeIfPresent(Int64.self, forKey: .counterFilterID)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try Self.encodeNullable(cpu, to: &values, forKey: .cpu)
        try Self.encodeNullable(processKey, to: &values, forKey: .processKey)
        try Self.encodeNullable(pid, to: &values, forKey: .pid)
        try Self.encodeNullable(threadKey, to: &values, forKey: .threadKey)
        try Self.encodeNullable(tid, to: &values, forKey: .tid)
        try Self.encodeNullable(rawState, to: &values, forKey: .rawState)
        try Self.encodeNullable(normalizedState, to: &values, forKey: .normalizedState)
        try Self.encodeNullable(name, to: &values, forKey: .name)
        try values.encode(nameMatch, forKey: .nameMatch)
        try Self.encodeNullable(
            minimumDurationNs, to: &values, forKey: .minimumDurationNs
        )
        try Self.encodeNullable(depth, to: &values, forKey: .depth)
        try Self.encodeNullable(counterFilterID, to: &values, forKey: .counterFilterID)
    }

    private static func encodeNullable<T: Encodable>(
        _ value: T?,
        to values: inout KeyedEncodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws {
        if let value { try values.encode(value, forKey: key) }
        else { try values.encodeNil(forKey: key) }
    }
}

package struct TraceAgentQueryRequest: Sendable {
    public let view: TraceAgentQueryView
    public let range: TraceTimeRange
    public let filters: TraceAgentQueryFilters
    public let limit: Int
    public let timeout: Duration

    public init(
        view: TraceAgentQueryView,
        range: TraceTimeRange,
        filters: TraceAgentQueryFilters = .none,
        limit: Int = 10_000,
        timeout: Duration = .seconds(10)
    ) throws {
        guard range.startNs < range.endNs else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Agent query range must be non-empty"
            )
        }
        guard (1...100_000).contains(limit), timeout >= .milliseconds(100),
            timeout <= .seconds(120)
        else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Agent query limit or timeout is invalid"
            )
        }
        try Self.validate(filters, for: view)
        self.view = view
        self.range = range
        self.filters = filters
        self.limit = limit
        self.timeout = timeout
    }

    private static func validate(
        _ filters: TraceAgentQueryFilters,
        for view: TraceAgentQueryView
    ) throws {
        let invalid: Bool
        switch view {
        case .cpuSlices:
            invalid = filters.rawState != nil || filters.normalizedState != nil
                || filters.name != nil || filters.minimumDurationNs != nil
                || filters.depth != nil || filters.counterFilterID != nil
        case .threadStates:
            invalid = filters.name != nil || filters.minimumDurationNs != nil
                || filters.depth != nil || filters.counterFilterID != nil
        case .slices:
            invalid = filters.cpu != nil || filters.rawState != nil
                || filters.normalizedState != nil || filters.counterFilterID != nil
        case .counters:
            invalid = filters.threadKey != nil || filters.tid != nil
                || filters.rawState != nil || filters.normalizedState != nil
                || filters.minimumDurationNs != nil || filters.depth != nil
                || (filters.cpu != nil
                    && (filters.processKey != nil || filters.pid != nil))
        }
        guard !invalid else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Agent query filter is not supported by the selected view"
            )
        }
    }
}

/// A closed result shape is used for all four views. Codable emits exactly one
/// event-array key selected by `view`; an empty selected array is still an
/// explicit payload. This avoids dynamically named keys or raw row maps while
/// making mixed-view documents impossible to decode.
package struct TraceAgentCounterEvent: Hashable, Codable, Sendable {
    public let filterID: Int64
    public let name: String
    public let scope: CounterScope
    public let cpu: Int64?
    public let processKey: ProcessKey?
    public let pid: Int64?
    public let processName: String?
    public let unit: String?
    public let sample: CounterSample

    public init(series: CounterSeries, sample: CounterSample) {
        filterID = series.filterID
        name = series.name
        scope = series.scope
        cpu = series.cpu
        processKey = series.processKey
        pid = series.pid
        processName = series.processName
        unit = series.unit
        self.sample = sample
    }

    private enum CodingKeys: String, CodingKey {
        case filterID, name, scope, cpu, processKey, pid, processName, unit, sample
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(filterID, forKey: .filterID)
        try values.encode(name, forKey: .name)
        try values.encode(scope, forKey: .scope)
        try Self.encodeNullable(cpu, to: &values, forKey: .cpu)
        try Self.encodeNullable(processKey, to: &values, forKey: .processKey)
        try Self.encodeNullable(pid, to: &values, forKey: .pid)
        try Self.encodeNullable(processName, to: &values, forKey: .processName)
        try Self.encodeNullable(unit, to: &values, forKey: .unit)
        try values.encode(sample, forKey: .sample)
    }

    private static func encodeNullable<T: Encodable>(
        _ value: T?,
        to values: inout KeyedEncodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws {
        if let value { try values.encode(value, forKey: key) }
        else { try values.encodeNil(forKey: key) }
    }
}

package struct TraceAgentQueryResult: Hashable, Codable, Sendable {
    public let view: TraceAgentQueryView
    public let range: TraceTimeRange
    public let filters: TraceAgentQueryFilters
    public let capabilityAvailable: Bool
    public let truncated: Bool
    public let dataQuality: TraceDataQuality
    public let cpuSlices: [CpuSlice]
    public let threadStates: [ThreadStateInterval]
    public let slices: [TraceSlice]
    public let counters: [TraceAgentCounterEvent]

    public init(
        view: TraceAgentQueryView,
        range: TraceTimeRange,
        filters: TraceAgentQueryFilters = .none,
        capabilityAvailable: Bool,
        truncated: Bool,
        dataQuality: TraceDataQuality,
        cpuSlices: [CpuSlice] = [],
        threadStates: [ThreadStateInterval] = [],
        slices: [TraceSlice] = [],
        counters: [TraceAgentCounterEvent] = []
    ) throws {
        let invalidPayload: Bool
        switch view {
        case .cpuSlices:
            invalidPayload = !threadStates.isEmpty || !slices.isEmpty || !counters.isEmpty
        case .threadStates:
            invalidPayload = !cpuSlices.isEmpty || !slices.isEmpty || !counters.isEmpty
        case .slices:
            invalidPayload = !cpuSlices.isEmpty || !threadStates.isEmpty || !counters.isEmpty
        case .counters:
            invalidPayload = !cpuSlices.isEmpty || !threadStates.isEmpty || !slices.isEmpty
        }
        guard !invalidPayload else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Agent query result contains a payload for the wrong view"
            )
        }
        self.view = view
        self.range = range
        self.filters = filters
        self.capabilityAvailable = capabilityAvailable
        self.truncated = truncated
        self.dataQuality = dataQuality
        self.cpuSlices = cpuSlices
        self.threadStates = threadStates
        self.slices = slices
        self.counters = counters
    }

    public var eventCount: Int {
        switch view {
        case .cpuSlices: cpuSlices.count
        case .threadStates: threadStates.count
        case .slices: slices.count
        case .counters: counters.count
        }
    }

    private enum CodingKeys: String, CodingKey {
        case view, range, filters, capabilityAvailable, truncated, dataQuality
        case cpuSlices, threadStates, slices, counters
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let view = try values.decode(TraceAgentQueryView.self, forKey: .view)
        let payloadKeys: [CodingKeys] = [.cpuSlices, .threadStates, .slices, .counters]
        let present = payloadKeys.filter(values.contains)
        let expected: CodingKeys
        switch view {
        case .cpuSlices: expected = .cpuSlices
        case .threadStates: expected = .threadStates
        case .slices: expected = .slices
        case .counters: expected = .counters
        }
        guard present == [expected] else {
            throw DecodingError.dataCorruptedError(
                forKey: expected,
                in: values,
                debugDescription: "Agent query result must contain exactly its selected payload"
            )
        }
        try self.init(
            view: view,
            range: values.decode(TraceTimeRange.self, forKey: .range),
            filters: values.decode(TraceAgentQueryFilters.self, forKey: .filters),
            capabilityAvailable: values.decode(Bool.self, forKey: .capabilityAvailable),
            truncated: values.decode(Bool.self, forKey: .truncated),
            dataQuality: values.decode(TraceDataQuality.self, forKey: .dataQuality),
            cpuSlices: view == .cpuSlices
                ? values.decode([CpuSlice].self, forKey: .cpuSlices) : [],
            threadStates: view == .threadStates
                ? values.decode([ThreadStateInterval].self, forKey: .threadStates) : [],
            slices: view == .slices
                ? values.decode([TraceSlice].self, forKey: .slices) : [],
            counters: view == .counters
                ? values.decode([TraceAgentCounterEvent].self, forKey: .counters) : []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(view, forKey: .view)
        try values.encode(range, forKey: .range)
        try values.encode(filters, forKey: .filters)
        try values.encode(capabilityAvailable, forKey: .capabilityAvailable)
        try values.encode(truncated, forKey: .truncated)
        try values.encode(dataQuality, forKey: .dataQuality)
        switch view {
        case .cpuSlices: try values.encode(cpuSlices, forKey: .cpuSlices)
        case .threadStates: try values.encode(threadStates, forKey: .threadStates)
        case .slices: try values.encode(slices, forKey: .slices)
        case .counters: try values.encode(counters, forKey: .counters)
        }
    }
}
