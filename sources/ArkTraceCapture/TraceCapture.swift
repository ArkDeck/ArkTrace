import Darwin
import Foundation
import Observation

/// The three bounded capture shapes ArkTrace exposes instead of the full
/// hiprofiler configuration language. They intentionally produce only data
/// the viewer can already parse and explain.
public enum TraceCaptureProfile: String, CaseIterable, Codable, Sendable, Identifiable {
    case appResponsiveness
    case cpuScheduling
    case systemOverview

    public var id: String { rawValue }
}

public struct TraceCaptureDevice: Hashable, Codable, Sendable, Identifiable {
    public enum Transport: String, Hashable, Codable, Sendable {
        case usb
        case network
    }

    public let id: String
    public let transport: Transport
    public let name: String?
    public let systemVersion: String?

    public init(
        id: String,
        transport: Transport? = nil,
        name: String? = nil,
        systemVersion: String? = nil
    ) {
        self.id = id
        self.transport = transport ?? (id.contains(":") ? .network : .usb)
        self.name = name
        self.systemVersion = systemVersion
    }
}

public struct TraceCaptureRequest: Hashable, Sendable {
    public static let allowedBufferSizesMB = [16, 32, 64, 128, 256]
    public static let durationRange = 5...300

    public let deviceID: String
    public let profile: TraceCaptureProfile
    public let durationSeconds: Int
    public let bufferSizeMB: Int
    public let destinationURL: URL

    public init(
        deviceID: String,
        profile: TraceCaptureProfile,
        durationSeconds: Int,
        bufferSizeMB: Int,
        destinationURL: URL
    ) throws {
        let deviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceID.isEmpty, deviceID.utf8.count <= 256,
            !deviceID.contains("\n"), !deviceID.contains("\0")
        else {
            throw TraceCaptureIssue.invalidConfiguration(
                "Select a connected device before starting the capture."
            )
        }
        guard Self.durationRange.contains(durationSeconds) else {
            throw TraceCaptureIssue.invalidConfiguration(
                "Enter a duration from 5 to 300 seconds."
            )
        }
        guard Self.allowedBufferSizesMB.contains(bufferSizeMB) else {
            throw TraceCaptureIssue.invalidConfiguration(
                "Choose one of the available trace buffer sizes."
            )
        }
        guard destinationURL.isFileURL else {
            throw TraceCaptureIssue.invalidConfiguration(
                "Choose a local file for the captured trace."
            )
        }
        self.deviceID = deviceID
        self.profile = profile
        self.durationSeconds = durationSeconds
        self.bufferSizeMB = bufferSizeMB
        self.destinationURL = destinationURL.standardizedFileURL
    }
}

/// The two native entry units exposed by the App. Capture requests continue to
/// carry seconds so the device protocol has one unambiguous bounded unit.
public enum TraceCaptureDurationUnit: String, CaseIterable, Hashable, Sendable, Identifiable {
    case seconds
    case minutes

    public var id: Self { self }

    public var inputRange: ClosedRange<Int> {
        switch self {
        case .seconds:
            TraceCaptureRequest.durationRange
        case .minutes:
            1...(TraceCaptureRequest.durationRange.upperBound / 60)
        }
    }

    public var quickValues: [Int] {
        switch self {
        case .seconds: [5, 10, 15, 30]
        case .minutes: [1, 2, 3]
        }
    }

    /// Converts a typed value to the request's canonical seconds while
    /// rejecting both out-of-range input and integer overflow.
    public func durationSeconds(for inputValue: Int) -> Int? {
        guard inputRange.contains(inputValue) else { return nil }
        let multiplier = self == .seconds ? 1 : 60
        let (seconds, overflow) = inputValue.multipliedReportingOverflow(by: multiplier)
        guard !overflow, TraceCaptureRequest.durationRange.contains(seconds) else {
            return nil
        }
        return seconds
    }

    /// Switching from seconds to minutes rounds up so changing the display
    /// unit never silently shortens the requested capture.
    public func inputValue(forDurationSeconds durationSeconds: Int) -> Int {
        let bounded = min(
            TraceCaptureRequest.durationRange.upperBound,
            max(TraceCaptureRequest.durationRange.lowerBound, durationSeconds)
        )
        switch self {
        case .seconds:
            return bounded
        case .minutes:
            return (bounded + 59) / 60
        }
    }
}

public enum TraceCaptureStage: String, Hashable, Codable, Sendable {
    case preparing
    case recording
    case transferring
}

public enum TraceCapturePhase: String, Hashable, Codable, Sendable {
    case idle
    case discovering
    case ready
    case preparing
    case recording
    case transferring
    case cancelling
    case completed
    case cancelled
    case failed

