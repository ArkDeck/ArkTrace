#if ARKTRACE_NATIVE_RUNTIME && ARKTRACE_RUST_PROCESS_FIXTURES
import AppKit
import ArkTraceCore
@testable import ArkTraceRustRuntime
@testable import ArkTraceRendering
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import XCTest

private enum ProcessCounterHitHarness {
    struct Input: Decodable, Sendable {
        let source: String; let helper: String; let parser: String
        let helperSHA256: String; let parserIdentity: TraceParserIdentity; let runtimeRoot: String
    }
    struct Context: Sendable { let engine: RustEngine; let repository: RustTraceRepository; let opening: Counts; let namespace: URL }
    struct Counts: Codable, Equatable, Sendable {
        let bytes: Int; let owners: Int; let stagingBytes: Int; let stagingOwners: Int; let sessions: Int; let requests: Int
    }
    struct HitValue: Codable, Equatable, Sendable {
        let event: EventKey?; let densitySource: TimelineTrackSource?; let densityTrack: TimelineTrackID?
        let bucket: TraceTimeRange?; let timeNs: Int64?
    }
    struct Probe: Codable, Sendable {
        let scene: Int; let kind: String; let point: CGPoint; let expected: HitValue
    }
    enum Failure: Error { case missingOwner, missingScene, deadline, fixtureNeedsProcessCounter,
        snapshotParity, hitParity, unexpectedNilHit, busyExhausted, attemptBudget, oversizedRecord }
    struct Selected: Codable, Sendable { let name: String; let source: TimelineTrackSource; let discoveredEvent: EventKey? }
    struct Discovery: Codable, Sendable { let kind: String; let rows: Int; let available: Bool; let truncated: Bool; let quality: TraceDataQuality }
    struct HitRead: Codable, Sendable {
        let label: String; let point: CGPoint; let expected: HitValue; let actual: HitValue
        let attempts: Int; let busy: Int; let threadID: UInt64; let enteredNs: UInt64; let returnedNs: UInt64
    }
    struct Attempt: Codable, Sendable { let index: Int; let label: String; let attempt: Int; let status: String; let error: String? }
    actor Journal {
        private var attempts: [Attempt]=[]; private var started=0; private var nativeLoads=0; private var referenceLoads=0
        func loadEntered(native:Bool) { if native { nativeLoads+=1 } else { referenceLoads+=1 } }
        func loads() -> [Int] { [nativeLoads,referenceLoads] }
        func begin() throws -> Int { guard started<64 else { throw Failure.attemptBudget }; started+=1; return started }
        func finish(_ record: Attempt) { attempts.append(record) }
        func all() -> [Attempt] { attempts }
    }
    @MainActor final class Held { var values: [TimelineSnapshot]=[]; func clear() { values.removeAll() } }
    static func counts(_ engine: RustEngine) async -> Counts {
        let c=RustEngine.developmentColdStorageCounts(), l=await engine.developmentLifecycleCounts()
        return Counts(bytes:c.bytes,owners:c.owners,stagingBytes:c.stagingBytes,stagingOwners:c.stagingOwners,sessions:l.sessions,requests:l.requests)
    }
    @concurrent static func open(_ input: Input) async throws -> Context {
        let namespace=URL(filePath:input.runtimeRoot).appendingPathComponent("cross-source")
        try FileManager.default.createDirectory(at:namespace,withIntermediateDirectories:true,attributes:[.posixPermissions:NSNumber(value:0o700)])
        let config=RustConfiguration.developmentFixture(namespace:namespace,helper:URL(filePath:input.helper),parser:URL(filePath:input.parser),
            helperSHA256:input.helperSHA256,parserIdentity:input.parserIdentity)
        try emit("configuration",try object(config))
        let engine=try await RustEngine.createDevelopmentFixture(config)
        do {
            print("A39_OPEN_ENTER");let session=try await engine.open(URL(filePath:input.source),format:.htrace,timeoutMilliseconds:8000)
            let repository=try await RustTraceRepository.create(session:session,sourceFormat:.htrace,operationTimeoutMilliseconds:5000)
            try await RustCleanup.flush();return Context(engine:engine,repository:repository,opening:await counts(engine),namespace:namespace)
        } catch {
            let original=error;var errors:[String]=[],shutdown=false
            do { try await engine.shutdown();shutdown=true } catch { errors.append(String(reflecting:error)) }
            do { try await RustCleanup.flush() } catch { errors.append(String(reflecting:error)) }
            try emit("open-failure-cleanup",["firstError":String(reflecting:original),"cleanupErrors":errors,
                "engineShutdown":shutdown,"nativeAfterEngineRelease":NSNull(),"final":try object(await counts(engine))])
            throw original
        }
    }
    static func value(_ event: EventKey?) -> HitValue { HitValue(event:event,densitySource:nil,densityTrack:nil,bucket:nil,timeNs:nil) }
    static func value(_ hit: TimelineDensityHit?,_ scene: TimelineSnapshot) throws -> HitValue {
        guard let hit else { return HitValue(event:nil,densitySource:nil,densityTrack:nil,bucket:nil,timeNs:nil) }
        guard let descriptor=scene.tracks.first(where:{$0.descriptor.id==hit.trackID})?.descriptor else { throw Failure.missingScene }
        return HitValue(event:nil,densitySource:descriptor.source,densityTrack:hit.trackID,bucket:hit.bucket,timeNs:hit.timeNs)
    }
    actor QueryLog {
        private var rows: [String] = []
        func record(_ value: String) { rows.append(value) }
        func all() -> [String] { rows }
    }
    // Every query and error is forwarded unchanged. The wrapper changes only
    // the dynamic type so the current loader executes its existing Swift path.
    struct ForwardingRepository: TraceRepositoryProtocol {
        let base: RustTraceRepository
        let log: QueryLog
        var immutableContentIdentity: TraceRepositoryContentIdentity? { base.immutableContentIdentity }
        func metadata() async throws -> TraceMetadata {
            await log.record("metadata")
            return try await base.metadata()
        }
        func processes(_ query: ProcessQuery) async throws -> BoundedPage<TraceProcess> {
            await log.record("processes" + ": " + String(describing: query))
            return try await base.processes(query)
        }
        func threads(_ query: ThreadQuery) async throws -> BoundedPage<TraceThread> {
            await log.record("threads" + ": " + String(describing: query))
            return try await base.threads(query)
        }
        func summaryFacts(_ query: TraceSummaryQuery) async throws -> TraceSummaryFacts {
            await log.record("summaryFacts" + ": " + String(describing: query))
            return try await base.summaryFacts(query)
        }
        func cpuSlices(_ query: CpuSliceQuery) async throws -> TraceEventPage<CpuSlice> {
            await log.record("cpuSlices" + ": " + String(describing: query))
            return try await base.cpuSlices(query)
        }
        func cpuCatalog(_ query: TraceCPUCatalogQuery) async throws -> TraceCPUCatalog {
            await log.record("cpuCatalog" + ": " + String(describing: query))
            return try await base.cpuCatalog(query)
        }
        func threadStates(_ query: ThreadStateQuery) async throws -> TraceEventPage<ThreadStateInterval> {
            await log.record("threadStates" + ": " + String(describing: query))
            return try await base.threadStates(query)
        }
        func slices(_ query: TraceSliceQuery) async throws -> TraceEventPage<TraceSlice> {
            await log.record("slices" + ": " + String(describing: query))
            return try await base.slices(query)
        }
        func arguments(_ query: TraceArgumentQuery) async throws -> TraceEventPage<TraceEventArgument> {
            await log.record("arguments" + ": " + String(describing: query))
            return try await base.arguments(query)
        }
        func frames(_ query: TraceFrameQuery) async throws -> TraceEventPage<TraceFrame> {
            await log.record("frames" + ": " + String(describing: query))
            return try await base.frames(query)
        }
        func counters(_ query: CounterQuery) async throws -> TraceEventPage<CounterSeries> {
            await log.record("counters" + ": " + String(describing: query))
            return try await base.counters(query)
        }
        func counterSeries(_ query: CounterSeriesQuery) async throws -> TraceEventPage<CounterSeriesDescriptor> {
            await log.record("counterSeries" + ": " + String(describing: query))
            return try await base.counterSeries(query)
        }
        func density(_ query: TraceDensityQuery) async throws -> TraceDensityResult {
            await log.record("density" + ": " + String(describing: query))
            return try await base.density(query)
        }
        func eventBatch(_ query: TraceRepositoryEventBatch) async throws -> TraceRepositoryEventBatchResult {
            await log.record("eventBatch" + ": " + String(describing: query))
            return try await base.eventBatch(query)
        }
    }
    @concurrent static func discover(_ repository: RustTraceRepository,_ deadline: ContinuousClock.Instant) async throws -> (TraceTimeRange,[Selected],[Discovery]) {
        try Task.checkCancellation(); guard ContinuousClock.now<deadline else { throw Failure.deadline }
        let metadata=try await repository.metadata(); try emit("metadata",try object(metadata))
        let range=try TraceTimeRange.query(startNs:0,endNs:metadata.durationNs)
        var selected: [Selected]=[], summaries: [Discovery]=[]
        // Metadata and one bounded typed page; identities come from actual DTOs.
        let process=try await repository.counters(CounterQuery(range:range,scope:.process,limit:128,deadline:deadline))
        summaries.append(Discovery(kind:"processCounters",rows:process.items.count,available:process.capabilityAvailable,truncated:process.truncated,quality:process.dataQuality))
        try emitItems("discovery-processCounters",process.items)
        if let row=process.items.first(where:{$0.filterID==0 && $0.processKey?.ipid==1 && !$0.samples.isEmpty}) {
            selected.append(Selected(name:"processCounter",source:.processCounter(filterID:row.filterID,processKey:row.processKey),discoveredEvent:row.samples.first?.key))
        }
        try emit("discovery-summary",["typedDiscoveryRequestsIncludingMetadata":1+summaries.count,"pageLimit":128,
            "range":try object(range),"pages":try object(summaries),"selected":try object(selected),"rawSQL":false,
            "constructedEvents":false,"PIDorTIDUsedAsIdentity":false])
        guard selected.count==1 else { throw Failure.fixtureNeedsProcessCounter }
        return (range,selected,summaries)
    }
    @concurrent static func pair(_ request: ViewportRequest,_ repository: RustTraceRepository,
        _ facade: ForwardingRepository,_ label: String,_ journal: Journal) async throws -> [TimelineSnapshot] {
        await journal.loadEntered(native:true);print("A39_LOAD_ENTER \(label)")
        guard let native=try await NativeTimelineSnapshot.load(request,repository:repository),native.nativeHitOwner != nil else { throw Failure.missingOwner }
        let loader=TimelineSnapshotLoader(); let reference: any TraceRepositoryProtocol=facade
        XCTAssertFalse(reference is RustTraceRepository)
        await journal.loadEntered(native:false);print("A39_REFERENCE_LOAD_ENTER \(label)")
        guard let swift=try await loader.load(request,repository:reference),swift.nativeHitOwner==nil else { throw Failure.missingScene }
        return [native,swift]
    }
    static func encoded<T:Encodable>(_ value:T) throws -> Data {
        let e=JSONEncoder(); e.outputFormatting=[.sortedKeys]; return try e.encode(value)
    }
    static func persistBytes(_ name: String,_ bytes: Data) throws {
        for start in stride(from:0,to:bytes.count,by:24000) {
            try emit(name+"-bytes-"+String(start/24000),["offset":start,"totalByteCount":bytes.count,
                "base64":bytes.subdata(in:start..<min(start+24000,bytes.count)).base64EncodedString()])
        }
    }
    @MainActor final class OracleWindow: NSWindow { override var backingScaleFactor: CGFloat { 1 } }
    @MainActor static func facts(_ scene: TimelineSnapshot) throws -> ([UInt64],[[UInt64]],[[UInt8]],[[UInt8]?]) {
        var doubles=[scene.viewport.nsPerPoint.bitPattern,scene.viewport.widthPoints.bitPattern,scene.viewport.heightPoints.bitPattern,
            scene.viewport.verticalOffsetPoints.bitPattern], geometry:[[UInt64]]=[],colors:[[UInt8]]=[],labels:[[UInt8]?]=[]
        for track in scene.tracks {
            doubles += [track.y.bitPattern,track.height.bitPattern]
            for primitive in track.primitives {
                let frame=TimelineGeometry.frame(for:primitive,in:track,viewport:scene.viewport,backingScale:1)
                geometry.append([Double(frame.minX).bitPattern,Double(frame.minY).bitPattern,Double(frame.width).bitPattern,Double(frame.height).bitPattern])
                let color: TimelineColor
                switch primitive {
                case .detail(let p): color=TimelineDetailPalette.color(for:p);labels.append(p.label.map{Array($0.utf8)})
                case .density(let p):
                    color=p.projection?.color ?? TimelineDensityPalette.color(for:p.bucket,fallback:TimelinePalette.greyColor)
                    if let value=p.bucket.utilization { doubles.append(value.bitPattern) };labels.append(nil)
                }
                colors.append([color.red,color.green,color.blue])
            }
        }
        return (doubles,geometry,colors,labels)
    }
    @MainActor static func oracle(_ reference: TimelineSnapshot,_ detail: Bool) throws -> [(CGPoint,HitValue)] {
        XCTAssertNil(reference.nativeHitOwner)
        let track=try XCTUnwrap(reference.tracks.first)
        guard let primitive=track.primitives.first(where:{!TimelineGeometry.frame(for:$0,in:track,viewport:reference.viewport,backingScale:1).isEmpty}) else { throw Failure.missingScene }
        let geometry=TimelineGeometry.frame(for:primitive,in:track,viewport:reference.viewport,backingScale:1)
        let points=[CGPoint(x:geometry.midX,y:geometry.midY),CGPoint(x:-4,y:geometry.midY)]
        let frame=CGRect(x:0,y:0,width:reference.viewport.widthPoints,height:reference.viewport.heightPoints)
        let view=TimelineNSView(frame:frame); view.snapshot=reference
        let window=OracleWindow(contentRect:frame,styleMask:.borderless,backing:.buffered,defer:false); window.contentView=view
        defer { window.contentView=nil }
        var probes: [(CGPoint,HitValue)]=[]
        for point in points {
            let expected: HitValue=detail ? value(view.event(at:point)) : try value(view.densityBand(at:point),reference)
            probes.append((point,expected))
        }
        if detail { guard let event=probes[0].1.event,event.table == .processMeasure else { throw Failure.unexpectedNilHit } }
        else { guard probes[0].1.bucket != nil else { throw Failure.unexpectedNilHit } }
        return probes
    }
    @concurrent static func nativeReads(_ scene: TimelineSnapshot,_ probes: [(CGPoint,HitValue)],_ detail: Bool,
        _ label: String,_ journal: Journal,_ deadline: ContinuousClock.Instant) async throws -> [HitRead] {
        guard let owner=scene.nativeHitOwner else { throw Failure.missingOwner };var results: [HitRead]=[]
        for (index,probe) in probes.enumerated() {
            var busy=0
            for attempt in 1...4 {
                try Task.checkCancellation();guard ContinuousClock.now<deadline else { throw Failure.deadline }
                let serial=try await journal.begin(),thread=threadID(),entered=DispatchTime.now().uptimeNanoseconds
                let actual: HitValue
                do {
                    actual=detail ? value(try owner.event(at:probe.0,viewport:scene.viewport,backingScale:1))
                        : try value(owner.densityBand(at:probe.0,viewport:scene.viewport,backingScale:1),scene)
                } catch TimelineNativeHitError.busy {
                    busy+=1;await journal.finish(Attempt(index:serial,label:label+"-"+String(index),attempt:attempt,status:"busy",error:"TimelineNativeHitError.busy"))
                    guard attempt<4 else { throw Failure.busyExhausted }
                    try Task.checkCancellation();guard ContinuousClock.now<deadline else { throw Failure.deadline };await Task.yield();continue
                } catch {
                    await journal.finish(Attempt(index:serial,label:label+"-"+String(index),attempt:attempt,status:"error",error:String(reflecting:error)));throw error
                }
                let returned=DispatchTime.now().uptimeNanoseconds
                await journal.finish(Attempt(index:serial,label:label+"-"+String(index),attempt:attempt,status:"success",error:nil))
                results.append(HitRead(label:label+"-"+String(index),point:probe.0,expected:probe.1,actual:actual,
                    attempts:attempt,busy:busy,threadID:thread,enteredNs:entered,returnedNs:returned))
                try emit(label+"-actual-hit-"+String(index),try object(results.last))
                guard actual==probe.1 else { throw Failure.hitParity };break
            }
        }
        return results
    }
    static func threadID() -> UInt64 { var value:UInt64=0;pthread_threadid_np(nil,&value);return value }
    static func object<T:Encodable>(_ value:T) throws -> Any { try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) }
    static func emit(_ name:String,_ value:Any) throws {
        let root=try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_A39_OUTPUT"])
        let data=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]);guard data.count<=65536 else { throw Failure.oversizedRecord }
        try data.write(to:URL(filePath:root).appendingPathComponent(name+".json"),options:.atomic)
    }
    static func emitItems<T:Encodable>(_ name:String,_ values:[T]) throws {
        for start in stride(from:0,to:values.count,by:4) { try emit(name+"-"+String(start/4),try object(Array(values[start..<min(start+4,values.count)]))) }
    }
    @MainActor static func cleanup(_ context:Context,_ held:Held,closed:Bool,shutdown:Bool,_ firstError:String?) async throws -> Counts {
        held.clear();var errors:[String]=[],didClose=closed,didShutdown=shutdown
        do { try await RustCleanup.flush() } catch { errors.append(String(reflecting:error)) }
        if !didClose { do { try await context.repository.close();didClose=true } catch { errors.append(String(reflecting:error)) } }
        var nativeAfterClose: UInt64?
        if didClose && !didShutdown { do { nativeAfterClose=try await context.engine.retainedResultBytes() } catch { errors.append(String(reflecting:error)) } }
        if !didShutdown { do { try await context.engine.shutdown();didShutdown=true } catch { errors.append(String(reflecting:error)) } }
        do { try await RustCleanup.flush() } catch { errors.append(String(reflecting:error)) }
        let final=await counts(context.engine)
        try emit("cleanup",["firstError":firstError.map{$0 as Any} ?? NSNull(),"cleanupErrors":errors,
            "repositoryClosed":didClose,"engineShutdown":didShutdown,"nativeAfterCloseBeforeShutdown":nativeAfterClose.map{$0 as Any} ?? NSNull(),
            "nativeAfterEngineRelease":NSNull(),"final":try object(final)])
        XCTAssertTrue(errors.isEmpty);XCTAssertEqual(final.bytes,0);XCTAssertEqual(final.owners,0);XCTAssertEqual(final.stagingBytes,0)
        XCTAssertEqual(final.stagingOwners,0);XCTAssertEqual(final.sessions,0);XCTAssertEqual(final.requests,0)
        return final
    }
}

