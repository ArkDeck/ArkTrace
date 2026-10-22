import AppKit
import ArkTraceAppSupport
import ArkTraceRendering
import SwiftUI

/// One Recent row.
///
/// A trace whose file has since been deleted keeps its row, greyed and inert,
/// rather than quietly dropping out of the list: the row is how the user finds
/// out the trace is gone, and the context menu is how they act on it — open
/// it, drop it from the list, or go and look at where it used to live.
struct RecentDocumentRow: View {
    var controller: TraceDocumentController
    let document: TraceRecentDocument

    var body: some View {
        Group {
            if document.isMissing {
                // Deliberately not a Button: there is nothing left to press.
                label.foregroundStyle(.tertiary)
            } else {
                Button {
                    controller.open(document.url)
                } label: {
                    label
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel(
            document.isMissing
                ? Text("\(document.url.lastPathComponent), missing")
                : Text(document.url.lastPathComponent)
        )
        .help(
            document.isMissing
                ? "Missing — \(document.url.path)"
                : document.url.path
        )
        .arktraceAccessibleTarget()
        .contextMenu {
            Button("Open") { controller.open(document.url) }
                .disabled(document.isMissing)
            Button("Remove from Recent") { controller.removeRecentDocument(document) }
            Button("Show in Finder") { showInFinder() }
                .disabled(finderTarget == nil)
        }
    }

    private var label: some View {
        Label(
            document.url.lastPathComponent,
            systemImage: document.isMissing ? "clock.badge.xmark" : "clock"
        )
        .lineLimit(1)
    }

    /// Finder can only select a file that is there; when it is not, the honest
    /// next best answer is the folder it was in, and that folder can be gone
    /// too — a deleted trace is often a deleted capture directory.
    private var finderTarget: URL? {
        let manager = FileManager.default
        if manager.fileExists(atPath: document.url.path) { return document.url }
        let parent = document.url.deletingLastPathComponent()
        return manager.fileExists(atPath: parent.path) ? parent : nil
    }

    private func showInFinder() {
        guard let target = finderTarget else { return }
        if target == document.url {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } else {
            NSWorkspace.shared.open(target)
        }
    }
}
