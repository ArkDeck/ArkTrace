import ArkTraceCore
import Foundation

public enum TraceContextTimeSelection: Hashable, Codable, Sendable {
    case timestamp(timestampNs: Int64, windowBeforeNs: Int64, windowAfterNs: Int64)
    case range(TraceTimeRange)

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: AnyCodingKey.self)
        let keys = Set(values.allKeys.map(\.stringValue))
        let timestampKeys: Set<String> = [
            "timestampNs", "windowBeforeNs", "windowAfterNs",
        ]
        if keys == timestampKeys {
            self = .timestamp(
                timestampNs: try values.decode(
                    Int64.self, forKey: AnyCodingKey(stringValue: "timestampNs")!
                ),
                windowBeforeNs: try values.decode(
                    Int64.self, forKey: AnyCodingKey(stringValue: "windowBeforeNs")!
                ),
                windowAfterNs: try values.decode(
                    Int64.self, forKey: AnyCodingKey(stringValue: "windowAfterNs")!
                )
            )
        } else if keys == Set(["range"]) {
            self = .range(
                try values.decode(
                    TraceTimeRange.self, forKey: AnyCodingKey(stringValue: "range")!
                )
            )
        } else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Context time must contain exactly one reviewed shape"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: AnyCodingKey.self)
        switch self {
        case .timestamp(let timestampNs, let windowBeforeNs, let windowAfterNs):
            try values.encode(
                timestampNs, forKey: AnyCodingKey(stringValue: "timestampNs")!
            )
            try values.encode(
                windowBeforeNs, forKey: AnyCodingKey(stringValue: "windowBeforeNs")!
            )
            try values.encode(
                windowAfterNs, forKey: AnyCodingKey(stringValue: "windowAfterNs")!
            )
        case .range(let range):
            try values.encode(range, forKey: AnyCodingKey(stringValue: "range")!)
        }
    }
}

public struct TraceContextRequest: Sendable {
    public static let defaultMaximumEvents = 10_000
    public static let defaultMaximumRows = 10_000
    public static let defaultMaximumOutputBytes = 8 * 1_024 * 1_024

    public let time: TraceContextTimeSelection
    public let filters: TraceAgentQueryFilters
    public let maximumEvents: Int
    public let maximumRows: Int
    public let maximumOutputBytes: Int
    public let timeout: Duration

    public init(
        time: TraceContextTimeSelection,
        filters: TraceAgentQueryFilters = .none,
        maximumEvents: Int = defaultMaximumEvents,
        maximumRows: Int = defaultMaximumRows,
        maximumOutputBytes: Int = defaultMaximumOutputBytes,
        timeout: Duration = .seconds(30)
    ) throws {
        switch time {
        case .timestamp(let timestampNs, let beforeNs, let afterNs):
            guard timestampNs >= 0, beforeNs >= 0, afterNs >= 0,
                beforeNs > 0 || afterNs > 0
            else {
                throw ArkTraceError(
                    code: .invalidArgument,
                    stage: .request,
                    message: "Context timestamp and windows are invalid"
                )
            }
        case .range(let range):
            guard range.startNs < range.endNs else {
                throw ArkTraceError(
                    code: .invalidArgument,
                    stage: .request,
                    message: "Context range must be non-empty"
                )
            }
        }
        guard (1...100_000).contains(maximumEvents),
            (1...100_000).contains(maximumRows),
            (1_024...(64 * 1_024 * 1_024)).contains(maximumOutputBytes),
            timeout >= .milliseconds(100), timeout <= .seconds(120)
        else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Context limits are invalid"
            )
        }
        self.time = time
        self.filters = filters
        self.maximumEvents = maximumEvents
        self.maximumRows = maximumRows
        self.maximumOutputBytes = maximumOutputBytes
        self.timeout = timeout
    }
}

public struct TraceContextSectionStatus: Hashable, Codable, Sendable {
    public let returnedCount: Int
    public let matchedCount: Int?
    public let truncated: Bool

    private enum CodingKeys: String, CodingKey {
        case returnedCount, matchedCount, truncated
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(returnedCount, forKey: .returnedCount)
        if let matchedCount { try values.encode(matchedCount, forKey: .matchedCount) }
        else { try values.encodeNil(forKey: .matchedCount) }
        try values.encode(truncated, forKey: .truncated)
    }
}

public struct TraceContextTruncation: Hashable, Codable, Sendable {
    public let processes: TraceContextSectionStatus
    public let threads: TraceContextSectionStatus
    public let cpuSlices: TraceContextSectionStatus
    public let threadStates: TraceContextSectionStatus
    public let slices: TraceContextSectionStatus
    public let counters: TraceContextSectionStatus
    public let summary: TraceContextSectionStatus
    public let referenceOmittedByBudget: Bool

    public var truncated: Bool {
        referenceOmittedByBudget || [
            processes, threads, cpuSlices, threadStates, slices, counters, summary,
        ].contains(where: \.truncated)
    }
}

/// Counts the exact UTF-8 bytes emitted by the repository's canonical
/// `JSONEncoder` settings without materializing the complete document. This
/// keeps every retention decision tied to the actual JSON size while the only
/// full allocation is the final, already-proven-to-fit encoding.
private enum TraceJSONByteCounter {
    enum LimitReached: Error { case maximumBytes }

    private final class Box {
        var count = 0
        let maximumBytes: Int?
        let deadline: ContinuousClock.Instant?
        private var operations = 0

        init(maximumBytes: Int?, deadline: ContinuousClock.Instant?) {
            self.maximumBytes = maximumBytes
            self.deadline = deadline
        }

        func add(_ amount: Int) {
            let (next, overflow) = count.addingReportingOverflow(amount)
            count = overflow ? .max : next
        }

        func check(force: Bool = false) throws {
            operations += 1
            guard force || operations.isMultiple(of: 1_024) else { return }
            try Task.checkCancellation()
            if let deadline, ContinuousClock.now >= deadline {
                throw ArkTraceError(
                    code: .queryTimeout,
                    stage: .analyzing,
                    message: "Trace context deadline was reached",
                    retryable: true
                )
            }
            if let maximumBytes, count > maximumBytes {
                throw LimitReached.maximumBytes
            }
        }
    }

    static func count<T: Encodable>(
        _ value: T,
        maximumBytes: Int? = nil,
        deadline: ContinuousClock.Instant? = nil
    ) throws -> Int {
        let box = Box(maximumBytes: maximumBytes, deadline: deadline)
        try box.check(force: true)
        try value.encode(to: CountingEncoder(box: box, codingPath: []))
        try box.check(force: true)
        return box.count
    }

