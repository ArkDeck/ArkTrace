import Foundation
import Synchronization
import XCTest

@testable import ArkTraceCapture

final class TraceCaptureConfigurationTests: XCTestCase {
    func testProfilesProduceBoundedOfficialHiprofilerConfiguration() throws {
        let destination = URL(filePath: "/tmp/result.htrace")
        let request = try TraceCaptureRequest(
            deviceID: "device-1",
            profile: .systemOverview,
            durationSeconds: 30,
            bufferSizeMB: 64,
            destinationURL: destination
        )
        let text = TraceCaptureConfigurationBuilder.text(
            for: request,
            remoteTracePath: "/data/local/tmp/result.htrace"
        )

        XCTAssertTrue(text.contains("pages: 16384"))
        XCTAssertTrue(text.contains("sample_duration: 30000"))
        XCTAssertTrue(text.contains("buffer_size_kb: 65536"))
        XCTAssertTrue(text.contains("ftrace_events: \"sched/sched_switch\""))
        XCTAssertTrue(text.contains("ftrace_events: \"power/cpu_frequency\""))
        XCTAssertTrue(text.contains("hitrace_categories: \"ace\""))
        XCTAssertTrue(text.contains("hitrace_categories: \"window\""))
        XCTAssertFalse(text.contains("result_file: \"\(destination.path)\""))
    }

    func testRequestRejectsUnboundedSettings() throws {
        XCTAssertThrowsError(
            try TraceCaptureRequest(
                deviceID: "device-1",
                profile: .cpuScheduling,
                durationSeconds: 301,
                bufferSizeMB: 64,
                destinationURL: URL(filePath: "/tmp/result.htrace")
            )
        ) { error in
            XCTAssertEqual((error as? TraceCaptureIssue)?.code, .invalidConfiguration)
        }
        XCTAssertThrowsError(
            try TraceCaptureRequest(
                deviceID: "",
                profile: .cpuScheduling,
                durationSeconds: 15,
                bufferSizeMB: 64,
                destinationURL: URL(filePath: "/tmp/result.htrace")
            )
        )
    }

    func testDeviceParserIsBoundedToUniqueTargetKeys() {
        let devices = HDCTraceCaptureClient.parseDevices(
            """
            [Empty]
            usb-device
            192.168.1.4:8710 connected
            usb-device
            """
        )
        XCTAssertEqual(devices.map(\.id), ["usb-device", "192.168.1.4:8710"])
        XCTAssertEqual(devices.map(\.transport), [.usb, .network])
    }

    func testLocatorPrefersPersistedThenConfiguredThenPathCandidates() {
        let candidates = HDCExecutableLocator.candidates(
            persistedPath: "/chosen/hdc",
            environment: [
                "HDC_PATH": "/sdk/toolchains",
                "PATH": "/first/bin:/second/bin",
            ]
        )
        XCTAssertEqual(candidates[0].path, "/chosen/hdc")
        XCTAssertEqual(candidates[1].path, "/sdk/toolchains/hdc")
        XCTAssertEqual(candidates[2].path, "/first/bin/hdc")
        XCTAssertEqual(candidates[3].path, "/second/bin/hdc")
    }
}

final class HDCTraceCaptureClientTests: XCTestCase {
    private actor Recorder {
        private(set) var invocations: [[String]] = []
        private(set) var configuration: String?

        func run(_ arguments: [String]) throws -> HDCProcessOutcome {
            invocations.append(arguments)
            if arguments.contains("send"), let localIndex = arguments.firstIndex(of: "send") {
                let localURL = URL(filePath: arguments[localIndex + 1])
                configuration = try String(contentsOf: localURL, encoding: .utf8)
            }
            if arguments.contains("recv"), let localPath = arguments.last {
                try Data([0x48, 0x54, 0x52, 0x41, 0x43, 0x45]).write(
                    to: URL(filePath: localPath)
                )
            }
            return HDCProcessOutcome(
                exitStatus: 0,
                stdout: Data("success".utf8),
                stderr: Data(),
                outputWasTruncated: false
            )
        }

        func values() -> ([[String]], String?) { (invocations, configuration) }
    }

