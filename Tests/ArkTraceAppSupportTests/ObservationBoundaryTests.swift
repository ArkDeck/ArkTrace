import Foundation
import XCTest

/// Source-level guard for the app's Observation boundaries.
///
/// SwiftUI + Observation invalidates exactly the views whose `body` read a
/// changed property, so the boundary IS the set of `controller.` reads inside
/// each child view. These tests parse the feature files in `Apps/ArkTraceApp` and
/// fail when a high-frequency property read creeps back into a view that must
/// stay out of its invalidation set — the regression that previously made
/// every snapshot/hover/search update re-evaluate the whole window.
final class ObservationBoundaryTests: XCTestCase {
    private func block(_ name: String) throws -> String {
        try AppSource.read().declaration(named: name)
    }

    private func assertNoRead(
        of properties: [String],
        in viewName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let text = try block(viewName)
        for property in properties {
            XCTAssertFalse(
                text.contains("controller.\(property)"),
                "\(viewName) must not read controller.\(property); that read widens its invalidation set",
                file: file,
                line: line
            )
        }
    }

    func testSplitChildViewsExist() throws {
        for name in [
            "TraceViewerRootView", "TraceViewerSidebar", "TraceTimelinePane",
            "TraceInspectorPane", "TraceErrorBannerOverlay", "TraceAnnouncementBridge",
            "TraceSearchField", "SettingsRootView", "TraceCacheSettingsView",
        ] {
            _ = try block(name)
        }
    }

    /// The root skeleton must not read any high-frequency controller state:
    /// every read it makes re-evaluates the whole window.
    func testRootSkeletonReadsNoHighFrequencyState() throws {
        try assertNoRead(
            of: [
                "snapshot", "phase", "selectedEvent", "selectedRange", "hoveredEvent",
                "searchResults", "searchFieldText", "isSearching", "rangeAnalysis",
                "errorPresentation", "accessibilityAnnouncement", "cacheInventory",
                "metadata", "recentDocuments", "trackGroups", "timelineFocusRequestID",
            ],
            in: "TraceViewerRootView"
        )
    }

    /// Viewport/snapshot updates must not rebuild the sidebar.
    func testSidebarIgnoresViewportAndSelectionState() throws {
        try assertNoRead(
            of: [
                "snapshot", "phase", "selectedEvent", "selectedRange", "hoveredEvent",
                "rangeAnalysis", "cacheInventory", "errorPresentation", "metadata",
                "timelineFocusRequestID",
            ],
            in: "TraceViewerSidebar"
        )
    }

    /// Search updates must not rebuild the timeline pane.
    func testTimelinePaneIgnoresSearchAndInventoryState() throws {
        try assertNoRead(
            of: [
                "searchResults", "searchFieldText", "isSearching",
                "cacheInventory", "recentDocuments", "cacheMaintenanceReport",
            ],
            in: "TraceTimelinePane"
        )
    }

    /// Cache inventory updates must stay inside Settings.
    func testCacheInventoryIsReadOnlyInSettings() throws {
        for viewer in [
            "TraceViewerRootView", "TraceViewerSidebar", "TraceTimelinePane",
            "TraceInspectorPane", "TraceErrorBannerOverlay",
        ] {
            try assertNoRead(of: ["cacheInventory"], in: viewer)
        }
        let settings = try block("TraceCacheSettingsView")
        XCTAssertTrue(
            settings.contains("controller.cacheInventory"),
            "the Settings cache tab is the one place inventory is displayed"
        )
    }

    /// Error and accessibility state have dedicated single-purpose boundaries.
    func testErrorAndAccessibilityHaveDedicatedBoundaries() throws {
        let banner = try block("TraceErrorBannerOverlay")
        XCTAssertTrue(banner.contains("controller.errorPresentation"))
        try assertNoRead(
            of: ["snapshot", "searchResults", "trackGroups", "cacheInventory"],
            in: "TraceErrorBannerOverlay"
        )

        let bridge = try block("TraceAnnouncementBridge")
        XCTAssertTrue(bridge.contains("controller.accessibilityAnnouncement"))
        try assertNoRead(
            of: ["snapshot", "searchResults", "errorPresentation"],
            in: "TraceAnnouncementBridge"
        )
    }

    /// Inspector reads selection facts only — never the search machinery.
    func testInspectorPaneIgnoresSearchState() throws {
        try assertNoRead(
            of: ["searchResults", "searchFieldText", "isSearching", "recentDocuments"],
            in: "TraceInspectorPane"
        )
    }
}
