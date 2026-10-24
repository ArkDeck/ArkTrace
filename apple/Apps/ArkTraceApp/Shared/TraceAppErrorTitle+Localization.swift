import ArkTraceAppSupport
import SwiftUI

extension TraceAppErrorTitle {
    var localizedResource: LocalizedStringResource {
        switch self {
        case .traceCouldNotBeOpened: .errorTitleTraceCouldNotBeOpened
        case .bundledParserUnavailable: .errorTitleBundledParserUnavailable
        case .cacheNeedsAttention: .errorTitleCacheNeedsAttention
        case .openingCancelled: .errorTitleOpeningCancelled
        case .couldNotFinish: .errorTitleCouldNotFinish
        }
    }
}
