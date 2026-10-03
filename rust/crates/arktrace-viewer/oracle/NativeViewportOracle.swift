import ArkTraceCore
import ArkTraceStore
import ArkTraceRendering
import Foundation

private struct WireTrack: Decodable, Sendable {
    let source: TraceDensitySource
    let isCollapsed: Bool
    let showsNestedDepth: Bool
    func value() -> TrackDescriptor {
        let kind: TimelineTrackSource
        switch source {
        case .cpu(let cpu): kind = .cpu(cpu)
        case .threadState(let thread): kind = .threadState(thread)
        case .namedSlice(let thread): kind = .namedSlice(thread)
        case .cpuCounter(let id, let cpu): kind = .cpuCounter(filterID: id, cpu: cpu)
        case .processCounter(let id, let process): kind = .processCounter(filterID: id, processKey: process)
        case .frame(let process): kind = .frame(process)
        }
        return TrackDescriptor(title: "native oracle", source: kind, isCollapsed: isCollapsed,
            showsNestedDepth: showsNestedDepth)
    }
}
private struct WireRequest: Decodable, Sendable {
    let viewport: TimelineViewport
    let tracks: [WireTrack]
    let pixelWidth: Int
    let generation: UInt64
    let preference: TimelineDetailPreference
    let maximumPrimitives: Int?
    let focusedEventKey: EventKey?
    func value() throws -> ViewportRequest {
        try ViewportRequest(viewport: viewport, tracks: tracks.map { $0.value() }, pixelWidth: pixelWidth,
            generation: generation, preference: preference, maximumPrimitives: maximumPrimitives,
            focusedEventKey: focusedEventKey, deadline: .now.advanced(by: .seconds(30)))
    }
}
private struct WireResolution: Decodable, Sendable {
    let source: TraceDensitySource
    let bucket: TraceTimeRange
    let timeNs: Int64
}
private struct Vector: Decodable, Sendable {
    let name: String
    let request: WireRequest?
    let resolution: WireResolution?
    let backingScale: Double
}
@main struct NativeViewportOracle {
    struct Source: Decodable { let sha256: String; let byteCount: Int64 }
    static func object<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
    }
    // This adapter retains every closed quality fact, redacting only human
    // messages at the machine boundary. The full Swift snapshot is retained.
    static func quality(_ value: TraceDataQuality) throws -> [String: Any] {
        guard value.issues.count <= 4096,
            value.issues.allSatisfy({ $0.category != .unclassified && ($0.count == nil || $0.count! >= 0)
                && ($0.scope == nil || TraceDataQualityScope.machineAllowed.contains($0.scope!)) })
        else { throw CocoaError(.coderInvalidValue) }
        let issues = value.issues.sorted {
            ($0.category.rawValue, $0.scope ?? "", $0.count ?? .min)
                < ($1.category.rawValue, $1.scope ?? "", $1.count ?? .min)
        }
        return ["status": value.status.rawValue, "warnings": issues.map {
            ["category": $0.category.rawValue, "scope": $0.scope as Any? ?? NSNull(),
                "count": $0.count as Any? ?? NSNull(), "message": NSNull()]
        }]
    }
    static func projection(_ snapshot: TimelineSnapshot, scale: Double) async throws -> [String: Any] {
        var tracks: [[String: Any]] = []
        for track in snapshot.tracks {
            var primitives: [[String: Any]] = []
            for primitive in track.primitives {
                let input: [String: Any]
                switch primitive {
                case .detail(let detail):
                    let style = await TimelineNSView.detailOracleStyleName(detail.category)
                    input = ["kind": "detail", "detail": ["eventKey": try object(detail.eventKey),
                        "range": try object(detail.range), "depth": detail.depth, "style": style,
                        "isOpenEnded": detail.inspector?.isOpenEnded ?? false]]
                case .density(let density): input = ["kind": "density", "bucket": try object(density.bucket)]
                }
                let visible = TimelineGeometry.isVisible(primitive, in: snapshot.viewport)
                var frame: Any = NSNull()
                if visible {
                    let rect = TimelineGeometry.frame(for: primitive, in: track, viewport: snapshot.viewport,
                        backingScale: CGFloat(scale))
                    frame = ["x": rect.origin.x, "y": rect.origin.y,
                        "width": rect.width, "height": rect.height]
                }
                primitives.append(["input": input, "visible": visible, "frame": frame])
            }
            tracks.append(["descriptor": ["source": try object(track.descriptor.source.nativeOracleDensitySource),
                "isCollapsed": track.descriptor.isCollapsed, "showsNestedDepth": track.descriptor.showsNestedDepth],
                "y": track.y, "height": track.height, "depthRowCount": track.depthRowCount,
                "primitives": primitives])
        }
        return ["viewport": try object(snapshot.viewport), "sourceGeneration": snapshot.generation,
            "backingScale": scale, "tracks": tracks, "dataQuality": try quality(snapshot.dataQuality)]
    }
    static func main() async throws {
        let args = CommandLine.arguments
        let output = try await Task.detached {
            guard args.count == 5 else { throw CocoaError(.coderInvalidValue) }
            let decoder = JSONDecoder()
            let parser = try decoder.decode(TraceParserIdentity.self, from: Data(args[2].utf8))
            let source = try decoder.decode(Source.self, from: Data(args[3].utf8))
            let cases = try decoder.decode([Vector].self, from: Data(args[4].utf8))
            let repository = try SQLiteTraceRepository(databaseURL: URL(filePath: args[1]), parser: parser,
                source: TraceSourceDescriptor(traceSHA256: source.sha256, sourceByteCount: source.byteCount))
            let loader = TimelineSnapshotLoader()
            var records: [[String: Any]] = []
            for value in cases {
                if let wire = value.request {
                    let request = try wire.value()
                    let snapshot = try await loader.load(request, repository: repository)
                    let projected: Any = if let snapshot { try await projection(snapshot, scale: value.backingScale) }
                        else { NSNull() }
                    records.append(["name": value.name, "projected": projected,
                        "fullSwiftSnapshot": try object(snapshot)])
                } else if let resolution = value.resolution {
                    let track = WireTrack(source: resolution.source, isCollapsed: false, showsNestedDepth: true).value()
                    let inspector = try await loader.resolveEvent(TimelineDensityHit(trackID: track.id,
                        bucket: resolution.bucket, timeNs: resolution.timeNs), track: track,
                        deadline: .now.advanced(by: .seconds(30)), repository: repository)
                    let selected: Any = if let inspector {
                        ["eventKey": try object(inspector.key), "range": try object(inspector.range),
                            "isOpenEnded": inspector.isOpenEnded]
                    } else { NSNull() }
                    records.append(["name": value.name, "selected": selected,
                        "fullSwiftInspector": try object(inspector)])
                } else { throw CocoaError(.coderInvalidValue) }
            }
            return try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys, .withoutEscapingSlashes])
        }.value
        try FileHandle.standardOutput.write(contentsOf: output)
        try FileHandle.standardOutput.write(contentsOf: Data([10]))
    }
}
