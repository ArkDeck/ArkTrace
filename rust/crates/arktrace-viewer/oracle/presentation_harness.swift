// Appended only to cache-copy TimelineRenderingTests.swift.
extension TimelineRenderingTests {
    private struct PaletteCase: Decodable {
        let kind:String;let name:String
        let text:String?;let depth:Int?;let modulus:Int?;let identity:Int64?;let raw:String?;let normalized:TraceThreadState?;let tag:Int64?;let index:Int?;let red:UInt8?;let green:UInt8?;let blue:UInt8?;let alpha:Double?;let count:Int64?;let source:TraceDensitySource?;let dominant:TraceDensityIdentity?
    }
    private struct GenericCase:Decodable {
        let name:String;let inspectorKind:TraceInspectorEventType?;let label:String?;let category:String?;let inspectorName:String?;let state:String?;let pid:Int64?;let tid:Int64?;let jankTag:Int64
    }
    private static func presentationColor(_ c:TimelineColor)->[String:Any] {
        ["rgb":["red":Int(c.red),"green":Int(c.green),"blue":Int(c.blue)],"rgba":c.cgColor.components!,
            "foreground":["red":Int(c.preferredLabelColor.red),"green":Int(c.preferredLabelColor.green),"blue":Int(c.preferredLabelColor.blue)]]
    }
    @MainActor
    func testActualPresentationOracle() async throws {
        let input=try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_PRESENTATION_INPUT"])
        let output=try XCTUnwrap(ProcessInfo.processInfo.environment["ARKTRACE_PRESENTATION_OUTPUT"])
        let root=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:input)))as? [String:Any])
        let decoder=JSONDecoder()
        let cases=try decoder.decode([PaletteCase].self,from:JSONSerialization.data(withJSONObject:root["palette"]!))
        var palette:[[String:Any]]=[]
        for c in cases {
            var result:[String:Any]=["name":c.name]
            switch c.kind {
            case "hash":
                result["hash"]=TimelinePalette.hash(c.text!,modulus:c.modulus!)
                result["hashFunc"]=TimelinePalette.hashFunc(c.text!,depth:c.depth!,modulus:c.modulus!)
                result["nameColor"]=Self.presentationColor(TimelinePalette.color(forName:c.text!))
                result["sliceColor"]=Self.presentationColor(TimelinePalette.color(forSliceName:c.text!))
                result["sliceDepthColor"]=Self.presentationColor(TimelinePalette.color(forSliceName:c.text!,depth:c.depth!))
            case "identity":result["color"]=Self.presentationColor(TimelinePalette.color(forProcessOrThreadID:c.identity!))
            case "state":result["color"]=Self.presentationColor(TimelinePalette.stateColor(raw:c.raw,normalized:c.normalized))
            case "jank":result["color"]=Self.presentationColor(TimelinePalette.jankColor(tag:c.tag!))
            case "annotation":result["color"]=Self.presentationColor(TimelineAnnotationPalette.color(at:c.index!))
            case "rgba":
                let color=TimelineColor(red:c.red!,green:c.green!,blue:c.blue!)
                result["color"]=Self.presentationColor(color);result["alphaRgba"]=color.cgColor(alpha:c.alpha!).components!
            case "track":result["color"]=Self.presentationColor(TimelinePalette.trackIdentityColor(c.text!))
            case "densityColor":
                let descriptor=ParallelDescriptor(source:c.source!,isCollapsed:false,showsNestedDepth:true).value()
                let bucket=TraceDensityBucket(range:try TraceTimeRange.query(startNs:0,endNs:1000),eventCount:1,occupiedNs:nil,utilization:nil,dominant:c.dominant)
                result["color"]=Self.presentationColor(TimelineDensityPalette.color(for:bucket,fallback:TimelinePalette.trackIdentityColor(descriptor.id.rawValue)))
            case "density":
                let viewport=try TimelineViewport(range:TraceTimeRange.query(startNs:0,endNs:1000),widthPoints:200,heightPoints:80,generation:1)
                let descriptor=TrackDescriptor(title:"oracle",source:.cpu(0))
                let bucket=TraceDensityBucket(range:viewport.range,eventCount:c.count!,occupiedNs:nil,utilization:nil,dominant:nil)
                let track=TimelineTrackSnapshot(descriptor:descriptor,y:0,height:28,primitives:[.density(TimelineDensityPrimitive(trackID:descriptor.id,bucket:bucket))])
                let snapshot=TimelineSnapshot(viewport:viewport,tracks:[track],generation:1,dataQuality:TraceDataQuality())
                let view=TimelineNSView(frame:CGRect(x:0,y:0,width:200,height:80))
                result["paint"]=try view.presentationDensityFacts(snapshot)
            default:throw CocoaError(.coderInvalidValue)
            }
            palette.append(result)
        }
        let generic=try decoder.decode([GenericCase].self,from:JSONSerialization.data(withJSONObject:root["genericDetails"]!))
        var genericResults:[[String:Any]]=[]
        let range=try TraceTimeRange(startNs:0,endNs:10);let key=EventKey(table:.callstack,rowID:1)
        for g in generic {
            let inspector=g.inspectorKind.map {kind in TraceEventInspector(key:key,type:kind,name:g.inspectorName,range:range,semanticDurationNs:range.durationNs,isOpenEnded:false,processKey:nil,threadKey:nil,pid:g.pid,tid:g.tid,cpu:nil,processName:nil,threadName:nil,category:g.category,state:g.state,value:nil,unit:nil)}
            let primitive=TimelineDetailPrimitive(trackID:TimelineTrackID(rawValue:"oracle"),eventKey:key,range:range,label:g.label,category:g.category,inspector:inspector,jankTag:g.jankTag)
            genericResults.append(["name":g.name,"color":Self.presentationColor(TimelineDetailPalette.color(for:primitive)),"style":TimelineNSView.presentationStyle(g.category)])
        }
        var dtoResults:[[String:Any]]=[]
        for obj in try XCTUnwrap(root["dto"]as? [Any]) {
            let v=try decoder.decode(DetailOracleVector.self,from:JSONSerialization.data(withJSONObject:obj))
            let viewport=try TimelineViewport(range:v.range,widthPoints:200,heightPoints:80,generation:1)
            let descriptor=ParallelDescriptor(source:v.source,isCollapsed:false,showsNestedDepth:v.showsNestedDepth).value()
            let request=try ViewportRequest(viewport:viewport,tracks:[descriptor],pixelWidth:400,generation:1,preference:.detail,maximumPrimitives:20000,deadline:.now.advanced(by:.seconds(60)))
            let loaded=try await TimelineSnapshotLoader().load(request,repository:DetailOracleRepository(v))
            let snapshot=try XCTUnwrap(loaded)
            let facts=try snapshot.tracks.flatMap(\.primitives).map {primitive -> [String:Any] in
                guard case .detail(let d)=primitive,let inspector=d.inspector else {throw CocoaError(.coderInvalidValue)}
                return ["key":try Self.object(d.eventKey),"kind":inspector.type.rawValue,"range":try Self.object(d.range),
                    "isOpenEnded":inspector.isOpenEnded,"isInstant":inspector.isInstant,"depth":d.depth,"jankTag":d.jankTag,
                    "identity":["processKey":try inspector.processKey.map(Self.object) ?? NSNull(),"threadKey":try inspector.threadKey.map(Self.object) ?? NSNull(),"pid":inspector.pid.map{$0 as Any} ?? NSNull(),"tid":inspector.tid.map{$0 as Any} ?? NSNull()],
                    "label":d.label.map{$0 as Any} ?? NSNull(),"category":d.category.map{$0 as Any} ?? NSNull(),"state":inspector.state.map{$0 as Any} ?? NSNull(),
                    "style":TimelineNSView.presentationStyle(d.category),"color":Self.presentationColor(TimelineDetailPalette.color(for:d))]
            }
            dtoResults.append(["name":v.name,"facts":facts])
        }
        let tokens:[String:Any]=["identity":TimelinePalette.funcColors.map(Self.presentationColor),"states":TimelinePalette.presentationStateTable.mapValues(Self.presentationColor),"unknown":Self.presentationColor(TimelinePalette.unknownStateColor),"grey":Self.presentationColor(TimelinePalette.greyColor),"jank":TimelinePalette.jankColors.map(Self.presentationColor),"annotation":TimelineAnnotationPalette.colors.map(Self.presentationColor)]
        let result:[String:Any]=["palette":palette,"genericDetails":genericResults,"dto":dtoResults,"tokens":tokens]
        try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted,.withoutEscapingSlashes]).write(to:URL(fileURLWithPath:output),options:.atomic)
        XCTAssertEqual(palette.count,cases.count);XCTAssertEqual(dtoResults.count,(root["dto"]as! [Any]).count)
    }
}
