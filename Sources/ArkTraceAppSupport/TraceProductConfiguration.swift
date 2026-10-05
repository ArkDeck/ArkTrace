import ArkTraceCore
import Foundation

/// How a product executes its reviewed bundled parser.
///
/// A non-sandboxed CLI or app snapshots the executable before launch. A
/// sandboxed signed app must execute the nested helper in place because macOS
/// rejects code copied from the sealed bundle into its writable container.
public enum TraceBundledParserExecutionPolicy: String, Hashable, Codable, Sendable {
    case immutableSnapshot
    case signedBundleInPlace
}

/// Fixed locations for the parser embedded by a consuming product.
///
/// Paths are relative to that product's bundle and are validated when this
/// value is constructed. A request opening a trace never gets to replace
/// these locations or select another executable.
public struct TraceBundledParserLocation: Hashable, Sendable {
    public let executableRelativePath: String
    public let manifestRelativePath: String

    public init(
        executableRelativePath: String,
        manifestRelativePath: String
    ) throws {
        try Self.validate(executableRelativePath, field: "executableRelativePath")
        try Self.validate(manifestRelativePath, field: "manifestRelativePath")
        self.executableRelativePath = executableRelativePath
        self.manifestRelativePath = manifestRelativePath
    }

    public func executableURL(in bundleURL: URL) -> URL {
        Self.appending(executableRelativePath, to: bundleURL)
    }

    public func manifestURL(in bundleURL: URL) -> URL {
        Self.appending(manifestRelativePath, to: bundleURL)
    }

    package static let arkTrace = TraceBundledParserLocation(
        reviewedExecutableRelativePath: "Contents/Helpers/trace_streamer",
        reviewedManifestRelativePath: "Contents/Resources/TraceStreamer/manifest.json"
    )

    private init(
        reviewedExecutableRelativePath: String,
        reviewedManifestRelativePath: String
    ) {
        executableRelativePath = reviewedExecutableRelativePath
        manifestRelativePath = reviewedManifestRelativePath
    }

    private static func validate(_ path: String, field: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
            path.utf8.count <= 4_096,
            !path.utf8.contains(0),
            !components.isEmpty,
            components.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
            })
        else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .preparing,
                message: "Bundled parser location is invalid",
                details: ["field": field]
            )
        }
    }

    private static func appending(_ relativePath: String, to bundleURL: URL) -> URL {
        relativePath.split(separator: "/").reduce(bundleURL.standardizedFileURL) {
            partial, component in
            partial.appending(path: String(component), directoryHint: .notDirectory)
        }
    }
}

/// Fixed product-owned storage for manual current-state backups.
public struct TraceProductViewStateBackupConfiguration: Hashable, Sendable {
    public let backupDirectory: URL

    public init(backupDirectory: URL) throws {
        let roots = [backupDirectory]
        guard roots.allSatisfy({ $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost")
            && $0.path.hasPrefix("/") && $0.path.utf8.count <= 4096 && !$0.path.utf8.contains(0)
            && !$0.pathComponents.contains("..") && !$0.pathComponents.contains(".")
            && $0.standardizedFileURL.path != "/"
            && $0.standardizedFileURL != FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL }) else {
            throw ArkTraceError(code: .invalidArgument, stage: .preparing,
                message: "Trace view-state backup storage configuration is invalid")
        }
        self.backupDirectory = backupDirectory.standardizedFileURL
    }

    fileprivate static func disjoint(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.standardizedFileURL.pathComponents, right = rhs.standardizedFileURL.pathComponents
        return !left.starts(with: right) && !right.starts(with: left)
    }
}

/// Product-owned composition values for the shared trace document engine.
/// Consumers own their bundles, storage, backups and preference namespaces.
public struct TraceProductConfiguration: Hashable, Sendable {
    public let bundleURL: URL
    public let cacheDirectory: URL
    public let stagingDirectory: URL
    public let recentDocumentsKey: String
    public let signpostSubsystem: String
    public let bundledParser: TraceBundledParserLocation
    public let bundledParserExecutionPolicy: TraceBundledParserExecutionPolicy
    public let viewStateBackup: TraceProductViewStateBackupConfiguration?

    public init(
        bundleURL: URL,
        cacheDirectory: URL,
        stagingDirectory: URL,
        recentDocumentsKey: String,
        signpostSubsystem: String,
        bundledParser: TraceBundledParserLocation,
        bundledParserExecutionPolicy: TraceBundledParserExecutionPolicy = .immutableSnapshot,
        viewStateBackup: TraceProductViewStateBackupConfiguration? = nil
    ) throws {
        let bundleURL = bundleURL.standardizedFileURL
        let cacheDirectory = cacheDirectory.standardizedFileURL
        let stagingDirectory = stagingDirectory.standardizedFileURL
        let cacheParent = cacheDirectory.deletingLastPathComponent()
        let stagingParent = stagingDirectory.deletingLastPathComponent()
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL
        guard bundleURL.isFileURL,
            cacheDirectory.isFileURL,
            stagingDirectory.isFileURL,
            cacheDirectory.lastPathComponent == "traces",
            stagingDirectory.lastPathComponent == "staging",
            cacheParent == stagingParent,
            cacheParent.path != "/",
            cacheParent != homeDirectory,
            cacheDirectory != stagingDirectory
        else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .cacheLookup,
                message: "Trace product storage configuration is invalid"
            )
        }
        guard Self.isBoundedIdentifier(recentDocumentsKey, maximumByteCount: 256),
            Self.isBoundedIdentifier(signpostSubsystem, maximumByteCount: 255)
        else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .preparing,
                message: "Trace product identity configuration is invalid"
            )
        }
        if let backup = viewStateBackup {
            guard [cacheDirectory, stagingDirectory].allSatisfy({ root in
                TraceProductViewStateBackupConfiguration.disjoint(root, backup.backupDirectory)
            }) else {
                throw ArkTraceError(code: .invalidArgument, stage: .preparing,
                    message: "Trace view-state backup root overlaps product storage")
            }
        }
        self.bundleURL = bundleURL
        self.cacheDirectory = cacheDirectory
        self.stagingDirectory = stagingDirectory
        self.recentDocumentsKey = recentDocumentsKey
        self.signpostSubsystem = signpostSubsystem
        self.bundledParser = bundledParser
        self.bundledParserExecutionPolicy = bundledParserExecutionPolicy
        self.viewStateBackup = viewStateBackup
    }

    package init(
        reviewedBundleURL: URL,
        reviewedCacheDirectory: URL,
        reviewedStagingDirectory: URL,
        reviewedRecentDocumentsKey: String,
        reviewedSignpostSubsystem: String,
        reviewedBundledParser: TraceBundledParserLocation,
        reviewedBundledParserExecutionPolicy: TraceBundledParserExecutionPolicy
    ) {
        bundleURL = reviewedBundleURL.standardizedFileURL
        cacheDirectory = reviewedCacheDirectory.standardizedFileURL
        stagingDirectory = reviewedStagingDirectory.standardizedFileURL
        recentDocumentsKey = reviewedRecentDocumentsKey
        signpostSubsystem = reviewedSignpostSubsystem
        bundledParser = reviewedBundledParser
        bundledParserExecutionPolicy = reviewedBundledParserExecutionPolicy
        viewStateBackup = nil
    }

    private static func isBoundedIdentifier(
        _ value: String,
        maximumByteCount: Int
    ) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumByteCount
            && !value.utf8.contains(0)
            && !value.contains("\n")
            && !value.contains("\r")
    }
}
