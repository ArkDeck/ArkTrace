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

private enum ConcurrentHitHarness {
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
    struct Read: Codable, Sendable {
        let round: Int; let probe: Int; let threadID: UInt64; let enteredNs: UInt64; let returnedNs: UInt64
        let attempts: Int; let busy: Int; let value: HitValue
    }
    struct Attempt: Codable, Sendable {
        let index: Int; let child: Int; let round: Int; let probe: Int; let attempt: Int
        let threadID: UInt64; let enteredNs: UInt64; let returnedNs: UInt64; let status: String; let error: String?
    }
    struct Consumer: Codable, Sendable { let id: Int; let records: [Read] }
    struct Event: Codable, Sendable { let sequence: Int; let name: String; let child: Int?; let threadID: UInt64 }
    struct ChildError: Codable, Sendable { let child: Int?; let error: String }
    struct Run: Codable, Sendable {
        let consumers: [Consumer]; let events: [Event]; let attempts: [Attempt]
        let successfulQueries: Int; let busy: Int; let childErrors: [ChildError]; let joined: [Int]; let timerJoined: Bool
    }
    struct Cleanup: Codable, Sendable {
        let label: String; let firstError: String?; let before: Counts; let after: Counts
        let snapshotCountBefore: Int; let cleanupErrors: [String]; let repositoryClosed: Bool; let engineShutdown: Bool
    }
    enum Failure: Error { case missingOwner, missingScene, badBarrier, barrierExpired, deadline,
        oracleMismatch(Int,Int), unsupportedPrimitive, attemptBudget, busyExhausted(Int,Int,Int),
        consumerFailed, expectedCleanupProbe }
    @MainActor final class Scenes { var values: [TimelineSnapshot]=[]; func clear() { values.removeAll() } }
    actor Ledger {
        private var events: [Event]=[]; private var attempts: [Attempt]=[]
        private var started=0; private var successful=0; private var busy=0
        func add(_ name: String,_ child: Int? = nil,_ threadID: UInt64 = 0) {
            precondition(events.count<64); events.append(Event(sequence:events.count,name:name,child:child,threadID:threadID))
        }
        func begin() throws -> Int { guard started<512 else { throw Failure.attemptBudget }; started+=1; return started }
        func finish(_ value: Attempt) { attempts.append(value); if value.status=="busy" { busy+=1 } }
        func success() { successful+=1; precondition(successful<=128) }
        func read() -> ([Event],[Attempt],Int,Int) { (events,attempts,successful,busy) }
    }
    actor Gate {
        private var arrivals: [Int:CheckedContinuation<Void,any Error>] = [:]
        private var parent: CheckedContinuation<Void,any Error>?;private var released=false;private var aborted=false
        func arrive(_ id: Int) async throws {
            guard !released,!aborted,arrivals[id]==nil else { throw Failure.badBarrier }
            try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,any Error>) in
                arrivals[id]=c;if arrivals.count==2 { parent?.resume();parent=nil }
            }
        }
        func waitForBoth() async throws {
            if aborted { throw Failure.barrierExpired };if arrivals.count==2 { return }
            try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,any Error>) in parent=c }
        }
        func release() throws {
            guard arrivals.count==2,!released,!aborted else { throw Failure.badBarrier }
            released=true;let values=arrivals;arrivals.removeAll();for c in values.values { c.resume() }
        }
        func abort() {
            aborted=true;parent?.resume(throwing:Failure.barrierExpired);parent=nil
            let values=arrivals;arrivals.removeAll();for c in values.values { c.resume(throwing:Failure.barrierExpired) }
        }
    }
    static func threadID() -> UInt64 { var value:UInt64=0;pthread_threadid_np(nil,&value);return value }
    static func counts(_ engine: RustEngine) async -> Counts {
        let c=RustEngine.developmentColdStorageCounts(),l=await engine.developmentLifecycleCounts()
        return Counts(bytes:c.bytes,owners:c.owners,stagingBytes:c.stagingBytes,stagingOwners:c.stagingOwners,sessions:l.sessions,requests:l.requests)
    }
    @concurrent static func open(_ input: Input) async throws -> Context {
        let namespace=URL(filePath:input.runtimeRoot).appendingPathComponent("concurrent-hit")
        try FileManager.default.createDirectory(at:namespace,withIntermediateDirectories:true,attributes:[.posixPermissions:NSNumber(value:0o700)])
        let config=RustConfiguration.developmentFixture(namespace:namespace,helper:URL(filePath:input.helper),parser:URL(filePath:input.parser),
            helperSHA256:input.helperSHA256,parserIdentity:input.parserIdentity)
        try emit("configuration",try object(config))
        let engine=try await RustEngine.createDevelopmentFixture(config)
        do {
            print("A35_OPEN_ENTER");let session=try await engine.open(URL(filePath:input.source),format:.htrace,timeoutMilliseconds:8000)
            let repository=try await RustTraceRepository.create(session:session,sourceFormat:.htrace,operationTimeoutMilliseconds:5000)
            try await RustCleanup.flush();return Context(engine:engine,repository:repository,opening:await counts(engine),namespace:namespace)
        } catch { try await engine.shutdown();try await RustCleanup.flush();throw error }
    }
    @concurrent static func loadScenes(_ context: Context,_ deadline: ContinuousClock.Instant) async throws -> [TimelineSnapshot] {
        let metadata=try await context.repository.metadata(),range=try TraceTimeRange.query(startNs:0,endNs:metadata.durationNs)
        let viewport=try TimelineViewport(range:range,widthPoints:800,heightPoints:600,generation:1)
        let track=TrackDescriptor(title:"named slices",source:.namedSlice(ThreadKey(itid:1)))
        var scenes:[TimelineSnapshot]=[]
        for (index,preference) in [TimelineDetailPreference.detail,.density].enumerated() {
            let request=try ViewportRequest(viewport:viewport,tracks:[track],pixelWidth:800,generation:1,preference:preference,maximumPrimitives:128,deadline:deadline)
            print("A35_LOAD_ENTER \(index)");guard let snapshot=try await NativeTimelineSnapshot.load(request,repository:context.repository),snapshot.nativeHitOwner != nil else { throw Failure.missingOwner }
            scenes.append(snapshot)
        }
        return scenes
    }
    static func value(_ event: EventKey?) -> HitValue { HitValue(event:event,densitySource:nil,densityTrack:nil,bucket:nil,timeNs:nil) }
    static func value(_ hit: TimelineDensityHit?,_ scene: TimelineSnapshot) throws -> HitValue {
        guard let hit else { return HitValue(event:nil,densitySource:nil,densityTrack:nil,bucket:nil,timeNs:nil) }
        guard let descriptor=scene.tracks.first(where:{$0.descriptor.id==hit.trackID})?.descriptor else { throw Failure.missingScene }
        return HitValue(event:nil,densitySource:descriptor.source,densityTrack:hit.trackID,bucket:hit.bucket,timeNs:hit.timeNs)
    }
    @MainActor final class OracleWindow: NSWindow { override var backingScaleFactor: CGFloat { 1 } }
    @MainActor static func oracle(_ scenes: [TimelineSnapshot]) throws -> [Probe] {
        var probes:[Probe]=[]
        for (index,scene) in scenes.enumerated() {
            let legacy=try JSONDecoder().decode(TimelineSnapshot.self,from:JSONEncoder().encode(scene));XCTAssertNil(legacy.nativeHitOwner)
            let track=try XCTUnwrap(legacy.tracks.first),primitive=try XCTUnwrap(track.primitives.first)
            let geometry=TimelineGeometry.frame(for:primitive,in:track,viewport:legacy.viewport,backingScale:1)
            XCTAssertFalse(geometry.isEmpty);let hit=CGPoint(x:geometry.midX,y:geometry.midY),miss=CGPoint(x:-4,y:geometry.midY)
            let frame=CGRect(x:0,y:0,width:legacy.viewport.widthPoints,height:legacy.viewport.heightPoints)
            let view=TimelineNSView(frame:frame);view.snapshot=legacy
            let window=OracleWindow(contentRect:frame,styleMask:.borderless,backing:.buffered,defer:false);window.contentView=view
            defer { window.contentView=nil }
            for point in [hit,miss] {
                let expected:HitValue
                if index==0 { expected=value(view.event(at:point)) }
                else { expected=try value(view.densityBand(at:point),legacy) }
                probes.append(Probe(scene:index,kind:index==0 ? "detail" : "density",point:point,expected:expected))
            }
        }
        XCTAssertNotNil(probes[0].expected.event);XCTAssertNil(probes[1].expected.event)
        XCTAssertNotNil(probes[2].expected.bucket);XCTAssertNil(probes[3].expected.bucket)
        return probes
    }
    // The caller supplies the actual retained-owner operation; only typed BUSY retries.
    @concurrent static func query(_ operation: @Sendable () throws -> HitValue, probe: Probe,
        child: Int, round: Int, index: Int, ledger: Ledger, deadline: ContinuousClock.Instant) async throws -> Read {
        var busy=0
        for attempt in 1...4 {
            try Task.checkCancellation(); guard ContinuousClock.now<deadline else { throw Failure.deadline }
            let serial=try await ledger.begin()
            try Task.checkCancellation(); guard ContinuousClock.now<deadline else { throw Failure.deadline }
            let thread=threadID(), entered=DispatchTime.now().uptimeNanoseconds
            let result: HitValue
            do { result=try operation() }
            catch TimelineNativeHitError.busy {
                let returned=DispatchTime.now().uptimeNanoseconds; busy+=1
                await ledger.finish(Attempt(index:serial,child:child,round:round,probe:index,attempt:attempt,
                    threadID:thread,enteredNs:entered,returnedNs:returned,status:"busy",error:"TimelineNativeHitError.busy"))
                guard attempt<4 else { throw Failure.busyExhausted(child,round,index) }
                try Task.checkCancellation(); guard ContinuousClock.now<deadline else { throw Failure.deadline }
                await Task.yield(); continue
            } catch {
                await ledger.finish(Attempt(index:serial,child:child,round:round,probe:index,attempt:attempt,
                    threadID:thread,enteredNs:entered,returnedNs:DispatchTime.now().uptimeNanoseconds,
                    status:"error",error:String(reflecting:error)))
                throw error
            }
            let returned=DispatchTime.now().uptimeNanoseconds
            await ledger.finish(Attempt(index:serial,child:child,round:round,probe:index,attempt:attempt,
                threadID:thread,enteredNs:entered,returnedNs:returned,status:"success",error:nil))
            guard result==probe.expected else { throw Failure.oracleMismatch(child,index) }
            await ledger.success()
            return Read(round:round,probe:index,threadID:thread,enteredNs:entered,returnedNs:returned,
                attempts:attempt,busy:busy,value:result)
        }
        throw Failure.attemptBudget
    }
    @concurrent static func consume(_ scenes: [TimelineSnapshot],_ probes: [Probe],_ id: Int,
        _ gate: Gate,_ ledger: Ledger,_ deadline: ContinuousClock.Instant) async throws -> Consumer {
        do {
            await ledger.add("child-ready",id,threadID()); try await gate.arrive(id)
            await ledger.add("consumer-enter",id,threadID()); print("A35_CONSUMER_ENTER \(id)")
            var records: [Read]=[]
            for round in 0..<16 {
                for (index,probe) in probes.enumerated() {
                    guard let owner=scenes[probe.scene].nativeHitOwner else { throw Failure.missingOwner }
                    let scene=scenes[probe.scene]
                    let read=try await query({
                        if probe.kind=="detail" { return value(try owner.event(at:probe.point,viewport:scene.viewport,backingScale:1)) }
                        return try value(owner.densityBand(at:probe.point,viewport:scene.viewport,backingScale:1),scene)
                    },probe:probe,child:id,round:round,index:index,ledger:ledger,deadline:deadline)
                    records.append(read)
                }
                await Task.yield()
            }
            await ledger.add("consumer-terminal",id,threadID()); print("A35_CONSUMER_TERMINAL \(id)")
            return Consumer(id:id,records:records)
        } catch { await ledger.add("consumer-failed",id,threadID()); throw error }
    }
    @concurrent static func run(_ scenes: [TimelineSnapshot],_ probes: [Probe],
        _ deadline: ContinuousClock.Instant) async -> Run {
        let ledger=Ledger(), gate=Gate(), barrierDeadline=ContinuousClock.now.advanced(by:.seconds(2))
        let timer=Task {
            do { try await Task.sleep(until:barrierDeadline,clock:.continuous); await gate.abort() }
            catch is CancellationError { await ledger.add("timer-cancelled") }
            catch { await ledger.add("timer-unexpected"); await gate.abort() }
        }
        let first=Task { try await consume(scenes,probes,0,gate,ledger,deadline) }
        let second=Task { try await consume(scenes,probes,1,gate,ledger,deadline) }
        var errors: [ChildError]=[]; var timerJoined=false
        do {
            try await gate.waitForBoth(); timer.cancel(); await timer.value; timerJoined=true
            await ledger.add("timer-joined"); await ledger.add("gate-release"); try await gate.release()
        } catch {
            errors.append(ChildError(child:nil,error:String(reflecting:error)))
            first.cancel(); second.cancel(); await gate.abort(); timer.cancel()
        }
        let a=await first.result
        if case .failure = a { first.cancel(); second.cancel(); await gate.abort(); timer.cancel() }
        let b=await second.result
        first.cancel(); second.cancel(); timer.cancel()
        if !timerJoined { await timer.value; timerJoined=true; await ledger.add("timer-joined") }
        var consumers: [Consumer]=[]
        for (id,result) in [(0,a),(1,b)] {
            switch result {
            case .success(let consumer): consumers.append(consumer)
            case .failure(let error): errors.append(ChildError(child:id,error:String(reflecting:error)))
            }
            await ledger.add("child-joined",id)
        }
        let (events,attempts,success,busy)=await ledger.read()
        return Run(consumers:consumers,events:events,attempts:attempts,successfulQueries:success,busy:busy,
            childErrors:errors,joined:[0,1],timerJoined:timerJoined)
    }
    // Both normal validation and validation failure use this same owned cleanup.
    @MainActor static func cleanup(_ context: Context,_ scenes: Scenes,closed: Bool,shutdown: Bool,
        label: String,validate: () throws -> Void) async throws -> Cleanup {
        var firstError: String?
        do { try validate() } catch { firstError=String(reflecting:error) }
        let before=await counts(context.engine), count=scenes.values.count
        scenes.clear(); var errors: [String]=[]; var didClose=closed, didShutdown=shutdown
        do { try await RustCleanup.flush() } catch { errors.append(String(reflecting:error)) }
        if !didClose {
            do { try await context.repository.close(); didClose=true } catch { errors.append(String(reflecting:error)) }
        }
        if !didShutdown {
            do { try await context.engine.shutdown(); didShutdown=true } catch { errors.append(String(reflecting:error)) }
        }
        do { try await RustCleanup.flush() } catch { errors.append(String(reflecting:error)) }
        let result=Cleanup(label:label,firstError:firstError,before:before,after:await counts(context.engine),
            snapshotCountBefore:count,cleanupErrors:errors,repositoryClosed:didClose,engineShutdown:didShutdown)
        try emit(label,try object(result)); return result
    }
    @concurrent static func policyFailureChecks(_ probe: Probe,_ deadline: ContinuousClock.Instant) async throws {
        let busyLedger=Ledger(); var exhausted=false
        do { _=try await query({ throw TimelineNativeHitError.busy },probe:probe,child:0,round:0,index:0,
            ledger:busyLedger,deadline:deadline) }
        catch Failure.busyExhausted { exhausted=true }
        let (_,busyAttempts,busySuccess,busyCount)=await busyLedger.read()
        XCTAssertTrue(exhausted); XCTAssertEqual(busyAttempts.count,4); XCTAssertEqual(busyCount,4); XCTAssertEqual(busySuccess,0)
        let errorLedger=Ledger(); var propagated=false
        do { _=try await query({ throw Failure.unsupportedPrimitive },probe:probe,child:0,round:0,index:0,
            ledger:errorLedger,deadline:deadline) }
        catch Failure.unsupportedPrimitive { propagated=true }
        let (_,errorAttempts,errorSuccess,errorBusy)=await errorLedger.read()
        XCTAssertTrue(propagated); XCTAssertEqual(errorAttempts.count,1); XCTAssertEqual(errorSuccess,0); XCTAssertEqual(errorBusy,0)
        try emit("policy-failure-checks",["syntheticTestOperations":true,"actualNativeHitCalls":0,
            "typedBusyExhaustedAt4":exhausted,"busyAttempts":try object(busyAttempts),
            "nonBusyPropagatedAt1":propagated,"nonBusyAttempts":try object(errorAttempts)])
    }
    static func object<T:Encodable>(_ value:T) throws -> Any { try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) }
    static func emit(_ name:String,_ value:Any) throws {
        let root=try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_A35_OUTPUT"])
        let data=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
        guard data.count<=65536 else { throw Failure.missingScene }
        try data.write(to:URL(filePath:root).appendingPathComponent(name+".json"),options:.atomic)
    }
    static func emitRun(_ run: Run) throws {
        for consumer in run.consumers {
            for round in 0..<16 {
                try emit("consumer-\(consumer.id)-round-\(round)",try object(consumer.records.filter{$0.round==round}))
            }
        }
        for start in stride(from:0,to:run.attempts.count,by:32) {
            try emit("attempts-\(start/32)",try object(Array(run.attempts[start..<min(start+32,run.attempts.count)])))
        }
        try emit("consumer-summary",["events":try object(run.events),"childErrors":try object(run.childErrors),
            "joined":run.joined,"timerJoined":run.timerJoined,"successfulQueries":run.successfulQueries,
            "nativeAttempts":run.attempts.count,"typedBusy":run.busy])
    }
}

