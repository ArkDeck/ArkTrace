import ArkTraceCore
import ArkTraceParser
import Darwin
import Foundation

/// Production resolver for a product-owned, bundle-only parser location.
/// There is intentionally no PATH or environment fallback: a missing or
/// drifted bundle is a typed unavailable/identity failure, never a launch of
/// an ambient executable.
package struct TraceBundledParserResolver: Sendable {
    public let bundleURL: URL
    public let location: TraceBundledParserLocation
    public let executionPolicy: TraceBundledParserExecutionPolicy

    public init(
        bundleURL: URL = Bundle.main.bundleURL,
        location: TraceBundledParserLocation = .arkTrace,
        executionPolicy: TraceBundledParserExecutionPolicy = .immutableSnapshot
    ) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.location = location
        self.executionPolicy = executionPolicy
    }

    public init(configuration: TraceProductConfiguration) {
        self.init(
            bundleURL: configuration.bundleURL,
            location: configuration.bundledParser,
            executionPolicy: configuration.bundledParserExecutionPolicy
        )
    }

    /// Every location this resolver will ever consider.
    public func candidateExecutableURLs() -> [URL] {
        [location.executableURL(in: bundleURL)]
    }

    public func resolve() throws -> TraceStreamerProcessParser {
        let executableURL = location.executableURL(in: bundleURL)
        let manifestURL = location.manifestURL(in: bundleURL)
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
                message:
                    "Bundled TraceStreamer executable or manifest is unavailable",
                retryable: true
            )
        }
        let executionMode: TraceStreamerExecutionMode = switch executionPolicy {
        case .immutableSnapshot: .immutableSnapshot
        case .signedBundleInPlace: .signedBundleInPlace
        }
        return try TraceStreamerProcessParser(
            executableURL: executableURL,
            manifestURL: manifestURL,
            executionMode: executionMode
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
            current.append(path: String(component), directoryHint: .notDirectory)
            let expected = index == components.count - 1 ? S_IFREG : S_IFDIR
            guard Self.hasMode(current, expected: expected) else { return false }
        }
        let mode = executable ? (R_OK | X_OK) : R_OK
        return unsafe candidate.path.withCString { unsafe Darwin.access($0, mode) } == 0
    }

    private static func hasMode(_ url: URL, expected: mode_t) -> Bool {
        var info = stat()
        return unsafe url.path.withCString { unsafe Darwin.lstat($0, &info) } == 0
            && (info.st_mode & S_IFMT) == expected
    }
}
