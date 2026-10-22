import AppKit
import SwiftUI

struct InspectorFocusButton: NSViewRepresentable {
    struct FocusContext: Equatable {
        let documentID: ObjectIdentifier
        let sessionID: UInt64
    }

    let title: String
    let systemImage: String
    let showsTitle: Bool
    let focusRequestID: UInt64?
    var focusContext: FocusContext? = nil
    var isFocusContextCurrent: @MainActor (FocusContext?) -> Bool = { _ in true }
    let onFocusRequestConsumed: @MainActor (UInt64) -> Void
    let action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onFocusRequestConsumed: onFocusRequestConsumed,
            action: action
        )
    }

    func makeNSView(context: Context) -> NativeButton {
        let button = NativeButton()
        button.bezelStyle = .rounded
        button.image = NSImage(
            systemSymbolName: systemImage,
            accessibilityDescription: title
        )
        button.imagePosition = showsTitle ? .imageLeading : .imageOnly
        button.title = showsTitle ? title : ""
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.isEnabled = context.environment.isEnabled
        context.coordinator.bind(button)
        configureFocus(on: button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: NativeButton, context: Context) {
        context.coordinator.onFocusRequestConsumed = onFocusRequestConsumed
        context.coordinator.action = action
        button.isEnabled = context.environment.isEnabled
        configureFocus(on: button, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ button: NativeButton, coordinator: Coordinator) {
        coordinator.invalidateFocus()
        button.onWindowChanged = nil
        button.target = nil
        button.action = nil
    }

    func configureFocus(on button: NativeButton, coordinator: Coordinator) {
        coordinator.isFocusContextCurrent = isFocusContextCurrent
        if coordinator.focusContext != focusContext {
            coordinator.invalidateFocus()
            coordinator.focusContext = focusContext
        }
        guard let focusRequestID else {
            coordinator.invalidateFocus()
            return
        }
        guard coordinator.lastFocusRequestID != focusRequestID
        else {
            return
        }
        coordinator.lastFocusRequestID = focusRequestID
        guard let window = unsafe button.window else { return }
        coordinator.scheduleFocus(on: button, in: window, requestID: focusRequestID)
    }

    /// AppKit owns focus for both Inspector and toolbar buttons. Handle the
    /// activation keys on that same responder, including Return after a sheet.
    @MainActor
    final class NativeButton: NSButton {
        var onWindowChanged: (@MainActor () -> Void)?

        override var acceptsFirstResponder: Bool { isEnabled }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?()
        }

        override func keyDown(with event: NSEvent) {
            guard [" ", "\r", "\u{3}"].contains(event.charactersIgnoringModifiers ?? "") else {
                super.keyDown(with: event)
                return
            }
            guard isEnabled, !isHiddenOrHasHiddenAncestor, !event.isARepeat,
                  unsafe window?.firstResponder === self,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            else { return }
            performClick(nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onFocusRequestConsumed: @MainActor (UInt64) -> Void
        var action: @MainActor () -> Void
        var lastFocusRequestID: UInt64?
        var focusContext: FocusContext?
        var isFocusContextCurrent: @MainActor (FocusContext?) -> Bool = { _ in true }
        private(set) var focusGeneration: UInt64 = 0
        private var pendingFocus: PendingFocus?
        private var focusScheduled = false

        var scheduledFocusCount: Int { focusScheduled ? 1 : 0 }

        func bind(_ button: NativeButton) {
            button.target = self
            button.action = #selector(activate)
            button.onWindowChanged = { [weak self] in self?.invalidateFocus() }
        }

        func invalidateFocus() {
            focusGeneration &+= 1
            pendingFocus = nil
        }

        private final class PendingFocus {
            weak var button: NativeButton?
            weak var window: NSWindow?
            let requestID: UInt64
            let generation: UInt64
            let context: FocusContext?

            init(button: NativeButton, window: NSWindow, requestID: UInt64,
                 generation: UInt64, context: FocusContext?) {
                self.button = button
                self.window = window
                self.requestID = requestID
                self.generation = generation
                self.context = context
            }
        }

        func scheduleFocus(on button: NativeButton, in window: NSWindow, requestID: UInt64) {
            pendingFocus = PendingFocus(button: button, window: window, requestID: requestID,
                                        generation: focusGeneration, context: focusContext)
            // Coalesce updates into one weak, non-suspending main-queue job.
            // Invalidation drops the intent; detachment cannot keep a view alive.
            guard !focusScheduled else { return }
            focusScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.focusScheduled = false
                let intent = self.pendingFocus
                self.pendingFocus = nil
                guard let intent, let button = intent.button, let window = intent.window,
                      unsafe button.window === window,
                      window.isVisible, window.isKeyWindow, window.attachedSheet == nil,
                      button.isEnabled, !button.isHiddenOrHasHiddenAncestor,
                      self.focusGeneration == intent.generation,
                      self.focusContext == intent.context,
                      self.isFocusContextCurrent(intent.context),
                      self.lastFocusRequestID == intent.requestID
                else { return }
                guard window.makeFirstResponder(button) else { return }
                self.onFocusRequestConsumed(intent.requestID)
            }
        }

        init(
            onFocusRequestConsumed: @escaping @MainActor (UInt64) -> Void,
            action: @escaping @MainActor () -> Void
        ) {
            self.onFocusRequestConsumed = onFocusRequestConsumed
            self.action = action
        }

        @objc func activate() {
            action()
        }
    }
}
