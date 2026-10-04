import ArkTraceCore
import Foundation

public struct RustOpenResult: Codable, Sendable {
    public let metadata: RustCacheMetadata
    public let inspection: RustInspection
    public func traceMetadata(sourceFormat: RustSourceFormat) -> TraceMetadata {
        TraceMetadata(traceSHA256: metadata.traceSHA256, sourceByteCount: metadata.sourceByteCount,
            durationNs: inspection.durationNs, sourceFormat: sourceFormat == .htrace ? "htrace" : "systrace",
            parser: metadata.parser, schemaFingerprint: inspection.schemaFingerprint,
            capabilities: inspection.capabilities, dataQuality: TraceDataQuality(preservingIssues: inspection.dataQuality.warnings))
    }
}
