import ArkTraceCore
import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import ArkTraceRuntime

final class TraceCacheIOTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-cache-io-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testInterruptedShortWritesPreserveEveryByte() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "written")
        let descriptor = Darwin.open(destination.path, O_CREAT | O_WRONLY | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { _ = Darwin.close(descriptor) }
        let payload = Data("0123456789abcdef".utf8)
        var calls = 0
        try TraceContentAddressedCache.writeAll(payload, descriptor: descriptor) { fd, bytes, count in
            calls += 1
            if calls == 2 { errno = EINTR; return -1 }
            return Darwin.write(fd, bytes, min(3, count))
        }
        XCTAssertGreaterThan(calls, 2)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    func testZeroAndNonInterruptedWriteFailuresAreNotRetried() {
        for result in [0, -1] {
            var calls = 0
            XCTAssertThrowsError(try TraceContentAddressedCache.writeAll(
                Data("x".utf8), descriptor: -1,
                write: { _, _, _ in calls += 1; errno = EIO; return result }
            ))
            XCTAssertEqual(calls, 1)
        }
    }

    func testInterruptedSourceReadsKeepSnapshotHashAndByteCount() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "input")
        let payload = Data("a source copied in short reads".utf8)
        try payload.write(to: source)
        var calls = 0
        let snapshot = try TraceContentAddressedCache.scanSource(
            source: source, snapshotDirectory: root,
            read: { fd, buffer, count in
                calls += 1
                if calls == 2 { errno = EINTR; return -1 }
                return Darwin.read(fd, buffer, min(5, count))
            }
        )
        XCTAssertGreaterThan(calls, 2)
        XCTAssertEqual(try Data(contentsOf: snapshot.url), payload)
        XCTAssertEqual(snapshot.byteCount, Int64(payload.count))
        XCTAssertEqual(snapshot.sha256, SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
    }

    func testRealReadFailureRemovesPartialSnapshotAndStaysTyped() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "input")
        try Data("source".utf8).write(to: source)
        var calls = 0
        XCTAssertThrowsError(try TraceContentAddressedCache.scanSource(
            source: source, snapshotDirectory: root,
            read: { _, _, _ in calls += 1; errno = EIO; return -1 }
        )) { error in
            XCTAssertEqual((error as? ArkTraceError)?.code, .traceFileUnreadable)
            XCTAssertEqual((error as? ArkTraceError)?.stage, .hashing)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "source.snapshot").path))
    }

    func testCancellationIsCheckedBeforeRetryingInterruptedSourceRead() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "input")
        try Data("source".utf8).write(to: source)
        let task = Task.detached {
            try TraceContentAddressedCache.scanSource(
                source: source, snapshotDirectory: root,
                read: { _, _, _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    errno = EINTR
                    return -1
                }
            )
        }
        do {
            _ = try await task.value
            XCTFail("cancelled scan must not return a snapshot")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "source.snapshot").path))
    }

    func testDirectorySyncRejectsFilesAndSymlinks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "file")
        let link = root.appending(path: "link")
        try Data("file".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertNoThrow(try TraceContentAddressedCache.synchronizeDirectory(at: root))
        XCTAssertThrowsError(try TraceContentAddressedCache.synchronizeDirectory(at: file))
        XCTAssertThrowsError(try TraceContentAddressedCache.synchronizeDirectory(at: link))
    }
}
