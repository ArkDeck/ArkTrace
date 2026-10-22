import AppKit
import ArkTraceAppSupport
import SwiftUI

/// Low-frequency backup observations stay in this toolbar child.
struct TraceViewStateBackupButton: View {
    var controller: TraceDocumentController
    @State private var review: Review?
    @State private var reviewedContext: InspectorFocusButton.FocusContext?
    @State private var focusRequestID: UInt64?
    @State private var focusRequestGeneration: UInt64 = 0

    private struct Review: Identifiable {
        let id: UInt64
        let controller: TraceDocumentController
    }

    private var focusContext: InspectorFocusButton.FocusContext {
        .init(documentID: ObjectIdentifier(controller), sessionID: controller.annotationSessionID)
    }

    var body: some View {
        if controller.canBackupViewState {
            InspectorFocusButton(
                title: String(localized: "Back Up Saved State…"),
                systemImage: "square.and.arrow.up",
                showsTitle: false,
                focusRequestID: focusRequestID,
                focusContext: focusContext,
                isFocusContextCurrent: { context in
                    context?.documentID == ObjectIdentifier(controller)
                        && context?.sessionID == controller.annotationSessionID
                        && controller.canBackupViewState
                },
                onFocusRequestConsumed: { requestID in
                    if focusRequestID == requestID { focusRequestID = nil }
                },
                action: show
            )
                .arktraceAccessibleTarget()
                .focusable()
                .onKeyPress(keys: [.space, .return], phases: .down) { _ in show(); return .handled }
                .sheet(item: $review, onDismiss: restoreFocus) { item in
                    TraceViewStateBackupReview(controller: item.controller, sessionID: item.id)
                }
                .onChange(of: focusContext) { _, _ in
                    reviewedContext = nil
                    focusRequestID = nil
                    review = nil
                }
        }
    }
    private func show() {
        guard review == nil, controller.canBackupViewState else { return }
        reviewedContext = focusContext
        review = Review(id: controller.annotationSessionID, controller: controller)
    }
    private func restoreFocus() {
        defer { reviewedContext = nil }
        guard reviewedContext == focusContext,
              controller.canBackupViewState else { return }
        focusRequestGeneration &+= 1
        focusRequestID = focusRequestGeneration
    }
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
