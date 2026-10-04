import Synchronization

/// Credits for the SDK's immutable packed arrays and UTF-8 pools. Decoder
/// scratch, native leases and explicit copies made by callers have separate
/// budgets. These counters are storage credits, not an allocator/RSS reading.
final class RustRetainedStorage: Sendable {
    private let bytes = Atomic<Int>(0)
    private let owners = Atomic<Int>(0)
    let maximumBytes: Int
    let maximumOwners: Int

    static let shared = RustRetainedStorage(maximumBytes: 128 * 1024 * 1024, maximumOwners: 256)

    init(maximumBytes: Int, maximumOwners: Int) {
        precondition(maximumBytes > 0 && maximumOwners > 0)
        self.maximumBytes = maximumBytes
        self.maximumOwners = maximumOwners
    }

    var retainedBytes: Int { bytes.load(ordering: .acquiring) }
    var retainedOwners: Int { owners.load(ordering: .acquiring) }

    func reserve(_ count: Int) throws -> RustStorageCredit {
        guard count > 0, count <= maximumBytes else { throw RustAdmission.outputLimit }
        var current = bytes.load(ordering: .relaxed)
        while true {
            guard current <= maximumBytes - count else { throw RustAdmission.outputLimit }
            let result = bytes.compareExchange(expected: current, desired: current + count, ordering: .acquiringAndReleasing)
            if result.exchanged { break }
            current = result.original
        }
        var currentOwners = owners.load(ordering: .relaxed)
        while true {
            guard currentOwners < maximumOwners else {
                bytes.subtract(count, ordering: .releasing)
                throw RustAdmission.capacity
            }
            let result = owners.compareExchange(expected: currentOwners, desired: currentOwners + 1, ordering: .acquiringAndReleasing)
            if result.exchanged { break }
            currentOwners = result.original
        }
        return RustStorageCredit(storage: self, bytes: count)
    }

    fileprivate func refund(_ count: Int) {
        bytes.subtract(count, ordering: .releasing)
        owners.subtract(1, ordering: .releasing)
    }
}

/// Reference semantics ensure copied pages, records and text share one credit.
/// The final ARC reference refunds once; no caller can refund an active owner.
final class RustStorageCredit: Sendable {
    private let storage: RustRetainedStorage
    let bytes: Int
    fileprivate init(storage: RustRetainedStorage, bytes: Int) {
        self.storage = storage
        self.bytes = bytes
    }
    deinit { storage.refund(bytes) }
}
