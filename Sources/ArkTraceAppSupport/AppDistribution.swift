import Foundation
import UniformTypeIdentifiers

/// Reviewed 0.1 distribution candidate. The app is intended for Developer-ID distribution
/// without App Sandbox because it must execute the pinned child parser and
/// open traces selected through Finder/Open With. It still persists only
/// security-scoped file grants when the OS supplies them; bookmark storage is
/// implemented by P3-T05.
public enum ArkTraceAppDistribution {
    public static let bundleIdentifier = "com.arktrace.ArkTrace"
    public static let minimumSystemVersion = "26.0"
    public static let appleSiliconOnly = true
    public static let appSandboxEnabled = false
    public static let signingCandidate = "Developer ID Application"
    public static let permitsNetworkUpload = false
    /// The GUI's explicit Capture window may invoke a user-selected or
    /// discovered OpenHarmony SDK `hdc`. Core, CLI and the ArkDeck analyzer do
    /// not link ArkTraceCapture and retain zero device authority.
    public static let permitsDeviceAccess = true

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

public extension TraceProductConfiguration {
    /// The standalone ArkTrace product profile. Other consumers construct
    /// their own fixed profile and keep product-specific values out of the
    /// shared trace modules.
    static func arkTrace(bundleURL: URL = Bundle.main.bundleURL) -> Self {
        let productRoot = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        )[0].appending(
            path: ArkTraceAppDistribution.bundleIdentifier,
            directoryHint: .isDirectory
        )
        return TraceProductConfiguration(
            reviewedBundleURL: bundleURL,
            reviewedCacheDirectory: productRoot.appending(
                path: "traces", directoryHint: .isDirectory
            ),
            reviewedStagingDirectory: productRoot.appending(
                path: "staging", directoryHint: .isDirectory
            ),
            reviewedRecentDocumentsKey: "ArkTrace.RecentTraceBookmarks.v1",
            reviewedSignpostSubsystem: ArkTraceAppDistribution.bundleIdentifier,
            reviewedBundledParser: .arkTrace,
            reviewedBundledParserExecutionPolicy: .immutableSnapshot
        )
    }
}
