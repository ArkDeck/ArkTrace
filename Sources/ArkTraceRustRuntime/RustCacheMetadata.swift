import ArkTraceCore
import Foundation

public struct RustCacheMetadata: Codable, Sendable {
    public let formatVersion: UInt32
    public let cacheKey: RustCacheKey
    public let parser: TraceParserIdentity
    public let traceSHA256: String
    public let sourceSHA256: String
    public let sourceByteCount: Int64
    public let schemaFingerprint: String
    public let schemaAdapterVersion: String
    public let indexSchemaVersion: UInt32
    public let databasePreparation: RustMetadataPreparation
    public let databaseByteCount: Int64
    public let createdAt: String
    public let lastAccessedAt: String
}
