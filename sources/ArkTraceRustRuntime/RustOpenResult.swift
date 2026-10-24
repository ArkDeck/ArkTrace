import ArkTraceCore
import Foundation

public struct RustOpenResult: Codable, Sendable {
    public let metadata: RustCacheMetadata
    public let inspection: RustInspection
    public let cacheHit: Bool
    private enum CodingKeys: String, CodingKey { case metadata, inspection, cacheHit }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try values.decode(RustCacheMetadata.self, forKey: .metadata)
        inspection = try values.decode(RustInspection.self, forKey: .inspection)
        cacheHit = try values.contains(.cacheHit) ? values.decode(Bool.self, forKey: .cacheHit) : false
    }
    public func traceMetadata(sourceFormat: RustSourceFormat) -> TraceMetadata {
        TraceMetadata(traceSHA256: metadata.traceSHA256, sourceByteCount: metadata.sourceByteCount,
            durationNs: inspection.durationNs, sourceFormat: sourceFormat == .htrace ? "htrace" : "systrace",
            parser: metadata.parser, schemaFingerprint: inspection.schemaFingerprint,
            capabilities: inspection.capabilities, dataQuality: TraceDataQuality(preservingIssues: inspection.dataQuality.warnings))
    }
}
