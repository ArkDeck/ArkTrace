import Foundation
import XCTest

/// Source-level guard for the two Find commands and the fields they focus.
///
/// The app has two searches — the sidebar's process filter and the toolbar's
/// event search — so it has two Find items rather than one ⌘F that has to
/// guess. Both are wired through the controller, because SwiftUI's
/// `@FocusState` does not survive a menu command here: the state flips and the
/// key window hands first responder straight back, so the field opens without
/// the keyboard. `FocusableTextField` makes the request in AppKit instead, and
/// that is also where the focus ring is turned off. There is no UI harness for
/// any of this, so it is parsed out of the feature files in `Apps/ArkTraceApp`,
/// the way `ObservationBoundaryTests` does.
final class AppCommandTests: XCTestCase {
    private func source() throws -> String {
        try AppSource.read().text
    }

    func testFindCommandsAreBoundAndReachTheController() throws {
        let source = try source()
        XCTAssertTrue(
            source.contains(#"Button("Filter Processes") { controller.focusProcessFilter() }"#),
            "the sidebar's filter needs a Find item"
        )
        XCTAssertTrue(
            source.contains(#".keyboardShortcut("f")"#),
            "⌘F, unmodified, must open the sidebar's process filter"
        )
        XCTAssertTrue(
            source.contains(#"Button("Search Trace") { controller.focusTraceSearch() }"#),
            "the toolbar search needs a binding of its own, or ⌘F is ambiguous"
        )
        XCTAssertTrue(
            source.contains(#".keyboardShortcut("f", modifiers: [.command, .shift])"#),
            "⇧⌘F must reach the toolbar search"
        )
    }

    /// Both fields are AppKit-backed: it is the only way the menu's focus
    /// request lands, and the only place the ring can be switched off.
    func testBothSearchFieldsAreFocusableFromTheMenu() throws {
        let source = try source()
        for requestID in ["controller.processFilterFocusRequestID", "controller.searchFocusRequestID"] {
            XCTAssertTrue(
                source.contains("focusRequestID: \(requestID)"),
                "a field with no focus request cannot answer its menu item (\(requestID))"
            )
        }
        XCTAssertTrue(
            source.contains("window.makeFirstResponder(field)"),
            "the focus request has to reach AppKit; SwiftUI focus does not survive the menu"
        )
    }

    func testFocusedFieldsDrawNoRing() throws {
        let source = try source()
        XCTAssertTrue(
            source.contains("field.focusRingType = .none"),
            "a focused field is shown by its caret, not by a blue ring"
        )
    }

    func testCaptureIsReachableFromMenuToolbarAndEmptyState() throws {
        let source = try source()
        XCTAssertTrue(
            source.contains(#"Window("Capture Trace", id: ArkTraceWindow.capture)"#),
            "capture needs a dedicated window so the current trace remains inspectable"
        )
        XCTAssertTrue(
            source.contains(#"Button("Capture Trace…") {"#)
                && source.contains(#".keyboardShortcut("n")"#),
            "File → Capture Trace… must have the native ⌘N command"
        )
        XCTAssertTrue(
            source.contains(#"Label("Capture", systemImage: "record.circle")"#),
            "the main toolbar must expose capture"
        )
        XCTAssertTrue(
            source.contains(#"Button("Capture Trace…", action: openCapture)"#),
            "the no-document state must offer capture without requiring the menu"
        )
    }

    func testCaptureDurationUsesNativeEntryUnitAndQuickControls() throws {
        let source = try source()
        XCTAssertTrue(
            source.contains(#"TextField("#)
                && source.contains(#"value: $capture.durationInputValue"#),
            "capture duration must be directly editable"
        )
        XCTAssertTrue(
            source.contains(#"Picker("#)
                && source.contains("\"Duration unit\"")
                && source.contains(#".pickerStyle(.segmented)"#),
            "seconds and minutes must use a native segmented picker"
        )
        XCTAssertTrue(
            source.contains(#"ForEach(capture.durationUnit.quickValues"#)
                && source.contains(#".toggleStyle(.button)"#),
            "the selected unit must expose native quick-duration toggles"
        )
    }

    func testCaptureShowsTheResolvedHDCVersionBesideItsName() throws {
        let source = try source()
        XCTAssertTrue(
            source.contains(#"Text(verbatim: hdcDisplayName(url))"#)
                && source.contains(#"return "\(url.lastPathComponent) v\(version)""#),
            "the selected HDC name must include its asynchronously resolved version"
        )
    }

    func testCaptureDevicePickerShowsTwoLineMetadataAndFullAccessibleID() throws {
        let source = try source()
        XCTAssertTrue(
            source.contains(#"Text(verbatim: deviceDisplayName(device))"#)
                && source.contains(#"Text(verbatim: deviceDetail(device))"#)
                && source.contains(#"if let device = selectedDevice"#)
                && source.contains(#"VStack(alignment: .leading, spacing: 1)"#),
            "each device option must show its name above version, shortened ID and transport"
        )
        XCTAssertTrue(
            source.contains(#".accessibilityLabel(deviceAccessibilityLabel(device))"#)
                && source.contains(#"components.append("Device \(device.id)")"#),
            "the picker must preserve the complete device ID for assistive technologies"
        )
    }

    func testCaptureSavePanelLetsTheContentTypeAppendHTraceOnce() throws {
        let source = try source()
        XCTAssertTrue(
            source.contains(#"panel.nameFieldStringValue = defaultCaptureBaseName()"#)
                && source.contains(#"return "ArkTrace_\(formatter.string(from: Date()))""#),
            "the suggested base name must not duplicate NSSavePanel's .htrace extension"
        )
    }
}
