import ArkTraceCore
import Foundation

/// Build provenance consumed by the production parser (AT-PARSE-002).
///
/// The identity-bearing fields are required and are validated before the
/// executable can be launched. The remaining fields preserve the build
/// evidence emitted by `scripts/build_trace_streamer.sh`.
package struct TraceStreamerManifest: Codable, Equatable, Sendable {
    public let name: String
    public let upstreamRepository: String
    public let upstreamRevision: String
    public let reportedVersion: String
    public let binarySHA256: String
    public let architecture: String
    public let adapterVersion: String
    public let buildRecipeVersion: String
    public let plugins: String
    public let localPatches: [String]
    public let thirdPartySources: String
    public let thirdPartyRevisions: [String: String]
    public let hostToolchain: String
    public let builtAt: String

    private static let expectedKeys: Set<String> = [
        "name", "upstreamRepository", "upstreamRevision", "reportedVersion",
        "binarySHA256", "architecture", "adapterVersion", "buildRecipeVersion",
        "plugins", "localPatches", "thirdPartySources", "thirdPartyRevisions",
        "hostToolchain", "builtAt",
    ]

    /// Loads the exact manifest schema. Decode and validation errors are
    /// deliberately collapsed to a typed, path-free identity error.
    public static func load(from url: URL) throws -> TraceStreamerManifest {
        let data: Data
        do {
            data = try ArkTraceBoundedRegularFile.read(
                at: url, maximumByteCount: 1_048_576
            )
        } catch {
            throw manifestError(reason: "unavailable")
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            Set(dictionary.keys) == expectedKeys,
            let manifest = try? JSONDecoder().decode(TraceStreamerManifest.self, from: data)
        else {
            throw manifestError(reason: "malformed")
        }

        try manifest.validateShape()
        return manifest
    }

    private func validateShape() throws {
        try Self.requireText(name, field: "name", maxLength: 128)
        try Self.requireText(upstreamRepository, field: "upstreamRepository", maxLength: 2_048)
        try Self.requireHex(upstreamRevision, field: "upstreamRevision", count: 40)
        try Self.requireText(reportedVersion, field: "reportedVersion", maxLength: 128)
        try Self.requireHex(binarySHA256, field: "binarySHA256", count: 64)
        try Self.requireText(architecture, field: "architecture", maxLength: 64)
        try Self.requireText(adapterVersion, field: "adapterVersion", maxLength: 64)
        try Self.requireText(buildRecipeVersion, field: "buildRecipeVersion", maxLength: 64)
        try Self.requireText(plugins, field: "plugins", maxLength: 16_384)
        try Self.requireText(thirdPartySources, field: "thirdPartySources", maxLength: 4_096)
        try Self.requireText(hostToolchain, field: "hostToolchain", maxLength: 4_096)
        try Self.requireText(builtAt, field: "builtAt", maxLength: 128)

        guard localPatches.count <= 128,
            localPatches.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4_096 }),
            thirdPartyRevisions.count <= 256,
            thirdPartyRevisions.allSatisfy({
                !$0.key.isEmpty && $0.key.utf8.count <= 256
                    && !$0.value.isEmpty && $0.value.utf8.count <= 256
            })
        else {
            throw Self.manifestError(reason: "invalidProvenance")
        }
    }

    private static func requireText(_ value: String, field: String, maxLength: Int) throws {
        guard !value.isEmpty, value.utf8.count <= maxLength else {
            throw manifestError(reason: "invalidField", field: field)
        }
    }

    private static func requireHex(_ value: String, field: String, count: Int) throws {
        guard ArkTraceIdentityGrammar.isLowercaseHex(value, count: count) else {
            throw manifestError(reason: "invalidField", field: field)
        }
    }

    private static func manifestError(reason: String, field: String? = nil) -> ArkTraceError {
        var details = ["reason": reason]
        if let field { details["field"] = field }
        return ArkTraceError(
            code: .traceStreamerIdentityMismatch,
            stage: .preparing,
            message: "TraceStreamer manifest is invalid",
            details: details
        )
    }
}

/// Reads the target architecture from a Mach-O header. Host architecture is
/// intentionally irrelevant: translated and cross-architecture processes are
/// valid deployment configurations.
enum TraceStreamerBinaryInspector {
    static func architecture(at url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw invalidBinary()
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8_192), data.count >= 8 else {
            throw invalidBinary()
        }

