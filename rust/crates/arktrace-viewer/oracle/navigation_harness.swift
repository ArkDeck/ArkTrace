import ArkTraceAnalysis
import ArkTraceCore
import ArkTraceRendering
import ArkTraceRuntime
import AppKit
import Foundation
import XCTest
@testable import ArkTraceAppSupport

private struct NavigationOracleFacts: Sendable {
    let metadata: TraceMetadata
    let threads: [TraceThread]
    let samples: [CpuSlice]
    let counters: [CounterSeriesDescriptor]
    let frames: [TraceFrame]
    let threadsTruncated: Bool
    let cpuTruncated: Bool
    let countersTruncated: Bool
    init(_ input: [String: Any]) throws {
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T { try decoder.decode(type, from: JSONSerialization.data(withJSONObject: value)) }
        let cap = try decode(TraceCapabilities.self, input["capabilities"]!)
        let duration = (input["durationNs"] as! NSNumber).int64Value
        metadata = TraceMetadata(traceSHA256: String(repeating: "a", count: 64), sourceByteCount: 1, durationNs: duration, sourceFormat: "htrace", parser: TraceParserIdentity(name: "oracle", reportedVersion: "1", binarySHA256: String(repeating: "b",count:64), upstreamRepository: "https://example.invalid/oracle", upstreamRevision: String(repeating:"c",count:40), architecture:"arm64", adapterVersion:"1", buildRecipeVersion:"1"), schemaFingerprint:String(repeating:"d",count:64), capabilities:cap,dataQuality:TraceDataQuality())
        threads = try (input["threads"] as! [[String: Any]]).map { t in
            var adapted = t; adapted["key"] = ["itid": t["key"]!]
            if let key = t["processKey"], !(key is NSNull) { adapted["processKey"] = ["ipid":key] }
            return try decode(TraceThread.self, adapted)
        }
        samples = try (input["cpuSamples"] as! [[String: Any]]).enumerated().map { (i,s) in
            let key: ProcessKey? = s["processKey"] is NSNull ? nil : try decode(ProcessKey.self,s["processKey"]!)
            return CpuSlice(key:EventKey(table:.schedSlice,rowID:Int64(i)),range:try TraceTimeRange(startNs:0,endNs:1),cpu:(s["cpu"] as! NSNumber).int64Value,threadKey:nil,processKey:key,tid:nil,pid:nil,threadName:nil,processName:nil,endState:nil,priority:nil,isOpenEnded:false)
        }
        counters = try decode([CounterSeriesDescriptor].self,input["counters"]!)
        frames = try (input["frameProcessKeys"] as! [[String:Any]]).enumerated().map { (i,p) in TraceFrame(key:EventKey(table:.frameSlice,rowID:Int64(i)),range:try TraceTimeRange(startNs:0,endNs:1),kind:.actual,vsync:0,processKey:try decode(ProcessKey.self,p),flag:0,isOpenEnded:false) }
        threadsTruncated = input["threadsTruncated"] as! Bool; cpuTruncated = input["cpuTruncated"] as! Bool; countersTruncated = input["countersTruncated"] as! Bool
    }
}
private actor NavigationOracleRepository: TraceRepositoryProtocol {
    let facts: NavigationOracleFacts
    init(_ facts: NavigationOracleFacts) { self.facts = facts }
    func metadata() async throws -> TraceMetadata { facts.metadata }
    func threads(_ query: ThreadQuery) async throws -> BoundedPage<TraceThread> { BoundedPage(items:facts.threads,truncated:facts.threadsTruncated) }
    func processes(_ query: ProcessQuery) async throws -> BoundedPage<TraceProcess> { BoundedPage(items:[],truncated:false) }
    func summaryFacts(_ query: TraceSummaryQuery) async throws -> TraceSummaryFacts { throw CancellationError() }
    func cpuCatalog(_ query: TraceCPUCatalogQuery) async throws -> TraceCPUCatalog {
        let cpus = Array(Set(facts.samples.map(\.cpu))).sorted()
        return TraceCPUCatalog(cpus: TraceEventPage(items: cpus.prefix(query.limit).map { TraceCPUIdentity(cpu: $0) },
            truncated: facts.cpuTruncated || cpus.count > query.limit),
            activity: TraceEventPage(items: facts.samples.prefix(query.activityLimit).map { TraceCPUActivity(processKey: $0.processKey) },
                truncated: facts.cpuTruncated || facts.samples.count > query.activityLimit))
    }
    func cpuSlices(_ query: CpuSliceQuery) async throws -> TraceEventPage<CpuSlice> { TraceEventPage(items:facts.samples,truncated:facts.cpuTruncated) }
    func counterSeries(_ query: CounterSeriesQuery) async throws -> TraceEventPage<CounterSeriesDescriptor> { TraceEventPage(items:facts.counters,truncated:facts.countersTruncated) }
    func frames(_ query: TraceFrameQuery) async throws -> TraceEventPage<TraceFrame> { TraceEventPage(items:facts.frames,truncated:false) }
}

