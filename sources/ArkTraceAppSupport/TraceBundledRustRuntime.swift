#if ARKTRACE_NATIVE_RUNTIME
import ArkTraceCore
import ArkTraceRustRuntime
import Darwin
import Foundation

public extension TraceRustProductRuntime {
    /// Starts the standalone App from its fixed bundled tools and publisher.
    /// Missing or drifted inputs fail startup; there is no alternate backend.
    @concurrent
    static func createBundled(bundleURL: URL = Bundle.main.bundleURL) async throws -> TraceRustProductRuntime {
        let bundleURL = try TraceBundledRustRuntime.physicalBundleURL(bundleURL)
        let profile = try TraceBundledRustRuntime.profile(bundleURL: bundleURL)
        return try await createBundled(configuration: profile,
            publisherCodeIdentifierPrefix: ArkTraceAppDistribution.bundleIdentifier)
    }

    /// Starts a consuming App from its fixed product profile and sealed bundle
    /// manifest. The product supplies its publisher prefix at composition time;
    /// a document request cannot replace tools, storage or publisher policy.
    /// Missing or drifted inputs fail startup without selecting another backend.
    @concurrent
    static func createBundled(
        configuration: TraceProductConfiguration,
        publisherCodeIdentifierPrefix: String
    ) async throws -> TraceRustProductRuntime {
        guard configuration.bundledParserExecutionPolicy == .signedBundleInPlace else {
            throw TraceBundledRustRuntime.unavailable()
        }
        let bundleURL = try TraceBundledRustRuntime.physicalBundleURL(configuration.bundleURL)
        let profile = try TraceProductConfiguration(bundleURL: bundleURL,
            cacheDirectory: configuration.cacheDirectory, stagingDirectory: configuration.stagingDirectory,
            recentDocumentsKey: configuration.recentDocumentsKey, signpostSubsystem: configuration.signpostSubsystem,
            bundledParser: configuration.bundledParser, bundledParserExecutionPolicy: .signedBundleInPlace,
            viewStateBackup: configuration.viewStateBackup)
        let manifest = try TraceBundledRustRuntime.manifest(in: bundleURL,
            publisherCodeIdentifierPrefix: publisherCodeIdentifierPrefix)
        let parser = try TraceBundledParserResolver(configuration: profile).resolve()
        let identity = try await parser.identity()
        try Task.checkCancellation()
        do {
            let roots = [profile.cacheDirectory, profile.stagingDirectory]
                + (profile.viewStateBackup.map { [$0.backupDirectory] } ?? [])
            for root in roots {
                try TraceBundledRustRuntime.preparePrivateDirectory(root)
            }
        } catch { throw TraceBundledRustRuntime.unavailable() }
        let configuration = RustConfiguration(namespace: profile.stagingDirectory,
            helper: bundleURL.appending(path: "Contents/Helpers/arktrace-host-process"),
            parser: bundleURL.appending(path: profile.bundledParser.executableRelativePath), helperSHA256: manifest.helperSHA256,
            parserIdentity: identity, publisher: manifest.publisher,
            storagePolicy: .contentAddressed(cacheDirectory: profile.cacheDirectory),
            viewStateBackup: profile.viewStateBackup.map { .init(backupDirectory: $0.backupDirectory) })
        guard configuration.configuredContractDigest == manifest.contractSHA256 else {
            throw TraceBundledRustRuntime.unavailable()
        }
        // Cold opening includes parsing, indexes and immutable file validation.
        // Use the existing five-minute opening ceiling for real large traces;
        // interactive repository operations retain their independent budgets.
        let runtime = try await create(configuration: profile, runtimeConfiguration: configuration,
            openTimeoutMilliseconds: 300_000)
        do {
            // Admit held storage roots before publishing the controller. The
            // worker admits the actual signed tools before its first open.
            _ = try await runtime.cacheMaintenance.inventory()
            try Task.checkCancellation()
            return runtime
        } catch {
            try await runtime.shutdown()
            throw error
        }
    }
}

