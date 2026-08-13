import Foundation

public struct TraceRecentDocument: Hashable, Sendable, Identifiable {
    public let url: URL
    public var id: String { url.standardizedFileURL.path }

    public init(url: URL) {
        self.url = url
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
            guard let url = resolve(data), url.isFileURL else { continue }
            retained.append(data)
            result.append(TraceRecentDocument(url: url))
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
        var values = storedData().filter { existing in
            guard let existingURL = resolve(existing) else { return false }
            return existingURL.standardizedFileURL != standardized
        }
        values.insert(data, at: 0)
        defaults.set(Array(values.prefix(maximumCount)), forKey: key)
    }

    public func removeAll() {
        defaults.removeObject(forKey: key)
    }

    private func storedData() -> [Data] {
        defaults.array(forKey: key) as? [Data] ?? []
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