    func testCaptureUsesArgumentArraysTransfersThenAtomicallyPromotes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-capture-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "capture.htrace")
        let request = try TraceCaptureRequest(
            deviceID: "device-key",
            profile: .appResponsiveness,
            durationSeconds: 15,
            bufferSizeMB: 32,
            destinationURL: destination
        )
        let recorder = Recorder()
        let client = HDCTraceCaptureClient { _, arguments in
            try await recorder.run(arguments)
        }
        let stages = Mutex<[TraceCaptureStage]>([])
        let result = try await client.capture(
            executableURL: URL(filePath: "/sdk/hdc"),
            request: request,
            progress: { stage in
                stages.withLock { $0.append(stage) }
            }
        )

        XCTAssertEqual(result, destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("HTRACE".utf8))
        let (invocations, configuration) = await recorder.values()
        XCTAssertEqual(invocations.count, 5)
        XCTAssertEqual(Array(invocations[0].prefix(4)), ["-t", "device-key", "file", "send"])
        XCTAssertEqual(Array(invocations[1].prefix(4)), ["-t", "device-key", "shell", "hiprofiler_cmd"])
        XCTAssertEqual(Array(invocations[2].prefix(4)), ["-t", "device-key", "file", "recv"])
        XCTAssertEqual(
            Array(invocations[3].prefix(5)),
            ["-t", "device-key", "shell", "hiprofiler_cmd", "-k"]
        )
        XCTAssertEqual(Array(invocations[4].prefix(5)), ["-t", "device-key", "shell", "rm", "-f"])
        XCTAssertFalse(invocations.flatMap { $0 }.contains("sh"))
        XCTAssertTrue(configuration?.contains("sample_duration: 15000") == true)
        let observedStages = stages.withLock { $0 }
        XCTAssertEqual(observedStages, [.preparing, .recording, .transferring])
    }

    func testCancellationDuringRemoteCleanupNeverPromotesThePartial() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-capture-cancel-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "cancelled.htrace")
        let request = try TraceCaptureRequest(
            deviceID: "device-key",
            profile: .appResponsiveness,
            durationSeconds: 15,
            bufferSizeMB: 32,
            destinationURL: destination
        )
        let cleanupStarted = Mutex(false)
        let client = HDCTraceCaptureClient { _, arguments in
            if arguments.contains("recv"), let localPath = arguments.last {
                try Data("HTRACE".utf8).write(to: URL(filePath: localPath))
            }
            if arguments.suffix(2) == ["hiprofiler_cmd", "-k"] {
                cleanupStarted.withLock { $0 = true }
                try await Task.sleep(for: .milliseconds(200))
            }
            return HDCProcessOutcome(
                exitStatus: 0,
                stdout: Data("success".utf8),
                stderr: Data(),
                outputWasTruncated: false
            )
        }
        let task = Task {
            try await client.capture(
                executableURL: URL(filePath: "/sdk/hdc"),
                request: request,
                progress: { _ in }
            )
        }

        while !cleanupStarted.withLock({ $0 }) { await Task.yield() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled capture must not publish its destination")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
            "the private partial must be removed after cancellation"
        )
    }
}

@MainActor
final class TraceCaptureControllerTests: XCTestCase {
    func testDiscoverySelectsOnlyDeviceAndCompletedCaptureCallsBack() async throws {
        let destination = URL(filePath: "/tmp/controller-capture.htrace")
        let controller = TraceCaptureController(
            executableURL: URL(filePath: "/sdk/hdc"),
            discover: { _ in [TraceCaptureDevice(id: "one-device")] },
            capture: { _, request, progress in
                progress(.preparing)
                progress(.recording)
                progress(.transferring)
                return request.destinationURL
            }
        )

        controller.refreshDevices()
        while controller.phase == .discovering { await Task.yield() }
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.selectedDeviceID, "one-device")
        XCTAssertTrue(controller.canStart)

        var completed: URL?
        controller.startCapture(to: destination) { completed = $0 }
        while controller.phase.isBusy { await Task.yield() }
        XCTAssertEqual(controller.phase, .completed)
        XCTAssertEqual(controller.completedURL, destination)
        XCTAssertEqual(completed, destination)
    }

    func testCancellationBecomesStableCancelledState() async throws {
        let controller = TraceCaptureController(
            executableURL: URL(filePath: "/sdk/hdc"),
            discover: { _ in [TraceCaptureDevice(id: "one-device")] },
            capture: { _, _, progress in
                progress(.recording)
                try await Task.sleep(for: .seconds(30))
                return URL(filePath: "/tmp/never.htrace")
            }
        )
        controller.refreshDevices()
        while controller.phase == .discovering { await Task.yield() }
        controller.startCapture(to: URL(filePath: "/tmp/cancelled.htrace")) { _ in
            XCTFail("a cancelled capture must not complete")
        }
        while controller.phase != .recording { await Task.yield() }
        controller.cancelCapture()
        while controller.phase == .cancelling { await Task.yield() }
        XCTAssertEqual(controller.phase, .cancelled)
    }
}
