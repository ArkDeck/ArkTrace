import ArkTraceCore
import CryptoKit
import Foundation

public struct CLIVerifiedLicenseFile: Hashable, Sendable {
    public let owner: String
    public let licenseExpression: String
    public let resourcePath: String
    public let sha256: String
    public let byteCount: Int
    public let data: Data
}

public enum CLILicenseResources {
    public static let componentCount = 14
    public static let buildToolCount = 2
    public static let licenseFileCount = 18
    static let noticeByteCount = 1_517
    static let noticeSHA256 =
        "9e03235bfb104fdeb7a91dfc8321294be0603ecd514729edcf2eace41f5a1a72"

    public static func noticeData() throws -> Data {
        let url = try resourceURL(named: "THIRD_PARTY_NOTICES", extension: "md")
        return try noticeData(resourceURL: url)
    }

    static func noticeData(resourceURL: URL) throws -> Data {
        let data = try boundedResource(at: resourceURL, maximumBytes: 128 * 1_024)
        guard let text = String(data: data, encoding: .utf8),
            data.count == noticeByteCount,
            sha256(data) == noticeSHA256,
            text.contains("ArkTrace itself is licensed under the MIT License"),
            !text.contains("ArkTrace itself is licensed under Apache-2.0")
        else { throw unavailable() }
        return data
    }

    public static func productLicenseData() throws -> Data {
        let data = try boundedResource(
            named: "LICENSE", extension: nil, maximumBytes: 32 * 1_024
        )
        let digest = sha256(data)
        guard data.count == 1_078,
            digest == "27ec10adbe109a67f514a5620190460e52b09352214aaf1d9869be568b6f46d9",
            String(data: data, encoding: .utf8)?.hasPrefix("MIT License\n") == true
        else { throw unavailable() }
        return data
    }

    public static func inventoryData() throws -> Data {
        let data = try boundedResource(
            named: "license-inventory", extension: "json", maximumBytes: 128 * 1_024
        )
        guard data.count == 6_939,
            sha256(data) == "b16397dbbe593a067a0906a496627c8f300b2a4a860eab489181549b35c81e1e"
        else { throw unavailable() }
        return data
    }

    /// Reads and hashes every license file named by the bundled inventory. The
    /// command never treats the inventory as a caller-authored list of paths:
    /// entries are flat LICENSES names and must remain inside the reviewed
    /// executable-relative resource root.
    public static func verifiedLicenseFiles(
        inventoryData suppliedInventory: Data? = nil,
        licenseDirectoryURL suppliedDirectory: URL? = nil
    ) throws -> [CLIVerifiedLicenseFile] {
        let inventory = try suppliedInventory ?? inventoryData()
        guard inventory.count == 6_939,
            sha256(inventory) == "b16397dbbe593a067a0906a496627c8f300b2a4a860eab489181549b35c81e1e",
            let root = suppliedDirectory
                ?? (try? CLIResourceLocator.productionRoot().appendingPathComponent(
                    "LICENSES", isDirectory: true
                ))
        else { throw unavailable() }
        return try validateInventory(inventory, licenseDirectoryURL: root)
    }

    private static func validateInventory(
        _ data: Data, licenseDirectoryURL: URL
    ) throws -> [CLIVerifiedLicenseFile] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == ["formatVersion", "policy", "buildTools", "components"],
            object["formatVersion"] as? Int == 1,
            let components = object["components"] as? [[String: Any]],
            components.count == componentCount,
            let buildTools = object["buildTools"] as? [[String: Any]],
            buildTools.count == buildToolCount
        else { throw unavailable() }

        let suppliedRoot = licenseDirectoryURL.standardizedFileURL
        let root = suppliedRoot.resolvingSymlinksInPath().standardizedFileURL
        guard suppliedRoot.path == root.path
        else { throw unavailable() }
        let rootValues = try? root.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard rootValues?.isDirectory == true, rootValues?.isSymbolicLink != true else {
            throw unavailable()
        }