    public var isBusy: Bool {
        switch self {
        case .discovering, .preparing, .recording, .transferring, .cancelling:
            true
        default:
            false
        }
    }

    public var isCapturing: Bool {
        switch self {
        case .preparing, .recording, .transferring, .cancelling:
            true
        default:
            false
        }
    }
}

public struct TraceCaptureIssue: Error, Hashable, Sendable, LocalizedError {
    public enum Code: String, Hashable, Codable, Sendable {
        case hdcUnavailable
        case deviceDiscoveryFailed
        case invalidConfiguration
        case configurationTransferFailed
        case profilerFailed
        case traceTransferFailed
        case capturedFileInvalid
        case destinationFailed
    }

    public let code: Code
    public let message: String
    public let recoverySuggestion: String
    public let diagnostic: String?

    public var errorDescription: String? { message }

    public init(
        code: Code,
        message: String,
        recoverySuggestion: String,
        diagnostic: String? = nil
    ) {
        self.code = code
        self.message = String(message.prefix(512))
        self.recoverySuggestion = String(recoverySuggestion.prefix(512))
        self.diagnostic = diagnostic.map { String($0.prefix(4_096)) }
    }

    static func invalidConfiguration(_ message: String) -> Self {
        Self(
            code: .invalidConfiguration,
            message: message,
            recoverySuggestion: "Review the capture settings and try again."
        )
    }
}

// MARK: - HDC configuration

extension TraceCaptureProfile {
    /// Official hiprofiler ftrace example plus the optional CPU power events
    /// used by SmartPerf's CPU frequency/idle probe.
    var ftraceEvents: [String] {
        let scheduling = [
            "sched/sched_switch",
            "power/suspend_resume",
            "sched/sched_wakeup",
            "sched/sched_wakeup_new",
            "sched/sched_waking",
            "sched/sched_process_exit",
            "sched/sched_process_free",
            "task/task_newtask",
            "task/task_rename",
        ]
        let cpuPower = ["power/cpu_frequency", "power/cpu_idle"]
        switch self {
        case .appResponsiveness: return scheduling
        case .cpuScheduling, .systemOverview: return scheduling + cpuPower
        }
    }

    /// A curated subset for the focused profiles and the complete documented
    /// set for System Overview. Each category is an argument value in the
    /// protobuf text config, never a shell fragment.
    var hitraceCategories: [String] {
        switch self {
        case .appResponsiveness:
            ["ability", "ace", "binder", "graphic", "ohos", "rpc", "sched", "sync", "window"]
        case .cpuScheduling:
            ["freq", "idle", "sched"]
        case .systemOverview:
            [
                "ability", "ace", "binder", "dsoftbus", "freq", "graphic", "idle",
                "memory", "ohos", "rpc", "sched", "sync", "window",
            ]
        }
    }
}

enum TraceCaptureConfigurationBuilder {
    static func text(
        for request: TraceCaptureRequest,
        remoteTracePath: String
    ) -> String {
        let durationMilliseconds = request.durationSeconds * 1_000
        let sessionPages = request.bufferSizeMB * 256
        let bufferSizeKB = request.bufferSizeMB * 1_024
        let eventLines = request.profile.ftraceEvents.map {
            "      ftrace_events: \"\($0)\""
        }
        let categoryLines = request.profile.hitraceCategories.map {
            "      hitrace_categories: \"\($0)\""
        }
        return ([
            "request_id: 1",
            "session_config {",
            "  buffers {",
            "    pages: \(sessionPages)",
            "  }",
            "  result_file: \"\(remoteTracePath)\"",
            "  sample_duration: \(durationMilliseconds)",
            "}",
            "plugin_configs {",
            "  plugin_name: \"ftrace-plugin\"",
            "  sample_interval: 1000",
            "  config_data {",
        ] + eventLines + categoryLines + [
            "      hitrace_time: \(request.durationSeconds)",
            "      buffer_size_kb: \(bufferSizeKB)",
            "      flush_interval_ms: 1000",
            "      flush_threshold_kb: 4096",
            "      parse_ksyms: true",
            "      clock: \"mono\"",
            "      trace_period_ms: 200",
            "      debug_on: false",
            "  }",
            "}",
            "",
        ]).joined(separator: "\n")
    }
}

enum HDCExecutableLocator {
    static let preferenceKey = "captureHDCExecutablePath"

    static func resolve(
        persistedPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        candidates(persistedPath: persistedPath, environment: environment)
            .first(where: isUsableExecutable)
    }