    private static func stringBytes(_ value: String) -> Int {
        var count = 2
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x22, 0x5C:
                count += 2
            case 0x00...0x1F:
                count += 6
            default:
                count += String(scalar).utf8.count
            }
        }
        return count
    }

    private static func checkedStringBytes(_ value: String, box: Box) throws -> Int {
        var count = 2
        for (index, scalar) in value.unicodeScalars.enumerated() {
            if index.isMultiple(of: 1_024) { try box.check(force: true) }
            switch scalar.value {
            case 0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x22, 0x5C:
                count += 2
            case 0x00...0x1F:
                count += 6
            default:
                count += String(scalar).utf8.count
            }
            if let maximumBytes = box.maximumBytes,
                box.count > maximumBytes - min(maximumBytes, count) {
                throw LimitReached.maximumBytes
            }
        }
        return count
    }

    private static func floatingBytes<T: Encodable>(_ value: T) throws -> Int {
        try JSONEncoder().encode(value).count
    }

    private struct CountingEncoder: Encoder {
        let box: Box
        let codingPath: [CodingKey]
        let userInfo: [CodingUserInfoKey: Any] = [:]

        func container<Key: CodingKey>(
            keyedBy type: Key.Type
        ) -> KeyedEncodingContainer<Key> {
            KeyedEncodingContainer(Keyed<Key>(box: box, codingPath: codingPath))
        }

        func unkeyedContainer() -> UnkeyedEncodingContainer {
            Unkeyed(box: box, codingPath: codingPath)
        }

        func singleValueContainer() -> SingleValueEncodingContainer {
            Single(box: box, codingPath: codingPath)
        }
    }

    private struct Keyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let box: Box
        let codingPath: [CodingKey]
        private var elementCount = 0

        init(box: Box, codingPath: [CodingKey]) {
            self.box = box
            self.codingPath = codingPath
            box.add(2)
        }

        private mutating func begin(_ key: Key) throws {
            try box.check(force: true)
            if elementCount > 0 { box.add(1) }
            elementCount += 1
            box.add(stringBytes(key.stringValue) + 1)
        }

        mutating func encodeNil(forKey key: Key) throws { try begin(key); box.add(4) }
        mutating func encode(_ value: Bool, forKey key: Key) throws {
            try begin(key); box.add(value ? 4 : 5)
        }
        mutating func encode(_ value: String, forKey key: Key) throws {
            try begin(key); box.add(try checkedStringBytes(value, box: box))
        }
        mutating func encode(_ value: Double, forKey key: Key) throws {
            try begin(key); box.add(try floatingBytes(value))
        }
        mutating func encode(_ value: Float, forKey key: Key) throws {
            try begin(key); box.add(try floatingBytes(value))
        }
        mutating func encode(_ value: Int, forKey key: Key) throws {
            try begin(key); box.add(String(value).utf8.count)
        }
        mutating func encode(_ value: Int8, forKey key: Key) throws {
            try begin(key); box.add(String(value).utf8.count)
        }
        mutating func encode(_ value: Int16, forKey key: Key) throws {
            try begin(key); box.add(String(value).utf8.count)
        }
        mutating func encode(_ value: Int32, forKey key: Key) throws {
            try begin(key); box.add(String(value).utf8.count)
        }
        mutating func encode(_ value: Int64, forKey key: Key) throws {
            try begin(key); box.add(String(value).utf8.count)
        }
        mutating func encode(_ value: UInt, forKey key: Key) throws {
            try begin(key); box.add(String(value).utf8.count)
        }
        mutating func encode(_ value: UInt8, forKey key: Key) throws {
            try begin(key); box.add(String(value).utf8.count)
        }
        mutating func encode(_ value: UInt16, forKey key: Key) throws {
            try begin(key); box.add(String(value).utf8.count)
        }
        mutating func encode(_ value: UInt32, forKey key: Key) throws {
            try begin(key); box.add(String(value).utf8.count)
        }
        mutating func encode(_ value: UInt64, forKey key: Key) throws {
            try begin(key); box.add(String(value).utf8.count)
        }
        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
            try begin(key)
            try value.encode(to: CountingEncoder(box: box, codingPath: codingPath + [key]))
        }
        mutating func nestedContainer<NestedKey: CodingKey>(
            keyedBy keyType: NestedKey.Type,
            forKey key: Key
        ) -> KeyedEncodingContainer<NestedKey> {
            if elementCount > 0 { box.add(1) }
            elementCount += 1
            box.add(stringBytes(key.stringValue) + 1)
            return KeyedEncodingContainer(
                Keyed<NestedKey>(box: box, codingPath: codingPath + [key])
            )
        }
        mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
            if elementCount > 0 { box.add(1) }
            elementCount += 1
            box.add(stringBytes(key.stringValue) + 1)
            return Unkeyed(box: box, codingPath: codingPath + [key])
        }
        mutating func superEncoder() -> Encoder {
            CountingEncoder(box: box, codingPath: codingPath)
        }
        mutating func superEncoder(forKey key: Key) -> Encoder {
            if elementCount > 0 { box.add(1) }
            elementCount += 1
            box.add(stringBytes(key.stringValue) + 1)
            return CountingEncoder(box: box, codingPath: codingPath + [key])
        }
    }

    private struct Unkeyed: UnkeyedEncodingContainer {
        let box: Box
        let codingPath: [CodingKey]
        private(set) var count = 0

        init(box: Box, codingPath: [CodingKey]) {
            self.box = box
            self.codingPath = codingPath
            box.add(2)
        }

        private mutating func begin() throws {
            try box.check(force: true)
            if count > 0 { box.add(1) }
            count += 1
        }
        mutating func encodeNil() throws { try begin(); box.add(4) }
        mutating func encode(_ value: Bool) throws { try begin(); box.add(value ? 4 : 5) }
        mutating func encode(_ value: String) throws {
            try begin(); box.add(try checkedStringBytes(value, box: box))
        }
        mutating func encode(_ value: Double) throws {
            try begin(); box.add(try floatingBytes(value))
        }
        mutating func encode(_ value: Float) throws {
            try begin(); box.add(try floatingBytes(value))
        }
        mutating func encode(_ value: Int) throws { try begin(); box.add(String(value).utf8.count) }
        mutating func encode(_ value: Int8) throws { try begin(); box.add(String(value).utf8.count) }
        mutating func encode(_ value: Int16) throws { try begin(); box.add(String(value).utf8.count) }
        mutating func encode(_ value: Int32) throws { try begin(); box.add(String(value).utf8.count) }
        mutating func encode(_ value: Int64) throws { try begin(); box.add(String(value).utf8.count) }
        mutating func encode(_ value: UInt) throws { try begin(); box.add(String(value).utf8.count) }
        mutating func encode(_ value: UInt8) throws { try begin(); box.add(String(value).utf8.count) }
        mutating func encode(_ value: UInt16) throws { try begin(); box.add(String(value).utf8.count) }
        mutating func encode(_ value: UInt32) throws { try begin(); box.add(String(value).utf8.count) }
        mutating func encode(_ value: UInt64) throws { try begin(); box.add(String(value).utf8.count) }
        mutating func encode<T: Encodable>(_ value: T) throws {
            try begin()
            try value.encode(to: CountingEncoder(box: box, codingPath: codingPath))
        }
        mutating func nestedContainer<NestedKey: CodingKey>(
            keyedBy keyType: NestedKey.Type
        ) -> KeyedEncodingContainer<NestedKey> {
            if count > 0 { box.add(1) }
            count += 1
            return KeyedEncodingContainer(Keyed<NestedKey>(box: box, codingPath: codingPath))
        }
        mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
            if count > 0 { box.add(1) }
            count += 1
            return Unkeyed(box: box, codingPath: codingPath)
        }
        mutating func superEncoder() -> Encoder {
            if count > 0 { box.add(1) }
            count += 1
            return CountingEncoder(box: box, codingPath: codingPath)
        }
    }

    private struct Single: SingleValueEncodingContainer {
        let box: Box
        let codingPath: [CodingKey]
        func encodeNil() throws { try box.check(force: true); box.add(4) }
        func encode(_ value: Bool) throws {
            try box.check(force: true); box.add(value ? 4 : 5)
        }
        func encode(_ value: String) throws {
            try box.check(force: true); box.add(try checkedStringBytes(value, box: box))
        }
        func encode(_ value: Double) throws {
            try box.check(force: true); box.add(try floatingBytes(value))
        }
        func encode(_ value: Float) throws {
            try box.check(force: true); box.add(try floatingBytes(value))
        }
        func encode(_ value: Int) throws { try box.check(force: true); box.add(String(value).utf8.count) }
        func encode(_ value: Int8) throws { try box.check(force: true); box.add(String(value).utf8.count) }
        func encode(_ value: Int16) throws { try box.check(force: true); box.add(String(value).utf8.count) }
        func encode(_ value: Int32) throws { try box.check(force: true); box.add(String(value).utf8.count) }
        func encode(_ value: Int64) throws { try box.check(force: true); box.add(String(value).utf8.count) }
        func encode(_ value: UInt) throws { try box.check(force: true); box.add(String(value).utf8.count) }
        func encode(_ value: UInt8) throws { try box.check(force: true); box.add(String(value).utf8.count) }
        func encode(_ value: UInt16) throws { try box.check(force: true); box.add(String(value).utf8.count) }
        func encode(_ value: UInt32) throws { try box.check(force: true); box.add(String(value).utf8.count) }
        func encode(_ value: UInt64) throws { try box.check(force: true); box.add(String(value).utf8.count) }
        func encode<T: Encodable>(_ value: T) throws {
            try box.check(force: true)
            try value.encode(to: CountingEncoder(box: box, codingPath: codingPath))
        }
    }
}

