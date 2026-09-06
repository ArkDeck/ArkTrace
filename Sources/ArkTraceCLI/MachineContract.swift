import ArkTraceAnalysis
import ArkTraceCore
import ArkTraceRuntime
import Foundation

package struct CLIMachineSchemaVersion: Hashable, Codable, Sendable {
    package static let current = CLIMachineSchemaVersion(validatedMajor: 1, minor: 0)

    package let major: Int
    package let minor: Int

    package init(major: Int, minor: Int) throws {
        guard major >= 0, major <= 999, minor >= 0, minor <= 999 else {
            throw CLIParsing.invalid("Machine schema version is invalid")
        }
        self.init(validatedMajor: major, minor: minor)
    }

    package init(_ value: String) throws {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
            let major = Int(parts[0]), let minor = Int(parts[1]),
            String(major) == parts[0], String(minor) == parts[1]
        else {
            throw CLIParsing.invalid("Machine schema version is invalid")
        }
        try self.init(major: major, minor: minor)
    }

    private init(validatedMajor major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// Minor releases are additive; only a different major is incompatible.
    package func isCompatible(with supported: CLIMachineSchemaVersion) -> Bool {
        major == supported.major
    }

    package var stringValue: String { "\(major).\(minor)" }

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ArkTrace machine schema version"
            )
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}

