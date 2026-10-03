import ArkTraceCore
import CArkTrace
import Foundation

public struct RustPublisher: Codable, Sendable {
    public let teamIdentifier: String
    public let helperCodeIdentifier: String
    public let parserCodeIdentifier: String
    public init(teamIdentifier: String, helperCodeIdentifier: String, parserCodeIdentifier: String) {
        self.teamIdentifier = teamIdentifier
        self.helperCodeIdentifier = helperCodeIdentifier
        self.parserCodeIdentifier = parserCodeIdentifier
    }
}

/// Fixed trusted host configuration. Requests cannot change these values.
public struct RustConfiguration: Encodable, Sendable {
    let abiVersion: UInt32 = ARKTRACE_ABI_VERSION
    let contractDigest: String = ARKTRACE_CONTRACT_DIGEST
    let cachePolicy = "ephemeral"
    let namespace: String
    let helper: String
    let parser: String
    let helperSHA256: String
    let parserIdentity: TraceParserIdentity
    let publisher: RustPublisher?
    public init(namespace: URL, helper: URL, parser: URL, helperSHA256: String, parserIdentity: TraceParserIdentity, publisher: RustPublisher) {
        self.namespace = namespace.path
        self.helper = helper.path
        self.parser = parser.path
        self.helperSHA256 = helperSHA256
        self.parserIdentity = parserIdentity
        self.publisher = publisher
    }
    #if ARKTRACE_RUST_PROCESS_FIXTURES
    public static func developmentFixture(namespace: URL, helper: URL, parser: URL, helperSHA256: String, parserIdentity: TraceParserIdentity) -> Self {
        Self(namespace: namespace, helper: helper, parser: parser, helperSHA256: helperSHA256, parserIdentity: parserIdentity)
    }
    private init(namespace: URL, helper: URL, parser: URL, helperSHA256: String, parserIdentity: TraceParserIdentity) {
        self.namespace = namespace.path; self.helper = helper.path; self.parser = parser.path
        self.helperSHA256 = helperSHA256; self.parserIdentity = parserIdentity; publisher = nil
    }
    #endif
}
