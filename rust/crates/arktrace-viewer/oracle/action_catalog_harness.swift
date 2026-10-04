
@MainActor
private final class ActionCatalogForwardRecorder: NSResponder {
    var events = 0
    override func keyDown(with event: NSEvent) { events += 1 }
}

extension TimelineNavigationKeyTests {
    @MainActor
    func testActualActionCatalogKeyboardOracle() throws {
        let env = ProcessInfo.processInfo.environment
        let input = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(env["ARKTRACE_ACTION_CATALOG_INPUT"])))) as! [String: Any]
        var output: [[String: Any]] = []
        ActionCatalogOracleProbe.enabled = true
        defer { ActionCatalogOracleProbe.enabled = false }
        for item in input["cases"] as! [[String: Any]] {
            let (view, _) = try makeView()
            let recorder = ActionCatalogForwardRecorder()
            view.nextResponder = recorder
            var annotations: [String] = []
            view.onAnnotationCommand = { annotations.append(String(describing: $0)) }
            let modifiers = (item["normalized"] as! [String: Any])["modifiers"] as! [String: Bool]
            var flags: NSEvent.ModifierFlags = []
            if modifiers["command"]! { flags.insert(.command) }
            if modifiers["control"]! { flags.insert(.control) }
            if modifiers["option"]! { flags.insert(.option) }
            if modifiers["shift"]! { flags.insert(.shift) }
            switch item["extraModifier"] as? String {
            case "capsLock": flags.insert(.capsLock)
            case "function": flags.insert(.function)
            case "numericPad": flags.insert(.numericPad)
            case "help": flags.insert(.help)
            default: break
            }
            let chars = item["characters"] as! String
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: chars, charactersIgnoringModifiers: chars,
                isARepeat: item["isRepeat"] as! Bool, keyCode: UInt16(item["keyCode"] as! Int)))
            ActionCatalogOracleProbe.commands = []
            view.keyDown(with: event)
            XCTAssertLessThanOrEqual(ActionCatalogOracleProbe.commands.count + annotations.count + recorder.events, 1)
            output.append(["id": item["id"]!, "commands": ActionCatalogOracleProbe.commands,
                "annotations": annotations, "forwarded": recorder.events > 0,
                "keyboardFocusVisible": view.keyboardFocusIsVisible])
        }
        let direct: [TimelineKeyboardCommand] = [.previousEvent, .nextEvent, .previousTrack, .nextTrack,
            .panBackward, .panForward, .zoomIn, .zoomOut, .zoomInAtPointer, .zoomOutAtPointer,
            .selectFocusedEvent, .zoomSelection, .resetViewport, .clearSelection]
        var directOutput: [[String: Any]] = []
        for command in direct {
            let (view, _) = try makeView()
            ActionCatalogOracleProbe.commands = []
            let performed = view.performKeyboardCommand(command)
            directOutput.append(["name": String(describing: command),
                "observed": ActionCatalogOracleProbe.commands, "performed": performed])
        }
        let result: [String: Any] = ["schemaVersion": 1, "cases": output, "directCommands": directOutput]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: try XCTUnwrap(env["ARKTRACE_ACTION_CATALOG_KEYBOARD_OUTPUT"])))
    }
}
