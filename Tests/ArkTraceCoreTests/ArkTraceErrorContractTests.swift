import XCTest

import ArkTraceCore

final class ArkTraceErrorContractTests: XCTestCase {
    func testEveryStableCodeHasAnAcceptingPublicPolicy() {
        let representatives: [(ArkTraceError.Code, ArkTraceError.Stage, Bool)] = [
            (.invalidArgument, .request, false),
            (.traceFileNotFound, .preparing, false),
            (.traceFileUnreadable, .hashing, false),
            (.traceFormatUnsupported, .parsing, false),
            (.traceStreamerUnavailable, .preparing, true),
            (.traceStreamerIdentityMismatch, .preparing, false),
            (.traceParseFailed, .parsing, false),
            (.traceSchemaUnsupported, .validating, false),
            (.traceDatabaseInvalid, .openingDatabase, false),
            (.traceCacheCorrupt, .cacheLookup, true),
            (.queryFailed, .querying, false),
            (.queryTimeout, .analyzing, true),
            (.queryLimitExceeded, .querying, true),
            (.outputLimitExceeded, .encoding, true),
            (.analysisUnsupported, .analyzing, false),
            (.cancelled, .preparing, true),
            (.internalError, .encoding, false),
        ]

        XCTAssertEqual(representatives.count, ArkTraceError.Code.allCases.count)
        for (code, stage, retryable) in representatives {
            let error = ArkTraceError(
                code: code,
                stage: stage,
                message: "representative",
                retryable: retryable
            )
            XCTAssertNil(error.publicContractViolation, "\(code.rawValue) policy rejected its representative")
            XCTAssertEqual(error.normalizedForPublicContract().code, code)
        }
    }

    func testFixedRetryabilityMismatchIsRejectedAndNormalized() {
        let error = ArkTraceError(
            code: .traceSchemaUnsupported,
            stage: .validating,
            message: "unsupported schema",
            retryable: true
        )

        XCTAssertEqual(error.publicContractViolation, .retryability)
        let normalized = error.normalizedForPublicContract()
        XCTAssertEqual(normalized.code, .internalError)
        XCTAssertEqual(normalized.stage, .encoding)
        XCTAssertFalse(normalized.retryable)
        XCTAssertEqual(normalized.details, ["reason": "invalidRetryability"])
        XCTAssertNil(normalized.publicContractViolation)
    }

    func testEveryFixedRetryabilityRuleRejectsItsOpposite() {
        for code in ArkTraceError.Code.allCases {
            let policy = ArkTraceError.publicContractPolicy(for: code)
            guard case .fixed(let required) = policy.retryability else { continue }
            guard let stage = policy.allowedStages.first else {
                return XCTFail("\(code.rawValue) has no allowed stage")
            }
            let invalid = ArkTraceError(
                code: code,
                stage: stage,
                message: "invalid retryability",
                retryable: !required
            )
            XCTAssertEqual(
                invalid.publicContractViolation,
                .retryability,
                "\(code.rawValue) accepted the opposite retryability"
            )
        }
    }

    func testStageMismatchIsRejectedAndNormalizedWithoutEchoingInput() {
        let error = ArkTraceError(
            code: .queryFailed,
            stage: .request,
            message: "should not be public",
            details: ["unsafe": "not echoed"]
        )

        XCTAssertEqual(error.publicContractViolation, .stage)
        let normalized = error.normalizedForPublicContract()
        XCTAssertEqual(normalized.code, .internalError)
        XCTAssertEqual(normalized.stage, .encoding)
        XCTAssertEqual(normalized.message, "Error violates the stable public contract")
        XCTAssertEqual(normalized.details, ["reason": "invalidStage"])
        XCTAssertNil(normalized.publicContractViolation)
    }

