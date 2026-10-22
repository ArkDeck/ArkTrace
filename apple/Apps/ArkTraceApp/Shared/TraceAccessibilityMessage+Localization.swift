import ArkTraceAppSupport
import SwiftUI

/// Typed bridge from AppSupport's closed message enums to the symbols Xcode
/// generates from `Localizable.xcstrings` (STRING_CATALOG_GENERATE_SYMBOLS).
/// The `%lld` keys generate `Int`-typed argument functions, so no narrowing
/// conversion is involved; adding a message case without a catalog entry now
/// fails to compile here instead of falling back silently at runtime.
extension TraceAccessibilityMessage {
    var localizedResource: LocalizedStringResource {
        switch self {
        case .openingTrace: .a11YAnnounceOpeningTrace
        case .openingCancelled: .a11YAnnounceOpeningCancelled
        case .traceClosed: .a11YAnnounceTraceClosed
        case .traceCloseFailed: .a11YAnnounceTraceCloseFailed
        case .traceOpenFailed: .a11YAnnounceTraceOpenFailed
        case .operationFailed: .a11YAnnounceOperationFailed
        case .rangeAnalysisComplete: .a11YAnnounceRangeAnalysisComplete
        case .traceLoadedWithoutTimedEvents: .a11YAnnounceTraceLoadedWithoutTimedEvents
        case .traceLoadedWithVisibleTracks(let count):
            .a11YAnnounceTraceLoadedWithVisibleTracks(count)
        case .searchFoundResults(let count):
            .a11YAnnounceSearchFoundResults(count)
        case .searchFoundAtLeastResults(let count):
            .a11YAnnounceSearchFoundAtLeastResults(count)
        case .error(let title): title.localizedResource
        }
    }
}
