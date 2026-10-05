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
public enum RustStoragePolicy: Sendable {
    case ephemeral
    case contentAddressed(cacheDirectory: URL)
}

/// Fixed product roots, separate from every trace or migration request.
public struct RustViewStateMigrationConfiguration: Encodable, Sendable {
    let legacyCacheDirectory: String
    let backupDirectory: String
    public init(legacyCacheDirectory: URL, backupDirectory: URL) {
        self.legacyCacheDirectory = legacyCacheDirectory.path
        self.backupDirectory = backupDirectory.path
    }
    package var configuredLegacyCacheDirectory: URL { URL(filePath: legacyCacheDirectory) }
    package var configuredBackupDirectory: URL { URL(filePath: backupDirectory) }
}

public struct RustConfiguration: Encodable, Sendable {
    let abiVersion: UInt32 = ARKTRACE_ABI_VERSION
    let contractDigest: String = ARKTRACE_CONTRACT_DIGEST
    let cachePolicy: String
    let cacheDirectory: String?
    let viewStateMigration: RustViewStateMigrationConfiguration?
    let namespace: String
    let helper: String
    let parser: String
    let helperSHA256: String
    let parserIdentity: TraceParserIdentity
    let publisher: RustPublisher?
    package var configuredNamespace: URL { URL(filePath: namespace) }
    package var configuredCacheDirectory: URL? { cacheDirectory.map { URL(filePath: $0) } }
    package var configuredParser: URL { URL(filePath: parser) }
    package var configuredViewStateMigration: RustViewStateMigrationConfiguration? { viewStateMigration }
    public init(namespace: URL, helper: URL, parser: URL, helperSHA256: String, parserIdentity: TraceParserIdentity, publisher: RustPublisher, storagePolicy: RustStoragePolicy = .ephemeral, viewStateMigration: RustViewStateMigrationConfiguration? = nil) {
        switch storagePolicy {
        case .ephemeral: cachePolicy = "ephemeral"; cacheDirectory = nil
        case .contentAddressed(let directory): cachePolicy = "contentAddressed"; cacheDirectory = directory.path
        }
        self.namespace = namespace.path
        self.viewStateMigration = viewStateMigration
        self.helper = helper.path
        self.parser = parser.path
        self.helperSHA256 = helperSHA256
        self.parserIdentity = parserIdentity
        self.publisher = publisher
    }
    #if ARKTRACE_RUST_PROCESS_FIXTURES
    public static func developmentFixture(namespace: URL, helper: URL, parser: URL, helperSHA256: String, parserIdentity: TraceParserIdentity, storagePolicy: RustStoragePolicy = .ephemeral, viewStateMigration: RustViewStateMigrationConfiguration? = nil) -> Self {
        Self(namespace: namespace, helper: helper, parser: parser, helperSHA256: helperSHA256, parserIdentity: parserIdentity, storagePolicy: storagePolicy, viewStateMigration: viewStateMigration)
    }
    private init(namespace: URL, helper: URL, parser: URL, helperSHA256: String, parserIdentity: TraceParserIdentity, storagePolicy: RustStoragePolicy, viewStateMigration: RustViewStateMigrationConfiguration?) {
        switch storagePolicy {
        case .ephemeral: cachePolicy = "ephemeral"; cacheDirectory = nil
        case .contentAddressed(let directory): cachePolicy = "contentAddressed"; cacheDirectory = directory.path
        }
        self.namespace = namespace.path; self.helper = helper.path; self.parser = parser.path
        self.viewStateMigration = viewStateMigration
        self.helperSHA256 = helperSHA256; self.parserIdentity = parserIdentity; publisher = nil
    }
    #endif
}
