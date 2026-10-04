import Synchronization

/// Credits for the SDK's explicit JSON byte copies, distinct from Rust leases.
/// JSONDecoder scratch, decoded values and copies made by consumers are not an
/// RSS measurement or covered by this counter. Retained decoded DTO ownership
/// uses separate packed-owner credits for typed directory pages. Other typed
/// responses and complete AT-RUST-012 aggregate budgeting remain pending.
enum RustDecodeCopies {
    private static let used = Atomic<Int>(0)
    static let maximumBytes = 64 * 1024 * 1024
    struct Credit {
        let bytes: Int
        func release() { used.subtract(bytes, ordering: .releasing) }
    }
    static func reserve(_ bytes: Int) throws -> Credit {
        var current = used.load(ordering: .relaxed)
        while true {
            guard bytes > 0, bytes <= maximumBytes, current <= maximumBytes - bytes else { throw RustAdmission.outputLimit }
            let result = used.compareExchange(expected: current, desired: current + bytes, ordering: .acquiringAndReleasing)
            if result.exchanged { return Credit(bytes: bytes) }
            current = result.original
        }
    }
}
