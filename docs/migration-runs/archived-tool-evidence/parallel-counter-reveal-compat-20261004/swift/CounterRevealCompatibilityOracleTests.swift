import ArkTraceCore
import ArkTraceStore
import ArkTraceRendering
import ArkTraceRuntime
import AppKit
import Foundation
import XCTest
@testable import ArkTraceAppSupport

@MainActor final class CounterRevealCompatibilityOracleTests: XCTestCase {
    private func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }
    private func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
    private func tree(_ controller: TraceDocumentController) throws -> [String: Any] {
        ["groups": try controller.trackGroups.map { group in
            ["id": group.id, "kind": group.kind.rawValue,
             "processKey": try group.processKey.map(object) ?? NSNull(),
             "title": group.title, "capabilityAvailable": group.capabilityAvailable,
             "truncated": group.truncated, "tracks": try group.tracks.map { track in
                ["title": track.title, "descriptor": ["source": try object(track.source),
                    "isCollapsed": track.isCollapsed, "showsNestedDepth": track.showsNestedDepth]]
             }] as [String: Any]
        }]
    }
    private func state(_ controller: TraceDocumentController) throws -> [String: Any] {
        var threads = try object(controller.counterRevealThreads) as! [[String: Any]]
        // Existing Rust directory DTO uses scalar keys. Format adapter only.
        for index in threads.indices {
            threads[index]["key"] = (threads[index]["key"] as! [String: Any])["itid"]
            if let key = threads[index]["processKey"] as? [String: Any] {
                threads[index]["processKey"] = key["ipid"]
            }
        }
        return ["identity": ["sessionId": 71, "generation": 8], "tree": try tree(controller),
                "catalogThreads": threads, "capabilities": try object(controller.metadata!.capabilities),
                "bounds": ["startNs": 0, "endNs": controller.metadata!.durationNs],
                "viewportRange": try object(controller.snapshot!.viewport.range),
                "processFilterText": controller.processFilterText,
                "favoriteTrackIds": controller.favoriteTrackIDs.map(\.rawValue),
                "searchResults": [], "searchResultsTruncated": false,
                "searchSelectionIndex": NSNull(), "pendingSelectionKey": NSNull()]
    }
    private func fullFacts(_ inspector: TraceEventInspector) throws -> [String: Any] {
        var facts = try object(inspector) as! [String: Any]
        facts["kind"] = facts.removeValue(forKey: "type")
        facts["isInstant"] = inspector.isInstant
        for key in ["name", "semanticDurationNs", "processKey", "threadKey", "pid", "tid", "cpu",
                    "processName", "threadName", "category", "state", "value", "unit", "priority"] {
            if facts[key] == nil { facts[key] = NSNull() }
        }
        return facts
    }
    func testRealCounterKeysThroughNativeFocusSelectionAndReveal() async throws {
        let env = ProcessInfo.processInfo.environment
        let inputPath = env["COUNTER_REVEAL_CASES"]!
        let input = try await Task.detached { try Data(contentsOf: URL(filePath: inputPath)) }.value
        let cases = try JSONSerialization.jsonObject(with: input) as! [[String: Any]]
        XCTAssertLessThanOrEqual(cases.count, 16)
        var output: [[String: Any]] = []
        for value in cases where value["inspectors"] != nil {
            let fixture = value["fixture"] as! String
            let database = URL(filePath: env["COUNTER_REVEAL_DATABASES"]!).appending(path: fixture).appending(path: "fixture.sqlite")
            let parserPath = env["COUNTER_REVEAL_PARSER"]!
            let repository = try await Task.detached {
                let parser = try JSONDecoder().decode(TraceParserIdentity.self, from: Data(contentsOf: URL(filePath: parserPath)))
                return try SQLiteTraceRepository(databaseURL: database, parser: parser,
                    source: TraceSourceDescriptor(traceSHA256: String(repeating: "a", count: 64), sourceByteCount: Int64(try Data(contentsOf: database).count)))
            }.value
            let source = try decode(TimelineTrackSource.self, value["source"]!)
            let descriptor = TrackDescriptor(title: value["title"] as! String, source: source)
            let frozenFacts = value["inspectors"] as! [[String: Any]]
            let inspectors = try frozenFacts.map { fact in
                var codable = fact; codable["type"] = codable.removeValue(forKey: "kind")
                return try decode(TraceEventInspector.self, codable)
            }
            let primitives = inspectors.map { inspector in
                TimelinePrimitive.detail(TimelineDetailPrimitive(trackID: descriptor.id,
                    eventKey: inspector.key, range: inspector.range, inspector: inspector))
            }
            let viewport = try TimelineViewport(range: TraceTimeRange.query(startNs: 0, endNs: 1000),
                widthPoints: 100, heightPoints: 100, generation: 0)
            let snapshot = TimelineSnapshot(viewport: viewport,
                tracks: [TimelineTrackSnapshot(descriptor: descriptor, y: 0, height: 100, primitives: primitives)],
                generation: 0, dataQuality: TraceDataQuality())
            let defaults = UserDefaults(suiteName: "CounterRevealCompatibility.\(UUID().uuidString)")!
            let controller = TraceDocumentController(recentStore: TraceRecentDocumentStore(defaults: defaults),
                maintenance: nil, opener: { _, _ in throw CancellationError() })
            try await controller.counterRevealInstall(repository: repository, snapshot: snapshot)
            let before = try state(controller)
            controller.counterRevealAdmit(descriptor)
            let admitted = try tree(controller)
            let view = TimelineNSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            view.snapshot = snapshot
            view.onSelectEvent = { controller.selectEvent($0) }
            var steps: [[String: Any]] = []
            let ordinal = (value["targetOrdinal"] as! NSNumber).intValue
            for _ in 0...ordinal {
                XCTAssertTrue(view.performKeyboardCommand(.nextEvent))
                steps.append(["trackID": view.focusedTrackID!.rawValue, "key": try object(view.focusedEventKey!)])
            }
            XCTAssertTrue(view.performKeyboardCommand(.selectFocusedEvent))
            let selected = try XCTUnwrap(controller.selectedEvent)
            XCTAssertEqual(selected.key, try decode(EventKey.self, value["afterEvent"]!))
            let selectedBeforeReveal = try fullFacts(selected)
            controller.counterRevealRange(selected.range)
            XCTAssertEqual(controller.selectedEvent, selected)
            output.append(["id": value["id"]!, "beforeState": before, "admittedTree": admitted,
                "focusSteps": steps, "focused": ["trackID": view.focusedTrackID!.rawValue,
                "key": try object(view.focusedEventKey!)], "selectedInspector": selectedBeforeReveal,
                "treeAfterReveal": try tree(controller), "viewportAfterReveal": try object(controller.snapshot!.viewport.range),
                "pendingKeyAfterReveal": try controller.counterRevealPendingKey.map(object) ?? NSNull(),
                "source": try object(source)])
        }
        XCTAssertEqual(output.count, 6)
        let bytes = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let outputPath = env["COUNTER_REVEAL_SWIFT"]!
        try await Task.detached { try bytes.write(to: URL(filePath: outputPath)) }.value
    }
}