/// Deterministic, bounded context. It intentionally contains no raw table rows,
/// SQL, filesystem path, parser log, or dynamic dictionary section.
public struct TraceContext: Hashable, Codable, Sendable {
    public let range: TraceTimeRange
    public let filters: TraceAgentQueryFilters
    public let processes: [TraceProcess]
    public let threads: [TraceThread]
    public let cpuSlices: [CpuSlice]
    public let threadStates: [ThreadStateInterval]
    public let slices: [TraceSlice]
    public let counters: [CounterSeries]
    public let summary: TraceSummary
    public let dataQuality: TraceDataQuality
    public let truncation: TraceContextTruncation

    public init(
        range: TraceTimeRange,
        filters: TraceAgentQueryFilters = .none,
        processes: [TraceProcess],
        threads: [TraceThread],
        cpuSlices: [CpuSlice],
        threadStates: [ThreadStateInterval],
        slices: [TraceSlice],
        counters: [CounterSeries],
        summary: TraceSummary,
        dataQuality: TraceDataQuality,
        truncation: TraceContextTruncation
    ) {
        self.range = range
        self.filters = filters
        self.processes = processes
        self.threads = threads
        self.cpuSlices = cpuSlices
        self.threadStates = threadStates
        self.slices = slices
        self.counters = counters
        self.summary = summary
        self.dataQuality = dataQuality
        self.truncation = truncation
    }

