import ArkTraceCore

/// One bounded, immutable closed failure; never a diagnostic event backlog.
final class RustCleanupFailure: Sendable {
    private let admission: RustAdmission
    private let product: ArkTraceError?
    init(_ error: any Error) {
        admission = (error as? RustAdmission) ?? .internalFailure
        if let error = error as? ArkTraceError, error.publicContractViolation == nil { product = error }
        else { product = nil }
    }
    func raise() throws {
        if let product { throw product }
        throw admission
    }
}
