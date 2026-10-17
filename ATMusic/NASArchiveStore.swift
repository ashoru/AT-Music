import Foundation
import Combine

/// 轻量级群晖 NAS 归档账本：记录已成功上传/归档到 NAS 的歌曲，彻底避免重复归档与覆盖
final class NASArchiveStore: ObservableObject {
    static let shared = NASArchiveStore()

    @Published private(set) var archivedIdentityKeys: Set<String> = []

    private let key = "atmusic.nas.archivedKeys.v1"
    private let defaults = UserDefaults.standard

    private init() {
        if let saved = defaults.stringArray(forKey: key) {
            archivedIdentityKeys = Set(saved)
        } else {
            archivedIdentityKeys = []
        }
    }

    /// 判断歌曲是否已经归档到群晖 NAS
    func isArchived(song: Song) -> Bool {
        // 1. 如果源头就是群晖 NAS，天然属于已归档
        if song.source == .synology {
            return true
        }
        // 2. 检查本地持久化账本（按全局唯一标识）
        if archivedIdentityKeys.contains(song.identityKey) {
            return true
        }
        // 3. 检查辅助识别键 (歌手 - 歌名 规整化比对，防止不同音源 ID 不一致导致重复归档)
        let normalizedKey = normalize(artist: song.artists, title: song.name)
        if !normalizedKey.isEmpty && archivedIdentityKeys.contains(normalizedKey) {
            return true
        }
        return false
    }

    /// 标记单首歌曲已归档
    func markArchived(song: Song, nasPath: String? = nil) {
        archivedIdentityKeys.insert(song.identityKey)
        let normalizedKey = normalize(artist: song.artists, title: song.name)
        if !normalizedKey.isEmpty {
            archivedIdentityKeys.insert(normalizedKey)
        }
        persist()
        ATMusicLogger.shared.log("📒 歌曲已记录入 NAS 归档账本：\(song.name) (Key: \(song.identityKey))", level: .info)
    }

    /// 批量标记已归档
    func markBatchArchived(songs: [Song]) {
        for song in songs {
            archivedIdentityKeys.insert(song.identityKey)
            let normalizedKey = normalize(artist: song.artists, title: song.name)
            if !normalizedKey.isEmpty {
                archivedIdentityKeys.insert(normalizedKey)
            }
        }
        persist()
    }

    /// 移除归档标记
    func removeArchived(song: Song) {
        archivedIdentityKeys.remove(song.identityKey)
        let normalizedKey = normalize(artist: song.artists, title: song.name)
        if !normalizedKey.isEmpty {
            archivedIdentityKeys.remove(normalizedKey)
        }
        persist()
    }

    /// 增量合并云端同步拉取的归档账本
    func mergeRemoteArchivedKeys(_ remoteKeys: [String]) {
        archivedIdentityKeys.formUnion(remoteKeys)
        persist()
    }

    private func persist() {
        defaults.set(Array(archivedIdentityKeys), forKey: key)
    }

    private func normalize(artist: String, title: String) -> String {
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanArtist.isEmpty && !cleanTitle.isEmpty else { return "" }
        return "norm:\(cleanArtist) - \(cleanTitle)"
    }
}
