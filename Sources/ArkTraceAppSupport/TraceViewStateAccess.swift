import ArkTraceCore
import ArkTraceRendering
import Foundation
#if canImport(ArkTraceRustRuntime)
import ArkTraceRustRuntime
#endif

/// One document's persistence authority. Native products use their held
/// Session; the legacy product uses its existing compatibility store.
struct TraceViewStateAccess: Sendable {
    private let read: @Sendable () async throws -> TraceViewStateStore.Restored
    private let write: @Sendable (TraceViewStateStore.Restored) async throws -> Void

    init(load: @escaping @Sendable () async throws -> TraceViewStateStore.Restored,
         save: @escaping @Sendable (TraceViewStateStore.Restored) async throws -> Void) {
        read = load; write = save
    }
    init(store: TraceViewStateStore) {
        self.init(load: { store.load() }, save: { store.save(annotations: $0.annotations, favoriteTrackIDs: $0.favoriteTrackIDs) })
    }

    @concurrent
    func load() async throws -> TraceViewStateStore.Restored {
        precondition(!Thread.isMainThread)
        do { return try await read() } catch { throw Self.mapped(error) }
    }

    @concurrent
    func save(_ state: TraceViewStateStore.Restored) async throws {
        precondition(!Thread.isMainThread)
        do { try await write(state) } catch { throw Self.mapped(error) }
    }

    private static func mapped(_ error: any Error) -> any Error {
        #if canImport(ArkTraceRustRuntime)
        if let admission = error as? RustAdmission { return RustTraceRepository.admissionError(admission) }
        #endif
        return error
    }

    #if canImport(ArkTraceRustRuntime)
    init(session: RustSession, traceSHA256: String, timeoutMilliseconds: UInt32) {
        self.init(load: {
            switch try await session.readViewState(timeoutMilliseconds: timeoutMilliseconds) {
            case .missing, .sessionScoped: return TraceViewStateStore.Restored()
            case .preserved:
                throw ArkTraceError(code: .queryFailed, stage: .querying,
                    message: "Saved annotations and favorites could not be restored. The original file was kept.",
                    details: ["reason": "viewStatePreserved"])
            case .restored(let view):
                var flags: [TimelineFlag] = [], marks: [TimelineMark] = [], favorites: [TimelineTrackID] = []
                flags.reserveCapacity(view.flagCount); marks.reserveCapacity(view.markCount)
                favorites.reserveCapacity(view.favoriteTrackCount ?? 0)
                for index in 0..<view.flagCount {
                    try Task.checkCancellation()
                    let flag = view.flag(at: index)
                    guard let id = Int(exactly: flag.id), let color = Int(exactly: flag.colorIndex) else { throw RustAdmission.invalidBuffer }
                    flags.append(TimelineFlag(id: id, timestampNs: flag.timestampNs, label: await flag.label.copyString(), colorIndex: color))
                }
                for index in 0..<view.markCount {
                    try Task.checkCancellation()
                    let mark = view.mark(at: index)
                    guard let id = Int(exactly: mark.id), let color = Int(exactly: mark.colorIndex) else { throw RustAdmission.invalidBuffer }
                    marks.append(TimelineMark(id: id, range: mark.range, label: await mark.label.copyString(), colorIndex: color, isPersistent: mark.isPersistent))
                }
                for index in 0..<(view.favoriteTrackCount ?? 0) {
                    try Task.checkCancellation()
                    favorites.append(TimelineTrackID(rawValue: await view.favoriteTrackID(at: index).copyString()))
                }
                try Task.checkCancellation()
                return TraceViewStateStore.Restored(annotations: TimelineAnnotations(flags: flags, marks: marks), favoriteTrackIDs: favorites)
            }
        }, save: { state in
            guard state.annotations.flags.count <= 4096,
                  state.annotations.marks.count <= 4096 - state.annotations.flags.count,
                  state.favoriteTrackIDs.count <= 4096 else { throw RustAdmission.outputLimit }
            let input = RustViewStateDocument(traceSHA256: traceSHA256,
                flags: state.annotations.flags.map { RustViewStateFlag(id: Int64($0.id), timestampNs: $0.timestampNs, label: $0.label, colorIndex: Int64($0.colorIndex)) },
                marks: state.annotations.marks.map { RustViewStateMark(id: Int64($0.id), range: $0.range, label: $0.label, colorIndex: Int64($0.colorIndex), isPersistent: $0.isPersistent) },
                favoriteTrackIDs: state.favoriteTrackIDs.map(\.rawValue))
            let status = try await session.writeViewState(input, timeoutMilliseconds: timeoutMilliseconds)
            if status == .preserved {
                throw ArkTraceError(code: .queryFailed, stage: .querying,
                    message: "Annotations and favorites could not be saved. The existing file was kept.",
                    details: ["reason": "viewStatePreserved"])
            }
        })
    }
    #endif
}

/// At most one active write and one latest pending snapshot. There is no
/// debounce delay or task per mutation. Close retains the session lease until
/// the final snapshot has been submitted to the storage adapter.
@MainActor
final class TraceViewStateWriteQueue {
    private let save: @Sendable (TraceViewStateStore.Restored) async throws -> Void
    private let failed: @MainActor @Sendable (any Error) -> Void
    private var pending: TraceViewStateStore.Restored?
    private var worker: Task<Void, Never>?
    private var failure: (any Error)?

    init(save: @escaping @Sendable (TraceViewStateStore.Restored) async throws -> Void,
         failed: @escaping @MainActor @Sendable (any Error) -> Void = { _ in }) {
        self.save = save; self.failed = failed
    }

    func submit(_ state: TraceViewStateStore.Restored) {
        pending = state
        guard worker == nil else { return }
        worker = Task { [self] in
            while let state = pending {
                pending = nil
                do { try await save(state); failure = nil }
                catch { failure = error; failed(error) }
            }
            worker = nil
        }
    }

    func flush() async throws {
        await worker?.value
        if let failure { throw failure }
    }
}