        let bytes = [UInt8](data)
        let magic = Array(bytes[0..<4])
        switch magic {
        case [0xcf, 0xfa, 0xed, 0xfe], [0xce, 0xfa, 0xed, 0xfe]:
            return architecture(cpuType: readUInt32(bytes, at: 4, littleEndian: true))
        case [0xfe, 0xed, 0xfa, 0xcf], [0xfe, 0xed, 0xfa, 0xce]:
            return architecture(cpuType: readUInt32(bytes, at: 4, littleEndian: false))
        case [0xca, 0xfe, 0xba, 0xbe]:
            return try fatArchitecture(bytes, littleEndian: false, is64Bit: false)
        case [0xbe, 0xba, 0xfe, 0xca]:
            return try fatArchitecture(bytes, littleEndian: true, is64Bit: false)
        case [0xca, 0xfe, 0xba, 0xbf]:
            return try fatArchitecture(bytes, littleEndian: false, is64Bit: true)
        case [0xbf, 0xba, 0xfe, 0xca]:
            return try fatArchitecture(bytes, littleEndian: true, is64Bit: true)
        default:
            throw invalidBinary()
        }
    }

    private static func fatArchitecture(
        _ bytes: [UInt8], littleEndian: Bool, is64Bit: Bool
    ) throws -> String {
        let count = Int(readUInt32(bytes, at: 4, littleEndian: littleEndian))
        let entrySize = is64Bit ? 32 : 20
        guard count > 0, count <= 32, bytes.count >= 8 + count * entrySize else {
            throw invalidBinary()
        }
        let architectures = (0..<count).map {
            architecture(
                cpuType: readUInt32(bytes, at: 8 + $0 * entrySize, littleEndian: littleEndian))
        }
        return Array(Set(architectures)).sorted().joined(separator: "+")
    }

    private static func architecture(cpuType: UInt32) -> String {
        switch cpuType {
        case 7: return "i386"
        case 12: return "arm"
        case 0x0100_0007: return "x86_64"
        case 0x0100_000c: return "arm64"
        default: return "cpu-\(String(cpuType, radix: 16))"
        }
    }

    private static func readUInt32(
        _ bytes: [UInt8], at offset: Int, littleEndian: Bool
    ) -> UInt32 {
        guard bytes.count >= offset + 4 else { return 0 }
        if littleEndian {
            return UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }
        return UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    private static func invalidBinary() -> ArkTraceError {
        ArkTraceError(
            code: .traceStreamerIdentityMismatch,
            stage: .preparing,
            message: "TraceStreamer executable is not a supported Mach-O binary",
            details: ["field": "architecture", "reason": "invalidBinary"]
        )
    }
}

/// Resolves only the deployment locations reviewed in DESIGN §8.2. Candidate
/// selection never consults PATH, and an invalid higher-priority candidate is
/// returned as an error instead of falling through to another binary.
package struct TraceStreamerResolver: Sendable {
    public let appBundleURL: URL
    public let cliExecutableURL: URL?

    public init(
        appBundleURL: URL = Bundle.main.bundleURL,
        cliExecutableURL: URL? = Bundle.main.executableURL
    ) {
        self.appBundleURL = appBundleURL
        self.cliExecutableURL = cliExecutableURL
    }

    public func resolve(explicitExecutableURL: URL? = nil) throws
        -> TraceStreamerProcessParser
    {
        if let explicitExecutableURL {
            return try TraceStreamerProcessParser(executableURL: explicitExecutableURL)
        }

        let appCandidate = Self.appBundleExecutableURL(bundleURL: appBundleURL)
        if FileManager.default.fileExists(atPath: appCandidate.path) {
            return try TraceStreamerProcessParser(
                executableURL: appCandidate,
                manifestURL: Self.appBundleManifestURL(bundleURL: appBundleURL)
            )
        }

        if let cliExecutableURL,
            let cliCandidate = Self.cliLibexecURL(cliExecutableURL: cliExecutableURL),
            FileManager.default.fileExists(atPath: cliCandidate.path)
        {
            return try TraceStreamerProcessParser(executableURL: cliCandidate)
        }

        throw ArkTraceError(
            code: .traceStreamerUnavailable,
            stage: .preparing,
            message: "Pinned trace_streamer executable is unavailable",
            retryable: true
        )
    }

    public static func appBundleExecutableURL(bundleURL: URL) -> URL {
        bundleURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Helpers", directoryHint: .isDirectory)
            .appending(path: "trace_streamer", directoryHint: .notDirectory)
    }

    public static func appBundleManifestURL(bundleURL: URL) -> URL {
        bundleURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Resources", directoryHint: .isDirectory)
            .appending(path: "TraceStreamer", directoryHint: .isDirectory)
            .appending(path: "manifest.json", directoryHint: .notDirectory)
    }

    public static func cliLibexecURL(cliExecutableURL: URL) -> URL? {
        let binDirectory = cliExecutableURL.deletingLastPathComponent()
        guard binDirectory.lastPathComponent == "bin" else { return nil }
        return binDirectory.deletingLastPathComponent()
            .appending(path: "libexec", directoryHint: .isDirectory)
            .appending(path: "arktrace", directoryHint: .isDirectory)
            .appending(path: "trace_streamer", directoryHint: .notDirectory)
    }

    /// Every location this resolver will ever consider, in resolution order.
    ///
    /// Production selection never searches `PATH`, and this makes that
    /// checkable rather than merely absent: a test can assert a planted binary
    /// is not in this list without mutating the process environment. Mutating
    /// the real `PATH` to prove the same thing races every other test that
    /// spawns a subprocess, because the environment is process-global.
    public func candidateExecutableURLs() -> [URL] {
        var candidates = [Self.appBundleExecutableURL(bundleURL: appBundleURL)]
        if let cliExecutableURL,
            let libexec = Self.cliLibexecURL(cliExecutableURL: cliExecutableURL)
        {
            candidates.append(libexec)
        }
        return candidates
    }
}
