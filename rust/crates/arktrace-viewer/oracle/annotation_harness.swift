// Runs actual public mutations, navigation commands, restoration and save().
// Input assignment / private reads / range interception are in access seam.
private func annotationJSON<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
}
private func annotationRange(_ value: Any?) throws -> TraceTimeRange? {
    guard let value, !(value is NSNull) else { return nil }
    return try JSONDecoder().decode(TraceTimeRange.self, from: JSONSerialization.data(withJSONObject: value))
}
private func annotationInteger(_ value: Any?) -> Int64? {
    (value as? NSNumber)?.int64Value
}
extension TraceDocumentControllerTests {
    func testActualAnnotationOracle() async throws {
        let input = try Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["ARKTRACE_ANNOTATION_INPUT"]!))
        let rootJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: input) as? [String: Any])
        let cases = try XCTUnwrap(rootJSON["cases"] as? [[String: Any]])
        var results: [[String: Any]] = []
        for vector in cases {
            let name = try XCTUnwrap(vector["name"] as? String)
            let root = FileManager.default.temporaryDirectory.appending(path: "arktrace-annotation-oracle-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appending(path: "trace.htrace")
            try Data().write(to: source)
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "ArkTraceAnnotationOracle.\(UUID().uuidString)"))
            let store = try TraceViewStateStoreTests().makeStore(root: root.appending(path: "restore"))
            let projectionStore = try TraceViewStateStoreTests().makeStore(root: root.appending(path: "projection"))
            let flags = try JSONDecoder().decode([TimelineFlag].self, from: JSONSerialization.data(withJSONObject: vector["flags"]!))
            let marks = try JSONDecoder().decode([TimelineMark].self, from: JSONSerialization.data(withJSONObject: vector["marks"]!))
            let sidecar = TraceViewStateSidecar(formatVersion: 1, traceSHA256: String(repeating: "a", count: 64), flags: flags, marks: marks, favoriteTrackIDs: nil)
            try JSONEncoder().encode(sidecar).write(to: store.entryURL.appending(path: TraceViewStateStore.fileName))
            let duration = annotationInteger(vector["durationNs"])
            let controller = TraceDocumentController(recentStore: TraceRecentDocumentStore(defaults: defaults), maintenance: nil, opener: { _, _ in
                TraceOpenedDocument(repository: Repository(identity: "a", durationNs: duration ?? 1000), cacheHit: false, cacheMetadata: nil, viewStateStore: store, close: {})
            })
            if duration != nil {
                controller.open(source)
                for _ in 0..<100000 where controller.phase != .ready { await Task.yield() }
                XCTAssertEqual(controller.phase, .ready, name)
            }
            func snapshot(_ created: [String: Any]?, rejected: Bool = false) throws -> [String: Any] {
                // Save to a separate real store to observe the projection, not
                // the previous action's on-disk state or a copied filter formula.
                projectionStore.save(annotations: controller.annotations, favoriteTrackIDs: [])
                let saved = projectionStore.load().annotations
                var probes: [[String: Any]] = []
                for raw in vector["anchors"] as! [NSNumber] {
                    let t = raw.int64Value
                    probes.append(["timestampNs": t,
                        "flagAfter": controller.annotations.flag(after: t)?.id as Any? ?? NSNull(),
                        "flagBefore": controller.annotations.flag(before: t)?.id as Any? ?? NSNull(),
                        "markAfter": controller.annotations.mark(after: t)?.id as Any? ?? NSNull(),
                        "markBefore": controller.annotations.mark(before: t)?.id as Any? ?? NSNull()])
                }
                return ["flags": try annotationJSON(controller.annotations.flags), "marks": try annotationJSON(controller.annotations.marks),
                    "orderedFlags": try annotationJSON(controller.annotations.orderedFlags), "orderedMarks": try annotationJSON(controller.annotations.orderedMarks),
                    "pointRanges": try controller.annotations.flags.map { ["id": $0.id, "range": try annotationJSON($0.pointRange)] },
                    "nextID": controller.annotationOracleNextID, "sessionID": controller.annotationSessionID, "isEmpty": controller.annotations.isEmpty,
                    "persistence": ["flags": try annotationJSON(saved.flags), "marks": try annotationJSON(saved.marks)],
                    "created": created as Any? ?? NSNull(), "persistCount": TraceDocumentController.annotationOraclePersistCount,
                    "reveals": try annotationJSON(TraceDocumentController.annotationOracleReveals), "guardRejected": rejected, "probes": probes]
            }
            TraceDocumentController.annotationOracleBegin()
            var states = [try snapshot(nil)]
            for action in vector["steps"] as! [[String: Any]] {
                TraceDocumentController.annotationOracleBegin()
                try controller.annotationOracleContext(viewport: annotationRange(action["viewportRange"]), selection: annotationRange(action["selectedRange"]), event: annotationRange(action["selectedEventRange"]))
                let kind = action["action"] as! String
                let id = Int(annotationInteger(action["id"]) ?? 0)
                let label = action["label"] as? String
                let color = annotationInteger(action["colorIndex"]).map(Int.init)
                var created: [String: Any]?
                var rejected = false
                switch kind {
                case "addFlag":
                    if let f = controller.addFlag(atNs: annotationInteger(action["timestampNs"])!, label: label) { created = ["kind": "flag", "id": f.id] }
                case "addMark":
                    if let m = controller.addMark(isPersistent: action["isPersistent"] as! Bool, label: label) { created = ["kind": "mark", "id": m.id] }
                case "updateFlag": controller.updateFlag(id: id, label: label, colorIndex: color)
                case "updateMark": controller.updateMark(id: id, label: label, colorIndex: color)
                case "removeFlag": controller.removeFlag(id: id)
                case "removeMark": controller.removeMark(id: id)
                case "cycleFlagColor":
                    if let f = controller.annotations.flags.first(where: { $0.id == id }) { controller.updateFlag(id: id, colorIndex: f.colorIndex + 1) }
                case "cycleMarkColor":
                    if let m = controller.annotations.marks.first(where: { $0.id == id }) { controller.updateMark(id: id, colorIndex: m.colorIndex + 1) }
                case "deferredRenameFlag":
                    let captured = (action["capturedSessionID"] as! NSNumber).uint64Value
                    rejected = captured != controller.annotationSessionID
                    controller.annotationOracleDeferredRename(id: id, label: label!, sessionID: captured)
                case "replaceSession":
                    // Actual open() clears synchronously; the same content then
                    // legitimately restores the saved persistent projection.
                    try? FileManager.default.removeItem(at: store.entryURL.appending(path: TraceViewStateStore.fileName))
                    controller.open(source)
                    for _ in 0..<100000 where controller.phase != .ready { await Task.yield() }
                    XCTAssertEqual(controller.phase, .ready, name)
                case "cancelSession": controller.cancel()
                case "closeSession": await controller.close()
                case "command":
                    let before = controller.annotations.marks
                    let command: TimelineAnnotationCommand
                    switch action["command"] as! String {
                    case "nextFlag": command = .nextFlag
                    case "previousFlag": command = .previousFlag
                    case "nextMark": command = .nextMark
                    case "previousMark": command = .previousMark
                    case "nearest": command = .scrollNearestFlagIntoView
                    case "createPersistent": command = .createMark(isPersistent: true)
                    case "createTransient": command = .createMark(isPersistent: false)
                    default: fatalError("unknown input command")
                    }
                    controller.handleAnnotationCommand(command)
                    if let m = controller.annotations.marks.last, !before.contains(where: { $0.id == m.id }) { created = ["kind": "mark", "id": m.id] }
                default: fatalError("unknown input action")
                }
                states.append(try snapshot(created, rejected: rejected))
            }
            TraceDocumentController.annotationOracleEnd()
            await controller.close()
            results.append(["name": name, "states": states])
        }
        let output: [String: Any] = ["cases": results]
        try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["ARKTRACE_ANNOTATION_OUTPUT"]!))
    }
}