package enum TraceBundledRustRuntime {
    package struct Manifest: Decodable {
        let formatVersion: UInt32
        let contractSHA256: String
        let helperSHA256: String
        let publisher: RustPublisher
    }

    /// Foundation shortens /private/tmp and /private/var when standardizing
    /// URLs. Restore only the verified root-owned OS prefix for native held
    /// no-follow traversal; preserve every bundle component without resolving it.
    static func physicalBundleURL(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw unavailable() }
        let path = url.path
        for alias in ["/tmp", "/var", "/etc"] where path.hasPrefix(alias + "/") {
            var info = stat()
            guard alias.withCString({ unsafe Darwin.lstat($0, &info) }) == 0,
                  info.st_uid == 0, info.st_mode & S_IFMT == S_IFLNK else { throw unavailable() }
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: alias)
            guard target == "/private" + alias || target == "private" + alias else { throw unavailable() }
            return URL(filePath: "/private" + path, directoryHint: .isDirectory)
        }
        return url
    }

    static func profile(bundleURL: URL) throws -> TraceProductConfiguration {
        let files = FileManager.default
        let cache = files.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: ArkTraceAppDistribution.bundleIdentifier).appending(path: "native-v1")
        let backup = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: ArkTraceAppDistribution.bundleIdentifier).appending(path: "view-state-backups")
        return try TraceProductConfiguration(bundleURL: bundleURL, cacheDirectory: cache.appending(path: "traces"),
            stagingDirectory: cache.appending(path: "staging"), recentDocumentsKey: "ArkTrace.RecentTraceBookmarks.v1",
            signpostSubsystem: ArkTraceAppDistribution.bundleIdentifier, bundledParser: .arkTrace,
            bundledParserExecutionPolicy: .signedBundleInPlace,
            viewStateBackup: .init(backupDirectory: backup))
    }

    static func manifest(in bundleURL: URL,
                         publisherCodeIdentifierPrefix: String = ArkTraceAppDistribution.bundleIdentifier) throws -> Manifest {
        let prefix = publisherCodeIdentifierPrefix
        guard !prefix.isEmpty, prefix.utf8.count <= 240,
              prefix.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }),
              prefix.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || [45, 46, 95].contains($0) }) else { throw unavailable() }
        let url = bundleURL.appending(path: "Contents/Resources/ArkTraceRuntime/manifest.json")
        let helper = bundleURL.appending(path: "Contents/Helpers/arktrace-host-process")
        guard TraceBundledParserResolver.isRegularReadableFile(url, inside: bundleURL, executable: false),
              TraceBundledParserResolver.isRegularReadableFile(helper, inside: bundleURL, executable: true) else {
            throw unavailable()
        }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: 65_537) ?? Data()
            guard data.count <= 65_536,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["formatVersion", "contractSHA256", "helperSHA256", "publisher"],
                  let publisher = object["publisher"] as? [String: Any],
                  Set(publisher.keys) == ["teamIdentifier", "helperCodeIdentifier", "parserCodeIdentifier"] else {
                throw unavailable()
            }
            let value = try JSONDecoder().decode(Manifest.self, from: data)
            guard value.formatVersion == 1,
                  [value.contractSHA256, value.helperSHA256].allSatisfy({ $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }),
                  value.publisher.teamIdentifier.utf8.count == 10,
                  value.publisher.teamIdentifier.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }),
                  value.publisher.helperCodeIdentifier == prefix + ".host-process",
                  value.publisher.parserCodeIdentifier == prefix + ".trace-streamer" else { throw unavailable() }
            return value
        } catch { throw unavailable() }
    }

    /// Creates only missing components through held, no-follow parents. Never
    /// repairs permissions of an existing directory. Native admission performs
    /// the remaining ACL, filesystem and held-root validation.
    static func preparePrivateDirectory(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), url.path != "/", !url.pathComponents.contains("..") else { throw unavailable() }
        let uid = Darwin.geteuid()
        var descriptor = unsafe Darwin.open("/", O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw unavailable() }
        defer { _ = Darwin.close(descriptor) }
        let components = url.pathComponents.dropFirst()
        for (index, component) in components.enumerated() {
            try Task.checkCancellation()
            var parent = stat()
            guard unsafe Darwin.fstat(descriptor, &parent) == 0,
                  parent.st_uid == 0 || parent.st_uid == uid,
                  parent.st_mode & 0o022 == 0 || (parent.st_uid == 0 && parent.st_mode & 0o1000 != 0) else { throw unavailable() }
            let access = index == components.count - 1 ? O_RDONLY : O_SEARCH
            let opened = component.withCString {
                let result = unsafe Darwin.openat(descriptor, $0, access | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                return (result, result < 0 ? errno : 0)
            }
            var child = opened
            if child.0 < 0, opened.1 == ENOENT {
                let made = component.withCString {
                    let result = unsafe Darwin.mkdirat(descriptor, $0, 0o700)
                    return (result, result < 0 ? errno : 0)
                }
                guard made.0 == 0 || made.1 == EEXIST else {
                    throw POSIXError(POSIXErrorCode(rawValue: made.1) ?? .EIO)
                }
                child = component.withCString {
                    let result = unsafe Darwin.openat(descriptor, $0, access | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    return (result, result < 0 ? errno : 0)
                }
            }
            guard child.0 >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: child.1) ?? .EIO) }
            _ = Darwin.close(descriptor)
            descriptor = child.0
            if index == components.count - 1 {
                var final = stat()
                guard unsafe Darwin.fstat(descriptor, &final) == 0,
                      final.st_uid == uid, final.st_mode & 0o077 == 0 else { throw unavailable() }
            }
        }
    }

    static func unavailable() -> ArkTraceError {
        ArkTraceError(code: .traceStreamerUnavailable, stage: .preparing,
            message: "Bundled trace runtime or private product storage is unavailable", retryable: true)
    }
}
#endif
