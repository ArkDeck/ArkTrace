import ArkTraceCore
import ArkTraceRendering
import ArkTraceRuntime
import Foundation
import XCTest

@testable import ArkTraceAppSupport

/// Persisted annotations: keyed by trace content, carrying nothing that says
/// where the trace came from, and degrading to "no annotations" rather than
/// failing an open.
final class TraceViewStateStoreTests: XCTestCase {
    func makeStore(root: URL) throws -> TraceViewStateStore {
        let metadata = TraceCacheMetadata(
            cacheKey: try TraceCacheKey(
                traceSHA256: String(repeating: "a", count: 64),
                parserBinarySHA256: String(repeating: "b", count: 64),
                upstreamRevision: String(repeating: "c", count: 40),
                schemaAdapterVersion: "2",
                indexSchemaVersion: 3
            ),
            parser: TraceParserIdentity(
                name: "parser", reportedVersion: "1",
                binarySHA256: String(repeating: "b", count: 64),
                upstreamRepository: "https://example.invalid/repo",
                upstreamRevision: String(repeating: "c", count: 40),
                architecture: "arm64", adapterVersion: "1", buildRecipeVersion: "1"
            ),
            sourceSHA256: String(repeating: "a", count: 64),
            sourceByteCount: 1,
            databasePreparation: TraceDatabasePreparationResult(
                schemaAdapterVersion: "2",
                schemaFingerprint: String(repeating: "d", count: 64),
                indexVersion: 3,
                upstreamDatabaseSHA256: String(repeating: "e", count: 64),
                upstreamDatabaseByteCount: 1
            ),
            databaseByteCount: 1,
            createdAt: Date(timeIntervalSince1970: 0),
            lastAccessedAt: Date(timeIntervalSince1970: 0)
        )
        let store = try XCTUnwrap(
            TraceViewStateStore(cacheDirectory: root, metadata: metadata)
        )
        try FileManager.default.createDirectory(
            at: store.entryURL, withIntermediateDirectories: true
        )
        return store
    }

    func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "arktrace-annotations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testRoundTripKeepsFlagsAndPersistentMarksOnly() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root: root)

        XCTAssertTrue(store.load().isEmpty, "no sidecar means no annotations")

        let annotations = TimelineAnnotations(
            flags: [
                TimelineFlag(id: 1, timestampNs: 400, label: "hotspot", colorIndex: 2)
            ],
            marks: [
                TimelineMark(
                    id: 2,
                    range: try TraceTimeRange.query(startNs: 10, endNs: 90),
                    label: "kept", colorIndex: 1, isPersistent: true
                ),
                TimelineMark(
                    id: 3,
                    range: try TraceTimeRange.query(startNs: 100, endNs: 200),
                    label: "transient", colorIndex: 0, isPersistent: false
                ),
            ]
        )
        store.save(annotations: annotations, favoriteTrackIDs: [])

