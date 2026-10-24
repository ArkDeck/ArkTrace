import AppKit
import ArkTraceAppSupport
import SwiftUI

/// Observation boundary: VoiceOver announcements. Reads only
/// `accessibilityAnnouncement`, so announcement churn re-evaluates this
/// zero-size bridge and nothing else.
struct TraceAnnouncementBridge: View {
    var controller: TraceDocumentController

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: controller.accessibilityAnnouncement) { _, announcement in
                guard let announcement else { return }
                postAccessibilityAnnouncement(announcement)
            }
    }

    /// AppSupport hands over a typed message and, for the counted messages,
    /// one numeric argument. Resolving here keeps the string catalog in the
    /// app bundle instead of giving a library target a resource bundle. The
    /// typed switch over generated catalog symbols replaces the former
    /// stringly-keyed lookup and C-varargs formatting pair, so a missing key
    /// or a drifted argument signature is now a compile error.
    private func localizedAnnouncement(
        _ announcement: TraceAccessibilityAnnouncement
    ) -> String {
        String(localized: announcement.kind.localizedResource)
    }

    private func postAccessibilityAnnouncement(
        _ announcement: TraceAccessibilityAnnouncement
    ) {
        guard let application = NSApp else { return }
        // AppKit owns the application and receives this announcement on the
        // main actor; no unretained accessibility object escapes this call.
        unsafe NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo:
            [
                .announcement: localizedAnnouncement(announcement),
                .priority: NSNumber(
                    value: announcement.priority == .urgent ? 90 : 50
                ),
            ]
        )
    }
}
