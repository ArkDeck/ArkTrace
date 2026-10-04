// Append to the cache copy of the original tests and existing carrier helpers.
// Repository DTOs are already proven native by inherited receipts. This actor
// only returns those DTOs; actual SnapshotLoader and DetailPalette do the work.
extension TimelineRenderingTests {
    @MainActor
    func testActualCounterCombinationOracle() async throws {
        let input = try XCTUnwrap(ProcessInfo.processInfo.environment["COUNTER_SWIFT_INPUT"])
        let output = try XCTUnwrap(ProcessInfo.processInfo.environment["COUNTER_SWIFT_OUTPUT"])
        let vectors = try JSONDecoder().decode([DetailOracleVector].self, from: Data(contentsOf: URL(fileURLWithPath: input)))
        var result: [[String: Any]] = []
        for v in vectors {
            let viewport = try TimelineViewport(range: v.range, widthPoints: 200, heightPoints: 1000, generation: 1)
            let descriptor = ParallelDescriptor(source: v.source, isCollapsed: false, showsNestedDepth: false).value()
            let request = try ViewportRequest(viewport: viewport, tracks: [descriptor], pixelWidth: 400,
                generation: 1, preference: .detail, maximumPrimitives: 20000,
                deadline: .now.advanced(by: .seconds(60)))
            let loaded = try await TimelineSnapshotLoader().load(request, repository: DetailOracleRepository(v))
            let snapshot = try XCTUnwrap(loaded)
            let facts = try snapshot.tracks.flatMap(\.primitives).map { p -> [String: Any] in
                guard case .detail(let d) = p, let i = d.inspector else { throw CocoaError(.coderInvalidValue) }
                let color = TimelineDetailPalette.color(for: d)
                return ["key": try Self.object(d.eventKey), "kind": i.type.rawValue, "range": try Self.object(d.range),
                    "isOpenEnded": i.isOpenEnded, "isInstant": i.isInstant, "depth": d.depth, "jankTag": d.jankTag,
                    "identity": ["processKey": try i.processKey.map(Self.object) ?? NSNull(), "threadKey": try i.threadKey.map(Self.object) ?? NSNull(),
                        "pid": i.pid.map { $0 as Any } ?? NSNull(), "tid": i.tid.map { $0 as Any } ?? NSNull()],
                    "label": d.label.map { $0 as Any } ?? NSNull(), "category": d.category.map { $0 as Any } ?? NSNull(),
                    "state": i.state.map { $0 as Any } ?? NSNull(), "style": TimelineNSView.counterCombinationStyle(d.category),
                    "color": ["rgb": ["red": Int(color.red), "green": Int(color.green), "blue": Int(color.blue)],
                        "rgba": color.cgColor.components!, "foreground": ["red": Int(color.preferredLabelColor.red),
                            "green": Int(color.preferredLabelColor.green), "blue": Int(color.preferredLabelColor.blue)]]]
            }
            result.append(["name": v.name, "facts": facts])
        }
        XCTAssertEqual(vectors.count, 6)
        XCTAssertEqual(result.flatMap { $0["facts"] as! [[String: Any]] }.count, 11)
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
            .write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
