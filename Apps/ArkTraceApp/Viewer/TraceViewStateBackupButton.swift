import AppKit
import ArkTraceAppSupport
import SwiftUI

/// Low-frequency backup observations stay in this toolbar child.
struct TraceViewStateBackupButton: View {
    var controller: TraceDocumentController
    @State private var review: Review?
    @FocusState private var backupFocused: Bool

    private struct Review: Identifiable { let id: UInt64 }

    var body: some View {
        if controller.canBackupViewState {
            Button("Back Up Saved State…", systemImage: "square.and.arrow.up", action: show)
                .arktraceAccessibleTarget()
                .focusable()
                .focused($backupFocused)
                .onKeyPress(keys: [.space, .return], phases: .down) { _ in show(); return .handled }
                .sheet(item: $review, onDismiss: { backupFocused = true }) { item in
                    TraceViewStateBackupReview(controller: controller, sessionID: item.id)
                }
                .onChange(of: controller.annotationSessionID) { _, _ in review = nil }
        }
    }
    private func show() { review = Review(id: controller.annotationSessionID) }
}

private struct TraceViewStateBackupReview: View {
    var controller: TraceDocumentController
    let sessionID: UInt64
    @Environment(\.dismiss) private var dismiss
    @FocusState private var createFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Saved State Backup").font(.title2).accessibilityAddTraits(.isHeader)
            Text("Create a separate copy of saved flags, persistent marks, and favorites. Backups stay available after the trace cache is cleared.")
                .fixedSize(horizontal: false, vertical: true)
            if sessionID == controller.annotationSessionID {
                if controller.isBackingUpViewState {
                    ProgressView("Backing Up Saved State…")
                } else if let error = controller.viewStateBackupError {
                    Text("Saved State Backup Could Not Be Created").font(.headline)
                    Text(error.reason).fixedSize(horizontal: false, vertical: true)
                } else if let report = controller.viewStateBackup {
                    statusText(report.status).fixedSize(horizontal: false, vertical: true)
                    if let receipt = report.receipt {
                        Text("Flags: \(receipt.flagCount) · Persistent marks: \(receipt.persistentMarkCount)")
                        if let count = receipt.favoriteTrackCount { Text("Saved favorites: \(count)") }
                        if let directory = report.directory {
                            Button("Show Backup in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
                                .arktraceAccessibleTarget().focusable()
                        }
                    }
                }
                HStack {
                    Spacer()
                    if controller.isBackingUpViewState {
                        Button("Cancel Backup") { controller.cancelViewStateBackup(sessionID: sessionID) }
                            .arktraceAccessibleTarget().focusable()
                    } else {
                        Button("Create Backup") { controller.backupViewState(sessionID: sessionID) }
                            .keyboardShortcut(.defaultAction).arktraceAccessibleTarget()
                            .focusable().focused($createFocused)
                    }
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction).arktraceAccessibleTarget().focusable()
                }
            } else {
                Text("This document has been closed or replaced.")
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 380, idealWidth: 480)
        .onAppear { createFocused = true }
    }
    private func statusText(_ status: TraceViewStateBackupPresentation.Status) -> Text {
        switch status {
        case .backedUp, .alreadyBackedUp: Text("Saved State Backup Is Ready")
        case .missing: Text("No saved state to back up. Add a flag, persistent mark, or favorite first.")
        case .preserved: Text("The saved state could not be read. Its original file was kept. No backup was created.")
        case .notConfigured, .sessionScoped: Text("Saved state backups are unavailable for this document.")
        }
    }
}