    static func candidates(
        persistedPath: String?,
        environment: [String: String]
    ) -> [URL] {
        var values: [URL] = []
        if let persistedPath, !persistedPath.isEmpty {
            values.append(URL(filePath: persistedPath))
        }
        if let configured = environment["HDC_PATH"] ?? environment["HDC_SDK_PATH"],
            !configured.isEmpty
        {
            let url = URL(filePath: configured)
            values.append(url.lastPathComponent == "hdc" ? url : url.appending(path: "hdc"))
        }
        if let sdk = environment["OHOS_SDK_HOME"], !sdk.isEmpty {
            let root = URL(filePath: sdk)
            values.append(root.appending(path: "toolchains/hdc"))
            values.append(root.appending(path: "openharmony/toolchains/hdc"))
        }
        if let path = environment["PATH"] {
            values += path.split(separator: ":").map {
                URL(filePath: String($0), directoryHint: .isDirectory)
                    .appending(path: "hdc")
            }
        }
        values += [
            URL(filePath: "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"),
            URL(filePath: "/Applications/deveco-studio.app/Contents/sdk/default/openharmony/toolchains/hdc"),
            URL(filePath: "/opt/homebrew/bin/hdc"),
            URL(filePath: "/usr/local/bin/hdc"),
        ]

        var seen = Set<String>()
        return values.compactMap { candidate in
            let candidate = candidate.standardizedFileURL
            return seen.insert(candidate.path).inserted ? candidate : nil
        }
    }

    static func isUsableExecutable(_ url: URL) -> Bool {
        guard url.isFileURL,
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
            && FileManager.default.isExecutableFile(atPath: url.path)
    }
}

// MARK: - Bounded child process runner

struct HDCProcessOutcome: Sendable {
    let exitStatus: Int32
    let stdout: Data
    let stderr: Data
    let outputWasTruncated: Bool

    var diagnosticText: String {
        let text = String(decoding: stdout + stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((text.isEmpty ? "hdc exited with status \(exitStatus)" : text).prefix(4_096))
    }

    var succeeded: Bool {
        guard exitStatus == 0 else { return false }
        let lower = String(decoding: stdout + stderr, as: UTF8.self).lowercased()
        return !lower.contains("[fail]") && !lower.contains("permission denied")
    }
}

typealias HDCProcessRunner = @Sendable (
    _ executableURL: URL,
    _ arguments: [String]
) async throws -> HDCProcessOutcome

private final class HDCProcessBox: @unchecked Sendable {
    private enum State {
        case notStarted
        case running(pid_t)
        case terminating(pid_t)
        case exited
    }

    private let lock = NSLock()
    private let process: Process
    private var state: State = .notStarted
    private var cancellationRequested = false
    private var escalation: DispatchWorkItem?

    init(_ process: Process) { self.process = process }

    func runIfNotCancelled() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancellationRequested else { throw CancellationError() }
        try process.run()
        state = .running(process.processIdentifier)
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        guard case .running(let pid) = state, process.isRunning else {
            lock.unlock()
            return
        }
        state = .terminating(pid)
        process.terminate()
        let work = DispatchWorkItem { [weak self] in self?.killIfNeeded(pid) }
        escalation = work
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + 0.5,
            execute: work
        )
    }

    func waitUntilExit() -> Int32 {
        process.waitUntilExit()
        lock.lock()
        defer { lock.unlock() }
        state = .exited
        escalation?.cancel()
        escalation = nil
        return process.terminationStatus
    }

    private func killIfNeeded(_ expectedPID: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        guard case .terminating(let pid) = state, pid == expectedPID,
            process.processIdentifier == expectedPID, process.isRunning
        else { return }
        _ = Darwin.kill(expectedPID, SIGKILL)
    }
}

final class HDCBoundedPipeSink: @unchecked Sendable {
    let pipe = Pipe()
    private let condition = NSCondition()
    private let capacity: Int
    private var data = Data()
    private var truncated = false
    private var accepting = true
    private var activeCallbacks = 0
    // Internal seams for exercising a read already in flight during teardown.
    private let readDidCompleteHook: (@Sendable () -> Void)?

