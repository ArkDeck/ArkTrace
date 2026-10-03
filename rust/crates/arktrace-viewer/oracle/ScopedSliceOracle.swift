import ArkTraceCore
import ArkTraceStore
import ArkTraceRendering
import Foundation

private struct Vector: Decodable, Sendable {
    let name: String
    let view: String
    let range: TraceTimeRange
    let threadKey: ThreadKey?
    let focusedEventKey: EventKey?
    let limit: Int
    let source: TraceDensitySource?
    let scope: CounterScope?
    let filterID: Int64?
}
private struct Page<T: Encodable & Sendable>: Encodable {
    let items: [T]
    let truncated: Bool
    let capabilityAvailable: Bool
    let dataQuality: TraceDataQuality
    init(_ page: TraceEventPage<T>) {
        items = page.items; truncated = page.truncated
        capabilityAvailable = page.capabilityAvailable; dataQuality = page.dataQuality
    }
}
@main struct ScopedSliceOracle {
    static func main() async throws {
        let args = CommandLine.arguments
        let output = try await Task.detached {
            guard args.count == 4 else { throw CocoaError(.coderInvalidValue) }
            let decoder = JSONDecoder()
            let parser = try decoder.decode(TraceParserIdentity.self, from: Data(args[2].utf8))
            let cases = try decoder.decode([Vector].self, from: Data(args[3].utf8))
            let repository = try SQLiteTraceRepository(databaseURL: URL(filePath: args[1]), parser: parser,
                source: TraceSourceDescriptor(traceSHA256: String(repeating: "a", count: 64), sourceByteCount: 1))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var records: [[String: Any]] = []
            for value in cases {
                let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                let encoded: Data
                if value.view == "general" {
                    encoded = try encoder.encode(Page(try await repository.slices(TraceSliceQuery(
                        range: value.range, threadKey: value.threadKey, limit: value.limit, deadline: deadline))))
                } else if value.view == "counter" {
                    encoded = try encoder.encode(Page(try await repository.counters(CounterQuery(
                        range: value.range, scope: value.scope, filterID: value.filterID,
                        limit: value.limit, deadline: deadline))))
                } else {
                    let viewport = try TimelineViewport(range: value.range, widthPoints: 200, heightPoints: 200, generation: 1)
                    let source: TimelineTrackSource
                    switch value.source {
                    case .some(.cpuCounter(let id, let cpu)): source = .cpuCounter(filterID: id, cpu: cpu)
                    case .some(.processCounter(let id, let process)): source = .processCounter(filterID: id, processKey: process)
                    case nil: source = .namedSlice(value.threadKey)
                    default: throw CocoaError(.coderInvalidValue)
                    }
                    let track = TrackDescriptor(title: "scope oracle", source: source)
                    let request = try ViewportRequest(viewport: viewport, tracks: [track], pixelWidth: 400, generation: 1,
                        preference: value.view == "density" ? .density : .detail, maximumPrimitives: value.limit,
                        focusedEventKey: value.focusedEventKey, deadline: deadline)
                    guard let snapshot = try await TimelineSnapshotLoader().load(request, repository: repository) else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    encoded = try encoder.encode(snapshot)
                }
                records.append(["name":value.name,"result":try JSONSerialization.jsonObject(with: encoded)])
            }
            return try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys, .withoutEscapingSlashes])
        }.value
        try FileHandle.standardOutput.write(contentsOf: output)
        try FileHandle.standardOutput.write(contentsOf: Data([10]))
    }
}
