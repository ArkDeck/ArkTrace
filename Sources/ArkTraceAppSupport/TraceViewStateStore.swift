import ArkTraceCore
import ArkTraceRendering
import ArkTraceRuntime
import Foundation

/// Per-trace view state persisted beside the cached Ready database: the user's
/// timeline annotations and which lanes they pinned.
///
/// The sidecar carries the trace's **content hash and nothing else** that could
/// identify where the trace came from — no absolute path, no file name, no
/// bookmark (AT-APP-001). Reopening the same bytes finds the same annotations
/// wherever that file now lives.
struct TraceViewStateSidecar: Codable, Hashable, Sendable {
    /// Bumped only on an incompatible layout change. An unreadable or
    /// unrecognised sidecar is treated as "no annotations", never as an error:
    /// bookmarks are convenience, and failing a trace open over them would be
    /// out of proportion.
    static let currentFormatVersion = 1

    let formatVersion: Int
    let traceSHA256: String
    let flags: [TimelineFlag]
    let marks: [TimelineMark]
    /// Pinned lanes, in the order the user arranged them. Optional so a
    /// sidecar written before favourites existed still decodes.
    let favoriteTrackIDs: [String]?
}

/// Reads and writes the view-state sidecar for one cache entry.
///
/// The file lives **inside the entry directory**, next to `database.sqlite`,
/// rather than at the trace level. The cache evicts whole entry directories and
/// only `rmdir`s the trace directory above them, so a trace-level file would
/// survive eviction as an orphan the inventory never counts. Entry-level means
/// annotations are removed exactly when the entry they belong to is.
struct TraceViewStateStore: Sendable {
    static let fileName = "view-state.json"

    let entryURL: URL
    let traceSHA256: String

    /// Nil when the session has no cache entry (an in-memory or uncached open),
    /// in which case annotations simply stay session-scoped.
    init?(cacheDirectory: URL, metadata: TraceCacheMetadata?) {
        guard let metadata else { return nil }
        traceSHA256 = metadata.cacheKey.traceSHA256
        entryURL = cacheDirectory
            .appending(path: metadata.cacheKey.traceSHA256, directoryHint: .isDirectory)
            .appending(path: metadata.cacheKey.parserKey, directoryHint: .isDirectory)
    }

    private var fileURL: URL { entryURL.appending(path: Self.fileName) }

    /// What one trace's persisted view state restores to.
    struct Restored: Equatable, Sendable {
        var annotations = TimelineAnnotations()
        var favoriteTrackIDs: [TimelineTrackID] = []

        var isEmpty: Bool { annotations.isEmpty && favoriteTrackIDs.isEmpty }
    }

    /// Never throws: a missing, truncated, or foreign-versioned sidecar yields
    /// empty state rather than blocking the trace.
    func load() -> Restored {
        guard let data = try? Data(contentsOf: fileURL),
            let sidecar = try? JSONDecoder().decode(
                TraceViewStateSidecar.self, from: data
            ),
            sidecar.formatVersion == TraceViewStateSidecar.currentFormatVersion,
            sidecar.traceSHA256 == traceSHA256
        else { return Restored() }
        return Restored(
            annotations: TimelineAnnotations(
                flags: sidecar.flags, marks: sidecar.marks
            ),
            favoriteTrackIDs: (sidecar.favoriteTrackIDs ?? []).map {
                TimelineTrackID(rawValue: $0)
            }
        )
    }

    /// Writes atomically so a crash mid-write cannot leave a half-file that
    /// would then be discarded on the next open. Empty state removes the
    /// sidecar instead of leaving `[]` behind.
    func save(
        annotations: TimelineAnnotations,
        favoriteTrackIDs: [TimelineTrackID]
    ) {
        // Transient marks are the current selection made visible, not a
        // bookmark; persisting them would resurrect a stale highlight.
        let persistentMarks = annotations.marks.filter(\.isPersistent)
        guard !annotations.flags.isEmpty || !persistentMarks.isEmpty
            || !favoriteTrackIDs.isEmpty
        else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let sidecar = TraceViewStateSidecar(
            formatVersion: TraceViewStateSidecar.currentFormatVersion,
            traceSHA256: traceSHA256,
            flags: annotations.flags,
            marks: persistentMarks,
            favoriteTrackIDs: favoriteTrackIDs.map(\.rawValue)
        )
        guard let data = try? JSONEncoder().encode(sidecar) else { return }
        let temporary = entryURL.appending(
            path: ".\(Self.fileName).\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: temporary, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }
}
