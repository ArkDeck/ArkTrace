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
    // Keyboard stepping through the results list.
    _ = controller.searchSelectionIndex
    controller.selectSearchResult(at: 0)
    _ = controller.stepSearchResult(by: 1)
    _ = controller.activateSearchResult()
    controller.searchFieldText = "query"
    _ = controller.cacheInventory?.totalByteCount
    _ = controller.cacheInventory?.entryCount
    _ = controller.cacheInventory?.activeEntryCount
    _ = controller.recentDocuments.map(\.url)
    _ = controller.recentDocuments.map(\.isMissing)
    controller.refreshRecentDocuments()
    controller.recentDocuments.first.map(controller.removeRecentDocument)
    _ = controller.errorPresentation
    _ = controller.cacheHit
    _ = controller.accessibilityAnnouncement
    _ = controller.timelineFocusRequestID
    _ = controller.timelineBounds
    controller.toggleTrack(trackID)
    // Pressing a process in the sidebar jumps to its lanes: the App calls this
    // and reads the offset it publishes.
    controller.revealTrackGroup("process:1")
    _ = controller.timelineScrollRequest.map { ($0.id, $0.y) }
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
    // The App chooses the dock and asks the policy about the axis that dock
    // spends, so both halves are promised outside the package.
    for dock in TraceInspectorDock.allCases {
        _ = dock.rawValue
        _ = TraceViewerLayoutPolicy.minimumDetailExtent(for: dock)
        switch TraceViewerLayoutPolicy.inspectorAction(
            detailWidth: 800,
            detailHeight: 600,
            dock: dock,
            inspectorVisible: true,
            inspectorWasAutoCollapsed: false
        ) {
        case .none, .collapseAutomatically, .expandAutomatically:
            break
        }
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
        annotations: TimelineAnnotations(),
        selection: nil,
        selectedEventKey: inspector.key,
        selectedEventLocation: TimelineEventLocation(
            trackID: TimelineTrackID(rawValue: "cpu:0"), range: inspector.range
        ),
        focusRequestID: 0,
        interactionBounds: nil,
        accessibilityLabelText: "timeline",
        onSelectEvent: { _ in },
        // A press on a density band is resolved by the App, so both halves of
        // that exchange -- the hit it receives and the location it hands back
        // -- are promised outside the package.
        onSelectDensityBand: { (hit: TimelineDensityHit) in
            _ = (hit.trackID, hit.bucket, hit.timeNs)
        },
        // The App draws the timeline's focus indicator itself, so it needs to
        // hear when the canvas starts and stops advertising keyboard focus.
        onKeyboardFocusVisibleChange: { (_: Bool) in },
        onHoverEvent: { _ in },
        onSelectRange: { _ in },
        onCreateFlag: { (_: Int64) in },
        // Naming a flag happens in the App, so the press it answers is part of
        // the promised surface.
        onSelectFlag: { (hit: TimelineFlagHit) in _ = (hit.id, hit.marker) },
        onAnnotationCommand: { (_: TimelineAnnotationCommand) in },
        onViewportIntent: { (_: TimelineViewportIntent) in },
        onZoomSelection: {},
        onResetViewport: {}
    )
    _ = TimelineAccessibilityLayout.primaryToolbarTargetPoints
    // Selection-endpoint dragging and wheel zoom are entirely inside
    // `TimelineNSView`, so nothing new is promised outside the package: the
    // minimum target size is the one value the App's own controls share.
    _ = TimelineAccessibilityLayout.minimumTargetPoints
    // The App renders and edits annotations, so their surface must stay
    // reachable from outside the package.
    var annotations = TimelineAnnotations()
    annotations.flags.append(
        TimelineFlag(id: 1, timestampNs: 0, label: "f", colorIndex: 0)
    )
    _ = annotations.orderedFlags.map(\.label)
    _ = annotations.orderedMarks.map(\.isPersistent)
    _ = annotations.flag(after: 0)
    _ = annotations.flag(before: 0)
    _ = annotations.mark(after: 0)
    _ = annotations.mark(before: 0)
    _ = annotations.isEmpty
    _ = TimelineAnnotationColor.count
    _ = TimelineAnnotationColor.cgColor(at: 0)
    for track in snapshot.tracks {
        _ = track.descriptor.title
        _ = track.descriptor.id
        _ = track.descriptor.isCollapsed
        _ = track.descriptor.showsNestedDepth
        _ = track.descriptor.source
        _ = track.depthRowCount
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
    // CPU slices carry scheduler priority; the Inspector renders it.
    _ = inspector.priority

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
        // The per-CPU split the Range Inspector shows beside the total.
        for share in value.cpuBreakdown {
            _ = share.cpu
            _ = share.occupiedNs
            _ = share.sliceCount
        }
    }
    for value in analysis.longSlices {
        _ = value.key
        _ = value.name
        _ = value.range.durationNs
    }
    // The Range Inspector renders the thread state distribution, so every
    // field it reads has to stay reachable from outside the package.
    for value in analysis.threadStateDistribution {
        _ = value.threadKey
        _ = value.processKey
        _ = value.tid
        _ = value.pid
        _ = value.rawState
        _ = value.normalizedState?.rawValue
        _ = value.durationNs
        _ = value.percentageOfRange
        _ = value.intervalCount
    }
    _ = analysis.threadStateDistributionTruncated
    // Slice-name aggregates and the bounded-total flag the table must show.
    for value in analysis.sliceNameAggregates {
        _ = value.name
        _ = value.totalDurationNs
        _ = value.averageDurationNs
        _ = value.occurrences
        _ = value.firstEventKey
        _ = value.firstRange.startNs
        _ = value.firstThreadKey?.itid
    }
    _ = analysis.sliceNameAggregatesTruncated
    _ = analysis.truncated
}
