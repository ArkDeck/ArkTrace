import ArkTraceCore
import Foundation

public struct RustCacheKey: Codable, Sendable {
    public let traceSHA256: String
    public let parserBinarySHA256: String
    public let upstreamRevision: String
    public let schemaAdapterVersion: String
    public let indexSchemaVersion: Int64
    public let parserKey: String
}
