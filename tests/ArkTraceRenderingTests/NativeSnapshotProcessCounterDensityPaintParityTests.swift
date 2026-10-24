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

private enum ProcessCounterPaintHarness {
    struct Input: Decodable, Sendable {
        let source: String; let helper: String; let parser: String
        let helperSHA256: String; let parserIdentity: TraceParserIdentity; let runtimeRoot: String
    }
    struct Context: Sendable { let engine: RustEngine; let repository: RustTraceRepository; let opening: Counts; let namespace: URL }
    struct Counts: Codable, Equatable, Sendable {
        let bytes: Int; let owners: Int; let stagingBytes: Int; let stagingOwners: Int; let sessions: Int; let requests: Int
    }

    enum Failure: Error { case missingOwner, missingScene, deadline, fixtureNeedsProcessCounter, oversizedRecord,
        invalidBitmap, noInteriorPaint, paintParity, bitmapLimit }
    struct Selected: Codable, Sendable { let name: String; let source: TimelineTrackSource; let discoveredEvent: EventKey? }
    struct Discovery: Codable, Sendable { let kind:String;let rows:Int;let available:Bool;let truncated:Bool;let quality:TraceDataQuality }
    actor LoadLog {
        private var native=0,reference=0
        func loadEntered(native:Bool) { if native { self.native+=1 } else { reference+=1 } }
        func loads() -> [Int] { [native,reference] }
    }
    @MainActor final class Held { var values:[TimelineSnapshot]=[];func clear(){values.removeAll()} }
    struct Sample: Codable, Sendable { let primitiveIndex:Int;let range:TraceTimeRange;let geometry:CGRect;let paintFrame:CGRect;let point:CGPoint }
    @MainActor static func probes(_ scene:TimelineSnapshot) throws -> [Sample] {
        let track=try XCTUnwrap(scene.tracks.first);var points:[Sample]=[]
        let bounds=CGRect(x:0,y:0,width:800,height:600)
        for (index,primitive) in track.primitives.enumerated() {
            guard case .density(let density)=primitive,density.bucket.eventCount>0,
                TimelineGeometry.isVisible(primitive,in:scene.viewport) else { continue }
            let geometry=TimelineGeometry.frame(for:primitive,in:track,viewport:scene.viewport,backingScale:1)
            let available=max(1,CGFloat(track.height)-6)
            let intensity=min(7,Int(log2(Double(max(1,density.bucket.eventCount)))))
            let height=max(1,available*TimelineNSView.densityHeightFraction(intensity))
            // Interior selection follows the current draw's bottom-anchored density band.
            // The test still calls the unmodified NSView to paint both complete scenes.
            let paint=CGRect(x:geometry.minX,y:TimelineGeometry.rulerHeight+CGFloat(track.y)+3+(available-height),width:geometry.width,height:height)
            let inside=paint.intersection(bounds).insetBy(dx:2,dy:2)
            guard !inside.isEmpty,inside.width>=1,inside.height>=1 else { continue }
            let point=CGPoint(x:floor(inside.midX)+0.5,y:floor(inside.midY)+0.5)
            guard inside.contains(point),point.y>TimelineGeometry.rulerHeight+3 else { continue }
            points.append(Sample(primitiveIndex:index,range:density.bucket.range,geometry:geometry,paintFrame:paint,point:point))
            if points.count==8 { break }
        }
        guard !points.isEmpty else { throw Failure.noInteriorPaint };return points
    }
    @MainActor static func resolvedPaint(_ scene:TimelineSnapshot,_ probe:Sample) throws -> [UInt8] {
        let track=try XCTUnwrap(scene.tracks.first)
        let density=try XCTUnwrap(track.primitives.compactMap { primitive -> TimelineDensityPrimitive? in
            guard case .density(let value)=primitive,value.bucket.range==probe.range else { return nil };return value
        }.first)
        let fallback=TimelinePalette.trackIdentityColor(track.descriptor.id.rawValue)
        let color=density.projection?.color ?? TimelineDensityPalette.color(for:density.bucket,fallback:fallback)
        return [color.red,color.green,color.blue,255]
    }
    @MainActor static func rgba(_ bitmap:NSBitmapImageRep,_ point:CGPoint) throws -> [UInt8] {
        let x=Int(floor(point.x)),y=Int(floor(point.y))
        guard x>=0 && x<800 && y>=0 && y<600 else { throw Failure.invalidBitmap }
        let color=try XCTUnwrap(bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB))
        let values=[color.redComponent,color.greenComponent,color.blueComponent,color.alphaComponent]
        guard values.allSatisfy({$0.isFinite && $0>=0 && $0<=1}) else { throw Failure.invalidBitmap }
        return values.map { UInt8(($0*255).rounded()) }
    }
    @MainActor static func render(_ scene:TimelineSnapshot,_ label:String) throws -> (NSBitmapImageRep,[String:Any]) {
        let bounds=CGRect(x:0,y:0,width:800,height:600)
        let view=TimelineNSView(frame:bounds),appearance=try XCTUnwrap(NSAppearance(named:.aqua))
        view.appearance=appearance;view.snapshot=scene
        // Match existing detached NSView cacheDisplay tests; no window auto-display preparation.
        let effectiveBackingScale=view.window?.backingScaleFactor ?? 1
        defer { view.snapshot=nil }
        var densityFills:[Int]=[],densityBuilds:[Int]=[],hooks:[[String:Any]]=[]
        view.fillBatchHook={kind,count in hooks.append(["callback":"fill","kind":kind,"count":count]);if kind=="density" { densityFills.append(count) }}
        view.pathCacheBuildHook={kind,count in hooks.append(["callback":"build","kind":kind,"count":count]);if kind=="density" { densityBuilds.append(count) }}
        let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:800,pixelsHigh:600,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:3200,bitsPerPixel:32))
        bitmap.size=NSSize(width:800,height:600)
        try emit(label+"-bitmap-before-cacheDisplay",[
            "label":label,"viewBounds":try object(view.bounds),"visibleRect":try object(view.visibleRect),
            "dirtyRect":try object(bounds),"viewConvertedBackingBounds":try object(view.convertToBacking(bounds)),
            "windowBackingScaleProperty":NSNull(),"effectiveBackingScale":effectiveBackingScale,"windowScaleOverrideForHarness":false,
            "screenBackingScale":NSNull(),
            "bitmapSizePoints":try object(bitmap.size),"pixelsWide":bitmap.pixelsWide,"pixelsHigh":bitmap.pixelsHigh,
            "bitsPerSample":bitmap.bitsPerSample,"samplesPerPixel":bitmap.samplesPerPixel,
            "colorSpaceName":bitmap.colorSpaceName.rawValue,"bitmapFormat":bitmap.bitmapFormat.rawValue,
            "isPlanar":bitmap.isPlanar,"hasAlpha":bitmap.hasAlpha,"bytesPerRow":bitmap.bytesPerRow,
            "bitsPerPixel":bitmap.bitsPerPixel,"appearance":appearance.name.rawValue,
            "needsDisplay":view.needsDisplay,"cacheDisplayEntered":false,"hookSequence":hooks])
        appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in:bounds,to:bitmap) }
        let conditions:[String:Bool]=[
            "densityFillCallbacksExactlyOne":densityFills.count==1,
            "densityFillPositive":densityFills.first.map{$0>0} ?? false,
            "densityBuildCallbacksExactlyOne":densityBuilds.count==1,
            "densityBuildPositive":densityBuilds.first.map{$0>0} ?? false,
            "pixelsWide800":bitmap.pixelsWide==800,"pixelsHigh600":bitmap.pixelsHigh==600,
            "bitsPerSample8":bitmap.bitsPerSample==8,"samplesPerPixel4":bitmap.samplesPerPixel==4,
            "deviceRGBColorSpaceName":bitmap.colorSpaceName == .deviceRGB]
        try emit(label+"-bitmap-before-guard",[
            "label":label,"conditions":conditions,"failedConditions":conditions.filter{!$0.value}.keys.sorted(),
            "densityDrawCallbacks":densityFills,"densityPathBuilds":densityBuilds,"hookSequence":hooks,
            "pixelsWide":bitmap.pixelsWide,"pixelsHigh":bitmap.pixelsHigh,
            "bitsPerSample":bitmap.bitsPerSample,"samplesPerPixel":bitmap.samplesPerPixel,
            "colorSpaceName":bitmap.colorSpaceName.rawValue,"bitmapFormat":bitmap.bitmapFormat.rawValue,
            "alphaFirst":bitmap.bitmapFormat.contains(.alphaFirst),
            "alphaNonpremultiplied":bitmap.bitmapFormat.contains(.alphaNonpremultiplied),
            "isPlanar":bitmap.isPlanar,"hasAlpha":bitmap.hasAlpha,"bytesPerRow":bitmap.bytesPerRow,
            "bitsPerPixel":bitmap.bitsPerPixel,"bitmapDataAvailable":bitmap.bitmapData != nil,
            "viewBounds":try object(view.bounds),"visibleRect":try object(view.visibleRect),
            "dirtyRect":try object(bounds),"viewConvertedBackingBounds":try object(view.convertToBacking(bounds)),
            "windowBackingScaleProperty":NSNull(),"effectiveBackingScale":effectiveBackingScale,"windowScaleOverrideForHarness":false,
            "screenBackingScale":NSNull(),
            "bitmapPixelPointScale":[Double(bitmap.pixelsWide)/bounds.width,Double(bitmap.pixelsHigh)/bounds.height],
            "appearance":appearance.name.rawValue,"cacheDisplayReturned":true,"exception":NSNull(),
            "acceptanceGuardUnchanged":true,"pixelTolerance":0])

        guard densityFills.count==1,densityFills[0]>0,densityBuilds.count==1,densityBuilds[0]>0,
            bitmap.pixelsWide==800,bitmap.pixelsHigh==600,bitmap.bitsPerSample==8,bitmap.samplesPerPixel==4,
            bitmap.colorSpaceName == .deviceRGB else { throw Failure.invalidBitmap }
        let raw=Data(bytes:try XCTUnwrap(bitmap.bitmapData),count:bitmap.bytesPerRow*bitmap.pixelsHigh)
        let png=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        guard raw.count<=2097152,png.count<=2097152 else { throw Failure.bitmapLimit }
        let output=try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_A40_PAINT_OUTPUT"])
        try png.write(to:URL(filePath:output).appendingPathComponent(label+".png"),options:.atomic)
        let record:[String:Any]=["label":label,"pixelsWide":800,"pixelsHigh":600,"bitsPerSample":8,"samplesPerPixel":4,
            "hasAlpha":bitmap.hasAlpha,"colorSpaceName":bitmap.colorSpaceName.rawValue,"appearance":appearance.name.rawValue,
            "scale":effectiveBackingScale,"dirtyRect":[0,0,800,600],"densityDrawCallbacks":densityFills,
            "densityPathBuilds":densityBuilds,"rawBytes":raw.count,"rawSHA256":SHA256.hash(data:raw).map{String(format:"%02x",$0)}.joined(),
            "PNGBytes":png.count,"PNGSHA256":SHA256.hash(data:png).map{String(format:"%02x",$0)}.joined(),
            "actualNSViewCacheDisplay":true,"offscreenTestBitmap":true,"GUIAcceptance":false]
        try emit(label+"-bitmap",record);return (bitmap,record)
    }
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
            print("A40R1_OPEN_ENTER");let session=try await engine.open(URL(filePath:input.source),format:.htrace,timeoutMilliseconds:8000)
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
        _ facade: ForwardingRepository,_ label: String,_ journal: LoadLog) async throws -> [TimelineSnapshot] {
        await journal.loadEntered(native:true);print("A40R1_LOAD_ENTER \(label)")
        guard let native=try await NativeTimelineSnapshot.load(request,repository:repository),native.nativeHitOwner != nil else { throw Failure.missingOwner }
        let loader=TimelineSnapshotLoader(); let reference: any TraceRepositoryProtocol=facade
        XCTAssertFalse(reference is RustTraceRepository)
        await journal.loadEntered(native:false);print("A40R1_REFERENCE_LOAD_ENTER \(label)")
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
    static func object<T:Encodable>(_ value:T) throws -> Any { try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) }
    static func emit(_ name:String,_ value:Any) throws {
        let root=try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_A40_PAINT_OUTPUT"])
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
final class NativeSnapshotProcessCounterDensityPaintParityTests:XCTestCase {
    func testActualProcessCounterDensityPaintMatchesCurrentSwift() async throws {
        typealias H=ProcessCounterPaintHarness
        let path=try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_NATIVE_PROCESS_COUNTER_PAINT_R1_INPUT"])
        let input=try JSONDecoder().decode(H.Input.self,from:Data(contentsOf:URL(filePath:path)))
        let context=try await H.open(input),held=H.Held(),log=H.QueryLog(),loads=H.LoadLog()
        let facade=H.ForwardingRepository(base:context.repository,log:log)
        var closed=false,shutdown=false
        do {
            let (range,selected,pages)=try await H.discover(context.repository,ContinuousClock.now.advanced(by:.seconds(12)))
            let selection=try XCTUnwrap(selected.first),viewport=try TimelineViewport(range:range,widthPoints:800,heightPoints:600,generation:1)
            let request=try ViewportRequest(viewport:viewport,tracks:[TrackDescriptor(title:selection.name,source:selection.source)],
                pixelWidth:800,generation:1,preference:.density,maximumPrimitives:128,deadline:ContinuousClock.now.advanced(by:.seconds(12)))
            held.values=try await H.pair(request,context.repository,facade,"processCounter-density",loads)
            let nativeBytes=try H.encoded(held.values[0]),swiftBytes=try H.encoded(held.values[1])
            try H.persistBytes("native-scene",nativeBytes);try H.persistBytes("swift-scene",swiftBytes)
            let probes=try H.probes(held.values[1]);try H.emit("actual-Swift-interior-probes",try H.object(probes))
            let (swiftBitmap,swiftRecord)=try H.render(held.values[1],"swift-density")
            let (nativeBitmap,nativeRecord)=try H.render(held.values[0],"native-density")
            var samples:[[String:Any]]=[];var samePixels=true,samePaint=true,allNonbackground=true
            for probe in probes {
                let expected=try H.rgba(swiftBitmap,probe.point),actual=try H.rgba(nativeBitmap,probe.point)
                let expectedPaint=try H.resolvedPaint(held.values[1],probe),actualPaint=try H.resolvedPaint(held.values[0],probe)
                let nonbackground=expected[3]==255 && (expected[0] != expected[1] || expected[1] != expected[2])
                samePixels = samePixels && actual==expected;samePaint = samePaint && actualPaint==expectedPaint
                allNonbackground = allNonbackground && nonbackground
                samples.append(["source":try H.object(selection.source),"probe":try H.object(probe),"SwiftRGBA8":expected,
                    "nativeRGBA8":actual,"pixelEqual":actual==expected,"SwiftResolvedPaintRGBA8":expectedPaint,
                    "nativeResolvedPaintRGBA8":actualPaint,"paintEqual":actualPaint==expectedPaint,"opaqueChromaticCanonical":nonbackground])
            }
            try H.emit("actual-paint-comparison",["samples":samples,"pixelTolerance":0,"resolvedPaintTolerance":0,
                "samePixels":samePixels,"sameResolvedPaint":samePaint,"allCanonicalNonbackground":allNonbackground,
                "SwiftBitmap":swiftRecord,"nativeBitmap":nativeRecord,"closedSceneEqual":nativeBytes==swiftBytes,
                "sourceAndProjectionUnmodified":true,"actualNativeHits":0])
            guard samePixels && samePaint && allNonbackground else { throw H.Failure.paintParity }
            let final=try await H.cleanup(context,held,closed:closed,shutdown:shutdown,nil);closed=true;shutdown=true
            let counts=await loads.loads()
            try H.emit("cross-source",["actualEngineOpens":1,"actualNativeLoads":counts[0],"actualReferenceLoads":counts[1],
                "actualNativeHitCalls":0,"actualConsumers":0,"actualBitmapDraws":2,"actualInteriorSamples":probes.count,
                "actualDiscoveryRequestsIncludingMetadata":1+pages.count,"selected":try H.object(selected),
                "referenceForwardedQueries":await log.all(),"pixelsEqual":samePixels,"resolvedPaintEqual":samePaint,
                "canonical":"actual unmodified current SwiftLoader scene through A33 pure forwarding facade, drawn by TimelineNSView cacheDisplay",
                "independentDatabaseBackend":false,"constructedExpected":false,"finalDropLogicalZero":final.bytes==0 && final.owners==0,
                "final":try H.object(final),"closeExecuted":closed,"shutdownExecuted":shutdown,
                "nativeAfterEngineRelease":NSNull(),"GUIAcceptance":false])
        } catch {
            let first=error,counts=await loads.loads()
            _=try await H.cleanup(context,held,closed:closed,shutdown:shutdown,String(reflecting:first))
            try H.emit("failure",["firstError":String(reflecting:first),"actualNativeLoads":counts[0],"actualReferenceLoads":counts[1],
                "referenceForwardedQueries":await log.all(),"actualNativeHits":0])
            throw first
        }
    }
}
#endif
