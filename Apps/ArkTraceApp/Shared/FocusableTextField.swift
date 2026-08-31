import AppKit
import SwiftUI

/// A text field that can be told to take the keyboard, and that never draws a
/// focus ring.
///
/// Both halves are why it is AppKit rather than a SwiftUI `TextField`.
/// `@FocusState` does not survive a menu command here — ⌘F runs the action and
/// the state flips, but the key window hands first responder straight back to
/// the canvas, so the field opens empty-handed (verified on a real capture,
/// with the field already open and with it closed). `makeFirstResponder` on the
/// next runloop pass is the same request AppKit actually honours, and it is the
/// shape ``TimelineView`` and ``InspectorFocusButton`` already use for "focus
/// this on request". `focusRingType` then answers the other half: the blue ring
/// around a focused field says what the caret says, louder.
struct FocusableTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    /// Bumped by whoever wants the keyboard here. Each new value focuses once.
    let focusRequestID: UInt64
    let onSubmit: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.setAccessibilityLabel(accessibilityLabel)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        context.coordinator.focusIfAsked(field, id: focusRequestID)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusableTextField
        private var lastFocusRequestID: UInt64?

        init(_ parent: FocusableTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }

        func focusIfAsked(_ field: NSTextField, id: UInt64) {
            guard lastFocusRequestID != id else { return }
            lastFocusRequestID = id
            // 0 is "nobody has asked yet". Without this the toolbar's field
            // would take the keyboard the moment the window is built, and a
            // trace would open with the caret in the search box instead of on
            // the timeline (AT-APP-009).
            guard id != 0 else { return }
            DispatchQueue.main.async { [weak field] in
                // Read AppKit's unowned window on the main actor and retain
                // it locally for the synchronous focus request.
                guard let field, let window = unsafe field.window else { return }
                window.makeFirstResponder(field)
            }
        }
    }
}