package indirect enum CLIJSONValue: Hashable, Codable, Sendable {
    case null
    case bool(Bool)
    case int64(Int64)
    case double(Double)
    case string(String)
    case array([CLIJSONValue])
    case object([String: CLIJSONValue])

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .int64(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([CLIJSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: CLIJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int64(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

package struct CLIMachineTool: Hashable, Codable, Sendable {
    package let name: String
    package let version: String
    package let buildRevision: String

    package init(name: String, version: String, buildRevision: String) throws {
        guard name == ArkTraceCLITool.name,
            version == ArkTraceCLITool.version,
            CLIMachineParserIdentity.isSHA256(buildRevision)
        else {
            throw ArkTraceError(
                code: .internalError,
                stage: .encoding,
                message: "Machine tool identity is invalid",
                details: ["reason": "invalidToolIdentity"]
            )
        }
        self.name = name
        self.version = version
        self.buildRevision = buildRevision
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            name: container.decode(String.self, forKey: .name),
            version: container.decode(String.self, forKey: .version),
            buildRevision: container.decode(String.self, forKey: .buildRevision)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case version
        case buildRevision
    }
}

package struct CLIMachineParserIdentity: Hashable, Codable, Sendable {
    package let name: String
    package let version: String
    package let upstreamRevision: String
    package let binarySHA256: String

    private enum CodingKeys: String, CodingKey {
        case name
        case version
        case upstreamRevision
        case binarySHA256 = "binarySha256"
    }

    package init(_ identity: TraceParserIdentity) throws {
        guard Self.safe(identity.name, maximumBytes: 128),
            Self.safe(identity.reportedVersion, maximumBytes: 128),
            Self.isLowercaseHex(identity.upstreamRevision, count: 40),
            Self.isSHA256(identity.binarySHA256)
        else {
            throw Self.invalidProvenance()
        }
        name = identity.name
        version = identity.reportedVersion
        upstreamRevision = identity.upstreamRevision
        binarySHA256 = identity.binarySHA256
    }

    private static func safe(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && !value.contains("/") && !value.contains("\\")
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        ArkTraceIdentityGrammar.isLowercaseHex(value, count: count)
    }

    static func isSHA256(_ value: String) -> Bool {
        ArkTraceIdentityGrammar.isSHA256(value)
    }

    static func invalidProvenance() -> ArkTraceError {
        ArkTraceError(
            code: .internalError,
            stage: .encoding,
            message: "Machine provenance is invalid"
        )
    }
}

package struct CLIMachineTrace: Hashable, Codable, Sendable {
    package let sha256: String
    package let byteCount: Int64
    package let durationNs: Int64
    package let parser: CLIMachineParserIdentity
    package let schemaFingerprint: String

    package init(metadata: TraceMetadata) throws {
        guard CLIMachineParserIdentity.isSHA256(metadata.traceSHA256),
            metadata.sourceByteCount >= 0,
            metadata.durationNs >= 0,
            CLIMachineParserIdentity.isSHA256(metadata.schemaFingerprint)
        else {
            throw CLIMachineParserIdentity.invalidProvenance()
        }
        sha256 = metadata.traceSHA256
        byteCount = metadata.sourceByteCount
        durationNs = metadata.durationNs
        parser = try CLIMachineParserIdentity(metadata.parser)
        schemaFingerprint = metadata.schemaFingerprint
    }
}

package struct CLIMachineProvenance: Hashable, Codable, Sendable {
    package let parserAdapterVersion: String
    package let parserBuildRecipeVersion: String
    package let schemaAdapterVersion: String
    package let indexSchemaVersion: Int
    package let upstreamDatabaseSHA256: String
    package let upstreamDatabaseByteCount: Int64

    private enum CodingKeys: String, CodingKey {
        case parserAdapterVersion
        case parserBuildRecipeVersion
        case schemaAdapterVersion
        case indexSchemaVersion
        case upstreamDatabaseSHA256 = "upstreamDatabaseSha256"
        case upstreamDatabaseByteCount
    }

    package init(
        parser: TraceParserIdentity,
        preparation: TraceDatabasePreparationResult
    ) throws {
        try CLIMachineValueValidation.requireSafeIdentifier(
            parser.adapterVersion,
            maximumBytes: 64
        )
        try CLIMachineValueValidation.requireSafeIdentifier(
            parser.buildRecipeVersion,
            maximumBytes: 64
        )
        try CLIMachineValueValidation.requireSafeIdentifier(
            preparation.schemaAdapterVersion,
            maximumBytes: 64
        )
        guard preparation.indexVersion >= 0,
            CLIMachineParserIdentity.isSHA256(preparation.upstreamDatabaseSHA256),
            preparation.upstreamDatabaseByteCount >= 0
        else {
            throw CLIMachineParserIdentity.invalidProvenance()
        }
        parserAdapterVersion = parser.adapterVersion
        parserBuildRecipeVersion = parser.buildRecipeVersion
        schemaAdapterVersion = preparation.schemaAdapterVersion
        indexSchemaVersion = preparation.indexVersion
        upstreamDatabaseSHA256 = preparation.upstreamDatabaseSHA256
        upstreamDatabaseByteCount = preparation.upstreamDatabaseByteCount
    }
}

package struct CLIMachineRequest: Hashable, Codable, Sendable {
    package let command: String
    package let parameters: [String: CLIJSONValue]

    package init(command: String, parameters: [String: CLIJSONValue] = [:]) throws {
        guard Self.isSafeIdentifier(command), command.utf8.count <= 64,
            parameters.count <= 64,
            parameters.keys.allSatisfy({ Self.isSafeIdentifier($0) && $0.utf8.count <= 64 })
        else {
            throw CLIParsing.invalid("Machine request echo is invalid")
        }
        self.command = command
        self.parameters = parameters
    }

    private init(validatedCommand command: String) {
        self.command = command
        parameters = [:]
    }

    static func hint(for arguments: [String]) -> CLIMachineRequest {
        let names: Set<String> = [
            "doctor", "inspect", "summary", "processes", "threads", "licenses",
            "query", "context", "analyze",
        ]
        let command = CLIArgumentParser.boundedPresentationArguments(arguments).first(where: {
            CLIArgumentParser.isWithinArgumentByteBudget($0) && names.contains($0)
        }) ?? "unknown"
        return CLIMachineRequest(validatedCommand: command)
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z"))
                || ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z"))
                || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-")
        }
    }
}

package extension CLIInvocation {
    func machineRequest() throws -> CLIMachineRequest {
        switch command {
        case .help:
            return try CLIMachineRequest(command: "help")
        case .version:
            return try CLIMachineRequest(command: "version")
        case .licenses:
            return try CLIMachineRequest(command: "licenses")
        case .doctor(let selfTest):
            return try CLIMachineRequest(
                command: "doctor",
                parameters: ["selfTest": .bool(selfTest)]
            )
        case .inspect:
            return try CLIMachineRequest(command: "inspect")
        case .summary(_, let range):
            return try CLIMachineRequest(
                command: "summary",
                parameters: [
                    "startNs": range.map { .int64($0.startNs) } ?? .null,
                    "endNs": range.map { .int64($0.endNs) } ?? .null,
                ]
            )
        case .processes(_, let pid, let name, let limit):
            return try CLIMachineRequest(
                command: "processes",
                parameters: [
                    "pid": pid.map(CLIJSONValue.int64) ?? .null,
                    "name": name.map(CLIJSONValue.string) ?? .null,
                    "limit": .int64(Int64(limit)),
                ]
            )
        case .threads(
            _, let processKey, let pid, let threadKey, let tid, let name, let limit
        ):
            return try CLIMachineRequest(
                command: "threads",
                parameters: [
                    "processKey": processKey.map(CLIJSONValue.int64) ?? .null,
                    "pid": pid.map(CLIJSONValue.int64) ?? .null,
                    "threadKey": threadKey.map(CLIJSONValue.int64) ?? .null,
                    "tid": tid.map(CLIJSONValue.int64) ?? .null,
                    "name": name.map(CLIJSONValue.string) ?? .null,
                    "limit": .int64(Int64(limit)),
                ]
            )
        case .query(_, let options):
            var parameters = options.filters.machineParameters
            parameters["view"] = .string(options.view.cliName)
            parameters["startNs"] = .int64(options.range.startNs)
            parameters["endNs"] = .int64(options.range.endNs)
            parameters["limit"] = .int64(Int64(options.limit))
            return try CLIMachineRequest(command: "query", parameters: parameters)
        case .context(_, let options):
            var parameters = options.filters.machineParameters
            switch options.time {
            case .timestamp(let timestampNs, let beforeNs, let afterNs):
                parameters["timestampNs"] = .int64(timestampNs)
                parameters["windowBeforeNs"] = .int64(beforeNs)
                parameters["windowAfterNs"] = .int64(afterNs)
                parameters["startNs"] = .null
                parameters["endNs"] = .null
            case .range(let range):
                parameters["timestampNs"] = .null
                parameters["windowBeforeNs"] = .null
                parameters["windowAfterNs"] = .null
                parameters["startNs"] = .int64(range.startNs)
                parameters["endNs"] = .int64(range.endNs)
            }
            return try CLIMachineRequest(command: "context", parameters: parameters)
        case .analyze(_, let options):
            var parameters = options.filters.machineParameters
            parameters["kind"] = .string(options.kind.rawValue)
            parameters["startNs"] = options.range.map { .int64($0.startNs) } ?? .null
            parameters["endNs"] = options.range.map { .int64($0.endNs) } ?? .null
            parameters["thresholdNs"] = .int64(options.thresholdNs)
            parameters["limit"] = .int64(Int64(options.limit))
            return try CLIMachineRequest(command: "analyze", parameters: parameters)
        }
    }
}

private extension TraceAgentQueryView {
    var cliName: String {
        switch self {
        case .cpuSlices: "cpu-slices"
        case .threadStates: "thread-states"
        case .slices: "slices"
        case .counters: "counters"
        }
    }
}

private extension TraceAgentQueryFilters {
    var machineParameters: [String: CLIJSONValue] {
        [
            "cpu": cpu.map(CLIJSONValue.int64) ?? .null,
            "processKey": processKey.map { .int64($0.ipid) } ?? .null,
            "pid": pid.map(CLIJSONValue.int64) ?? .null,
            "threadKey": threadKey.map { .int64($0.itid) } ?? .null,
            "tid": tid.map(CLIJSONValue.int64) ?? .null,
            "rawState": rawState.map(CLIJSONValue.string) ?? .null,
            "normalizedState": normalizedState.map { .string($0.rawValue) } ?? .null,
            "name": name.map(CLIJSONValue.string) ?? .null,
            "nameMatch": .string(nameMatch.rawValue),
            "minimumDurationNs": minimumDurationNs.map(CLIJSONValue.int64) ?? .null,
            "depth": depth.map(CLIJSONValue.int64) ?? .null,
            "counterFilterID": counterFilterID.map(CLIJSONValue.int64) ?? .null,
        ]
    }
}

package struct CLIMachineLimits: Hashable, Codable, Sendable {
    package let timeoutMs: Int64
    package let maxRows: Int
    package let maxEvents: Int
    package let maxOutputBytes: Int

    package init(_ limits: CLILimits) {
        timeoutMs = limits.timeoutMs
        maxRows = limits.maxRows
        maxEvents = limits.maxEvents
        maxOutputBytes = limits.maxOutputBytes
    }
}

package struct CLIMachineDataQualityWarning: Hashable, Codable, Sendable {
    package let category: TraceDataQualityIssue.Category
    package let scope: String?
    package let count: Int64?
    package let message: String?

    private enum CodingKeys: String, CodingKey {
        case category
        case scope
        case count
        case message
    }

    init(_ issue: TraceDataQualityIssue) throws {
        guard issue.count == nil || issue.count! >= 0,
            Self.safeScope(issue.scope)
        else {
            throw ArkTraceError(
                code: .internalError,
                stage: .encoding,
                message: "Machine data-quality evidence is invalid"
            )
        }
        category = issue.category
        scope = issue.scope
        count = issue.count
        // Store messages are human diagnostics. Machine clients branch on
        // the closed category/scope/count tuple, so raw diagnostic prose is
        // deliberately omitted from the privacy boundary.
        message = nil
    }

    private static func safeScope(_ value: String?) -> Bool {
        guard let value else { return true }
        return allowedScopes.contains(value)
    }

    private static let allowedScopes = TraceDataQualityScope.machineAllowed

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(category, forKey: .category)
        if let scope { try container.encode(scope, forKey: .scope) }
        else { try container.encodeNil(forKey: .scope) }
        if let count { try container.encode(count, forKey: .count) }
        else { try container.encodeNil(forKey: .count) }
        if let message { try container.encode(message, forKey: .message) }
        else { try container.encodeNil(forKey: .message) }
    }
}

package struct CLIMachineDataQuality: Hashable, Codable, Sendable {
    package let status: TraceDataQuality.Status
    package let warnings: [CLIMachineDataQualityWarning]

    package init(_ quality: TraceDataQuality) throws {
        guard quality.issues.count <= 4_096 else {
            throw ArkTraceError(
                code: .outputLimitExceeded,
                stage: .encoding,
                message: "Machine data-quality evidence exceeds its item budget",
                retryable: true
            )
        }
        guard quality.issues.allSatisfy({ $0.category != .unclassified }) else {
            throw ArkTraceError(
                code: .internalError,
                stage: .encoding,
                message: "Machine data-quality evidence is not categorized"
            )
        }
        warnings = try quality.issues.map(CLIMachineDataQualityWarning.init).sorted {
            let lhs = ($0.category.rawValue, $0.scope ?? "", $0.count ?? Int64.min, $0.message ?? "")
            let rhs = ($1.category.rawValue, $1.scope ?? "", $1.count ?? Int64.min, $1.message ?? "")
            return lhs < rhs
        }
        status = warnings.isEmpty ? .ok : .warnings
    }
}

package struct CLIMachineTruncation: Hashable, Codable, Sendable {
    package let truncated: Bool
    package let sections: [String]

    package init(sections: [String] = []) throws {
        guard sections.count <= 256,
            sections.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 })
        else {
            throw ArkTraceError(
                code: .outputLimitExceeded,
                stage: .encoding,
                message: "Machine truncation evidence exceeds its item budget",
                retryable: true
            )
        }
        self.sections = Array(Set(sections)).sorted()
        truncated = !self.sections.isEmpty
    }
}

package enum CLIMachineDoctorStatus: String, Codable, Sendable {
    case ok
    case warning
    case failed
}

package struct CLIMachineDoctorCheck: Hashable, Codable, Sendable {
    package let code: String
    package let name: String
    package let status: CLIMachineDoctorStatus

    package init(code: String, name: String, status: CLIMachineDoctorStatus) throws {
        try CLIMachineValueValidation.requireSafeIdentifier(code, maximumBytes: 64)
        guard let canonicalName = Self.canonicalNames[code], name == canonicalName else {
            throw CLIMachineValueValidation.contractFailure(reason: "unknownDoctorCheck")
        }
        self.code = code
        self.name = name
        self.status = status
    }

    private static let canonicalNames: [String: String] = [
        "tool": "ArkTrace tool",
        "os": "Operating system",
        "architecture": "Architecture",
        "parserManifest": "Parser manifest",
        "parserIdentity": "Parser identity",
        "sqlite": "SQLite",
        "cache": "Trace cache",
        "schemaAdapter": "Schema adapter",
        "selfTest": "End-to-end self-test",
    ]

    fileprivate static let canonicalOrder = [
        "tool", "os", "architecture", "parserManifest", "parserIdentity",
        "sqlite", "cache", "schemaAdapter", "selfTest",
    ]
}

package struct CLIMachineDoctorResult: Hashable, Codable, Sendable {
    package let selfTest: Bool
    package let checks: [CLIMachineDoctorCheck]

    package init(selfTest: Bool, checks: [CLIMachineDoctorCheck]) throws {
        let identities = checks.map(\.code)
        let ranks = identities.compactMap {
            CLIMachineDoctorCheck.canonicalOrder.firstIndex(of: $0)
        }
        guard checks.count <= 256,
            Set(identities).count == identities.count,
            ranks.count == checks.count,
            ranks == ranks.sorted()
        else {
            throw CLIMachineValueValidation.limitFailure()
        }
        self.selfTest = selfTest
        self.checks = checks
    }
}

package struct CLIMachineInspectResult: Hashable, Codable, Sendable {
    package let cacheHit: Bool
    package let capabilities: TraceCapabilities
    package let indexSchemaVersion: Int

    fileprivate init(
        cacheHit: Bool,
        capabilities: TraceCapabilities,
        indexSchemaVersion: Int
    ) throws {
        guard indexSchemaVersion >= 0 else {
            throw CLIMachineValueValidation.contractFailure(reason: "invalidIndexVersion")
        }
        self.cacheHit = cacheHit
        self.capabilities = capabilities
        self.indexSchemaVersion = indexSchemaVersion
    }
}

package struct CLIMachineRange: Hashable, Codable, Sendable {
    package let startNs: Int64
    package let endNs: Int64

    fileprivate init(_ range: TraceTimeRange) {
        startNs = range.startNs
        endNs = range.endNs
    }
}

package struct CLIMachineEventSourceCount: Hashable, Codable, Sendable {
    package let source: String
    package let count: Int64

    fileprivate init(_ value: TraceEventSourceCount) throws {
        try CLIMachineValueValidation.requireBoundedText(value.source, maximumBytes: 1_024)
        guard value.count >= 0 else {
            throw CLIMachineValueValidation.contractFailure(reason: "negativeCount")
        }
        source = value.source
        count = value.count
    }
}

package struct CLIMachineSummaryResult: Hashable, Codable, Sendable {
    package let range: CLIMachineRange
    package let durationNs: Int64
    package let cpuCount: Int64?
    package let processCount: Int64
    package let threadCount: Int64
    package let cpuSliceCount: Int64?
    package let threadStateCount: Int64?
    package let namedSliceCount: Int64?
    package let counterSeriesCount: Int64?
    package let eventCountBySource: [CLIMachineEventSourceCount]?
    package let capabilities: TraceCapabilities

    private enum CodingKeys: String, CodingKey {
        case range
        case durationNs
        case cpuCount
        case processCount
        case threadCount
        case cpuSliceCount
        case threadStateCount
        case namedSliceCount
        case counterSeriesCount
        case eventCountBySource
        case capabilities
    }

    fileprivate init(_ summary: TraceSummary) throws {
        let counts = [
            summary.cpuCount, summary.cpuSliceCount, summary.threadStateCount,
            summary.namedSliceCount, summary.counterSeriesCount,
        ]
        guard summary.durationNs >= 0,
            summary.processCount >= 0,
            summary.threadCount >= 0,
            counts.allSatisfy({ $0 == nil || $0! >= 0 }),
            (summary.eventCountBySource?.count ?? 0) <= 100_000
        else {
            throw CLIMachineValueValidation.contractFailure(reason: "invalidSummaryValue")
        }
        range = CLIMachineRange(summary.range)
        durationNs = summary.durationNs
        cpuCount = summary.cpuCount
        processCount = summary.processCount
        threadCount = summary.threadCount
        cpuSliceCount = summary.cpuSliceCount
        threadStateCount = summary.threadStateCount
        namedSliceCount = summary.namedSliceCount
        counterSeriesCount = summary.counterSeriesCount
        eventCountBySource = try summary.eventCountBySource?.map(CLIMachineEventSourceCount.init)
        capabilities = summary.capabilities
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(range, forKey: .range)
        try container.encode(durationNs, forKey: .durationNs)
        try container.encodeNullable(cpuCount, forKey: .cpuCount)
        try container.encode(processCount, forKey: .processCount)
        try container.encode(threadCount, forKey: .threadCount)
        try container.encodeNullable(cpuSliceCount, forKey: .cpuSliceCount)
        try container.encodeNullable(threadStateCount, forKey: .threadStateCount)
        try container.encodeNullable(namedSliceCount, forKey: .namedSliceCount)
        try container.encodeNullable(counterSeriesCount, forKey: .counterSeriesCount)
        try container.encodeNullable(eventCountBySource, forKey: .eventCountBySource)
        try container.encode(capabilities, forKey: .capabilities)
    }
}

package struct CLIMachineProcess: Hashable, Codable, Sendable {
    package let key: Int64
    package let pid: Int64
    package let name: String?
    package let startNs: Int64?
    package let endNs: Int64?
    package let threadCount: Int?

    private enum CodingKeys: String, CodingKey {
        case key
        case pid
        case name
        case startNs
        case endNs
        case threadCount
    }

    fileprivate init(_ process: TraceProcess) throws {
        try CLIMachineValueValidation.requireBoundedOptionalText(
            process.name,
            maximumBytes: 4_096
        )
        guard process.startNs == nil || process.startNs! >= 0,
            process.endNs == nil || process.endNs! >= 0,
            process.threadCount == nil || process.threadCount! >= 0
        else {
            throw CLIMachineValueValidation.contractFailure(reason: "invalidProcessValue")
        }
        key = process.key.ipid
        pid = process.pid
        name = process.name
        startNs = process.startNs
        endNs = process.endNs
        threadCount = process.threadCount
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(pid, forKey: .pid)
        try container.encodeNullable(name, forKey: .name)
        try container.encodeNullable(startNs, forKey: .startNs)
        try container.encodeNullable(endNs, forKey: .endNs)
        try container.encodeNullable(threadCount, forKey: .threadCount)
    }
}

package struct CLIMachineProcessesResult: Hashable, Codable, Sendable {
    package let items: [CLIMachineProcess]

    fileprivate init(_ page: BoundedPage<TraceProcess>) throws {
        guard page.items.count <= 100_000 else {
            throw CLIMachineValueValidation.limitFailure()
        }
        items = try page.items.map(CLIMachineProcess.init)
    }
}

package struct CLIMachineThread: Hashable, Codable, Sendable {
    package let key: Int64
    package let processKey: Int64?
    package let tid: Int64
    package let pid: Int64?
    package let name: String?
    package let processName: String?
    package let startNs: Int64?
    package let endNs: Int64?
    package let isMainThread: Bool?

    private enum CodingKeys: String, CodingKey {
        case key
        case processKey
        case tid
        case pid
        case name
        case processName
        case startNs
        case endNs
        case isMainThread
    }

    fileprivate init(_ thread: TraceThread) throws {
        try CLIMachineValueValidation.requireBoundedOptionalText(
            thread.name,
            maximumBytes: 4_096
        )
        try CLIMachineValueValidation.requireBoundedOptionalText(
            thread.processName,
            maximumBytes: 4_096
        )
        guard thread.startNs == nil || thread.startNs! >= 0,
            thread.endNs == nil || thread.endNs! >= 0
        else {
            throw CLIMachineValueValidation.contractFailure(reason: "invalidThreadValue")
        }
        key = thread.key.itid
        processKey = thread.processKey?.ipid
        tid = thread.tid
        pid = thread.pid
        name = thread.name
        processName = thread.processName
        startNs = thread.startNs
        endNs = thread.endNs
        isMainThread = thread.isMainThread
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encodeNullable(processKey, forKey: .processKey)
        try container.encode(tid, forKey: .tid)
        try container.encodeNullable(pid, forKey: .pid)
        try container.encodeNullable(name, forKey: .name)
        try container.encodeNullable(processName, forKey: .processName)
        try container.encodeNullable(startNs, forKey: .startNs)
        try container.encodeNullable(endNs, forKey: .endNs)
        try container.encodeNullable(isMainThread, forKey: .isMainThread)
    }
}

package struct CLIMachineThreadsResult: Hashable, Codable, Sendable {
    package let items: [CLIMachineThread]

    fileprivate init(_ page: BoundedPage<TraceThread>) throws {
        guard page.items.count <= 100_000 else {
            throw CLIMachineValueValidation.limitFailure()
        }
        items = try page.items.map(CLIMachineThread.init)
    }
}

package struct CLIMachineAgentQueryResult: Encodable, Sendable {
    private let value: TraceAgentQueryResult
    private let dataQuality: CLIMachineDataQuality

    private enum CodingKeys: String, CodingKey {
        case view, range, filters, capabilityAvailable, truncated, dataQuality
        case cpuSlices, threadStates, slices, counters
    }

    fileprivate init(_ value: TraceAgentQueryResult) throws {
        self.value = value
        dataQuality = try CLIMachineDataQuality(value.dataQuality)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.view, forKey: .view)
        try container.encode(value.range, forKey: .range)
        try container.encode(value.filters, forKey: .filters)
        try container.encode(value.capabilityAvailable, forKey: .capabilityAvailable)
        try container.encode(value.truncated, forKey: .truncated)
        try container.encode(dataQuality, forKey: .dataQuality)
        switch value.view {
        case .cpuSlices: try container.encode(value.cpuSlices, forKey: .cpuSlices)
        case .threadStates: try container.encode(value.threadStates, forKey: .threadStates)
        case .slices: try container.encode(value.slices, forKey: .slices)
        case .counters: try container.encode(value.counters, forKey: .counters)
        }
    }
}

