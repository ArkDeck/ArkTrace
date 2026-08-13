import ArkTraceCore
import ArkTraceParser
import Darwin
import Foundation

/// Reviewed 0.1 distribution candidate. The app is intended for Developer-ID distribution
/// without App Sandbox because it must execute the pinned child parser and
/// open traces selected through Finder/Open With. It still persists only
/// security-scoped file grants when the OS supplies them; bookmark storage is
/// implemented by P3-T05.
public enum ArkTraceAppDistribution {
    public static let bundleIdentifier = "com.arktrace.ArkTrace"
    public static let minimumSystemVersion = "14.0"
    public static let appleSiliconOnly = true
    public static let appSandboxEnabled = false
    public static let signingCandidate = "Developer ID Application"
    public static let permitsNetworkUpload = false
    public static let permitsDeviceAccess = false

    public static func cacheURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }
}

/// Production resolver is bundle-only. There is intentionally no PATH or
/// environment fallback: a missing or drifted bundle is a typed unavailable/
/// identity failure, never a launch of an ambient executable.
public struct ArkTraceBundledParserResolver: Sendable {
    public let bundleURL: URL

    public init(bundleURL: URL = Bundle.main.bundleURL) {
        self.bundleURL = bundleURL
    }

    public func resolve() throws -> TraceStreamerProcessParser {
        let executableURL = TraceStreamerResolver.appBundleExecutableURL(
            bundleURL: bundleURL
        )
        let manifestURL = executableURL.deletingLastPathComponent()
            .appendingPathComponent("manifest.json", isDirectory: false)
        guard Self.isRegularReadableFile(executableURL, executable: true),
            Self.isRegularReadableFile(manifestURL, executable: false)
        else {
            throw ArkTraceError(
                code: .traceStreamerUnavailable,
                stage: .preparing,
                message: "Bundled TraceStreamer executable or manifest is unavailable",
                retryable: true
            )
        }
        return try TraceStreamerResolver(
            appBundleURL: bundleURL,
            cliExecutableURL: nil
        ).resolve()
    }

    private static func isRegularReadableFile(
        _ url: URL,
        executable: Bool
    ) -> Bool {
        var info = stat()
        let status = url.path.withCString { Darwin.lstat($0, &info) }
        guard status == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        let mode = executable ? (R_OK | X_OK) : R_OK
        return url.path.withCString { Darwin.access($0, mode) } == 0
    }
}

/// Debug-only explicit override. App production code does not instantiate
/// this type and never reads PATH/environment variables.
#if DEBUG
public struct ArkTraceDeveloperParserResolver: Sendable {
    public init() {}

    public func resolve(executableURL: URL) throws -> TraceStreamerProcessParser {
        try TraceStreamerResolver(
            appBundleURL: URL(fileURLWithPath: "/nonexistent", isDirectory: true),
            cliExecutableURL: nil
        ).resolve(explicitExecutableURL: executableURL)
    }
}
#endif
