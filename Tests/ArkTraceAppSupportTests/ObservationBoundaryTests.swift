import Foundation
import XCTest

/// Source-level guard for the app's Observation boundaries.
///
/// SwiftUI + Observation invalidates exactly the views whose `body` read a
/// changed property, so the boundary IS the set of `controller.` reads inside
/// each child view. These tests parse `Apps/ArkTraceApp/ArkTraceApp.swift` and
/// fail when a high-frequency property read creeps back into a view that must
/// stay out of its invalidation set — the regression that previously made
/// every snapshot/hover/search update re-evaluate the whole window.
final class ObservationBoundaryTests: XCTestCase {
    private static let appSource: String = {
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()  // ObservationBoundaryTests.swift
            .deletingLastPathComponent()  // ArkTraceAppSupportTests
            .deletingLastPathComponent()  // Tests
        let url = repositoryRoot.appending(
            path: "Apps/ArkTraceApp/ArkTraceApp.swift"
        )
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// Text of one top-level type declaration, from its `struct <name>` line
    /// to the next top-level declaration.
    private func block(_ name: String) throws -> String {
        let source = Self.appSource
        XCTAssertFalse(source.isEmpty, "app source is unreadable")
        guard let start = source.range(of: "struct \(name)") else {
            throw XCTSkip("declaration \(name) is absent")
        }
        let tail = source[start.lowerBound...]
        // Top-level declarations in this file are all "private struct" /
        // "private extension" / "private func" at column zero.
        let boundaries = ["\nprivate struct ", "\nprivate extension ", "\nprivate func "]
        var end = tail.endIndex
        for boundary in boundaries {
            if let found = tail.dropFirst(1).range(of: boundary) {
                end = min(end, found.lowerBound)
            }
        }
        return String(tail[..<end])
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
            XCTAssertTrue(
                Self.appSource.contains("struct \(name)"),
                "expected Observation boundary view \(name) to exist"
            )
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