    /// Exact second-stage byte enforcement (AT-CTX-005). The builder performs
    /// the same check before returning, and callers can recheck after wrapping.
    public func encoded(maximumBytes: Int) throws -> Data {
        let exactByteCount: Int
        do {
            exactByteCount = try TraceJSONByteCounter.count(
                self, maximumBytes: maximumBytes
            )
        } catch TraceJSONByteCounter.LimitReached.maximumBytes {
            throw ArkTraceError(
                code: .outputLimitExceeded,
                stage: .encoding,
                message: "Trace context exceeded its output byte budget",
                retryable: true,
                details: ["maximumBytes": String(maximumBytes)]
            )
        }
        guard exactByteCount <= maximumBytes else {
            throw ArkTraceError(
                code: .outputLimitExceeded,
                stage: .encoding,
                message: "Trace context exceeded its output byte budget",
                retryable: true,
                details: [
                    "maximumBytes": String(maximumBytes),
                    "requiredBytes": String(exactByteCount),
                ]
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count == exactByteCount, data.count <= maximumBytes else {
            throw ArkTraceError(
                code: .outputLimitExceeded,
                stage: .encoding,
                message: "Trace context exceeded its output byte budget",
                retryable: true,
                details: [
                    "maximumBytes": String(maximumBytes),
                    "requiredBytes": String(data.count),
                ]
            )
        }
        return data
    }
}

public struct TraceContextBuilder: Sendable {
    private enum CandidateKind: Int, Sendable {
        case cpuSlice
        case threadState
        case slice
        case counter
    }

    private struct Candidate: Sendable {
        let kind: CandidateKind
        let key: EventKey
        let startNs: Int64
        let durationNs: Int64
        let explicitlyMatched: Bool
        let centerDistanceNs: Int64?
        let processKey: ProcessKey?
        let threadKey: ThreadKey?
    }

    private enum DirectoryEntity: Hashable, Sendable {
        case process(ProcessKey)
        case thread(ThreadKey)
    }

    private struct CounterSeriesIdentity: Hashable {
        let filterID: Int64
        let name: String
        let scope: CounterScope
        let cpu: Int64?
        let processKey: ProcessKey?
        let pid: Int64?
        let processName: String?
        let unit: String?
    }

    private struct Loaded {
        let metadata: TraceMetadata
        let range: TraceTimeRange
        let filters: TraceAgentQueryFilters
        let center: Int64?
        let processPage: BoundedPage<TraceProcess>
        let threadPage: BoundedPage<TraceThread>
        let cpu: TraceAgentQueryResult
        let states: TraceAgentQueryResult
        let slices: TraceAgentQueryResult
        let counters: TraceAgentQueryResult
        let summary: TraceSummary
        var processByKey: [ProcessKey: TraceProcess]
        var threadByKey: [ThreadKey: TraceThread]
        var budgetOmittedReferences: Set<DirectoryEntity>
        var missingReferenceCount: Int
        let candidates: [Candidate]
    }

    private struct Assembly {
        let context: TraceContext
        let requiredDirectoryCount: Int

        var contextEventCount: Int {
            context.cpuSlices.count + context.threadStates.count + context.slices.count
                + context.counters.reduce(0) { $0 + $1.samples.count }
        }
    }

    private let repository: any TraceRepositoryProtocol
    private let byteCountHook: (@Sendable () -> Void)?

    public init(repository: any TraceRepositoryProtocol) {
        self.repository = repository
        byteCountHook = nil
    }

    init(
        repository: any TraceRepositoryProtocol,
        byteCountHook: @escaping @Sendable () -> Void
    ) {
        self.repository = repository
        self.byteCountHook = byteCountHook
    }

    public func build(_ request: TraceContextRequest) async throws -> TraceContext {
        do {
            return try await TraceAnalysisOperationDeadline.run(
                timeout: request.timeout,
                stage: .analyzing,
                timeoutMessage: "Trace context deadline was reached"
            ) { deadline in
                try await build(request, deadline: deadline)
            }
        } catch {
            if (error as? ArkTraceError)?.code == .outputLimitExceeded { throw error }
            if Task.isCancelled || error is CancellationError {
                throw ArkTraceError(
                    code: .cancelled,
                    stage: .analyzing,
                    message: "Trace context construction was cancelled",
                    retryable: true
                )
            }
            throw error
        }
    }

    private func build(
        _ request: TraceContextRequest,
        deadline: ContinuousClock.Instant
    ) async throws -> TraceContext {
            var loaded = try await load(request, deadline: deadline)
            try await loadReferencedDirectories(
                &loaded,
                maximumReferences: request.maximumRows,
                deadline: deadline
            )
            try Self.check(deadline)

            let fullCount = min(request.maximumEvents, loaded.candidates.count)
            let full = try assemble(
                loaded,
                eventCount: fullCount,
                directoryLimit: request.maximumRows,
                includeExtraDirectories: true,
                deadline: deadline
            )
            if try fits(
                full.context,
                maximumBytes: request.maximumOutputBytes,
                deadline: deadline
            ) {
                try Self.check(deadline)
                return try Self.exactlyValidated(
                    full.context,
                    maximumBytes: request.maximumOutputBytes,
                    deadline: deadline
                )
            }

            // Drop unrelated directory rows before removing retained events and
            // their referential closure.
            let closureOnly = try assemble(
                loaded,
                eventCount: fullCount,
                directoryLimit: request.maximumRows,
                includeExtraDirectories: false,
                deadline: deadline
            )
            if try fits(
                closureOnly.context,
                maximumBytes: request.maximumOutputBytes,
                deadline: deadline
            ) {
                return try maximizeDirectories(
                    loaded,
                    eventCount: fullCount,
                    lowerBound: closureOnly.requiredDirectoryCount,
                    request: request,
                    deadline: deadline
                )
            }

            var lower = 0
            var upper = max(0, fullCount - 1)
            var best: Assembly?
            while lower <= upper {
                try Self.check(deadline)
                let middle = lower + (upper - lower) / 2
                let value = try assemble(
                    loaded,
                    eventCount: middle,
                    directoryLimit: request.maximumRows,
                    includeExtraDirectories: false,
                    deadline: deadline
                )
                if try fits(
                    value.context,
                    maximumBytes: request.maximumOutputBytes,
                    deadline: deadline
                ) {
                    best = value
                    lower = middle + 1
                } else {
                    upper = middle - 1
                }
            }
            guard let best else {
                let minimum = try assemble(
                    loaded,
                    eventCount: 0,
                    directoryLimit: 0,
                    includeExtraDirectories: false,
                    deadline: deadline
                ).context
                try Self.check(deadline)
                let minimumByteCount = try TraceJSONByteCounter.count(
                    minimum, deadline: deadline
                )
                if minimumByteCount <= request.maximumOutputBytes {
                    return try Self.exactlyValidated(
                        minimum,
                        maximumBytes: request.maximumOutputBytes,
                        deadline: deadline
                    )
                }
                throw ArkTraceError(
                    code: .outputLimitExceeded,
                    stage: .encoding,
                    message: "The minimum Trace context exceeds its output byte budget",
                    retryable: true,
                    details: [
                        "maximumBytes": String(request.maximumOutputBytes),
                        "requiredBytes": String(minimumByteCount),
                    ]
                )
            }
            return try maximizeDirectories(
                loaded,
                eventCount: best.contextEventCount,
                lowerBound: best.requiredDirectoryCount,
                request: request,
                deadline: deadline
            )
    }

    private func load(
        _ request: TraceContextRequest,
        deadline: ContinuousClock.Instant
    ) async throws -> Loaded {
        try Self.check(deadline)
        let metadata = try await repository.metadata()
        let normalized = try Self.normalized(request.time, durationNs: metadata.durationNs)
        let queryEngine = TraceAgentQueryEngine(repository: repository)
        let eventLimit = request.maximumEvents

        let cpuFilters = try TraceAgentQueryFilters(
            cpu: request.filters.cpu,
            processKey: request.filters.processKey,
            pid: request.filters.pid,
            threadKey: request.filters.threadKey,
            tid: request.filters.tid
        )
        let stateFilters = try TraceAgentQueryFilters(
            cpu: request.filters.cpu,
            processKey: request.filters.processKey,
            pid: request.filters.pid,
            threadKey: request.filters.threadKey,
            tid: request.filters.tid,
            rawState: request.filters.rawState,
            normalizedState: request.filters.normalizedState
        )
        let sliceFilters = try TraceAgentQueryFilters(
            processKey: request.filters.processKey,
            pid: request.filters.pid,
            threadKey: request.filters.threadKey,
            tid: request.filters.tid,
            name: request.filters.name,
            nameMatch: request.filters.nameMatch,
            minimumDurationNs: request.filters.minimumDurationNs,
            depth: request.filters.depth
        )
        let counterScopeConflict = request.filters.cpu != nil
            && (request.filters.processKey != nil || request.filters.pid != nil)
        let counterFilters = try TraceAgentQueryFilters(
            cpu: counterScopeConflict ? nil : request.filters.cpu,
            processKey: counterScopeConflict ? nil : request.filters.processKey,
            pid: counterScopeConflict ? nil : request.filters.pid,
            counterFilterID: request.filters.counterFilterID
        )
        func remaining() throws -> Duration {
            try Self.check(deadline)
            return ContinuousClock.now.duration(to: deadline)
        }
        var batchEntries = [
            TraceAgentQueryEngine.BatchEntry(
                view: .cpuSlices, filters: cpuFilters, limit: eventLimit
            ),
            TraceAgentQueryEngine.BatchEntry(
                view: .threadStates, filters: stateFilters, limit: eventLimit
            ),
            TraceAgentQueryEngine.BatchEntry(
                view: .slices, filters: sliceFilters, limit: eventLimit
            ),
        ]
        if !counterScopeConflict {
            batchEntries.append(
                TraceAgentQueryEngine.BatchEntry(
                    view: .counters, filters: counterFilters, limit: eventLimit
                )
            )
        }
        async let eventResults = queryEngine.queryBatch(
            range: normalized.range, entries: batchEntries, deadline: deadline
        )
        async let processResult = repository.processes(
            ProcessQuery(
                processKey: request.filters.processKey,
                pid: request.filters.pid,
                limit: request.maximumRows,
                deadline: deadline
            )
        )
        async let threadResult = repository.threads(
            ThreadQuery(
                processKey: request.filters.processKey,
                pid: request.filters.pid,
                threadKey: request.filters.threadKey,
                tid: request.filters.tid,
                limit: request.maximumRows,
                deadline: deadline
            )
        )
        async let summaryResult = TraceSummaryEngine(repository: repository).summarize(
            try TraceSummaryRequest(
                range: normalized.range,
                maximumRowsPerSection: request.maximumRows,
                maximumEventsPerSection: request.maximumEvents,
                timeout: remaining()
            )
        )
        let (events, processPage, threadPage, summary) = try await (
            eventResults, processResult, threadResult, summaryResult
        )
        let cpu = events[0]
        let states = events[1]
        let slices = events[2]
        let counters: TraceAgentQueryResult
        if counterScopeConflict {
            counters = try TraceAgentQueryResult(
                view: .counters,
                range: normalized.range,
                capabilityAvailable: metadata.capabilities.cpuCounters
                    || metadata.capabilities.processCounters,
                truncated: false,
                dataQuality: metadata.dataQuality,
                counters: []
            )
        } else {
            counters = events[3]
        }
        let processByKey = try Self.uniqueDirectoryMap(
            processPage.items, key: \.key, entityName: "process", deadline: deadline
        )
        let threadByKey = try Self.uniqueDirectoryMap(
            threadPage.items, key: \.key, entityName: "thread", deadline: deadline
        )
        var loaded = Loaded(
            metadata: metadata,
            range: normalized.range,
            filters: request.filters,
            center: normalized.center,
            processPage: processPage,
            threadPage: threadPage,
            cpu: cpu,
            states: states,
            slices: slices,
            counters: counters,
            summary: summary,
            processByKey: processByKey,
            threadByKey: threadByKey,
            budgetOmittedReferences: [],
            missingReferenceCount: 0,
            candidates: []
        )
        loaded = Loaded(
            metadata: loaded.metadata, range: loaded.range, filters: loaded.filters,
            center: loaded.center,
            processPage: loaded.processPage, threadPage: loaded.threadPage,
            cpu: loaded.cpu, states: loaded.states, slices: loaded.slices,
            counters: loaded.counters, summary: loaded.summary,
            processByKey: loaded.processByKey, threadByKey: loaded.threadByKey,
            budgetOmittedReferences: loaded.budgetOmittedReferences,
            missingReferenceCount: loaded.missingReferenceCount,
            candidates: try Self.candidates(
                loaded, filters: request.filters, deadline: deadline
            )
        )
        return loaded
    }

    private static func uniqueDirectoryMap<Key: Hashable, Value>(
        _ values: [Value],
        key: KeyPath<Value, Key>,
        entityName: String,
        deadline: ContinuousClock.Instant
    ) throws -> [Key: Value] {
        var result: [Key: Value] = [:]
        result.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 1_024) { try check(deadline) }
            let identity = value[keyPath: key]
            guard result.updateValue(value, forKey: identity) == nil else {
                throw ArkTraceError(
                    code: .queryFailed,
                    stage: .querying,
                    message: "Directory query returned a duplicate \(entityName) identity"
                )
            }
        }
        try check(deadline)
        return result
    }

