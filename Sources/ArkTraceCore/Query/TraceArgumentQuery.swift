import Foundation

/// Bounded lookup of one slice's argument set.
///
/// Arguments are fetched only for the event the user actually selected, never
/// per primitive while building a snapshot: a viewport holds tens of thousands
/// of slices and one query each would defeat the whole bounded-page design.
package struct TraceArgumentQuery: Hashable, Sendable {
    public let argSetID: Int64
    public let limit: Int
    public let deadline: ContinuousClock.Instant

    /// Real traces top out around ten arguments per set, so the cap is
    /// generous; it exists so a malformed set cannot flood the Inspector
    /// (AT-DB-007).
    public static let maximumLimit = 64

    public init(
        argSetID: Int64,
        limit: Int = TraceArgumentQuery.maximumLimit,
        deadline: ContinuousClock.Instant
    ) throws {
        guard (1...Self.maximumLimit).contains(limit) else {
            throw ArkTraceError(
                code: .invalidArgument,
                stage: .request,
                message: "Argument limit must be within 1...\(Self.maximumLimit)"
            )
        }
        self.argSetID = argSetID
        self.limit = limit
        self.deadline = deadline
    }
}
