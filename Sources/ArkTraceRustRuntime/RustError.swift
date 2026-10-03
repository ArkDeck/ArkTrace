import ArkTraceCore
import CArkTrace
import Foundation

/// Admission outcomes remain separate from terminal product errors.
public enum RustAdmission: UInt32, Error, Sendable {
    case busy = 1, capacity = 2, invalidInput = 3, invalidBuffer = 4
    case invalidHandle = 5, abiMismatch = 6, unsupportedHost = 7, closed = 8
    case cancelled = 9, internalFailure = 10, unsupportedOperation = 11
    case outputLimit = 12, poisoned = 13
}

struct RustEnvelope<Body: Decodable & Sendable>: Decodable, Sendable {
    let formatVersion: UInt32
    let session: UInt64
    let request: UInt64
    let body: Body
}
struct RustPublicFailure: Decodable, Sendable {
    let code: ArkTraceError.Code
    let stage: ArkTraceError.Stage
    let message: String
    let retryable: Bool
    let details: [String: String]
    func value() throws -> ArkTraceError {
        let value = ArkTraceError(code: code, stage: stage, message: message, retryable: retryable, details: details)
        guard value.publicContractViolation == nil else { throw RustAdmission.internalFailure }
        return value
    }
}

func checkAdmission(_ status: UInt32) throws {
    guard status == ARKTRACE_STATUS_OK else { throw RustAdmission(rawValue: status) ?? .internalFailure }
}
