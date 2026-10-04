import ArkTraceRendering
import Foundation

/// Compatibility IO adapter. Native held-FD persistence can replace these
/// operations without changing the controller's queue or close barrier.
struct TraceViewStateAccess: Sendable {
    let store: TraceViewStateStore

    @concurrent
    func load() async -> TraceViewStateStore.Restored {
        precondition(!Thread.isMainThread)
        return store.load()
    }

    @concurrent
    func save(_ state: TraceViewStateStore.Restored) async {
        precondition(!Thread.isMainThread)
        store.save(annotations: state.annotations, favoriteTrackIDs: state.favoriteTrackIDs)
    }
}

/// At most one active write and one latest pending snapshot. There is no
/// debounce delay or task per mutation. Close retains the session lease until
/// the final snapshot has been submitted to the storage adapter.
@MainActor
final class TraceViewStateWriteQueue {
    private let save: @Sendable (TraceViewStateStore.Restored) async -> Void
    private var pending: TraceViewStateStore.Restored?
    private var worker: Task<Void, Never>?

    init(save: @escaping @Sendable (TraceViewStateStore.Restored) async -> Void) {
        self.save = save
    }

    func submit(_ state: TraceViewStateStore.Restored) {
        pending = state
        guard worker == nil else { return }
        worker = Task { [self] in
            while let state = pending {
                pending = nil
                await save(state)
            }
            worker = nil
        }
    }

    func flush() async { await worker?.value }
}
