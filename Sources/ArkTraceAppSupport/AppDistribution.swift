import ArkTraceCore
import ArkTraceParser
import Darwin
import Foundation
import UniformTypeIdentifiers

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

    /// Reviewed file-picker and Finder hint extensions (SPEC 2.3). The format
    /// is decided by the parser and schema validation, never by the extension;
    /// this list only drives `CFBundleDocumentTypes` and the Open panel, and
    /// `AppDistributionTests` fails closed when the two drift apart.
    public static let supportedTraceExtensions = ["htrace", "ftrace", "systrace", "trace"]

    /// Uniform types for the Open panel, derived from the same reviewed list.
    /// Extensions the system does not know become dynamic types, which is the
    /// documented way to filter on an app-specific extension.
    public static var supportedTraceContentTypes: [UTType] {
        supportedTraceExtensions.compactMap { UTType(filenameExtension: $0) }
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

    /// Every location this resolver will ever consider.
    ///
    /// The bundled resolver has exactly one: the helper inside the app bundle.
    /// Exposing it lets a test assert that a planted binary elsewhere is never
    /// a candidate, without mutating the process-global `PATH` to say so.
    public func candidateExecutableURLs() -> [URL] {
        [TraceStreamerResolver.appBundleExecutableURL(bundleURL: bundleURL)]
    }

    public func resolve() throws -> TraceStreamerProcessParser {
        let executableURL = TraceStreamerResolver.appBundleExecutableURL(
            bundleURL: bundleURL
        )
        let manifestURL = TraceStreamerResolver.appBundleManifestURL(
            bundleURL: bundleURL
        )
        guard Self.isRegularReadableFile(
                executableURL, inside: bundleURL, executable: true
            ),
            Self.isRegularReadableFile(
                manifestURL, inside: bundleURL, executable: false
            )
        else {
            throw ArkTraceError(
                code: .traceStreamerUnavailable,
                stage: .preparing,
                message: "Bundled TraceStreamer executable or manifest is unavailable",
                retryable: true
            )
        }
        return try TraceStreamerProcessParser(
            executableURL: executableURL,
            manifestURL: manifestURL
        )
    }

    private static func isRegularReadableFile(
        _ url: URL,
        inside bundleURL: URL,
        executable: Bool
    ) -> Bool {
        let root = bundleURL.standardizedFileURL
        let candidate = url.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(prefix),
            Self.hasMode(root, expected: S_IFDIR)
        else { return false }
        let relative = candidate.path.dropFirst(prefix.count)
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return false }
        var current = root
        for (index, component) in components.enumerated() {
            current.appendPathComponent(String(component), isDirectory: false)
            let expected = index == components.count - 1 ? S_IFREG : S_IFDIR
            guard Self.hasMode(current, expected: expected) else { return false }
        }
        let mode = executable ? (R_OK | X_OK) : R_OK
        return candidate.path.withCString { Darwin.access($0, mode) } == 0
    }

    private static func hasMode(_ url: URL, expected: mode_t) -> Bool {
        var info = stat()
        return url.path.withCString { Darwin.lstat($0, &info) } == 0
            && (info.st_mode & S_IFMT) == expected
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
