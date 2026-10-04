import ArkTraceCore
import CArkTrace

public typealias RustOpenProgressHandler = @Sendable (TraceLoadingProgress) -> Void

enum RustOpeningProgress {
    static func decode(_ raw: UInt32) throws -> TraceLoadingProgress? {
        switch raw {
        case 0: nil
        case ARKTRACE_PROGRESS_SOURCE_SNAPSHOT: .hashing
        case ARKTRACE_PROGRESS_PARSER_IDENTITY: .preparing
        case ARKTRACE_PROGRESS_PARSING: .parsing
        case ARKTRACE_PROGRESS_INDEXING: .indexing
        case ARKTRACE_PROGRESS_VALIDATING: .validating
        case ARKTRACE_PROGRESS_PUBLISHING: .preparing
        // Native cache lookup and opening share this coarse ABI code. Avoid
        // claiming that a database connection has already started opening.
        case ARKTRACE_PROGRESS_OPENING_DATABASE: .preparing
        case ARKTRACE_PROGRESS_READY: .ready
        default: throw RustAdmission.invalidBuffer
        }
    }
}