private struct CLIMachineContextSummary: Encodable, Sendable {
    let value: TraceSummary
    let dataQuality: CLIMachineDataQuality

    private enum CodingKeys: String, CodingKey {
        case range, durationNs, cpuCount, processCount, threadCount
        case cpuSliceCount, threadStateCount, namedSliceCount, counterSeriesCount
        case eventCountBySource, capabilities, schemaFingerprint, dataQuality
        case truncatedSections
    }

    init(_ value: TraceSummary) throws {
        self.value = value
        dataQuality = try CLIMachineDataQuality(value.dataQuality)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.range, forKey: .range)
        try container.encode(value.durationNs, forKey: .durationNs)
        try container.encodeNullable(value.cpuCount, forKey: .cpuCount)
        try container.encode(value.processCount, forKey: .processCount)
        try container.encode(value.threadCount, forKey: .threadCount)
        try container.encodeNullable(value.cpuSliceCount, forKey: .cpuSliceCount)
        try container.encodeNullable(value.threadStateCount, forKey: .threadStateCount)
        try container.encodeNullable(value.namedSliceCount, forKey: .namedSliceCount)
        try container.encodeNullable(value.counterSeriesCount, forKey: .counterSeriesCount)
        try container.encodeNullable(value.eventCountBySource, forKey: .eventCountBySource)
        try container.encode(value.capabilities, forKey: .capabilities)
        try container.encode(value.schemaFingerprint, forKey: .schemaFingerprint)
        try container.encode(dataQuality, forKey: .dataQuality)
        try container.encode(value.truncatedSections, forKey: .truncatedSections)
    }
}

package struct CLIMachineContextResult: Encodable, Sendable {
    private let value: TraceContext
    private let dataQuality: CLIMachineDataQuality
    private let summary: CLIMachineContextSummary

    private enum CodingKeys: String, CodingKey {
        case range, filters, processes, threads, cpuSlices, threadStates
        case slices, counters, summary, dataQuality, truncation
    }

    fileprivate init(_ value: TraceContext) throws {
        self.value = value
        dataQuality = try CLIMachineDataQuality(value.dataQuality)
        summary = try CLIMachineContextSummary(value.summary)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.range, forKey: .range)
        try container.encode(value.filters, forKey: .filters)
        try container.encode(value.processes, forKey: .processes)
        try container.encode(value.threads, forKey: .threads)
        try container.encode(value.cpuSlices, forKey: .cpuSlices)
        try container.encode(value.threadStates, forKey: .threadStates)
        try container.encode(value.slices, forKey: .slices)
        try container.encode(value.counters, forKey: .counters)
        try container.encode(summary, forKey: .summary)
        try container.encode(dataQuality, forKey: .dataQuality)
        try container.encode(value.truncation, forKey: .truncation)
    }
}

package struct CLIMachineDeterministicAnalysisResult: Encodable, Sendable {
    private let value: TraceDeterministicAnalysis
    private let dataQuality: CLIMachineDataQuality

    private enum CodingKeys: String, CodingKey {
        case kind, parameters, range, cpuUtilization, topProcesses, topThreads
        case longSlices, threadStateDistribution, schedulingLatency, hotIntervals
        case sections, dataQuality
    }

    fileprivate init(_ value: TraceDeterministicAnalysis) throws {
        self.value = value
        dataQuality = try CLIMachineDataQuality(value.dataQuality)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.kind, forKey: .kind)
        try container.encode(value.parameters, forKey: .parameters)
        try container.encode(value.range, forKey: .range)
        try container.encode(value.cpuUtilization, forKey: .cpuUtilization)
        try container.encode(value.topProcesses, forKey: .topProcesses)
        try container.encode(value.topThreads, forKey: .topThreads)
        try container.encode(value.longSlices, forKey: .longSlices)
        try container.encode(value.threadStateDistribution, forKey: .threadStateDistribution)
        try container.encode(value.schedulingLatency, forKey: .schedulingLatency)
        try container.encode(value.hotIntervals, forKey: .hotIntervals)
        try container.encode(value.sections, forKey: .sections)
        try container.encode(dataQuality, forKey: .dataQuality)
    }
}

