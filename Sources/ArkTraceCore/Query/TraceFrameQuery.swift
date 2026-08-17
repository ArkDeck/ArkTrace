import Foundation

/// Bounded query over `frame_slice`.
package struct TraceFrameQuery: Hashable, Sendable {
    public let range: TraceTimeRange
    public let processKey: ProcessKey?
    public let limit: Int
    public let deadline: ContinuousClock.Instant

    public static let maximumLimit = 20_000

    public init(
        range: TraceTimeRange,
        processKey: ProcessKey? = nil,
        limit: Int = 20_000,
        deadline: ContinuousClock.Instant
    ) throws {
        guard (1...Self.maximumLimit).contains(limit) else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Frame limit must be within 1...\(Self.maximumLimit)"
            )
        }
        self.range = range
        self.processKey = processKey
        self.limit = limit
        self.deadline = deadline
    }
}