        let restored = store.load().annotations
        XCTAssertEqual(restored.flags, annotations.flags)
        XCTAssertEqual(
            restored.marks.map(\.label), ["kept"],
            "a transient mark is the live selection made visible, not a bookmark"
        )
    }

    /// AT-APP-001: nothing on disk may say where the trace came from.
    func testSidecarContainsNoUserPath() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root: root)
        store.save(
            annotations: TimelineAnnotations(
                flags: [
                    TimelineFlag(id: 1, timestampNs: 1, label: "note", colorIndex: 0)
                ]
            ),
            favoriteTrackIDs: [TimelineTrackID(rawValue: "thread-state:9")]
        )
        let data = try Data(
            contentsOf: store.entryURL.appending(path: TraceViewStateStore.fileName)
        )
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("/Users"))
        XCTAssertFalse(text.contains(NSHomeDirectory()))
        XCTAssertFalse(text.contains(".htrace"))
        XCTAssertTrue(text.contains(String(repeating: "a", count: 64)))
    }

    func testEmptyAnnotationsRemoveTheSidecar() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root: root)
        let fileURL = store.entryURL.appending(path: TraceViewStateStore.fileName)
        store.save(
            annotations: TimelineAnnotations(
                flags: [TimelineFlag(id: 1, timestampNs: 1, label: "n", colorIndex: 0)]
            ),
            favoriteTrackIDs: []
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        store.save(annotations: TimelineAnnotations(), favoriteTrackIDs: [])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path),
            "an empty set removes the sidecar rather than leaving an empty one"
        )
    }

    /// A damaged or foreign sidecar must not block opening the trace.
    func testUnreadableOrMismatchedSidecarYieldsNoAnnotations() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root: root)
        let fileURL = store.entryURL.appending(path: TraceViewStateStore.fileName)

        try Data("not json".utf8).write(to: fileURL)
        XCTAssertTrue(store.load().isEmpty)

        // Right shape, wrong trace: annotations must never cross traces.
        let foreign = TraceViewStateSidecar(
            formatVersion: TraceViewStateSidecar.currentFormatVersion,
            traceSHA256: String(repeating: "f", count: 64),
            flags: [TimelineFlag(id: 1, timestampNs: 1, label: "x", colorIndex: 0)],
            marks: [],
            favoriteTrackIDs: nil
        )
        try JSONEncoder().encode(foreign).write(to: fileURL)
        XCTAssertTrue(store.load().isEmpty)

        // Right trace, unknown format version.
        let future = TraceViewStateSidecar(
            formatVersion: TraceViewStateSidecar.currentFormatVersion + 1,
            traceSHA256: store.traceSHA256,
            flags: [TimelineFlag(id: 1, timestampNs: 1, label: "x", colorIndex: 0)],
            marks: [],
            favoriteTrackIDs: nil
        )
        try JSONEncoder().encode(future).write(to: fileURL)
        XCTAssertTrue(store.load().isEmpty)
    }

    /// The sidecar lives inside the entry directory so cache eviction removes
    /// it with the entry instead of leaving an orphan the inventory never counts.
    func testSidecarLivesInsideTheCacheEntryDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root: root)
        XCTAssertEqual(
            store.entryURL.deletingLastPathComponent().lastPathComponent,
            String(repeating: "a", count: 64),
            "entry sits under the trace hash directory"
        )
        XCTAssertNotEqual(
            store.entryURL.lastPathComponent,
            String(repeating: "a", count: 64),
            "the sidecar is at entry level, not trace level"
        )
    }
}

extension TraceViewStateStoreTests {
    /// Favourites ride the same sidecar as annotations and survive a round
    /// trip in the order the user arranged them.
    func testFavoritesRoundTripInOrder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root: root)
        let ids = [
            TimelineTrackID(rawValue: "thread-state:3"),
            TimelineTrackID(rawValue: "named-slice:9"),
            TimelineTrackID(rawValue: "cpu:1"),
        ]
        store.save(annotations: TimelineAnnotations(), favoriteTrackIDs: ids)
        XCTAssertEqual(store.load().favoriteTrackIDs, ids, "order is the point")
        XCTAssertTrue(store.load().annotations.isEmpty)

        // Favourites alone are enough to keep the sidecar alive.
        XCTAssertFalse(store.load().isEmpty)
        store.save(annotations: TimelineAnnotations(), favoriteTrackIDs: [])
        XCTAssertTrue(store.load().isEmpty)
    }

    /// A sidecar written before favourites existed must still load.
    func testSidecarWithoutFavoritesStillDecodes() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root: root)
        let legacy = TraceViewStateSidecar(
            formatVersion: TraceViewStateSidecar.currentFormatVersion,
            traceSHA256: store.traceSHA256,
            flags: [TimelineFlag(id: 1, timestampNs: 5, label: "old", colorIndex: 0)],
            marks: [],
            favoriteTrackIDs: nil
        )
        try JSONEncoder().encode(legacy).write(
            to: store.entryURL.appending(path: TraceViewStateStore.fileName)
        )
        let restored = store.load()
        XCTAssertEqual(restored.annotations.flags.map(\.label), ["old"])
        XCTAssertTrue(restored.favoriteTrackIDs.isEmpty)
    }
}
