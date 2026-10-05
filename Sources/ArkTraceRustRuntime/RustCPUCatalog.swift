import ArkTraceCore
import Foundation

struct RustCPUCatalogQuery: Encodable, Sendable {
    let range: TraceTimeRange
    let limit: Int
    let activityLimit: Int
}

private struct CPUIdentityRecord: RustEventColdRecord {
    static var isQuality: Bool { false }
    var additionalRetainedBytes: Int { 0 }
    let cpu: Int64
    private enum CodingKeys: String, CodingKey { case cpu }
    init(from decoder: any Decoder) throws {
        try rustColdKeys(decoder, ["cpu"])
        cpu = try decoder.container(keyedBy: CodingKeys.self).decode(Int64.self, forKey: .cpu)
    }
}
private struct CPUActivityRecord: RustEventColdRecord {
    static var isQuality: Bool { false }
    var additionalRetainedBytes: Int { 0 }
    let processKey: ProcessKey?
    private enum CodingKeys: String, CodingKey { case processKey }
    init(from decoder: any Decoder) throws {
        try rustColdKeys(decoder, ["processKey"])
        processKey = try decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent(RustWireProcessKey.self, forKey: .processKey)?.value
        guard processKey?.ipid != 0 else { throw RustAdmission.invalidBuffer }
    }
}
private struct CPUCatalogBody: Decodable {
    let cpus: EventWirePage<CPUIdentityRecord>
    let activity: EventWirePage<CPUActivityRecord>
    private enum CodingKeys: String, CodingKey { case cpus, activity }
    init(from decoder: any Decoder) throws {
        try rustColdKeys(decoder, ["cpus", "activity"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cpus = try values.decode(EventWirePage<CPUIdentityRecord>.self, forKey: .cpus)
        activity = try values.decode(EventWirePage<CPUActivityRecord>.self, forKey: .activity)
        guard cpus.capabilityAvailable == activity.capabilityAvailable else { throw RustAdmission.invalidBuffer }
        for (left, right) in zip(cpus.items, cpus.items.dropFirst()) {
            guard left.cpu < right.cpu else { throw RustAdmission.invalidBuffer }
        }
    }
}

enum RustCPUCatalogDecoder {
    @concurrent
    static func decode(_ data: Data, identity: RustSessionIdentity, request: UInt64,
                       query: TraceCPUCatalogQuery) async throws -> TraceCPUCatalog {
        precondition(!Thread.isMainThread)
        try Task.checkCancellation()
        guard identity.engine != 0, identity.session != 0, request != 0 else { throw RustAdmission.invalidBuffer }
        let context = try RustColdContext(limit: query.activityLimit, session: identity.session,
            request: request, inputBytes: data.count, staging: rustColdStaging,
            maximumItems: 20_000, maximumInputBytes: 4 * 1024 * 1024,
            singlePageLimits: ["cpus": query.limit, "activity": query.activityLimit])
        try RustJSONShape.validate(data, staging: rustColdStaging, integerNumbersOnly: true,
            maximumInputBytes: 4 * 1024 * 1024, maximumArrayElements: 20_000)
        let decoder = JSONDecoder(); decoder.userInfo[rustColdContextKey] = context
        let decoded: RustColdEnvelope<CPUCatalogBody>
        do { decoded = try decoder.decode(RustColdEnvelope<CPUCatalogBody>.self, from: data) }
        catch is DecodingError { throw RustAdmission.invalidBuffer }
        func quality(_ issues: [RustPackedQuality]) throws -> TraceDataQuality {
            try TraceDataQuality(machineIssues: issues.map { issue in
                TraceDataQualityIssue(category: issue.category, scope: issue.scope.map {
                    String(decoding: context.bytes[$0], as: UTF8.self)
                }, count: issue.count)
            })
        }
        let result = try TraceCPUCatalog(
            cpus: TraceEventPage(items: decoded.body.cpus.items.map { TraceCPUIdentity(cpu: $0.cpu) },
                truncated: decoded.body.cpus.truncated, capabilityAvailable: decoded.body.cpus.capabilityAvailable,
                dataQuality: quality(decoded.body.cpus.quality)),
            activity: TraceEventPage(items: decoded.body.activity.items.map { TraceCPUActivity(processKey: $0.processKey) },
                truncated: decoded.body.activity.truncated, capabilityAvailable: decoded.body.activity.capabilityAvailable,
                dataQuality: quality(decoded.body.activity.quality))
        )
        try Task.checkCancellation()
        return result
    }
}

package extension RustSession {
    @concurrent
    func coreCPUCatalog(_ query: TraceCPUCatalogQuery, timeoutMilliseconds: UInt32) async throws -> TraceCPUCatalog {
        let wire = RustCPUCatalogQuery(range: query.range, limit: query.limit, activityLimit: query.activityLimit)
        let result = try await self.query(.queryWithDeadline(RustWireDeadlineQuery(.cpuCatalog(wire),
            deadline: query.deadline)), timeoutMilliseconds: timeoutMilliseconds)
        return try await result.cpuCatalog(identity: identity, query: query)
    }
}
