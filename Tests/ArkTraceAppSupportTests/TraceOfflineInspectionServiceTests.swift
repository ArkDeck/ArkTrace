@testable import ArkTraceAppSupport
import ArkTraceCore
import Foundation
import OSLog
import Synchronization
import XCTest

final class TraceOfflineInspectionServiceTests: XCTestCase {
    func testSharedRustMigrationQualityVectorsAgainstSwiftOracle() throws {
        struct Corpus: Decodable {
            struct Vector: Decodable {
                let id: String
                let issue: TraceDataQualityIssue
                let valid: Bool
            }
            let version: Int
            let vectors: [Vector]
        }
        let root = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let corpus = try JSONDecoder().decode(
            Corpus.self, from: Data(contentsOf: root.appending(path: "contracts/quality-vectors.json"))
        )
        XCTAssertEqual(corpus.version, 1)
        XCTAssertFalse(corpus.vectors.isEmpty)
        for vector in corpus.vectors {
            if vector.valid {
                let issue = try TraceOfflineInspectionQualityIssue(vector.issue)
                XCTAssertEqual(issue.category, vector.issue.category, vector.id)
                XCTAssertEqual(issue.scope, vector.issue.scope, vector.id)
                XCTAssertEqual(issue.count, vector.issue.count, vector.id)
                XCTAssertFalse(String(reflecting: issue).contains("/Users/"), vector.id)
            } else {
                XCTAssertThrowsError(try TraceOfflineInspectionQualityIssue(vector.issue), vector.id)
            }
        }
    }

    func testFailedInspectionPreservesPrimaryErrorWhenCleanupAlsoFails() async throws {
        for cleanupFails in [false, true] {
            let closeCount = Mutex(0)
            let primary = ArkTraceError(
                code: .traceDatabaseInvalid, stage: .validating,
                message: "Offline Trace inspection provenance is invalid",
                details: ["reason": "sourceBindingMismatch"]
            )
            do {
                let _: Int = try await TraceOfflineInspectionService.withClosedSession(
                    logger: Logger(subsystem: "ArkTraceTests", category: "OfflineInspection"),
                    operation: { throw primary },
                    close: {
                        closeCount.withLock { $0 += 1 }
                        if cleanupFails {
                            throw NSError(domain: "/Users/private/staging", code: 1)
                        }
                    }
                )
                XCTFail("failed inspection must not return a report")
            } catch let error as ArkTraceError {
                XCTAssertEqual(error.code, primary.code)
                XCTAssertEqual(error.stage, primary.stage)
                XCTAssertEqual(error.message, primary.message)
                XCTAssertEqual(error.retryable, primary.retryable)
                XCTAssertEqual(error.details["reason"], "sourceBindingMismatch")
                XCTAssertEqual(error.details["sessionCleanupFailed"], cleanupFails ? "true" : nil)
                XCTAssertFalse(error.details.values.contains { $0.contains("/Users/") })
            }
            XCTAssertEqual(closeCount.withLock { $0 }, 1)
        }
    }

    func testSuccessfulInspectionRequiresOneSuccessfulCleanup() async throws {
        for cleanupFails in [false, true] {
            let closeCount = Mutex(0)
            do {
                let value = try await TraceOfflineInspectionService.withClosedSession(
                    logger: Logger(subsystem: "ArkTraceTests", category: "OfflineInspection"),
                    operation: { 42 },
                    close: {
                        closeCount.withLock { $0 += 1 }
                        if cleanupFails {
                            throw ArkTraceError(
                                code: .traceParseFailed, stage: .openingDatabase,
                                message: "Trace session storage could not be released",
                                retryable: true, details: ["reason": "sessionCleanupFailed"]
                            )
                        }
                    }
                )
                XCTAssertFalse(cleanupFails)
                XCTAssertEqual(value, 42)
            } catch let error as ArkTraceError {
                XCTAssertTrue(cleanupFails)
                XCTAssertEqual(error.code, .traceParseFailed)
                XCTAssertEqual(error.details, ["reason": "sessionCleanupFailed"])
            }
            XCTAssertEqual(closeCount.withLock { $0 }, 1)
        }
    }