    private func loadReferencedDirectories(
        _ loaded: inout Loaded,
        maximumReferences: Int,
        deadline: ContinuousClock.Instant
    ) async throws {
        // Preserve candidate retention order across entity kinds. A lower
        // priority thread must not consume the last probe before a retained,
        // higher priority process-only counter gets its process closure.
        var ordered: [DirectoryEntity] = []
        var scheduled: Set<DirectoryEntity> = []
        for (index, candidate) in loaded.candidates.enumerated() {
            if index.isMultiple(of: 1_024) { try Self.check(deadline) }
            if let key = candidate.processKey {
                let value = DirectoryEntity.process(key)
                if scheduled.insert(value).inserted { ordered.append(value) }
            }
            if let key = candidate.threadKey {
                let value = DirectoryEntity.thread(key)
                if scheduled.insert(value).inserted { ordered.append(value) }
            }
        }
        var processByKey = loaded.processByKey
        var threadByKey = loaded.threadByKey
        var budgetOmitted = loaded.budgetOmittedReferences
        var missingCount = loaded.missingReferenceCount
        var probes = 0
        var index = 0
        while index < ordered.count {
            try Self.check(deadline)
            let entity = ordered[index]
            index += 1
            switch entity {
            case .process(let key) where processByKey[key] != nil:
                continue
            case .thread(let key) where threadByKey[key] != nil:
                if let processKey = threadByKey[key]?.processKey {
                    let process = DirectoryEntity.process(processKey)
                    if scheduled.insert(process).inserted {
                        ordered.insert(process, at: index)
                    }
                }
                continue
            default:
                break
            }
            guard probes < maximumReferences else {
                budgetOmitted.insert(entity)
                continue
            }
            probes += 1
            switch entity {
            case .process(let key):
                let page = try await repository.processes(
                    ProcessQuery(processKey: key, limit: 1, deadline: deadline)
                )
                if let value = page.items.first {
                    processByKey[key] = value
                } else {
                    missingCount += 1
                }
            case .thread(let key):
                let page = try await repository.threads(
                    ThreadQuery(threadKey: key, limit: 1, deadline: deadline)
                )
                if let value = page.items.first {
                    threadByKey[key] = value
                    if let processKey = value.processKey {
                        let process = DirectoryEntity.process(processKey)
                        if scheduled.insert(process).inserted {
                            ordered.insert(process, at: index)
                        }
                    }
                } else {
                    missingCount += 1
                }
            }
        }
        loaded = Loaded(
            metadata: loaded.metadata, range: loaded.range, filters: loaded.filters,
            center: loaded.center,
            processPage: loaded.processPage, threadPage: loaded.threadPage,
            cpu: loaded.cpu, states: loaded.states, slices: loaded.slices,
            counters: loaded.counters, summary: loaded.summary,
            processByKey: processByKey, threadByKey: threadByKey,
            budgetOmittedReferences: budgetOmitted,
            missingReferenceCount: missingCount,
            candidates: loaded.candidates
        )
    }

