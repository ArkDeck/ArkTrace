#if ARKTRACE_NATIVE_RUNTIME && ARKTRACE_RUST_PROCESS_FIXTURES
import ArkTraceCore
@testable import ArkTraceRustRuntime
@testable import ArkTraceRendering
import CArkTrace
import CoreGraphics
import CryptoKit
import Foundation
import XCTest

final class NativeSnapshotConcurrentByteAdmissionTests: XCTestCase, @unchecked Sendable {
    private struct Fixture: Decodable {
        let source: String; let helper: String; let parser: String
        let helperSHA256: String; let parserIdentity: TraceParserIdentity; let runtimeRoot: String
    }
    private struct Counts: Codable, Equatable, Sendable {
        let bytes: Int; let owners: Int; let native: UInt64
        let stagingBytes: Int; let stagingOwners: Int; let sessions: Int; let requests: Int
    }
    private struct Values: Codable, Equatable, Sendable {
        let snapshot: Data; let snapshotSHA256: String
        let inspectors: [TraceEventInspector]; let labelsUTF8: [[UInt8]?]
        let geometryBits: [[UInt64]]; let colors: [[UInt8]]
    }
    // Read and clear only after the producing child has joined. No concurrent
    // mutation of the retained value is permitted by this harness.
    private final class SnapshotBox: @unchecked Sendable {
        private var snapshot: TimelineSnapshot?
        init(_ snapshot: TimelineSnapshot) { self.snapshot = snapshot }
        @inline(never) func clear() { snapshot = nil }
        @inline(never) func read() throws -> Values {
            let value = try XCTUnwrap(snapshot)
            var inspectors: [TraceEventInspector] = [], labels: [[UInt8]?] = []
            var geometry: [[UInt64]] = [], colors: [[UInt8]] = []
            for track in value.tracks {
                for primitive in track.primitives {
                    guard case .detail(let detail) = primitive else { throw Failure.unexpectedPrimitive }
                    inspectors.append(try XCTUnwrap(detail.inspector))
                    labels.append(detail.label.map { Array($0.utf8) })
                    let frame = TimelineGeometry.frame(for: primitive,in:track,viewport:value.viewport,backingScale:1)
                    geometry.append([Double(frame.minX).bitPattern,Double(frame.minY).bitPattern,Double(frame.width).bitPattern,Double(frame.height).bitPattern])
                    let c = TimelineDetailPalette.color(for: detail); colors.append([c.red,c.green,c.blue])
                }
            }
            XCTAssertEqual(value.primitiveCount,2); XCTAssertEqual(inspectors.count,2)
            let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; let data = try e.encode(value)
            return Values(snapshot:data,snapshotSHA256:SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined(),
                inspectors:inspectors,labelsUTF8:labels,geometryBits:geometry,colors:colors)
        }
    }
    private final class CreditBox {
        private var credit: RustStorageCredit?
        func retain(_ credit: RustStorageCredit) { self.credit = credit }
        @inline(never) func clear() { credit = nil }
    }
    private enum Failure: Error { case noSnapshot, unexpectedPrimitive, barrierExpired, badBarrier, badMeasurement, unexpectedOutcomes }
    private struct Step: Codable, Sendable { let sequence: Int; let action: String; let child: Int?; let admission: UInt32? }
    private actor Steps {
        private var values: [Step] = []
        func add(_ action: String,_ child: Int? = nil,_ admission: UInt32? = nil) {
            precondition(values.count<64);values.append(Step(sequence:values.count,action:action,child:child,admission:admission))
        }
        func read() -> [Step] { values }
    }
    private actor Gate {
        private var children: [Int:CheckedContinuation<Void,any Error>] = [:]
        private var waitingParent: CheckedContinuation<Void,any Error>?
        private var released = false, cancelled = false
        func ready(_ child: Int) async throws {
            guard children[child]==nil,!released,!cancelled else { throw Failure.badBarrier }
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,any Error>) in
                children[child]=continuation
                if children.count==2 { waitingParent?.resume();waitingParent=nil }
            }
        }
        func waitForTwo() async throws {
            if cancelled { throw Failure.barrierExpired }
            if children.count==2 { return }
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,any Error>) in waitingParent=continuation }
        }
        func release() throws {
            guard children.count==2,!cancelled,!released else { throw Failure.badBarrier }
            released=true;let captured=children;children.removeAll();for child in captured.values { child.resume() }
        }
        func cancel() {
            cancelled=true;waitingParent?.resume(throwing:Failure.barrierExpired);waitingParent=nil
            let captured=children;children.removeAll();for child in captured.values { child.resume(throwing:Failure.barrierExpired) }
        }
        func state() -> (Bool,Bool,Int) { (released,cancelled,children.count) }
    }
    private enum Outcome: Sendable { case value(SnapshotBox), refusal(RustAdmission), unexpected(String) }
    @concurrent private static func load(_ request: ViewportRequest,_ repository: RustTraceRepository,_ id: Int,_ steps: Steps) async -> Outcome {
        await steps.add("load-enter",id);print("A34_LOAD_ENTER \(id)")
        do {
            guard let result = try await NativeTimelineSnapshot.load(request,repository:repository) else { throw Failure.noSnapshot }
            let box=SnapshotBox(result);await steps.add("load-success",id);print("A34_LOAD_SUCCESS \(id)");return .value(box)
        } catch let admission as RustAdmission {
            await steps.add("load-refusal",id,admission.rawValue);print("A34_LOAD_REFUSAL \(id) \(admission.rawValue)");return .refusal(admission)
        } catch {
            await steps.add("load-unexpected",id);return .unexpected(String(reflecting:error))
        }
    }
    @concurrent private static func competitor(_ request: ViewportRequest,_ repository: RustTraceRepository,_ id: Int,_ gate: Gate,_ steps: Steps) async -> Outcome {
        await steps.add("child-ready",id);print("A34_CHILD_READY \(id)")
        do { try await gate.ready(id) } catch { return .unexpected(String(reflecting:error)) }
        return await load(request,repository,id,steps)
    }
    @concurrent private static func counts(_ engine: RustEngine) async throws -> Counts {
        let c=RustEngine.developmentColdStorageCounts(),l=await engine.developmentLifecycleCounts()
        return Counts(bytes:c.bytes,owners:c.owners,native:try await engine.retainedResultBytes(),stagingBytes:c.stagingBytes,
            stagingOwners:c.stagingOwners,sessions:l.sessions,requests:l.requests)
    }
    private static func encoded<T:Encodable>(_ value:T) throws -> Any { try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) }
    private static func emit(_ name:String,_ value:[String:Any]) throws {
        let p=try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_A34_R1_OUTPUT"])
        let data=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]);XCTAssertLessThanOrEqual(data.count,65536)
        try data.write(to:URL(filePath:p).appendingPathComponent(name+".json"),options:.atomic)
    }
    // Test-only ownership boundary: the caller retains the repository alone.
    @concurrent private static func openRepository(_ engine: RustEngine,_ source: URL) async throws -> RustTraceRepository {
        let session=try await engine.open(source,format:.htrace,timeoutMilliseconds:8000)
        return try await RustTraceRepository.create(session:session,sourceFormat:.htrace,operationTimeoutMilliseconds:5000)
    }
    @concurrent func testTwoActualLoadsCompeteForLastMeasuredByteCreditAndRecover() async throws {
        let path=try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_NATIVE_CONCURRENT_BYTE_R1_INPUT"])
        let fixture=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(filePath:path)))
        let root=URL(filePath:fixture.runtimeRoot).appendingPathComponent("concurrent-byte")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:NSNumber(value:0o700)])
        let configuration=RustConfiguration.developmentFixture(namespace:root,helper:URL(filePath:fixture.helper),parser:URL(filePath:fixture.parser),
            helperSHA256:fixture.helperSHA256,parserIdentity:fixture.parserIdentity)
        try Self.emit("configuration",try XCTUnwrap(try Self.encoded(configuration) as? [String:Any]))
        var identity=ArkTraceAbiIdentity();XCTAssertEqual(arktrace_abi_identity(&identity,UInt64(MemoryLayout<ArkTraceAbiIdentity>.size)),UInt32(ARKTRACE_STATUS_OK))
        XCTAssertEqual(identity.abi_version,2);XCTAssertEqual(ARKTRACE_SNAPSHOT_FORMAT_VERSION,2)
        let engine=try await RustEngine.createDevelopmentFixture(configuration)
        var repository:RustTraceRepository?, boxes:[SnapshotBox]=[], first:Task<Outcome,Never>?,second:Task<Outcome,Never>?,timer:Task<Void,Never>?
        let credit=CreditBox(),gate=Gate(),steps=Steps();var closeDone=false,shutdownDone=false
        defer { credit.clear();for box in boxes { box.clear() } }
        do {
            try await RustCleanup.flush();let baseline=try await Self.counts(engine)
            XCTAssertEqual(baseline.bytes,0);XCTAssertEqual(baseline.native,0);XCTAssertEqual(baseline.owners,0)
            print("A34_OPEN_ENTER");let repo=try await Self.openRepository(engine,URL(filePath:fixture.source));repository=repo
            let metadata=try await repo.metadata(),range=try TraceTimeRange.query(startNs:0,endNs:metadata.durationNs)
            let viewport=try TimelineViewport(range:range,widthPoints:800,heightPoints:600,generation:1)
            let originalDeadline=ContinuousClock.now.advanced(by:.seconds(15))
            let request=try ViewportRequest(viewport:viewport,tracks:[TrackDescriptor(title:"named slices",source:.namedSlice(ThreadKey(itid:1)))],
                pixelWidth:800,generation:1,preference:.detail,maximumPrimitives:128,deadline:originalDeadline)
            try await RustCleanup.flush();let opening=try await Self.counts(engine)
            let calibration=await Self.load(request,repo,-1,steps)
            guard case .value(let measured)=calibration else { throw Failure.badMeasurement }
            boxes.append(measured);let facts=try measured.read();try await RustCleanup.flush();let measuredCounts=try await Self.counts(engine)
            let (charge,overflow)=measuredCounts.bytes.subtractingReportingOverflow(opening.bytes)
            guard !overflow,charge>0,measuredCounts.owners==opening.owners+1 else { throw Failure.badMeasurement }
            let lease=measuredCounts.native-opening.native;XCTAssertGreaterThan(lease,0)
            measured.clear();try await RustCleanup.flush();let afterMeasuredDrop=try await Self.counts(engine);XCTAssertEqual(afterMeasuredDrop,opening)
            let storage=RustRetainedStorage.shared
            let (injectedBytes,subtractOverflow)=storage.maximumBytes.subtractingReportingOverflow(charge)
            guard !subtractOverflow,injectedBytes>0,opening.bytes==0,opening.owners==0 else { throw Failure.badMeasurement }
            credit.retain(try storage.reserve(injectedBytes));let injected=try await Self.counts(engine)
            XCTAssertEqual(injected.bytes,injectedBytes);XCTAssertEqual(injected.owners,1)
            XCTAssertEqual(storage.maximumBytes-injected.bytes,charge);XCTAssertLessThan(injected.owners+2,storage.maximumOwners)
            let gateDeadline=ContinuousClock.now.advanced(by:.seconds(2))
            timer=Task { do { try await Task.sleep(until:gateDeadline,clock:.continuous);await gate.cancel() }
                catch is CancellationError { await steps.add("timer-cancelled") }
                catch { await steps.add("timer-unexpected");await gate.cancel() } }
            first=Task { await Self.competitor(request,repo,0,gate,steps) }
            second=Task { await Self.competitor(request,repo,1,gate,steps) }
            try await gate.waitForTwo();timer?.cancel();await timer?.value;await steps.add("timer-joined")
            await steps.add("gate-release");try await gate.release()
            let a=await first!.value;await steps.add("child-joined",0)
            let b=await second!.value;await steps.add("child-joined",1)
            let outcomes=[a,b];var refusals:[RustAdmission]=[],winners:[SnapshotBox]=[]
            for outcome in outcomes { switch outcome { case .value(let value):winners.append(value);boxes.append(value)
                case .refusal(let admission):refusals.append(admission)
                case .unexpected(let error):try Self.emit("unexpected-child",["error":error]);throw Failure.unexpectedOutcomes } }
            guard winners.count==1,refusals.count==1 else { throw Failure.unexpectedOutcomes }
            let winner=try XCTUnwrap(winners.first);XCTAssertEqual(try winner.read(),facts)
            try await RustCleanup.flush();let raced=try await Self.counts(engine)
            XCTAssertEqual(raced.bytes,storage.maximumBytes);XCTAssertEqual(raced.owners,2);XCTAssertLessThan(raced.owners,storage.maximumOwners)
            XCTAssertEqual(raced.native,opening.native+lease);XCTAssertEqual(raced.requests,0);XCTAssertEqual(raced.sessions,1)
            XCTAssertEqual(raced.stagingBytes,0);XCTAssertEqual(raced.stagingOwners,0)
            credit.clear();try await RustCleanup.flush();let injectionDropped=try await Self.counts(engine)
            XCTAssertEqual(injectionDropped,measuredCounts);XCTAssertEqual(try winner.read(),facts)
            winner.clear();try await RustCleanup.flush();let winnerDropped=try await Self.counts(engine);XCTAssertEqual(winnerDropped,opening)
            XCTAssertLessThan(ContinuousClock.now,originalDeadline)
            let recovery=await Self.load(request,repo,2,steps);guard case .value(let healthy)=recovery else { throw Failure.unexpectedOutcomes }
            boxes.append(healthy);XCTAssertEqual(try healthy.read(),facts)
            try await RustCleanup.flush();let recoveryHeld=try await Self.counts(engine);XCTAssertEqual(recoveryHeld,measuredCounts)
            healthy.clear();try await RustCleanup.flush();let recoveryDropped=try await Self.counts(engine);XCTAssertEqual(recoveryDropped,opening)
            try await repo.close();closeDone=true;try await RustCleanup.flush();let closed=try await Self.counts(engine);XCTAssertEqual(closed,baseline)
            try await engine.shutdown();shutdownDone=true;try await RustCleanup.flush()
            let cold=RustEngine.developmentColdStorageCounts(),life=await engine.developmentLifecycleCounts(),state=await gate.state(),events=await steps.read()
            XCTAssertEqual(cold.bytes,0);XCTAssertEqual(cold.owners,0);XCTAssertEqual(cold.stagingBytes,0);XCTAssertEqual(cold.stagingOwners,0)
            XCTAssertEqual(life.sessions,0);XCTAssertEqual(life.requests,0);XCTAssertTrue(state.0);XCTAssertFalse(state.1);XCTAssertEqual(state.2,0)
            let actualEntries=events.filter { $0.action=="load-enter" && ($0.child==0 || $0.child==1) }
            let firstTerminal=try XCTUnwrap(events.first { ($0.action=="load-success" || $0.action=="load-refusal" || $0.action=="load-unexpected") && ($0.child==0 || $0.child==1) })
            let bothEnteredBeforeFirstTerminal=actualEntries.count==2 && actualEntries.allSatisfy { $0.sequence<firstTerminal.sequence }
            XCTAssertTrue(bothEnteredBeforeFirstTerminal,"Both actual Swift load entries must precede the first competing terminal")
            try Self.emit("concurrent-byte",["bothActualEntriesBeforeFirstTerminal":bothEnteredBeforeFirstTerminal,"firstCompetitionTerminalSequence":firstTerminal.sequence,"actualEngineOpenCalls":1,"actualNativeLoadAttempts":4,"actualNativeLoadSuccesses":3,"actualNativeLoadFailures":1,
                "measuredCharge":charge,"nativeLeaseDelta":lease,"injectedCredits":1,"injectedBytes":injectedBytes,"maximumBytes":storage.maximumBytes,
                "maximumOwners":storage.maximumOwners,"competitionWinners":winners.count,"typedAdmissionRaw":refusals[0].rawValue,
                "requestedAdmissionRaw":RustAdmission.outputLimit.rawValue,"typedContractMatchesRequest":refusals[0] == .outputLimit,
                "childrenReady":[0,1],"childrenJoined":[0,1],"timerCancelledJoined":true,"gateReleased":state.0,"gateAborted":state.1,
                "gateDeadline":String(describing:gateDeadline),"sameOriginalLoadDeadline":String(describing:originalDeadline),"events":try Self.encoded(events),
                "samples":try Self.encoded(["baseline":baseline,"opening":opening,"measurementHeld":measuredCounts,"measurementDropped":afterMeasuredDrop,
                    "injected":injected,"competitionJoinedFlush":raced,"injectionDropped":injectionDropped,"winnerDropped":winnerDropped,
                    "recoveryHeld":recoveryHeld,"recoveryDropped":recoveryDropped,"closed":closed]),"completeFacts":try Self.encoded(facts),
                "failureLeaseRefundedAfterJoinFlush":raced.native==measuredCounts.native,"closeExecuted":closeDone,"shutdownExecuted":shutdownDone,
                "finalColdBytes":cold.bytes,"finalColdOwners":cold.owners,"finalStagingBytes":cold.stagingBytes,"finalStagingOwners":cold.stagingOwners,
                "finalSessions":life.sessions,"finalRequests":life.requests,"postReleaseNativeCounter":NSNull(),"CWorkerSimultaneityClaimed":false])
            // Exact current byte-admission outcome per the task correction.
            XCTAssertEqual(refusals[0],.outputLimit,"Byte-credit refusal must be exact typed outputLimit")
        } catch {
            first?.cancel();second?.cancel();await gate.cancel();timer?.cancel()
            if let one=await first?.value,case .value(let value)=one { value.clear() }
            if let two=await second?.value,case .value(let value)=two { value.clear() }
            await timer?.value;credit.clear();for box in boxes { box.clear() }
            try Self.emit("failure",["error":String(reflecting:error),"events":try Self.encoded(await steps.read())])
            try await RustCleanup.flush()
            if !closeDone,let repo=repository { try await repo.close();closeDone=true }
            if !shutdownDone { try await engine.shutdown();shutdownDone=true }
            try await RustCleanup.flush();throw error
        }
    }
}
#endif
