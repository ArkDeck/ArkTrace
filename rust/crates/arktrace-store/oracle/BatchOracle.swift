import ArkTraceCore
@testable import ArkTraceStore
import Foundation

// Actual prepared repository eventBatch, including its concurrent clones.
// This adapter builds typed requests and strips diagnostic quality prose.
struct Query: Decodable, Sendable {
    let range: TraceTimeRange?
    let cpu: Int64?
    let processKey: Int64?
    let pid: Int64?
    let threadKey: Int64?
    let tid: Int64?
    let rawState: String?
    let state: TraceThreadState?
    let name: String?
    let nameMatch: TraceDirectoryNameMatch?
    let minimumDurationNs: Int64?
    let depth: Int64?
    let includesArgumentSet: Bool?
    let eventKey: EventKey?
    let filterID: Int64?
    let limit: Int?
    let source: TraceDensitySource?
    let bucketCount: Int?
    var process: ProcessKey? { processKey.map(ProcessKey.init(ipid:)) }
    var thread: ThreadKey? { threadKey.map(ThreadKey.init(itid:)) }
    func bounds() throws -> (TraceTimeRange, Int) {
        guard let range, let limit else { throw CocoaError(.coderInvalidValue) }
        return (range,limit)
    }
}
struct Input: Decodable, Sendable {
    let cpuSlices: [Query]; let threadStates: [Query]; let slices: [Query]
    let counters: [Query]; let counterSeries: [Query]; let densities: [Query]; let threads: [Query]
    func typed() throws -> TraceRepositoryEventBatch {
        let deadline=ContinuousClock.now.advanced(by: .seconds(30))
        return try TraceRepositoryEventBatch(
            cpuSlices: cpuSlices.map { q in let (range,limit)=try q.bounds()
                return try CpuSliceQuery(range:range,cpu:q.cpu,processKey:q.process,pid:q.pid,
                    threadKey:q.thread,tid:q.tid,limit:limit,deadline:deadline) },
            threadStates: threadStates.map { q in let (range,limit)=try q.bounds()
                return try ThreadStateQuery(range:range,cpu:q.cpu,processKey:q.process,pid:q.pid,
                    threadKey:q.thread,tid:q.tid,rawState:q.rawState,state:q.state,limit:limit,deadline:deadline) },
            slices: slices.map { q in let (range,limit)=try q.bounds()
                let name: TraceSliceNameFilter?=q.name.map { text in
                    switch q.nameMatch ?? .exact { case .exact: TraceSliceNameFilter.exact(text)
                    case .prefix: .prefix(text); case .contains: .contains(text) } }
                return try TraceSliceQuery(range:range,eventKey:q.eventKey,processKey:q.process,pid:q.pid,
                    threadKey:q.thread,tid:q.tid,name:name,minimumDurationNs:q.minimumDurationNs,
                    depth:q.depth,includesArgumentSet:q.includesArgumentSet ?? false,limit:limit,deadline:deadline) },
            counters: counters.map { q in let (range,limit)=try q.bounds()
                let name: CounterNameFilter?=q.name.map { text in
                    switch q.nameMatch ?? .exact { case .exact: CounterNameFilter.exact(text)
                    case .prefix: .prefix(text); case .contains: .contains(text) } }
                return try CounterQuery(range:range,filterID:q.filterID,cpu:q.cpu,processKey:q.process,
                    pid:q.pid,name:name,limit:limit,deadline:deadline) },
            counterSeries: counterSeries.map { q in let (range,limit)=try q.bounds()
                return try CounterSeriesQuery(range:range,limit:limit,deadline:deadline) },
            densities: densities.map { q in
                guard let range=q.range, let source=q.source,let count=q.bucketCount else { throw CocoaError(.coderInvalidValue) }
                return try TraceDensityQuery(range:range,source:source,bucketCount:count,deadline:deadline) },
            threads: threads.map { q in guard let limit=q.limit else { throw CocoaError(.coderInvalidValue) }
                return try ThreadQuery(processKey:q.process,pid:q.pid,threadKey:q.thread,tid:q.tid,
                    name:q.name,nameMatch:q.nameMatch ?? .exact,limit:limit,deadline:deadline) })
    }
}
struct Case: Decodable, Sendable { let id: String; let batch: Input }
struct Context: Decodable, Sendable {
    let parser: TraceParserIdentity; let sourceSHA256: String; let sourceByteCount: Int64
    let databasePreparation: TraceDatabasePreparationResult
}
struct Warning: Encodable {
    let category: TraceDataQualityIssue.Category; let scope: String?; let count: Int64?
    enum CodingKeys: CodingKey { case category,scope,count,message }
    func encode(to encoder: Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(category,forKey:.category);try c.encode(scope,forKey:.scope)
        try c.encode(count,forKey:.count);try c.encodeNil(forKey:.message)
    }
}
struct Quality: Encodable {
    let status: TraceDataQuality.Status;let warnings: [Warning]
    init(_ issues: [TraceDataQualityIssue]) throws {
        guard issues.count<=4096,issues.allSatisfy({ $0.category != .unclassified &&
            ($0.count == nil || $0.count! >= 0) &&
            ($0.scope == nil || TraceDataQualityScope.machineAllowed.contains($0.scope!)) }) else { throw CocoaError(.coderInvalidValue) }
        warnings=issues.map { Warning(category:$0.category,scope:$0.scope,count:$0.count) }.sorted {
            ($0.category.rawValue,$0.scope ?? "",$0.count ?? .min) < ($1.category.rawValue,$1.scope ?? "",$1.count ?? .min) }
        status=warnings.isEmpty ? .ok : .warnings
    }
}
struct Page<T: Encodable & Sendable>: Encodable {
    let items: [T];let truncated: Bool;let capabilityAvailable: Bool;let dataQuality: Quality
    init(_ page: TraceEventPage<T>) throws { items=page.items;truncated=page.truncated
        capabilityAvailable=page.capabilityAvailable;dataQuality=try Quality(page.dataQuality.issues) }
}
struct Density: Encodable {
    let buckets: [TraceDensityBucket];let capabilityAvailable: Bool;let dataQuality: Quality
    init(_ value: TraceDensityResult) throws { buckets=value.buckets;capabilityAvailable=value.capabilityAvailable
        dataQuality=try Quality(value.dataQuality.issues) }
}
struct Directory: Encodable {
    let items: [TraceThread];let truncated: Bool;let dataQualityIssues: [Warning]
    init(_ value: BoundedPage<TraceThread>) throws { items=value.items;truncated=value.truncated
        dataQualityIssues=try Quality(value.dataQualityIssues).warnings }
}
struct Result: Encodable {
    let cpuSlices: [Page<CpuSlice>];let threadStates: [Page<ThreadStateInterval>]
    let slices: [Page<TraceSlice>];let counters: [Page<CounterSeries>]
    let counterSeries: [Page<CounterSeriesDescriptor>];let densities: [Density];let threads: [Directory]
    init(_ value: TraceRepositoryEventBatchResult) throws {
        cpuSlices=try value.cpuSlices.map(Page.init);threadStates=try value.threadStates.map(Page.init)
        slices=try value.slices.map(Page.init);counters=try value.counters.map(Page.init)
        counterSeries=try value.counterSeries.map(Page.init);densities=try value.densities.map(Density.init)
        threads=try value.threads.map(Directory.init)
    }
}
struct Failure: Encodable { let code: ArkTraceError.Code;let stage: ArkTraceError.Stage;let details: [String:String] }
struct Record: Encodable { let id: String;var result: Result?;var error: Failure? }
@main struct BatchOracle {
    static func main() async throws {
        let args=CommandLine.arguments
        let output=try await Task.detached {
            guard args.count==4 else { throw CocoaError(.coderInvalidValue) }
            let decoder=JSONDecoder()
            let context=try decoder.decode(Context.self,from:Data(args[2].utf8))
            let cases=try decoder.decode([Case].self,from:Data(args[3].utf8))
            let repository=try SQLiteTraceRepository(databaseURL:URL(filePath:args[1]),parser:context.parser,
                source:TraceSourceDescriptor(traceSHA256:context.sourceSHA256,sourceByteCount:context.sourceByteCount),
                expectedPreparation:context.databasePreparation)
            var records:[Record]=[]
            for value in cases {
                var record=Record(id:value.id)
                do { record.result=try Result(await repository.eventBatch(value.batch.typed())) }
                catch let error as ArkTraceError { record.error=Failure(code:error.code,stage:error.stage,details:error.details) }
                records.append(record)
            }
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            return try encoder.encode(records)
        }.value
        try FileHandle.standardOutput.write(contentsOf:output)
        try FileHandle.standardOutput.write(contentsOf:Data([10]))
    }
}