        var records: [(owner: String, expression: String, path: String, sha: String, bytes: Int)] = []
        for entry in components {
            let baseKeys: Set<String> = [
                "name", "repository", "revision", "licenseExpression", "licenseFile",
                "licenseSHA256", "licenseByteCount", "usage",
            ]
            let allowedKeys = baseKeys.union(["additionalLicenseFiles"])
            guard Set(entry.keys).isSubset(of: allowedKeys),
                Set(entry.keys).isSuperset(of: baseKeys),
                let name = boundedString(entry["name"], maximumBytes: 128),
                let expression = boundedString(entry["licenseExpression"], maximumBytes: 256),
                let path = safeLicensePath(entry["licenseFile"]),
                let sha = shaValue(entry["licenseSHA256"]),
                let bytes = positiveInt(entry["licenseByteCount"])
            else { throw unavailable() }
            records.append((name, expression, path, sha, bytes))
            let additional: [[String: Any]]
            if let supplied = entry["additionalLicenseFiles"] {
                guard let parsed = supplied as? [[String: Any]], parsed.count <= 8
                else { throw unavailable() }
                additional = parsed
            } else {
                additional = []
            }
            for extra in additional {
                guard Set(extra.keys) == ["path", "sha256", "byteCount"],
                    let extraPath = safeLicensePath(extra["path"]),
                    let extraSHA = shaValue(extra["sha256"]),
                    let extraBytes = positiveInt(extra["byteCount"])
                else { throw unavailable() }
                records.append((name, expression, extraPath, extraSHA, extraBytes))
            }
        }
        for entry in buildTools {
            guard Set(entry.keys) == [
                "name", "repository", "revision", "artifactURL", "artifactSHA256",
                "artifactByteCount", "licenseExpression", "licenseFile", "licenseSHA256",
                "licenseByteCount", "usage",
            ],
                let name = boundedString(entry["name"], maximumBytes: 128),
                let expression = boundedString(entry["licenseExpression"], maximumBytes: 256),
                let path = safeLicensePath(entry["licenseFile"]),
                let sha = shaValue(entry["licenseSHA256"]),
                let bytes = positiveInt(entry["licenseByteCount"])
            else { throw unavailable() }
            records.append((name, expression, path, sha, bytes))
        }
        guard records.count == licenseFileCount,
            Set(records.map(\.path)).count == records.count
        else { throw unavailable() }

        let expectedNames = Set(records.map {
            String($0.path.dropFirst("LICENSES/".count))
        })
        guard let directoryEntries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ), directoryEntries.count == expectedNames.count,
            Set(directoryEntries.map(\.lastPathComponent)) == expectedNames,
            directoryEntries.allSatisfy({ entry in
                guard entry.deletingLastPathComponent().resolvingSymlinksInPath()
                    .standardizedFileURL.path == root.path,
                    let values = try? entry.resourceValues(forKeys: [
                        .isRegularFileKey, .isSymbolicLinkKey,
                    ])
                else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
            })
        else { throw unavailable() }

        return try records.map { record in
            let fileName = String(record.path.dropFirst("LICENSES/".count))
            let candidate = root.appendingPathComponent(fileName, isDirectory: false)
                .standardizedFileURL
            guard candidate.deletingLastPathComponent().resolvingSymlinksInPath()
                    .standardizedFileURL.path == root.path,
                record.bytes <= 128 * 1_024
            else { throw unavailable() }
            let contents = try boundedResource(at: candidate, maximumBytes: 128 * 1_024)
            guard contents.count == record.bytes, sha256(contents) == record.sha
            else { throw unavailable() }
            return CLIVerifiedLicenseFile(
                owner: record.owner, licenseExpression: record.expression,
                resourcePath: record.path, sha256: record.sha,
                byteCount: record.bytes, data: contents
            )
        }.sorted {
            Data($0.resourcePath.utf8).lexicographicallyPrecedes(Data($1.resourcePath.utf8))
        }
    }

    private static func safeLicensePath(_ value: Any?) -> String? {
        guard let path = boundedString(value, maximumBytes: 256),
            path.hasPrefix("LICENSES/"), !path.contains(".."),
            !path.dropFirst("LICENSES/".count).contains("/"),
            path.utf8.dropFirst("LICENSES/".utf8.count).allSatisfy({ byte in
                (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                    || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                    || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                    || [UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "+"), UInt8(ascii: "-")].contains(byte)
            })
        else { return nil }
        return path
    }

    private static func boundedString(_ value: Any?, maximumBytes: Int) -> String? {
        guard let string = value as? String, !string.isEmpty,
            string.utf8.count <= maximumBytes
        else { return nil }
        return string
    }

    private static func shaValue(_ value: Any?) -> String? {
        guard let string = value as? String, string.utf8.count == 64,
            string.utf8.allSatisfy({
                ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                    || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f"))
            })
        else { return nil }
        return string
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let integer = number.intValue
        return integer > 0 && integer <= 128 * 1_024 ? integer : nil
    }

    private static func boundedResource(
        named name: String,
        extension fileExtension: String?,
        maximumBytes: Int
    ) throws -> Data {
        let url = try resourceURL(named: name, extension: fileExtension)
        return try boundedResource(at: url, maximumBytes: maximumBytes)
    }

    private static func resourceURL(
        named name: String,
        extension fileExtension: String?
    ) throws -> URL {
        let fileName = fileExtension.map { "\(name).\($0)" } ?? name
        guard !name.isEmpty, !name.contains("/"), fileExtension?.contains("/") != true else {
            throw unavailable()
        }
        return try CLIResourceLocator.productionRoot()
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private static func boundedResource(at url: URL, maximumBytes: Int) throws -> Data {
        do {
            return try ArkTraceBoundedRegularFile.read(
                at: url, maximumByteCount: maximumBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw unavailable()
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func unavailable() -> ArkTraceError {
        ArkTraceError(
            code: .internalError,
            stage: .encoding,
            message: "Bundled license resources are unavailable",
            details: ["reason": "licenseResourcesUnavailable"]
        )
    }
}
