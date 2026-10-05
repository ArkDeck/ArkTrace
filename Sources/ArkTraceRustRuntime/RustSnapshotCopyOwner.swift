/// Credits retained with the platform's converted scene. These are bounded
/// storage reservations, including conservative String/copy overhead, not RSS.
package final class RustSnapshotCopyOwner: Sendable {
    private let native: RustSnapshot
    private let credit: RustStorageCredit
    package init(native: RustSnapshot, maximumCopyBytes: Int) throws {
        self.native = native
        credit = try RustRetainedStorage.shared.reserve(maximumCopyBytes)
    }
    package func hit(atX x: Double, y: Double, viewport: RustViewport,
        backingScale: Double, mode: RustSnapshotHitMode) throws -> RustSnapshotHit? {
        try native.hit(atX: x, y: y, viewport: viewport, backingScale: backingScale, mode: mode)
    }
}