package struct CLIMachineAnalyzeResult: Encodable, Sendable {
    package let kind: CLIAnalyzeKind
    package let analysis: CLIMachineDeterministicAnalysisResult

    fileprivate init(kind: CLIAnalyzeKind, analysis: TraceDeterministicAnalysis) throws {
        self.kind = kind
        self.analysis = try CLIMachineDeterministicAnalysisResult(analysis)
    }
}

package enum CLIMachineCommandResult: Encodable, Sendable {
    case doctor(CLIMachineDoctorResult)
    case inspect(CLIMachineInspectResult)
    case summary(CLIMachineSummaryResult)
    case processes(CLIMachineProcessesResult)
    case threads(CLIMachineThreadsResult)
    case query(CLIMachineAgentQueryResult)
    case context(CLIMachineContextResult)
    case analyze(CLIMachineAnalyzeResult)

    package func encode(to encoder: Encoder) throws {
        switch self {
        case .doctor(let result): try result.encode(to: encoder)
        case .inspect(let result): try result.encode(to: encoder)
        case .summary(let result): try result.encode(to: encoder)
        case .processes(let result): try result.encode(to: encoder)
        case .threads(let result): try result.encode(to: encoder)
        case .query(let result): try result.encode(to: encoder)
        case .context(let result): try result.encode(to: encoder)
        case .analyze(let result): try result.encode(to: encoder)
        }
    }
}

struct CLIMachineTraceSnapshot: Sendable {
    let metadata: TraceMetadata
    let preparation: TraceDatabasePreparationResult
    let cacheHit: Bool

    init(
        parsed: ParsedTrace,
        metadata: TraceMetadata,
        cacheHit: Bool,
        cacheMetadata: TraceCacheMetadata? = nil
    ) throws {
        guard metadata.traceSHA256 == parsed.sourceSHA256,
            metadata.sourceByteCount == parsed.sourceByteCount,
            metadata.parser == parsed.parser,
            metadata.schemaFingerprint == parsed.databasePreparation.schemaFingerprint
        else {
            throw CLIMachineValueValidation.contractFailure(
                reason: "sessionProvenanceMismatch"
            )
        }
        if let cacheMetadata {
            guard cacheMetadata.parser == parsed.parser,
                cacheMetadata.sourceSHA256 == parsed.sourceSHA256,
                cacheMetadata.sourceByteCount == parsed.sourceByteCount,
                cacheMetadata.databasePreparation == parsed.databasePreparation
            else {
                throw CLIMachineValueValidation.contractFailure(
                    reason: "cacheProvenanceMismatch"
                )
            }
        }
        try CLIMachineCommandPayload.validate(
            metadata: metadata,
            preparation: parsed.databasePreparation
        )
        self.metadata = metadata
        preparation = parsed.databasePreparation
        self.cacheHit = cacheHit
    }

}

struct CLIMachineBoundTraceResult<Value: Sendable>: Sendable {
    let snapshot: CLIMachineTraceSnapshot
    let value: Value
}

/// Internal execution boundary for machine payloads. Production conformance
/// is owned by TraceSession, so metadata, parse provenance and every query
/// result come from one immutable session rather than caller-supplied pieces.
protocol CLIMachineTraceSession: Sendable {
    func cliInspectSnapshot() async throws -> CLIMachineTraceSnapshot
    func cliSummary(
        _ request: TraceSummaryRequest
    ) async throws -> CLIMachineBoundTraceResult<TraceSummary>
    func cliProcesses(
        _ query: ProcessQuery
    ) async throws -> CLIMachineBoundTraceResult<BoundedPage<TraceProcess>>
    func cliThreads(
        _ query: ThreadQuery
    ) async throws -> CLIMachineBoundTraceResult<BoundedPage<TraceThread>>
    func cliAgentQuery(
        _ request: TraceAgentQueryRequest
    ) async throws -> CLIMachineBoundTraceResult<TraceAgentQueryResult>
    func cliContext(
        _ request: TraceContextRequest
    ) async throws -> CLIMachineBoundTraceResult<TraceContext>
    func cliAnalyze(
        _ request: TraceDeterministicAnalysisRequest
    ) async throws -> CLIMachineBoundTraceResult<TraceDeterministicAnalysis>
}

// Existing internal session doubles that exercise only the Phase 2 commands
// stay source-compatible. Phase 4 command tests override the exact operation
// they support; reaching one of these defaults is a stable test-boundary
// failure rather than a fabricated result.
extension CLIMachineTraceSession {
    func cliAgentQuery(
        _ request: TraceAgentQueryRequest
    ) async throws -> CLIMachineBoundTraceResult<TraceAgentQueryResult> {
        throw ArkTraceError(
            code: .internalError,
            stage: .querying,
            message: "Trace session does not implement Agent query",
            details: ["reason": "missingAgentQueryBoundary"]
        )
    }

    func cliContext(
        _ request: TraceContextRequest
    ) async throws -> CLIMachineBoundTraceResult<TraceContext> {
        throw ArkTraceError(
            code: .internalError,
            stage: .analyzing,
            message: "Trace session does not implement Context",
            details: ["reason": "missingContextBoundary"]
        )
    }

    func cliAnalyze(
        _ request: TraceDeterministicAnalysisRequest
    ) async throws -> CLIMachineBoundTraceResult<TraceDeterministicAnalysis> {
        throw ArkTraceError(
            code: .internalError,
            stage: .analyzing,
            message: "Trace session does not implement deterministic analysis",
            details: ["reason": "missingAnalysisBoundary"]
        )
    }
}

extension TraceSession: CLIMachineTraceSession {
    func cliInspectSnapshot() async throws -> CLIMachineTraceSnapshot {
        let metadata = try await repository.metadata()
        return try CLIMachineTraceSnapshot(
            parsed: parsed,
            metadata: metadata,
            cacheHit: cacheHit,
            cacheMetadata: cacheMetadata
        )
    }

    func cliSummary(
        _ request: TraceSummaryRequest
    ) async throws -> CLIMachineBoundTraceResult<TraceSummary> {
        let value = try await TraceSummaryEngine(repository: repository).summarize(request)
        return try await CLIMachineBoundTraceResult(
            snapshot: cliInspectSnapshot(),
            value: value
        )
    }

    func cliProcesses(
        _ query: ProcessQuery
    ) async throws -> CLIMachineBoundTraceResult<BoundedPage<TraceProcess>> {
        let value = try await repository.processes(query)
        return try await CLIMachineBoundTraceResult(
            snapshot: cliInspectSnapshot(),
            value: value
        )
    }

    func cliThreads(
        _ query: ThreadQuery
    ) async throws -> CLIMachineBoundTraceResult<BoundedPage<TraceThread>> {
        let value = try await repository.threads(query)
        return try await CLIMachineBoundTraceResult(
            snapshot: cliInspectSnapshot(),
            value: value
        )
    }

    func cliAgentQuery(
        _ request: TraceAgentQueryRequest
    ) async throws -> CLIMachineBoundTraceResult<TraceAgentQueryResult> {
        let value = try await TraceAgentQueryEngine(repository: repository).query(request)
        return try await CLIMachineBoundTraceResult(
            snapshot: cliInspectSnapshot(), value: value
        )
    }

    func cliContext(
        _ request: TraceContextRequest
    ) async throws -> CLIMachineBoundTraceResult<TraceContext> {
        let value = try await TraceContextBuilder(repository: repository).build(request)
        return try await CLIMachineBoundTraceResult(
            snapshot: cliInspectSnapshot(), value: value
        )
    }

    func cliAnalyze(
        _ request: TraceDeterministicAnalysisRequest
    ) async throws -> CLIMachineBoundTraceResult<TraceDeterministicAnalysis> {
        let value = try await TraceDeterministicAnalysisEngine(
            repository: repository
        ).analyze(request)
        return try await CLIMachineBoundTraceResult(
            snapshot: cliInspectSnapshot(), value: value
        )
    }
}

