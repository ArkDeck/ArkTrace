import ArkTraceCore
@testable import ArkTraceParser
import ArkTraceAnalysis
import ArkTraceRendering
import AppKit
import CryptoKit
import Darwin
import XCTest

@_silgen_name("flock")
private func arkTraceTestFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

@testable import ArkTraceRuntime
@testable import ArkTraceStore

/// End-to-end vertical slice (SPEC §21.3): real trace → real pinned
/// TraceStreamer process → SQLite → schema validation → typed queries.
///
/// The test resolves TraceStreamer from `ARKTRACE_TRACE_STREAMER` or the
/// default `ThirdParty/TraceStreamer/macx` layout. A custom binary must carry
/// its sibling pinned `manifest.json`.
final class ParserIntegrationTests: XCTestCase {
    private final class PerformanceStageRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var instants: [TraceLoadingStage: ContinuousClock.Instant] = [:]

        func record(_ stage: TraceLoadingStage) {
            lock.withLock {
                if instants[stage] == nil { instants[stage] = .now }
            }
        }

        func milliseconds(
            from start: TraceLoadingStage,
            to end: TraceLoadingStage
        ) -> Double? {
            lock.withLock {
                guard let start = instants[start], let end = instants[end] else { return nil }
                return ParserIntegrationTests.milliseconds(start.duration(to: end))
            }
        }
    }
    private struct SchemaEvidence: Decodable {
        struct Upstream: Decodable {
            let repository: String
            let revision: String
            let license: String
            let licensePath: String
            let licenseBlob: String
            let licenseSHA256: String
            let licenseByteCount: Int64
        }

        struct Parser: Decodable {
            let reportedVersion: String
            let binarySHA256: String
            let architecture: String
            let adapterVersion: String
            let buildRecipeVersion: String
        }

        struct TraceRange: Decodable {
            let startTs: Int64
            let endTs: Int64
            let durationNs: Int64
        }

        struct Capabilities: Decodable {
            let cpuScheduling: Bool
            let threadStates: Bool
            let namedSlices: Bool
            let cpuCounters: Bool
            let processCounters: Bool
        }

        struct Fixture: Decodable {
            let name: String
            let upstreamPath: String
            let upstreamBlob: String
            let sourceSHA256: String
            let sourceByteCount: Int64
            let databaseSHA256: String
            let databaseByteCount: Int64
            let traceRange: TraceRange
            let rowCounts: [String: Int64]
            let capabilities: Capabilities
            let quickCheck: String
            let metaTablePresent: Bool
            let deterministicExportRuns: Int
        }

        let formatVersion: Int
        let upstream: Upstream
        let parser: Parser
        let schemaAdapterVersion: String
        let schemaFingerprint: String
        let schemaTableCount: Int
        let fixtures: [Fixture]
    }

    private enum SchemaEvidenceValidationError: Error {
        case unsupportedFormatVersion(Int)
        case invalidFixtureProvenance(String)
    }

    private final class CancellationBarrier: @unchecked Sendable {
        private let lock = NSLock()
        private var reached = false

        func pauseUntilCancelled() async {
            lock.withLock { reached = true }
            while !Task.isCancelled {
                await Task.yield()
            }
        }

        func waitUntilReached() async {
            while true {
                let current = lock.withLock { reached }
                if current { return }
                await Task.yield()
            }
        }
    }

    private final class BlockingCancellationBarrier: @unchecked Sendable {
        private let reached = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)

        func pauseUntilReleased() {
            reached.signal()
            release.wait()
        }

        private func waitBlocking() {
            reached.wait()
        }

        func waitUntilReached() async {
            await Task.detached { self.waitBlocking() }.value
        }

        func resume() {
            release.signal()
        }
    }

    private final class BlockingStageBarrier: @unchecked Sendable {
        private let target: TraceLoadingStage
        private let lock = NSLock()
        private let reached = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private var didPause = false

        init(_ target: TraceLoadingStage) {
            self.target = target
        }

        func record(_ stage: TraceLoadingStage) {
            guard stage == target else { return }
            let shouldPause = lock.withLock {
                guard !didPause else { return false }
                didPause = true
                return true
            }
            guard shouldPause else { return }
            reached.signal()
            release.wait()
        }

        private func waitBlocking() {
            reached.wait()
        }

        func waitUntilReached() async {
            await Task.detached { self.waitBlocking() }.value
        }

        func resume() {
            release.signal()
        }
    }

    private final class ProcessLaunchBarrier: @unchecked Sendable {
        private let release = DispatchSemaphore(value: 0)

        func record(_: pid_t) {
            release.wait()
        }

        func resume() { release.signal() }
    }

    private enum ProcessLaunchEvent: Sendable {
        case launched(pid_t)
        case openCompleted
    }

    private enum ProcessLaunchWaitError: Error {
        case timedOut
        case eventStreamEnded
    }

    private static func firstProcessLaunchEvent(
        from events: AsyncStream<ProcessLaunchEvent>,
        timeout: Duration
    ) async throws -> ProcessLaunchEvent {
        try await withThrowingTaskGroup(of: ProcessLaunchEvent.self) { group in
            group.addTask {
                for await event in events { return event }
                throw ProcessLaunchWaitError.eventStreamEnded
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProcessLaunchWaitError.timedOut
            }
            guard let event = try await group.next() else {
                throw ProcessLaunchWaitError.eventStreamEnded
            }
            group.cancelAll()
            return event
        }
    }

    private final class StageRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stages: [TraceLoadingStage] = []

        func append(_ stage: TraceLoadingStage) {
            lock.withLock { stages.append(stage) }
        }

        func snapshot() -> [TraceLoadingStage] {
            lock.withLock { stages }
        }
    }

    private final class CountingParser: TraceParser, @unchecked Sendable {
        private let lock = NSLock()
        private let base: TraceStreamerProcessParser
        private var parseCalls = 0
        private var identityCalls = 0
        private var cacheIdentityCalls = 0
        private let processCounterURL: URL?

        init(base: TraceStreamerProcessParser, processCounterURL: URL? = nil) {
            self.base = base
            self.processCounterURL = processCounterURL
        }

        func identity() async throws -> TraceParserIdentity {
            lock.withLock { identityCalls += 1 }
            return try await base.identity()
        }

        func cacheIdentity() async throws -> TraceParserIdentity {
            lock.withLock { cacheIdentityCalls += 1 }
            return try await base.cacheIdentity()
        }

        func parse(
            source: URL,
            destination: URL,
            progress: TraceProgressHandler?,
            prepareDatabase: @escaping TraceDatabasePreparer
        ) async throws -> ParsedTrace {
            lock.withLock { parseCalls += 1 }
            if let processCounterURL {
                let descriptor = processCounterURL.path.withCString {
                    Darwin.open($0, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
                }
                guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
                defer { _ = Darwin.close(descriptor) }
                var marker = UInt8(ascii: "1")
                guard Darwin.write(descriptor, &marker, 1) == 1,
                    Darwin.fsync(descriptor) == 0
                else { throw CocoaError(.fileWriteUnknown) }
            }
            return try await base.parse(
                source: source,
                destination: destination,
                progress: progress,
                prepareDatabase: prepareDatabase
            )
        }

        func count() -> Int {
            lock.withLock { parseCalls }
        }

        func identityCount() -> Int {
            lock.withLock { identityCalls }
        }

        func cacheIdentityCount() -> Int {
            lock.withLock { cacheIdentityCalls }
        }
    }

    private final class PromotionBarrier: @unchecked Sendable {
        private let lock = NSLock()
        private let reached = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private var observedURL: URL?

        func pause(at url: URL) {
            lock.withLock { observedURL = url }
            reached.signal()
            release.wait()
        }

        private func waitBlocking() {
            reached.wait()
        }

        func waitUntilReached() async -> URL {
            await Task.detached { self.waitBlocking() }.value
            return lock.withLock { observedURL! }
        }

        func resume() {
            release.signal()
        }

        func hasReached() -> Bool {
            lock.withLock { observedURL != nil }
        }
    }

    private final class OneShotSignal: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)

        func signal() {
            semaphore.signal()
        }

        private func waitBlocking() {
            semaphore.wait()
        }

        func wait() async {
            await Task.detached { self.waitBlocking() }.value
        }
    }

    private final class URLRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var value: URL?

        func record(_ url: URL) {
            lock.withLock { value = url }
        }

        func snapshot() -> URL? {
            lock.withLock { value }
        }
    }

    private final class OneShotFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var available = true

        func take() -> Bool {
            lock.withLock {
                guard available else { return false }
                available = false
                return true
            }
        }
    }

    private final class BlockingOneShotProbeFailure: @unchecked Sendable {
        private let lock = NSLock()
        private let reached = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private var invocationCount = 0

        func invoke(_: URL) throws {
            let shouldFail = lock.withLock {
                invocationCount += 1
                return invocationCount == 1
            }
            guard shouldFail else { return }
            reached.signal()
            release.wait()
            throw CocoaError(.fileReadNoPermission)
        }

        private func waitBlocking() {
            reached.wait()
        }

        func waitUntilReached() async {
            await Task.detached { self.waitBlocking() }.value
        }

        func resume() {
            release.signal()
        }

        func count() -> Int {
            lock.withLock { invocationCount }
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        private let lock = NSLock()
        private var terminationStatus: Int32?
        private var waiters: [CheckedContinuation<Int32, Never>] = []

        init(_ process: Process) {
            self.process = process
            process.terminationHandler = { [weak self] process in
                self?.finish(status: process.terminationStatus)
            }
        }

        func wait() async -> Int32 {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let terminationStatus {
                    lock.unlock()
                    continuation.resume(returning: terminationStatus)
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        private func finish(status: Int32) {
            lock.lock()
            guard terminationStatus == nil else {
                lock.unlock()
                return
            }
            terminationStatus = status
            let waiters = waiters
            self.waiters.removeAll()
            lock.unlock()
            for waiter in waiters { waiter.resume(returning: status) }
        }
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ParserIntegrationTests.swift
            .deletingLastPathComponent()  // ArkTraceIntegrationTests
            .deletingLastPathComponent()  // Tests
    }

    private static func traceStreamerURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["ARKTRACE_TRACE_STREAMER"].map(URL.init(fileURLWithPath:)),
            repoRoot.appendingPathComponent("ThirdParty/TraceStreamer/macx/trace_streamer"),
        ]
        return candidates.compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func fixtureURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["ARKTRACE_TEST_TRACE"].map(URL.init(fileURLWithPath:)),
            repoRoot.appendingPathComponent("Fixtures/traces/hiprofiler_data_ability.htrace"),
        ]
        return candidates.compactMap { $0 }
            .first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    private static var evidenceURL: URL {
        repoRoot.appendingPathComponent(
            "Fixtures/databases/trace_streamer_4.3.7.schema-evidence.json")
    }

    private static let lockedFixtureProvenance: [
        String: (upstreamPath: String, upstreamBlob: String)
    ] = [
        "trace_small_10.systrace": (
            "smartperf_host/trace_streamer/test/resource/trace_small_10.systrace",
            "0c9acff0ca12c3501d4a4235a6dc4efbd95475d4"
        ),
        "zlib.htrace": (
            "smartperf_host/trace_streamer/test/resource/zlib.htrace",
            "42775ede9bc79cea920760e8f6e3904b86fb711d"
        ),
    ]
    private static let requiredRowCountTables: Set<String> = [
        "trace_range", "process", "thread", "sched_slice", "thread_state", "callstack",
    ]
    private static let lockedLicenseProvenance = (
        path: "Fixtures/traces/LICENSE.Apache-2.0.txt",
        blob: "261eeb9e9f8b2b4b0d119366dda99c6fd7d35c64",
        sha256: "c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4",
        byteCount: Int64(11_357)
    )

    private static func decodeLockedEvidence(from data: Data) throws -> SchemaEvidence {
        let evidence = try JSONDecoder().decode(SchemaEvidence.self, from: data)
        guard evidence.formatVersion == 1 else {
            throw SchemaEvidenceValidationError.unsupportedFormatVersion(evidence.formatVersion)
        }
        guard evidence.fixtures.count == lockedFixtureProvenance.count else {
            throw SchemaEvidenceValidationError.invalidFixtureProvenance("fixtureSet")
        }
        guard evidence.upstream.license == "Apache-2.0",
            evidence.upstream.licensePath == lockedLicenseProvenance.path,
            evidence.upstream.licenseBlob == lockedLicenseProvenance.blob,
            evidence.upstream.licenseSHA256 == lockedLicenseProvenance.sha256,
            evidence.upstream.licenseByteCount == lockedLicenseProvenance.byteCount
        else {
            throw SchemaEvidenceValidationError.invalidFixtureProvenance("license")
        }
        for fixture in evidence.fixtures {
            guard let expected = lockedFixtureProvenance[fixture.name],
                fixture.upstreamPath == expected.upstreamPath,
                fixture.upstreamBlob == expected.upstreamBlob,
                Set(fixture.rowCounts.keys) == requiredRowCountTables
            else {
                throw SchemaEvidenceValidationError.invalidFixtureProvenance(fixture.name)
            }
        }
        return evidence
    }

    private static func lockedEvidence() throws -> SchemaEvidence {
        try decodeLockedEvidence(from: Data(contentsOf: evidenceURL))
    }

    private static func lockedFixtureURL(named name: String) -> URL {
        repoRoot.appendingPathComponent("Fixtures/traces/\(name)")
    }

    private func sha256AndSize(
        at url: URL,
        maximumByteCount: Int64 = .max,
        afterOpen: (() throws -> Void)? = nil
    ) throws -> (sha256: String, byteCount: Int64) {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw ArkTraceError(
                code: .internalError, stage: .hashing,
                message: "Fixture could not be opened"
            )
        }
        defer { _ = Darwin.close(descriptor) }
        var initial = stat()
        guard Darwin.fstat(descriptor, &initial) == 0,
            initial.st_mode & S_IFMT == S_IFREG,
            initial.st_size >= 0, initial.st_size <= maximumByteCount
        else {
            throw ArkTraceError(
                code: .internalError, stage: .hashing,
                message: "Fixture size or type is invalid"
            )
        }
        try afterOpen?()
        var hasher = SHA256()
        var byteCount: Int64 = 0
        var remaining = Int64(initial.st_size)
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while remaining > 0 {
            let requested = min(buffer.count, Int(remaining))
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, requested)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw ArkTraceError(
                    code: .internalError,
                    stage: .hashing,
                    message: "Fixture changed while hashing"
                )
            }
            byteCount += Int64(count)
            remaining -= Int64(count)
            hasher.update(data: Data(buffer.prefix(count)))
        }
        var extra: UInt8 = 0
        guard Darwin.read(descriptor, &extra, 1) == 0 else {
            throw ArkTraceError(
                code: .internalError, stage: .hashing,
                message: "Fixture grew while hashing"
            )
        }
        var final = stat()
        guard Darwin.fstat(descriptor, &final) == 0,
            initial.st_dev == final.st_dev,
            initial.st_ino == final.st_ino,
            initial.st_size == final.st_size,
            initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
            initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
            initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec,
            initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec
        else {
            throw ArkTraceError(
                code: .internalError, stage: .hashing,
                message: "Fixture changed while hashing"
            )
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (hash, byteCount)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func percentile(_ values: [Double], fraction: Double) -> Double {
        precondition(!values.isEmpty)
        let sorted = values.sorted()
        let rank = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))
        return sorted[rank]
    }

    func testPhase3PerformanceEvidenceWindowsClampExtremeEventRanges() throws {
        let nearMaximum = try TraceTimeRange.query(
            startNs: Int64.max - 10, endNs: Int64.max
        )
        let maximumWindow = try Self.clampedWindow(
            around: nearMaximum,
            padding: 50_000_000,
            traceDurationNs: Int64.max
        )
        XCTAssertEqual(maximumWindow.endNs, Int64.max)
        XCTAssertGreaterThan(maximumWindow.endNs, maximumWindow.startNs)

        let origin = try TraceTimeRange.query(startNs: 0, endNs: 1)
        let originWindow = try Self.clampedWindow(
            around: origin,
            padding: 50_000_000,
            traceDurationNs: 100
        )
        XCTAssertEqual(originWindow, try TraceTimeRange.query(startNs: 0, endNs: 100))
    }

    func testPhase3StreamingIdentityRejectsGrowthBeyondInitialSize() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-identity-growth-\(UUID().uuidString)")
        let file = root.appendingPathComponent("trace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("initial".utf8).write(to: file)
        XCTAssertThrowsError(try sha256AndSize(
            at: file,
            maximumByteCount: 1_024,
            afterOpen: {
                let handle = try FileHandle(forWritingTo: file)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(repeating: 0x41, count: 64))
                try handle.close()
            }
        ))
    }

    func testProcessLaunchWaitStopsWhenOpenCompletesBeforeLaunchHook() async throws {
        let (events, continuation) = AsyncStream.makeStream(of: ProcessLaunchEvent.self)
        continuation.yield(.openCompleted)
        continuation.finish()
        let start = ContinuousClock.now
        let event = try await Self.firstProcessLaunchEvent(
            from: events, timeout: .seconds(1)
        )
        guard case .openCompleted = event else {
            return XCTFail("completion must win when no process was launched")
        }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(250))
    }

    private static func clampedWindow(
        around range: TraceTimeRange,
        padding: Int64,
        traceDurationNs: Int64
    ) throws -> TraceTimeRange {
        let startCandidate = range.startNs.subtractingReportingOverflow(padding)
        let endCandidate = range.endNs.addingReportingOverflow(padding)
        let start = max(0, startCandidate.overflow ? 0 : startCandidate.partialValue)
        let end = min(
            traceDurationNs,
            endCandidate.overflow ? traceDurationNs : endCandidate.partialValue
        )
        if end > start { return try TraceTimeRange.query(startNs: start, endNs: end) }
        let fallbackStart = min(max(0, range.startNs), max(0, traceDurationNs - 1))
        return try TraceTimeRange.query(
            startNs: fallbackStart,
            endNs: traceDurationNs
        )
    }

    func testPhase3ViewportPercentilesDoNotDiluteAutomaticLoaderTail() {
        let sixFastQueryFamilies = Array(repeating: 1.0, count: 120)
        let loader = Array(repeating: 2.0, count: 18) + [700.0, 900.0]
        XCTAssertEqual(Self.percentile(sixFastQueryFamilies + loader, fraction: 0.95), 2.0)
        XCTAssertEqual(Self.percentile(loader, fraction: 0.95), 700.0)
    }

    private static func sysctlString(_ name: String) -> String? {
        var byteCount = 0
        guard sysctlbyname(name, nil, &byteCount, nil, 0) == 0, byteCount > 1,
            byteCount <= 4_096
        else { return nil }
        var bytes = [CChar](repeating: 0, count: byteCount)
        guard sysctlbyname(name, &bytes, &byteCount, nil, 0) == 0 else { return nil }
        return String(
            decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    private static func machineArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private func gitBlobOID(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func rowCount(_ table: String, in db: TraceDatabase) throws -> Int64 {
        let rows = try db.query("SELECT COUNT(*) FROM \(table)") { $0.int64(0) ?? -1 }
        return try XCTUnwrap(rows.first)
    }

    private func assertLockedFixture(_ fixture: SchemaEvidence.Fixture) async throws {
        guard let binary = Self.traceStreamerURL() else {
            throw XCTSkip("trace_streamer binary not available; set ARKTRACE_TRACE_STREAMER")
        }
        let source = Self.lockedFixtureURL(named: fixture.name)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: source.path))
        let sourceIdentity = try sha256AndSize(at: source)
        XCTAssertEqual(sourceIdentity.sha256, fixture.sourceSHA256)
        XCTAssertEqual(sourceIdentity.byteCount, fixture.sourceByteCount)
        XCTAssertEqual(try gitBlobOID(at: source), fixture.upstreamBlob)

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-evidence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let session = try await TraceSession.open(
            source: source,
            parser: try TraceStreamerProcessParser(executableURL: binary),
            stagingDirectory: staging
        )
        let evidence = try Self.lockedEvidence()
        let metadata = try await session.repository.metadata()
        let parsed = await session.parsed
        XCTAssertEqual(metadata.traceSHA256, fixture.sourceSHA256)
        XCTAssertEqual(metadata.sourceByteCount, fixture.sourceByteCount)
        XCTAssertEqual(metadata.schemaFingerprint, evidence.schemaFingerprint)
        XCTAssertEqual(metadata.durationNs, fixture.traceRange.durationNs)
        XCTAssertEqual(metadata.capabilities.cpuScheduling, fixture.capabilities.cpuScheduling)
        XCTAssertEqual(metadata.capabilities.threadStates, fixture.capabilities.threadStates)
        XCTAssertEqual(metadata.capabilities.namedSlices, fixture.capabilities.namedSlices)
        XCTAssertEqual(metadata.capabilities.cpuCounters, fixture.capabilities.cpuCounters)
        XCTAssertEqual(metadata.capabilities.processCounters, fixture.capabilities.processCounters)
        XCTAssertEqual(
            metadata.parser,
            TraceParserIdentity(
                name: "trace_streamer",
                reportedVersion: evidence.parser.reportedVersion,
                binarySHA256: evidence.parser.binarySHA256,
                upstreamRepository: evidence.upstream.repository,
                upstreamRevision: evidence.upstream.revision,
                architecture: evidence.parser.architecture,
                adapterVersion: evidence.parser.adapterVersion,
                buildRecipeVersion: evidence.parser.buildRecipeVersion
            )
        )

        let db = try TraceDatabase(url: parsed.databaseURL, readOnly: true)
        XCTAssertTrue(try db.quickCheckIsOK())
        let tables = try db.tableNames()
        XCTAssertEqual(tables.count, evidence.schemaTableCount)
        XCTAssertEqual(tables.contains("meta"), fixture.metaTablePresent)
        for (table, expectedCount) in fixture.rowCounts {
            XCTAssertEqual(try rowCount(table, in: db), expectedCount, "row count for \(table)")
        }
        let ranges = try db.query(
            "SELECT start_ts, end_ts FROM trace_range",
            stage: .validating
        ) { ($0.int64(0), $0.int64(1)) }
        XCTAssertEqual(ranges.first?.0, fixture.traceRange.startTs)
        XCTAssertEqual(ranges.first?.1, fixture.traceRange.endTs)

        let indexNames = Set(try db.query(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name GLOB 'arktrace_v*'"
        ) { $0.text(0) }.compactMap { $0 })
        XCTAssertTrue(
            TraceDatabaseStagingPreparer.requiredIndexNames.isSubset(of: indexNames),
            "missing versioned indexes: \(TraceDatabaseStagingPreparer.requiredIndexNames.subtracting(indexNames))"
        )
        XCTAssertTrue(
            indexNames.contains("arktrace_v1_thread_state_ts_cpu"),
            "locked upstream schema includes optional thread_state.cpu and must index it"
        )
        let plans = [
            ("SELECT ipid FROM process WHERE ipid = 1", "arktrace_v1_process_ipid"),
            ("SELECT itid FROM thread WHERE itid = 1", "arktrace_v1_thread_itid"),
            (
                "SELECT ts FROM sched_slice WHERE itid = 1 AND ts >= 0",
                "arktrace_v1_sched_slice_itid_ts"
            ),
            (
                "SELECT ts FROM thread_state WHERE itid = 1 AND ts >= 0",
                "arktrace_v1_thread_state_itid_ts"
            ),
            (
                "SELECT ts FROM callstack WHERE callid = 1 AND ts >= 0",
                "arktrace_v2_callstack_callid_ts_id_dur"
            ),
        ]
        for (sql, indexName) in plans {
            let plan = try db.query("EXPLAIN QUERY PLAN \(sql)") {
                $0.text(3) ?? ""
            }.joined(separator: " ")
            XCTAssertTrue(plan.contains(indexName), plan)
        }

        XCTAssertEqual(
            parsed.databasePreparation.upstreamDatabaseSHA256,
            fixture.databaseSHA256
        )
        XCTAssertEqual(
            parsed.databasePreparation.upstreamDatabaseByteCount,
            fixture.databaseByteCount
        )
        let databaseBytes = try Data(contentsOf: parsed.databaseURL)
        let sidecarBytes = try Data(contentsOf: parsed.metadataSidecarURL)
        XCTAssertNil(databaseBytes.range(of: Data(source.path.utf8)))
        XCTAssertNil(databaseBytes.range(of: Data(staging.path.utf8)))
        XCTAssertNil(sidecarBytes.range(of: Data(source.path.utf8)))
        XCTAssertNil(sidecarBytes.range(of: Data(staging.path.utf8)))

        let fullRange = try TraceTimeRange.query(
            startNs: 0,
            endNs: metadata.durationNs
        )
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        if metadata.capabilities.cpuScheduling {
            let slices = try await session.repository.cpuSlices(
                CpuSliceQuery(
                    range: fullRange,
                    limit: 8,
                    deadline: deadline
                )
            )
            XCTAssertTrue(slices.capabilityAvailable)
            XCTAssertFalse(slices.items.isEmpty)
            XCTAssertTrue(zip(slices.items, slices.items.dropFirst()).allSatisfy {
                $0.startNs < $1.startNs
                    || ($0.startNs == $1.startNs && $0.key.rowID < $1.key.rowID)
            })
            XCTAssertTrue(slices.items.allSatisfy { $0.key.table == .schedSlice })

            let states = try await session.repository.threadStates(
                ThreadStateQuery(
                    range: fullRange,
                    limit: 8,
                    deadline: deadline
                )
            )
            XCTAssertTrue(states.capabilityAvailable)
            XCTAssertFalse(states.items.isEmpty)
        }
        if metadata.capabilities.namedSlices {
            let slices = try await session.repository.slices(
                TraceSliceQuery(
                    range: fullRange,
                    limit: 8,
                    deadline: deadline
                )
            )
            XCTAssertTrue(slices.capabilityAvailable)
            XCTAssertFalse(slices.items.isEmpty)
            XCTAssertTrue(slices.items.allSatisfy { $0.key.table == .callstack })
        }
        if metadata.capabilities.cpuScheduling || metadata.capabilities.namedSlices {
            let densitySource: TraceDensitySource = metadata.capabilities.cpuScheduling
                ? .cpu(0) : .namedSlice(ThreadKey(itid: 1))
            let density = try await session.repository.density(
                TraceDensityQuery(
                    range: fullRange,
                    source: densitySource,
                    bucketCount: 32,
                    deadline: deadline
                )
            )
            XCTAssertTrue(density.capabilityAvailable)
            XCTAssertLessThanOrEqual(density.buckets.count, 32)
        }
    }

    private func requireEnvironment() throws -> (binary: URL, fixture: URL) {
        guard let binary = Self.traceStreamerURL() else {
            throw XCTSkip("trace_streamer binary not available; set ARKTRACE_TRACE_STREAMER")
        }
        guard let fixture = Self.fixtureURL() else {
            throw XCTSkip("trace fixture not available; set ARKTRACE_TEST_TRACE")
        }
        return (binary, fixture)
    }

    private func requireCacheEnvironment() throws -> (binary: URL, fixture: URL) {
        guard let binary = Self.traceStreamerURL() else {
            throw XCTSkip("trace_streamer binary not available; set ARKTRACE_TRACE_STREAMER")
        }
        let fixture = Self.lockedFixtureURL(named: "zlib.htrace")
        guard FileManager.default.isReadableFile(atPath: fixture.path) else {
            throw XCTSkip("locked zlib trace fixture is unavailable")
        }
        return (binary, fixture)
    }

    private func permissions(at url: URL) throws -> mode_t {
        var info = stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return info.st_mode & 0o777
    }

    private func publicSessionEntries(at root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
            $0.hasPrefix("session-") || $0.hasPrefix(".arktrace-cleanup-")
        }
    }

    private func launchCacheWorker(
        action: String,
        root: URL,
        binary: URL,
        fixture: URL,
        result: URL? = nil,
        ready: URL? = nil,
        release: URL? = nil,
        counter: URL? = nil
    ) throws -> ProcessBox {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "ArkTraceIntegrationTests.ParserIntegrationTests/testCacheCrossProcessWorker",
            Bundle(for: ParserIntegrationTests.self).bundleURL.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["ARKTRACE_CACHE_WORKER_ACTION"] = action
        environment["ARKTRACE_CACHE_WORKER_ROOT"] = root.path
        environment["ARKTRACE_CACHE_WORKER_BINARY"] = binary.path
        environment["ARKTRACE_CACHE_WORKER_FIXTURE"] = fixture.path
        environment["ARKTRACE_CACHE_WORKER_RESULT"] = result?.path
        environment["ARKTRACE_CACHE_WORKER_READY"] = ready?.path
        environment["ARKTRACE_CACHE_WORKER_RELEASE"] = release?.path
        environment["ARKTRACE_CACHE_WORKER_COUNTER"] = counter?.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let box = ProcessBox(process)
        try process.run()
        return box
    }

    private func waitForFile(_ url: URL, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else {
                throw CocoaError(.fileReadUnknown)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func cacheMetadata(in cache: URL) throws -> TraceCacheMetadata {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil)
        )
        var metadataURL: URL?
        while let item = enumerator.nextObject() as? URL {
            if item.lastPathComponent == "metadata.json" {
                metadataURL = item
                break
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            TraceCacheMetadata.self,
            from: Data(contentsOf: try XCTUnwrap(metadataURL))
        )
    }

    private func canAcquireExclusiveLock(at url: URL) -> Bool {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }
        guard arkTraceTestFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        _ = arkTraceTestFlock(descriptor, LOCK_UN)
        return true
    }

    private static func replacePromotionBuild(at build: URL) throws {
        let displaced = build.deletingLastPathComponent()
            .appendingPathComponent(
                ".displaced-\(build.lastPathComponent)",
                isDirectory: true
            )
        try FileManager.default.moveItem(at: build, to: displaced)
        try FileManager.default.createDirectory(
            at: build,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("replacement".utf8).write(
            to: build.appendingPathComponent("marker")
        )
    }

    func testParserIdentity() async throws {
        let (binary, _) = try requireEnvironment()
        let parser = try TraceStreamerProcessParser(executableURL: binary)
        let identity = try await parser.identity()
        XCTAssertEqual(identity.name, "trace_streamer")
        XCTAssertEqual(identity.binarySHA256.count, 64)
        XCTAssertEqual(identity.reportedVersion, "4.3.7")
        XCTAssertEqual(
            identity.upstreamRepository,
            TraceStreamerProcessParser.expectedUpstreamRepository
        )
        XCTAssertEqual(
            identity.upstreamRevision,
            TraceStreamerProcessParser.expectedUpstreamRevision
        )
        XCTAssertEqual(identity.architecture, "arm64")
        XCTAssertEqual(identity.adapterVersion, TraceStreamerProcessParser.adapterVersion)
        XCTAssertEqual(
            identity.buildRecipeVersion,
            TraceStreamerProcessParser.supportedBuildRecipeVersion
        )
    }

    func testLockedSchemaEvidenceMatchesPinnedUpstreamAndManifest() throws {
        guard let binary = Self.traceStreamerURL() else {
            throw XCTSkip("trace_streamer binary not available; set ARKTRACE_TRACE_STREAMER")
        }
        let evidence = try Self.lockedEvidence()
        let manifest = try TraceStreamerManifest.load(
            from: binary.deletingLastPathComponent().appendingPathComponent("manifest.json")
        )
        let actualBinary = try sha256AndSize(at: binary)
        XCTAssertEqual(evidence.formatVersion, 1)
        XCTAssertEqual(
            evidence.upstream.repository,
            TraceStreamerProcessParser.expectedUpstreamRepository
        )
        XCTAssertEqual(
            evidence.upstream.revision,
            TraceStreamerProcessParser.expectedUpstreamRevision
        )
        XCTAssertEqual(evidence.upstream.license, "Apache-2.0")
        XCTAssertEqual(evidence.upstream.licensePath, Self.lockedLicenseProvenance.path)
        XCTAssertEqual(evidence.upstream.licenseBlob, Self.lockedLicenseProvenance.blob)
        XCTAssertEqual(evidence.upstream.licenseSHA256, Self.lockedLicenseProvenance.sha256)
        XCTAssertEqual(evidence.upstream.licenseByteCount, Self.lockedLicenseProvenance.byteCount)
        XCTAssertEqual(actualBinary.sha256, evidence.parser.binarySHA256)
        XCTAssertEqual(manifest.name, "trace_streamer")
        XCTAssertEqual(manifest.binarySHA256, actualBinary.sha256)
        XCTAssertEqual(manifest.binarySHA256, evidence.parser.binarySHA256)
        XCTAssertEqual(manifest.reportedVersion, evidence.parser.reportedVersion)
        XCTAssertEqual(manifest.upstreamRepository, evidence.upstream.repository)
        XCTAssertEqual(manifest.upstreamRevision, evidence.upstream.revision)
        XCTAssertEqual(manifest.architecture, evidence.parser.architecture)
        XCTAssertEqual(manifest.adapterVersion, evidence.parser.adapterVersion)
        XCTAssertEqual(manifest.buildRecipeVersion, evidence.parser.buildRecipeVersion)
        XCTAssertEqual(evidence.parser.reportedVersion, "4.3.7")
        XCTAssertEqual(evidence.parser.architecture, "arm64")
        XCTAssertEqual(
            evidence.parser.adapterVersion,
            TraceStreamerProcessParser.adapterVersion
        )
        XCTAssertEqual(evidence.schemaAdapterVersion, TraceSchemaAdapter.version)
        XCTAssertEqual(
            evidence.parser.buildRecipeVersion,
            TraceStreamerProcessParser.supportedBuildRecipeVersion
        )
        XCTAssertEqual(evidence.schemaFingerprint.count, 64)
        XCTAssertEqual(Set(evidence.fixtures.map(\.name)), [
            "trace_small_10.systrace", "zlib.htrace",
        ])
        XCTAssertTrue(evidence.fixtures.contains { $0.capabilities.cpuScheduling })
        XCTAssertTrue(evidence.fixtures.contains { $0.capabilities.threadStates })
        XCTAssertTrue(evidence.fixtures.contains { $0.capabilities.namedSlices })
        XCTAssertTrue(evidence.fixtures.allSatisfy { !$0.capabilities.cpuCounters })
        XCTAssertTrue(evidence.fixtures.allSatisfy { !$0.capabilities.processCounters })
        for fixture in evidence.fixtures {
            let provenance = try XCTUnwrap(Self.lockedFixtureProvenance[fixture.name])
            XCTAssertEqual(fixture.upstreamPath, provenance.upstreamPath)
            XCTAssertEqual(fixture.upstreamBlob, provenance.upstreamBlob)
            XCTAssertEqual(fixture.quickCheck, "ok")
            XCTAssertFalse(fixture.metaTablePresent)
            XCTAssertGreaterThanOrEqual(fixture.deterministicExportRuns, 2)
        }
    }

    func testLockedEvidenceFormatAndProvenanceFailClosed() throws {
        let originalData = try Data(contentsOf: Self.evidenceURL)
        let originalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: originalData) as? [String: Any]
        )
        let evidence = try Self.decodeLockedEvidence(from: originalData)
        for fixture in evidence.fixtures {
            let fixtureURL = Self.lockedFixtureURL(named: fixture.name)
            XCTAssertEqual(try gitBlobOID(at: fixtureURL), fixture.upstreamBlob)
        }
        let licenseURL = Self.repoRoot.appendingPathComponent(evidence.upstream.licensePath)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: licenseURL.path))
        let licenseIdentity = try sha256AndSize(at: licenseURL)
        XCTAssertEqual(licenseIdentity.sha256, evidence.upstream.licenseSHA256)
        XCTAssertEqual(licenseIdentity.byteCount, evidence.upstream.licenseByteCount)
        XCTAssertEqual(try gitBlobOID(at: licenseURL), evidence.upstream.licenseBlob)

        var unsupportedVersion = originalObject
        unsupportedVersion["formatVersion"] = 999
        XCTAssertThrowsError(
            try Self.decodeLockedEvidence(
                from: JSONSerialization.data(withJSONObject: unsupportedVersion)
            )
        )

        var missingVersion = originalObject
        missingVersion.removeValue(forKey: "formatVersion")
        XCTAssertThrowsError(
            try Self.decodeLockedEvidence(
                from: JSONSerialization.data(withJSONObject: missingVersion)
            )
        )

        for mutation in [
            (key: "upstreamPath", value: "arbitrary/path.htrace"),
            (key: "upstreamBlob", value: String(repeating: "a", count: 40)),
        ] {
            var invalidProvenance = originalObject
            var fixtures = try XCTUnwrap(
                invalidProvenance["fixtures"] as? [[String: Any]]
            )
            fixtures[0][mutation.key] = mutation.value
            invalidProvenance["fixtures"] = fixtures
            XCTAssertThrowsError(
                try Self.decodeLockedEvidence(
                    from: JSONSerialization.data(withJSONObject: invalidProvenance)
                ),
                "\(mutation.key) drift must fail closed"
            )
        }

        var missingRequiredRowCount = originalObject
        var fixtures = try XCTUnwrap(
            missingRequiredRowCount["fixtures"] as? [[String: Any]]
        )
        var rowCounts = try XCTUnwrap(fixtures[0]["rowCounts"] as? [String: Any])
        rowCounts.removeValue(forKey: "process")
        fixtures[0]["rowCounts"] = rowCounts
        missingRequiredRowCount["fixtures"] = fixtures
        XCTAssertThrowsError(
            try Self.decodeLockedEvidence(
                from: JSONSerialization.data(withJSONObject: missingRequiredRowCount)
            )
        )

        var invalidLicenseBlob = originalObject
        var upstream = try XCTUnwrap(invalidLicenseBlob["upstream"] as? [String: Any])
        upstream["licenseBlob"] = String(repeating: "a", count: 40)
        invalidLicenseBlob["upstream"] = upstream
        XCTAssertThrowsError(
            try Self.decodeLockedEvidence(
                from: JSONSerialization.data(withJSONObject: invalidLicenseBlob)
            )
        )
    }

    func testRealSchedulingFixtureMatchesLockedSchemaEvidence() async throws {
        let fixture = try XCTUnwrap(
            Self.lockedEvidence().fixtures.first { $0.name == "trace_small_10.systrace" }
        )
        XCTAssertGreaterThan(fixture.rowCounts["sched_slice"] ?? 0, 0)
        XCTAssertGreaterThan(fixture.rowCounts["thread_state"] ?? 0, 0)
        try await assertLockedFixture(fixture)
    }

    func testRealNamedSliceFixtureMatchesLockedSchemaEvidence() async throws {
        let fixture = try XCTUnwrap(
            Self.lockedEvidence().fixtures.first { $0.name == "zlib.htrace" }
        )
        XCTAssertGreaterThan(fixture.rowCounts["callstack"] ?? 0, 0)
        try await assertLockedFixture(fixture)
    }

    func testParseRealTraceAndQuery() async throws {
        let (binary, fixture) = try requireEnvironment()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        let session = try await TraceSession.open(
            source: fixture,
            parser: try TraceStreamerProcessParser(executableURL: binary),
            stagingDirectory: staging
        )

        let metadata = try await session.repository.metadata()
        let parsed = await session.parsed
        XCTAssertGreaterThan(metadata.durationNs, 0, "trace must have a positive duration")
        XCTAssertEqual(metadata.traceSHA256.count, 64)
        XCTAssertEqual(metadata.schemaFingerprint.count, 64)
        let manifest = try TraceStreamerManifest.load(
            from: binary.deletingLastPathComponent().appendingPathComponent("manifest.json")
        )
        XCTAssertEqual(metadata.parser.binarySHA256, manifest.binarySHA256)
        XCTAssertEqual(metadata.parser.reportedVersion, manifest.reportedVersion)
        XCTAssertEqual(metadata.parser.upstreamRepository, manifest.upstreamRepository)
        XCTAssertEqual(metadata.parser.upstreamRevision, manifest.upstreamRevision)
        XCTAssertEqual(metadata.parser.architecture, manifest.architecture)
        XCTAssertEqual(metadata.parser.adapterVersion, manifest.adapterVersion)
        XCTAssertEqual(metadata.parser.buildRecipeVersion, manifest.buildRecipeVersion)
        XCTAssertEqual(
            parsed.databasePreparation.indexVersion,
            TraceDatabaseStagingPreparer.indexVersion
        )
        XCTAssertEqual(
            parsed.databasePreparation.schemaFingerprint,
            metadata.schemaFingerprint
        )
        let sidecarData = try Data(contentsOf: parsed.metadataSidecarURL)
        let sidecar = try JSONDecoder().decode(
            TraceDatabaseMetadataSidecar.self,
            from: sidecarData
        )
        XCTAssertEqual(sidecar.parser, parsed.parser)
        XCTAssertEqual(sidecar.sourceSHA256, parsed.sourceSHA256)
        XCTAssertEqual(sidecar.databasePreparation, parsed.databasePreparation)
        XCTAssertNil(sidecarData.range(of: Data(fixture.path.utf8)))
        XCTAssertNil(sidecarData.range(of: Data(staging.path.utf8)))

        let processes = try await session.repository.processes(ProcessQuery())
        XCTAssertFalse(processes.items.isEmpty, "a real trace exposes at least one process")

        let threads = try await session.repository.threads(ThreadQuery())
        XCTAssertFalse(threads.items.isEmpty, "a real trace exposes at least one thread")

        let firstPid = processes.items[0].pid
        let filtered = try await session.repository.processes(try ProcessQuery(pid: firstPid))
        XCTAssertTrue(filtered.items.allSatisfy { $0.pid == firstPid })
    }

    func testRealTraceSummaryIsDeterministicAndRangeScoped() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-summary-real-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let session = try await TraceSession.open(
            source: fixture,
            parser: try TraceStreamerProcessParser(executableURL: binary),
            stagingDirectory: staging
        )
        defer { Task { try? await session.close() } }
        let repository = await session.repository
        let engine = TraceSummaryEngine(repository: repository)
        let fullRequest = try TraceSummaryRequest(
            maximumRowsPerSection: 10_000,
            timeout: .seconds(30)
        )
        let full = try await engine.summarize(fullRequest)
        let metadata = try await repository.metadata()
        XCTAssertEqual(full.durationNs, metadata.durationNs)
        XCTAssertGreaterThan(full.processCount, 0)
        XCTAssertEqual(full.threadCount, 0)
        XCTAssertTrue(full.dataQuality.warnings.contains { $0.contains("threadCount is a lower bound") })
        XCTAssertGreaterThan(full.namedSliceCount ?? 0, 0)
        XCTAssertNil(full.cpuCount)
        XCTAssertNil(full.cpuSliceCount)
        XCTAssertNotNil(full.eventCountBySource)
        XCTAssertEqual(full.eventCountBySource?.reduce(0) { $0 + $1.count }, 6_138)
        XCTAssertTrue(full.dataQuality.warnings.contains { $0.contains("non-received") })

        let midpoint = metadata.durationNs / 2
        let scoped = try await engine.summarize(
            try TraceSummaryRequest(
                range: TraceTimeRange.query(startNs: 0, endNs: midpoint),
                maximumRowsPerSection: 10_000,
                timeout: .seconds(30)
            )
        )
        XCTAssertEqual(scoped.durationNs, midpoint)
        XCTAssertLessThanOrEqual(scoped.namedSliceCount ?? 0, full.namedSliceCount ?? 0)
        XCTAssertEqual(scoped.threadCount, 0)
        XCTAssertTrue(scoped.dataQuality.warnings.contains { $0.contains("lower bound") })
        XCTAssertNil(scoped.eventCountBySource)

        let first = try TraceSummaryJSONEncoder.encode(full)
        let second = try TraceSummaryJSONEncoder.encode(
            try await engine.summarize(fullRequest)
        )
        XCTAssertEqual(first, second)
        try await session.close()
    }

    func testPhase1ProgressReportsActualStagesInOrder() async throws {
        let (binary, fixture) = try requireEnvironment()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-progress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let recorder = StageRecorder()

        _ = try await TraceSession.open(
            source: fixture,
            parser: try TraceStreamerProcessParser(executableURL: binary),
            stagingDirectory: staging,
            progress: { recorder.append($0) }
        )

        XCTAssertEqual(recorder.snapshot(), [
            .preparing,
            .hashing,
            .parsing,
            .validating,
            .indexing,
            .openingDatabase,
            .ready,
        ])
    }

    func testPhase1GateWritesBoundedMachineEvidenceWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ARKTRACE_PHASE1_GATE"] == "1" else { return }
        let outputPath = try XCTUnwrap(environment["ARKTRACE_PHASE1_EVIDENCE_OUTPUT"])
        let outputURL = URL(fileURLWithPath: outputPath)
        let (binary, fixture) = try requireEnvironment()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let recorder = StageRecorder()
        let session = try await TraceSession.open(
            source: fixture,
            parser: try TraceStreamerProcessParser(executableURL: binary),
            stagingDirectory: staging,
            progress: { recorder.append($0) }
        )
        let parsed = await session.parsed
        let metadata = try await session.repository.metadata()
        let processes = try await session.repository.processes(ProcessQuery())
        let threads = try await session.repository.threads(ThreadQuery())
        let readyDatabase = try sha256AndSize(at: parsed.databaseURL)
        let db = try TraceDatabase(url: parsed.databaseURL, readOnly: true)
        let tables = try db.tableNames()
        let databaseBytes = try Data(contentsOf: parsed.databaseURL)
        let sidecarBytes = try Data(contentsOf: parsed.metadataSidecarURL)
        let pathsAbsent = databaseBytes.range(of: Data(fixture.path.utf8)) == nil
            && databaseBytes.range(of: Data(staging.path.utf8)) == nil
            && sidecarBytes.range(of: Data(fixture.path.utf8)) == nil
            && sidecarBytes.range(of: Data(staging.path.utf8)) == nil

        struct GateEvidence: Encodable {
            let formatVersion: Int
            let parserBinarySHA256: String
            let parserVersion: String
            let sourceSHA256: String
            let sourceByteCount: Int64
            let upstreamDatabaseSHA256: String
            let upstreamDatabaseByteCount: Int64
            let readyDatabaseSHA256: String
            let readyDatabaseByteCount: Int64
            let schemaFingerprint: String
            let schemaAdapterVersion: String
            let indexVersion: Int
            let durationNs: Int64
            let processSampleCount: Int
            let processSampleTruncated: Bool
            let threadSampleCount: Int
            let threadSampleTruncated: Bool
            let schemaTableCount: Int
            let quickCheck: String
            let metaTablePresent: Bool
            let pathsAbsent: Bool
            let stages: [String]
        }

        let evidence = GateEvidence(
            formatVersion: 1,
            parserBinarySHA256: metadata.parser.binarySHA256,
            parserVersion: metadata.parser.reportedVersion,
            sourceSHA256: metadata.traceSHA256,
            sourceByteCount: metadata.sourceByteCount,
            upstreamDatabaseSHA256: parsed.databasePreparation.upstreamDatabaseSHA256,
            upstreamDatabaseByteCount: parsed.databasePreparation.upstreamDatabaseByteCount,
            readyDatabaseSHA256: readyDatabase.sha256,
            readyDatabaseByteCount: readyDatabase.byteCount,
            schemaFingerprint: metadata.schemaFingerprint,
            schemaAdapterVersion: parsed.databasePreparation.schemaAdapterVersion,
            indexVersion: parsed.databasePreparation.indexVersion,
            durationNs: metadata.durationNs,
            processSampleCount: processes.items.count,
            processSampleTruncated: processes.truncated,
            threadSampleCount: threads.items.count,
            threadSampleTruncated: threads.truncated,
            schemaTableCount: tables.count,
            quickCheck: try db.quickCheckIsOK() ? "ok" : "failed",
            metaTablePresent: tables.contains("meta"),
            pathsAbsent: pathsAbsent,
            stages: recorder.snapshot().map(\.rawValue)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(evidence)
        XCTAssertLessThanOrEqual(data.count, 4_096)
        try data.write(to: outputURL, options: .atomic)
    }

    func testPhase2GateWritesCachedOpenBenchmarkEvidenceWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ARKTRACE_PHASE2_GATE"] == "1" else { return }
        let outputPath = try XCTUnwrap(environment["ARKTRACE_PHASE2_EVIDENCE_OUTPUT"])
        let outputURL = URL(fileURLWithPath: outputPath)
        let (binary, fixture) = try requireCacheEnvironment()
        let parser = try TraceStreamerProcessParser(executableURL: binary)
        let parserIdentity = try await parser.identity()
        let traceIdentity = try sha256AndSize(
            at: fixture, maximumByteCount: 2_147_483_648
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-phase2-benchmark-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let initial = try await TraceSession.open(
            source: fixture,
            parser: parser,
            stagingDirectory: staging,
            storagePolicy: .contentAddressed(cacheDirectory: cache)
        )
        let initialCacheHit = await initial.cacheHit
        let initialCacheMetadataValue = await initial.cacheMetadata
        XCTAssertFalse(initialCacheHit)
        let initialCacheMetadata = try XCTUnwrap(initialCacheMetadataValue)
        try await initial.close()

        let iterations = 20
        var openMilliseconds: [Double] = []
        var metadataMilliseconds: [Double] = []
        openMilliseconds.reserveCapacity(iterations)
        metadataMilliseconds.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let openStart = ContinuousClock.now
            let session = try await TraceSession.open(
                source: fixture,
                parser: parser,
                stagingDirectory: staging,
                storagePolicy: .contentAddressed(cacheDirectory: cache)
            )
            openMilliseconds.append(
                Self.milliseconds(openStart.duration(to: ContinuousClock.now))
            )
            let cacheHit = await session.cacheHit
            XCTAssertTrue(cacheHit)

            let metadataStart = ContinuousClock.now
            let metadata = try await session.repository.metadata()
            metadataMilliseconds.append(
                Self.milliseconds(metadataStart.duration(to: ContinuousClock.now))
            )
            XCTAssertEqual(metadata.traceSHA256, traceIdentity.sha256)
            try await session.close()
        }

        struct Phase2Evidence: Encodable {
            struct Machine: Encodable {
                let model: String
                let architecture: String
                let operatingSystem: String
                let physicalMemoryBytes: UInt64
            }

            let formatVersion: Int
            let arkTraceVersion: String
            let arkTraceBaseRevision: String
            let workingTreeDirty: Bool
            let machine: Machine
            let traceSHA256: String
            let traceByteCount: Int64
            let parserBinarySHA256: String
            let parserVersion: String
            let parserUpstreamRevision: String
            let databaseByteCount: Int64
            let iterations: Int
            let cacheOpenP50Ms: Double
            let cacheOpenP95Ms: Double
            let metadataP50Ms: Double
            let metadataP95Ms: Double
            let cacheHitCount: Int
        }

        let evidence = Phase2Evidence(
            formatVersion: 1,
            arkTraceVersion: "0.1.0",
            arkTraceBaseRevision: environment["ARKTRACE_BASE_REVISION"] ?? "unknown",
            workingTreeDirty: environment["ARKTRACE_WORKTREE_DIRTY"] == "1",
            machine: .init(
                model: Self.sysctlString("hw.model") ?? "unknown",
                architecture: Self.machineArchitecture(),
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
            ),
            traceSHA256: traceIdentity.sha256,
            traceByteCount: traceIdentity.byteCount,
            parserBinarySHA256: parserIdentity.binarySHA256,
            parserVersion: parserIdentity.reportedVersion,
            parserUpstreamRevision: parserIdentity.upstreamRevision,
            databaseByteCount: initialCacheMetadata.databaseByteCount,
            iterations: iterations,
            cacheOpenP50Ms: Self.percentile(openMilliseconds, fraction: 0.50),
            cacheOpenP95Ms: Self.percentile(openMilliseconds, fraction: 0.95),
            metadataP50Ms: Self.percentile(metadataMilliseconds, fraction: 0.50),
            metadataP95Ms: Self.percentile(metadataMilliseconds, fraction: 0.95),
            cacheHitCount: iterations
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(evidence)
        XCTAssertLessThanOrEqual(data.count, 4_096)
        try data.write(to: outputURL, options: .atomic)
    }

    func testPhase3GateWritesViewportPerformanceEvidenceWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ARKTRACE_PHASE3_GATE"] == "1" else { return }
        let fixtureClass = environment["ARKTRACE_PHASE3_FIXTURE_CLASS"] ?? "medium"
        XCTAssertTrue(["medium", "large"].contains(fixtureClass))
        let outputURL = URL(fileURLWithPath: try XCTUnwrap(
            environment["ARKTRACE_PHASE3_EVIDENCE_OUTPUT"]
        ))
        let fixture = URL(fileURLWithPath: try XCTUnwrap(
            environment["ARKTRACE_PHASE3_TRACE"]
                ?? environment["ARKTRACE_PHASE3_MEDIUM_TRACE"]
        ))
        let parserURL = URL(fileURLWithPath: try XCTUnwrap(
            environment["ARKTRACE_TRACE_STREAMER"]
        ))
        let fixtureBytes = try XCTUnwrap(
            fixture.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        if fixtureClass == "large" {
            XCTAssertGreaterThan(fixtureBytes, 500 * 1_024 * 1_024)
            XCTAssertLessThanOrEqual(fixtureBytes, 2 * 1_024 * 1_024 * 1_024)
        } else {
            XCTAssertGreaterThan(fixtureBytes, 50 * 1_024 * 1_024)
            XCTAssertLessThanOrEqual(fixtureBytes, 500 * 1_024 * 1_024)
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-phase3-benchmark-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parser = try TraceStreamerProcessParser(executableURL: parserURL)
        let parserIdentity = try await parser.identity()
        let stages = PerformanceStageRecorder()
        let coldStart = ContinuousClock.now
        let cold = try await TraceSession.open(
            source: fixture,
            parser: parser,
            stagingDirectory: staging,
            storagePolicy: .contentAddressed(cacheDirectory: cache),
            progress: { stages.record($0) }
        )
        let coldOpenMs = Self.milliseconds(coldStart.duration(to: .now))
        let coldWasCacheHit = await cold.cacheHit
        XCTAssertFalse(coldWasCacheHit)
        let metadata = try await cold.repository.metadata()
        let parsed = await cold.parsed
        let coldCacheMetadata = await cold.cacheMetadata
        let cacheMetadata = try XCTUnwrap(coldCacheMetadata)
        XCTAssertTrue(metadata.capabilities.cpuScheduling)
        XCTAssertTrue(metadata.capabilities.threadStates)
        XCTAssertTrue(metadata.capabilities.namedSlices)
        let fullRange = try TraceTimeRange.query(startNs: 0, endNs: metadata.durationNs)
        // These are independent capability probes, not one aggregate request.
        // Give each the reviewed per-query bound so an earlier full-range probe
        // cannot consume a later probe's complete deadline on a real large DB.
        let probeDeadline = { ContinuousClock.now.advanced(by: .seconds(30)) }
        let cpuProbe = try await cold.repository.cpuSlices(
            try CpuSliceQuery(range: fullRange, limit: 1, deadline: probeDeadline())
        )
        let stateProbe = try await cold.repository.threadStates(
            try ThreadStateQuery(range: fullRange, limit: 1, deadline: probeDeadline())
        )
        let sliceProbe = try await cold.repository.slices(
            try TraceSliceQuery(range: fullRange, limit: 1, deadline: probeDeadline())
        )
        let firstCPU = try XCTUnwrap(cpuProbe.items.first)
        let firstState = try XCTUnwrap(stateProbe.items.first)
        let firstSlice = try XCTUnwrap(sliceProbe.items.first)
        let densityProbes = [
            try await cold.repository.density(
                try TraceDensityQuery(
                    range: fullRange, source: .cpu(firstCPU.cpu), bucketCount: 64,
                    deadline: probeDeadline()
                )
            ),
            try await cold.repository.density(
                try TraceDensityQuery(
                    range: fullRange, source: .threadState(firstState.threadKey),
                    bucketCount: 64, deadline: probeDeadline()
                )
            ),
            try await cold.repository.density(
                try TraceDensityQuery(
                    range: fullRange, source: .namedSlice(firstSlice.threadKey),
                    bucketCount: 64, deadline: probeDeadline()
                )
            ),
        ]
        XCTAssertTrue(densityProbes.allSatisfy {
            $0.capabilityAvailable && $0.buckets.reduce(0) { $0 + $1.eventCount } > 0
        })
        try await cold.close()

        let iterations = 20
        var cacheOpenMs: [Double] = []
        var cacheHashMs: [Double] = []
        var cacheValidationMs: [Double] = []
        var directoryMs: [Double] = []
        let viewportMeasurementNames = [
            "cpuDetail", "threadStateDetail", "namedSliceDetail",
            "cpuDensity", "threadStateDensity", "namedSliceDensity", "automaticLoader",
        ]
        var viewportMeasurements = Dictionary(
            uniqueKeysWithValues: viewportMeasurementNames.map { ($0, [Double]()) }
        )
        var contextMs: [Double] = []
        var analysisMs: [Double] = []
        var measuredRows: [String: Int64] = [:]
        var lastSnapshot: TimelineSnapshot?
        var lastInteractionSnapshot: TimelineSnapshot?
        var cpuTracks = [firstCPU.cpu]
        for cpu in Int64(0)..<64 where cpuTracks.count < 6 && !cpuTracks.contains(cpu) {
            cpuTracks.append(cpu)
        }
        let tracks = cpuTracks.map {
            TrackDescriptor(title: "CPU \($0)", source: .cpu($0))
        } + [
            TrackDescriptor(
                title: "Thread state \(firstState.threadKey.itid)",
                source: .threadState(firstState.threadKey)
            ),
            TrackDescriptor(
                title: "Named slices",
                source: .namedSlice(firstSlice.threadKey)
            ),
        ]
        XCTAssertEqual(tracks.count, 8)
        let contextTimestampNs: Int64 = 10_200_000_000
        let contextWindowBeforeNs: Int64 = 50_000_000
        let contextWindowAfterNs: Int64 = 50_000_000
        let contextRange = try TraceTimeRange.query(
            startNs: 10_150_000_000,
            endNs: 10_250_000_000
        )
        XCTAssertGreaterThanOrEqual(metadata.durationNs, contextRange.endNs)
        let contextRequest = try TraceContextRequest(
            time: .timestamp(
                timestampNs: contextTimestampNs,
                windowBeforeNs: contextWindowBeforeNs,
                windowAfterNs: contextWindowAfterNs
            )
        )
        // AT-PERF-006 freezes one reproducible range-analysis workload rather
        // than allowing the measured window or budgets to drift with a probe.
        // These are the CLI effective defaults for a reviewed 10.1...10.3 s
        // range: global maxRows/maxEvents 10k, local limit 1k, 30 s timeout.
        let analysisRange = try TraceTimeRange.query(
            startNs: 10_100_000_000,
            endNs: 10_300_000_000
        )
        XCTAssertGreaterThanOrEqual(metadata.durationNs, analysisRange.endNs)
        let analysisMaximumRows = 10_000
        let analysisRequest = try TraceDeterministicAnalysisRequest(
            range: analysisRange,
            maximumCPUSlices: 10_000,
            maximumProcessSlices: 10_000,
            maximumThreadSlices: 10_000,
            maximumStateIntervals: 10_000,
            maximumNamedSlices: 10_000,
            maximumSchedulingEvents: 10_000,
            maximumHotEvents: 10_000,
            topProcessLimit: 1_000,
            topThreadLimit: 1_000,
            longSliceLimit: 1_000,
            schedulingSampleLimit: 1_000,
            hotIntervalLimit: 1_000,
            timeout: .seconds(30)
        )
        var analysisParameters: TraceDeterministicAnalysisParameters?
        let loader = TimelineSnapshotLoader()
        for iteration in 0..<iterations {
            let hitStages = PerformanceStageRecorder()
            let openStart = ContinuousClock.now
            let session = try await TraceSession.open(
                source: fixture,
                parser: parser,
                stagingDirectory: staging,
                storagePolicy: .contentAddressed(cacheDirectory: cache),
                progress: { hitStages.record($0) }
            )
            cacheOpenMs.append(Self.milliseconds(openStart.duration(to: .now)))
            cacheHashMs.append(
                hitStages.milliseconds(from: .hashing, to: .cacheLookup) ?? -1
            )
            cacheValidationMs.append(
                hitStages.milliseconds(from: .openingDatabase, to: .ready) ?? -1
            )
            let wasCacheHit = await session.cacheHit
            XCTAssertTrue(wasCacheHit)

            let directoryStart = ContinuousClock.now
            let processPage = try await session.repository.processes(
                try ProcessQuery(
                    limit: 1_024,
                    deadline: ContinuousClock.now.advanced(by: .seconds(5))
                )
            )
            let threadPage = try await session.repository.threads(
                try ThreadQuery(
                    limit: 1_024,
                    deadline: ContinuousClock.now.advanced(by: .seconds(5))
                )
            )
            directoryMs.append(Self.milliseconds(directoryStart.duration(to: .now)))
            XCTAssertFalse(processPage.items.isEmpty)
            XCTAssertFalse(threadPage.items.isEmpty)

            let contextStartTime = ContinuousClock.now
            let context = try await TraceContextBuilder(
                repository: session.repository
            ).build(contextRequest)
            XCTAssertEqual(context.range, contextRange)
            let contextBytes = try context.encoded(
                maximumBytes: 8 * 1_024 * 1_024
            ).count
            let contextEvents = context.cpuSlices.count
                + context.threadStates.count
                + context.slices.count
                + context.counters.reduce(0) { $0 + $1.samples.count }
            XCTAssertGreaterThan(contextEvents, 0)
            XCTAssertLessThanOrEqual(contextBytes, 8 * 1_024 * 1_024)
            contextMs.append(Self.milliseconds(contextStartTime.duration(to: .now)))

            let analysisStart = ContinuousClock.now
            let analysis = try await TraceDeterministicAnalysisEngine(
                repository: session.repository
            ).analyze(analysisRequest).retainingRows(maximumRows: analysisMaximumRows)
            analysisParameters = analysis.parameters
            analysisMs.append(Self.milliseconds(analysisStart.duration(to: .now)))
            XCTAssertFalse(analysis.cpuUtilization.isEmpty)
            let analysisRows = analysis.cpuUtilization.count
                + analysis.topProcesses.count
                + analysis.topThreads.count
                + analysis.longSlices.count
                + analysis.threadStateDistribution.count
                + analysis.schedulingLatency.topSamples.count
                + analysis.hotIntervals.count
            XCTAssertGreaterThan(analysisRows, 0)

            let generation = UInt64(iteration + 1)
            let viewport = try TimelineViewport(
                range: fullRange,
                widthPoints: 2_000,
                heightPoints: 640,
                generation: generation
            )
            let request = try ViewportRequest(
                viewport: viewport,
                tracks: tracks,
                pixelWidth: 2_000,
                generation: generation,
                deadline: ContinuousClock.now.advanced(by: .seconds(5))
            )
            let viewportDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            var queryStart = ContinuousClock.now
            let detailCPU = try await session.repository.cpuSlices(
                try CpuSliceQuery(
                    range: fullRange, cpu: firstCPU.cpu, limit: 2_000,
                    deadline: viewportDeadline
                )
            )
            viewportMeasurements["cpuDetail", default: []].append(
                Self.milliseconds(queryStart.duration(to: .now))
            )
            queryStart = ContinuousClock.now
            let detailState = try await session.repository.threadStates(
                try ThreadStateQuery(
                    range: fullRange, threadKey: firstState.threadKey, limit: 2_000,
                    deadline: viewportDeadline
                )
            )
            viewportMeasurements["threadStateDetail", default: []].append(
                Self.milliseconds(queryStart.duration(to: .now))
            )
            queryStart = ContinuousClock.now
            let detailSlice = try await session.repository.slices(
                try TraceSliceQuery(
                    range: fullRange, threadKey: firstSlice.threadKey, limit: 2_000,
                    deadline: viewportDeadline
                )
            )
            viewportMeasurements["namedSliceDetail", default: []].append(
                Self.milliseconds(queryStart.duration(to: .now))
            )
            queryStart = ContinuousClock.now
            let densityCPU = try await session.repository.density(
                try TraceDensityQuery(
                    range: fullRange, source: .cpu(firstCPU.cpu), bucketCount: 2_000,
                    deadline: viewportDeadline
                )
            )
            viewportMeasurements["cpuDensity", default: []].append(
                Self.milliseconds(queryStart.duration(to: .now))
            )
            queryStart = ContinuousClock.now
            let densityState = try await session.repository.density(
                try TraceDensityQuery(
                    range: fullRange, source: .threadState(firstState.threadKey),
                    bucketCount: 2_000, deadline: viewportDeadline
                )
            )
            viewportMeasurements["threadStateDensity", default: []].append(
                Self.milliseconds(queryStart.duration(to: .now))
            )
            queryStart = ContinuousClock.now
            let densitySlice = try await session.repository.density(
                try TraceDensityQuery(
                    range: fullRange, source: .namedSlice(firstSlice.threadKey),
                    bucketCount: 2_000, deadline: viewportDeadline
                )
            )
            viewportMeasurements["namedSliceDensity", default: []].append(
                Self.milliseconds(queryStart.duration(to: .now))
            )
            let densityCounts = [densityCPU, densityState, densitySlice].map {
                $0.buckets.reduce(Int64(0)) { $0 + $1.eventCount }
            }
            XCTAssertTrue([
                detailCPU.items.count, detailState.items.count, detailSlice.items.count,
            ].allSatisfy { $0 > 0 })
            XCTAssertTrue(densityCounts.allSatisfy { $0 > 0 })
            measuredRows = [
                "cpuDetail": Int64(detailCPU.items.count),
                "threadStateDetail": Int64(detailState.items.count),
                "namedSliceDetail": Int64(detailSlice.items.count),
                "cpuDensityEvents": densityCounts[0],
                "threadStateDensityEvents": densityCounts[1],
                "namedSliceDensityEvents": densityCounts[2],
                "contextBytes": Int64(contextBytes),
                "contextEvents": Int64(contextEvents),
                "deterministicAnalysisRows": Int64(analysisRows),
            ]
            let loaderStart = ContinuousClock.now
            let snapshot = try await loader.load(request, repository: session.repository)
            viewportMeasurements["automaticLoader", default: []].append(
                Self.milliseconds(loaderStart.duration(to: .now))
            )
            let loaded = try XCTUnwrap(snapshot)
            XCTAssertLessThanOrEqual(loaded.primitiveCount, 20_000)
            XCTAssertLessThanOrEqual(
                loaded.tracks.flatMap(\.primitives).filter {
                    if case .density = $0 { return true }
                    return false
                }.count,
                2_000 * 2 * tracks.count
            )
            XCTAssertTrue(loaded.tracks.contains {
                $0.descriptor.source == .threadState(firstState.threadKey)
                    && !$0.primitives.isEmpty
            })
            XCTAssertTrue(loaded.tracks.contains {
                $0.descriptor.source == .namedSlice(firstSlice.threadKey)
                    && !$0.primitives.isEmpty
            })
            lastSnapshot = loaded
            if iteration == iterations - 1 {
                let interactionRange = try Self.clampedWindow(
                    around: firstCPU.range,
                    padding: 1_000_000,
                    traceDurationNs: metadata.durationNs
                )
                let interactionViewport = try TimelineViewport(
                    range: interactionRange,
                    widthPoints: 2_000,
                    heightPoints: 160,
                    generation: 10_000
                )
                let interactionRequest = try ViewportRequest(
                    viewport: interactionViewport,
                    tracks: [tracks[0]],
                    pixelWidth: 2_000,
                    generation: interactionViewport.generation,
                    deadline: ContinuousClock.now.advanced(by: .seconds(5))
                )
                let interactionResult = try await loader.load(
                    interactionRequest, repository: session.repository
                )
                let interaction = try XCTUnwrap(interactionResult)
                XCTAssertFalse(
                    interaction.tracks.flatMap(\.primitives)
                        .compactMap(\.selectableEventKey).isEmpty,
                    "interaction frame evidence requires a real detail event"
                )
                lastInteractionSnapshot = interaction
            }
            try await session.close()
        }

        let finalSnapshot = try XCTUnwrap(lastSnapshot)
        let interactionSnapshot = try XCTUnwrap(lastInteractionSnapshot)
        let frameFamilies = try await Self.drawDurations(
            snapshot: finalSnapshot,
            interactionSnapshot: interactionSnapshot,
            iterations: iterations
        )
        let steadyFrameMs = frameFamilies.steady
        let selectionFrameMs = frameFamilies.selection
        let panFrameMs = frameFamilies.pan
        let rebuildFrameMs = frameFamilies.rebuild
        let diagnostics = try await TraceDatabaseStagingPreparer.performanceDiagnostics(
            databaseURL: parsed.databaseURL
        )
        XCTAssertFalse(diagnostics.usesAutomaticIndex)
        XCTAssertEqual(
            diagnostics.persistentIndexNames, diagnostics.applicableIndexNames
        )
        XCTAssertTrue(diagnostics.relationshipProbeSteps.values.allSatisfy {
            $0 < diagnostics.relationshipVMInstructionBudget
        })

        let cacheP95 = Self.percentile(cacheOpenMs, fraction: 0.95)
        let directoryP95 = Self.percentile(directoryMs, fraction: 0.95)
        struct LatencyEvidence: Encodable {
            let sampleCount: Int
            let p50Ms: Double
            let p95Ms: Double
        }
        let viewportLatency = try Dictionary(uniqueKeysWithValues:
            viewportMeasurementNames.map { name in
                let samples = try XCTUnwrap(viewportMeasurements[name])
                XCTAssertEqual(samples.count, iterations)
                return (
                    name,
                    LatencyEvidence(
                        sampleCount: samples.count,
                        p50Ms: Self.percentile(samples, fraction: 0.50),
                        p95Ms: Self.percentile(samples, fraction: 0.95)
                    )
                )
            }
        )
        let viewportP95 = try XCTUnwrap(viewportLatency.values.map(\.p95Ms).max())
        let viewportP50 = try XCTUnwrap(viewportLatency.values.map(\.p50Ms).max())
        let frameP95 = Self.percentile(steadyFrameMs, fraction: 0.95)
        let selectionFrameP95 = Self.percentile(selectionFrameMs, fraction: 0.95)
        let panFrameP95 = Self.percentile(panFrameMs, fraction: 0.95)
        let rebuildFrameP95 = Self.percentile(rebuildFrameMs, fraction: 0.95)
        let contextP95 = Self.percentile(contextMs, fraction: 0.95)
        let analysisP95 = Self.percentile(analysisMs, fraction: 0.95)
        let warmupOnly = environment["ARKTRACE_PHASE3_WARMUP_ONLY"] == "1"
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        let peakRSSBytes = Int64(usage.ru_maxrss)
        if !warmupOnly {
            XCTAssertLessThanOrEqual(
                cacheP95, 1_000,
                "cacheOpen p50/p95/max=\(Self.percentile(cacheOpenMs, fraction: 0.50))/"
                    + "\(cacheP95)/\(cacheOpenMs.max() ?? -1), hash p50/p95="
                    + "\(Self.percentile(cacheHashMs, fraction: 0.50))/"
                    + "\(Self.percentile(cacheHashMs, fraction: 0.95)), validation p50/p95="
                    + "\(Self.percentile(cacheValidationMs, fraction: 0.50))/"
                    + "\(Self.percentile(cacheValidationMs, fraction: 0.95))"
            )
            XCTAssertLessThanOrEqual(directoryP95, 150)
            XCTAssertLessThanOrEqual(
                viewportP95, fixtureClass == "large" ? 500 : 250,
                "viewportP95ByFamily=" + viewportMeasurementNames.map {
                    "\($0)=\(viewportLatency[$0]?.p95Ms ?? -1)"
                }.joined(separator: ",")
            )
            XCTAssertLessThanOrEqual(contextP95, fixtureClass == "large" ? 2_000 : 1_000)
            XCTAssertLessThanOrEqual(analysisP95, fixtureClass == "large" ? 5_000 : 3_000)
            XCTAssertLessThanOrEqual(
                frameP95, 16.7,
                "steady frame p50/p95/max=\(Self.percentile(steadyFrameMs, fraction: 0.50))/"
                    + "\(frameP95)/\(steadyFrameMs.max() ?? -1), shape="
                    + finalSnapshot.tracks.map { track in
                        let detail = track.primitives.reduce(0) {
                            if case .detail = $1 { return $0 + 1 }
                            return $0
                        }
                        let density = track.primitives.count - detail
                        return "\(track.descriptor.id.rawValue):d\(detail)/b\(density)"
                    }.joined(separator: ",")
            )
            XCTAssertLessThanOrEqual(selectionFrameP95, 16.7)
            XCTAssertLessThanOrEqual(panFrameP95, 16.7)
            XCTAssertLessThanOrEqual(rebuildFrameP95, 250)
            XCTAssertLessThanOrEqual(peakRSSBytes, 1_610_612_736)
        }
        XCTAssertTrue(measuredRows.values.allSatisfy { $0 > 0 })
        let parseMs = try XCTUnwrap(stages.milliseconds(from: .parsing, to: .validating))
        let validationMs = try XCTUnwrap(stages.milliseconds(from: .validating, to: .indexing))
        let indexMs = try XCTUnwrap(stages.milliseconds(from: .indexing, to: .openingDatabase))
        XCTAssertGreaterThanOrEqual(parseMs, 0)
        XCTAssertGreaterThanOrEqual(validationMs, 0)
        XCTAssertGreaterThanOrEqual(indexMs, 0)
        XCTAssertGreaterThan(cacheMetadata.databaseByteCount, 0)

        struct Phase3Evidence: Encodable {
            struct ContextWorkload: Encodable {
                struct Time: Encodable {
                    let timestampNs: Int64
                    let windowBeforeNs: Int64
                    let windowAfterNs: Int64
                }
                let name: String
                let time: Time
                let normalizedRange: TraceTimeRange
                let filters: TraceAgentQueryFilters
                let maximumEvents: Int
                let maximumRows: Int
                let maximumOutputBytes: Int
                let timeoutSeconds: Int64
                let timeoutAttoseconds: Int64
            }
            struct AnalysisWorkload: Encodable {
                let name: String
                let range: TraceTimeRange
                let globalMaximumRows: Int
                let parameters: TraceDeterministicAnalysisParameters
            }
            struct Machine: Encodable {
                let model: String
                let architecture: String
                let operatingSystem: String
                let physicalMemoryBytes: UInt64
            }
            let formatVersion: Int
            let arkTraceVersion: String
            let arkTraceBaseRevision: String
            let arkTraceSourceTreeSHA256: String
            let arkTraceTestBinarySHA256: String
            let workingTreeDirty: Bool
            let machine: Machine
            let fixtureClass: String
            let traceSHA256: String
            let traceByteCount: Int64
            let traceDurationNs: Int64
            let fixtureProvenanceSHA256: String
            let fixtureProvenanceSource: String
            let fixtureLicenseSHA256: String
            let parserBinarySHA256: String
            let parserVersion: String
            let parserUpstreamRevision: String
            let databaseByteCount: Int64
            let coldOpenMs: Double
            let parseMs: Double
            let validationMs: Double
            let indexMs: Double
            let iterations: Int
            let cacheOpenP50Ms: Double
            let cacheOpenP95Ms: Double
            let metadataDirectoryP50Ms: Double
            let metadataDirectoryP95Ms: Double
            let viewportP50Ms: Double
            let viewportP95Ms: Double
            let viewportLatency: [String: LatencyEvidence]
            let frameP50Ms: Double
            let frameP95Ms: Double
            let selectionFrameP50Ms: Double
            let selectionFrameP95Ms: Double
            let panFrameP50Ms: Double
            let panFrameP95Ms: Double
            let rebuildFrameP50Ms: Double
            let rebuildFrameP95Ms: Double
            let contextP50Ms: Double
            let contextP95Ms: Double
            let deterministicAnalysisP50Ms: Double
            let deterministicAnalysisP95Ms: Double
            let contextWorkload: ContextWorkload
            let analysisWorkload: AnalysisWorkload
            let peakRSSBytes: Int64
            let maximumPrimitives: Int
            let capabilities: TraceCapabilities
            let measuredRows: [String: Int64]
            let diagnostics: TraceDatabasePerformanceDiagnostics
        }
        let evidence = Phase3Evidence(
            formatVersion: 3,
            arkTraceVersion: ArkTraceProduct.version,
            arkTraceBaseRevision: environment["ARKTRACE_BASE_REVISION"] ?? "unknown",
            arkTraceSourceTreeSHA256: try XCTUnwrap(
                environment["ARKTRACE_SOURCE_TREE_SHA256"]
            ),
            // XCTest is launched by Xcode's `xctest` runner, so argv[0] is
            // the runner (and may itself be a symlink), not the ArkTrace test
            // bundle whose bytes exercised this candidate. Bind evidence to
            // the loaded bundle executable instead.
            arkTraceTestBinarySHA256: try sha256AndSize(
                at: try XCTUnwrap(Bundle(for: type(of: self)).executableURL)
            ).sha256,
            workingTreeDirty: environment["ARKTRACE_WORKTREE_DIRTY"] == "1",
            machine: .init(
                model: Self.sysctlString("hw.model") ?? "unknown",
                architecture: Self.machineArchitecture(),
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
            ),
            fixtureClass: fixtureClass,
            traceSHA256: metadata.traceSHA256,
            traceByteCount: metadata.sourceByteCount,
            traceDurationNs: metadata.durationNs,
            fixtureProvenanceSHA256: try XCTUnwrap(
                environment["ARKTRACE_PHASE3_PROVENANCE_SHA256"]
            ),
            fixtureProvenanceSource: try XCTUnwrap(
                environment["ARKTRACE_PHASE3_PROVENANCE_SOURCE"]
            ),
            fixtureLicenseSHA256: try XCTUnwrap(
                environment["ARKTRACE_PHASE3_FIXTURE_LICENSE_SHA256"]
            ),
            parserBinarySHA256: parserIdentity.binarySHA256,
            parserVersion: parserIdentity.reportedVersion,
            parserUpstreamRevision: parserIdentity.upstreamRevision,
            databaseByteCount: cacheMetadata.databaseByteCount,
            coldOpenMs: coldOpenMs,
            parseMs: parseMs,
            validationMs: validationMs,
            indexMs: indexMs,
            iterations: iterations,
            cacheOpenP50Ms: Self.percentile(cacheOpenMs, fraction: 0.50),
            cacheOpenP95Ms: cacheP95,
            metadataDirectoryP50Ms: Self.percentile(directoryMs, fraction: 0.50),
            metadataDirectoryP95Ms: directoryP95,
            viewportP50Ms: viewportP50,
            viewportP95Ms: viewportP95,
            viewportLatency: viewportLatency,
            frameP50Ms: Self.percentile(steadyFrameMs, fraction: 0.50),
            frameP95Ms: frameP95,
            selectionFrameP50Ms: Self.percentile(selectionFrameMs, fraction: 0.50),
            selectionFrameP95Ms: selectionFrameP95,
            panFrameP50Ms: Self.percentile(panFrameMs, fraction: 0.50),
            panFrameP95Ms: panFrameP95,
            rebuildFrameP50Ms: Self.percentile(rebuildFrameMs, fraction: 0.50),
            rebuildFrameP95Ms: rebuildFrameP95,
            contextP50Ms: Self.percentile(contextMs, fraction: 0.50),
            contextP95Ms: contextP95,
            deterministicAnalysisP50Ms: Self.percentile(analysisMs, fraction: 0.50),
            deterministicAnalysisP95Ms: analysisP95,
            contextWorkload: .init(
                name: "timestamp-default-v1",
                time: .init(
                    timestampNs: contextTimestampNs,
                    windowBeforeNs: contextWindowBeforeNs,
                    windowAfterNs: contextWindowAfterNs
                ),
                normalizedRange: contextRange,
                filters: contextRequest.filters,
                maximumEvents: contextRequest.maximumEvents,
                maximumRows: contextRequest.maximumRows,
                maximumOutputBytes: contextRequest.maximumOutputBytes,
                timeoutSeconds: contextRequest.timeout.components.seconds,
                timeoutAttoseconds: contextRequest.timeout.components.attoseconds
            ),
            analysisWorkload: .init(
                name: "agent-range-default-v1",
                range: analysisRange,
                globalMaximumRows: analysisMaximumRows,
                parameters: try XCTUnwrap(analysisParameters)
            ),
            peakRSSBytes: peakRSSBytes,
            maximumPrimitives: 20_000,
            capabilities: metadata.capabilities,
            measuredRows: measuredRows,
            diagnostics: diagnostics
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(evidence)
        XCTAssertLessThanOrEqual(data.count, 32_768)
        try data.write(to: outputURL, options: .atomic)
    }

    func testPhase3LargeTraceCancellationLeavesNoReadyOrPrivateBuildWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ARKTRACE_PHASE3_LARGE_CANCELLATION"] == "1" else { return }
        let fixture = URL(fileURLWithPath: try XCTUnwrap(
            environment["ARKTRACE_PHASE3_TRACE"]
        ))
        let parserURL = URL(fileURLWithPath: try XCTUnwrap(
            environment["ARKTRACE_TRACE_STREAMER"]
        ))
        let evidenceURL = URL(fileURLWithPath: try XCTUnwrap(
            environment["ARKTRACE_PHASE3_LARGE_CANCELLATION_EVIDENCE"]
        ))
        let fixtureBytes = try XCTUnwrap(
            fixture.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        XCTAssertGreaterThan(fixtureBytes, 500 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(fixtureBytes, 2 * 1_024 * 1_024 * 1_024)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-phase3-large-cancel-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let launchBarrier = ProcessLaunchBarrier()
        let (launchEvents, launchContinuation) = AsyncStream.makeStream(
            of: ProcessLaunchEvent.self
        )
        let parser = try TraceStreamerProcessParser(
            executableURL: parserURL,
            finalizationHook: nil,
            processDidLaunchHook: {
                launchContinuation.yield(.launched($0))
                launchBarrier.record($0)
            }
        )
        let task = Task {
            defer {
                launchContinuation.yield(.openCompleted)
                launchContinuation.finish()
            }
            return try await TraceSession.open(
                source: fixture,
                parser: parser,
                stagingDirectory: staging,
                storagePolicy: .contentAddressed(cacheDirectory: cache)
            )
        }
        let launchEvent: ProcessLaunchEvent
        do {
            launchEvent = try await Self.firstProcessLaunchEvent(
                from: launchEvents, timeout: .seconds(300)
            )
        } catch {
            task.cancel()
            launchBarrier.resume()
            _ = await task.result
            XCTFail("large parse did not reach a running child within its bounded wait")
            return
        }
        guard case .launched(let launchedPID) = launchEvent else {
            launchBarrier.resume()
            let result = await task.result
            if case .success(let session) = result { try? await session.close() }
            XCTFail("large parse completed before launching the parser child: \(result)")
            return
        }
        XCTAssertEqual(Darwin.kill(launchedPID, 0), 0)
        task.cancel()
        launchBarrier.resume()
        var observedCancellation = false
        do {
            _ = try await task.value
            XCTFail("cancelled large parse must not return Ready")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .cancelled)
            observedCancellation = error.code == .cancelled
        } catch is CancellationError {
            observedCancellation = true
        }
        errno = 0
        XCTAssertEqual(Darwin.kill(launchedPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)

        let residuals = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: []
        )?.compactMap { element -> String? in
            guard let url = element as? URL else { return nil }
            return String(url.path.dropFirst(root.path.count + 1))
        } ?? []
        XCTAssertFalse(residuals.contains { $0.split(separator: "/").contains("database.sqlite") })
        XCTAssertFalse(residuals.contains { $0.split(separator: "/").contains("metadata.json") })
        XCTAssertFalse(residuals.contains { path in
            path.split(separator: "/").contains { component in
                component.hasPrefix("session-")
                    || component.hasPrefix("entry-")
                    || component.hasPrefix("cancelled-")
                    || component.hasPrefix("displaced-")
            }
        })
        XCTAssertFalse(residuals.contains { $0.hasPrefix(".owners/") })
        XCTAssertTrue(observedCancellation)
        let traceIdentity = try sha256AndSize(
            at: fixture, maximumByteCount: 2_147_483_648
        )
        struct CancellationEvidence: Encodable {
            let formatVersion: Int
            let fixtureClass: String
            let traceSHA256: String
            let traceByteCount: Int64
            let testExecuted: Bool
            let cancellationObserved: Bool
            let residualCount: Int
        }
        let evidence = CancellationEvidence(
            formatVersion: 1,
            fixtureClass: "large",
            traceSHA256: traceIdentity.sha256,
            traceByteCount: traceIdentity.byteCount,
            testExecuted: true,
            cancellationObserved: observedCancellation,
            residualCount: residuals.count
        )
        let data = try JSONEncoder().encode(evidence)
        XCTAssertLessThanOrEqual(data.count, 4_096)
        try data.write(to: evidenceURL, options: .atomic)
    }

    @MainActor
    private static func drawDurations(
        snapshot: TimelineSnapshot,
        interactionSnapshot: TimelineSnapshot,
        iterations: Int
    ) throws -> (steady: [Double], selection: [Double], pan: [Double], rebuild: [Double]) {
        let width = max(1, Int(snapshot.viewport.widthPoints))
        let height = max(1, Int(snapshot.viewport.heightPoints))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            let failed = [Double.infinity]
            return (failed, failed, failed, failed)
        }
        let view = TimelineNSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let interactionView = TimelineNSView(
            frame: NSRect(x: 0, y: 0, width: width, height: height)
        )
        view.snapshot = snapshot
        interactionView.snapshot = interactionSnapshot
        // Exclude one-time AppKit/CoreGraphics glyph and immutable snapshot
        // path construction from the steady-state 60 fps frame distribution.
        for _ in 0..<2 {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            view.draw(view.bounds)
            context.cgContext.flush()
            NSGraphicsContext.restoreGraphicsState()
        }
        func draw(_ target: TimelineNSView = view) -> Double {
            let start = ContinuousClock.now
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            target.draw(target.bounds)
            context.cgContext.flush()
            NSGraphicsContext.restoreGraphicsState()
            return milliseconds(start.duration(to: .now))
        }
        var steady: [Double] = []
        var selection: [Double] = []
        var pan: [Double] = []
        var rebuild: [Double] = []
        steady.reserveCapacity(iterations)
        selection.reserveCapacity(iterations)
        pan.reserveCapacity(iterations)
        rebuild.reserveCapacity(iterations)
        let eventKeys = interactionSnapshot.tracks.flatMap(\.primitives)
            .compactMap(\.selectableEventKey)
        let selectableEvent = try XCTUnwrap(
            eventKeys.first,
            "frame evidence requires a real selectable detail event"
        )
        let originalRange = interactionSnapshot.viewport.range
        let shift = max(1, originalRange.durationNs / 20)
        let forwardStart = originalRange.startNs.addingReportingOverflow(shift)
        let forwardEnd = originalRange.endNs.addingReportingOverflow(shift)
        let shiftedRange: TraceTimeRange
        if !forwardStart.overflow, !forwardEnd.overflow {
            shiftedRange = try TraceTimeRange.query(
                startNs: forwardStart.partialValue,
                endNs: forwardEnd.partialValue
            )
        } else {
            shiftedRange = try TraceTimeRange.query(
                startNs: originalRange.startNs - shift,
                endNs: originalRange.endNs - shift
            )
        }
        for iteration in 0..<iterations {
            steady.append(draw())
            interactionView.selectedEventKey = iteration.isMultiple(of: 2)
                ? selectableEvent : nil
            selection.append(draw(interactionView))
            let panGeneration = interactionSnapshot.generation &+ UInt64(iteration * 2 + 1)
            let panViewport = try TimelineViewport(
                range: iteration.isMultiple(of: 2) ? shiftedRange : originalRange,
                widthPoints: interactionSnapshot.viewport.widthPoints,
                heightPoints: interactionSnapshot.viewport.heightPoints,
                generation: panGeneration
            )
            interactionView.snapshot = TimelineSnapshot(
                viewport: panViewport,
                tracks: interactionSnapshot.tracks,
                generation: panGeneration,
                dataQuality: interactionSnapshot.dataQuality,
                isLoading: interactionSnapshot.isLoading
            )
            pan.append(draw(interactionView))
            let generation = snapshot.generation &+ UInt64(iteration + 1)
            view.snapshot = TimelineSnapshot(
                viewport: snapshot.viewport,
                tracks: snapshot.tracks,
                generation: generation,
                dataQuality: snapshot.dataQuality,
                isLoading: snapshot.isLoading
            )
            rebuild.append(draw())
        }
        return (steady, selection, pan, rebuild)
    }

    func testCancellationTerminatesParser() async throws {
        let (binary, fixture) = try requireEnvironment()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        let task = Task.detached {
            return try await TraceSession.open(
                source: fixture,
                parser: try TraceStreamerProcessParser(executableURL: binary),
                stagingDirectory: staging
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            // Tiny fixtures may finish before the cancellation lands; both
            // outcomes are acceptable, silent partial output is not.
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .cancelled)
        } catch is CancellationError {
            // Structured concurrency surfaced the cancellation directly.
        }
    }

    func testCancellationDuringStagingQuickCheckCannotPromoteReady() async throws {
        let (binary, fixture) = try requireEnvironment()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-quick-check-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("trace.sqlite")
        let barrier = BlockingCancellationBarrier()
        let parser = try TraceStreamerProcessParser(executableURL: binary)

        let task = Task.detached {
            try await parser.parse(
                source: fixture,
                destination: destination,
                progress: nil,
                prepareDatabase: { databaseURL, progress in
                    try TraceDatabaseStagingPreparer.prepare(
                        databaseURL: databaseURL,
                        progress: progress,
                        quickCheckProgressHook: { barrier.pauseUntilReleased() }
                    )
                }
            )
        }
        await barrier.waitUntilReached()
        task.cancel()
        barrier.resume()

        do {
            _ = try await task.value
            XCTFail("cancelled quick_check must not promote a Ready database")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path + ".arktrace.json")
        )
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(leftovers.isEmpty, "partial DB and destination claim must be cleaned")
    }

    func testConcurrentSessionsSharingStagingRootUseDistinctDatabases() async throws {
        let (binary, fixture) = try requireEnvironment()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-concurrent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let parser = try TraceStreamerProcessParser(executableURL: binary)

        async let first = TraceSession.open(
            source: fixture,
            parser: parser,
            stagingDirectory: staging
        )
        async let second = TraceSession.open(
            source: fixture,
            parser: parser,
            stagingDirectory: staging
        )
        let sessions = try await [first, second]
        let firstURL = await sessions[0].parsed.databaseURL
        let secondURL = await sessions[1].parsed.databaseURL

        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testCancellationDuringRepositoryValidationCannotReturnReadySession() async throws {
        let (binary, fixture) = try requireEnvironment()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-repository-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let barrier = CancellationBarrier()

        let task = Task.detached {
            let parser = try TraceStreamerProcessParser(executableURL: binary)
            return try await TraceSession.open(
                source: fixture,
                parser: parser,
                stagingDirectory: staging,
                repositoryValidationHook: { await barrier.pauseUntilCancelled() }
            )
        }
        await barrier.waitUntilReached()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled repository validation must not return Ready")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .cancelled)
        }
        let leftovers = (try? publicSessionEntries(at: staging)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "cancelled session directory must be removed")
    }

    func testContentCacheMissThenHitKeepsPathFreeMetadataAndActiveLease() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cache-hit-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parser = CountingParser(
            base: try TraceStreamerProcessParser(executableURL: binary)
        )
        let missStages = StageRecorder()

        let first = try await TraceSession.openCached(
            source: fixture,
            parser: parser,
            stagingDirectory: staging,
            cacheDirectory: cache,
            progress: { missStages.append($0) },
            now: { Date(timeIntervalSince1970: 100) }
        )
        let firstParsed = await first.parsed
        let firstMetadataValue = await first.cacheMetadata
        let firstMetadata = try XCTUnwrap(firstMetadataValue)
        let firstCacheHit = await first.cacheHit
        XCTAssertFalse(firstCacheHit)
        XCTAssertEqual(parser.count(), 1)
        XCTAssertEqual(parser.identityCount(), 0)
        XCTAssertEqual(parser.cacheIdentityCount(), 1)
        XCTAssertEqual(missStages.snapshot(), [
            .preparing, .hashing, .cacheLookup, .parsing, .validating,
            .indexing, .openingDatabase, .ready,
        ])
        XCTAssertEqual(firstParsed.databaseURL.lastPathComponent, "database.sqlite")
        XCTAssertEqual(firstParsed.metadataSidecarURL.lastPathComponent, "metadata.json")
        XCTAssertEqual(firstMetadata.sourceSHA256, firstParsed.sourceSHA256)
        XCTAssertEqual(firstMetadata.traceSHA256, firstParsed.sourceSHA256)
        XCTAssertEqual(firstMetadata.sourceByteCount, firstParsed.sourceByteCount)
        XCTAssertEqual(
            firstMetadata.schemaFingerprint,
            firstParsed.databasePreparation.schemaFingerprint
        )
        XCTAssertEqual(
            firstMetadata.schemaAdapterVersion,
            TraceDatabaseStagingPreparer.schemaAdapterVersion
        )
        XCTAssertEqual(
            firstMetadata.indexSchemaVersion,
            TraceDatabaseStagingPreparer.indexVersion
        )
        XCTAssertEqual(
            firstMetadata.databasePreparation.schemaAdapterVersion,
            TraceDatabaseStagingPreparer.schemaAdapterVersion
        )
        XCTAssertEqual(
            firstMetadata.databasePreparation.indexVersion,
            TraceDatabaseStagingPreparer.indexVersion
        )
        XCTAssertEqual(
            firstMetadata.databaseByteCount,
            try sha256AndSize(at: firstParsed.databaseURL).byteCount
        )
        XCTAssertEqual(firstMetadata.createdAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(firstMetadata.lastAccessedAt, Date(timeIntervalSince1970: 100))

        let metadataBytes = try Data(contentsOf: firstParsed.metadataSidecarURL)
        XCTAssertNil(metadataBytes.range(of: Data(fixture.path.utf8)))
        XCTAssertNil(metadataBytes.range(of: Data(staging.path.utf8)))
        XCTAssertNil(metadataBytes.range(of: Data(cache.path.utf8)))
        let compatibleSidecar = try JSONDecoder().decode(
            TraceDatabaseMetadataSidecar.self,
            from: metadataBytes
        )
        XCTAssertEqual(compatibleSidecar.parser, firstParsed.parser)
        XCTAssertEqual(compatibleSidecar.databasePreparation, firstParsed.databasePreparation)
        XCTAssertEqual(try permissions(at: cache), 0o700)
        XCTAssertEqual(
            try permissions(at: firstParsed.databaseURL.deletingLastPathComponent()),
            0o700
        )
        XCTAssertEqual(try permissions(at: firstParsed.databaseURL), 0o400)
        XCTAssertEqual(try permissions(at: firstParsed.metadataSidecarURL), 0o400)
        let contention = OneShotSignal()
        let mutationBarrier = PromotionBarrier()
        let mutationTask = Task {
            try await TraceContentAddressedCache.withExclusiveEntryMutation(
                cacheDirectory: cache,
                key: firstMetadata.cacheKey,
                contentionHook: { contention.signal() },
                operation: { mutationBarrier.pause(at: $0) }
            )
        }
        await contention.wait()
        XCTAssertFalse(
            mutationBarrier.hasReached(),
            "an active session must hold the exclusive mutation guard outside"
        )
        try await first.close()
        _ = await mutationBarrier.waitUntilReached()
        mutationBarrier.resume()
        try await mutationTask.value

        let hitStages = StageRecorder()
        let second = try await TraceSession.openCached(
            source: fixture,
            parser: parser,
            stagingDirectory: staging,
            cacheDirectory: cache,
            progress: { hitStages.append($0) },
            now: { Date(timeIntervalSince1970: 200) }
        )
        let secondCacheHit = await second.cacheHit
        XCTAssertTrue(secondCacheHit)
        XCTAssertEqual(parser.count(), 1, "cache hit must not export the trace again")
        XCTAssertEqual(parser.identityCount(), 0, "cache hit must not launch --version")
        XCTAssertEqual(parser.cacheIdentityCount(), 2)
        XCTAssertEqual(hitStages.snapshot(), [
            .preparing, .hashing, .cacheLookup, .openingDatabase, .ready,
        ])
        let secondParsed = await second.parsed
        XCTAssertEqual(secondParsed.databaseURL, firstParsed.databaseURL)
        let secondMetadataValue = await second.cacheMetadata
        let secondMetadata = try XCTUnwrap(secondMetadataValue)
        XCTAssertEqual(secondMetadata.createdAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(secondMetadata.lastAccessedAt, Date(timeIntervalSince1970: 200))
        XCTAssertTrue(
            try publicSessionEntries(at: staging).isEmpty,
            "source snapshots must not survive a successful cached open"
        )
        try await second.close()
    }

    func testConcurrentCachedOpenIsSingleFlight() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cache-single-flight-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parser = CountingParser(
            base: try TraceStreamerProcessParser(executableURL: binary)
        )

        async let first = TraceSession.openCached(
            source: fixture,
            parser: parser,
            stagingDirectory: staging,
            cacheDirectory: cache
        )
        async let second = TraceSession.openCached(
            source: fixture,
            parser: parser,
            stagingDirectory: staging,
            cacheDirectory: cache
        )
        let sessions = try await [first, second]
        XCTAssertEqual(parser.count(), 1)
        let hitStates = await sessions.asyncMap { await $0.cacheHit }
        XCTAssertEqual(hitStates.filter { !$0 }.count, 1)
        XCTAssertEqual(hitStates.filter { $0 }.count, 1)
        let paths = await sessions.asyncMap { await $0.parsed.databaseURL }
        XCTAssertEqual(Set(paths).count, 1)
        for session in sessions { try await session.close() }
    }

    func testCacheCrossProcessWorker() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let action = environment["ARKTRACE_CACHE_WORKER_ACTION"] else { return }
        let root = URL(fileURLWithPath: try XCTUnwrap(environment["ARKTRACE_CACHE_WORKER_ROOT"]))
        let binary = URL(
            fileURLWithPath: try XCTUnwrap(environment["ARKTRACE_CACHE_WORKER_BINARY"])
        )
        let fixture = URL(
            fileURLWithPath: try XCTUnwrap(environment["ARKTRACE_CACHE_WORKER_FIXTURE"])
        )
        let result = environment["ARKTRACE_CACHE_WORKER_RESULT"].map(URL.init(fileURLWithPath:))
        let ready = environment["ARKTRACE_CACHE_WORKER_READY"].map(URL.init(fileURLWithPath:))
        let release = environment["ARKTRACE_CACHE_WORKER_RELEASE"].map(URL.init(fileURLWithPath:))
        let counter = environment["ARKTRACE_CACHE_WORKER_COUNTER"].map(URL.init(fileURLWithPath:))
        let parser = CountingParser(
            base: try TraceStreamerProcessParser(executableURL: binary),
            processCounterURL: counter
        )
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)

        let waitForRelease: @Sendable () -> Void = {
            guard let release else { return }
            while !FileManager.default.fileExists(atPath: release.path) {
                Darwin.usleep(10_000)
            }
        }
        let hooks: TraceCacheTestHooks
        if action == "hold-key" {
            hooks = TraceCacheTestHooks(afterKeyLock: { _ in
                if let ready { try? Data("ready".utf8).write(to: ready) }
                waitForRelease()
            })
        } else {
            hooks = TraceCacheTestHooks()
        }

        let session = try await TraceSession.openCached(
            source: fixture,
            parser: parser,
            stagingDirectory: staging,
            cacheDirectory: cache,
            hooks: hooks
        )
        let hit = await session.cacheHit
        var execChild: ProcessBox?
        if action == "hold-lease" {
            if let ready { try Data("ready".utf8).write(to: ready) }
            waitForRelease()
        } else if action == "cloexec" {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["3"]
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            let childBox = ProcessBox(child)
            try child.run()
            execChild = childBox
        }
        try await session.close()
        if let result {
            try Data((hit ? "hit" : "miss").utf8).write(to: result)
        }
        if let execChild {
            let execChildStatus = await execChild.wait()
            XCTAssertEqual(execChildStatus, 0)
        }
    }

    func testCrossProcessSingleFlightCancellationLeaseAndCLOEXEC() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cache-process-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let counter = root.appendingPathComponent("export.count")
        let firstResult = root.appendingPathComponent("first.result")
        let secondResult = root.appendingPathComponent("second.result")
        let first = try launchCacheWorker(
            action: "open",
            root: root,
            binary: binary,
            fixture: fixture,
            result: firstResult,
            counter: counter
        )
        let second = try launchCacheWorker(
            action: "open",
            root: root,
            binary: binary,
            fixture: fixture,
            result: secondResult,
            counter: counter
        )
        async let firstStatus = first.wait()
        async let secondStatus = second.wait()
        let statuses = await [firstStatus, secondStatus]
        XCTAssertEqual(statuses, [0, 0])
        XCTAssertEqual(try Data(contentsOf: counter).count, 1)
        XCTAssertEqual(
            Set([
                try String(contentsOf: firstResult, encoding: .utf8),
                try String(contentsOf: secondResult, encoding: .utf8),
            ]),
            Set(["miss", "hit"])
        )

        // A separate process holds the per-key single-flight lock. The local
        // waiter must observe cancellation without waiting for that process.
        let waitRoot = root.appendingPathComponent("waiter", isDirectory: true)
        let keyReady = root.appendingPathComponent("key.ready")
        let keyRelease = root.appendingPathComponent("key.release")
        let keyHolder = try launchCacheWorker(
            action: "hold-key",
            root: waitRoot,
            binary: binary,
            fixture: fixture,
            ready: keyReady,
            release: keyRelease
        )
        try await waitForFile(keyReady)
        let keyContention = OneShotSignal()
        let waiter = Task {
            try await TraceSession.openCached(
                source: fixture,
                parser: try TraceStreamerProcessParser(executableURL: binary),
                stagingDirectory: waitRoot.appendingPathComponent("local-staging"),
                cacheDirectory: waitRoot.appendingPathComponent("cache"),
                hooks: TraceCacheTestHooks(
                    keyLockContended: { keyContention.signal() }
                )
            )
        }
        await keyContention.wait()
        let cancelStart = ContinuousClock.now
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("cross-process key-lock waiter must cancel")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .cancelled)
            XCTAssertEqual(error.stage, .cacheLookup)
        }
        XCTAssertLessThan(cancelStart.duration(to: .now), .seconds(1))
        try Data().write(to: keyRelease)
        let keyHolderStatus = await keyHolder.wait()
        XCTAssertEqual(keyHolderStatus, 0)

        // A shared lease held by another process prevents mutation. Once the
        // mutation enters, it retains key+exclusive lease until its closure
        // finishes, so a third process cannot reopen the entry mid-mutation.
        let leaseReady = root.appendingPathComponent("lease.ready")
        let leaseRelease = root.appendingPathComponent("lease.release")
        let leaseHolder = try launchCacheWorker(
            action: "hold-lease",
            root: root,
            binary: binary,
            fixture: fixture,
            ready: leaseReady,
            release: leaseRelease
        )
        try await waitForFile(leaseReady)
        let metadata = try cacheMetadata(in: root.appendingPathComponent("cache"))
        let contention = OneShotSignal()
        let mutation = PromotionBarrier()
        let mutationTask = Task {
            try await TraceContentAddressedCache.withExclusiveEntryMutation(
                cacheDirectory: root.appendingPathComponent("cache"),
                key: metadata.cacheKey,
                contentionHook: { contention.signal() },
                operation: { mutation.pause(at: $0) }
            )
        }
        await contention.wait()
        XCTAssertFalse(mutation.hasReached())
        try Data().write(to: leaseRelease)
        let leaseHolderStatus = await leaseHolder.wait()
        XCTAssertEqual(leaseHolderStatus, 0)
        _ = await mutation.waitUntilReached()
        let guardedResult = root.appendingPathComponent("guarded.result")
        let guardedReader = try launchCacheWorker(
            action: "open",
            root: root,
            binary: binary,
            fixture: fixture,
            result: guardedResult
        )
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: guardedResult.path))
        mutation.resume()
        try await mutationTask.value
        let guardedReaderStatus = await guardedReader.wait()
        XCTAssertEqual(guardedReaderStatus, 0)
        XCTAssertEqual(try String(contentsOf: guardedResult, encoding: .utf8), "hit")

        // The lease descriptor is O_CLOEXEC. A long-lived exec child started
        // by a cache holder must not keep the lease alive after its parent closes.
        let cloexecResult = root.appendingPathComponent("cloexec.result")
        let cloexecWorker = try launchCacheWorker(
            action: "cloexec",
            root: root,
            binary: binary,
            fixture: fixture,
            result: cloexecResult
        )
        try await waitForFile(cloexecResult)
        let mutationStart = ContinuousClock.now
        try await TraceContentAddressedCache.withExclusiveEntryMutation(
            cacheDirectory: root.appendingPathComponent("cache"),
            key: metadata.cacheKey,
            operation: { _ in }
        )
        XCTAssertLessThan(mutationStart.duration(to: .now), .seconds(1))
        let cloexecStatus = await cloexecWorker.wait()
        XCTAssertEqual(cloexecStatus, 0)
    }

    func testCorruptCacheIsQuarantinedAndRebuiltOnce() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cache-corrupt-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parser = CountingParser(
            base: try TraceStreamerProcessParser(executableURL: binary)
        )

        let first = try await TraceSession.openCached(
            source: fixture,
            parser: parser,
            stagingDirectory: staging,
            cacheDirectory: cache
        )
        let databaseURL = await first.parsed.databaseURL
        try await first.close()
        try Data("not-a-sqlite-database".utf8).write(to: databaseURL, options: .atomic)

        let rebuilt = try await TraceSession.openCached(
            source: fixture,
            parser: parser,
            stagingDirectory: staging,
            cacheDirectory: cache
        )
        let rebuiltCacheHit = await rebuilt.cacheHit
        XCTAssertFalse(rebuiltCacheHit)
        XCTAssertEqual(parser.count(), 2)
        XCTAssertTrue(try TraceDatabase(url: databaseURL, readOnly: true).quickCheckIsOK())
        let corruptRoot = cache.appendingPathComponent(".corrupt", isDirectory: true)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: corruptRoot.path).count,
            1
        )
        try await rebuilt.close()
    }

    func testCacheKeyChangesForEveryStableIdentityDimensionAndHasNoDelimiterCollision()
        throws
    {
        let trace = String(repeating: "a", count: 64)
        let binary = String(repeating: "b", count: 64)
        let base = try TraceCacheKey(
            traceSHA256: trace,
            parserBinarySHA256: binary,
            upstreamRevision: "revision",
            schemaAdapterVersion: "2",
            indexSchemaVersion: 1
        )
        let variants = [
            try TraceCacheKey(
                traceSHA256: String(repeating: "c", count: 64),
                parserBinarySHA256: binary,
                upstreamRevision: "revision",
                schemaAdapterVersion: "2",
                indexSchemaVersion: 1
            ),
            try TraceCacheKey(
                traceSHA256: trace,
                parserBinarySHA256: String(repeating: "d", count: 64),
                upstreamRevision: "revision",
                schemaAdapterVersion: "2",
                indexSchemaVersion: 1
            ),
            try TraceCacheKey(
                traceSHA256: trace,
                parserBinarySHA256: binary,
                upstreamRevision: "revision-next",
                schemaAdapterVersion: "2",
                indexSchemaVersion: 1
            ),
            try TraceCacheKey(
                traceSHA256: trace,
                parserBinarySHA256: binary,
                upstreamRevision: "revision",
                schemaAdapterVersion: "3",
                indexSchemaVersion: 1
            ),
            try TraceCacheKey(
                traceSHA256: trace,
                parserBinarySHA256: binary,
                upstreamRevision: "revision",
                schemaAdapterVersion: "2",
                indexSchemaVersion: 2
            ),
        ]
        XCTAssertTrue(variants.allSatisfy { $0 != base })
        XCTAssertEqual(Set([base] + variants).count, variants.count + 1)

        let left = try TraceCacheKey(
            traceSHA256: trace,
            parserBinarySHA256: binary,
            upstreamRevision: "a|b",
            schemaAdapterVersion: "c",
            indexSchemaVersion: 1
        )
        let right = try TraceCacheKey(
            traceSHA256: trace,
            parserBinarySHA256: binary,
            upstreamRevision: "a",
            schemaAdapterVersion: "b|c",
            indexSchemaVersion: 1
        )
        XCTAssertNotEqual(left.parserKey, right.parserKey)
    }

    func testCachePromotionIsInvisibleUntilAtomicRename() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cache-atomic-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parser = CountingParser(
            base: try TraceStreamerProcessParser(executableURL: binary)
        )
        let barrier = PromotionBarrier()
        let task = Task {
            try await TraceSession.openCached(
                source: fixture,
                parser: parser,
                stagingDirectory: staging,
                cacheDirectory: cache,
                hooks: TraceCacheTestHooks(beforePromotion: { barrier.pause(at: $0) })
            )
        }
        let publicEntry = await barrier.waitUntilReached()
        XCTAssertFalse(FileManager.default.fileExists(atPath: publicEntry.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: publicEntry.appendingPathComponent("database.sqlite").path
            )
        )
        barrier.resume()
        let session = try await task.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: publicEntry.path))
        try await session.close()
    }

    func testPrivateBuildSessionAndReadyEntryCarryCrashOwnerEvidence() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cache-owner-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let barrier = PromotionBarrier()
        let task = Task {
            try await TraceSession.openCached(
                source: fixture,
                parser: try TraceStreamerProcessParser(executableURL: binary),
                stagingDirectory: staging,
                cacheDirectory: cache,
                hooks: TraceCacheTestHooks(beforePromotion: { barrier.pause(at: $0) })
            )
        }
        let publicEntry = await barrier.waitUntilReached()
        let sessionOwners = staging.appendingPathComponent(".owners", isDirectory: true)
        let buildOwners = cache.appendingPathComponent(".staging/.owners", isDirectory: true)
        let sessionMarker = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: sessionOwners,
                includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "lock" }
        )
        let buildMarker = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: buildOwners,
                includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "lock" }
        )
        XCTAssertFalse(canAcquireExclusiveLock(at: sessionMarker))
        XCTAssertFalse(canAcquireExclusiveLock(at: buildMarker))
        XCTAssertEqual(try permissions(at: sessionMarker), 0o600)
        XCTAssertEqual(try permissions(at: buildMarker), 0o600)

        barrier.resume()
        let session = try await task.value
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: sessionOwners.path).isEmpty)
        let readyOwners = try FileManager.default.contentsOfDirectory(
            at: buildOwners,
            includingPropertiesForKeys: nil
        )
        let readyMarker = try XCTUnwrap(readyOwners.first { $0.pathExtension == "lock" })
        let readyEvidenceURL = try XCTUnwrap(
            readyOwners.first { $0.pathExtension == "json" }
        )
        XCTAssertTrue(canAcquireExclusiveLock(at: readyMarker))
        let readyEvidence = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: readyEvidenceURL))
                as? [String: Any]
        )
        XCTAssertEqual(readyEvidence["state"] as? String, "ready")
        let relativePath = try XCTUnwrap(readyEvidence["relativePath"] as? String)
        XCTAssertEqual(cache.appendingPathComponent(relativePath), publicEntry)
        try await session.close()
    }

    func testCancellationAfterPromotionQuarantinesOwnedReadyEntry() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cache-promote-cancel-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parser = CountingParser(
            base: try TraceStreamerProcessParser(executableURL: binary)
        )
        let barrier = PromotionBarrier()
        let task = Task {
            try await TraceSession.openCached(
                source: fixture,
                parser: parser,
                stagingDirectory: staging,
                cacheDirectory: cache,
                hooks: TraceCacheTestHooks(afterPromotion: { barrier.pause(at: $0) })
            )
        }
        let publicEntry = await barrier.waitUntilReached()
        XCTAssertTrue(FileManager.default.fileExists(atPath: publicEntry.path))
        task.cancel()
        barrier.resume()
        do {
            _ = try await task.value
            XCTFail("cancelled post-promotion open must not return Ready")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .cancelled)
            XCTAssertEqual(error.stage, .openingDatabase)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: publicEntry.path))
        let corruptRoot = cache.appendingPathComponent(".corrupt", isDirectory: true)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: corruptRoot.path).count,
            1
        )
        XCTAssertTrue(
            try publicSessionEntries(at: staging).isEmpty
        )
    }

    func testCancellationAtMissReadyHandoffRollsBackPublicEntry() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cache-handoff-cancel-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = PromotionBarrier()
        let task = Task {
            try await TraceSession.openCached(
                source: fixture,
                parser: try TraceStreamerProcessParser(executableURL: binary),
                stagingDirectory: staging,
                cacheDirectory: cache,
                hooks: TraceCacheTestHooks(
                    beforeReadyHandoff: { entry, _ in handoff.pause(at: entry) }
                )
            )
        }
        let publicEntry = await handoff.waitUntilReached()
        XCTAssertTrue(FileManager.default.fileExists(atPath: publicEntry.path))
        task.cancel()
        handoff.resume()
        do {
            _ = try await task.value
            XCTFail("cancelled miss handoff must not return Ready")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .cancelled)
            XCTAssertEqual(error.stage, .openingDatabase)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: publicEntry.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: cache.appendingPathComponent(".corrupt").path
            ).count,
            1
        )
        XCTAssertTrue(try publicSessionEntries(at: staging).isEmpty)
    }

    func testPromotionRejectsBuildPathReplacementAfterSourceIdentityCheck() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cache-source-swap-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entryRecorder = URLRecorder()
        do {
            _ = try await TraceSession.openCached(
                source: fixture,
                parser: try TraceStreamerProcessParser(executableURL: binary),
                stagingDirectory: staging,
                cacheDirectory: cache,
                hooks: TraceCacheTestHooks(
                    beforePromotion: { entryRecorder.record($0) },
                    promotionSourceValidated: { build in
                        try Self.replacePromotionBuild(at: build)
                    },
                    beforePromotionBuildCleanup: { original in
                        let movedAgain = original.deletingLastPathComponent()
                            .appendingPathComponent(
                                ".moved-again-\(original.lastPathComponent)",
                                isDirectory: true
                            )
                        try FileManager.default.moveItem(at: original, to: movedAgain)
                    }
                )
            )
            XCTFail("a replaced promotion source must fail closed")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .traceCacheCorrupt)
            XCTAssertEqual(error.details["reason"], "cacheIO")
        }
        let publicEntry = try XCTUnwrap(entryRecorder.snapshot())
        XCTAssertFalse(FileManager.default.fileExists(atPath: publicEntry.path))
        let corruptRoot = cache.appendingPathComponent(".corrupt", isDirectory: true)
        let quarantines = try FileManager.default.contentsOfDirectory(
            at: corruptRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(quarantines.count, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: quarantines[0].appendingPathComponent("marker").path
            )
        )
        let buildStaging = cache.appendingPathComponent(".staging", isDirectory: true)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: buildStaging.path)
                .filter { $0 != ".owners" }
                .isEmpty
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: buildStaging.appendingPathComponent(".owners").path
            ).isEmpty
        )
        XCTAssertTrue(try publicSessionEntries(at: staging).isEmpty)
    }

    func testPromotionMismatchIsolationFailureRetainsOwnerEvidence() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cache-source-swap-fail-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entryRecorder = URLRecorder()
        do {
            _ = try await TraceSession.openCached(
                source: fixture,
                parser: try TraceStreamerProcessParser(executableURL: binary),
                stagingDirectory: staging,
                cacheDirectory: cache,
                hooks: TraceCacheTestHooks(
                    beforePromotion: { entryRecorder.record($0) },
                    rollbackInitialProbe: { _ in
                        throw CocoaError(.fileWriteNoPermission)
                    },
                    promotionDestinationRenamed: { entry in
                        try Self.replacePromotionBuild(at: entry)
                    }
                )
            )
            XCTFail("failed mismatch isolation must not return Ready")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .traceCacheCorrupt)
            XCTAssertEqual(error.details["reason"], "cacheCleanupFailed")
            XCTAssertFalse(error.message.contains(root.path))
            XCTAssertFalse(error.details.values.contains { $0.contains(root.path) })
        }
        let publicEntry = try XCTUnwrap(entryRecorder.snapshot())
        // The injected isolation failure leaves the exact unexpected public
        // direntry visible, but the call fails closed and retains the original
        // build plus its stale owner marker for a later safe retry.
        XCTAssertTrue(FileManager.default.fileExists(atPath: publicEntry.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: publicEntry.appendingPathComponent("marker").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: publicEntry.deletingLastPathComponent()
                    .appendingPathComponent(
                        ".displaced-\(publicEntry.lastPathComponent)",
                        isDirectory: true
                    ).path
            )
        )
        let buildStaging = cache.appendingPathComponent(".staging", isDirectory: true)
        let residuals = try FileManager.default.contentsOfDirectory(atPath: buildStaging.path)
            .filter { $0 != ".owners" }
        XCTAssertTrue(residuals.isEmpty)
        let owners = try FileManager.default.contentsOfDirectory(
            at: buildStaging.appendingPathComponent(".owners", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        let markers = owners.filter { $0.pathExtension == "lock" }
        let evidenceFiles = owners.filter { $0.pathExtension == "json" }
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(evidenceFiles.count, 1)
        XCTAssertTrue(canAcquireExclusiveLock(at: markers[0]))
        let evidenceData = try Data(contentsOf: evidenceFiles[0])
        let evidence = try XCTUnwrap(
            JSONSerialization.jsonObject(with: evidenceData) as? [String: Any]
        )
        XCTAssertEqual(evidence["formatVersion"] as? Int, 1)
        let relativePath = try XCTUnwrap(evidence["relativePath"] as? String)
        let evidencedDirectory = cache.appendingPathComponent(relativePath)
            .standardizedFileURL
        let displacedOriginal = publicEntry.deletingLastPathComponent()
            .appendingPathComponent(
                ".displaced-\(publicEntry.lastPathComponent)",
                isDirectory: true
            ).standardizedFileURL
        XCTAssertEqual(evidencedDirectory, displacedOriginal)
        var evidencedInfo = stat()
        XCTAssertEqual(
            evidencedDirectory.path.withCString { Darwin.lstat($0, &evidencedInfo) },
            0
        )
        XCTAssertEqual(
            (evidence["device"] as? NSNumber)?.uint64Value,
            UInt64(evidencedInfo.st_dev)
        )
        XCTAssertEqual(
            (evidence["inode"] as? NSNumber)?.uint64Value,
            UInt64(evidencedInfo.st_ino)
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: cache.appendingPathComponent(".corrupt").path
            ).isEmpty
        )
        XCTAssertTrue(try publicSessionEntries(at: staging).isEmpty)
    }

    func testPromotionRelocationOutsideRecoveryRootPreservesSafeEvidence() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cache-outside-relocation-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let outside = root.appendingPathComponent("outside-original", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await TraceSession.openCached(
                source: fixture,
                parser: try TraceStreamerProcessParser(executableURL: binary),
                stagingDirectory: staging,
                cacheDirectory: cache,
                hooks: TraceCacheTestHooks(
                    promotionSourceValidated: { build in
                        try Self.replacePromotionBuild(at: build)
                    },
                    beforePromotionBuildCleanup: { original in
                        try FileManager.default.moveItem(at: original, to: outside)
                    }
                )
            )
            XCTFail("root-external relocation must fail closed")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .traceCacheCorrupt)
            XCTAssertEqual(error.details["reason"], "cacheCleanupFailed")
            XCTAssertFalse(error.message.contains(root.path))
            XCTAssertFalse(error.details.values.contains { $0.contains(root.path) })
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        var outsideInfo = stat()
        XCTAssertEqual(outside.path.withCString { Darwin.lstat($0, &outsideInfo) }, 0)
        let ownersRoot = cache.appendingPathComponent(".staging/.owners", isDirectory: true)
        let owners = try FileManager.default.contentsOfDirectory(
            at: ownersRoot,
            includingPropertiesForKeys: nil
        )
        let marker = try XCTUnwrap(owners.first { $0.pathExtension == "lock" })
        let evidenceURL = try XCTUnwrap(owners.first { $0.pathExtension == "json" })
        XCTAssertTrue(canAcquireExclusiveLock(at: marker))
        let evidence = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: evidenceURL))
                as? [String: Any]
        )
        let relativePath = try XCTUnwrap(evidence["relativePath"] as? String)
        XCTAssertFalse(relativePath.isEmpty)
        XCTAssertFalse(relativePath.hasPrefix("/"))
        XCTAssertFalse(relativePath.split(separator: "/").contains(".."))
        XCTAssertEqual(
            (evidence["device"] as? NSNumber)?.uint64Value,
            UInt64(outsideInfo.st_dev)
        )
        XCTAssertEqual(
            (evidence["inode"] as? NSNumber)?.uint64Value,
            UInt64(outsideInfo.st_ino)
        )
    }

    func testPromotionEvidenceCommitRejectsRelocationToCacheSibling() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cache-evidence-sibling-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let publicEntry = URLRecorder()
        let relocatedEntry = URLRecorder()
        do {
            _ = try await TraceSession.openCached(
                source: fixture,
                parser: try TraceStreamerProcessParser(executableURL: binary),
                stagingDirectory: staging,
                cacheDirectory: cache,
                hooks: TraceCacheTestHooks(
                    beforePromotion: { publicEntry.record($0) },
                    beforePromotionEvidenceCommit: { entry in
                        let sibling = cache.appendingPathComponent(
                            ".post-promote-\(UUID().uuidString)",
                            isDirectory: true
                        )
                        try FileManager.default.moveItem(at: entry, to: sibling)
                        relocatedEntry.record(sibling)
                    }
                )
            )
            XCTFail("a relocated promoted entry must not be committed")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .traceCacheCorrupt)
            XCTAssertEqual(error.details["reason"], "cacheIO")
        }
        let entry = try XCTUnwrap(publicEntry.snapshot())
        let sibling = try XCTUnwrap(relocatedEntry.snapshot())
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: cache.appendingPathComponent(".staging/.owners").path
            ).isEmpty
        )
        XCTAssertTrue(try publicSessionEntries(at: staging).isEmpty)
    }

    func testPromotionEvidenceCommitOutsideRecoveryRootRetainsOwnerEvidence() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cache-evidence-outside-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let outside = root.appendingPathComponent("outside-promoted", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let publicEntry = URLRecorder()
        do {
            _ = try await TraceSession.openCached(
                source: fixture,
                parser: try TraceStreamerProcessParser(executableURL: binary),
                stagingDirectory: staging,
                cacheDirectory: cache,
                hooks: TraceCacheTestHooks(
                    beforePromotion: { publicEntry.record($0) },
                    beforePromotionEvidenceCommit: { entry in
                        try FileManager.default.moveItem(at: entry, to: outside)
                    }
                )
            )
            XCTFail("a root-external promoted entry must fail closed")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .traceCacheCorrupt)
            XCTAssertEqual(error.details["reason"], "cacheCleanupFailed")
            XCTAssertFalse(error.message.contains(root.path))
            XCTAssertFalse(error.details.values.contains { $0.contains(root.path) })
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: try XCTUnwrap(publicEntry.snapshot()).path)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        let ownersRoot = cache.appendingPathComponent(".staging/.owners", isDirectory: true)
        let owners = try FileManager.default.contentsOfDirectory(
            at: ownersRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(owners.filter { $0.pathExtension == "lock" }.count, 1)
        let evidenceURL = try XCTUnwrap(owners.first { $0.pathExtension == "json" })
        let evidence = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: evidenceURL))
                as? [String: Any]
        )
        let relativePath = try XCTUnwrap(evidence["relativePath"] as? String)
        XCTAssertFalse(relativePath.hasPrefix("/"))
        XCTAssertFalse(relativePath.split(separator: "/").contains(".."))
    }

    func testPromotionRelocationAfterFinalIdentityCheckRetainsReadyEvidence() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cache-final-commit-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let publicEntry = URLRecorder()
        let relocatedEntry = URLRecorder()
        do {
            _ = try await TraceSession.openCached(
                source: fixture,
                parser: try TraceStreamerProcessParser(executableURL: binary),
                stagingDirectory: staging,
                cacheDirectory: cache,
                hooks: TraceCacheTestHooks(
                    beforePromotion: { publicEntry.record($0) },
                    afterPromotionFinalIdentityCheck: { entry in
                        let sibling = cache.appendingPathComponent(
                            ".after-final-check-\(UUID().uuidString)",
                            isDirectory: true
                        )
                        try FileManager.default.moveItem(at: entry, to: sibling)
                        try FileManager.default.copyItem(at: sibling, to: entry)
                        relocatedEntry.record(sibling)
                    }
                )
            )
            XCTFail("a post-check relocation must not return a Ready session")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .traceCacheCorrupt)
            XCTAssertEqual(error.details["reason"], "cacheIO")
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: try XCTUnwrap(publicEntry.snapshot()).path)
        )
        let sibling = try XCTUnwrap(relocatedEntry.snapshot())
        XCTAssertFalse(FileManager.default.fileExists(atPath: sibling.path))
        let ownersRoot = cache.appendingPathComponent(".staging/.owners", isDirectory: true)
        let owners = try FileManager.default.contentsOfDirectory(
            at: ownersRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(owners.isEmpty)
    }

    func testReadyHandoffRejectsValidPublicReplacement() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cache-handoff-swap-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = URLRecorder()
        let relocated = URLRecorder()
        do {
            _ = try await TraceSession.openCached(
                source: fixture,
                parser: try TraceStreamerProcessParser(executableURL: binary),
                stagingDirectory: staging,
                cacheDirectory: cache,
                hooks: TraceCacheTestHooks(
                    beforeReadyHandoff: { entry, _ in
                        original.record(entry)
                        let sibling = cache.appendingPathComponent(
                            ".handoff-original-\(UUID().uuidString)",
                            isDirectory: true
                        )
                        do {
                            try FileManager.default.moveItem(at: entry, to: sibling)
                            try FileManager.default.copyItem(at: sibling, to: entry)
                        } catch {
                            XCTFail("failed to install deterministic handoff replacement")
                            return
                        }
                        relocated.record(sibling)
                    }
                )
            )
            XCTFail("handoff must remain bound to the promoted directory inode")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .traceCacheCorrupt)
            XCTAssertEqual(error.details["reason"], "cacheIO")
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: try XCTUnwrap(original.snapshot()).path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: try XCTUnwrap(relocated.snapshot()).path)
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: cache.appendingPathComponent(".staging/.owners").path
            ).isEmpty
        )
    }

    func testReadyHandoffRejectsRepositoryDirectoryABA() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cache-repository-aba-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalSibling = URLRecorder()
        let replacementSibling = URLRecorder()
        do {
            _ = try await TraceSession.openCached(
                source: fixture,
                parser: try TraceStreamerProcessParser(executableURL: binary),
                stagingDirectory: staging,
                cacheDirectory: cache,
                hooks: TraceCacheTestHooks(
                    afterPromotion: { entry in
                        let original = cache.appendingPathComponent(
                            ".aba-original-\(UUID().uuidString)",
                            isDirectory: true
                        )
                        do {
                            try FileManager.default.moveItem(at: entry, to: original)
                            try FileManager.default.copyItem(at: original, to: entry)
                            originalSibling.record(original)
                        } catch {
                            XCTFail("failed to install ABA replacement")
                        }
                    },
                    beforeReadyHandoff: { entry, _ in
                        guard let original = originalSibling.snapshot() else {
                            XCTFail("missing ABA original")
                            return
                        }
                        let replacement = cache.appendingPathComponent(
                            ".aba-replacement-\(UUID().uuidString)",
                            isDirectory: true
                        )
                        do {
                            try FileManager.default.moveItem(at: entry, to: replacement)
                            try FileManager.default.moveItem(at: original, to: entry)
                            replacementSibling.record(replacement)
                        } catch {
                            XCTFail("failed to restore ABA original")
                        }
                    }
                )
            )
            XCTFail("repository connection must remain bound to the public database inode")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .traceCacheCorrupt)
            XCTAssertEqual(error.details["reason"], "cacheIO")
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: try XCTUnwrap(replacementSibling.snapshot()).path
            )
        )
        XCTAssertTrue(try publicSessionEntries(at: staging).isEmpty)
    }

    func testCacheMissReadyHandoffRejectsMetadataReplacement() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cache-miss-metadata-swap-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await TraceSession.openCached(
                source: fixture,
                parser: try TraceStreamerProcessParser(executableURL: binary),
                stagingDirectory: staging,
                cacheDirectory: cache,
                hooks: TraceCacheTestHooks(
                    beforeReadyHandoff: { entry, _ in
                        let metadata = entry.appendingPathComponent("metadata.json")
                        let original = cache.appendingPathComponent(
                            ".miss-metadata-original-\(UUID().uuidString)"
                        )
                        do {
                            try FileManager.default.moveItem(at: metadata, to: original)
                            try FileManager.default.copyItem(at: original, to: metadata)
                        } catch {
                            XCTFail("failed to install metadata replacement")
                        }
                    }
                )
            )
            XCTFail("miss handoff must remain bound to validated metadata bytes")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .traceCacheCorrupt)
            XCTAssertEqual(error.details["reason"], "cacheIO")
        }
    }

    func testCacheHitMetadataReplacementIsQuarantinedAndRebuilt() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cache-hit-metadata-swap-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parser = CountingParser(
            base: try TraceStreamerProcessParser(executableURL: binary)
        )
        let seeded = try await TraceSession.openCached(
            source: fixture,
            parser: parser,
            stagingDirectory: staging,
            cacheDirectory: cache
        )
        try await seeded.close()
        let firstHandoff = OneShotFlag()
        let reopened = try await TraceSession.openCached(
            source: fixture,
            parser: parser,
            stagingDirectory: staging,
            cacheDirectory: cache,
            hooks: TraceCacheTestHooks(
                beforeReadyHandoff: { entry, _ in
                    guard firstHandoff.take() else { return }
                    let metadata = entry.appendingPathComponent("metadata.json")
                    let original = cache.appendingPathComponent(
                        ".hit-metadata-original-\(UUID().uuidString)"
                    )
                    do {
                        try FileManager.default.moveItem(at: metadata, to: original)
                        try FileManager.default.copyItem(at: original, to: metadata)
                    } catch {
                        XCTFail("failed to install metadata replacement")
                    }
                }
            )
        )
        let wasHit = await reopened.cacheHit
        XCTAssertFalse(wasHit)
        XCTAssertEqual(parser.count(), 2)
        try await reopened.close()
    }

    func testOwnerEvidenceReplacementFailurePreservesLastCommittedJSON() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-owner-evidence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try await TraceContentAddressedCache.createOwnedDirectory(
            root: root,
            prefix: "session-"
        )
        let previous = try Data(contentsOf: directory.ownerEvidenceURL)
        do {
            try TraceContentAddressedCache.updateOwnerEvidence(
                for: directory,
                beforeReplace: { temporary in
                    let descriptor = temporary.path.withCString {
                        Darwin.open($0, O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC)
                    }
                    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
                    defer { _ = Darwin.close(descriptor) }
                    var partial = UInt8(ascii: "{")
                    guard Darwin.write(descriptor, &partial, 1) == 1,
                        Darwin.fsync(descriptor) == 0
                    else { throw CocoaError(.fileWriteUnknown) }
                    throw CocoaError(.fileWriteNoPermission)
                }
            )
            XCTFail("injected evidence replace failure must throw")
        } catch {}
        let afterFailure = try Data(contentsOf: directory.ownerEvidenceURL)
        XCTAssertEqual(afterFailure, previous)
        let evidence = try XCTUnwrap(
            JSONSerialization.jsonObject(with: afterFailure) as? [String: Any]
        )
        XCTAssertEqual(evidence["formatVersion"] as? Int, 1)
        XCTAssertEqual(
            (evidence["device"] as? NSNumber)?.uint64Value,
            directory.device
        )
        XCTAssertEqual(
            (evidence["inode"] as? NSNumber)?.uint64Value,
            directory.inode
        )
        try await TraceContentAddressedCache.removeOwnedDirectory(
            directory,
            removalHook: nil
        )
    }

    func testOwnedDirectoryHandleCreationFailureCleansDirectoryAndEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-owner-handle-fail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await TraceContentAddressedCache.createOwnedDirectory(
                root: root,
                prefix: "session-",
                handleCreationHook: { _ in throw CocoaError(.fileReadNoPermission) }
            )
            XCTFail("injected handle creation failure must throw")
        } catch {}
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(contents, [".owners"])
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: root.appendingPathComponent(".owners").path
            ).isEmpty
        )
    }

    func testOwnedDirectoryIdentityFailureDoesNotDeletePathReplacement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-owner-identity-swap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let originalPath = URLRecorder()
        do {
            _ = try await TraceContentAddressedCache.createOwnedDirectory(
                root: root,
                prefix: "session-",
                identityReadyHook: { directory in
                    originalPath.record(directory)
                    try Self.replacePromotionBuild(at: directory)
                    throw CancellationError()
                }
            )
            XCTFail("cancelled identity setup must not return an owned directory")
        } catch is CancellationError {}
        let replacement = try XCTUnwrap(originalPath.snapshot())
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
        XCTAssertEqual(
            try String(
                contentsOf: replacement.appendingPathComponent("marker"),
                encoding: .utf8
            ),
            "replacement"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: replacement.deletingLastPathComponent()
                    .appendingPathComponent(
                        ".displaced-\(replacement.lastPathComponent)",
                        isDirectory: true
                    ).path
            )
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: root.appendingPathComponent(".owners").path
            ).isEmpty
        )
    }

    func testInjectedInitialDirectoryOpenFailureRetainsBoundedCreatingEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-owner-unbound-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await TraceContentAddressedCache.createOwnedDirectory(
                root: root,
                prefix: "session-",
                injectDirectoryHandleOpenFailure: true
            )
            XCTFail("an unbound created directory must fail closed")
        } catch is TraceStorageTransactionError {}
        let residual = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix("session-") }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: residual.path))
        let ownersRoot = root.appendingPathComponent(".owners", isDirectory: true)
        let owners = try FileManager.default.contentsOfDirectory(
            at: ownersRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(owners.filter { $0.pathExtension == "lock" }.count, 1)
        let evidenceURL = try XCTUnwrap(owners.first { $0.pathExtension == "json" })
        let evidence = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: evidenceURL))
                as? [String: Any]
        )
        XCTAssertEqual(evidence["state"] as? String, "creating")
        XCTAssertNil(evidence["device"])
        XCTAssertNil(evidence["inode"])
        let relativePath = try XCTUnwrap(evidence["relativePath"] as? String)
        XCTAssertFalse(relativePath.isEmpty)
        XCTAssertFalse(relativePath.hasPrefix("/"))
        XCTAssertFalse(relativePath.split(separator: "/").contains(".."))
    }

    func testFirstReentrantDirectoryHookRunsAfterIdentityBinding() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-owner-bound-swap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let publicPath = URLRecorder()
        let directory = try await TraceContentAddressedCache.createOwnedDirectory(
            root: root,
            prefix: "session-",
            directoryBindingHook: { path in
                publicPath.record(path)
                try Self.replacePromotionBuild(at: path)
            }
        )
        let replacement = try XCTUnwrap(publicPath.snapshot())
        XCTAssertNotEqual(directory.url, replacement)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: replacement.appendingPathComponent("marker").path
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.url.path))
        try await TraceContentAddressedCache.removeOwnedDirectory(
            directory,
            removalHook: nil
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.url.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: replacement.appendingPathComponent("marker").path
            )
        )
    }

    func testOwnedDirectoryMkdirEEXISTNeverClaimsForeignDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-owner-mkdir-race-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let foreign = URLRecorder()
        do {
            _ = try await TraceContentAddressedCache.createOwnedDirectory(
                root: root,
                prefix: "session-",
                beforeDirectoryMkdirHook: { target in
                    foreign.record(target)
                    try FileManager.default.createDirectory(
                        at: target,
                        withIntermediateDirectories: false
                    )
                    try Data("foreign".utf8).write(
                        to: target.appendingPathComponent("marker")
                    )
                }
            )
            XCTFail("mkdir EEXIST must not claim a foreign directory")
        } catch {}
        let target = try XCTUnwrap(foreign.snapshot())
        XCTAssertEqual(
            try String(contentsOf: target.appendingPathComponent("marker")),
            "foreign"
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: root.appendingPathComponent(".owners").path
            ).isEmpty
        )
    }

    func testCacheLeaseCoversHitValidationThroughReadyHandoff() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cache-hit-lease-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parser = CountingParser(
            base: try TraceStreamerProcessParser(executableURL: binary)
        )
        let seeded = try await TraceSession.openCached(
            source: fixture,
            parser: parser,
            stagingDirectory: staging,
            cacheDirectory: cache
        )
        let seededMetadata = await seeded.cacheMetadata
        let metadata = try XCTUnwrap(seededMetadata)
        try await seeded.close()

        let validation = CancellationBarrier()
        let openTask = Task {
            try await TraceSession.openCached(
                source: fixture,
                parser: parser,
                stagingDirectory: staging,
                cacheDirectory: cache,
                repositoryValidationHook: { await validation.pauseUntilCancelled() }
            )
        }
        await validation.waitUntilReached()
        let contention = OneShotSignal()
        let mutation = PromotionBarrier()
        let mutationTask = Task {
            try await TraceContentAddressedCache.withExclusiveEntryMutation(
                cacheDirectory: cache,
                key: metadata.cacheKey,
                contentionHook: { contention.signal() },
                operation: { mutation.pause(at: $0) }
            )
        }
        await contention.wait()
        XCTAssertFalse(mutation.hasReached())
        openTask.cancel()
        do {
            _ = try await openTask.value
            XCTFail("cancelled hit validation must not return Ready")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .cancelled)
        }
        _ = await mutation.waitUntilReached()
        mutation.resume()
        try await mutationTask.value
    }

    func testCacheLeaseCoversMissPromotionThroughReadyHandoff() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cache-miss-lease-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = PromotionBarrier()
        let parser = CountingParser(
            base: try TraceStreamerProcessParser(executableURL: binary)
        )
        let task = Task {
            try await TraceSession.openCached(
                source: fixture,
                parser: parser,
                stagingDirectory: staging,
                cacheDirectory: cache,
                hooks: TraceCacheTestHooks(
                    beforeReadyHandoff: { entry, _ in handoff.pause(at: entry) }
                )
            )
        }
        _ = await handoff.waitUntilReached()
        XCTAssertFalse(task.isCancelled)
        // The miss owns the key lock and exclusive lease through this barrier;
        // an external mutation cannot enter before the Ready handoff finishes.
        let metadataData = try Data(contentsOf: try XCTUnwrap(
            FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .first { $0.lastPathComponent == "metadata.json" }
        ))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(TraceCacheMetadata.self, from: metadataData)
        let mutation = PromotionBarrier()
        let mutationTask = Task {
            try await TraceContentAddressedCache.withExclusiveEntryMutation(
                cacheDirectory: cache,
                key: metadata.cacheKey,
                operation: { mutation.pause(at: $0) }
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(mutation.hasReached())
        handoff.resume()
        let session = try await task.value
        try await session.close()
        _ = await mutation.waitUntilReached()
        mutation.resume()
        try await mutationTask.value
    }

    func testCacheRollbackProbeFailureOverridesCancellationWithoutPaths() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cache-probe-fail-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let barrier = PromotionBarrier()
        let task = Task {
            try await TraceSession.openCached(
                source: fixture,
                parser: try TraceStreamerProcessParser(executableURL: binary),
                stagingDirectory: staging,
                cacheDirectory: cache,
                hooks: TraceCacheTestHooks(
                    afterPromotion: { barrier.pause(at: $0) },
                    rollbackInitialProbe: { _ in throw CocoaError(.fileReadNoPermission) }
                )
            )
        }
        let publicEntry = await barrier.waitUntilReached()
        task.cancel()
        barrier.resume()
        do {
            _ = try await task.value
            XCTFail("rollback probe failure must fail closed")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .traceCacheCorrupt)
            XCTAssertEqual(error.details["reason"], "cacheCleanupFailed")
            XCTAssertFalse(error.message.contains(root.path))
            XCTAssertFalse(error.details.values.contains { $0.contains(root.path) })
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: publicEntry.path))
    }

    func testEphemeralSessionCloseRemovesReadyDatabase() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-ephemeral-close-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let session = try await TraceSession.open(
            source: fixture,
            parser: try TraceStreamerProcessParser(executableURL: binary),
            stagingDirectory: staging,
            storagePolicy: .ephemeral
        )
        let parsed = await session.parsed
        let cacheHit = await session.cacheHit
        XCTAssertFalse(cacheHit)
        XCTAssertTrue(FileManager.default.fileExists(atPath: parsed.databaseURL.path))
        try await session.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: parsed.databaseURL.path))
        XCTAssertTrue(
            try publicSessionEntries(at: staging).isEmpty
        )
    }

    func testEphemeralReadyHandoffRejectsDirectoryAndRepositoryABA() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-ephemeral-handoff-aba-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let publicPath = URLRecorder()
        let originalSibling = URLRecorder()
        do {
            _ = try await TraceSession.open(
                source: fixture,
                parser: try TraceStreamerProcessParser(executableURL: binary),
                stagingDirectory: staging,
                repositoryValidationHook: {
                    do {
                        let entry = try XCTUnwrap(
                            try FileManager.default.contentsOfDirectory(
                                at: staging,
                                includingPropertiesForKeys: nil
                            ).first { $0.lastPathComponent.hasPrefix("session-") }
                        )
                        let sibling = staging.appendingPathComponent(
                            ".ephemeral-original-\(UUID().uuidString)",
                            isDirectory: true
                        )
                        try FileManager.default.moveItem(at: entry, to: sibling)
                        try FileManager.default.copyItem(at: sibling, to: entry)
                        publicPath.record(entry)
                        originalSibling.record(sibling)
                    } catch {
                        XCTFail("failed to install ephemeral ABA replacement")
                    }
                }
            )
            XCTFail("ephemeral handoff must bind its directory and opened database")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .traceDatabaseInvalid)
            XCTAssertEqual(error.stage, .openingDatabase)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: try XCTUnwrap(publicPath.snapshot()).path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: try XCTUnwrap(originalSibling.snapshot()).path
            )
        )
    }

    func testEphemeralCloseFailureRetainsOwnershipForSerializedRetry() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-ephemeral-close-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let probe = BlockingOneShotProbeFailure()
        let session = try await TraceSession.open(
            source: fixture,
            parser: try TraceStreamerProcessParser(executableURL: binary),
            stagingDirectory: staging,
            repositoryValidationHook: nil,
            directoryInitialProbeHook: { try probe.invoke($0) }
        )
        let parsed = await session.parsed
        let first = Task { try await session.close() }
        await probe.waitUntilReached()
        let second = Task { try await session.close() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(probe.count(), 1)
        probe.resume()
        for close in [first, second] {
            do {
                try await close.value
                XCTFail("all waiters must observe the shared cleanup failure")
            } catch let error as ArkTraceError {
                XCTAssertEqual(error.code, .traceParseFailed)
                XCTAssertEqual(error.details["reason"], "sessionCleanupFailed")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: parsed.databaseURL.path))
        XCTAssertEqual(probe.count(), 1)

        try await session.close()
        XCTAssertEqual(probe.count(), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parsed.databaseURL.path))
        XCTAssertTrue(try publicSessionEntries(at: staging).isEmpty)
    }

    func testEphemeralStagingRootSymlinkIsRejectedWithoutWriteThrough() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-ephemeral-symlink-\(UUID().uuidString)")
        let victim = root.appendingPathComponent("victim", isDirectory: true)
        let stagingLink = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: stagingLink, withDestinationURL: victim)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await TraceSession.open(
                source: fixture,
                parser: try TraceStreamerProcessParser(executableURL: binary),
                stagingDirectory: stagingLink,
                storagePolicy: .ephemeral
            )
            XCTFail("ephemeral staging symlink must fail closed")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .traceParseFailed)
            XCTAssertEqual(error.stage, .preparing)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: victim.path).isEmpty)
    }

    func testEphemeralCancellationCleanupFailureOverridesCancelled() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-ephemeral-cleanup-fail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let barrier = CancellationBarrier()
        let task = Task {
            try await TraceSession.open(
                source: fixture,
                parser: try TraceStreamerProcessParser(executableURL: binary),
                stagingDirectory: staging,
                repositoryValidationHook: { await barrier.pauseUntilCancelled() },
                directoryRemovalHook: { _ in throw CocoaError(.fileWriteNoPermission) }
            )
        }
        await barrier.waitUntilReached()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cleanup failure must override cancellation")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .traceParseFailed)
            XCTAssertEqual(error.stage, .openingDatabase)
            XCTAssertEqual(error.details["reason"], "sessionCleanupFailed")
            XCTAssertFalse(error.message.contains(staging.path))
            XCTAssertFalse(error.details.values.contains { $0.contains(staging.path) })
        }
        let publicSessions = try FileManager.default.contentsOfDirectory(atPath: staging.path)
            .filter { $0.hasPrefix("session-") }
        XCTAssertTrue(publicSessions.isEmpty)
        let quarantines = try FileManager.default.contentsOfDirectory(atPath: staging.path)
            .filter { $0.hasPrefix(".arktrace-cleanup-") }
        XCTAssertEqual(quarantines.count, 1)
    }

    func testCacheRootSymlinkIsRejectedWithoutWritingThroughIt() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-cache-symlink-\(UUID().uuidString)")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let victim = root.appendingPathComponent("victim", isDirectory: true)
        let cacheLink = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cacheLink, withDestinationURL: victim)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await TraceSession.openCached(
                source: fixture,
                parser: try TraceStreamerProcessParser(executableURL: binary),
                stagingDirectory: staging,
                cacheDirectory: cacheLink
            )
            XCTFail("cache root symlink must fail closed")
        } catch let error as ArkTraceError {
            XCTAssertEqual(error.code, .traceCacheCorrupt)
            XCTAssertEqual(error.stage, .cacheLookup)
        }
        XCTAssertTrue(
            (try FileManager.default.contentsOfDirectory(atPath: victim.path)).isEmpty
        )
    }

    func testCacheMaintenanceSkipsActiveLeaseThenEvictsToLowWatermark() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let original = try sha256AndSize(at: fixture)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-maintenance-\(UUID().uuidString)")
        let cache = root.appendingPathComponent("traces", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await TraceSession.open(
            source: fixture,
            parser: try TraceStreamerProcessParser(executableURL: binary),
            stagingDirectory: staging,
            storagePolicy: .contentAddressed(cacheDirectory: cache)
        )
        let maintenance = try TraceCacheMaintenance(
            cacheDirectory: cache,
            stagingDirectory: staging
        )
        let active = try await maintenance.inventory()
        XCTAssertEqual(active.entryCount, 1)
        XCTAssertEqual(active.activeEntryCount, 1)
        XCTAssertGreaterThan(active.totalByteCount, 0)

        let protected = try await maintenance.purgeUnused()
        XCTAssertEqual(protected.removedEntryCount, 0)
        XCTAssertEqual(protected.skippedActiveEntryCount, 1)
        XCTAssertEqual(protected.after.entryCount, 1)

        try await session.close()
        let report = try await maintenance.maintain(
            watermarks: TraceCacheWatermarks(highBytes: 1, lowBytes: 0)
        )
        XCTAssertEqual(report.removedEntryCount, 1)
        XCTAssertEqual(report.after.entryCount, 0)
        XCTAssertEqual(try sha256AndSize(at: fixture).sha256, original.sha256)
        XCTAssertEqual(try sha256AndSize(at: fixture).byteCount, original.byteCount)
    }

    func testBuildingEvidenceBoundToReadyEntryUsesReadyLeaseTransaction() async throws {
        let (binary, fixture) = try requireCacheEnvironment()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-building-ready-\(UUID().uuidString)")
        let cache = root.appendingPathComponent("traces", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await TraceSession.openCached(
            source: fixture,
            parser: try TraceStreamerProcessParser(executableURL: binary),
            stagingDirectory: staging,
            cacheDirectory: cache
        )
        let entry = await session.parsed.databaseURL.deletingLastPathComponent()
        let ownerRoot = cache.appendingPathComponent(".staging/.owners", isDirectory: true)
        let evidenceURLs = try FileManager.default.contentsOfDirectory(
            at: ownerRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        let evidenceURL = try XCTUnwrap(evidenceURLs.first)
        var evidence = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: evidenceURL))
                as? [String: Any]
        )
        evidence["state"] = "building"
        evidence["relativePath"] = ".staging/entry-crash-window"
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
            .write(to: evidenceURL, options: .atomic)

        let maintenance = try TraceCacheMaintenance(
            cacheDirectory: cache,
            stagingDirectory: staging
        )
        let protected = try await maintenance.purgeUnused()
        XCTAssertEqual(protected.removedEntryCount, 0)
        XCTAssertEqual(protected.skippedActiveEntryCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.path))

        try await session.close()
        let removed = try await maintenance.purgeUnused()
        XCTAssertEqual(removed.removedEntryCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.path))
    }

    func testCacheMaintenanceEvictsLeastRecentlyAccessedReadyEntryFirst() async throws {
        let (binary, oldFixture) = try requireCacheEnvironment()
        let newFixture = Self.repoRoot.appendingPathComponent(
            "Fixtures/traces/hiprofiler_data_ability.htrace"
        )
        guard FileManager.default.isReadableFile(atPath: newFixture.path) else {
            throw XCTSkip("second LRU fixture is unavailable")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-lru-\(UUID().uuidString)")
        let cache = root.appendingPathComponent("traces", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parser = try TraceStreamerProcessParser(executableURL: binary)
        let older = try await TraceSession.openCached(
            source: oldFixture,
            parser: parser,
            stagingDirectory: staging,
            cacheDirectory: cache,
            now: { Date(timeIntervalSince1970: 100) }
        )
        try await older.close()
        let newer = try await TraceSession.openCached(
            source: newFixture,
            parser: parser,
            stagingDirectory: staging,
            cacheDirectory: cache,
            now: { Date(timeIntervalSince1970: 200) }
        )
        try await newer.close()

        let maintenance = try TraceCacheMaintenance(
            cacheDirectory: cache,
            stagingDirectory: staging
        )
        let inventory = try await maintenance.inventory()
        XCTAssertEqual(inventory.entryCount, 2)
        let report = try await maintenance.maintain(
            watermarks: TraceCacheWatermarks(
                highBytes: inventory.totalByteCount - 1,
                lowBytes: inventory.totalByteCount - 2
            )
        )
        XCTAssertEqual(report.removedEntryCount, 1)
        XCTAssertEqual(report.after.entryCount, 1)

        let retained = try await TraceSession.openCached(
            source: newFixture,
            parser: parser,
            stagingDirectory: staging,
            cacheDirectory: cache
        )
        let wasHit = await retained.cacheHit
        XCTAssertTrue(wasHit)
        try await retained.close()
    }

    func testCacheMaintenanceRecoversOnlyBoundStaleOwnersAndOrphanMarkers() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-owner-recovery-\(UUID().uuidString)")
        let cache = root.appendingPathComponent("traces", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var stale: TraceOwnedDirectory? = try await TraceContentAddressedCache
            .createOwnedDirectory(root: staging, prefix: "session-")
        let staleURL = try XCTUnwrap(stale).url
        stale = nil

        let owners = staging.appendingPathComponent(".owners", isDirectory: true)
        try FileManager.default.createDirectory(at: owners, withIntermediateDirectories: true)
        let creatingBase = "session-unbound"
        let creatingMarker = owners.appendingPathComponent("\(creatingBase).lock")
        let creatingEvidence = owners.appendingPathComponent("\(creatingBase).json")
        FileManager.default.createFile(atPath: creatingMarker.path, contents: Data())
        let evidenceObject: [String: Any] = [
            "formatVersion": 1,
            "state": "creating",
            "relativePath": "session-unbound",
        ]
        try JSONSerialization.data(
            withJSONObject: evidenceObject,
            options: [.sortedKeys]
        ).write(to: creatingEvidence)
        let orphanMarker = owners.appendingPathComponent("session-orphan.lock")
        FileManager.default.createFile(atPath: orphanMarker.path, contents: Data())

        let maintenance = try TraceCacheMaintenance(
            cacheDirectory: cache,
            stagingDirectory: staging
        )
        let report = try await maintenance.maintain()
        XCTAssertEqual(report.recoveredPrivateDirectoryCount, 1)
        XCTAssertEqual(report.removedOrphanOwnerMarkerCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanMarker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: creatingMarker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: creatingEvidence.path))
    }

    func testCacheMaintenanceRejectsBroadOrUnresolvedTargets() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertThrowsError(
            try TraceCacheMaintenance(
                cacheDirectory: home.appendingPathComponent("traces"),
                stagingDirectory: home.appendingPathComponent("staging")
            )
        ) { error in
            XCTAssertEqual((error as? ArkTraceError)?.code, .invalidArgument)
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arktrace-maintenance-root-\(UUID().uuidString)")
        XCTAssertThrowsError(
            try TraceCacheMaintenance(
                cacheDirectory: root.appendingPathComponent("child/../traces"),
                stagingDirectory: root.appendingPathComponent("staging")
            )
        )
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self {
            result.append(await transform(element))
        }
        return result
    }
}
