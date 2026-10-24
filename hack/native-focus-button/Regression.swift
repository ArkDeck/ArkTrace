import AppKit
import Foundation

/// These two admission flags are simulated. All responder/button operations
/// use real AppKit objects; this is not actual sheet, desktop or VoiceOver proof.
@MainActor
private final class FixtureWindow: NSWindow {
    var visibleForAdmission = true
    var keyForAdmission = true
    override var isVisible: Bool { visibleForAdmission }
    override var isKeyWindow: Bool { keyForAdmission }
    var physicallyVisible: Bool { super.isVisible }
    var physicallyKey: Bool { super.isKeyWindow }
}

@MainActor
private final class LiveContext {
    var value: InspectorFocusButton.FocusContext
    init(_ value: InspectorFocusButton.FocusContext) { self.value = value }
}

@main
private struct Regression {
    @MainActor
    static func main() async throws {
        let app = NSApplication.shared
        let initiallyActive = app.isActive
        let window = FixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                   styleMask: .borderless, backing: .buffered, defer: false)
        let second = FixtureWindow(contentRect: window.frame,
                                   styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        let root = NSView(frame: window.frame)
        let otherRoot = NSView(frame: second.frame)
        window.contentView = root
        second.contentView = otherRoot
        let group = NSView(frame: root.frame)
        root.addSubview(group)
        let trigger = InspectorFocusButton.NativeButton(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        let other = InspectorFocusButton.NativeButton(frame: NSRect(x: 50, y: 0, width: 32, height: 32))
        let otherSecond = InspectorFocusButton.NativeButton(frame: other.frame)
        group.addSubview(trigger)
        root.addSubview(other)
        otherRoot.addSubview(otherSecond)
        let document = NSObject(), replacement = NSObject()
        let context = InspectorFocusButton.FocusContext(documentID: ObjectIdentifier(document), sessionID: 1)
        let newDocument = InspectorFocusButton.FocusContext(documentID: ObjectIdentifier(replacement), sessionID: 1)
        let newSession = InspectorFocusButton.FocusContext(documentID: ObjectIdentifier(document), sessionID: 2)
        var consumed = [UInt64]()
        var actions = 0
        var passed = [String]()
        let coordinator = InspectorFocusButton.Coordinator(
            onFocusRequestConsumed: { consumed.append($0) }, action: { actions += 1 })
        coordinator.bind(trigger)
        defer {
            InspectorFocusButton.dismantleNSView(trigger, coordinator: coordinator)
            window.contentView = nil
            second.contentView = nil
            window.close()
            second.close()
        }
        func check(_ name: String, _ value: Bool) throws {
            guard value else { throw NSError(domain: "NativeFocusRegression", code: 1,
                userInfo: [NSLocalizedDescriptionKey: name]) }
            passed.append(name)
        }
        func update(_ id: UInt64?, _ focusContext: InspectorFocusButton.FocusContext? = nil) {
            InspectorFocusButton(title: "Back Up Saved State…", systemImage: "square.and.arrow.up",
                showsTitle: false, focusRequestID: id, focusContext: focusContext ?? context,
                onFocusRequestConsumed: { consumed.append($0) }, action: { actions += 1 })
                .configureFocus(on: trigger, coordinator: coordinator)
        }
        func drain() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        func resetResponder() throws {
            try check("native-other-responder-\(passed.count)", window.makeFirstResponder(other))
        }
        try check("physical-windows-hidden", !window.physicallyVisible && !second.physicallyVisible)
        try check("physical-windows-not-key", !window.physicallyKey && !second.physicallyKey)
        try resetResponder()
        update(1); update(2); update(3)
        try check("coalesced-one-job", coordinator.scheduledFocusCount == 1)
        await drain()
        try check("latest-request-only", window.firstResponder === trigger && consumed == [3])
        try check("job-drained", coordinator.scheduledFocusCount == 0)
        try resetResponder()
        update(3); await drain()
        try check("duplicate-no-focus", window.firstResponder === other && consumed == [3])
        update(4); update(nil); await drain()
        try check("nil-invalidates-queued-focus", window.firstResponder === other && !consumed.contains(4))
        update(5); update(5, newDocument); await drain()
        try check("document-replacement-invalidates", window.firstResponder === other && !consumed.contains(5))
        update(6); update(6, newSession); await drain()
        try check("session-replacement-invalidates", window.firstResponder === other && !consumed.contains(6))
        update(7); group.isHidden = true; await drain()
        try check("hidden-ancestor-rejects", window.firstResponder === other && !consumed.contains(7))
        group.isHidden = false
        update(8); trigger.isEnabled = false; await drain()
        try check("disabled-rejects", window.firstResponder === other && !consumed.contains(8))
        trigger.isEnabled = true
        update(9); trigger.removeFromSuperview(); await drain()
        try check("detachment-invalidates", window.firstResponder === other && !consumed.contains(9))
        group.addSubview(trigger)
        update(9); await drain()
        try check("reattachment-does-not-replay", window.firstResponder === other && !consumed.contains(9))
        try check("second-native-responder", second.makeFirstResponder(otherSecond))
        update(10); otherRoot.addSubview(trigger); await drain()
        try check("reparenting-invalidates", window.firstResponder === other && second.firstResponder === otherSecond && !consumed.contains(10))
        group.addSubview(trigger)
        window.visibleForAdmission = false
        update(11); await drain()
        try check("invisible-admission-rejects", window.firstResponder === other && !consumed.contains(11))
        window.visibleForAdmission = true
        window.keyForAdmission = false
        update(12); await drain()
        try check("inactive-admission-rejects", window.firstResponder === other && !consumed.contains(12))
        window.keyForAdmission = true
        update(13); await drain()
        try check("fresh-focus-after-rejections", window.firstResponder === trigger && consumed.last == 13)
        func key(_ text: String, repeatKey: Bool = false, modifiers: NSEvent.ModifierFlags = []) throws {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                characters: text, charactersIgnoringModifiers: text,
                isARepeat: repeatKey, keyCode: text == " " ? 49 : 36) else {
                throw NSError(domain: "NativeFocusRegression", code: 2)
            }
            trigger.keyDown(with: event)
        }
        try key("\r"); try key(" ")
        try check("focused-return-space-activate-once", actions == 2)
        try key(" ", repeatKey: true); try key("\r", modifiers: .command)
        try check("repeat-modified-key-do-not-activate", actions == 2)
        try resetResponder()
        try key("\r"); try key(" ")
        try check("unfocused-key-does-not-activate", actions == 2)
        update(14)
        InspectorFocusButton.dismantleNSView(trigger, coordinator: coordinator)
        await drain()
        try check("dismantle-invalidates-and-drains", window.firstResponder === other && !consumed.contains(14) && coordinator.scheduledFocusCount == 0)
        weak var released: InspectorFocusButton.NativeButton?
        autoreleasepool {
            let ephemeral = InspectorFocusButton.NativeButton(frame: trigger.frame)
            group.addSubview(ephemeral)
            coordinator.bind(ephemeral)
            InspectorFocusButton(title: "Temporary", systemImage: "square.and.arrow.up",
                showsTitle: false, focusRequestID: 15, focusContext: context,
                onFocusRequestConsumed: { consumed.append($0) }, action: {})
                .configureFocus(on: ephemeral, coordinator: coordinator)
            released = ephemeral
            ephemeral.removeFromSuperview()
            InspectorFocusButton.dismantleNSView(ephemeral, coordinator: coordinator)
        }
        await drain()
        try check("queued-work-does-not-retain-detached-button", released == nil && !consumed.contains(15) && coordinator.scheduledFocusCount == 0)
        coordinator.bind(trigger)
        let liveContext = LiveContext(context)
        InspectorFocusButton(title: "Live document", systemImage: "square.and.arrow.up",
            showsTitle: false, focusRequestID: 16, focusContext: context,
            isFocusContextCurrent: { $0 == liveContext.value },
            onFocusRequestConsumed: { consumed.append($0) }, action: {})
            .configureFocus(on: trigger, coordinator: coordinator)
        liveContext.value = newSession
        await drain()
        try check("live-context-change-before-view-update-rejects", window.firstResponder === other && !consumed.contains(16))
        try check("no-foreground-activation", app.isActive == initiallyActive)
        window.contentView = nil
        second.contentView = nil
        window.close()
        second.close()
        try check("physical-window-cleanup", window.contentView == nil && second.contentView == nil
                  && !window.physicallyVisible && !second.physicallyVisible)
        let result: [String: Any] = ["passed": passed, "caseCount": passed.count,
            "windowAdmissionFlagsSimulated": true, "actualNativeObjects": true,
            "actualDesktopSheetFocusVerified": false, "globalKeyboardEvents": 0,
            "activationCalls": 0, "orderFrontCalls": 0, "windowsClosed": 2,
            "initiallyActive": initiallyActive, "finallyActive": app.isActive,
            "scheduledFocusResidue": coordinator.scheduledFocusCount]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        guard data.count < 65536 else { throw NSError(domain: "NativeFocusRegression", code: 3) }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}