/// Domain-owned evidence returned by command executors. Construction is
/// module-internal and trace results are obtained through CLIMachineTraceSession;
/// external executors cannot forge a successful machine envelope.
package struct CLIMachineCommandPayload: Sendable {
    private enum Storage: Sendable {
        case doctor(CLIMachineDoctorResult, truncated: Bool)
        case inspect(CLIMachineTraceSnapshot, CLIMachineInspectResult)
        case summary(CLIMachineTraceSnapshot, TraceSummary)
        case processes(CLIMachineTraceSnapshot, BoundedPage<TraceProcess>)
        case threads(CLIMachineTraceSnapshot, BoundedPage<TraceThread>)
        case query(CLIMachineTraceSnapshot, TraceAgentQueryResult)
        case context(CLIMachineTraceSnapshot, TraceContext)
        case analyze(CLIMachineTraceSnapshot, CLIAnalyzeKind, TraceDeterministicAnalysis)
    }

    private let storage: Storage

    /// Runs the same request/result/provenance checks for human and Machine
    /// presentation. The fixed internal tool is never encoded or exposed; it
    /// only lets the single envelope implementation remain the source of truth.
    func validate(for invocation: CLIInvocation) throws {
        let validationTool = try CLIMachineTool(
            name: ArkTraceCLITool.name,
            version: ArkTraceCLITool.version,
            buildRevision: String(repeating: "0", count: 64)
        )
        _ = try validatedEnvelope(
            for: invocation,
            tool: validationTool,
            performMachinePreflight: false
        )
    }

    static func doctor(
        selfTest: Bool,
        checks: BoundedPage<CLIMachineDoctorCheck>
    ) throws -> CLIMachineCommandPayload {
        CLIMachineCommandPayload(storage: .doctor(
            try CLIMachineDoctorResult(selfTest: selfTest, checks: checks.items),
            truncated: checks.truncated
        ))
    }

    static func inspect(
        session: any CLIMachineTraceSession
    ) async throws -> CLIMachineCommandPayload {
        try inspect(snapshot: await session.cliInspectSnapshot())
    }

    static func inspect(
        snapshot: CLIMachineTraceSnapshot
    ) throws -> CLIMachineCommandPayload {
        return CLIMachineCommandPayload(storage: .inspect(
            snapshot,
            try CLIMachineInspectResult(
                cacheHit: snapshot.cacheHit,
                capabilities: snapshot.metadata.capabilities,
                indexSchemaVersion: snapshot.preparation.indexVersion
            )
        ))
    }

    static func summary(
        session: any CLIMachineTraceSession,
        request: TraceSummaryRequest
    ) async throws -> CLIMachineCommandPayload {
        try summary(bound: await session.cliSummary(request))
    }

    static func summary(
        bound: CLIMachineBoundTraceResult<TraceSummary>
    ) throws -> CLIMachineCommandPayload {
        try validateSummary(bound.value, snapshot: bound.snapshot)
        return CLIMachineCommandPayload(storage: .summary(bound.snapshot, bound.value))
    }

    private static func validateSummary(
        _ summary: TraceSummary,
        snapshot: CLIMachineTraceSnapshot
    ) throws {
        let metadata = snapshot.metadata
        guard summary.dataQuality.issues.count <= 4_096,
            (summary.eventCountBySource?.count ?? 0) <= 100_000
        else { throw CLIMachineValueValidation.limitFailure() }
        guard summary.schemaFingerprint == metadata.schemaFingerprint,
            summary.capabilities == metadata.capabilities,
            Set(metadata.dataQuality.issues).isSubset(of: Set(summary.dataQuality.issues)),
            summary.range.startNs >= 0,
            summary.range.endNs <= metadata.durationNs,
            summary.durationNs == summary.range.durationNs
        else {
            throw CLIMachineValueValidation.contractFailure(reason: "summaryProvenanceMismatch")
        }
        try validateSummaryCapabilityContract(summary)
        var previousSourceBytes: Data?
        for (index, item) in (summary.eventCountBySource ?? []).enumerated() {
            if index.isMultiple(of: 1_024), Task.isCancelled { throw CancellationError() }
            _ = try CLIMachineEventSourceCount(item)
            let sourceBytes = Data(item.source.utf8)
            if let previousSourceBytes,
                !previousSourceBytes.lexicographicallyPrecedes(sourceBytes)
            {
                throw CLIMachineValueValidation.contractFailure(
                    reason: "duplicateOrUnstableEventSource"
                )
            }
            previousSourceBytes = sourceBytes
        }
    }

    static func processes(
        session: any CLIMachineTraceSession,
        query: ProcessQuery
    ) async throws -> CLIMachineCommandPayload {
        try processes(bound: await session.cliProcesses(query))
    }

    static func processes(
        bound: CLIMachineBoundTraceResult<BoundedPage<TraceProcess>>
    ) throws -> CLIMachineCommandPayload {
        let page = bound.value
        guard page.items.count <= 100_000 else {
            throw CLIMachineValueValidation.limitFailure()
        }
        try validateProcesses(page.items, durationNs: bound.snapshot.metadata.durationNs)
        return CLIMachineCommandPayload(storage: .processes(bound.snapshot, page))
    }

    static func threads(
        session: any CLIMachineTraceSession,
        query: ThreadQuery
    ) async throws -> CLIMachineCommandPayload {
        try threads(bound: await session.cliThreads(query))
    }

    static func threads(
        bound: CLIMachineBoundTraceResult<BoundedPage<TraceThread>>
    ) throws -> CLIMachineCommandPayload {
        let page = bound.value
        guard page.items.count <= 100_000 else {
            throw CLIMachineValueValidation.limitFailure()
        }
        try validateThreads(page.items, durationNs: bound.snapshot.metadata.durationNs)
        return CLIMachineCommandPayload(storage: .threads(bound.snapshot, page))
    }

    static func query(
        bound: CLIMachineBoundTraceResult<TraceAgentQueryResult>
    ) throws -> CLIMachineCommandPayload {
        guard bound.value.range.endNs <= bound.snapshot.metadata.durationNs,
            bound.value.dataQuality.issues.count <= 4_096
        else {
            throw CLIMachineValueValidation.contractFailure(
                reason: "agentQueryProvenanceMismatch"
            )
        }
        return CLIMachineCommandPayload(storage: .query(bound.snapshot, bound.value))
    }

    static func context(
        bound: CLIMachineBoundTraceResult<TraceContext>
    ) throws -> CLIMachineCommandPayload {
        guard bound.value.range.endNs <= bound.snapshot.metadata.durationNs,
            bound.value.dataQuality.issues.count <= 4_096
        else {
            throw CLIMachineValueValidation.contractFailure(
                reason: "contextProvenanceMismatch"
            )
        }
        try validateSummary(bound.value.summary, snapshot: bound.snapshot)
        let context = bound.value
        let summary = context.summary
        guard summary.range == context.range,
            Set(summary.dataQuality.issues).isSubset(of: Set(context.dataQuality.issues))
        else {
            throw CLIMachineValueValidation.contractFailure(
                reason: "contextSummaryMismatch"
            )
        }
        try validateContextSectionStatuses(context)
        return CLIMachineCommandPayload(storage: .context(bound.snapshot, context))
    }

    private static func validateContextSectionStatuses(_ context: TraceContext) throws {
        let counters = context.counters.reduce(into: 0) { total, series in
            let (next, overflow) = total.addingReportingOverflow(series.samples.count)
            total = overflow ? .max : next
        }
        let values: [(TraceContextSectionStatus, Int)] = [
            (context.truncation.processes, context.processes.count),
            (context.truncation.threads, context.threads.count),
            (context.truncation.cpuSlices, context.cpuSlices.count),
            (context.truncation.threadStates, context.threadStates.count),
            (context.truncation.slices, context.slices.count),
            (context.truncation.counters, counters),
            (context.truncation.summary, 1),
        ]
        guard values.allSatisfy({ status, actual in
            status.returnedCount == actual
                && status.returnedCount >= 0
                && (status.matchedCount == nil || status.matchedCount! >= actual)
        }) else {
            throw CLIMachineValueValidation.contractFailure(
                reason: "contextSectionStatusMismatch"
            )
        }
    }

    static func analyze(
        kind: CLIAnalyzeKind,
        bound: CLIMachineBoundTraceResult<TraceDeterministicAnalysis>
    ) throws -> CLIMachineCommandPayload {
        guard bound.value.range.endNs <= bound.snapshot.metadata.durationNs,
            bound.value.dataQuality.issues.count <= 4_096
        else {
            throw CLIMachineValueValidation.contractFailure(
                reason: "analysisProvenanceMismatch"
            )
        }
        try validateAnalysisSectionStatuses(bound.value)
        return CLIMachineCommandPayload(
            storage: .analyze(bound.snapshot, kind, bound.value)
        )
    }

    private static func validateAnalysisSectionStatuses(
        _ analysis: TraceDeterministicAnalysis
    ) throws {
        let values: [(TraceAnalysisSectionStatus, Int)] = [
            (analysis.sections.cpuUtilization, analysis.cpuUtilization.count),
            (analysis.sections.topProcesses, analysis.topProcesses.count),
            (analysis.sections.topThreads, analysis.topThreads.count),
            (analysis.sections.longSlices, analysis.longSlices.count),
            (
                analysis.sections.threadStateDistribution,
                analysis.threadStateDistribution.count
            ),
            (
                analysis.sections.schedulingLatency,
                analysis.schedulingLatency.topSamples.count
            ),
            (analysis.sections.hotIntervals, analysis.hotIntervals.count),
        ]
        guard values.allSatisfy({ status, actual in
            status.returnedCount == actual
                && status.returnedCount >= 0
                && (status.matchedCount == nil || status.matchedCount! >= actual)
        }) else {
            throw CLIMachineValueValidation.contractFailure(
                reason: "analysisSectionStatusMismatch"
            )
        }
    }

    func envelope(
        for invocation: CLIInvocation,
        tool: CLIMachineTool
    ) throws -> CLIMachineSuccessEnvelope<CLIMachineCommandResult> {
        try validatedEnvelope(
            for: invocation,
            tool: tool,
            performMachinePreflight: true
        )
    }

    private func validatedEnvelope(
        for invocation: CLIInvocation,
        tool: CLIMachineTool,
        performMachinePreflight: Bool
    ) throws -> CLIMachineSuccessEnvelope<CLIMachineCommandResult> {
        if performMachinePreflight {
            try preflight(maximumBytes: invocation.options.limits.maxOutputBytes)
        }
        let request = try invocation.machineRequest()
        let limits = CLIMachineLimits(invocation.options.limits)
        switch (storage, invocation.command) {
        case (.doctor(let result, let truncated), .doctor(let requestedSelfTest)):
            guard result.selfTest == requestedSelfTest else {
                throw CLIMachineValueValidation.contractFailure(reason: "requestPayloadMismatch")
            }
            try validateItemCount(
                result.checks.count,
                requestedLimit: invocation.options.limits.maxRows,
                globalLimit: invocation.options.limits.maxRows,
                truncated: truncated
            )
            if truncated {
                let expectedPrefix = Array(
                    CLIMachineDoctorCheck.canonicalOrder.prefix(result.checks.count)
                )
                guard result.checks.map(\.code) == expectedPrefix else {
                    throw CLIMachineValueValidation.contractFailure(
                        reason: "requestPayloadMismatch"
                    )
                }
            }
            return CLIMachineSuccessEnvelope(
                tool: tool,
                trace: nil,
                request: request,
                limits: limits,
                result: .doctor(result),
                dataQuality: try CLIMachineDataQuality(TraceDataQuality()),
                truncation: try CLIMachineTruncation(
                    sections: truncated ? ["checks"] : []
                ),
                provenance: nil
            )
        case (.inspect(let snapshot, let result), .inspect):
            let probeTruncated = snapshot.metadata.dataQuality.issues.contains {
                $0.category == .probeTruncated
            }
            return try traceEnvelope(
                metadata: snapshot.metadata,
                preparation: snapshot.preparation,
                tool: tool,
                request: request,
                limits: limits,
                result: .inspect(result),
                quality: snapshot.metadata.dataQuality,
                truncationSections: probeTruncated ? ["dataQualityProbes"] : []
            )
        case (.summary(let snapshot, let summary), .summary(_, let requestedRange)):
            let metadata = snapshot.metadata
            let expectedRange = try requestedRange
                ?? TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs)
            guard summary.range == expectedRange else {
                throw CLIMachineValueValidation.contractFailure(reason: "requestPayloadMismatch")
            }
            guard (summary.eventCountBySource?.count ?? 0)
                <= invocation.options.limits.maxEvents
            else { throw CLIMachineValueValidation.limitFailure() }
            try validateSummaryCounts(
                summary,
                rowLimit: invocation.options.limits.maxRows,
                eventLimit: invocation.options.limits.maxEvents
            )
            return try traceEnvelope(
                metadata: metadata,
                preparation: snapshot.preparation,
                tool: tool,
                request: request,
                limits: limits,
                result: .summary(try CLIMachineSummaryResult(summary)),
                quality: summary.dataQuality,
                truncationSections: summary.truncatedSections.map(\.rawValue)
            )
        case (.processes(let snapshot, let page),
              .processes(_, let pid, let name, let requestedLimit)):
            let metadata = snapshot.metadata
            try validateItemCount(
                page.items.count,
                requestedLimit: requestedLimit,
                globalLimit: invocation.options.limits.maxRows,
                truncated: page.truncated
            )
            guard page.items.allSatisfy({
                (pid == nil || $0.pid == pid) && (name == nil || $0.name == name)
            }) else {
                throw CLIMachineValueValidation.contractFailure(reason: "requestPayloadMismatch")
            }
            return try traceEnvelope(
                metadata: metadata,
                preparation: snapshot.preparation,
                tool: tool,
                request: request,
                limits: limits,
                result: .processes(try CLIMachineProcessesResult(page)),
                quality: TraceDataQuality(
                    warnings: metadata.dataQuality.warnings,
                    issues: metadata.dataQuality.issues + page.dataQualityIssues
                ),
                truncationSections: page.truncated ? ["processes"] : []
            )
        case (.threads(let snapshot, let page),
              .threads(
                _, let processKey, let pid, let threadKey, let tid, let name,
                let requestedLimit
              )):
            let metadata = snapshot.metadata
            try validateItemCount(
                page.items.count,
                requestedLimit: requestedLimit,
                globalLimit: invocation.options.limits.maxRows,
                truncated: page.truncated
            )
            guard page.items.allSatisfy({
                (processKey == nil || $0.processKey?.ipid == processKey)
                    && (pid == nil || $0.pid == pid)
                    && (threadKey == nil || $0.key.itid == threadKey)
                    && (tid == nil || $0.tid == tid)
                    && (name == nil || $0.name == name)
            }) else {
                throw CLIMachineValueValidation.contractFailure(reason: "requestPayloadMismatch")
            }
            return try traceEnvelope(
                metadata: metadata,
                preparation: snapshot.preparation,
                tool: tool,
                request: request,
                limits: limits,
                result: .threads(try CLIMachineThreadsResult(page)),
                quality: TraceDataQuality(
                    warnings: metadata.dataQuality.warnings,
                    issues: metadata.dataQuality.issues + page.dataQualityIssues
                ),
                truncationSections: page.truncated ? ["threads"] : []
            )
        case (.query(let snapshot, let result), .query(_, let options)):
            guard result.view == options.view, result.range == options.range,
                result.filters == options.filters,
                result.eventCount <= options.limit
            else {
                throw CLIMachineValueValidation.contractFailure(
                    reason: "requestPayloadMismatch"
                )
            }
            return try traceEnvelope(
                metadata: snapshot.metadata,
                preparation: snapshot.preparation,
                tool: tool,
                request: request,
                limits: limits,
                result: .query(try CLIMachineAgentQueryResult(result)),
                quality: result.dataQuality,
                truncationSections: result.truncated ? [options.view.cliName] : []
            )
        case (.context(let snapshot, let context), .context(_, let options)):
            let requestedRange = try expectedContextRange(
                options.time, durationNs: snapshot.metadata.durationNs
            )
            let directoryCount = checkedTotal([
                context.processes.count, context.threads.count,
            ])
            let eventCount = checkedTotal(
                [
                    context.cpuSlices.count,
                    context.threadStates.count,
                    context.slices.count,
                ] + context.counters.map(\.samples.count)
            )
            guard context.range == requestedRange,
                context.filters == options.filters,
                directoryCount != nil,
                directoryCount! <= invocation.options.limits.maxRows,
                eventCount != nil,
                eventCount! <= invocation.options.limits.maxEvents
            else {
                throw CLIMachineValueValidation.contractFailure(
                    reason: "requestPayloadMismatch"
                )
            }
            let sections = contextTruncationSections(context.truncation)
            return try traceEnvelope(
                metadata: snapshot.metadata,
                preparation: snapshot.preparation,
                tool: tool,
                request: request,
                limits: limits,
                result: .context(try CLIMachineContextResult(context)),
                quality: context.dataQuality,
                truncationSections: sections
            )
        case (.analyze(let snapshot, let kind, let analysis),
              .analyze(_, let options)):
            let expectedRange = try options.range
                ?? TraceTimeRange.query(
                    startNs: 0, endNs: snapshot.metadata.durationNs
                )
            let expectedTimeout = Duration.milliseconds(limits.timeoutMs).components
            let returnedRows = checkedTotal([
                analysis.cpuUtilization.count,
                analysis.topProcesses.count,
                analysis.topThreads.count,
                analysis.longSlices.count,
                analysis.threadStateDistribution.count,
                analysis.schedulingLatency.topSamples.count,
                analysis.hotIntervals.count,
            ])
            guard kind == options.kind, analysis.range == expectedRange,
                analysis.parameters.filters == options.filters,
                analysis.parameters.maximumCPUSlices == limits.maxEvents,
                analysis.parameters.maximumProcessSlices == limits.maxEvents,
                analysis.parameters.maximumThreadSlices == limits.maxEvents,
                analysis.parameters.maximumStateIntervals == limits.maxEvents,
                analysis.parameters.maximumNamedSlices == limits.maxEvents,
                analysis.parameters.maximumSchedulingEvents == limits.maxEvents,
                analysis.parameters.maximumHotEvents == limits.maxEvents,
                analysis.parameters.minimumLongSliceDurationNs == options.thresholdNs,
                analysis.parameters.topProcessLimit == options.limit,
                analysis.parameters.topThreadLimit == options.limit,
                analysis.parameters.longSliceLimit == options.limit,
                analysis.parameters.schedulingSampleLimit == options.limit,
                analysis.parameters.hotIntervalLimit == options.limit,
                analysis.parameters.hotBucketCount == 100,
                analysis.parameters.timeoutSeconds == expectedTimeout.seconds,
                analysis.parameters.timeoutAttoseconds == expectedTimeout.attoseconds,
                returnedRows != nil,
                returnedRows! <= limits.maxRows
            else {
                throw CLIMachineValueValidation.contractFailure(
                    reason: "requestPayloadMismatch"
                )
            }
            return try traceEnvelope(
                metadata: snapshot.metadata,
                preparation: snapshot.preparation,
                tool: tool,
                request: request,
                limits: limits,
                result: .analyze(
                    try CLIMachineAnalyzeResult(kind: kind, analysis: analysis)
                ),
                quality: analysis.dataQuality,
                truncationSections: analysisTruncationSections(analysis.sections)
            )
        default:
            throw CLIMachineValueValidation.contractFailure(reason: "requestPayloadMismatch")
        }
    }

    private func checkedTotal(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }

    private func expectedContextRange(
        _ selection: TraceContextTimeSelection,
        durationNs: Int64
    ) throws -> TraceTimeRange {
        switch selection {
        case .range(let range): return range
        case .timestamp(let timestamp, let before, let after):
            let start = timestamp >= before ? timestamp - before : 0
            let (candidateEnd, overflow) = timestamp.addingReportingOverflow(after)
            return try TraceTimeRange.query(
                startNs: start,
                endNs: min(durationNs, overflow ? .max : candidateEnd)
            )
        }
    }

    private func contextTruncationSections(
        _ value: TraceContextTruncation
    ) -> [String] {
        var sections: [String] = []
        if value.processes.truncated { sections.append("processes") }
        if value.threads.truncated { sections.append("threads") }
        if value.cpuSlices.truncated { sections.append("cpuSlices") }
        if value.threadStates.truncated { sections.append("threadStates") }
        if value.slices.truncated { sections.append("slices") }
        if value.counters.truncated { sections.append("counters") }
        if value.summary.truncated { sections.append("summary") }
        if value.referenceOmittedByBudget { sections.append("references") }
        return sections
    }

    private func analysisTruncationSections(
        _ value: TraceDeterministicAnalysisSections
    ) -> [String] {
        var sections: [String] = []
        if value.cpuUtilization.truncated { sections.append("cpuUtilization") }
        if value.topProcesses.truncated { sections.append("topProcesses") }
        if value.topThreads.truncated { sections.append("topThreads") }
        if value.longSlices.truncated { sections.append("longSlices") }
        if value.threadStateDistribution.truncated {
            sections.append("threadStateDistribution")
        }
        if value.schedulingLatency.truncated { sections.append("schedulingLatency") }
        if value.hotIntervals.truncated { sections.append("hotIntervals") }
        return sections
    }

    fileprivate static func validate(
        metadata: TraceMetadata,
        preparation: TraceDatabasePreparationResult
    ) throws {
        guard metadata.schemaFingerprint == preparation.schemaFingerprint else {
            throw CLIMachineValueValidation.contractFailure(reason: "provenanceMismatch")
        }
        _ = try CLIMachineTrace(metadata: metadata)
        _ = try CLIMachineProvenance(parser: metadata.parser, preparation: preparation)
        _ = try CLIMachineDataQuality(metadata.dataQuality)
    }

    private static func validateSummaryCapabilityContract(
        _ summary: TraceSummary
    ) throws {
        let capabilities = summary.capabilities
        guard (summary.cpuCount != nil) == capabilities.cpuScheduling,
            (summary.cpuSliceCount != nil) == capabilities.cpuScheduling,
            (summary.threadStateCount != nil) == capabilities.threadStates,
            (summary.namedSliceCount != nil) == capabilities.namedSlices,
            (summary.counterSeriesCount != nil)
                == (capabilities.cpuCounters || capabilities.processCounters)
        else {
            throw CLIMachineValueValidation.contractFailure(
                reason: "capabilityNullabilityMismatch"
            )
        }

        let truncated = Set(summary.truncatedSections)
        guard !truncated.contains(.cpuCount) || capabilities.cpuScheduling,
            !truncated.contains(.cpuSliceCount) || capabilities.cpuScheduling,
            !truncated.contains(.threadStateCount) || capabilities.threadStates,
            !truncated.contains(.namedSliceCount) || capabilities.namedSlices,
            !truncated.contains(.counterSeriesCount)
                || capabilities.cpuCounters || capabilities.processCounters,
            !truncated.contains(.eventCountBySource)
                || summary.eventCountBySource != nil
        else {
            throw CLIMachineValueValidation.contractFailure(
                reason: "unavailableSectionTruncated"
            )
        }
    }

    private static func validateProcesses(
        _ items: [TraceProcess],
        durationNs: Int64
    ) throws {
        var identities: Set<ProcessKey> = []
        var previous: (pid: Int64, key: Int64)?
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 1_024), Task.isCancelled { throw CancellationError() }
            _ = try CLIMachineProcess(item)
            guard identities.insert(item.key).inserted,
                validRange(start: item.startNs, end: item.endNs, durationNs: durationNs)
            else {
                throw CLIMachineValueValidation.contractFailure(reason: "invalidProcessPage")
            }
            let order = (item.pid, item.key.ipid)
            if let previous,
                order.0 < previous.pid || (order.0 == previous.pid && order.1 < previous.key)
            {
                throw CLIMachineValueValidation.contractFailure(reason: "unstableProcessOrder")
            }
            previous = order
        }
    }

    private static func validateThreads(
        _ items: [TraceThread],
        durationNs: Int64
    ) throws {
        var identities: Set<ThreadKey> = []
        var previous: (nilPID: Bool, pid: Int64, tid: Int64, key: Int64)?
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 1_024), Task.isCancelled { throw CancellationError() }
            _ = try CLIMachineThread(item)
            guard identities.insert(item.key).inserted,
                validRange(start: item.startNs, end: item.endNs, durationNs: durationNs)
            else {
                throw CLIMachineValueValidation.contractFailure(reason: "invalidThreadPage")
            }
            let order = (item.pid == nil, item.pid ?? 0, item.tid, item.key.itid)
            if let previous {
                guard !threadOrderLess(order, previous) else {
                    throw CLIMachineValueValidation.contractFailure(
                        reason: "unstableThreadOrder"
                    )
                }
            }
            previous = order
        }
    }

    private static func threadOrderLess(
        _ lhs: (nilPID: Bool, pid: Int64, tid: Int64, key: Int64),
        _ rhs: (nilPID: Bool, pid: Int64, tid: Int64, key: Int64)
    ) -> Bool {
        if lhs.nilPID != rhs.nilPID { return !lhs.nilPID && rhs.nilPID }
        if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
        if lhs.tid != rhs.tid { return lhs.tid < rhs.tid }
        return lhs.key < rhs.key
    }

    private static func validRange(
        start: Int64?,
        end: Int64?,
        durationNs: Int64
    ) -> Bool {
        guard start == nil || (0...durationNs).contains(start!),
            end == nil || (0...durationNs).contains(end!)
        else { return false }
        guard let start, let end else { return true }
        return start <= end
    }

    private func validateSummaryCounts(
        _ summary: TraceSummary,
        rowLimit: Int,
        eventLimit: Int
    ) throws {
        let directoryCounts = [summary.processCount, summary.threadCount].compactMap { $0 }
        let eventCounts = [
            summary.cpuCount, summary.cpuSliceCount, summary.threadStateCount,
            summary.namedSliceCount, summary.counterSeriesCount,
        ].compactMap { $0 }
        // Section row budgets cap sampled identities/rows. A stat row's
        // aggregate `count`, however, is domain data and may legitimately be
        // greater than the number of sampled rows.
        guard directoryCounts.allSatisfy({ $0 <= Int64(rowLimit) }),
            eventCounts.allSatisfy({ $0 <= Int64(eventLimit) })
        else { throw CLIMachineValueValidation.limitFailure() }
    }

    /// Conservative pre-encoding lower bound for executor-controlled dynamic
    /// data. Rejection is therefore sound (the exact encoding cannot fit),
    /// while the final encoder remains authoritative at the byte boundary.
    /// Together with field/item caps, this also bounds worst-case escaping.
    private func preflight(maximumBytes: Int) throws {
        var cost = 0
        func add(_ amount: Int) throws {
            let (next, overflow) = cost.addingReportingOverflow(amount)
            guard !overflow, next <= maximumBytes else {
                throw CLIMachineValueValidation.limitFailure()
            }
            cost = next
        }
        func addString(_ value: String?) throws {
            guard let value else { return }
            try add(value.utf8.count)
        }
        func addMetadata(_ metadata: TraceMetadata) throws {
            try addString(metadata.parser.name)
            try addString(metadata.parser.reportedVersion)
            try addString(metadata.parser.upstreamRevision)
            try addString(metadata.parser.adapterVersion)
            try addString(metadata.parser.buildRecipeVersion)
            for issue in metadata.dataQuality.issues {
                try add(2)
                try addString(issue.scope)
                try addString(issue.message)
            }
        }

        switch storage {
        case .doctor(let result, _):
            for check in result.checks {
                try add(2)
                try addString(check.code)
                try addString(check.name)
            }
        case .inspect(let snapshot, _):
            try addMetadata(snapshot.metadata)
            try addString(snapshot.preparation.schemaAdapterVersion)
        case .summary(let snapshot, let summary):
            try addMetadata(snapshot.metadata)
            try addString(snapshot.preparation.schemaAdapterVersion)
            for issue in summary.dataQuality.issues where
                !snapshot.metadata.dataQuality.issues.contains(issue)
            {
                try add(2)
                try addString(issue.scope)
                try addString(issue.message)
            }
            for item in summary.eventCountBySource ?? [] {
                try add(2)
                try addString(item.source)
            }
        case .processes(let snapshot, let page):
            try addMetadata(snapshot.metadata)
            try addString(snapshot.preparation.schemaAdapterVersion)
            for item in page.items {
                try add(2)
                try addString(item.name)
            }
        case .threads(let snapshot, let page):
            try addMetadata(snapshot.metadata)
            try addString(snapshot.preparation.schemaAdapterVersion)
            for item in page.items {
                try add(2)
                try addString(item.name)
                try addString(item.processName)
            }
        case .query(let snapshot, let result):
            try addMetadata(snapshot.metadata)
            try addString(snapshot.preparation.schemaAdapterVersion)
            try add(result.eventCount * 2)
            for item in result.cpuSlices {
                try addString(item.threadName)
                try addString(item.processName)
                try addString(item.endState)
            }
            for item in result.threadStates {
                try addString(item.state)
                try addString(item.threadName)
                try addString(item.processName)
            }
            for item in result.slices {
                try addString(item.name)
                try addString(item.category)
                try addString(item.threadName)
                try addString(item.processName)
            }
            for item in result.counters {
                try addString(item.name)
                try addString(item.processName)
                try addString(item.unit)
            }
        case .context(let snapshot, let context):
            try addMetadata(snapshot.metadata)
            try addString(snapshot.preparation.schemaAdapterVersion)
            try add(
                (context.processes.count + context.threads.count
                    + context.cpuSlices.count + context.threadStates.count
                    + context.slices.count + context.counters.count) * 2
            )
        case .analyze(let snapshot, _, let analysis):
            try addMetadata(snapshot.metadata)
            try addString(snapshot.preparation.schemaAdapterVersion)
            try add(
                (analysis.cpuUtilization.count + analysis.topProcesses.count
                    + analysis.topThreads.count + analysis.longSlices.count
                    + analysis.threadStateDistribution.count
                    + analysis.schedulingLatency.topSamples.count
                    + analysis.hotIntervals.count) * 2
            )
        }
    }

    private func traceEnvelope(
        metadata: TraceMetadata,
        preparation: TraceDatabasePreparationResult,
        tool: CLIMachineTool,
        request: CLIMachineRequest,
        limits: CLIMachineLimits,
        result: CLIMachineCommandResult,
        quality: TraceDataQuality,
        truncationSections: [String]
    ) throws -> CLIMachineSuccessEnvelope<CLIMachineCommandResult> {
        CLIMachineSuccessEnvelope(
            tool: tool,
            trace: try CLIMachineTrace(metadata: metadata),
            request: request,
            limits: limits,
            result: result,
            dataQuality: try CLIMachineDataQuality(quality),
            truncation: try CLIMachineTruncation(sections: truncationSections),
            provenance: try CLIMachineProvenance(
                parser: metadata.parser,
                preparation: preparation
            )
        )
    }

    private func validateItemCount(
        _ count: Int,
        requestedLimit: Int,
        globalLimit: Int,
        truncated: Bool
    ) throws {
        guard count <= requestedLimit, count <= globalLimit,
            !truncated || count == requestedLimit
        else {
            throw CLIMachineValueValidation.limitFailure()
        }
    }
}

