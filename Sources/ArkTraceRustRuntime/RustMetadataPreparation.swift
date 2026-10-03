import ArkTraceCore
import Foundation

public struct RustMetadataPreparation: Codable, Sendable {
    public let schemaAdapterVersion: String
    public let schemaFingerprint: String
    public let indexVersion: UInt32
    public let upstreamDatabaseSHA256: String
    public let upstreamDatabaseByteCount: Int64
}
