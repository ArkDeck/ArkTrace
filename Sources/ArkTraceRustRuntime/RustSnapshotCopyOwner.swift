/// Credits retained with the platform's converted scene. These are bounded
/// storage reservations, including conservative String/copy overhead, not RSS.
package final class RustSnapshotCopyOwner: Sendable {
    private let native: RustSnapshot
    private let credit: RustStorageCredit
    package init(native: RustSnapshot, maximumCopyBytes: Int) throws {
        self.native = native
        credit = try RustRetainedStorage.shared.reserve(maximumCopyBytes)
    }
}
