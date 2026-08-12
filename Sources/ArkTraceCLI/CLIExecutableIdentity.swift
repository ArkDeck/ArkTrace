import ArkTraceCore
import CryptoKit
import Darwin
import Foundation
import MachO

struct CLIExecutableFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

/// Resolves the content identity of the Mach-O image that is actually mapped
/// into this process. The path is only used to acquire an fd; the mapped image
/// vnode and the opened fd must agree before any bytes are trusted.
struct CLIExecutableIdentityResolver: @unchecked Sendable {
    typealias MappedIdentityProvider = @Sendable () throws -> CLIExecutableFileIdentity
    typealias BoundFileHook = @Sendable () throws -> Void

    private let executableURL: URL
    private let mappedIdentity: MappedIdentityProvider
    private let boundFileHook: BoundFileHook?

    init(
        executableURL: URL,
        mappedIdentity: @escaping MappedIdentityProvider,
        boundFileHook: BoundFileHook? = nil
    ) {
        self.executableURL = executableURL
        self.mappedIdentity = mappedIdentity
        self.boundFileHook = boundFileHook
    }

    static func current() throws -> CLIExecutableIdentityResolver {
        let executable = try currentMappedExecutable()
        return CLIExecutableIdentityResolver(
            executableURL: executable.url,
            mappedIdentity: { executable.identity }
        )
    }

    func resolveBuildRevision() throws -> String {
        let expected = try mappedIdentity()
        let descriptor = executableURL.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw Self.identityFailure(reason: "executableOpenFailed")
        }
        defer { _ = close(descriptor) }

        let initial = try Self.snapshot(descriptor: descriptor)
        guard initial.identity == expected else {
            throw Self.identityFailure(reason: "executableIdentityMismatch")
        }
        let initialDigest = try Self.hashContents(
            descriptor: descriptor,
            expectedSize: initial.size
        )
        let bound = try Self.snapshot(descriptor: descriptor)
        guard initial == bound else {
            throw Self.identityFailure(reason: "executableChanged")
        }
        guard let boundFileHook else {
            return initialDigest
        }
        try boundFileHook()
        let finalDigest = try Self.hashContents(
            descriptor: descriptor,
            expectedSize: initial.size
        )
        let final = try Self.snapshot(descriptor: descriptor)
        guard initial.identity == final.identity,
            initial.size == final.size,
            initial.modificationSeconds == final.modificationSeconds,
            initial.modificationNanoseconds == final.modificationNanoseconds,
            initialDigest == finalDigest
        else {
            throw Self.identityFailure(reason: "executableChanged")
        }
        return finalDigest
    }

    private static func hashContents(
        descriptor: Int32,
        expectedSize: off_t
    ) throws -> String {
        var hasher = SHA256()
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 1 * 1_024 * 1_024)
        while true {
            if Task.isCancelled { throw CancellationError() }
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                pread(descriptor, rawBuffer.baseAddress, rawBuffer.count, offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.identityFailure(reason: "executableReadFailed")
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
            offset += off_t(count)
            guard offset <= expectedSize else {
                throw Self.identityFailure(reason: "executableChanged")
            }
        }
        guard offset == expectedSize else {
            throw Self.identityFailure(reason: "executableChanged")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct FileSnapshot: Equatable {
        let identity: CLIExecutableFileIdentity
        let size: off_t
        let modificationSeconds: Int
        let modificationNanoseconds: Int
        let statusChangeSeconds: Int
        let statusChangeNanoseconds: Int
    }

    private static func snapshot(descriptor: Int32) throws -> FileSnapshot {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_size >= 0
        else {
            throw identityFailure(reason: "executableStatFailed")
        }
        return FileSnapshot(
            identity: CLIExecutableFileIdentity(
                device: UInt64(status.st_dev),
                inode: UInt64(status.st_ino)
            ),
            size: status.st_size,
            modificationSeconds: status.st_mtimespec.tv_sec,
            modificationNanoseconds: status.st_mtimespec.tv_nsec,
            statusChangeSeconds: status.st_ctimespec.tv_sec,
            statusChangeNanoseconds: status.st_ctimespec.tv_nsec
        )
    }

    private struct MappedExecutable: Sendable {
        let url: URL
        let identity: CLIExecutableFileIdentity
    }

    private static func currentMappedExecutable() throws -> MappedExecutable {
        guard let header = _dyld_get_image_header(0) else {
            throw identityFailure(reason: "mappedExecutableUnavailable")
        }
        var info = proc_regionwithpathinfo()
        let byteCount = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(
                getpid(),
                PROC_PIDREGIONPATHINFO,
                UInt64(UInt(bitPattern: UnsafeRawPointer(header))),
                $0,
                Int32(MemoryLayout<proc_regionwithpathinfo>.size)
            )
        }
        guard byteCount == MemoryLayout<proc_regionwithpathinfo>.size else {
            throw identityFailure(reason: "mappedExecutableProbeFailed")
        }
        let status = info.prp_vip.vip_vi.vi_stat
        guard (status.vst_mode & UInt16(S_IFMT)) == UInt16(S_IFREG),
            status.vst_ino != 0
        else {
            throw identityFailure(reason: "mappedExecutableInvalid")
        }
        let path = withUnsafePointer(to: &info.prp_vip.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw identityFailure(reason: "mappedExecutablePathInvalid")
        }
        return MappedExecutable(
            url: URL(fileURLWithPath: path, isDirectory: false),
            identity: CLIExecutableFileIdentity(
                device: UInt64(status.vst_dev),
                inode: status.vst_ino
            )
        )
    }

    private static func identityFailure(reason: String) -> ArkTraceError {
        ArkTraceError(
            code: .internalError,
            stage: .encoding,
            message: "Executable build identity is unavailable",
            details: ["reason": reason]
        )
    }
}