private enum CLIMachineValueValidation {
    static func requireBoundedText(_ value: String, maximumBytes: Int) throws {
        guard !value.isEmpty, value.utf8.count <= maximumBytes else {
            throw contractFailure(reason: "unboundedText")
        }
    }

    static func requireBoundedOptionalText(
        _ value: String?,
        maximumBytes: Int
    ) throws {
        guard let value else { return }
        try requireBoundedText(value, maximumBytes: maximumBytes)
    }

    static func requireSafeIdentifier(_ value: String, maximumBytes: Int) throws {
        guard !value.isEmpty, value.utf8.count <= maximumBytes,
            value.utf8.allSatisfy({
                ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z"))
                    || ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z"))
                    || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                    || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-")
                    || $0 == UInt8(ascii: ".")
            })
        else { throw contractFailure(reason: "unsafeIdentifier") }
    }

    static func contractFailure(reason: String) -> ArkTraceError {
        ArkTraceError(
            code: .internalError,
            stage: .encoding,
            message: "Machine payload violates the encoding contract",
            details: ["reason": reason]
        )
    }

    static func limitFailure() -> ArkTraceError {
        ArkTraceError(
            code: .outputLimitExceeded,
            stage: .encoding,
            message: "Machine payload exceeds its item budget",
            retryable: true
        )
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeNullable<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value { try encode(value, forKey: key) }
        else { try encodeNil(forKey: key) }
    }
}

