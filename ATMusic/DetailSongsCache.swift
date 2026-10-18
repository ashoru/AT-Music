import Foundation

/// 持久化详情页歌曲缓存。
/// 详情页优先展示上次成功加载的内容，过期后在后台静默刷新，避免每次进入都先显示转圈。
final class DetailSongsCache {
    static let shared = DetailSongsCache()

    struct Entry: Codable {
        let songs: [Song]
        let savedAt: Date
    }

    private let defaults = UserDefaults.standard
    private let storageKey = "atmusic.detailSongsCache.v1"
    private let lock = NSLock()
    private let persistenceQueue = DispatchQueue(
        label: "AT Music.DetailSongsCache.persistence",
        qos: .utility
    )
    private var entries: [String: Entry]

    /// 详情缓存保留 30 分钟；过期后仍先展示旧内容，再静默请求最新数据。
    let ttl: TimeInterval = 30 * 60

    private init() {
        entries = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    func cachedSongs(for key: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    func save(_ songs: [Song], for key: String) {
        guard !songs.isEmpty else { return }
        lock.lock()
        entries[key] = Entry(songs: songs, savedAt: Date())
        let snapshot = entries
        lock.unlock()
        persistAsync(snapshot)
    }

    func isFresh(_ entry: Entry, now: Date = Date()) -> Bool {
        now.timeIntervalSince(entry.savedAt) < ttl
    }

    func updateSong(_ updated: Song) {
        lock.lock()
        var changed = false
        for (key, entry) in entries {
            var updatedSongs = entry.songs
            var entryChanged = false
            for idx in updatedSongs.indices {
                let s = updatedSongs[idx]
                if s.identityKey == updated.identityKey || LocalLibraryStore.isMatchingSong(s, updated) || (s.source == updated.source && s.id == updated.id && s.id != 0) {
                    updatedSongs[idx] = updated
                    entryChanged = true
                }
            }
            if entryChanged {
                entries[key] = Entry(songs: updatedSongs, savedAt: entry.savedAt)
                changed = true
            }
        }
        let snapshot = entries
        lock.unlock()
        if changed { persistAsync(snapshot) }
    }

    func invalidateAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        persistAsync([:])
    }

    func invalidate(for key: String) {
        lock.lock()
        entries.removeValue(forKey: key)
        let snapshot = entries
        lock.unlock()
        persistAsync(snapshot)
    }

    private func persistAsync(_ value: [String: Entry]) {
        persistenceQueue.async { [defaults, storageKey] in
            guard let data = try? JSONEncoder().encode(value) else { return }
            defaults.set(data, forKey: storageKey)
        }
    }
}
