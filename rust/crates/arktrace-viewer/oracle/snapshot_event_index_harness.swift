import ArkTraceCore
import ArkTraceRendering
import Foundation
import XCTest
@testable import ArkTraceAppSupport

private struct IndexInput: Decodable { let schemaVersion: Int; let cases: [IndexCase] }
private struct IndexCase: Decodable {
    let id: String; let snapshotPresent: Bool; let generation: UInt64
    let tracks: [[IndexFact]]; let queries: [EventKey?]
}
private struct IndexFact: Decodable {
    let kind: String; let eventKey: EventKey?; let hasInspector: Bool?
}
@MainActor final class SnapshotEventIndexCanonicalOracleTests: XCTestCase {
    func testActualControllerFirstMatchHoverAndSelection() throws {
        let env = ProcessInfo.processInfo.environment
        let input = try JSONDecoder().decode(IndexInput.self, from: Data(contentsOf: URL(fileURLWithPath: env["ARKTRACE_SNAPSHOT_EVENT_INDEX_INPUT"]!)))
        XCTAssertEqual(input.schemaVersion, 1)
        let defaultsName = "SnapshotEventIndexOracle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let controller = TraceDocumentController(recentStore: TraceRecentDocumentStore(defaults: defaults), maintenance: nil, opener: { _, _ in throw CancellationError() })
        let range = try TraceTimeRange(startNs: 0, endNs: 100)
        var output: [[String: Any]] = []
        for row in input.cases {
            let tracks = try row.tracks.enumerated().map { ti, facts in
                let descriptor = TrackDescriptor(title: "track-\(ti)", source: .cpu(Int64(ti)))
                let primitives: [TimelinePrimitive] = try facts.enumerated().map { pi, fact in
                    if fact.kind == "density" {
                        return .density(TimelineDensityPrimitive(trackID: descriptor.id, bucket: TraceDensityBucket(range: range, eventCount: 7, occupiedNs: nil, utilization: nil, dominant: nil)))
                    }
                    XCTAssertEqual(fact.kind, "detail")
                    let key = try XCTUnwrap(fact.eventKey)
                    // A minimal real Inspector carries a unique position marker. No facts projection is tested here.
                    let inspector = fact.hasInspector == true ? TraceEventInspector(key: key, type: .namedSlice, name: "\(ti):\(pi)", range: range, semanticDurationNs: 100, isOpenEnded: false, processKey: nil, threadKey: nil, pid: nil, tid: nil, cpu: nil, processName: nil, threadName: nil, category: nil, state: nil, value: nil, unit: nil) : nil
                    return .detail(TimelineDetailPrimitive(trackID: descriptor.id, eventKey: key, range: range, inspector: inspector))
                }
                return TimelineTrackSnapshot(descriptor: descriptor, y: Double(ti * 24), height: 24, primitives: primitives)
            }
            let viewport = try TimelineViewport(range: range, widthPoints: 100, heightPoints: 100, generation: row.generation)
            let snapshot = row.snapshotPresent ? TimelineSnapshot(viewport: viewport, tracks: tracks, generation: row.generation, dataQuality: TraceDataQuality()) : nil
            // Reuse the controller across installs, including equal-generation replacements.
            controller.snapshotEventIndexOracleInstall(snapshot)
            for (qi, key) in row.queries.enumerated() {
                let direct = controller.snapshotEventIndexOracleInspector(key)
                let position = controller.snapshotEventIndexOraclePosition
                controller.snapshotEventIndexOracleResetPosition()
                controller.hoverEvent(key)
                let hoverPosition = controller.snapshotEventIndexOraclePosition
                let hover = controller.hoveredEvent
                controller.snapshotEventIndexOracleResetPosition()
                controller.selectEvent(key)
                let selectPosition = controller.snapshotEventIndexOraclePosition
                let selected = controller.selectedEvent
                XCTAssertEqual(position, hoverPosition, row.id)
                XCTAssertEqual(position, selectPosition, row.id)
                XCTAssertEqual(direct, hover, row.id)
                XCTAssertEqual(direct, selected, row.id)
                var lookup: [String: Any] = ["kind": "noMatch"]
                if let position {
                    XCTAssertEqual(position.count, 2)
                    lookup = ["kind": "matched", "location": ["trackIndex": position[0], "primitiveIndex": position[1], "hasInspector": direct != nil]]
                }
                output.append(["caseID": row.id, "queryIndex": qi, "lookup": lookup,
                    "directMarker": direct?.name as Any? ?? NSNull(), "hoverMarker": hover?.name as Any? ?? NSNull(), "selectMarker": selected?.name as Any? ?? NSNull(),
                    "hoverPosition": hoverPosition as Any? ?? NSNull(), "selectPosition": selectPosition as Any? ?? NSNull()])
            }
        }
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "platform": ProcessInfo.processInfo.operatingSystemVersionString, "cases": input.cases.count, "rows": output], options: [.sortedKeys]).write(to: URL(fileURLWithPath: env["ARKTRACE_SNAPSHOT_EVENT_INDEX_OUTPUT"]!))
        XCTAssertEqual(output.count, input.cases.reduce(0) { $0 + $1.queries.count })
    }
}