package struct CLIMachineSuccessEnvelope<Result: Encodable & Sendable>: Encodable, Sendable {
    package let schemaVersion: CLIMachineSchemaVersion
    package let tool: CLIMachineTool
    package let trace: CLIMachineTrace?
    package let request: CLIMachineRequest
    package let limits: CLIMachineLimits
    package let result: Result
    package let dataQuality: CLIMachineDataQuality
    package let truncation: CLIMachineTruncation
    package let provenance: CLIMachineProvenance?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case tool
        case trace
        case request
        case limits
        case result
        case dataQuality
        case truncation
        case provenance
    }

    init(
        tool: CLIMachineTool,
        trace: CLIMachineTrace?,
        request: CLIMachineRequest,
        limits: CLIMachineLimits,
        result: Result,
        dataQuality: CLIMachineDataQuality,
        truncation: CLIMachineTruncation,
        provenance: CLIMachineProvenance?
    ) {
        schemaVersion = .current
        self.tool = tool
        self.trace = trace
        self.request = request
        self.limits = limits
        self.result = result
        self.dataQuality = dataQuality
        self.truncation = truncation
        self.provenance = provenance
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(tool, forKey: .tool)
        if let trace { try container.encode(trace, forKey: .trace) }
        else { try container.encodeNil(forKey: .trace) }
        try container.encode(request, forKey: .request)
        try container.encode(limits, forKey: .limits)
        try container.encode(result, forKey: .result)
        try container.encode(dataQuality, forKey: .dataQuality)
        try container.encode(truncation, forKey: .truncation)
        if let provenance { try container.encode(provenance, forKey: .provenance) }
        else { try container.encodeNil(forKey: .provenance) }
    }
}

