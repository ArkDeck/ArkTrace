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

/// Fixed product backup root, separate from every trace request.
public struct RustViewStateBackupConfiguration: Encodable, Sendable {
    let backupDirectory: String
    public init(backupDirectory: URL) {
        self.backupDirectory = backupDirectory.path
    }
    package var configuredBackupDirectory: URL { URL(filePath: backupDirectory) }
}

public struct RustConfiguration: Encodable, Sendable {
    let abiVersion: UInt32 = ARKTRACE_ABI_VERSION
    let contractDigest: String = ARKTRACE_CONTRACT_DIGEST
    package var configuredContractDigest: String { contractDigest }
    let cachePolicy: String
    let cacheDirectory: String?
    let viewStateBackup: RustViewStateBackupConfiguration?
    let namespace: String
    let helper: String
    let parser: String
    let helperSHA256: String
    let parserIdentity: TraceParserIdentity
    let publisher: RustPublisher?
    package var configuredNamespace: URL { URL(filePath: namespace) }
    package var configuredCacheDirectory: URL? { cacheDirectory.map { URL(filePath: $0) } }
    package var configuredParser: URL { URL(filePath: parser) }
    package var configuredViewStateBackup: RustViewStateBackupConfiguration? { viewStateBackup }
    public init(namespace: URL, helper: URL, parser: URL, helperSHA256: String, parserIdentity: TraceParserIdentity, publisher: RustPublisher, storagePolicy: RustStoragePolicy = .ephemeral, viewStateBackup: RustViewStateBackupConfiguration? = nil) {
        switch storagePolicy {
        case .ephemeral: cachePolicy = "ephemeral"; cacheDirectory = nil
        case .contentAddressed(let directory): cachePolicy = "contentAddressed"; cacheDirectory = directory.path
        }
        self.namespace = namespace.path
        self.viewStateBackup = viewStateBackup
        self.helper = helper.path
        self.parser = parser.path
        self.helperSHA256 = helperSHA256
        self.parserIdentity = parserIdentity
        self.publisher = publisher
    }
    #if ARKTRACE_RUST_PROCESS_FIXTURES
    public static func developmentFixture(namespace: URL, helper: URL, parser: URL, helperSHA256: String, parserIdentity: TraceParserIdentity, storagePolicy: RustStoragePolicy = .ephemeral, viewStateBackup: RustViewStateBackupConfiguration? = nil) -> Self {
        Self(namespace: namespace, helper: helper, parser: parser, helperSHA256: helperSHA256, parserIdentity: parserIdentity, storagePolicy: storagePolicy, viewStateBackup: viewStateBackup)
    }
    private init(namespace: URL, helper: URL, parser: URL, helperSHA256: String, parserIdentity: TraceParserIdentity, storagePolicy: RustStoragePolicy, viewStateBackup: RustViewStateBackupConfiguration?) {
        switch storagePolicy {
        case .ephemeral: cachePolicy = "ephemeral"; cacheDirectory = nil
        case .contentAddressed(let directory): cachePolicy = "contentAddressed"; cacheDirectory = directory.path
        }
        self.namespace = namespace.path; self.helper = helper.path; self.parser = parser.path
        self.viewStateBackup = viewStateBackup
        self.helperSHA256 = helperSHA256; self.parserIdentity = parserIdentity; publisher = nil
    }
    #endif
}