    private func maximizeDirectories(
        _ loaded: Loaded,
        eventCount: Int,
        lowerBound: Int,
        request: TraceContextRequest,
        deadline: ContinuousClock.Instant
    ) throws -> TraceContext {
        var lower = min(lowerBound, request.maximumRows)
        var upper = request.maximumRows
        var best = try assemble(
            loaded,
            eventCount: eventCount,
            directoryLimit: lower,
            includeExtraDirectories: true,
            deadline: deadline
        ).context
        guard try fits(
            best,
            maximumBytes: request.maximumOutputBytes,
            deadline: deadline
        ) else {
            throw ArkTraceError(
                code: .internalError,
                stage: .encoding,
                message: "Context directory retention lower bound did not fit"
            )
        }
        while lower <= upper {
            try Self.check(deadline)
            let middle = lower + (upper - lower) / 2
            let value = try assemble(
                loaded,
                eventCount: eventCount,
                directoryLimit: middle,
                includeExtraDirectories: true,
                deadline: deadline
            ).context
            if try fits(
                value,
                maximumBytes: request.maximumOutputBytes,
                deadline: deadline
            ) {
                best = value
                lower = middle + 1
            } else {
                upper = middle - 1
            }
        }
        try Self.check(deadline)
        return try Self.exactlyValidated(
            best, maximumBytes: request.maximumOutputBytes, deadline: deadline
        )
    }

    private func assemble(
        _ loaded: Loaded,
        eventCount: Int,
        directoryLimit: Int,
        includeExtraDirectories: Bool,
        deadline: ContinuousClock.Instant
    ) throws -> Assembly {
        try Self.check(deadline)
        let retained = Array(loaded.candidates.prefix(eventCount))
        let retainedKeys = Set(retained.map(\.key))
        let cpu = loaded.cpu.cpuSlices.filter { retainedKeys.contains($0.key) }
        let states = loaded.states.threadStates.filter { retainedKeys.contains($0.key) }
        let slices = loaded.slices.slices.filter { retainedKeys.contains($0.key) }
        var counterSamples: [CounterSeriesIdentity: [CounterSample]] = [:]
        for (index, event) in loaded.counters.counters.enumerated()
            where retainedKeys.contains(event.sample.key) {
            if index.isMultiple(of: 1_024) { try Self.check(deadline) }
            let identity = CounterSeriesIdentity(
                filterID: event.filterID, name: event.name, scope: event.scope,
                cpu: event.cpu, processKey: event.processKey, pid: event.pid,
                processName: event.processName, unit: event.unit
            )
            counterSamples[identity, default: []].append(event.sample)
        }
        try Self.check(deadline)
        let counterIdentities = counterSamples.keys.sorted(by: Self.counterIdentityPrecedes)
        try Self.check(deadline)
        var counters: [CounterSeries] = []
        counters.reserveCapacity(counterIdentities.count)
        for (index, identity) in counterIdentities.enumerated() {
            if index.isMultiple(of: 1_024) { try Self.check(deadline) }
            counters.append(CounterSeries(
                filterID: identity.filterID, name: identity.name, scope: identity.scope,
                cpu: identity.cpu, processKey: identity.processKey, pid: identity.pid,
                processName: identity.processName, unit: identity.unit,
                samples: counterSamples[identity]!.sorted(by: Self.counterSamplePrecedes)
            ))
        }

        var required: [DirectoryEntity] = []
        var seen: Set<DirectoryEntity> = []
        for (index, candidate) in retained.enumerated() {
            if index.isMultiple(of: 1_024) { try Self.check(deadline) }
            if let process = candidate.processKey {
                let value = DirectoryEntity.process(process)
                if seen.insert(value).inserted { required.append(value) }
            }
            if let thread = candidate.threadKey {
                let value = DirectoryEntity.thread(thread)
                if seen.insert(value).inserted { required.append(value) }
                if let process = loaded.threadByKey[thread]?.processKey {
                    let processValue = DirectoryEntity.process(process)
                    if seen.insert(processValue).inserted { required.append(processValue) }
                }
            }
        }
        let availableRequired = required.filter { value in
            switch value {
            case .process(let key): loaded.processByKey[key] != nil
            case .thread(let key): loaded.threadByKey[key] != nil
            }
        }
        var selected = Array(availableRequired.prefix(directoryLimit))
        if includeExtraDirectories, selected.count < directoryLimit {
            let extras: [DirectoryEntity] = loaded.processPage.items
                .sorted(by: Self.processPrecedes)
                .map { .process($0.key) }
                + loaded.threadPage.items
                    .sorted(by: Self.threadPrecedes)
                    .map { .thread($0.key) }
            for value in extras where selected.count < directoryLimit {
                if seen.insert(value).inserted { selected.append(value) }
            }
        }
        let selectedSet = Set(selected)
        let processes = selected.compactMap { value -> TraceProcess? in
            guard case .process(let key) = value else { return nil }
            return loaded.processByKey[key]
        }.sorted(by: Self.processPrecedes)
        let threads = selected.compactMap { value -> TraceThread? in
            guard case .thread(let key) = value else { return nil }
            return loaded.threadByKey[key]
        }.sorted(by: Self.threadPrecedes)
        let omittedReference = required.contains { value in
            guard !selectedSet.contains(value) else { return false }
            if loaded.budgetOmittedReferences.contains(value) { return true }
            switch value {
            case .process(let key): return loaded.processByKey[key] != nil
            case .thread(let key): return loaded.threadByKey[key] != nil
            }
        }

        let retainedCPU = cpu.count
        let retainedStates = states.count
        let retainedSlices = slices.count
        let retainedCounters = counters.reduce(0) { $0 + $1.samples.count }
        let sourceCounters = loaded.counters.counters.count
        var qualityInputs = [
            loaded.summary.dataQuality,
            loaded.cpu.dataQuality,
            loaded.states.dataQuality,
            loaded.slices.dataQuality,
            loaded.counters.dataQuality,
            TraceDataQuality(issues: loaded.processPage.dataQualityIssues),
            TraceDataQuality(issues: loaded.threadPage.dataQualityIssues)
        ]
        if loaded.missingReferenceCount > 0 {
            qualityInputs.append(
                TraceDataQuality(issues: [
                    TraceDataQualityIssue(
                        category: .referentialIntegrity,
                        scope: nil,
                        count: Int64(loaded.missingReferenceCount),
                        message: "Referenced directory identity is unavailable"
                    )
                ])
            )
        }
        if !loaded.budgetOmittedReferences.isEmpty {
            qualityInputs.append(
                TraceDataQuality(issues: [
                    TraceDataQualityIssue(
                        category: .probeTruncated,
                        scope: nil,
                        count: nil,
                        message: "Directory reference probing reached its row budget"
                    )
                ])
            )
        }
        let quality = Self.quality(qualityInputs)
        let truncation = TraceContextTruncation(
            processes: .init(
                returnedCount: processes.count,
                matchedCount: loaded.processPage.truncated ? nil : loaded.processPage.items.count,
                truncated: loaded.processPage.truncated
                    || processes.count < loaded.processPage.items.count
            ),
            threads: .init(
                returnedCount: threads.count,
                matchedCount: loaded.threadPage.truncated ? nil : loaded.threadPage.items.count,
                truncated: loaded.threadPage.truncated
                    || threads.count < loaded.threadPage.items.count
            ),
            cpuSlices: .init(
                returnedCount: retainedCPU,
                matchedCount: loaded.cpu.truncated ? nil : loaded.cpu.cpuSlices.count,
                truncated: loaded.cpu.truncated || retainedCPU < loaded.cpu.cpuSlices.count
            ),
            threadStates: .init(
                returnedCount: retainedStates,
                matchedCount: loaded.states.truncated ? nil : loaded.states.threadStates.count,
                truncated: loaded.states.truncated
                    || retainedStates < loaded.states.threadStates.count
            ),
            slices: .init(
                returnedCount: retainedSlices,
                matchedCount: loaded.slices.truncated ? nil : loaded.slices.slices.count,
                truncated: loaded.slices.truncated || retainedSlices < loaded.slices.slices.count
            ),
            counters: .init(
                returnedCount: retainedCounters,
                matchedCount: loaded.counters.truncated ? nil : sourceCounters,
                truncated: loaded.counters.truncated || retainedCounters < sourceCounters
            ),
            summary: .init(
                returnedCount: 1,
                matchedCount: 1,
                truncated: !loaded.summary.truncatedSections.isEmpty
            ),
            referenceOmittedByBudget: omittedReference
        )
        try Self.check(deadline)
        return Assembly(
            context: TraceContext(
                range: loaded.range, filters: loaded.filters,
                processes: processes, threads: threads,
                cpuSlices: cpu, threadStates: states, slices: slices,
                counters: counters, summary: loaded.summary,
                dataQuality: quality, truncation: truncation
            ),
            requiredDirectoryCount: availableRequired.count
        )
    }