package struct CLIMachineError: Hashable, Codable, Sendable {
    package let code: ArkTraceError.Code
    package let message: String
    package let retryable: Bool
    package let stage: ArkTraceError.Stage
    package let details: [String: CLIJSONValue]

    package init(_ error: ArkTraceError) {
        let error = error.normalizedForPublicContract()
        code = error.code
        message = Self.canonicalMessage(for: error.code)
        retryable = error.retryable
        stage = error.stage
        details = Dictionary(uniqueKeysWithValues: error.details.keys.sorted().prefix(16).compactMap {
            key -> (String, CLIJSONValue)? in
            guard Self.allowedDetailKeys(for: error.code).contains(key),
                let value = error.details[key],
                Self.safeDetailValue(value, key: key)
            else { return nil }
            return (key, .string(value))
        })
    }

    private static func canonicalMessage(for code: ArkTraceError.Code) -> String {
        switch code {
        case .invalidArgument: "The request arguments are invalid."
        case .traceFileNotFound: "The trace file was not found."
        case .traceFileUnreadable: "The trace file is not readable."
        case .traceFormatUnsupported: "The trace format is not supported."
        case .traceStreamerUnavailable: "The pinned trace parser is unavailable."
        case .traceStreamerIdentityMismatch: "The trace parser identity is invalid."
        case .traceParseFailed: "The trace could not be parsed."
        case .traceSchemaUnsupported: "The parsed trace schema is not supported."
        case .traceDatabaseInvalid: "The parsed trace database is invalid."
        case .traceCacheCorrupt: "The trace cache entry is invalid."
        case .queryFailed: "The trace query failed."
        case .queryTimeout: "The trace operation reached its deadline."
        case .queryLimitExceeded: "The trace query exceeded its row budget."
        case .outputLimitExceeded: "The machine output exceeded its byte budget."
        case .analysisUnsupported: "The requested analysis is not supported."
        case .cancelled: "The trace operation was cancelled."
        case .internalError: "ArkTrace encountered an internal error."
        }
    }

    private static func allowedDetailKeys(for code: ArkTraceError.Code) -> Set<String> {
        switch code {
        case .invalidArgument:
            ["reason"]
        case .traceStreamerIdentityMismatch:
            ["field", "reason"]
        case .traceParseFailed, .traceCacheCorrupt:
            // underlyingCode preserves the stable code of a failure whose
            // cleanup-outranks policy replaced it at the throw site.
            ["reason", "underlyingCode"]
        case .traceDatabaseInvalid:
            // Producers attach sqliteCode (TraceDatabase open/step failures)
            // and rowCount (trace_range shape evidence); stripping them left
            // details always empty for this code.
            ["reason", "rowCount", "sqliteCode"]
        case .internalError:
            ["reason"]
        case .traceSchemaUnsupported:
            ["missingCapability", "reason", "rowCount"]
        case .queryFailed, .queryTimeout, .queryLimitExceeded:
            ["reason", "sqliteCode"]
        case .outputLimitExceeded:
            ["maximumBytes", "requiredBytes"]
        case .traceFileNotFound, .traceFileUnreadable, .traceFormatUnsupported,
             .traceStreamerUnavailable, .analysisUnsupported, .cancelled:
            []
        }
    }

    private static func safeDetailValue(_ value: String, key: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128,
            !value.contains("/"), !value.contains("\\"),
            !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else { return false }

        if ["sqliteCode", "rowCount", "maximumBytes", "requiredBytes"].contains(key) {
            return Int64(value) != nil
        }
        if key == "reason" {
            return stableReasonTokens.contains(value)
        }
        if key == "underlyingCode" {
            return ArkTraceError.Code(rawValue: value) != nil
        }
        if key == "field" {
            return [
                "adapterVersion", "architecture", "binarySHA256", "buildRecipeVersion",
                "name", "reportedVersion", "upstreamRepository", "upstreamRevision",
            ].contains(value)
        }
        if key == "missingCapability" {
            return [
                "cpuScheduling", "threadStates", "namedSlices", "cpuCounters",
                "processCounters",
            ].contains(value)
        }
        return false
    }

    private static let stableReasonTokens: Set<String> = [
        "alreadyExists", "cacheCleanupFailed", "cacheIO", "cacheProvenanceMismatch",
        "capabilityNullabilityMismatch", "directorySync", "directorySyncOpen",
        "duplicateOrUnstableEventSource", "executableChanged",
        "executableIdentityMismatch", "executableOpenFailed", "executableReadFailed",
        "executableStatFailed", "fileSync", "fileSyncOpen", "forbiddenField",
        "identityCleanupFailed", "inUse", "invalidBinary", "invalidDocument",
        "invalidField", "invalidIndexVersion", "invalidName", "invalidProcessPage",
        "invalidProcessValue", "invalidProvenance", "invalidRetryability", "invalidStage",
        "invalidSummaryValue", "invalidThreadPage", "invalidThreadValue",
        "invalidToolIdentity", "invalidURL", "malformed", "mappedExecutableInvalid",
        "mappedExecutablePathInvalid", "mappedExecutableProbeFailed",
        "mappedExecutableUnavailable", "metadataTooLarge", "metadataWrite", "mismatch",
        "missingToolIdentity", "missingTypedPayload", "negativeCount",
        "nonIntegerNanoseconds", "notExecutable", "notRegular", "occupied",
        "parentUnavailable", "parseIdentityChanged", "preparationIdentityChanged",
        "prepareStaging", "privateValidationFailed", "promotedFileChanged",
        "promotedValidationFailed", "promotionFailed", "provenanceMismatch",
        "readyIdentityProbeFailed", "readyQuarantineFailed", "readyRemovalFailed",
        "readyRollbackFailed", "replacementRestoreFailed", "requestPayloadMismatch",
        "sameAsSource", "sessionCleanupFailed", "sessionIO",
        "sessionProvenanceMismatch", "signalMonitorSetup", "snapshotIO",
        "sourceSnapshotChanged",
        "stagingCleanupFailed", "stagingIO", "summaryProvenanceMismatch",
        "unavailable", "unavailableSectionTruncated", "unboundedText",
        "unknownDoctorCheck", "unreadable", "unreported", "unsafeDiagnostic",
        "unsafeIdentifier", "unstableProcessOrder", "unstableThreadOrder", "unsupported",
        "verifySourceSnapshot", "vmStepBudgetExceeded",
    ]
}

package struct CLIMachineErrorEnvelope: Encodable, Sendable {
    package let schemaVersion: CLIMachineSchemaVersion
    package let tool: CLIMachineTool
    package let request: CLIMachineRequest
    package let error: CLIMachineError

    package init(
        tool: CLIMachineTool,
        request: CLIMachineRequest,
        error: ArkTraceError
    ) {
        schemaVersion = .current
        self.tool = tool
        self.request = request
        self.error = CLIMachineError(error)
    }
}
