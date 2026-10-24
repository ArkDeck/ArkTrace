#if canImport(ArkTraceRustRuntime) && canImport(CArkTrace)
import ArkTraceAnalysis
import ArkTraceCore
import ArkTraceRustRuntime
import ArkTraceRuntime
import CryptoKit
import Foundation
import Darwin
import XCTest

/// Explicit opt-in: real signed production composition, one open, no mocked
/// budget error. Input paths belong to the consumer's reviewed evidence only.
@MainActor
final class NativeRangeAnalysisBudgetRecoveryTests: XCTestCase {
    private struct Input: Decodable, Sendable {
        let source: String
        let helper: String
        let parser: String
        let helperSHA256: String
        let parserIdentity: TraceParserIdentity
        let publisher: RustPublisher
        let namespace: String
        let cacheDirectory: String
        let cacheEntryDirectory: String
        let parserKey: String
        let schemaAdapterVersion: String
        let indexSchemaVersion: Int
        let admissionProposalPath: String
        let admissionProposalSHA256: String
        let backupDirectory: String
        let sourceSHA256: String
        let openTimeoutMilliseconds: UInt32
        let operationTimeoutMilliseconds: UInt32
        let maximumSlices: Int
        let maximumStateIntervals: Int
        let minimumLongSliceDurationNs: Int64
        let ordinaryVMBudget: Int
        let lateRange: TraceTimeRange
        let healthyRange: TraceTimeRange
    }
    private struct Failure: Codable, Sendable {
        let code: String
        let stage: String
        let message: String
        let retryable: Bool
        let details: [String: String]
        init(_ error: any Error) {
            if let value = error as? ArkTraceError {
                code = value.code.rawValue; stage = value.stage.rawValue
                message = value.message; retryable = value.retryable; details = value.details
            } else {
                code = String(describing: type(of: error)); stage = "test-boundary"
                message = String(describing: error); retryable = false; details = [:]
            }
        }
    }
    private struct Facts: Codable, Sendable {
        let engine: UInt64
        let session: UInt64
        let cacheHit: Bool
        let metadata: TraceMetadata
    }
    /// Success oracle uses freshly read real native pages from this same DB,
    /// then the unchanged shared Analyzer. It does not manufacture a failure
    /// or duplicate reduction logic and is not an independent database.
    private actor PageOracle: TraceRepositoryProtocol {
        let facts: TraceMetadata
        let pages: TraceRepositoryEventBatchResult
        init(facts: TraceMetadata, pages: TraceRepositoryEventBatchResult) {
            self.facts = facts; self.pages = pages
        }
        func metadata() async throws -> TraceMetadata { facts }
        func processes(_ query: ProcessQuery) async throws -> BoundedPage<TraceProcess> {
            BoundedPage(items: [], truncated: false)
        }
        func threads(_ query: ThreadQuery) async throws -> BoundedPage<TraceThread> {
            BoundedPage(items: [], truncated: false)
        }
        func cpuCatalog(_ query: TraceCPUCatalogQuery) async throws -> TraceCPUCatalog { .unavailable }
        func summaryFacts(_ query: TraceSummaryQuery) async throws -> TraceSummaryFacts {
            throw ArkTraceError(code: .invalidArgument, stage: .request, message: "Oracle supports only captured event pages")
        }
        func eventBatch(_ batch: TraceRepositoryEventBatch) async throws -> TraceRepositoryEventBatchResult {
            guard batch.cpuSlices.count == 1, batch.threadStates.count == 1, batch.slices.count == 1,
                  batch.counters.isEmpty, batch.counterSeries.isEmpty, batch.densities.isEmpty,
                  batch.threads.isEmpty else {
                throw ArkTraceError(code: .invalidArgument, stage: .request, message: "Oracle batch differs from captured pages")
            }
            return pages
        }
    }
    private struct FilePin: Codable, Sendable {
        let path: String
        let byteCount: Int
        let sha256: String
        let inode: UInt64
        let device: UInt64
        let mtimeNS: Int64
        let mode: UInt16
    }
    private struct DirectoryPin: Codable, Sendable {
        let path: String
        let inode: UInt64
        let device: UInt64
        let mode: UInt16
    }
    /// A pinned, source-backed MAIN handoff is required before open. This
    /// harness does not create, copy, repair or rebind native owner evidence.
    private struct ReadyProposal: Decodable, Sendable {
        let task: String
        let allowNativeOpen: Bool
        let freshParseAllowed: Bool
        let exclusiveHandoff: Bool
        let cacheHitOnlyPremiseVerifiedByMAIN: Bool
        let ownerFormatVersion: Int
        let namespace: String
        let cacheDirectory: String
        let cacheEntryDirectory: String
        let sourceSHA256: String
        let parserKey: String
        let sourceProof: [FilePin]
        let readyFiles: [FilePin]
        let directories: [DirectoryPin]
    }
    private struct Part: Codable, Sendable {
        let name: String
        let byteCount: Int
        let sha256: String
    }
    private struct CanonicalEvidence: Codable, Sendable {
        let byteCount: Int
        let sha256: String
        let parts: [Part]
    }
    private enum PremiseReason: String, Codable, Sendable {
        case invalidInput, pathSyntax, pathBudget, pathOpen, pathType, descriptorClose
        case fileIdentity, fileHash, directoryIdentity, requestPolicy, cacheIdentity
        case proposalHash, proposalPolicy, fixtureOwnership, fixtureCleanup
    }
    private struct FDState: Codable, Sendable {
        var opened = 0
        var closed = 0
        var closeFailures = 0
        var outstanding: Int { opened - closed }
    }
    nonisolated private static func invalidPremise(_ reason: PremiseReason = .invalidInput) -> ArkTraceError {
        ArkTraceError(code: .invalidArgument, stage: .cacheLookup,
            message: "Reviewed exclusive Ready admission premise is invalid",
            details: ["reason": reason.rawValue])
    }
    nonisolated private static func boundedRead(_ url: URL, limit: Int = 131_072) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
        return data
    }
    nonisolated private static func canonicalURL(_ path: String) throws -> URL {
        var state = FDState()
        return try canonicalURL(path, state: &state)
    }
    /// Check the supplied physical spelling without Foundation alias rewriting.
    /// Every acquired descriptor remains ours until the bounded walk finishes;
    /// the common exit closes each exactly once and reports any close failure.
    nonisolated private static func canonicalURL(_ path: String, state: inout FDState) throws -> URL {
        guard path.utf8.count <= 4_096 else { throw invalidPremise(.pathBudget) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count - 1 <= 128 else { throw invalidPremise(.pathBudget) }
        guard path.hasPrefix("/"), path != "/", !path.utf8.contains(0),
              components.first == "",
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw invalidPremise(.pathSyntax) }
        let url = URL(filePath: path)
        guard url.path == path else { throw invalidPremise(.pathSyntax) }
        var descriptors: [Int32] = []
        var outcome: (any Error)?
        do {
            let root = unsafe Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard root >= 0 else { throw invalidPremise(.pathOpen) }
            descriptors.append(root); state.opened += 1
            var parent = root
            for (index, component) in components.dropFirst().enumerated() {
                let last = index == components.count - 2
                let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (last ? O_NONBLOCK : O_DIRECTORY)
                let child = component.withCString { unsafe Darwin.openat(parent, $0, flags) }
                guard child >= 0 else { throw invalidPremise(.pathOpen) }
                descriptors.append(child); state.opened += 1; parent = child
            }
            var info = stat()
            guard unsafe Darwin.fstat(parent, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR
            else { throw invalidPremise(.pathType) }
        } catch { outcome = error }
        for descriptor in descriptors.reversed() {
            if Darwin.close(descriptor) == 0 { state.closed += 1 }
            else { state.closeFailures += 1 }
        }
        // EINTR/failed close is not retried against a possibly reused FD and
        // cannot be reported as closed or outstanding=0.
        if state.closeFailures > 0 { throw invalidPremise(.descriptorClose) }
        if let outcome { throw outcome }
        return url
    }
    nonisolated private static func checkDirectory(_ pin: DirectoryPin) throws {
        let url = try canonicalURL(pin.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == pin.inode,
              (attributes[.systemNumber] as? NSNumber)?.uint64Value == pin.device,
              (attributes[.posixPermissions] as? NSNumber)?.uint16Value == pin.mode else { throw invalidPremise(.directoryIdentity) }
    }
    nonisolated private static func checkFile(_ pin: FilePin) throws {
        let url = try canonicalURL(pin.path)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        guard before[.type] as? FileAttributeType == .typeRegular,
              (before[.size] as? NSNumber)?.intValue == pin.byteCount,
              (before[.systemFileNumber] as? NSNumber)?.uint64Value == pin.inode,
              (before[.systemNumber] as? NSNumber)?.uint64Value == pin.device,
              (before[.posixPermissions] as? NSNumber)?.uint16Value == pin.mode else { throw invalidPremise(.fileIdentity) }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256(), bytes = 0
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            bytes += chunk.count
            guard bytes <= pin.byteCount else { throw invalidPremise(.fileHash) }
            digest.update(data: chunk)
        }
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        guard bytes == pin.byteCount,
              digest.finalize().map({ String(format: "%02x", $0) }).joined() == pin.sha256,
              (after[.systemFileNumber] as? NSNumber)?.uint64Value == pin.inode,
              (after[.systemNumber] as? NSNumber)?.uint64Value == pin.device,
              (after[.size] as? NSNumber)?.intValue == pin.byteCount,
              (after[.modificationDate] as? Date) == (before[.modificationDate] as? Date) else { throw invalidPremise(.fileHash) }
    }
    @concurrent private static func readInput(_ path: String) async throws -> Input {
        try JSONDecoder().decode(Input.self, from: boundedRead(canonicalURL(path)))
    }
    @concurrent private static func validateReadyPremise(_ input: Input) async throws {
        guard input.ordinaryVMBudget == 2_000_000,
              input.maximumSlices == 20_000, input.maximumStateIntervals == 20_000,
              input.minimumLongSliceDurationNs == 0,
              input.openTimeoutMilliseconds > 0, input.openTimeoutMilliseconds <= 300_000,
              input.operationTimeoutMilliseconds > 0, input.operationTimeoutMilliseconds <= 30_000,
              input.lateRange.startNs == 40_554_000_000, input.lateRange.endNs == 40_720_000_000,
              input.healthyRange.startNs == 10_100_000_000, input.healthyRange.endNs == 10_300_000_000
        else { throw invalidPremise(.requestPolicy) }
        let key = try TraceCacheKey(traceSHA256: input.sourceSHA256,
            parserBinarySHA256: input.parserIdentity.binarySHA256,
            upstreamRevision: input.parserIdentity.upstreamRevision,
            schemaAdapterVersion: input.schemaAdapterVersion, indexSchemaVersion: input.indexSchemaVersion)
        let cache = try canonicalURL(input.cacheDirectory)
        let entry = try canonicalURL(input.cacheEntryDirectory)
        guard input.schemaAdapterVersion == "2", input.indexSchemaVersion == 4,
              input.parserKey == key.parserKey,
              entry == cache.appending(path: input.sourceSHA256).appending(path: key.parserKey)
        else { throw invalidPremise(.cacheIdentity) }
        let bytes = try boundedRead(canonicalURL(input.admissionProposalPath))
        guard hashData(bytes) == input.admissionProposalSHA256 else { throw invalidPremise(.proposalHash) }
        let proposal = try JSONDecoder().decode(ReadyProposal.self, from: bytes)
        guard proposal.task == "N35", proposal.allowNativeOpen, !proposal.freshParseAllowed,
              proposal.exclusiveHandoff, proposal.cacheHitOnlyPremiseVerifiedByMAIN,
              proposal.ownerFormatVersion == 4,
              proposal.namespace == input.namespace, proposal.cacheDirectory == input.cacheDirectory,
              proposal.cacheEntryDirectory == input.cacheEntryDirectory,
              proposal.sourceSHA256 == input.sourceSHA256, proposal.parserKey == key.parserKey,
              !proposal.sourceProof.isEmpty, proposal.readyFiles.count >= 3,
              proposal.readyFiles.contains(where: { $0.path == entry.appending(path: "trace.sqlite").path }),
              proposal.readyFiles.contains(where: { $0.path == entry.appending(path: "metadata.json").path }),
              proposal.directories.contains(where: { $0.path == cache.path }),
              proposal.directories.contains(where: { $0.path == entry.path }),
              proposal.directories.contains(where: { $0.path == input.namespace })
        else { throw invalidPremise(.proposalPolicy) }
        for pin in proposal.sourceProof + proposal.readyFiles { try checkFile(pin) }
        for pin in proposal.directories { try checkDirectory(pin) }
    }
    nonisolated private static func hashData(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    nonisolated private static func hash<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return hashData(try encoder.encode(value))
    }
    /// Refuse oversized or already existing output before touching the file.
    @concurrent private static func checkedWrite(_ data: Data, to url: URL, limit: Int = 131_072) async throws {
        guard data.count <= limit else {
            throw ArkTraceError(code: .outputLimitExceeded, stage: .encoding,
                message: "Native recovery evidence exceeded its record budget")
        }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        try data.write(to: url, options: .atomic)
    }
    @concurrent private static func canonicalEvidence(_ value: TraceRangeAnalysis,
        output: URL, label: String) async throws -> CanonicalEvidence {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(value)
        guard bytes.count <= 8_388_608 else {
            throw ArkTraceError(code: .outputLimitExceeded, stage: .encoding,
                message: "Native recovery canonical evidence exceeded its total budget")
        }
        var parts: [Part] = []
        for offset in stride(from: 0, to: bytes.count, by: 65_536) {
            let part = bytes.subdata(in: offset..<min(offset + 65_536, bytes.count))
            let name = output.lastPathComponent + "." + label + String(format: ".canonical.part-%03d", parts.count + 1)
            try await checkedWrite(part, to: output.deletingLastPathComponent().appending(path: name), limit: 65_536)
            parts.append(Part(name: name, byteCount: part.count, sha256: hashData(part)))
        }
        return CanonicalEvidence(byteCount: bytes.count, sha256: hashData(bytes), parts: parts)
    }
    private struct GuardInput: Decodable, Sendable {
        let task: String
        let epoch: String
        let fixtureRoot: String
        let outputPath: String
    }
    private struct GuardCase: Codable, Sendable {
        let name: String
        let expectedAccepted: Bool
        let accepted: Bool
        let expectedReason: PremiseReason?
        let actualFailure: Failure?
        let descriptors: FDState
        let outstandingAfterReturn: Int
        let acceptedPhysicalSpellingPreserved: Bool
    }
    private struct GuardRecord: Codable, Sendable {
        let task: String
        let fixtureEpoch: String
        let physicalFixtureRoot: String
        let originalGuardAcceptedPhysicalFile: Bool
        let originalStandardizedPath: String
        let originalResolvedPath: String
        let regularFixtureSHA256: String
        let cases: [GuardCase]
        let cleanupJoined: Bool
        let cleanupFailureReason: PremiseReason?
        let EngineCreateOpenCalls: Int
        let MAINReadyAccessCalls: Int
        let nativeRangeRecoveryProven: Bool
        let allOwnDescriptorClosesConfirmed: Bool
    }
    @concurrent private static func readGuardInput(_ path: String) async throws -> GuardInput {
        try JSONDecoder().decode(GuardInput.self, from: boundedRead(canonicalURL(path), limit: 65_536))
    }
    @concurrent private static func exercisePhysicalGuard(_ input: GuardInput) async throws -> GuardRecord {
        guard input.task == "N35", input.fixtureRoot.hasPrefix("/private/tmp/arktrace-n35-physical-"),
              !input.epoch.isEmpty else { throw invalidPremise(.fixtureOwnership) }
        let root = try canonicalURL(input.fixtureRoot)
        let marker = try boundedRead(root.appending(path: "epoch.json"), limit: 65_536)
        let epoch = try JSONDecoder().decode([String: String].self, from: marker)
        guard epoch == ["task": "N35", "epoch": input.epoch] else { throw invalidPremise(.fixtureOwnership) }
        let manager = FileManager.default
        let parent = root.appending(path: "physical-parent", directoryHint: .isDirectory)
        let file = parent.appending(path: "physical-file.bin")
        let bytes = Data("physical-path-regression".utf8)
        var rows: [GuardCase] = []
        var originalAccepted = true, standardized = "", resolved = ""
        var setupFailure: (any Error)?
        do {
            try manager.createDirectory(at: parent, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try bytes.write(to: file, options: .atomic)
            let old = URL(filePath: file.path).standardizedFileURL
            standardized = old.path; resolved = old.resolvingSymlinksInPath().path
            originalAccepted = file.path.hasPrefix("/") && old.path == file.path && resolved == file.path
            try manager.createSymbolicLink(atPath: root.appending(path: "file-link").path, withDestinationPath: file.path)
            try manager.createSymbolicLink(atPath: root.appending(path: "parent-link").path, withDestinationPath: parent.path)
            let fifo = parent.appending(path: "fifo")
            guard unsafe Darwin.mkfifo(fifo.path, 0o600) == 0 else { throw invalidPremise(.fixtureOwnership) }
            let attempts: [(String, String, Bool, PremiseReason?)] = [
                ("physical-directory", parent.path, true, nil),
                ("physical-file", file.path, true, nil),
                ("symlink-file", root.appending(path: "file-link").path, false, .pathOpen),
                ("symlink-parent", root.path + "/parent-link/physical-file.bin", false, .pathOpen),
                ("fifo-final-no-block", fifo.path, false, .pathType),
                ("missing-file", parent.path + "/missing", false, .pathOpen),
                ("dot-component", parent.path + "/./physical-file.bin", false, .pathSyntax),
                ("dotdot-component", parent.path + "/../physical-parent/physical-file.bin", false, .pathSyntax),
                ("empty-component", root.path + "//physical-parent", false, .pathSyntax),
                ("trailing-separator", parent.path + "/", false, .pathSyntax),
                ("relative-path", "physical-parent/physical-file.bin", false, .pathSyntax),
                ("root-only", "/", false, .pathSyntax),
                ("nul-component", parent.path + "/" + String(UnicodeScalar(0)!) + "bad", false, .pathSyntax),
                ("path-byte-budget", "/" + String(repeating: "x", count: 4_096), false, .pathBudget),
                ("component-budget", "/" + Array(repeating: "x", count: 129).joined(separator: "/"), false, .pathBudget)
            ]
            for (name, path, expected, reason) in attempts {
                var state = FDState(), accepted = false, failure: Failure?, sameSpelling = false
                do { let value = try canonicalURL(path, state: &state); accepted = true; sameSpelling = value.path == path }
                catch { failure = Failure(error) }
                rows.append(GuardCase(name: name, expectedAccepted: expected, accepted: accepted,
                    expectedReason: reason, actualFailure: failure, descriptors: state,
                    outstandingAfterReturn: state.outstanding, acceptedPhysicalSpellingPreserved: sameSpelling))
            }
        } catch { setupFailure = error }
        var cleanupReason: PremiseReason?
        do { try manager.removeItem(at: root) } catch { cleanupReason = .fixtureCleanup }
        if let setupFailure { throw setupFailure }
        return GuardRecord(task: "N35", fixtureEpoch: input.epoch, physicalFixtureRoot: root.path,
            originalGuardAcceptedPhysicalFile: originalAccepted, originalStandardizedPath: standardized,
            originalResolvedPath: resolved, regularFixtureSHA256: hashData(bytes), cases: rows,
            cleanupJoined: cleanupReason == nil, cleanupFailureReason: cleanupReason,
            EngineCreateOpenCalls: 0, MAINReadyAccessCalls: 0, nativeRangeRecoveryProven: false,
            allOwnDescriptorClosesConfirmed: rows.allSatisfy { $0.outstandingAfterReturn == 0 && $0.descriptors.closeFailures == 0 && $0.descriptors.opened == $0.descriptors.closed })
    }
    func testPhysicalReadyPremisePathsAndNoFollowClosure() async throws {
        guard let path = ProcessInfo.processInfo.environment["ARKTRACE_N35_GUARD_INPUT"] else {
            throw XCTSkip("Requires owned N35 physical-path regression fixture")
        }
        let input = try await Self.readGuardInput(path)
        let record = try await Self.exercisePhysicalGuard(input)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try await Self.checkedWrite(try encoder.encode(record), to: URL(filePath: input.outputPath), limit: 65_536)
        XCTAssertFalse(record.originalGuardAcceptedPhysicalFile)
        XCTAssertEqual(record.cases.count, 15)
        for value in record.cases {
            XCTAssertEqual(value.accepted, value.expectedAccepted, value.name)
            XCTAssertEqual(value.outstandingAfterReturn, 0, value.name)
            XCTAssertEqual(value.descriptors.closeFailures, 0, value.name)
            if value.expectedAccepted { XCTAssertTrue(value.acceptedPhysicalSpellingPreserved, value.name) }
            else {
                XCTAssertEqual(value.actualFailure?.code, ArkTraceError.Code.invalidArgument.rawValue, value.name)
                XCTAssertEqual(value.actualFailure?.stage, ArkTraceError.Stage.cacheLookup.rawValue, value.name)
                XCTAssertEqual(value.actualFailure?.details, ["reason": value.expectedReason!.rawValue], value.name)
            }
        }
        XCTAssertTrue(record.allOwnDescriptorClosesConfirmed)
        XCTAssertTrue(record.cleanupJoined)
        XCTAssertEqual(record.EngineCreateOpenCalls, 0)
        XCTAssertEqual(record.MAINReadyAccessCalls, 0)
    }
    @inline(never)
    private func openRepository(_ engine: RustEngine, input: Input) async throws -> (RustTraceRepository, Facts) {
        // Only the repository escapes; session/opening aliases stay in this
        // frame, so repository.close can release the retained opening owner.
        let session = try await engine.open(URL(filePath: input.source), format: .htrace,
            timeoutMilliseconds: input.openTimeoutMilliseconds)
        let opening = try await session.openingView()
        let repository = try await RustTraceRepository.create(session: session, opening: opening,
            sourceFormat: .htrace, operationTimeoutMilliseconds: input.operationTimeoutMilliseconds)
        let metadata = try await repository.metadata()
        return (repository, Facts(engine: opening.sessionIdentity.engine,
            session: opening.sessionIdentity.session, cacheHit: opening.cacheHit, metadata: metadata))
    }
    func testActualLateRangeBudgetFailureThenHealthySameSession() async throws {
        guard let path = ProcessInfo.processInfo.environment["ARKTRACE_N35_INPUT"] else {
            throw XCTSkip("Requires reviewed signed native range-recovery input")
        }
        let input = try await Self.readInput(path)
        let started = ContinuousClock.now
        var engine: RustEngine?, repository: RustTraceRepository?, facts: Facts?
        var operationFailure: Failure?, lateFailure: Failure?
        var cleanupFailures: [Failure] = []
        var analysis: TraceRangeAnalysis?, oracle: TraceRangeAnalysis?
        var cpuCount: Int?, stateCount: Int?, namedCount: Int?
        var pageHashes: [String: String] = [:]
        var nativeBeforeShutdown: UInt64?, nativeInputBeforeShutdown: UInt64?
        var engineCreated = false, openAttempted = false, opened = false, repositoryClosed = false, shutdownJoined = false
        var lateAttempted = false, healthyAttempted = false, pagesRead = false
        var events: [String] = [], thrown: (any Error)?
        do {
            try await Self.validateReadyPremise(input)
            events.append("pinned-main-exclusive-ready-premise-verified")
            let configuration = RustConfiguration(namespace: URL(filePath: input.namespace),
                helper: URL(filePath: input.helper), parser: URL(filePath: input.parser),
                helperSHA256: input.helperSHA256, parserIdentity: input.parserIdentity,
                publisher: input.publisher, storagePolicy: .contentAddressed(cacheDirectory: URL(filePath: input.cacheDirectory)),
                viewStateBackup: RustViewStateBackupConfiguration(backupDirectory: URL(filePath: input.backupDirectory)))
            engine = try await RustEngine.create(configuration)
            engineCreated = true; events.append("production-engine-created")
            guard let engine else { throw CocoaError(.coderValueNotFound) }
            openAttempted = true; events.append("single-open-submitted")
            let value = try await openRepository(engine, input: input)
            repository = value.0; facts = value.1; opened = true
            events.append("owned-ready-open-returned")
            guard value.1.cacheHit, value.1.metadata.traceSHA256 == input.sourceSHA256 else {
                throw ArkTraceError(code: .traceCacheCorrupt, stage: .cacheLookup,
                    message: "Native open did not return the reviewed cache-hit Ready")
            }
            events.append("actual-cache-hit-required-before-any-analysis")
            let request = try TraceRangeAnalysisRequest(range: input.lateRange,
                maximumSlices: input.maximumSlices, maximumStateIntervals: input.maximumStateIntervals,
                minimumLongSliceDurationNs: input.minimumLongSliceDurationNs, timeout: .seconds(30))
            lateAttempted = true; events.append("late-native-analyzer-submitted")
            do {
                _ = try await TraceRangeAnalysisEngine(repository: value.0).analyze(request)
                throw ArkTraceError(code: .internalError, stage: .analyzing,
                    message: "Actual late range did not reject under ordinary budget")
            } catch {
                lateFailure = Failure(error); events.append("late-native-failure-returned")
                guard (error as? ArkTraceError)?.code == .queryLimitExceeded else { throw error }
            }
            let healthy = try TraceRangeAnalysisRequest(range: input.healthyRange,
                maximumSlices: input.maximumSlices, maximumStateIntervals: input.maximumStateIntervals,
                minimumLongSliceDurationNs: input.minimumLongSliceDurationNs, timeout: .seconds(30))
            healthyAttempted = true; events.append("same-repository-healthy-analyzer-submitted")
            let healthyValue = try await TraceRangeAnalysisEngine(repository: value.0).analyze(healthy)
            analysis = healthyValue; events.append("same-repository-healthy-analysis-returned")
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            let pages = try await value.0.eventBatch(TraceRepositoryEventBatch(
                cpuSlices: [CpuSliceQuery(range: input.healthyRange, limit: input.maximumSlices, deadline: deadline)],
                threadStates: [ThreadStateQuery(range: input.healthyRange, limit: input.maximumStateIntervals, deadline: deadline)],
                slices: [TraceSliceQuery(range: input.healthyRange, minimumDurationNs: 0, limit: input.maximumSlices, deadline: deadline)]))
            pagesRead = true; events.append("fresh-same-db-three-pages-returned")
            let cpu = pages.cpuSlices[0], states = pages.threadStates[0], named = pages.slices[0]
            cpuCount = cpu.items.count; stateCount = states.items.count; namedCount = named.items.count
            XCTAssertFalse(cpu.items.isEmpty); XCTAssertFalse(states.items.isEmpty); XCTAssertFalse(named.items.isEmpty)
            XCTAssertFalse(cpu.truncated); XCTAssertFalse(states.truncated); XCTAssertFalse(named.truncated)
            XCTAssertEqual(healthyValue.range, input.healthyRange)
            XCTAssertFalse(healthyValue.cpuUtilizationTruncated)
            XCTAssertFalse(healthyValue.threadStateDistributionTruncated)
            XCTAssertFalse(healthyValue.sliceNameAggregatesTruncated)
            XCTAssertEqual(healthyValue.cpuUtilization.reduce(0) { $0 + $1.sliceCount }, cpu.items.count)
            XCTAssertTrue(Set(healthyValue.topThreads.map(\.threadKey)).isSubset(of: Set(cpu.items.compactMap(\.threadKey))))
            XCTAssertTrue(Set(healthyValue.longSlices.map(\.key)).isSubset(of: Set(named.items.map(\.key))))
            pageHashes = ["cpu": try Self.hash(cpu.items), "threadStates": try Self.hash(states.items), "namedSlices": try Self.hash(named.items)]
            let expected = try await TraceRangeAnalysisEngine(repository: PageOracle(facts: value.1.metadata, pages: pages)).analyze(healthy)
            oracle = expected; XCTAssertEqual(healthyValue, expected)
            guard healthyValue == expected else {
                throw ArkTraceError(code: .internalError, stage: .analyzing,
                    message: "Native analysis differs from the current shared Analyzer page oracle")
            }
            events.append("unmodified-shared-analyzer-page-oracle-matched")
        } catch { thrown = error; operationFailure = Failure(error); events.append("operation-failed") }
        // Cleanup executes after either real admission failure or successful
        // recovery. No second Engine.open, maintenance, fixture or parse retry.
        if let current = repository {
            do { try await current.close(); repositoryClosed = true; events.append("repository-close-returned") }
            catch { cleanupFailures.append(Failure(error)); if thrown == nil { thrown = error } }
            repository = nil
        }
        do { try await RustCleanup.flush(); events.append("pre-shutdown-cleanup-flushed") }
        catch { cleanupFailures.append(Failure(error)); if thrown == nil { thrown = error } }
        if let current = engine {
            do {
                nativeBeforeShutdown = try await current.retainedResultBytes()
                nativeInputBeforeShutdown = try await current.retainedViewStateInputBytes()
                XCTAssertEqual(nativeBeforeShutdown, 0); XCTAssertEqual(nativeInputBeforeShutdown, 0)
            } catch { cleanupFailures.append(Failure(error)); if thrown == nil { thrown = error } }
            do { try await current.shutdown(); shutdownJoined = true; events.append("engine-shutdown-drain-returned") }
            catch { cleanupFailures.append(Failure(error)); if thrown == nil { thrown = error } }
            engine = nil
        }
        do { try await RustCleanup.flush(); events.append("final-cleanup-flushed") }
        catch { cleanupFailures.append(Failure(error)); if thrown == nil { thrown = error } }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func object<T: Encodable>(_ value: T?) throws -> Any {
            guard let value else { return NSNull() }
            return try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
        }
        let elapsed = started.duration(to: .now)
        var record: [String: Any] = ["schemaVersion": 2, "engineCreated": engineCreated,
            "actualEngineOpenCalls": openAttempted ? 1 : 0, "opened": opened,
            "facts": try object(facts), "lateRequestAttempted": lateAttempted,
            "lateFailure": try object(lateFailure), "healthyRequestAttempted": healthyAttempted,
            "canonicalEquality": analysis != nil && analysis == oracle,
            "healthyAnalysis": NSNull(), "sameDBPageOracle": NSNull(),
            "canonicalPayloadsStoredAsBoundedParts": true,
            "freshThreePagesRead": pagesRead, "pageCounts": ["cpu": cpuCount as Any? ?? NSNull(), "threadStates": stateCount as Any? ?? NSNull(), "namedSlices": namedCount as Any? ?? NSNull()],
            "pageHashes": pageHashes, "operationFailure": try object(operationFailure),
            "cleanupFailures": try object(cleanupFailures), "repositoryClosed": repositoryClosed,
            "engineShutdownJoined": shutdownJoined, "nativeRetainedBytesBeforeShutdown": nativeBeforeShutdown as Any? ?? NSNull(),
            "nativeInputBytesBeforeShutdown": nativeInputBeforeShutdown as Any? ?? NSNull(),
            "nativeRetainedBytesAfterEngineRelease": NSNull(), "nativeResultOwnerCount": NSNull(),
            "SDKSessionRequestColdStagingCounts": NSNull(), "SDKDiagnosticUnavailableOnNormalConfiguration": true,
            "events": events, "elapsedSeconds": Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            "generationOrGUIProof": false, "independentDatabase": false, "sameNativeRepositoryForFailureAndRecovery": opened && lateAttempted && healthyAttempted,
            "ordinaryVMBudget": input.ordinaryVMBudget, "maxSlices": input.maximumSlices,
            "maxStateIntervals": input.maximumStateIntervals, "minLongSliceDurationNs": input.minimumLongSliceDurationNs,
            "lateRange": try object(input.lateRange), "healthyRange": try object(input.healthyRange),
            "noMockedError": true, "productionSignedComposition": true, "freshParseRetries": 0]
        if let output = ProcessInfo.processInfo.environment["ARKTRACE_N35_OUTPUT"] {
            let url = URL(filePath: output)
            // Two independent sorted encodings preserve bytes and hashes without
            // repeating whole objects inside the bounded result or matrix.
            if let analysis { record["healthyCanonical"] = try object(try await Self.canonicalEvidence(analysis, output: url, label: "healthy")) }
            if let oracle { record["oracleCanonical"] = try object(try await Self.canonicalEvidence(oracle, output: url, label: "oracle")) }
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try await Self.checkedWrite(data, to: url)
        }
        if let thrown { throw thrown }
    }
}
#endif
