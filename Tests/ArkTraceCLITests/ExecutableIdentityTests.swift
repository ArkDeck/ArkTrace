@testable import ArkTraceCLI
import ArkTraceCore
import CryptoKit
import Darwin
import Foundation
import MachO
import XCTest

final class ExecutableIdentityTests: XCTestCase {
    func testCurrentResolverHashesTheMappedExecutableBytes() throws {
        let revision = try CLIExecutableIdentityResolver.current().resolveBuildRevision()
        let imageName = try XCTUnwrap(_dyld_get_image_name(0))
        let executableURL = URL(fileURLWithPath: String(cString: imageName))
        let expected = SHA256.hash(data: try Data(contentsOf: executableURL))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(revision, expected)
    }

    func testBoundDescriptorSurvivesPathReplacementDuringHash() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("tool", isDirectory: false)
        let displaced = directory.appendingPathComponent("running", isDirectory: false)
        let original = Data("original executable bytes".utf8)
        let replacement = Data("replacement executable bytes".utf8)
        try original.write(to: executable, options: .withoutOverwriting)
        let identity = try fileIdentity(executable)

        let resolver = CLIExecutableIdentityResolver(
            executableURL: executable,
            mappedIdentity: { identity },
            boundFileHook: {
                try FileManager.default.moveItem(at: executable, to: displaced)
                try replacement.write(to: executable, options: .withoutOverwriting)
            }
        )
        let revision = try resolver.resolveBuildRevision()
        let expected = SHA256.hash(data: original)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(revision, expected)
        XCTAssertNotEqual(revision, SHA256.hash(data: replacement)
            .map { String(format: "%02x", $0) }.joined())
    }

    func testResolverRejectsPathThatIsNotTheMappedExecutable() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("tool", isDirectory: false)
        try Data("replacement".utf8).write(to: executable, options: .withoutOverwriting)
        let actual = try fileIdentity(executable)
        let different = CLIExecutableFileIdentity(
            device: actual.device,
            inode: actual.inode &+ 1
        )
        XCTAssertThrowsError(try CLIExecutableIdentityResolver(
            executableURL: executable,
            mappedIdentity: { different }
        ).resolveBuildRevision()) { error in
            let typed = error as? ArkTraceError
            XCTAssertEqual(typed?.code, .internalError)
            XCTAssertEqual(typed?.stage, .encoding)
            XCTAssertEqual(typed?.details["reason"], "executableIdentityMismatch")
            XCTAssertFalse(typed?.details.values.joined().contains(directory.path) ?? true)
        }
    }

    func testResolverRejectsInPlaceMutationAfterDescriptorBinding() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("tool", isDirectory: false)
        try Data("mapped executable".utf8).write(to: executable, options: .withoutOverwriting)
        let identity = try fileIdentity(executable)
        let resolver = CLIExecutableIdentityResolver(
            executableURL: executable,
            mappedIdentity: { identity },
            boundFileHook: {
                let handle = try FileHandle(forWritingTo: executable)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(" changed".utf8))
            }
        )
        XCTAssertThrowsError(try resolver.resolveBuildRevision()) { error in
            let typed = error as? ArkTraceError
            XCTAssertEqual(typed?.code, .internalError)
            XCTAssertEqual(typed?.details["reason"], "executableChanged")
        }
    }

    func testResolverRejectsEqualLengthInPlaceMutationWithRestoredModificationTime() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("tool", isDirectory: false)
        let original = Data("mapped executable bytes".utf8)
        let replacement = Data("forged executable bytes".utf8)
        XCTAssertEqual(original.count, replacement.count)
        try original.write(to: executable, options: .withoutOverwriting)
        let identity = try fileIdentity(executable)

        var originalStatus = stat()
        XCTAssertEqual(lstat(executable.path, &originalStatus), 0)
        let originalAccessSeconds = originalStatus.st_atimespec.tv_sec
        let originalAccessNanoseconds = originalStatus.st_atimespec.tv_nsec
        let originalModificationSeconds = originalStatus.st_mtimespec.tv_sec
        let originalModificationNanoseconds = originalStatus.st_mtimespec.tv_nsec
        let resolver = CLIExecutableIdentityResolver(
            executableURL: executable,
            mappedIdentity: { identity },
            boundFileHook: {
                let descriptor = executable.path.withCString {
                    open($0, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
                defer { _ = close(descriptor) }

                let written = replacement.withUnsafeBytes { bytes in
                    pwrite(descriptor, bytes.baseAddress, bytes.count, 0)
                }
                guard written == replacement.count, fsync(descriptor) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
                var timestamps = [
                    timespec(
                        tv_sec: originalAccessSeconds,
                        tv_nsec: originalAccessNanoseconds
                    ),
                    timespec(
                        tv_sec: originalModificationSeconds,
                        tv_nsec: originalModificationNanoseconds
                    ),
                ]
                guard timestamps.withUnsafeMutableBufferPointer({ buffer in
                    futimens(descriptor, buffer.baseAddress)
                }) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        )

        XCTAssertThrowsError(try resolver.resolveBuildRevision()) { error in
            let typed = error as? ArkTraceError
            XCTAssertEqual(typed?.code, .internalError)
            XCTAssertEqual(typed?.stage, .encoding)
            XCTAssertEqual(typed?.details["reason"], "executableChanged")
        }
        var finalStatus = stat()
        XCTAssertEqual(lstat(executable.path, &finalStatus), 0)
        XCTAssertEqual(finalStatus.st_size, originalStatus.st_size)
        XCTAssertEqual(finalStatus.st_mtimespec.tv_sec, originalStatus.st_mtimespec.tv_sec)
        XCTAssertEqual(finalStatus.st_mtimespec.tv_nsec, originalStatus.st_mtimespec.tv_nsec)
        XCTAssertTrue(
            finalStatus.st_ctimespec.tv_sec != originalStatus.st_ctimespec.tv_sec
                || finalStatus.st_ctimespec.tv_nsec != originalStatus.st_ctimespec.tv_nsec
        )
    }

    func testResolverFailsTypedWhenExecutableCannotBeRead() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("tool", isDirectory: false)
        try Data("execute only".utf8).write(to: executable, options: .withoutOverwriting)
        let identity = try fileIdentity(executable)
        XCTAssertEqual(chmod(executable.path, 0o111), 0)
        defer { _ = chmod(executable.path, 0o600) }

        XCTAssertThrowsError(try CLIExecutableIdentityResolver(
            executableURL: executable,
            mappedIdentity: { identity }
        ).resolveBuildRevision()) { error in
            let typed = error as? ArkTraceError
            XCTAssertEqual(typed?.code, .internalError)
            XCTAssertEqual(typed?.stage, .encoding)
            XCTAssertEqual(typed?.details["reason"], "executableOpenFailed")
        }
    }

    func testMachineApplicationFailsClosedWhenToolIdentityIsUnavailable() async {
        let writer = ExecutableIdentityWriter()
        let application = CLIApplication(machineToolProvider: {
            throw ArkTraceError(
                code: .internalError,
                stage: .encoding,
                message: "identity unavailable",
                details: ["reason": "executableOpenFailed"]
            )
        })
        let status = await application.run(
            arguments: ["--json", "--version"],
            writer: writer
        )
        XCTAssertEqual(status, 9)
        let output = writer.snapshot()
        XCTAssertTrue(output.stdout.isEmpty)
        XCTAssertTrue(String(decoding: output.stderr, as: UTF8.self).contains("INTERNAL_ERROR"))
        XCTAssertFalse(String(decoding: output.stderr, as: UTF8.self).contains("/"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cli-executable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func fileIdentity(_ url: URL) throws -> CLIExecutableFileIdentity {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return CLIExecutableFileIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
    }
}

private final class ExecutableIdentityWriter: CLIOutputWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func writeStdout(_ data: Data) { lock.withLock { stdout.append(data) } }
    func writeStderr(_ data: Data) { lock.withLock { stderr.append(data) } }

    func snapshot() -> (stdout: Data, stderr: Data) {
        lock.withLock { (stdout, stderr) }
    }
}
