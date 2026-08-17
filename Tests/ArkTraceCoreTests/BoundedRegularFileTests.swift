import Darwin
import Foundation
import XCTest

@testable import ArkTraceCore

final class BoundedRegularFileTests: XCTestCase {
    func testDescriptorSnapshotRejectsPathReplacementWithoutReadingReplacement() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-bounded-file-\(UUID().uuidString)")
        let file = root.appending(path: "resource")
        let displaced = root.appending(path: "opened")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("reviewed bytes".utf8)
        let replacement = Data("foreign bytes".utf8)
        try original.write(to: file)

        XCTAssertThrowsError(try ArkTraceBoundedRegularFile.read(
            at: file,
            maximumByteCount: 1_024,
            afterOpen: {
                try FileManager.default.moveItem(at: file, to: displaced)
                try replacement.write(to: file)
            }
        ))
        XCTAssertEqual(try Data(contentsOf: displaced), original)
        XCTAssertEqual(try Data(contentsOf: file), replacement)
    }

    func testDescriptorSnapshotRejectsGrowthAfterOpen() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-bounded-growth-\(UUID().uuidString)")
        let file = root.appending(path: "resource")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("small".utf8).write(to: file)

        XCTAssertThrowsError(try ArkTraceBoundedRegularFile.read(
            at: file,
            maximumByteCount: 1_024,
            afterOpen: {
                let descriptor = file.path.withCString {
                    Darwin.open($0, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
                }
                XCTAssertGreaterThanOrEqual(descriptor, 0)
                defer { if descriptor >= 0 { _ = Darwin.close(descriptor) } }
                let extra = [UInt8](repeating: 0x41, count: 32)
                let written = extra.withUnsafeBytes {
                    Darwin.write(descriptor, $0.baseAddress, $0.count)
                }
                XCTAssertEqual(written, extra.count)
            }
        ))
    }

    func testDescriptorSnapshotRejectsFinalSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-bounded-symlink-\(UUID().uuidString)")
        let target = root.appending(path: "target")
        let link = root.appending(path: "resource")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("bytes".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try ArkTraceBoundedRegularFile.read(
            at: link, maximumByteCount: 1_024
        ))
    }

    func testMaximumIntLimitDoesNotOverflowBeforeReading() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-bounded-intmax-\(UUID().uuidString)")
        let file = root.appending(path: "resource")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = Data("bounded".utf8)
        try expected.write(to: file)
        XCTAssertEqual(
            try ArkTraceBoundedRegularFile.read(at: file, maximumByteCount: .max),
            expected
        )
    }
}
