import ArkTraceAppSupport
import SwiftUI

/// Migration observations stay outside the viewer layout and hot timeline.
struct TraceViewStateMigrationOverlay: View {
    var controller: TraceDocumentController
    @State private var review: Review?
    @FocusState private var reviewFocused: Bool

    private struct Review: Identifiable {
        let id: UInt64
    }

    var body: some View {
        if let report = controller.viewStateMigration, report.shouldPresent {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    TraceMigrationStatusText(status: report.status).font(.headline)
                    if !report.unmatchedFavoriteTrackIDs.isEmpty {
                        Text("Some saved favorites could not be matched to this parser. Their identities were kept.")
                            .font(.callout)
                    }
                    if report.preservedSourceCount > 0 {
                        Text("Some older saved states could not be imported. Their original files were kept.")
                            .font(.callout)
                    }
                }
                Spacer(minLength: 12)
                Button("Review Saved State…") { review = Review(id: controller.annotationSessionID) }
                    .arktraceAccessibleTarget()
                    .focusable()
                    .focused($reviewFocused)
                    .onKeyPress(keys: [.space, .return], phases: .down) { _ in
                        review = Review(id: controller.annotationSessionID)
                        return .handled
                    }
                Button("Dismiss") { controller.dismissViewStateMigration(sessionID: controller.annotationSessionID) }
                    .arktraceAccessibleTarget()
                    .disabled(controller.isImportingLegacyViewState)
            }
            .padding(12)
            .background(.thickMaterial)
            .sheet(item: $review, onDismiss: { reviewFocused = true }) { item in
                TraceViewStateMigrationReview(controller: controller, sessionID: item.id)
            }
            .onChange(of: controller.annotationSessionID) { _, _ in review = nil }
        }
    }
}

private struct TraceMigrationStatusText: View {
    let status: TraceViewStateMigrationPresentation.Status
    var body: some View {
        switch status {
        case .conflict, .invalidSelection: Text("Choose an Older Saved State")
        case .preservedSource: Text("Older Saved State Needs Attention")
        case .preservedDestination: Text("Current Saved State Was Kept")
        case .destinationKept: Text("Current Saved State Was Kept")
        case .imported, .alreadyCompleted: Text("Older Saved State Imported")
        case .notConfigured, .missing, .sessionScoped: Text("Saved State")
        }
    }
}

private struct TraceViewStateMigrationReview: View {
    var controller: TraceDocumentController
    let sessionID: UInt64
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if sessionID == controller.annotationSessionID, let report = controller.viewStateMigration {
                TraceMigrationStatusText(status: report.status).font(.title2)
                    .accessibilityAddTraits(.isHeader)
                if report.needsSelection {
                    Text("Several older states contain different annotations. Choose one to import. The trace stays open, and all original files and backups are kept.")
                    List(selection: $selection) {
                        ForEach(report.candidates) { candidate in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Parser: \(candidate.parserReportedVersion)").font(.headline)
                                Text("Flags: \(candidate.flagCount) · Persistent marks: \(candidate.persistentMarkCount)")
                                if let count = candidate.favoriteTrackCount { Text("Saved favorites: \(count)") }
                                if !candidate.exactParserIdentity {
                                    Text("Favorites from this parser will be kept as unmatched identities.").font(.callout)
                                }
                                ForEach(candidate.labelPreviews.indices, id: \.self) { index in
                                    Text(verbatim: candidate.labelPreviews[index]).font(.callout)
                                }
                                Text(verbatim: candidate.id).font(.caption.monospaced()).textSelection(.enabled)
                            }
                            .padding(.vertical, 6)
                            .tag(candidate.id)
                        }
                    }
                    .accessibilityLabel("Older Saved States")
                    .disabled(controller.isImportingLegacyViewState)
                    .frame(minHeight: 180, maxHeight: 300)
                }
                if report.preservedSourceCount > 0 {
                    Text("Some older saved states could not be imported. Their original files were kept.")
                }
                if !report.unmatchedFavoriteTrackIDs.isEmpty {
                    DisclosureGroup("Unmatched Saved Favorites") {
                        Text("These identities are retained without assigning them to a different track.")
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(report.unmatchedFavoriteTrackIDs.indices, id: \.self) { index in
                                    Text(verbatim: report.unmatchedFavoriteTrackIDs[index])
                                        .font(.caption.monospaced()).textSelection(.enabled)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 140)
                    }
                }
                if controller.isImportingLegacyViewState { ProgressView("Importing Saved State…") }
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        if report.needsSelection { Text("Choose Later") } else { Text("Done") }
                    }
                        .keyboardShortcut(.cancelAction)
                        .disabled(controller.isImportingLegacyViewState)
                        .arktraceAccessibleTarget()
                    if report.needsSelection {
                        Button("Import Selected State") {
                            if let selection { controller.importLegacyViewState(snapshotIdentifier: selection, sessionID: sessionID) }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selection == nil || controller.isImportingLegacyViewState)
                        .arktraceAccessibleTarget()
                    }
                }
            } else {
                Text("This document has been closed or replaced.")
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 560)
        .interactiveDismissDisabled(controller.isImportingLegacyViewState)
    }
}
