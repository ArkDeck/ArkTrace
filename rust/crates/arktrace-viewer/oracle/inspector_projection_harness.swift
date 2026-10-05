import ArkTraceCore
@testable import ArkTraceRendering
import Foundation
import XCTest

private actor InspectorProjectionOracleRepository: TraceRepositoryProtocol {
    func cpuCatalog(_ query: TraceCPUCatalogQuery) async throws -> TraceCPUCatalog { .unavailable }

    let cpu: [CpuSlice]; let states: [ThreadStateInterval]; let named: [TraceSlice]
    let framesInput: [TraceFrame]; let counterInput: [CounterSeries]
    init(cpu: [CpuSlice] = [], states: [ThreadStateInterval] = [], named: [TraceSlice] = [], frames: [TraceFrame] = [], counters: [CounterSeries] = []) {
        self.cpu = cpu; self.states = states; self.named = named; self.framesInput = frames; self.counterInput = counters
    }
    func metadata() async throws -> TraceMetadata { throw CancellationError() }
    func processes(_ q: ProcessQuery) async throws -> BoundedPage<TraceProcess> { BoundedPage(items: [], truncated: false) }
    func threads(_ q: ThreadQuery) async throws -> BoundedPage<TraceThread> { BoundedPage(items: [], truncated: false) }
    func summaryFacts(_ q: TraceSummaryQuery) async throws -> TraceSummaryFacts { throw CancellationError() }
    func cpuSlices(_ q: CpuSliceQuery) async throws -> TraceEventPage<CpuSlice> { TraceEventPage(items: cpu, truncated: false) }
    func threadStates(_ q: ThreadStateQuery) async throws -> TraceEventPage<ThreadStateInterval> { TraceEventPage(items: states, truncated: false) }
    func slices(_ q: TraceSliceQuery) async throws -> TraceEventPage<TraceSlice> { TraceEventPage(items: named, truncated: false) }
    func frames(_ q: TraceFrameQuery) async throws -> TraceEventPage<TraceFrame> { TraceEventPage(items: framesInput, truncated: false) }
    func counters(_ q: CounterQuery) async throws -> TraceEventPage<CounterSeries> { TraceEventPage(items: counterInput, truncated: false) }
}
final class InspectorProjectionOracleTests: XCTestCase {
    private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed) }
    private func optional<T: Encodable>(_ value: T?) throws -> Any { try value.map(object) ?? NSNull() }
    @MainActor
    func testActualLoaderInspectorFacts() async throws {
        let env = ProcessInfo.processInfo.environment
        let input = try XCTUnwrap(env["ARKTRACE_INSPECTOR_PROJECTION_INPUT"])
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: input))) as! [String: Any]
        let decoder = JSONDecoder()
        var output: [[String: Any]] = []
        for item in root["cases"] as! [[String: Any]] {
            let data = try JSONSerialization.data(withJSONObject: item["events"]!)
            let query = try decoder.decode(TraceTimeRange.self, from: JSONSerialization.data(withJSONObject: item["queryRange"]!))
            let repository: InspectorProjectionOracleRepository
            let source: TimelineTrackSource
            switch item["kind"] as! String {
            case "cpuSlice": repository = InspectorProjectionOracleRepository(cpu: try decoder.decode([CpuSlice].self, from: data)); source = .cpu(0)
            case "threadState": repository = InspectorProjectionOracleRepository(states: try decoder.decode([ThreadStateInterval].self, from: data)); source = .threadState(ThreadKey(itid: 0))
            case "namedSlice": repository = InspectorProjectionOracleRepository(named: try decoder.decode([TraceSlice].self, from: data)); source = .namedSlice(nil)
            case "frame": repository = InspectorProjectionOracleRepository(frames: try decoder.decode([TraceFrame].self, from: data)); source = .frame(nil)
            case "counter":
                let descriptor = try decoder.decode(CounterSeriesDescriptor.self, from: JSONSerialization.data(withJSONObject: item["series"]!))
                let series = CounterSeries(filterID: descriptor.filterID, name: descriptor.name, scope: descriptor.scope,
                    cpu: descriptor.cpu, processKey: descriptor.processKey, pid: descriptor.pid, processName: descriptor.processName,
                    unit: descriptor.unit, samples: try decoder.decode([CounterSample].self, from: data))
                repository = InspectorProjectionOracleRepository(counters: [series])
                source = descriptor.scope == .cpu ? .cpuCounter(filterID: descriptor.filterID, cpu: descriptor.cpu) : .processCounter(filterID: descriptor.filterID, processKey: descriptor.processKey)
            case "densityBand":
                let descriptor = TrackDescriptor(title: "oracle", source: .cpu(0))
                let bucket = TraceDensityBucket(range: query, eventCount: 1, occupiedNs: nil, utilization: nil, dominant: nil)
                let primitive = TimelinePrimitive.density(TimelineDensityPrimitive(trackID: descriptor.id, bucket: bucket))
                let inspector: TraceEventInspector?
                if case .detail(let detail) = primitive { inspector = detail.inspector } else { inspector = nil }
                output.append(["id": item["id"]!, "facts": [try optional(inspector)]])
                continue
            default: throw CocoaError(.coderInvalidValue)
            }
            let track = TrackDescriptor(title: "oracle", source: source)
            let primitives = try await TimelineSnapshotLoader().inspectorProjectionOracleDetails(track: track, range: query, repository: repository)
            let facts = try primitives.map { primitive -> [String: Any] in
                guard case .detail(let detail) = primitive, let f = detail.inspector else { throw CocoaError(.coderInvalidValue) }
                return ["key": try object(f.key), "kind": f.type.rawValue, "name": try optional(f.name),
                    "range": try object(f.range), "semanticDurationNs": try optional(f.semanticDurationNs),
                    "isOpenEnded": f.isOpenEnded, "isInstant": f.isInstant,
                    "processKey": try optional(f.processKey), "threadKey": try optional(f.threadKey),
                    "pid": try optional(f.pid), "tid": try optional(f.tid), "cpu": try optional(f.cpu),
                    "processName": try optional(f.processName), "threadName": try optional(f.threadName),
                    "category": try optional(f.category), "state": try optional(f.state),
                    "value": try optional(f.value), "unit": try optional(f.unit), "priority": try optional(f.priority)]
            }
            output.append(["id": item["id"]!, "facts": facts])
        }
        let result: [String: Any] = ["schemaVersion": 1, "cases": output]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]).write(to: URL(fileURLWithPath: try XCTUnwrap(env["ARKTRACE_INSPECTOR_PROJECTION_OUTPUT"])))
    }
}