@MainActor
final class NativeSnapshotProcessCounterHitParityTests: XCTestCase {
    func testActualProcessCounterMatchesCurrentSwiftLoaderAndHit() async throws {
        typealias H=ProcessCounterHitHarness
        let path=try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_NATIVE_PROCESS_COUNTER_PARITY_INPUT"])
        let input=try JSONDecoder().decode(H.Input.self,from:Data(contentsOf:URL(filePath:path)))
        let context=try await H.open(input),held=H.Held()
        let deadline=ContinuousClock.now.advanced(by:.seconds(12))
        let log=H.QueryLog(),facade=H.ForwardingRepository(base:context.repository,log:log),journal=H.Journal()
        var nativeLoads=0,referenceLoads=0,rows:[[String:Any]]=[];var closed=false,shutdown=false
        do {
            let (range,selected,pages)=try await H.discover(context.repository,deadline)
            for selection in selected {
                for (mode,preference) in [("detail",TimelineDetailPreference.detail),("density",.density)] {
                    let label=selection.name+"-"+mode,generation=UInt64(nativeLoads+1)
                    let viewport=try TimelineViewport(range:range,widthPoints:800,heightPoints:600,generation:generation)
                    let operationDeadline=ContinuousClock.now.advanced(by:.seconds(12))
                    let request=try ViewportRequest(viewport:viewport,tracks:[TrackDescriptor(title:selection.name,source:selection.source)],
                        pixelWidth:800,generation:generation,preference:preference,maximumPrimitives:128,deadline:operationDeadline)
                    nativeLoads+=1;referenceLoads+=1;held.values=try await H.pair(request,context.repository,facade,label,journal)
                    let nativeData=try H.encoded(held.values[0]),swiftData=try H.encoded(held.values[1])
                    try H.persistBytes(label+"-native",nativeData);try H.persistBytes(label+"-swift",swiftData)
                    let nf=try H.facts(held.values[0]),sf=try H.facts(held.values[1])
                    let sameSnapshot=nativeData==swiftData,sameDoubles=nf.0==sf.0,sameGeometry=nf.1==sf.1,sameColors=nf.2==sf.2,sameLabels=nf.3==sf.3
                    try H.emit(label+"-parity",["source":try H.object(selection.source),"discoveredEvent":try H.object(selection.discoveredEvent),
                        "range":try H.object(range),"nativeSnapshotSHA256":SHA256.hash(data:nativeData).map{String(format:"%02x",$0)}.joined(),
                        "swiftSnapshotSHA256":SHA256.hash(data:swiftData).map{String(format:"%02x",$0)}.joined(),
                        "closedSnapshotEqual":sameSnapshot,"doubleBitsEqual":sameDoubles,"geometryBitsEqual":sameGeometry,
                        "colorEqual":sameColors,"labelUTF8Equal":sameLabels,"noQualityNormalization":true])
                    // Record scene differences without substituting for the actual hit oracle.
                    // A39 gates typed detail/density hits; A38 cross-source acceptance stays FAILED.
                    let probes=try H.oracle(held.values[1],mode=="detail")
                    try H.emit(label+"-oracle",try H.object(probes.enumerated().map { H.Probe(scene:Int(generation),kind:mode+"-"+String($0.offset),point:$0.element.0,expected:$0.element.1) }))
                    let hits=try await H.nativeReads(held.values[0],probes,mode=="detail",label,journal,operationDeadline)
                    try H.emit(label+"-hits",try H.object(hits))
                    let success=hits.allSatisfy{$0.actual==$0.expected};XCTAssertTrue(success)
                    rows.append(["label":label,"source":try H.object(selection.source),"closedSnapshotEqual":sameSnapshot,
                        "fullFactsEqual":sameDoubles && sameGeometry && sameColors && sameLabels,"hitCount":hits.count,"hitsEqual":success])
                    held.clear();try await RustCleanup.flush();let dropped=await H.counts(context.engine)
                    XCTAssertEqual(dropped,context.opening);try H.emit(label+"-dropped",try H.object(dropped))
                }
            }
            let final=try await H.cleanup(context,held,closed:closed,shutdown:shutdown,nil);closed=true;shutdown=true
            let actualLoads=await journal.loads();nativeLoads=actualLoads[0];referenceLoads=actualLoads[1]
            let attempts=await journal.all();try H.emit("hit-attempts",try H.object(attempts))
            try H.emit("cross-source",["actualEngineOpens":1,"actualNativeLoads":nativeLoads,"actualReferenceLoads":referenceLoads,
                "actualNativeHitCalls":attempts.count,"actualConsumers":0,"selected":try H.object(selected),"cases":rows,
                "discoveryTypedRequestsIncludingMetadata":1+pages.count,"referenceForwardedQueries":await log.all(),
                "canonical":"unmodified current Swift TimelineSnapshotLoader via A33 pure forwarding facade, then TimelineNSView",
                "independentDatabaseBackend":false,"constructedExpected":false,"finalDropLogicalZero":final.bytes==0 && final.owners==0,
                "final":try H.object(final),"closeExecuted":closed,"shutdownExecuted":shutdown,"nativeAfterEngineRelease":NSNull(),
                "nativeInFlightCancellationClaimed":false,"GUIAcceptance":false])
        } catch {
            let original=error;let actualLoads=await journal.loads();nativeLoads=actualLoads[0];referenceLoads=actualLoads[1]
            _=try await H.cleanup(context,held,closed:closed,shutdown:shutdown,String(reflecting:original))
            try H.emit("failure",["firstError":String(reflecting:original),"actualNativeLoads":nativeLoads,"actualReferenceLoads":referenceLoads,
                "completedCases":rows,"referenceForwardedQueries":await log.all(),"hitAttempts":try H.object(await journal.all())])
            throw original
        }
    }
}
#endif