    private static func candidates(
        _ loaded: Loaded,
        filters: TraceAgentQueryFilters,
        deadline: ContinuousClock.Instant
    ) throws -> [Candidate] {
        let cpuExplicit = filters.cpu != nil || filters.processKey != nil
            || filters.pid != nil || filters.threadKey != nil || filters.tid != nil
        let stateExplicit = cpuExplicit || filters.rawState != nil
            || filters.normalizedState != nil
        let sliceExplicit = filters.processKey != nil || filters.pid != nil
            || filters.threadKey != nil || filters.tid != nil || filters.name != nil
            || filters.minimumDurationNs != nil || filters.depth != nil
        let counterExplicit = filters.counterFilterID != nil || filters.cpu != nil
            || filters.processKey != nil || filters.pid != nil
        func distance(start: Int64, duration: Int64) -> Int64? {
            guard let center = loaded.center else { return nil }
            let (midpointValue, overflow) = start.addingReportingOverflow(duration / 2)
            let midpoint = overflow ? Int64.max : midpointValue
            return midpoint >= center ? midpoint - center : center - midpoint
        }
        var values: [Candidate] = []
        values.reserveCapacity(
            loaded.cpu.cpuSlices.count + loaded.states.threadStates.count
                + loaded.slices.slices.count + loaded.counters.counters.count
        )
        for (index, value) in loaded.cpu.cpuSlices.enumerated() {
            if index.isMultiple(of: 1_024) { try check(deadline) }
            values.append(Candidate(
                kind: .cpuSlice, key: value.key, startNs: value.startNs,
                durationNs: value.range.durationNs,
                explicitlyMatched: cpuExplicit,
                centerDistanceNs: distance(
                    start: value.startNs, duration: value.range.durationNs
                ),
                processKey: value.processKey, threadKey: value.threadKey
            ))
        }
        for (index, value) in loaded.states.threadStates.enumerated() {
            if index.isMultiple(of: 1_024) { try check(deadline) }
            values.append(Candidate(
                kind: .threadState, key: value.key, startNs: value.startNs,
                durationNs: value.range.durationNs,
                explicitlyMatched: stateExplicit,
                centerDistanceNs: distance(
                    start: value.startNs, duration: value.range.durationNs
                ),
                processKey: value.processKey, threadKey: value.threadKey
            ))
        }
        for (index, value) in loaded.slices.slices.enumerated() {
            if index.isMultiple(of: 1_024) { try check(deadline) }
            values.append(Candidate(
                kind: .slice, key: value.key, startNs: value.startNs,
                durationNs: value.range.durationNs,
                explicitlyMatched: sliceExplicit,
                centerDistanceNs: distance(
                    start: value.startNs, duration: value.range.durationNs
                ),
                processKey: value.processKey, threadKey: value.threadKey
            ))
        }
        for (index, event) in loaded.counters.counters.enumerated() {
            if index.isMultiple(of: 1_024) { try check(deadline) }
            let sample = event.sample
            let overlapStart = max(sample.timestampNs, loaded.range.startNs)
            let available = max(0, loaded.range.endNs - overlapStart)
            let effectiveDuration: Int64
            if let duration = sample.durationNs, duration >= 0 {
                let (rawEnd, overflow) = sample.timestampNs.addingReportingOverflow(duration)
                let end = min(loaded.range.endNs, overflow ? .max : rawEnd)
                effectiveDuration = max(0, end - overlapStart)
            } else {
                effectiveDuration = available
            }
            values.append(
                Candidate(
                    kind: .counter, key: sample.key, startNs: sample.timestampNs,
                    durationNs: effectiveDuration,
                    explicitlyMatched: counterExplicit,
                    centerDistanceNs: distance(
                        start: overlapStart, duration: effectiveDuration
                    ),
                    processKey: event.processKey, threadKey: nil
                )
            )
        }
        try check(deadline)
        let sorted = values.sorted {
            if $0.explicitlyMatched != $1.explicitlyMatched {
                return $0.explicitlyMatched && !$1.explicitlyMatched
            }
            if let lhsDistance = $0.centerDistanceNs,
                let rhsDistance = $1.centerDistanceNs,
                lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }
            if loaded.center == nil, $0.startNs != $1.startNs {
                return $0.startNs < $1.startNs
            }
            if $0.durationNs != $1.durationNs { return $0.durationNs > $1.durationNs }
            if $0.key.table.rawValue != $1.key.table.rawValue {
                return $0.key.table.rawValue < $1.key.table.rawValue
            }
            return $0.key.rowID < $1.key.rowID
        }
        try check(deadline)
        return sorted
    }

    private static func processPrecedes(_ lhs: TraceProcess, _ rhs: TraceProcess) -> Bool {
        if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
        return lhs.key.ipid < rhs.key.ipid
    }

    private static func threadPrecedes(_ lhs: TraceThread, _ rhs: TraceThread) -> Bool {
        if lhs.pid != rhs.pid { return optionalIntPrecedes(lhs.pid, rhs.pid) }
        if lhs.tid != rhs.tid { return lhs.tid < rhs.tid }
        return lhs.key.itid < rhs.key.itid
    }

    private static func optionalIntPrecedes(_ lhs: Int64?, _ rhs: Int64?) -> Bool {
        switch (lhs, rhs) {
        case (nil, .some): true
        case (.some, nil): false
        case (.some(let lhs), .some(let rhs)): lhs < rhs
        case (nil, nil): false
        }
    }

    private static func counterIdentityPrecedes(
        _ lhs: CounterSeriesIdentity,
        _ rhs: CounterSeriesIdentity
    ) -> Bool {
        if lhs.scope.rawValue != rhs.scope.rawValue {
            return lhs.scope.rawValue < rhs.scope.rawValue
        }
        if lhs.filterID != rhs.filterID { return lhs.filterID < rhs.filterID }
        if lhs.cpu != rhs.cpu { return optionalIntPrecedes(lhs.cpu, rhs.cpu) }
        if lhs.processKey?.ipid != rhs.processKey?.ipid {
            return optionalIntPrecedes(lhs.processKey?.ipid, rhs.processKey?.ipid)
        }
        if lhs.pid != rhs.pid { return optionalIntPrecedes(lhs.pid, rhs.pid) }
        if lhs.name != rhs.name {
            return lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8)
        }
        if lhs.processName != rhs.processName {
            return optionalStringPrecedes(lhs.processName, rhs.processName)
        }
        if lhs.unit != rhs.unit {
            return optionalStringPrecedes(lhs.unit, rhs.unit)
        }
        return false
    }

    private static func optionalStringPrecedes(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, .some): return true
        case (.some, nil): return false
        case (.some(let lhs), .some(let rhs)):
            return lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
        case (nil, nil): return false
        }
    }

    private static func counterSamplePrecedes(
        _ lhs: CounterSample,
        _ rhs: CounterSample
    ) -> Bool {
        if lhs.timestampNs != rhs.timestampNs { return lhs.timestampNs < rhs.timestampNs }
        if lhs.key.table.rawValue != rhs.key.table.rawValue {
            return lhs.key.table.rawValue < rhs.key.table.rawValue
        }
        return lhs.key.rowID < rhs.key.rowID
    }

    private static func normalized(
        _ selection: TraceContextTimeSelection,
        durationNs: Int64
    ) throws -> (range: TraceTimeRange, center: Int64?) {
        switch selection {
        case .range(let range):
            guard range.endNs <= durationNs else {
                throw ArkTraceError(
                    code: .invalidArgument,
                    stage: .request,
                    message: "Context range exceeds trace duration"
                )
            }
            return (range, nil)
        case .timestamp(let timestamp, let before, let after):
            guard timestamp <= durationNs else {
                throw ArkTraceError(
                    code: .invalidArgument,
                    stage: .request,
                    message: "Context timestamp exceeds trace duration"
                )
            }
            let start = timestamp >= before ? timestamp - before : 0
            let (candidateEnd, overflow) = timestamp.addingReportingOverflow(after)
            let end = min(durationNs, overflow ? .max : candidateEnd)
            guard start < end else {
                throw ArkTraceError(
                    code: .invalidArgument,
                    stage: .request,
                    message: "Normalized context window is empty"
                )
            }
            return (try TraceTimeRange.query(startNs: start, endNs: end), timestamp)
        }
    }

    private static func quality(_ values: [TraceDataQuality]) -> TraceDataQuality {
        let issues = Array(Set(values.flatMap(\.issues))).sorted {
            let lhs = ($0.category.rawValue, $0.scope ?? "", $0.count ?? .min, $0.message ?? "")
            let rhs = ($1.category.rawValue, $1.scope ?? "", $1.count ?? .min, $1.message ?? "")
            return lhs < rhs
        }
        return TraceDataQuality(issues: issues)
    }

    private static func encodedData(_ value: TraceContext) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw ArkTraceError(
                code: .internalError,
                stage: .encoding,
                message: "Trace context encoding failed"
            )
        }
    }

    private func fits(
        _ value: TraceContext,
        maximumBytes: Int,
        deadline: ContinuousClock.Instant
    ) throws -> Bool {
        byteCountHook?()
        do {
            return try TraceJSONByteCounter.count(
                value, maximumBytes: maximumBytes, deadline: deadline
            ) <= maximumBytes
        } catch TraceJSONByteCounter.LimitReached.maximumBytes {
            return false
        }
    }

    private static func exactlyValidated(
        _ value: TraceContext,
        maximumBytes: Int,
        deadline: ContinuousClock.Instant
    ) throws -> TraceContext {
        try check(deadline)
        let exactByteCount = try TraceJSONByteCounter.count(value, deadline: deadline)
        guard exactByteCount <= maximumBytes else {
            throw ArkTraceError(
                code: .outputLimitExceeded,
                stage: .encoding,
                message: "Trace context exceeded its output byte budget",
                retryable: true,
                details: [
                    "maximumBytes": String(maximumBytes),
                    "requiredBytes": String(exactByteCount),
                ]
            )
        }
        let data = try encodedData(value)
        try check(deadline)
        guard data.count == exactByteCount, data.count <= maximumBytes else {
            throw ArkTraceError(
                code: .outputLimitExceeded,
                stage: .encoding,
                message: "Trace context exceeded its output byte budget",
                retryable: true,
                details: [
                    "maximumBytes": String(maximumBytes),
                    "requiredBytes": String(data.count),
                ]
            )
        }
        return value
    }

    private static func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
            throw ArkTraceError(
                code: .queryTimeout,
                stage: .analyzing,
                message: "Trace context deadline was reached",
                retryable: true
            )
        }
    }
}