@MainActor final class NavigationCanonicalOracleTests: XCTestCase {
    private func encoded<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options:[.fragmentsAllowed]) }
    private func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T { try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject:value)) }
    func testCanonicalTrimmingScalars() throws {
        let scalars = (0...0x10ffff).compactMap { value -> Int? in
            guard let scalar = Unicode.Scalar(value), CharacterSet.whitespacesAndNewlines.contains(scalar) else { return nil }; return value
        }
        let output = ProcessInfo.processInfo.environment["ARKTRACE_NAVIGATION_WHITESPACE_OUTPUT"]!
        try JSONSerialization.data(withJSONObject:scalars,options:[.prettyPrinted]).write(to:URL(fileURLWithPath:output))
    }
    private func tree(_ controller: TraceDocumentController) throws -> [String: Any] {
        ["groups": try controller.trackGroups.map { g in
            ["id":g.id,"kind":g.kind.rawValue,"processKey":try g.processKey.map(encoded) ?? NSNull(),"title":g.title,"capabilityAvailable":g.capabilityAvailable,"truncated":g.truncated,"tracks":try g.tracks.map { t in ["title":t.title,"descriptor":["source":try encoded(t.source),"isCollapsed":t.isCollapsed,"showsNestedDepth":t.showsNestedDepth]] }] as [String:Any]
        }]
    }
    private func projection(_ controller: TraceDocumentController) throws -> [String: Any] {
        ["tree":try tree(controller),"searchResults":try encoded(controller.searchResults),"favoriteTrackIDs":controller.favoriteTrackIDs.map(\.rawValue),"processFilterText":controller.processFilterText,"searchSelectionIndex":controller.searchSelectionIndex as Any? ?? NSNull(),"pendingSelectionKey":try controller.navigationOraclePendingKey.map(encoded) ?? NSNull(),"viewportRange":try controller.snapshot.map { try encoded($0.viewport.range) } ?? NSNull()]
    }
    func testCanonicalFavoriteRestore() async throws {
        let env = ProcessInfo.processInfo.environment
        let cases = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:env["ARKTRACE_NAVIGATION_RESTORE_INPUT"]!))) as! [[String:Any]]
        var output: [[String:Any]] = []
        for item in cases {
            let facts = try NavigationOracleFacts(item["facts"] as! [String:Any])
            let root = URL(fileURLWithPath:env["ARKTRACE_NAVIGATION_TEST_CACHE"]!).appending(path:UUID().uuidString)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:root) }
            let metadata = TraceCacheMetadata(cacheKey:try TraceCacheKey(traceSHA256:facts.metadata.traceSHA256,parserBinarySHA256:facts.metadata.parser.binarySHA256,upstreamRevision:facts.metadata.parser.upstreamRevision,schemaAdapterVersion:"2",indexSchemaVersion:3),parser:facts.metadata.parser,sourceSHA256:facts.metadata.traceSHA256,sourceByteCount:1,databasePreparation:TraceDatabasePreparationResult(schemaAdapterVersion:"2",schemaFingerprint:facts.metadata.schemaFingerprint,indexVersion:3,upstreamDatabaseSHA256:String(repeating:"e",count:64),upstreamDatabaseByteCount:1),databaseByteCount:1,createdAt:Date(timeIntervalSince1970:0),lastAccessedAt:Date(timeIntervalSince1970:0))
            let store = TraceViewStateStore(cacheDirectory:root,metadata:metadata)!
            try FileManager.default.createDirectory(at:store.entryURL,withIntermediateDirectories:true)
            store.save(annotations:TimelineAnnotations(),favoriteTrackIDs:(item["ids"] as! [String]).map { TimelineTrackID(rawValue:$0) })
            let repository = NavigationOracleRepository(facts)
            let controller = TraceDocumentController(recentStore:TraceRecentDocumentStore(defaults:UserDefaults(suiteName:"NavigationRestore.\(UUID().uuidString)")!),maintenance:nil,opener:{ _,_ in TraceOpenedDocument(repository:repository,cacheHit:true,cacheMetadata:metadata,viewStateStore:store,close:{}) })
            let url = root.appending(path:"synthetic.htrace")
            try Data().write(to:url)
            controller.open(url)
            var attempts = 0
            while controller.phase != .ready && attempts < 100_000 { attempts += 1; await Task.yield() }
            XCTAssertEqual(controller.phase,.ready)
            output.append(["name":item["name"]!,"tree":try tree(controller),"favoriteTrackIDs":controller.favoriteTrackIDs.map(\.rawValue)])
            await controller.close()
        }
        try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:env["ARKTRACE_NAVIGATION_RESTORE_OUTPUT"]!))
    }
    func testCanonicalDisplayedNavigation() throws {
        let env = ProcessInfo.processInfo.environment
        let cases = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:env["ARKTRACE_NAVIGATION_RENDERING_INPUT"]!))) as! [[String:Any]]
        var output: [[String:Any]] = []
        for item in cases {
            let range = try decode(TraceTimeRange.self,item["viewport"]!)
            let viewport = try TimelineViewport(range:range,widthPoints:100,heightPoints:100,generation:0)
            var tracks: [TimelineTrackSnapshot] = []
            for (i,lane) in (item["lanes"] as! [[String:Any]]).enumerated() {
                let descriptor = TrackDescriptor(title:"lane",source:.cpu(Int64(i)))
                let primitives = try (lane["events"] as! [[String:Any]]).map { e in TimelinePrimitive.detail(TimelineDetailPrimitive(trackID:descriptor.id,eventKey:try decode(EventKey.self,e["key"]!),range:try decode(TraceTimeRange.self,e["range"]!))) }
                tracks.append(TimelineTrackSnapshot(descriptor:descriptor,y:Double(i*28),height:28,primitives:primitives))
            }
            let view = TimelineNSView(frame:CGRect(x:0,y:0,width:100,height:100))
            view.snapshot = TimelineSnapshot(viewport:viewport,tracks:tracks,generation:0,dataQuality:TraceDataQuality())
            view.selectedEventKey = item["selected"] is NSNull ? nil : try decode(EventKey.self,item["selected"]!)
            if let f = item["focused"] as? [String:Any] { view.navigationOracleSetFocus(try decode(EventKey.self,f["key"]!),track:TimelineTrackID(rawValue:f["trackID"] as! String)) } else { view.navigationOracleSetFocus(nil,track:nil) }
            let command = item["command"] as! String
            let delta = (item["delta"] as! NSNumber).intValue
            var changed: Bool? = nil; var anchor: Int64? = nil
            if command == "event" { changed = view.navigationOracleMoveEvent(delta) }
            if command == "track" { changed = view.navigationOracleMoveTrack(delta) }
            if command == "anchor" {
                view.selection = item["selection"] is NSNull ? nil : try decode(TraceTimeRange.self,item["selection"]!)
                view.updatePointerLocation((item["pointerX"] as? NSNumber).map { CGPoint(x:$0.doubleValue,y:50) })
                anchor = view.navigationOracleZoomAnchor(item["usesPointer"] as! Bool ? .zoomInAtPointer : .zoomIn)
            }
            output.append(["name":item["name"]!,"changed":changed as Any? ?? NSNull(),"focus":try view.focusedEventKey.map { ["trackID":view.focusedTrackID!.rawValue,"key":try encoded($0)] } as Any? ?? NSNull(),"anchorNs":anchor as Any? ?? NSNull()])
        }
        try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:env["ARKTRACE_NAVIGATION_RENDERING_OUTPUT"]!))
    }
    func testCanonicalTrackTreeAndActions() async throws {
        let environment = ProcessInfo.processInfo.environment
        let cases = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:environment["ARKTRACE_NAVIGATION_INPUT"]!))) as! [[String:Any]]
        var output: [[String:Any]] = []
        for item in cases {
            let facts = try NavigationOracleFacts(item["facts"] as! [String:Any])
            let defaults = UserDefaults(suiteName:"NavigationOracle.\(UUID().uuidString)")!
            let controller = TraceDocumentController(recentStore:TraceRecentDocumentStore(defaults:defaults),maintenance:nil,opener:{ _, _ in throw CancellationError() })
            try await controller.navigationOracleInstall(repository:NavigationOracleRepository(facts))
            let initial = try projection(controller)
            var filters: [[String:Any]] = []
            for text in item["filters"] as! [String] {
                controller.processFilterText = text
                let needle = text.trimmingCharacters(in:.whitespacesAndNewlines)
                filters.append(["text":text,"trimmed":needle,"ids":controller.filteredTrackGroups().map(\.id),"matches":controller.trackGroups.map { ["title":$0.title,"matches":$0.title.range(of:needle,options:[.caseInsensitive]) != nil] }])
            }
            controller.processFilterText = ""
            var steps: [[String:Any]] = []
            for a in item["actions"] as! [[String:Any]] {
                let focusBefore = controller.timelineFocusRequestID
                let rangeBefore = controller.snapshot?.viewport.range
                controller.navigationOraclePreferences = []; controller.navigationOraclePersistCount = 0
                var returned: Bool? = nil
                switch a["kind"] as! String {
                case "toggleTrack": controller.toggleTrack(TimelineTrackID(rawValue:a["id"] as! String))
                case "toggleTrackDepth": controller.toggleTrackDepth(TimelineTrackID(rawValue:a["id"] as! String))
                case "toggleFavorite": controller.toggleFavorite(TimelineTrackID(rawValue:a["id"] as! String))
                case "moveFavorite": controller.moveFavorite(from:(a["source"] as! NSNumber).intValue,to:(a["destination"] as! NSNumber).intValue)
                case "setSearchResults": controller.navigationOracleSetSearchResults(try decode([TraceSearchResult].self,a["items"]!),truncated:a["truncated"] as? Bool ?? false)
                case "selectSearchResult": controller.selectSearchResult(at:(a["index"] as! NSNumber).intValue)
                case "stepSearchResult": returned = controller.stepSearchResult(by:(a["delta"] as! NSNumber).intValue)
                case "activateSearchResult": returned = controller.activateSearchResult()
                case "revealSearchResult": controller.reveal(try decode(TraceSearchResult.self,a["result"]!))
                case "revealSliceAggregate":
                    let key: ThreadKey? = a["firstThreadKey"] is NSNull ? nil : try decode(ThreadKey.self,a["firstThreadKey"]!)
                    let event: EventKey? = a["firstEventKey"] is NSNull ? nil : try decode(EventKey.self,a["firstEventKey"]!)
                    let range: TraceTimeRange? = a["firstRange"] is NSNull ? nil : try decode(TraceTimeRange.self,a["firstRange"]!)
                    controller.revealSliceAggregate(TraceSliceNameAggregate(name:a["name"] as! String,totalDurationNs:range?.durationNs ?? 0,averageDurationNs:range?.durationNs ?? 0,occurrences:1,firstEventKey:event!,firstRange:range!,firstThreadKey:key))
                case "revealRange": controller.navigationOracleRevealRange(try decode(TraceTimeRange.self,a["range"]!))
                case "revealTrackGroup": controller.revealTrackGroup(a["id"] as! String)
                case "admitTrack":
                    let t = a["track"] as! [String:Any]; let d = t["descriptor"] as! [String:Any]
                    controller.navigationOracleAdmit(TrackDescriptor(title:t["title"] as! String,source:try decode(TimelineTrackSource.self,d["source"]!),isCollapsed:d["isCollapsed"] as! Bool,showsNestedDepth:d["showsNestedDepth"] as! Bool))
                default: XCTFail("unknown action")
                }
                let viewportIntent: TraceTimeRange? = controller.snapshot?.viewport.range != rangeBefore ? controller.snapshot?.viewport.range : nil
                steps.append(["projection":try projection(controller),"returned":returned as Any? ?? NSNull(),"focusTimeline":controller.timelineFocusRequestID != focusBefore,"snapshotPreference":controller.navigationOraclePreferences.last.map { String(describing:$0) } as Any? ?? NSNull(),"persistFavorites":controller.navigationOraclePersistCount > 0,"viewportIntent":try viewportIntent.map(encoded) ?? NSNull()])
            }
            output.append(["name":item["name"]!,"initial":initial,"filters":filters,"steps":steps])
        }
        let bytes = try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
        try bytes.write(to:URL(fileURLWithPath:environment["ARKTRACE_NAVIGATION_OUTPUT"]!))
    }
}