    func testCancellationIdentitySurvivesFailedCleanup() async throws {
        let closeCount = Mutex(0)
        do {
            let _: Int = try await TraceOfflineInspectionService.withClosedSession(
                logger: Logger(subsystem: "ArkTraceTests", category: "OfflineInspection"),
                operation: { throw CancellationError() },
                close: {
                    closeCount.withLock { $0 += 1 }
                    throw CocoaError(.fileWriteUnknown)
                }
            )
            XCTFail("cancelled inspection must fail")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(closeCount.withLock { $0 }, 1)
    }

    func testReportBindsExactSourceAndPublishesPathFreeProvenance() throws {
        let sourceSHA = String(repeating: "1", count: 64)
        let databaseSHA = String(repeating: "2", count: 64)
        let schemaSHA = String(repeating: "3", count: 64)
        let parser = parserIdentity()
        let preparation = TraceDatabasePreparationResult(
            schemaAdapterVersion: "2",
            schemaFingerprint: schemaSHA,
            indexVersion: 3,
            upstreamDatabaseSHA256: databaseSHA,
            upstreamDatabaseByteCount: 4_096
        )
        let parsed = ParsedTrace(
            databaseURL: URL(filePath: "/private/database.sqlite"),
            metadataSidecarURL: URL(filePath: "/private/database.metadata.json"),
            parser: parser,
            sourceSHA256: sourceSHA,
            sourceByteCount: 2_048,
            databasePreparation: preparation
        )
        let metadata = TraceMetadata(
            traceSHA256: sourceSHA,
            sourceByteCount: 2_048,
            durationNs: 1_000,
            sourceFormat: "htrace",
            parser: parser,
            schemaFingerprint: schemaSHA,
            capabilities: TraceCapabilities(
                cpuScheduling: true,
                threadStates: true,
                namedSlices: false,
                cpuCounters: false,
                processCounters: false
            ),
            dataQuality: TraceDataQuality(issues: [
                TraceDataQualityIssue(
                    category: .probeTruncated,
                    scope: "thread.start_ts"
                )
            ])
        )

        let report = try TraceOfflineInspectionReport(
            parsed: parsed,
            metadata: metadata,
            expectedSourceSHA256: sourceSHA,
            expectedSourceByteCount: 2_048
        )

        XCTAssertEqual(report.sourceSHA256, sourceSHA)
        XCTAssertEqual(report.sourceByteCount, 2_048)
        XCTAssertEqual(report.durationNs, 1_000)
        XCTAssertEqual(report.provenance.parser, parser)
        XCTAssertEqual(report.provenance.schemaAdapterVersion, "2")
        XCTAssertEqual(report.provenance.indexSchemaVersion, 3)
        XCTAssertEqual(report.provenance.upstreamDatabaseSHA256, databaseSHA)
        XCTAssertEqual(report.dataQualityStatus, .warnings)
        XCTAssertEqual(report.dataQualityIssues.count, 1)
        XCTAssertEqual(report.dataQualityIssues.first?.scope, "thread.start_ts")

        let mirror = String(reflecting: report)
        XCTAssertFalse(mirror.contains("/private/"))
    }

    func testReportRejectsSourceOrParserProvenanceDrift() throws {
        let sourceSHA = String(repeating: "1", count: 64)
        let preparation = TraceDatabasePreparationResult(
            schemaAdapterVersion: "2",
            schemaFingerprint: String(repeating: "3", count: 64),
            indexVersion: 3,
            upstreamDatabaseSHA256: String(repeating: "2", count: 64),
            upstreamDatabaseByteCount: 4_096
        )
        let parsed = ParsedTrace(
            databaseURL: URL(filePath: "/private/database.sqlite"),
            metadataSidecarURL: URL(filePath: "/private/database.metadata.json"),
            parser: parserIdentity(),
            sourceSHA256: sourceSHA,
            sourceByteCount: 2_048,
            databasePreparation: preparation
        )
        let metadata = TraceMetadata(
            traceSHA256: sourceSHA,
            sourceByteCount: 2_048,
            durationNs: 1_000,
            sourceFormat: "htrace",
            parser: parserIdentity(binarySHA: String(repeating: "9", count: 64)),
            schemaFingerprint: preparation.schemaFingerprint,
            capabilities: TraceCapabilities(
                cpuScheduling: false,
                threadStates: false,
                namedSlices: false,
                cpuCounters: false,
                processCounters: false
            ),
            dataQuality: TraceDataQuality()
        )

        XCTAssertThrowsError(try TraceOfflineInspectionReport(
            parsed: parsed,
            metadata: metadata,
            expectedSourceSHA256: sourceSHA,
            expectedSourceByteCount: 2_048
        )) {
            XCTAssertEqual(($0 as? ArkTraceError)?.code, .traceDatabaseInvalid)
            XCTAssertEqual(($0 as? ArkTraceError)?.details["reason"], "sourceBindingMismatch")
        }
        XCTAssertThrowsError(try TraceOfflineInspectionReport(
            parsed: parsed,
            metadata: TraceMetadata(
                traceSHA256: sourceSHA,
                sourceByteCount: 2_048,
                durationNs: 1_000,
                sourceFormat: "htrace",
                parser: parserIdentity(),
                schemaFingerprint: preparation.schemaFingerprint,
                capabilities: metadata.capabilities,
                dataQuality: TraceDataQuality()
            ),
            expectedSourceSHA256: String(repeating: "4", count: 64),
            expectedSourceByteCount: 2_048
        )) {
            XCTAssertEqual(($0 as? ArkTraceError)?.code, .traceDatabaseInvalid)
        }
    }

    func testReportDropsDiagnosticMessagesAndPreservesStructuredWarnings() throws {
        let issue = TraceDataQualityIssue(
            category: .probeTruncated, scope: "thread.start_ts", count: 7,
            message: "/Users/private/source.htrace: bounded probe reached its limit"
        )
        let fixture = matchingFixture(quality: TraceDataQuality(issues: [issue]))
        let report = try TraceOfflineInspectionReport(
            parsed: fixture.parsed, metadata: fixture.metadata,
            expectedSourceSHA256: fixture.parsed.sourceSHA256,
            expectedSourceByteCount: fixture.parsed.sourceByteCount
        )

        XCTAssertEqual(report.dataQualityStatus, .warnings)
        XCTAssertEqual(report.dataQualityIssues.count, 1)
        XCTAssertEqual(report.dataQualityIssues.first?.category, issue.category)
        XCTAssertEqual(report.dataQualityIssues.first?.scope, issue.scope)
        XCTAssertEqual(report.dataQualityIssues.first?.count, issue.count)
        XCTAssertFalse(String(reflecting: report).contains("/Users/private/"))
        XCTAssertFalse(String(reflecting: report).contains("bounded probe"))
    }

    func testReportRejectsInvalidStructuredQualityFactsEvenWithMessages() throws {
        let invalidIssues = [
            TraceDataQualityIssue(
                category: .unclassified,
                message: "/private/source.htrace failed"
            ),
            TraceDataQualityIssue(
                category: .probeTruncated, scope: "/private/source.htrace",
                message: "diagnostic"
            ),
            TraceDataQualityIssue(
                category: .probeTruncated, scope: "thread.start_ts", count: -1,
                message: "diagnostic"
            ),
        ]
        for issue in invalidIssues {
            let fixture = matchingFixture(quality: TraceDataQuality(issues: [issue]))

            XCTAssertThrowsError(try TraceOfflineInspectionReport(
                parsed: fixture.parsed,
                metadata: fixture.metadata,
                expectedSourceSHA256: fixture.parsed.sourceSHA256,
                expectedSourceByteCount: fixture.parsed.sourceByteCount
            )) {
                XCTAssertEqual(($0 as? ArkTraceError)?.code, .traceDatabaseInvalid)
                XCTAssertEqual(
                    ($0 as? ArkTraceError)?.details["reason"],
                    "dataQualityNotMachineSafe"
                )
            }
        }
    }

    private func matchingFixture(
        quality: TraceDataQuality
    ) -> (parsed: ParsedTrace, metadata: TraceMetadata) {
        let parser = parserIdentity()
        let sourceSHA = String(repeating: "1", count: 64)
        let schemaSHA = String(repeating: "3", count: 64)
        let preparation = TraceDatabasePreparationResult(
            schemaAdapterVersion: "2",
            schemaFingerprint: schemaSHA,
            indexVersion: 3,
            upstreamDatabaseSHA256: String(repeating: "2", count: 64),
            upstreamDatabaseByteCount: 4_096
        )
        return (
            ParsedTrace(
                databaseURL: URL(filePath: "/private/database.sqlite"),
                metadataSidecarURL: URL(filePath: "/private/database.metadata.json"),
                parser: parser,
                sourceSHA256: sourceSHA,
                sourceByteCount: 2_048,
                databasePreparation: preparation
            ),
            TraceMetadata(
                traceSHA256: sourceSHA,
                sourceByteCount: 2_048,
                durationNs: 1_000,
                sourceFormat: "htrace",
                parser: parser,
                schemaFingerprint: schemaSHA,
                capabilities: TraceCapabilities(
                    cpuScheduling: false,
                    threadStates: false,
                    namedSlices: false,
                    cpuCounters: false,
                    processCounters: false
                ),
                dataQuality: quality
            )
        )
    }

    private func parserIdentity(
        binarySHA: String = String(repeating: "4", count: 64)
    ) -> TraceParserIdentity {
        TraceParserIdentity(
            name: "trace_streamer",
            reportedVersion: "4.3.7",
            binarySHA256: binarySHA,
            upstreamRepository: "https://example.invalid/trace_streamer",
            upstreamRevision: String(repeating: "5", count: 40),
            architecture: "arm64",
            adapterVersion: "1",
            buildRecipeVersion: "1"
        )
    }
}
