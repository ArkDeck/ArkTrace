import Darwin
import Foundation

/// Reads one immutable, regular-file snapshot through a no-follow descriptor.
///
/// The size check and the bytes come from the same opened object. The reader
/// never trusts path metadata followed by a second path-based open, and it
/// checks task cancellation between bounded chunks.
public enum ArkTraceBoundedRegularFile {
    public static func read(
        at url: URL,
        maximumByteCount: Int
    ) throws -> Data {
        try read(at: url, maximumByteCount: maximumByteCount, afterOpen: nil)
    }

    static func read(
        at url: URL,
        maximumByteCount: Int,
        afterOpen: (() throws -> Void)?
    ) throws -> Data {
        guard maximumByteCount > 0 else { throw BoundedFileError.invalidLimit }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw BoundedFileError.openFailed }
        defer { _ = Darwin.close(descriptor) }

        let initial = try snapshot(descriptor)
        guard initial.byteCount > 0, initial.byteCount <= UInt64(maximumByteCount)
        else { throw BoundedFileError.invalidSize }
        try afterOpen?()

        var result = Data()
        result.reserveCapacity(Int(initial.byteCount))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumByteCount))
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw BoundedFileError.readFailed
            }
            guard result.count <= maximumByteCount - count else {
                throw BoundedFileError.invalidSize
            }
            result.append(buffer, count: count)
        }
        try Task.checkCancellation()
        let final = try snapshot(descriptor)
        guard final == initial, result.count == Int(initial.byteCount)
        else { throw BoundedFileError.changedDuringRead }
        return result
    }

    private struct Snapshot: Equatable {
        let device: UInt64
        let inode: UInt64
        let byteCount: UInt64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
    }

    private static func snapshot(_ descriptor: Int32) throws -> Snapshot {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_size > 0
        else { throw BoundedFileError.notRegular }
        return Snapshot(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            byteCount: UInt64(status.st_size),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            changeSeconds: Int64(status.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(status.st_ctimespec.tv_nsec)
        )
    }

    private enum BoundedFileError: Error {
        case invalidLimit
        case openFailed
        case notRegular
        case invalidSize
        case readFailed
        case changedDuringRead
    }
}
