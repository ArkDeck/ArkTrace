import ArkTraceCore
import ArkTraceStore
import Foundation

/// Delegates to the one reviewed bounded reader in Core and pairs the bytes
/// with the file identity SQLite later re-verifies. EINTR is retried and the
/// double-`fstat` change check happens inside `ArkTraceBoundedRegularFile`.
///
/// Cancellation is rethrown rather than folded into `nil`: a cancelled read
/// says nothing about entry health. Callers map `nil` to their own typed
/// outcome — the cache quarantines (`CacheIO.metadata`), the session surfaces
/// an invalid-database error — which is why this helper does not throw a
/// domain error itself. Replaces two verbatim copies that lived in
/// `TraceCache` and `TraceSession`.
func readBoundedRegularFileSnapshot(
    at url: URL,
    maximumByteCount: Int
) throws -> (data: Data, fileIdentity: TraceDatabaseFileIdentity)? {
    do {
        let contents = try ArkTraceBoundedRegularFile.readContents(
            at: url,
            maximumByteCount: maximumByteCount
        )
        return (
            contents.data,
            TraceDatabaseFileIdentity(
                device: contents.device,
                inode: contents.inode
            )
        )
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        return nil
    }
}