    init(capacity: Int = 65_536, readDidCompleteHook: (@Sendable () -> Void)? = nil) {
        self.capacity = capacity
        self.readDidCompleteHook = readDidCompleteHook
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(from: handle)
        }
    }

    func finishAndDrain(callbacksStoppedHook: (@Sendable () -> Void)? = nil) -> (Data, Bool) {
        let handle = pipe.fileHandleForReading
        condition.lock()
        accepting = false
        condition.unlock()
        handle.readabilityHandler = nil
        callbacksStoppedHook?()
        condition.lock()
        while activeCallbacks > 0 { condition.wait() }
        condition.unlock()
        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { break }
            append(chunk)
        }
        condition.lock()
        defer { condition.unlock() }
        return (data, truncated)
    }

    private func consume(from handle: FileHandle) {
        condition.lock()
        guard accepting else {
            condition.unlock()
            return
        }
        activeCallbacks += 1
        condition.unlock()

        // Register before reading: stopping callbacks must not discard bytes
        // already removed from the pipe, or start a competing EOF drain.
        let chunk = handle.availableData
        readDidCompleteHook?()
        condition.lock()
        if chunk.isEmpty {
            accepting = false
        } else {
            appendLocked(chunk)
        }
        activeCallbacks -= 1
        condition.broadcast()
        condition.unlock()
        if chunk.isEmpty { handle.readabilityHandler = nil }
    }

    private func append(_ chunk: Data) {
        condition.lock()
        appendLocked(chunk)
        condition.unlock()
    }

    private func appendLocked(_ chunk: Data) {
        guard data.count < capacity else {
            truncated = true
            return
        }
        let remaining = capacity - data.count
        data.append(chunk.prefix(remaining))
        if chunk.count > remaining { truncated = true }
    }
}

enum HDCProcessExecutor {
    static func run(
        executableURL: URL,
        arguments: [String]
    ) async throws -> HDCProcessOutcome {
        let worker = Task.detached {
            try await runOnWorker(executableURL: executableURL, arguments: arguments)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func runOnWorker(
        executableURL: URL,
        arguments: [String]
    ) async throws -> HDCProcessOutcome {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = executableURL.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("DYLD_") {
            environment.removeValue(forKey: key)
        }
        environment["LANG"] = "C"
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = HDCBoundedPipeSink()
        let stderr = HDCBoundedPipeSink()
        process.standardOutput = stdout.pipe
        process.standardError = stderr.pipe

        let box = HDCProcessBox(process)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    process.terminationHandler = { _ in continuation.resume() }
                    do {
                        try box.runIfNotCancelled()
                    } catch {
                        process.terminationHandler = nil
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                box.cancel()
            }
        } catch {
            // No child was launched, so Foundation still owns both parent
            // write ends. Close them before waiting for EOF on the readers.
            try? stdout.pipe.fileHandleForWriting.close()
            try? stderr.pipe.fileHandleForWriting.close()
            _ = stdout.finishAndDrain()
            _ = stderr.finishAndDrain()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw error
        }
        let status = box.waitUntilExit()
        let (stdoutData, stdoutTruncated) = stdout.finishAndDrain()
        let (stderrData, stderrTruncated) = stderr.finishAndDrain()
        if Task.isCancelled { throw CancellationError() }
        return HDCProcessOutcome(
            exitStatus: status,
            stdout: stdoutData,
            stderr: stderrData,
            outputWasTruncated: stdoutTruncated || stderrTruncated
        )
    }
}

// MARK: - HDC capture client

struct HDCTraceCaptureClient: Sendable {
    private let runner: HDCProcessRunner

    init(runner: @escaping HDCProcessRunner = HDCProcessExecutor.run) {
        self.runner = runner
    }

    func version(executableURL: URL) async -> String? {
        let outcome: HDCProcessOutcome
        do {
            outcome = try await runner(executableURL, ["-v"])
        } catch {
            return nil
        }
        guard outcome.succeeded, !outcome.outputWasTruncated else { return nil }
        return Self.parseVersion(
            String(decoding: outcome.stdout + outcome.stderr, as: UTF8.self)
        )
    }

    static func parseVersion(_ output: String) -> String? {
        let tokens = output.prefix(4_096).split(whereSeparator: \.isWhitespace)
        var followsVersionLabel = false
        for rawToken in tokens {
            let raw = String(rawToken)
            let marker = raw.trimmingCharacters(
                in: CharacterSet(charactersIn: ":,;()[]{}")
            ).lowercased()
            if marker == "ver" || marker == "version" {
                followsVersionLabel = true
                continue
            }

            var candidate = raw.trimmingCharacters(
                in: CharacterSet(charactersIn: ":,;()[]{}")
            )
            let hasVersionPrefix = candidate.first?.lowercased() == "v"
            if hasVersionPrefix { candidate.removeFirst() }
            let canBeVersion = followsVersionLabel || hasVersionPrefix || tokens.count == 1
            followsVersionLabel = false
            guard canBeVersion, candidate.utf8.count <= 32, candidate.contains(".") else {
                continue
            }
            let scalars = candidate.unicodeScalars
            guard let first = scalars.first, (48...57).contains(first.value) else {
                continue
            }
            let isSafe = scalars.allSatisfy { scalar in
                switch scalar.value {
                case 43, 45, 46, 48...57, 65...90, 95, 97...122:
                    true
                default:
                    false
                }
            }
            if isSafe { return candidate }
        }
        return nil
    }

