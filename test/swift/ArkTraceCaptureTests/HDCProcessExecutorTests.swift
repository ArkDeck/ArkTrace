import Darwin
import Foundation
import Synchronization
import XCTest

@testable import ArkTraceCapture

final class HDCProcessExecutorTests: XCTestCase {
    func testLaunchFailureReturnsWithoutWaitingForUnownedPipeEOF() async throws {
        let workerKey = "ARKTRACE_TEST_HDC_LAUNCH_FAILURE"
        if ProcessInfo.processInfo.environment[workerKey] == "1" {
            do {
                _ = try await HDCProcessExecutor.run(
                    executableURL: FileManager.default.temporaryDirectory
                        .appending(path: "missing-hdc-\(UUID().uuidString)"),
                    arguments: ["list", "targets"]
                )
                XCTFail("a nonexistent executable must fail to launch")
            } catch {
                XCTAssertFalse(error is CancellationError)
            }
            return
        }

        // A blocked availableData cannot be cancelled by a task-group timeout.
        // Run this regression in a child that the parent can kill and reap.
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest", "-XCTest",
            "ArkTraceCaptureTests.HDCProcessExecutorTests/testLaunchFailureReturnsWithoutWaitingForUnownedPipeEOF",
            Bundle(for: Self.self).bundleURL.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment[workerKey] = "1"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let (exits, continuation) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { child in
            continuation.yield(child.terminationStatus)
            continuation.finish()
        }
        try process.run()
        defer {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        let timedOut = Mutex(false)
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(15)) }
            catch { return }
            if process.isRunning {
                timedOut.withLock { $0 = true }
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        defer { timeout.cancel() }

        // An async test may resume on a different cooperative-pool thread.
        // Foundation's synchronous waitUntilExit can strand that thread in
        // its run loop even after the child exits. The termination callback
        // supplies the reaped child's status without a thread-bound wait.
        let status = await exits.first(where: { _ in true })
        XCTAssertFalse(timedOut.withLock { $0 }, "launch failure left the HDC pipe drain blocked")
        XCTAssertEqual(status, 0)
    }

    func testDrainRetainsBytesAlreadyReadWhenCallbacksStop() throws {
        let readReached = DispatchSemaphore(value: 0)
        let releaseRead = DispatchSemaphore(value: 0)
        let sink = HDCBoundedPipeSink(readDidCompleteHook: {
            readReached.signal()
            XCTAssertEqual(releaseRead.wait(timeout: .now() + 5), .success)
        })
        defer { releaseRead.signal() }
        let payload = Data("device-1\n".utf8)
        try sink.pipe.fileHandleForWriting.write(contentsOf: payload)
        XCTAssertEqual(readReached.wait(timeout: .now() + 5), .success)
        try sink.pipe.fileHandleForWriting.close()

        // The callback holds the bytes outside the lock. Only release it once
        // finish has disabled new callbacks, forcing the old discard window.
        let result = sink.finishAndDrain(callbacksStoppedHook: { releaseRead.signal() })
        XCTAssertEqual(result.0, payload)
        XCTAssertFalse(result.1)
    }

    func testExecutorCollectsBothStreamsThroughChildExit() async throws {
        let result = try await HDCProcessExecutor.run(
            executableURL: URL(filePath: "/bin/sh"),
            arguments: ["-c", "printf 'device-1\\n'; printf 'version-1\\n' >&2"]
        )
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(result.stdout, Data("device-1\n".utf8))
        XCTAssertEqual(result.stderr, Data("version-1\n".utf8))
        XCTAssertFalse(result.outputWasTruncated)
    }
}