    func testEveryBoundedStageRuleRejectsAnOutOfContractStage() {
        for code in ArkTraceError.Code.allCases {
            let policy = ArkTraceError.publicContractPolicy(for: code)
            guard let invalidStage = ArkTraceError.Stage.allCases.first(where: {
                !policy.allowedStages.contains($0)
            }) else {
                continue
            }
            let retryable: Bool
            switch policy.retryability {
            case .fixed(let required): retryable = required
            case .conditional: retryable = false
            }
            let invalid = ArkTraceError(
                code: code,
                stage: invalidStage,
                message: "invalid stage",
                retryable: retryable
            )
            XCTAssertEqual(
                invalid.publicContractViolation,
                .stage,
                "\(code.rawValue) accepted \(invalidStage.rawValue)"
            )
        }
    }

    func testTraceParseFailedRetainsConditionalRetryability() {
        let terminal = ArkTraceError(
            code: .traceParseFailed,
            stage: .parsing,
            message: "parser rejected input",
            retryable: false
        )
        let policy = ArkTraceError.publicContractPolicy(for: .traceParseFailed)
        XCTAssertEqual(
            policy.retryability,
            .conditional(
                retryableReasons: ArkTraceError.traceParseFailedRetryableReasons
            )
        )
        XCTAssertNil(terminal.publicContractViolation)
        let normalizedTerminal = terminal.normalizedForPublicContract()
        XCTAssertEqual(normalizedTerminal.code, terminal.code)
        XCTAssertEqual(normalizedTerminal.stage, terminal.stage)
        XCTAssertEqual(normalizedTerminal.retryable, terminal.retryable)
        XCTAssertEqual(normalizedTerminal.details, terminal.details)

        for reason in ArkTraceError.traceParseFailedRetryableReasons {
            let transient = ArkTraceError(
                code: .traceParseFailed,
                stage: .indexing,
                message: "transient parser storage failure",
                retryable: true,
                details: ["reason": reason]
            )
            XCTAssertNil(transient.publicContractViolation, reason)
            XCTAssertTrue(policy.accepts(
                stage: transient.stage,
                retryable: transient.retryable,
                details: transient.details
            ))
            let normalized = transient.normalizedForPublicContract()
            XCTAssertEqual(normalized.code, transient.code)
            XCTAssertEqual(normalized.details, transient.details)
        }

        let rejectedReasons: [String?] = [
            nil,
            "",
            "unknownTransientFailure",
            "/Users/example/private.sqlite",
            String(repeating: "a", count: 4_096),
        ]
        for reason in rejectedReasons {
            var details: [String: String] = [:]
            if let reason { details["reason"] = reason }
            let invalid = ArkTraceError(
                code: .traceParseFailed,
                stage: .parsing,
                message: "retry suggested with unreviewed evidence",
                retryable: true,
                details: details
            )
            XCTAssertEqual(invalid.publicContractViolation, .retryability)
            XCTAssertFalse(policy.accepts(
                stage: invalid.stage,
                retryable: invalid.retryable,
                details: invalid.details
            ))
            let normalized = invalid.normalizedForPublicContract()
            XCTAssertEqual(normalized.code, .internalError)
            XCTAssertEqual(normalized.stage, .encoding)
            XCTAssertEqual(normalized.details, ["reason": "invalidRetryability"])
            XCTAssertFalse(normalized.details.values.contains(where: { value in
                details.values.contains(value)
            }))
        }
    }

    func testCancellationAndInternalErrorsAllowEveryLifecycleStageWithFixedRetryability() {
        for stage in ArkTraceError.Stage.allCases {
            XCTAssertNil(ArkTraceError(
                code: .cancelled,
                stage: stage,
                message: "cancelled",
                retryable: true
            ).publicContractViolation)
            XCTAssertNil(ArkTraceError(
                code: .internalError,
                stage: stage,
                message: "internal"
            ).publicContractViolation)
        }

        XCTAssertEqual(ArkTraceError(
            code: .cancelled,
            stage: .querying,
            message: "cancelled",
            retryable: false
        ).publicContractViolation, .retryability)
        XCTAssertEqual(ArkTraceError(
            code: .internalError,
            stage: .querying,
            message: "internal",
            retryable: true
        ).publicContractViolation, .retryability)
    }
}
