import ArkTraceCore
import Foundation

struct RustWireDeadlineQuery: Encodable, Sendable {
    let clock = "hostContinuousEpochV1"
    let deadline: RustWireContinuousDeadline?
    let query: RustRequest
    init(_ query: RustRequest, deadline: ContinuousClock.Instant?) {
        self.query = query; self.deadline = deadline.map(RustWireContinuousDeadline.init)
    }
    private enum CodingKeys: String, CodingKey { case clock, deadline, query }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clock, forKey: .clock)
        // Null directory policy is explicit; synthesized optional encoding
        // would omit this field and hide an incomplete native request.
        try container.encode(deadline, forKey: .deadline)
        try container.encode(query, forKey: .query)
    }
}
package extension RustSession {
    @concurrent func coreProcesses(_ query: ProcessQuery, timeoutMilliseconds: UInt32) async throws -> BoundedPage<TraceProcess> {
        let match: RustNameMatch = switch query.nameMatch { case .exact: .exact; case .prefix: .prefix; case .contains: .contains }
        let wire = RustProcessQuery(processKey: query.processKey?.ipid, pid: query.pid, name: query.name, nameMatch: match, limit: query.limit)
        let result = try await self.query(.queryWithDeadline(RustWireDeadlineQuery(.processes(wire), deadline: query.deadline)), timeoutMilliseconds: timeoutMilliseconds)
        let page = try await result.processPage(identity: identity, limit: query.limit)
        return try await page.copyCorePage()
    }
    @concurrent func coreSummaryFacts(_ query: TraceSummaryQuery, timeoutMilliseconds: UInt32) async throws -> TraceSummaryFacts {
        let wire = RustSummaryQuery(range: query.range, maximumRowsPerSection: query.maximumRowsPerSection, maximumEventsPerSection: query.maximumEventsPerSection)
        let result = try await self.query(.queryWithDeadline(RustWireDeadlineQuery(.summaryFacts(wire), deadline: query.deadline)), timeoutMilliseconds: timeoutMilliseconds)
        let view = try await result.summaryView(identity: identity, query: wire)
        return try await view.copyCoreFacts()
    }
    @concurrent func coreFrames(_ query: TraceFrameQuery, timeoutMilliseconds: UInt32) async throws -> TraceEventPage<TraceFrame> {
        let wire = RustFrameQuery(range: query.range, processKey: query.processKey?.ipid, limit: query.limit)
        let result = try await self.query(.queryWithDeadline(RustWireDeadlineQuery(.frames(wire), deadline: query.deadline)), timeoutMilliseconds: timeoutMilliseconds)
        let page = try await result.eventPage(identity: identity, limit: query.limit, maximumItems: 20_000, type: RustPackedFrame.self,
            record: { RustFrameRecord(lease: $0, index: $1) })
        return try await page.copyCorePage()
    }
    @concurrent func coreArguments(_ query: TraceArgumentQuery, timeoutMilliseconds: UInt32) async throws -> TraceEventPage<TraceEventArgument> {
        let wire = RustArgumentQuery(argSetID: query.argSetID, limit: query.limit)
        let result = try await self.query(.queryWithDeadline(RustWireDeadlineQuery(.arguments(wire), deadline: query.deadline)), timeoutMilliseconds: timeoutMilliseconds)
        let page = try await result.eventPage(identity: identity, limit: query.limit, maximumItems: 64, type: RustPackedArgument.self,
            record: { RustArgumentRecord(lease: $0, index: $1) })
        return try await page.copyCorePage()
    }
}