@MainActor
final class NativeSnapshotConcurrentRetainedHitTests: XCTestCase {
    func testTwoSendableConsumersReadRetainedOwnersAfterEngineRelease() async throws {
        typealias H=ConcurrentHitHarness
        let path=try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_NATIVE_CONCURRENT_HIT_INPUT"])
        let input=try JSONDecoder().decode(H.Input.self,from:Data(contentsOf:URL(filePath:path)))
        let deadline=ContinuousClock.now.advanced(by:.seconds(12)), context=try await H.open(input), scenes=H.Scenes()
        var closed=false, shutdown=false
        do {
            scenes.values=try await H.loadScenes(context,deadline); XCTAssertEqual(scenes.values.count,2)
            let probes=try H.oracle(scenes.values)
            try H.emit("oracle",["probes":try H.object(probes),"sceneSnapshots":try H.object(scenes.values),
                "SwiftOracleCalls":4,"nativeOracleCalls":0,"legacyCopiesHaveNativeOwner":false,
                "reference":"current unmodified TimelineNSView over Codable copy; same actual Ready primitives",
                "independentSwiftDatabaseBackend":false])
            try await H.policyFailureChecks(probes[0],deadline)
            try await RustCleanup.flush(); let held=await H.counts(context.engine), nativeHeld=try await context.engine.retainedResultBytes()
            XCTAssertEqual(held.owners,2); XCTAssertGreaterThan(held.bytes,0)
            try await context.repository.close(); closed=true; try await RustCleanup.flush()
            let beforeShutdown=await H.counts(context.engine), nativeBeforeShutdown=try await context.engine.retainedResultBytes()
            XCTAssertEqual(beforeShutdown.sessions,0); XCTAssertEqual(beforeShutdown.owners,2)
            try await context.engine.shutdown(); shutdown=true; try await RustCleanup.flush()
            let released=await H.counts(context.engine); XCTAssertEqual(released.bytes,held.bytes); XCTAssertEqual(released.owners,2)
            XCTAssertEqual(released.sessions,0); XCTAssertEqual(released.requests,0)
            let run=await H.run(scenes.values,probes,deadline); try H.emitRun(run)
            guard run.childErrors.isEmpty else { throw H.Failure.consumerFailed }
            XCTAssertEqual(run.consumers.count,2); XCTAssertEqual(run.successfulQueries,128)
            XCTAssertTrue(run.consumers.allSatisfy{$0.records.count==64}); XCTAssertTrue(run.attempts.count<=512)
            XCTAssertEqual(run.attempts.filter{$0.status=="success"}.count,128)
            XCTAssertEqual(run.attempts.filter{$0.status=="busy"}.count,run.busy)
            XCTAssertEqual(run.attempts.filter{$0.status=="error"}.count,0)
            let entries=run.events.filter{$0.name=="consumer-enter"}.map{$0.sequence}
            let terminals=run.events.filter{$0.name=="consumer-terminal"}.map{$0.sequence}
            let enteredBeforeFirstTerminal=entries.count==2 && terminals.count==2 && entries.max()!<terminals.min()!
            XCTAssertTrue(enteredBeforeFirstTerminal)
            let overlap=run.consumers.map{$0.records.first!.enteredNs}.max()!<run.consumers.map{$0.records.last!.returnedNs}.min()!
            XCTAssertTrue(overlap,"Actual successful-call ranges overlap; no simultaneous C calls asserted")
            let afterReads=await H.counts(context.engine); XCTAssertEqual(afterReads,released)
            // Actual failure cleanup with both owners held, after every worker result has joined.
            let failureCleanup=try await H.cleanup(context,scenes,closed:closed,shutdown:shutdown,
                label:"expected-failure-cleanup",validate:{ throw H.Failure.expectedCleanupProbe })
            XCTAssertEqual(failureCleanup.firstError,String(reflecting:H.Failure.expectedCleanupProbe))
            XCTAssertEqual(failureCleanup.before.owners,2); XCTAssertEqual(failureCleanup.snapshotCountBefore,2)
            XCTAssertTrue(failureCleanup.cleanupErrors.isEmpty)
            XCTAssertEqual(failureCleanup.after.bytes,0); XCTAssertEqual(failureCleanup.after.owners,0)
            XCTAssertEqual(failureCleanup.after.stagingBytes,0); XCTAssertEqual(failureCleanup.after.stagingOwners,0)
            XCTAssertEqual(failureCleanup.after.sessions,0); XCTAssertEqual(failureCleanup.after.requests,0)
            let normalCleanup=try await H.cleanup(context,scenes,closed:true,shutdown:true,label:"normal-cleanup",validate:{})
            XCTAssertNil(normalCleanup.firstError); XCTAssertTrue(normalCleanup.cleanupErrors.isEmpty)
            XCTAssertEqual(normalCleanup.after,failureCleanup.after)
            try H.emit("concurrent-hit",["actualEngineOpens":1,"actualNativeLoads":2,"actualDirectSDKLoads":0,
                "actualConsumers":2,"actualNativeHitCalls":run.attempts.count,"actualLogicalSuccessQueries":run.successfulQueries,
                "actualTypedBusy":run.busy,"maximumAttemptsPerQuery":4,"maximumActualNativeAttempts":512,
                "roundsPerConsumer":16,"probesPerRound":4,"sameTwoSendableOwners":true,
                "bothConsumerEntriesBeforeFirstTerminal":enteredBeforeFirstTerminal,"actualConsumerCallRangesOverlap":overlap,
                "CWorkerSimultaneityClaimed":false,"consumersJoined":run.joined,"timerCancelledJoined":run.timerJoined,
                "events":try H.object(run.events),"samples":try H.object(["opening":context.opening,"twoHeld":held,
                    "closedBeforeShutdown":beforeShutdown,"releasedBeforeConsumers":released,"afterConsumers":afterReads,
                    "allDropped":normalCleanup.after]),"nativeBeforeClose":nativeHeld,"nativeBeforeShutdown":nativeBeforeShutdown,
                "nativeAfterEngineRelease":NSNull(),"postReleaseNativeZeroClaimed":false,
                "closeExecuted":closed,"shutdownExecuted":shutdown,"noCreditIncreaseDuringReads":afterReads==released,
                "finalDropLogicalZero":normalCleanup.after.bytes==0 && normalCleanup.after.owners==0,
                "failureCleanupProbe":"controlled validation failure after128 successes/all workers joined, before2 owners dropped",
                "inFlightFailureInjection":false,"originalInternalDeadline":String(describing:deadline),"GUIAcceptance":false])
        } catch {
            let firstError=error
            let cleanup=try await H.cleanup(context,scenes,closed:closed,shutdown:shutdown,label:"failure",
                validate:{ throw firstError })
            XCTAssertTrue(cleanup.cleanupErrors.isEmpty); XCTAssertEqual(cleanup.after.bytes,0); XCTAssertEqual(cleanup.after.owners,0)
            XCTAssertEqual(cleanup.after.stagingBytes,0); XCTAssertEqual(cleanup.after.stagingOwners,0)
            XCTAssertEqual(cleanup.after.sessions,0); XCTAssertEqual(cleanup.after.requests,0)
            throw firstError
        }
    }
}
#endif
