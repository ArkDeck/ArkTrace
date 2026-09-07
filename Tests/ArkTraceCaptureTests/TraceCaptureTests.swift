import Foundation
import Observation
import Synchronization
import XCTest

@testable import ArkTraceCapture

final class TraceCaptureConfigurationTests: XCTestCase {
    /// The bounds are shared by every profile, but the event and category sets
    /// are the *only* thing a profile selects -- so each one is pinned here.
    /// Driving the whole of `allCases` is deliberate: a new profile that
    /// nobody mapped fails this test instead of silently shipping empty.
    func testEveryProfileProducesItsOwnBoundedHiprofilerConfiguration() throws {
        let expected: [TraceCaptureProfile: (categories: [String], cpuPower: Bool)] = [
            .appResponsiveness: (
                ["ability", "ace", "binder", "graphic", "ohos", "rpc", "sched", "sync", "window"],
                false
            ),
            .cpuScheduling: (["freq", "idle", "sched"], true),
            .systemOverview: (
                [
                    "ability", "ace", "binder", "dsoftbus", "freq", "graphic", "idle",
                    "memory", "ohos", "rpc", "sched", "sync", "window",
                ],
                true
            ),
        ]
        XCTAssertEqual(
            Set(expected.keys), Set(TraceCaptureProfile.allCases),
            "a new capture profile has to pin its own event and category mapping"
        )

        let destination = URL(filePath: "/tmp/result.htrace")
        for profile in TraceCaptureProfile.allCases {
            let mapping = try XCTUnwrap(expected[profile])
            let request = try TraceCaptureRequest(
                deviceID: "device-1",
                profile: profile,
                durationSeconds: 30,
                bufferSizeMB: 64,
                destinationURL: destination
            )
            let text = TraceCaptureConfigurationBuilder.text(
                for: request,
                remoteTracePath: "/data/local/tmp/result.htrace"
            )

            // Bounds: identical for every profile.
            XCTAssertTrue(text.contains("pages: 16384"), "\(profile)")
            XCTAssertTrue(text.contains("sample_duration: 30000"), "\(profile)")
            XCTAssertTrue(text.contains("buffer_size_kb: 65536"), "\(profile)")
            XCTAssertFalse(
                text.contains("result_file: \"\(destination.path)\""),
                "\(profile): the host path must never reach the device config"
            )

            // The mapping the profile actually selects.
            func values(_ key: String) -> [String] {
                text.split(separator: "\n").compactMap { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("\(key): \"") else { return nil }
                    return String(trimmed.dropFirst(key.utf8.count + 3).dropLast())
                }
            }
            XCTAssertEqual(values("hitrace_categories"), mapping.categories, "\(profile)")
            XCTAssertTrue(
                values("ftrace_events").contains("sched/sched_switch"),
                "\(profile): scheduling events are common to every profile"
            )
            XCTAssertEqual(
                values("ftrace_events").contains("power/cpu_frequency"), mapping.cpuPower,
                "\(profile): only the CPU-power profiles carry the frequency probe"
            )
        }
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

    func testDurationUnitsExposeBoundedInputAndRequestedQuickValues() {
        XCTAssertEqual(TraceCaptureDurationUnit.seconds.inputRange, 5...300)
        XCTAssertEqual(TraceCaptureDurationUnit.seconds.quickValues, [5, 10, 15, 30])
        XCTAssertEqual(TraceCaptureDurationUnit.minutes.inputRange, 1...5)
        XCTAssertEqual(TraceCaptureDurationUnit.minutes.quickValues, [1, 2, 3])

        XCTAssertEqual(TraceCaptureDurationUnit.seconds.durationSeconds(for: 45), 45)
        XCTAssertEqual(TraceCaptureDurationUnit.minutes.durationSeconds(for: 3), 180)
        XCTAssertNil(TraceCaptureDurationUnit.seconds.durationSeconds(for: 4))
        XCTAssertNil(TraceCaptureDurationUnit.minutes.durationSeconds(for: 6))
        XCTAssertNil(TraceCaptureDurationUnit.minutes.durationSeconds(for: .max))
    }

    func testSwitchingToMinutesRoundsUpInsteadOfShorteningTheCapture() {
        XCTAssertEqual(
            TraceCaptureDurationUnit.minutes.inputValue(forDurationSeconds: 15),
            1
        )
        XCTAssertEqual(
            TraceCaptureDurationUnit.minutes.inputValue(forDurationSeconds: 61),
            2
        )
        XCTAssertEqual(
            TraceCaptureDurationUnit.minutes.inputValue(forDurationSeconds: 300),
            5
        )
        XCTAssertEqual(
            TraceCaptureDurationUnit.seconds.inputValue(forDurationSeconds: 180),
            180
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

    func testDevicePropertyParserRejectsFailureAndPlaceholderValues() {
        XCTAssertEqual(
            HDCTraceCaptureClient.parseDeviceProperty("HUAWEI Mate 80 Pro \n"),
            "HUAWEI Mate 80 Pro"
        )
        XCTAssertEqual(
            HDCTraceCaptureClient.parseDeviceProperty("\"OpenHarmony-7.0.0.39\"\n"),
            "OpenHarmony-7.0.0.39"
        )
        XCTAssertNil(HDCTraceCaptureClient.parseDeviceProperty("default\n"))
        XCTAssertNil(
            HDCTraceCaptureClient.parseDeviceProperty(
                "Get parameter \"const.product.name\" fail! errNum is:106!\n"
            )
        )
        XCTAssertNil(HDCTraceCaptureClient.parseDeviceProperty("value\nwith-control\n"))
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

    func testVersionParserAcceptsOnlyBoundedExplicitVersionTokens() {
        XCTAssertEqual(HDCTraceCaptureClient.parseVersion("Ver: 3.2.0f\n"), "3.2.0f")
        XCTAssertEqual(HDCTraceCaptureClient.parseVersion("HDC version v1.3.0f"), "1.3.0f")
        XCTAssertEqual(HDCTraceCaptureClient.parseVersion("v2.0.0-beta+1"), "2.0.0-beta+1")
        XCTAssertNil(HDCTraceCaptureClient.parseVersion("server at 127.0.0.1"))
        XCTAssertNil(HDCTraceCaptureClient.parseVersion("Ver: not-a-version"))
        XCTAssertNil(HDCTraceCaptureClient.parseVersion("Ver: \(String(repeating: "1", count: 40)).0"))
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

    func testVersionUsesVersionArgumentAndParsesStandardError() async {
        let invocations = Mutex<[[String]]>([])
        let client = HDCTraceCaptureClient { _, arguments in
            invocations.withLock { $0.append(arguments) }
            return HDCProcessOutcome(
                exitStatus: 0,
                stdout: Data(),
                stderr: Data("Ver: 3.2.0f\n".utf8),
                outputWasTruncated: false
            )
        }

        let version = await client.version(executableURL: URL(filePath: "/sdk/hdc"))

        XCTAssertEqual(version, "3.2.0f")
        XCTAssertEqual(invocations.withLock { $0 }, [["-v"]])
    }

    func testDiscoveryEnrichesEveryDeviceWithoutChangingItsSelectionKey() async throws {
        let invocations = Mutex<[[String]]>([])
        let client = HDCTraceCaptureClient { _, arguments in
            invocations.withLock { $0.append(arguments) }
            let output: String
            switch arguments {
            case ["list", "targets"]:
                output = "150100424a544434520325874bbf4900\n5SM0125725000252\n"
            case ["-t", "150100424a544434520325874bbf4900", "shell", "param", "get", "const.product.name"]:
                output = "OpenHarmony 3.2\n"
            case ["-t", "150100424a544434520325874bbf4900", "shell", "param", "get", "const.ohos.fullname"]:
                output = "OpenHarmony-7.0.0.37\n"
            case ["-t", "5SM0125725000252", "shell", "param", "get", "const.product.name"]:
                output = "HUAWEI Mate 80 Pro\n"
            case ["-t", "5SM0125725000252", "shell", "param", "get", "const.ohos.fullname"]:
                output = "OpenHarmony-7.0.0.39\n"
            default:
                XCTFail("unexpected HDC invocation: \(arguments)")
                output = ""
            }
            return HDCProcessOutcome(
                exitStatus: 0,
                stdout: Data(output.utf8),
                stderr: Data(),
                outputWasTruncated: false
            )
        }

        let devices = try await client.discoverDevices(
            executableURL: URL(filePath: "/sdk/hdc")
        )

        XCTAssertEqual(
            devices,
            [
                TraceCaptureDevice(
                    id: "150100424a544434520325874bbf4900",
                    name: "OpenHarmony 3.2",
                    systemVersion: "OpenHarmony-7.0.0.37"
                ),
                TraceCaptureDevice(
                    id: "5SM0125725000252",
                    name: "HUAWEI Mate 80 Pro",
                    systemVersion: "OpenHarmony-7.0.0.39"
                ),
            ]
        )
        let observed = invocations.withLock { $0 }
        XCTAssertEqual(observed.count, 5)
        XCTAssertEqual(observed.first, ["list", "targets"])
    }

    func testDiscoveryKeepsDeviceWhenMetadataIsUnavailable() async throws {
        let client = HDCTraceCaptureClient { _, arguments in
            if arguments == ["list", "targets"] {
                return HDCProcessOutcome(
                    exitStatus: 0,
                    stdout: Data("device-key\n".utf8),
                    stderr: Data(),
                    outputWasTruncated: false
                )
            }
            throw URLError(.cannotConnectToHost)
        }

        let devices = try await client.discoverDevices(
            executableURL: URL(filePath: "/sdk/hdc")
        )

        XCTAssertEqual(devices, [TraceCaptureDevice(id: "device-key")])
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
    private func waitForPhase(_ phase: TraceCapturePhase, in controller: TraceCaptureController) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while controller.phase != phase, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(controller.phase, phase)
    }

    private func assertLateProgressIsIgnored(
        in controller: TraceCaptureController,
        progress: @Sendable (TraceCaptureStage) -> Void
    ) async {
        let phase = controller.phase
        let changed = expectation(description: "late progress must not change \(phase)")
        changed.isInverted = true
        withObservationTracking { _ = controller.phase } onChange: { changed.fulfill() }
        progress(.recording)
        progress(.transferring)
        await fulfillment(of: [changed], timeout: 0.05)
        XCTAssertEqual(controller.phase, phase)
    }

    func testQueuedProgressCannotUndoCancellationOrCancelledState() async throws {
        let progressSlot = Mutex<(@Sendable (TraceCaptureStage) -> Void)?>(nil)
        let completion = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let controller = TraceCaptureController(
            executableURL: URL(filePath: "/sdk/hdc"),
            discover: { _ in [TraceCaptureDevice(id: "one-device")] },
            capture: { _, request, progress in
                progressSlot.withLock { $0 = progress }
                await withCheckedContinuation { continuation in
                    completion.withLock { $0 = continuation }
                    progress(.recording)
                }
                // A dependency may finish despite cancellation. The controller
                // must still honor the user's cancellation before publishing.
                return request.destinationURL
            }
        )
        defer { completion.withLock { $0?.resume(); $0 = nil } }
        controller.refreshDevices()
        try await waitForPhase(.ready, in: controller)
        controller.startCapture(to: URL(filePath: "/tmp/cancelled.htrace")) { _ in
            XCTFail("cancelled capture must not publish")
        }
        try await waitForPhase(.recording, in: controller)
        let progress = try XCTUnwrap(progressSlot.withLock { $0 })
        controller.cancelCapture()
        await assertLateProgressIsIgnored(in: controller, progress: progress)
        completion.withLock { $0?.resume(); $0 = nil }
        try await waitForPhase(.cancelled, in: controller)
        await assertLateProgressIsIgnored(in: controller, progress: progress)
    }

    func testQueuedProgressCannotUndoCompletedOrFailedState() async throws {
        for shouldFail in [false, true] {
            let progressSlot = Mutex<(@Sendable (TraceCaptureStage) -> Void)?>(nil)
            let controller = TraceCaptureController(
                executableURL: URL(filePath: "/sdk/hdc"),
                discover: { _ in [TraceCaptureDevice(id: "one-device")] },
                capture: { _, request, progress in
                    progressSlot.withLock { $0 = progress }
                    if shouldFail { throw CocoaError(.fileReadUnknown) }
                    return request.destinationURL
                }
            )
            controller.refreshDevices()
            try await waitForPhase(.ready, in: controller)
            controller.startCapture(to: URL(filePath: "/tmp/completed.htrace")) { _ in }
            try await waitForPhase(shouldFail ? .failed : .completed, in: controller)
            let progress = try XCTUnwrap(progressSlot.withLock { $0 })
            await assertLateProgressIsIgnored(in: controller, progress: progress)
        }
    }

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

    func testTypedDurationUnitsQuickValuesAndValidationReachCanStart() async throws {
        let controller = TraceCaptureController(
            executableURL: URL(filePath: "/sdk/hdc"),
            discover: { _ in [TraceCaptureDevice(id: "one-device")] },
            capture: { _, request, _ in request.destinationURL }
        )
        controller.refreshDevices()
        while controller.phase == .discovering { await Task.yield() }

        XCTAssertEqual(controller.durationInputValue, 10)
        XCTAssertEqual(controller.durationSeconds, 10)
        controller.durationSeconds = 45
        XCTAssertEqual(controller.durationUnit, .seconds)
        XCTAssertEqual(controller.durationInputValue, 45)
        XCTAssertEqual(controller.durationSeconds, 45)
        XCTAssertTrue(controller.canStart)

        controller.setDurationUnit(.minutes)
        XCTAssertEqual(controller.durationInputValue, 1)
        XCTAssertEqual(controller.durationSeconds, 60)

        controller.selectQuickDuration(3)
        XCTAssertEqual(controller.durationInputValue, 3)
        XCTAssertEqual(controller.durationSeconds, 180)

        controller.durationInputValue = 6
        XCTAssertFalse(controller.isDurationValid)
        XCTAssertFalse(controller.canStart)

        controller.setDurationUnit(.seconds)
        XCTAssertEqual(controller.durationInputValue, 10)
        XCTAssertEqual(controller.durationSeconds, 10)
        XCTAssertTrue(controller.canStart)
    }

    func testDiscoveryPublishesHDCVersionWithoutChangingDeviceReadiness() async throws {
        let controller = TraceCaptureController(
            executableURL: URL(filePath: "/sdk/hdc"),
            discover: { _ in [TraceCaptureDevice(id: "one-device")] },
            versionLookup: { _ in "3.2.0f" },
            capture: { _, request, _ in request.destinationURL }
        )

        XCTAssertNil(controller.hdcVersion)
        controller.refreshDevices()
        while controller.phase == .discovering { await Task.yield() }

        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.hdcVersion, "3.2.0f")
        XCTAssertTrue(controller.canStart)
    }
}
