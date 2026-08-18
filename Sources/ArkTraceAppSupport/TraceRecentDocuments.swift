import Foundation

public struct TraceRecentDocument: Hashable, Sendable, Identifiable {
    public let url: URL
    /// Nothing is at the end of this entry's bookmark any more. The entry is
    /// kept and marked rather than dropped: a row that silently disappears
    /// never tells the user their trace is gone, and leaves them nothing to
    /// act on.
    public let isMissing: Bool
    public var id: String { url.standardizedFileURL.path }

    public init(url: URL, isMissing: Bool = false) {
        self.url = url
        self.isMissing = isMissing
    }
}

/// Bounded bookmark persistence. Security-scoped bookmarks are preferred;
/// the unsandboxed Developer-ID build falls back to a normal bookmark when
/// the OS does not provide a scope for a Finder-selected URL.
@MainActor
public final class TraceRecentDocumentStore {
    private let defaults: UserDefaults
    private let key: String
    private let maximumCount: Int
    private let maximumBookmarkBytes = 65_536

    public init(
        defaults: UserDefaults = .standard,
        key: String = "ArkTrace.RecentTraceBookmarks.v1",
        maximumCount: Int = 20
    ) {
        self.defaults = defaults
        self.key = key
        self.maximumCount = min(100, max(1, maximumCount))
    }

    public func documents() -> [TraceRecentDocument] {
        var retained: [Data] = []
        var result: [TraceRecentDocument] = []
        for data in storedData().prefix(maximumCount) {
            guard data.count <= maximumBookmarkBytes else { continue }
            guard let url = storedURL(data) else { continue }
            retained.append(data)
            result.append(
                TraceRecentDocument(
                    url: url,
                    isMissing: !FileManager.default.fileExists(atPath: url.path)
                )
            )
        }
        if retained != storedData() { defaults.set(retained, forKey: key) }
        return result
    }

    public func record(_ url: URL) throws {
        guard url.isFileURL else { return }
        let standardized = url.standardizedFileURL
        let data: Data
        do {
            data = try standardized.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            data = try standardized.bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        guard data.count <= maximumBookmarkBytes else { return }
        let target = identity(standardized)
        var values = storedData().filter { existing in
            guard let existingURL = storedURL(existing) else { return false }
            return identity(existingURL) != target
        }
        values.insert(data, at: 0)
        defaults.set(Array(values.prefix(maximumCount)), forKey: key)
    }

    /// Drops a single entry. The list is the user's shortcut list, not a log:
    /// an entry whose file is gone stays until they say otherwise, and this is
    /// how they say it.
    public func remove(_ url: URL) {
        let target = identity(url)
        let values = storedData().filter { existing in
            guard let existingURL = storedURL(existing) else { return false }
            return identity(existingURL) != target
        }
        if values.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(values, forKey: key)
        }
    }

    public func removeAll() {
        defaults.removeObject(forKey: key)
    }

    private func storedData() -> [Data] {
        defaults.array(forKey: key) as? [Data] ?? []
    }

    /// Where an entry points, whether or not the bookmark still resolves.
    ///
    /// A bookmark stops resolving once its file is deleted, but it also
    /// carries the path it was made from, and that is enough to keep naming
    /// the trace in the list. Deletion must not be the same event as leaving
    /// the list.
    private func storedURL(_ data: Data) -> URL? {
        if let resolved = resolve(data), resolved.isFileURL {
            return resolved.standardizedFileURL
        }
        guard
            let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path
        else { return nil }
        let url = URL(filePath: path, directoryHint: .notDirectory).standardizedFileURL
        return url.isFileURL ? url : nil
    }

    /// The comparison form of an entry's location.
    ///
    /// A bookmark resolves to the physical path while a caller's URL may still
    /// come through a symlink — `/var` for `/private/var` is the everyday case
    /// — and `resolvingSymlinksInPath()` reconciles the two only while the
    /// file exists, which is precisely what a deleted trace no longer does.
    /// Resolving the directory and keeping the name compares both forms
    /// without asking whether the file is still there.
    private func identity(_ url: URL) -> String {
        let directory = url.deletingLastPathComponent().resolvingSymlinksInPath()
        return directory
            .appending(path: url.lastPathComponent, directoryHint: .notDirectory)
            .standardizedFileURL.path
    }

    private func resolve(_ data: Data) -> URL? {
        for options in [
            URL.BookmarkResolutionOptions([.withSecurityScope, .withoutUI]),
            URL.BookmarkResolutionOptions([.withoutUI]),
        ] {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), !stale {
                return url
            }
        }
        return nil
    }
}
