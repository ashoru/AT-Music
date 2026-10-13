import Foundation

/// 内存级轻量音频 URL 解析结果缓存（带 TTL 时效，默认 2 小时）
/// 用于消除单曲循环、上一首/下一首反复回切、重复播放时的网络往返延迟，实现 0 毫秒秒播。
final class AudioURLCache {
    static let shared = AudioURLCache()

    struct CacheEntry {
        let url: URL
        let expireDate: Date
        let isPreview: Bool
    }

    private var cache: [String: CacheEntry] = [:]
    private let lock = NSLock()
    private let defaultTTL: TimeInterval = 2400 // 40 分钟（兼顾秒播与防盗链签名有效窗口）

    private init() {}

    private func cacheKey(songId: String, quality: String) -> String {
        "\(songId)_\(quality)"
    }

    func get(songKey: String, quality: String) -> (url: URL, isPreview: Bool)? {
        get(songId: songKey, quality: quality)
    }

    func set(songKey: String, quality: String, url: URL, isPreview: Bool = false, ttl: TimeInterval? = nil) {
        set(songId: songKey, quality: quality, url: url, isPreview: isPreview, ttl: ttl)
    }

    func remove(songKey: String, quality: String) {
        remove(songId: songKey, quality: quality)
    }

    func get(songId: Int, quality: String) -> (url: URL, isPreview: Bool)? {
        get(songId: String(songId), quality: quality)
    }

    func set(songId: Int, quality: String, url: URL, isPreview: Bool = false, ttl: TimeInterval? = nil) {
        set(songId: String(songId), quality: quality, url: url, isPreview: isPreview, ttl: ttl)
    }

    func remove(songId: Int, quality: String) {
        remove(songId: String(songId), quality: quality)
    }

    /// 获取未过期的有效音频 URL
    func get(songId: String, quality: String) -> (url: URL, isPreview: Bool)? {
        lock.lock()
        defer { lock.unlock() }

        let key = cacheKey(songId: songId, quality: quality)
        guard let entry = cache[key] else { return nil }

        if Date() > entry.expireDate {
            cache.removeValue(forKey: key)
            return nil
        }
        return (entry.url, entry.isPreview)
    }

    /// 写入音频 URL 缓存
    func set(songId: String, quality: String, url: URL, isPreview: Bool = false, ttl: TimeInterval? = nil) {
        lock.lock()
        defer { lock.unlock() }

        let key = cacheKey(songId: songId, quality: quality)
        let expireDate = Date().addingTimeInterval(ttl ?? defaultTTL)
        cache[key] = CacheEntry(url: url, expireDate: expireDate, isPreview: isPreview)
    }

    /// 清除指定歌曲的缓存
    func remove(songId: String, quality: String) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: cacheKey(songId: songId, quality: quality))
    }

    /// 清除所有缓存
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }
}
