import ArkTraceAnalysis
import ArkTraceAppSupport
import ArkTraceCore
import ArkTraceRendering
import Foundation
import UniformTypeIdentifiers

// Every reference below is public API the app target actually uses (or the
// transitive signature closure it forces). This file is never executed; it
// only has to compile from outside the package, exactly like the app does.
//
// If a demotion breaks this file, either the symbol must stay public or the
// app usage it mirrors was removed first — update both together.

@MainActor
private func pinAppSupportSurface(
    controller: TraceDocumentController,
    trackID: TimelineTrackID
) async {
    // Document lifecycle and state the app reads.
    controller.open(URL(filePath: "/dev/null"))
    controller.reload()
    controller.cancel()
    _ = controller.phase == TraceDocumentPhase.ready
    _ = controller.sourceURL
    _ = controller.metadata?.schemaFingerprint
    _ = controller.metadata?.durationNs
    _ = controller.metadata?.sourceByteCount
    _ = controller.trackGroups.map(\.title)
    _ = controller.trackGroups.map(\.kind)
    _ = controller.trackGroups.first?.capabilityAvailable
    _ = controller.trackGroups.first?.truncated
    _ = controller.trackGroups.first?.tracks
    _ = controller.snapshot?.viewport.widthPoints
    _ = controller.snapshot?.tracks.last.map { $0.y + $0.height }
    _ = controller.selectedEvent?.key
    _ = controller.hoveredEvent
    _ = controller.selectedRange
    _ = controller.rangeAnalysis
    _ = controller.searchResults.items
    _ = controller.searchResults.truncated
    _ = controller.isSearching
    controller.searchFieldText = "query"
    _ = controller.cacheInventory?.totalByteCount
    _ = controller.cacheInventory?.entryCount
    _ = controller.cacheInventory?.activeEntryCount
    _ = controller.recentDocuments.map(\.url)
    _ = controller.errorPresentation
    _ = controller.cacheHit
    _ = controller.accessibilityAnnouncement
    _ = controller.timelineFocusRequestID
    _ = controller.timelineBounds
    controller.toggleTrack(trackID)
    controller.selectEvent(nil)
    controller.hoverEvent(nil)
    controller.selectRange(nil)
    controller.search("text")
    controller.zoomToSelection()
    controller.resetViewport()
    controller.zoomIn()
    controller.zoomOut()
    controller.markFirstWindowAppeared()
    controller.markTimelineDisplayed()
    await controller.refreshCacheInventory()
    await controller.purgeUnusedCache()
    await controller.close()

    _ = TraceDocumentController(bundleURL: URL(filePath: "/dev/null"))
}

@MainActor
private func pinViewerPolicies(
    announcement: TraceAccessibilityAnnouncement,
    error: TraceAppErrorPresentation
) {
    _ = TraceViewerFocusPolicy.afterInspectorVisibilityChange(
        current: TraceViewerFocusRegion.inspector,
        inspectorVisible: false
    )
    switch TraceViewerLayoutPolicy.inspectorAction(
        detailWidth: 800,
        inspectorVisible: true,
        inspectorWasAutoCollapsed: false
    ) {
    case .none, .collapseAutomatically, .expandAutomatically:
        break
    }

    _ = announcement.revision
    _ = announcement.kind.localizationKey
    _ = announcement.kind.countArgument
    _ = announcement.kind.sourceText
    _ = announcement.message
    _ = announcement.priority == .urgent

    _ = error.titleKey.rawValue
    _ = error.titleKey.sourceText
    _ = error.reason
    _ = error.diagnostic
    switch error.recoveryAction {
    case .retry, .chooseAnotherFile, .openCacheSettings, .dismiss:
        break
    }
    _ = TraceAppErrorTitle.allCases

    _ = ArkTraceAppDistribution.supportedTraceContentTypes as [UTType]
    _ = ArkTraceAppDistribution.supportedTraceExtensions
    _ = ArkTraceAppDistribution.minimumSystemVersion
    _ = ArkTraceAppDistribution.bundleIdentifier
}

@MainActor
private func pinRenderingSurface(
    snapshot: TimelineSnapshot,
    inspector: TraceEventInspector
) {
    _ = TimelineView(
        snapshot: snapshot,
        selection: nil,
        selectedEventKey: inspector.key,
        focusRequestID: 0,
        interactionBounds: nil,
        accessibilityLabelText: "timeline",
        onSelectEvent: { _ in },
        onHoverEvent: { _ in },
        onSelectRange: { _ in },
        onViewportIntent: { (_: TimelineViewportIntent) in },
        onZoomSelection: {},
        onResetViewport: {}
    )
    _ = TimelineAccessibilityLayout.primaryToolbarTargetPoints
    for track in snapshot.tracks {
        _ = track.descriptor.title
        _ = track.descriptor.id
        _ = track.descriptor.isCollapsed
        _ = track.descriptor.source
        for primitive in track.primitives {
            if case .detail(let detail) = primitive {
                _ = detail.eventKey
                _ = detail.inspector
            }
            if case .density(let density) = primitive {
                _ = density.bucket
            }
        }
    }
}

private func pinCoreSurface(inspector: TraceEventInspector) throws {
    _ = inspector.type.rawValue
    _ = inspector.key.table.rawValue
    _ = inspector.key.rowID
    _ = inspector.range.startNs
    _ = inspector.semanticDurationNs
    _ = inspector.isOpenEnded
    _ = inspector.processKey?.ipid
    _ = inspector.threadKey?.itid
    _ = inspector.pid
    _ = inspector.tid
    _ = inspector.cpu
    _ = inspector.processName
    _ = inspector.threadName
    _ = inspector.category
    _ = inspector.state
    _ = inspector.value
    _ = inspector.unit

    let range = try TraceTimeRange.query(startNs: 0, endNs: 1)
    _ = range.durationNs

    for stage in [TraceLoadingStage.preparing, .hashing, .cacheLookup, .parsing,
                  .validating, .indexing, .openingDatabase, .ready, .failed,
                  .cancelled] {
        _ = stage
    }

    _ = try ArkTraceBoundedRegularFile.read(
        at: URL(filePath: "/dev/null"), maximumByteCount: 16
    )

    let error = ArkTraceError(
        code: .invalidArgument, stage: .request, message: "baseline"
    )
    _ = TraceAppErrorPresentation(error: error)
}

private func pinAnalysisSurface(analysis: TraceRangeAnalysis) {
    for value in analysis.cpuUtilization {
        _ = value.cpu
        _ = value.utilization
        _ = value.sliceCount
    }
    for value in analysis.topThreads {
        _ = value.threadKey
        _ = value.name
        _ = value.tid
        _ = value.occupiedNs
        _ = value.shareOfOneCPU
    }
    for value in analysis.longSlices {
        _ = value.key
        _ = value.name
        _ = value.range.durationNs
    }
    _ = analysis.truncated
}
