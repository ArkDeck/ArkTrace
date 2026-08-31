import AppKit
import ArkTraceAppSupport
import ArkTraceCapture
import SwiftUI

@main
struct ArkTraceNativeApp: App {
    @State private var controller = TraceDocumentController()
    @State private var captureController = TraceCaptureController()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            TraceViewerRootView(controller: controller)
                .onOpenURL { controller.open($0) }
        }
        .defaultSize(width: 1_280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Capture Trace…") {
                    openWindow(id: ArkTraceWindow.capture)
                }
                .keyboardShortcut("n")
                Button("Open Trace…") { presentOpenPanel() }
                    .keyboardShortcut("o")
                Button("Reload") { controller.reload() }
                    .keyboardShortcut("r")
                    .disabled(controller.sourceURL == nil)
            }
            // Two searches, so two Find items rather than one ⌘F that has to
            // guess which one was meant. The sidebar's filter takes plain ⌘F:
            // it is the one that starts a session ("go to that process"),
            // while searching for an event is the deeper step.
            CommandGroup(after: .textEditing) {
                Button("Filter Processes") { controller.focusProcessFilter() }
                    .keyboardShortcut("f")
                    .disabled(controller.trackGroups.isEmpty)
                Button("Search Trace") { controller.focusTraceSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(controller.metadata == nil)
            }
            // Upstream lists its bindings behind `/`; on macOS this belongs on
            // the Help menu, and `/` stays free for a future search entry
            // point on the timeline. The default Help item is replaced rather
            // than joined: ArkTrace ships no help book for it to open.
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    openWindow(id: ArkTraceWindow.keyboardShortcuts)
                }
            }
        }

        Window("Keyboard Shortcuts", id: ArkTraceWindow.keyboardShortcuts) {
            ShortcutHelpView()
        }
        .defaultSize(width: 520, height: 620)

        Window("Capture Trace", id: ArkTraceWindow.capture) {
            TraceCaptureWindow(
                capture: captureController,
                documentController: controller
            )
        }
        .defaultSize(width: 580, height: 640)

        Settings {
            SettingsRootView(controller: controller)
        }
    }

    @MainActor
    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Trace"
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // SPEC 2.3: the extension is only a picker/Finder hint; the parser and
        // schema validation decide whether a file is actually supported.
        panel.allowedContentTypes = ArkTraceAppDistribution.supportedTraceContentTypes
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let url = panel.url { controller.open(url) }
    }
}