    func discoverDevices(executableURL: URL) async throws -> [TraceCaptureDevice] {
        let outcome: HDCProcessOutcome
        do {
            outcome = try await runner(executableURL, ["list", "targets"])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TraceCaptureIssue(
                code: .deviceDiscoveryFailed,
                message: "Unable to ask HDC for connected devices.",
                recoverySuggestion: "Check the HDC executable, then try again.",
                diagnostic: String(describing: error)
            )
        }
        guard outcome.succeeded else {
            throw TraceCaptureIssue(
                code: .deviceDiscoveryFailed,
                message: "HDC could not list connected devices.",
                recoverySuggestion: "Check USB or network debugging, then refresh the device list.",
                diagnostic: outcome.diagnosticText
            )
        }
        let devices = Self.parseDevices(String(decoding: outcome.stdout, as: UTF8.self))
        return try await enrichDevices(devices, executableURL: executableURL)
    }

    static func parseDevices(_ output: String) -> [TraceCaptureDevice] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                !line.lowercased().contains("empty"),
                !line.hasPrefix("[")
            else { return nil }
            guard let token = line.split(whereSeparator: \.isWhitespace).first else { return nil }
            let id = String(token)
            guard seen.insert(id).inserted else { return nil }
            return TraceCaptureDevice(id: id)
        }
    }

    static func parseDeviceProperty(_ output: String) -> String? {
        var value = output.prefix(1_024).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 256 else { return nil }
        if value.count >= 2,
            (value.first == "\"" && value.last == "\"")
                || (value.first == "'" && value.last == "'")
        {
            value.removeFirst()
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let normalized = value.lowercased()
        guard !value.isEmpty,
            !["default", "unknown", "none", "null", "[empty]"].contains(normalized),
            !normalized.hasPrefix("[fail]"),
            !(normalized.contains("get parameter") && normalized.contains("fail")),
            value.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else { return nil }
        return value
    }

    private func enrichDevices(
        _ devices: [TraceCaptureDevice],
        executableURL: URL
    ) async throws -> [TraceCaptureDevice] {
        guard !devices.isEmpty else { return [] }
        return try await withThrowingTaskGroup(
            of: (Int, TraceCaptureDevice).self,
            returning: [TraceCaptureDevice].self
        ) { group in
            for (index, device) in devices.enumerated() {
                group.addTask {
                    async let name = deviceProperty(
                        executableURL: executableURL,
                        deviceID: device.id,
                        key: "const.product.name"
                    )
                    async let systemVersion = deviceProperty(
                        executableURL: executableURL,
                        deviceID: device.id,
                        key: "const.ohos.fullname"
                    )
                    return try await (
                        index,
                        TraceCaptureDevice(
                            id: device.id,
                            transport: device.transport,
                            name: name,
                            systemVersion: systemVersion
                        )
                    )
                }
            }

            var enriched = devices
            for try await (index, device) in group {
                enriched[index] = device
            }
            return enriched
        }
    }

    private func deviceProperty(
        executableURL: URL,
        deviceID: String,
        key: String
    ) async throws -> String? {
        let outcome: HDCProcessOutcome
        do {
            outcome = try await runner(
                executableURL,
                ["-t", deviceID, "shell", "param", "get", key]
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        guard outcome.succeeded, !outcome.outputWasTruncated else { return nil }
        return Self.parseDeviceProperty(
            String(decoding: outcome.stdout + outcome.stderr, as: UTF8.self)
        )
    }

    func capture(
        executableURL: URL,
        request: TraceCaptureRequest,
        progress: @escaping @Sendable (TraceCaptureStage) -> Void
    ) async throws -> URL {
        let nonce = UUID().uuidString.lowercased()
        let remoteTrace = "/data/local/tmp/arktrace-\(nonce).htrace"
        let remoteConfiguration = "/data/local/tmp/arktrace-\(nonce).txt"
        let localConfiguration = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-\(nonce).txt")
        let partial = request.destinationURL.deletingLastPathComponent()
            .appending(path: ".arktrace-\(nonce).partial")
        let configuration = TraceCaptureConfigurationBuilder.text(
            for: request,
            remoteTracePath: remoteTrace
        )

        do {
            try Data(configuration.utf8).write(to: localConfiguration, options: [.atomic])
        } catch {
            throw TraceCaptureIssue(
                code: .configurationTransferFailed,
                message: "Unable to prepare the capture configuration.",
                recoverySuggestion: "Check available disk space and try again.",
                diagnostic: String(describing: error)
            )
        }

        let acquisition: Result<Void, Error>
        do {
            progress(.preparing)
            try Task.checkCancellation()
            let send = try await runner(
                executableURL,
                Self.targetArguments(request.deviceID)
                    + ["file", "send", localConfiguration.path, remoteConfiguration]
            )
            guard send.succeeded else {
                throw TraceCaptureIssue(
                    code: .configurationTransferFailed,
                    message: "Unable to send the capture configuration to the device.",
                    recoverySuggestion: "Keep the device connected, then try again.",
                    diagnostic: send.diagnosticText
                )
            }

            progress(.recording)
            let record = try await runner(
                executableURL,
                Self.targetArguments(request.deviceID) + [
                    "shell", "hiprofiler_cmd",
                    "-c", remoteConfiguration,
                    "-o", remoteTrace,
                    "-t", String(request.durationSeconds),
                    "-s", "-k",
                ]
            )
            guard record.succeeded else {
                throw TraceCaptureIssue(
                    code: .profilerFailed,
                    message: "The device could not capture this trace.",
                    recoverySuggestion: "Confirm hiprofiler_cmd is installed and profiling is allowed, then try again.",
                    diagnostic: record.diagnosticText
                )
            }

            progress(.transferring)
            let receive = try await runner(
                executableURL,
                Self.targetArguments(request.deviceID)
                    + ["file", "recv", remoteTrace, partial.path]
            )
            guard receive.succeeded else {
                throw TraceCaptureIssue(
                    code: .traceTransferFailed,
                    message: "The trace was captured but could not be copied to this Mac.",
                    recoverySuggestion: "Keep the device connected and try the capture again.",
                    diagnostic: receive.diagnosticText
                )
            }
            try Task.checkCancellation()
            try Self.validateCapturedFile(partial)
            acquisition = .success(())
        } catch {
            acquisition = .failure(error)
        }

        // Cleanup is independent of the cancelled parent task. Both paths are
        // names generated by ArkTrace for this request, never user input.
        await cleanupRemote(
            executableURL: executableURL,
            deviceID: request.deviceID,
            paths: [remoteTrace, remoteConfiguration]
        )
        try? FileManager.default.removeItem(at: localConfiguration)

        do {
            try Task.checkCancellation()
            try acquisition.get()
            // This non-suspending check-to-rename sequence is the commit
            // boundary. Cancellation before it leaves only the private
            // partial; cancellation after it observes a committed success.
            try Task.checkCancellation()
            try Self.promote(partial, to: request.destinationURL)
            return request.destinationURL
        } catch {
            try? FileManager.default.removeItem(at: partial)
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private func cleanupRemote(
        executableURL: URL,
        deviceID: String,
        paths: [String]
    ) async {
        let runner = runner
        let task = Task.detached {
            // `-k` is hiprofiler_cmd's documented dependent-process shutdown.
            // It matters on cancellation, where terminating the host-side HDC
            // client alone must not leave the profiler running on the device.
            _ = try? await runner(
                executableURL,
                Self.targetArguments(deviceID) + ["shell", "hiprofiler_cmd", "-k"]
            )
            _ = try? await runner(
                executableURL,
                Self.targetArguments(deviceID) + ["shell", "rm", "-f"] + paths
            )
        }
        await task.value
    }

    private static func targetArguments(_ deviceID: String) -> [String] {
        ["-t", deviceID]
    }

    private static func validateCapturedFile(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 else {
            throw TraceCaptureIssue(
                code: .capturedFileInvalid,
                message: "The captured trace is empty or unreadable.",
                recoverySuggestion: "Try a longer capture or a different profile."
            )
        }
    }

    private static func promote(_ partial: URL, to destination: URL) throws {
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: partial)
            } else {
                try manager.moveItem(at: partial, to: destination)
            }
        } catch {
            throw TraceCaptureIssue(
                code: .destinationFailed,
                message: "The trace could not be saved at the chosen location.",
                recoverySuggestion: "Choose another folder and try again.",
                diagnostic: String(describing: error)
            )
        }
    }
}

// MARK: - UI state

typealias TraceCaptureDeviceDiscovery = @Sendable (URL) async throws -> [TraceCaptureDevice]
typealias HDCVersionLookup = @Sendable (URL) async -> String?
typealias TraceCaptureOperation = @Sendable (
    URL,
    TraceCaptureRequest,
    @escaping @Sendable (TraceCaptureStage) -> Void
) async throws -> URL

@MainActor
@Observable
public final class TraceCaptureController {
    public private(set) var hdcExecutableURL: URL?
    public private(set) var hdcVersion: String?
    public private(set) var devices: [TraceCaptureDevice] = []
    public var selectedDeviceID: String?
    public var profile: TraceCaptureProfile = .appResponsiveness
    public var durationInputValue = 10
    public private(set) var durationUnit: TraceCaptureDurationUnit = .seconds
    public var bufferSizeMB = 64
    public private(set) var phase: TraceCapturePhase = .idle
    public private(set) var elapsedSeconds = 0
    public private(set) var issue: TraceCaptureIssue?
    public private(set) var completedURL: URL?

    public var canStart: Bool {
        guard !phase.isBusy, hdcExecutableURL != nil, let selectedDeviceID else {
            return false
        }
        return devices.contains(where: { $0.id == selectedDeviceID })
            && isDurationValid
            && TraceCaptureRequest.allowedBufferSizesMB.contains(bufferSizeMB)
    }

    public var durationSeconds: Int {
        get { durationUnit.durationSeconds(for: durationInputValue) ?? 0 }
        set {
            durationUnit = .seconds
            durationInputValue = newValue
        }
    }

    public var isDurationValid: Bool {
        durationUnit.durationSeconds(for: durationInputValue) != nil
    }

    public var progressFraction: Double? {
        guard phase == .recording, durationSeconds > 0 else { return nil }
        return min(1, Double(elapsedSeconds) / Double(durationSeconds))
    }

    @ObservationIgnored private let discover: TraceCaptureDeviceDiscovery
    @ObservationIgnored private let versionLookup: HDCVersionLookup
    @ObservationIgnored private let capture: TraceCaptureOperation
    @ObservationIgnored private let persistExecutable: @MainActor (URL?) -> Void
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var elapsedTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    public convenience init() {
        let defaults = UserDefaults.standard
        let persisted = defaults.string(forKey: HDCExecutableLocator.preferenceKey)
        let executable = HDCExecutableLocator.resolve(persistedPath: persisted)
        let client = HDCTraceCaptureClient()
        self.init(
            executableURL: executable,
            discover: { try await client.discoverDevices(executableURL: $0) },
            versionLookup: { await client.version(executableURL: $0) },
            capture: { executableURL, request, progress in
                try await client.capture(
                    executableURL: executableURL,
                    request: request,
                    progress: progress
                )
            },
            persistExecutable: { url in
                defaults.set(url?.path, forKey: HDCExecutableLocator.preferenceKey)
            }
        )
    }

    init(
        executableURL: URL?,
        discover: @escaping TraceCaptureDeviceDiscovery,
        versionLookup: @escaping HDCVersionLookup = { _ in nil },
        capture: @escaping TraceCaptureOperation,
        persistExecutable: @escaping @MainActor (URL?) -> Void = { _ in }
    ) {
        self.hdcExecutableURL = executableURL
        self.discover = discover
        self.versionLookup = versionLookup
        self.capture = capture
        self.persistExecutable = persistExecutable
    }

    deinit {
        discoveryTask?.cancel()
        captureTask?.cancel()
        elapsedTask?.cancel()
    }

    public func setHDCExecutable(_ url: URL) {
        guard !phase.isCapturing else { return }
        let url = url.standardizedFileURL
        guard HDCExecutableLocator.isUsableExecutable(url) else {
            issue = TraceCaptureIssue(
                code: .hdcUnavailable,
                message: "The selected file is not an executable HDC tool.",
                recoverySuggestion: "Choose hdc from the OpenHarmony SDK toolchains folder."
            )
            phase = .failed
            return
        }
        discoveryTask?.cancel()
        generation &+= 1
        hdcExecutableURL = url
        hdcVersion = nil
        persistExecutable(url)
        devices = []
        selectedDeviceID = nil
        issue = nil
        completedURL = nil
        phase = .idle
        refreshDevices()
    }

    public func setDurationUnit(_ unit: TraceCaptureDurationUnit) {
        guard !phase.isCapturing, unit != durationUnit else { return }
        let currentSeconds = durationUnit.durationSeconds(for: durationInputValue) ?? 10
        durationUnit = unit
        durationInputValue = unit.inputValue(forDurationSeconds: currentSeconds)
    }

    public func selectQuickDuration(_ inputValue: Int) {
        guard !phase.isCapturing, durationUnit.quickValues.contains(inputValue) else {
            return
        }
        durationInputValue = inputValue
    }

    public func refreshDevices() {
        guard !phase.isCapturing else { return }
        discoveryTask?.cancel()
        generation &+= 1
        let generation = generation
        guard let executableURL = hdcExecutableURL else {
            devices = []
            selectedDeviceID = nil
            issue = TraceCaptureIssue(
                code: .hdcUnavailable,
                message: "HDC was not found on this Mac.",
                recoverySuggestion: "Choose hdc from the OpenHarmony SDK toolchains folder."
            )
            phase = .failed
            return
        }
        issue = nil
        phase = .discovering
        let discover = discover
        let versionLookup = versionLookup
        discoveryTask = Task { [weak self] in
            async let version = versionLookup(executableURL)
            do {
                let devices = try await discover(executableURL)
                let hdcVersion = await version
                try Task.checkCancellation()
                guard let self, self.generation == generation else { return }
                self.devices = devices
                self.hdcVersion = hdcVersion
                if !devices.contains(where: { $0.id == self.selectedDeviceID }) {
                    self.selectedDeviceID = devices.count == 1 ? devices[0].id : nil
                }
                self.phase = .ready
            } catch is CancellationError {
                return
            } catch let issue as TraceCaptureIssue {
                guard let self, self.generation == generation else { return }
                self.issue = issue
                self.phase = .failed
            } catch {
                guard let self, self.generation == generation else { return }
                self.issue = TraceCaptureIssue(
                    code: .deviceDiscoveryFailed,
                    message: "Unable to refresh connected devices.",
                    recoverySuggestion: "Check USB or network debugging, then try again.",
                    diagnostic: String(describing: error)
                )
                self.phase = .failed
            }
        }
    }

    public func startCapture(
        to destinationURL: URL,
        onCompleted: @escaping @MainActor @Sendable (URL) -> Void
    ) {
        guard !phase.isBusy, let executableURL = hdcExecutableURL,
            let selectedDeviceID,
            devices.contains(where: { $0.id == selectedDeviceID })
        else {
            issue = TraceCaptureIssue.invalidConfiguration(
                "Select a connected device before starting the capture."
            )
            phase = .failed
            return
        }
        let request: TraceCaptureRequest
        do {
            request = try TraceCaptureRequest(
                deviceID: selectedDeviceID,
                profile: profile,
                durationSeconds: durationSeconds,
                bufferSizeMB: bufferSizeMB,
                destinationURL: destinationURL
            )
        } catch let issue as TraceCaptureIssue {
            self.issue = issue
            phase = .failed
            return
        } catch {
            issue = TraceCaptureIssue.invalidConfiguration(String(describing: error))
            phase = .failed
            return
        }

        discoveryTask?.cancel()
        captureTask?.cancel()
        elapsedTask?.cancel()
        generation &+= 1
        let generation = generation
        elapsedSeconds = 0
        issue = nil
        completedURL = nil
        phase = .preparing
        let capture = capture

        captureTask = Task { [weak self] in
            do {
                let url = try await capture(
                    executableURL,
                    request,
                    { [weak self] stage in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == generation else { return }
                            self.apply(stage)
                        }
                    }
                )
                try Task.checkCancellation()
                guard let self, self.generation == generation else { return }
                self.stopElapsedTimer()
                self.completedURL = url
                self.phase = .completed
                onCompleted(url)
            } catch is CancellationError {
                guard let self, self.generation == generation else { return }
                self.stopElapsedTimer()
                self.phase = .cancelled
            } catch let issue as TraceCaptureIssue {
                guard let self, self.generation == generation else { return }
                self.stopElapsedTimer()
                self.issue = issue
                self.phase = .failed
            } catch {
                guard let self, self.generation == generation else { return }
                self.stopElapsedTimer()
                self.issue = TraceCaptureIssue(
                    code: .profilerFailed,
                    message: "The trace capture could not finish.",
                    recoverySuggestion: "Keep the device connected and try again.",
                    diagnostic: String(describing: error)
                )
                self.phase = .failed
            }
        }
    }

    public func cancelCapture() {
        guard phase.isCapturing else { return }
        phase = .cancelling
        stopElapsedTimer()
        captureTask?.cancel()
    }

    public func prepareForAnotherCapture() {
        guard !phase.isBusy else { return }
        issue = nil
        completedURL = nil
        elapsedSeconds = 0
        phase = hdcExecutableURL == nil ? .idle : .ready
    }

    private func apply(_ stage: TraceCaptureStage) {
        // Progress is delivered by queued MainActor tasks. Only a live
        // capture can advance; cancellation and terminal states are final.
        guard phase == .preparing || phase == .recording || phase == .transferring else {
            return
        }
        switch stage {
        case .preparing:
            phase = .preparing
        case .recording:
            phase = .recording
            startElapsedTimer()
        case .transferring:
            stopElapsedTimer()
            phase = .transferring
        }
    }

    private func startElapsedTimer() {
        guard elapsedTask == nil else { return }
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self, self.phase == .recording else { return }
                self.elapsedSeconds = min(self.durationSeconds, self.elapsedSeconds + 1)
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = nil
    }
}
