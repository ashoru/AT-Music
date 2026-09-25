import Foundation

/// 歌单播放来源策略。歌单仍保存原始歌曲；策略只影响播放时选择哪个已存在来源。
enum PlaylistSourceStrategy: String, CaseIterable, Codable, Identifiable {
    case automatic
    case preferNetEase
    case preferQQ
    case preferKugou
    case preferSynology

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "自动（按歌单记录）"
        case .preferNetEase: return "优先网易云音乐"
        case .preferQQ: return "优先 QQ 音乐"
        case .preferKugou: return "优先酷狗音乐"
        case .preferSynology: return "优先群晖 NAS"
        }
    }
    var preferredSource: SongSource? {
        switch self {
        case .automatic: return nil
        case .preferNetEase: return .netease
        case .preferQQ: return .qq
        case .preferKugou: return .kugou
        case .preferSynology: return .synology
        }
    }
}

/// 本地歌单（保存在设备本机，不依赖任何平台账号）。可混合保存多个平台歌曲。
struct LocalPlaylist: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var songs: [Song] = []
    var createdAt = Date()
    var sourceStrategy: PlaylistSourceStrategy = .automatic

    enum CodingKeys: String, CodingKey { case id, name, songs, createdAt, sourceStrategy }

    init(id: UUID = UUID(), name: String, songs: [Song] = [], createdAt: Date = Date(), sourceStrategy: PlaylistSourceStrategy = .automatic) {
        self.id = id
        self.name = name
        self.songs = songs
        self.createdAt = createdAt
        self.sourceStrategy = sourceStrategy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名歌单"
        songs = try c.decodeIfPresent([Song].self, forKey: .songs) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        sourceStrategy = try c.decodeIfPresent(PlaylistSourceStrategy.self, forKey: .sourceStrategy) ?? .automatic
    }
}

/// 本地音乐库：本地歌单的创建 / 删除 / 收藏歌曲，UserDefaults JSON 持久化（覆盖安装不丢失）
final class LocalLibraryStore: ObservableObject {
    static let shared = LocalLibraryStore()

    @Published var playlists: [LocalPlaylist] {
        didSet { save() }
    }
    @Published var importedSongs: [Song] {
        didSet { saveImportedSongs() }
    }

    private let defaults = UserDefaults.standard
    private let key = "atmusic.localLibrary.playlists"
    private let importedSongsKey = "atmusic.localLibrary.importedSongs.v1"

    private init() {
        if let data = defaults.data(forKey: key),
           let list = try? JSONDecoder().decode([LocalPlaylist].self, from: data) {
            playlists = list
            UnifiedSongStore.synchronizeLegacy(list)
        } else {
            playlists = []
        }
        if let data = defaults.data(forKey: importedSongsKey),
           let songs = try? JSONDecoder().decode([Song].self, from: data) {
            importedSongs = songs.filter { $0.source == .local }
        } else {
            importedSongs = []
        }
    }

    @discardableResult
    func createPlaylist(name: String) -> LocalPlaylist {
        let playlist = LocalPlaylist(name: name)
        playlists.append(playlist)
        return playlist
    }

    func deletePlaylist(id: UUID) {
        playlists.removeAll { $0.id == id }
    }

    func renamePlaylist(id: UUID, name: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].name = name
    }

    /// 调整本地歌单顺序，顺序会随歌单一起持久化。
    func movePlaylist(id: UUID, offset: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard playlists.indices.contains(destination) else { return }
        var reordered = playlists
        reordered.swapAt(index, destination)
        playlists = reordered
    }

    /// 使用 List 的拖动结果更新顺序，显式重新赋值确保 @Published 与持久化都能触发。
    func movePlaylists(from offsets: IndexSet, to destination: Int) {
        var reordered = playlists
        reordered.move(fromOffsets: offsets, toOffset: destination)
        playlists = reordered
    }

    /// 添加歌曲到本地歌单（按 identityKey 去重）
    func addSong(_ song: Song, to id: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        guard !playlists[idx].songs.contains(where: { $0.identityKey == song.identityKey }) else { return }
        playlists[idx].songs.append(song)
    }

    @discardableResult
    func addSongs(_ songs: [Song], to id: UUID) -> Int {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return 0 }
        var seen = Set(playlists[index].songs.map(\.identityKey))
        let added = songs.filter { seen.insert($0.identityKey).inserted }
        if !added.isEmpty { playlists[index].songs.append(contentsOf: added) }
        return added.count
    }

    /// 设置混合歌单的播放来源偏好；不会删除或替换歌单中的原始来源记录。
    func setSourceStrategy(_ strategy: PlaylistSourceStrategy, for id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].sourceStrategy = strategy
    }

    /// 根据歌单策略解析播放快照。没有严格匹配的替代来源时保留原歌曲，避免歌单消失。
    func playbackSongs(for id: UUID) -> [Song] {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return [] }
        guard let preferred = playlist.sourceStrategy.preferredSource else { return playlist.songs }
        return playlist.songs.map { song in
            UnifiedSongStore.shared.alternateSongs(for: song, preferredSource: preferred).first ?? song
        }
    }

    func containsSong(_ song: Song?) -> Bool {
        guard let song else { return false }
        return playlists.contains { $0.songs.contains { $0.identityKey == song.identityKey } }
    }

    @discardableResult
    func addToDefaultFavorites(_ song: Song, name: String = "我的收藏歌单") -> String {
        let playlist = playlists.first(where: { $0.name == name }) ?? createPlaylist(name: name)
        let before = playlists.first(where: { $0.id == playlist.id })?.songs.count ?? 0
        addSong(song, to: playlist.id)
        let after = playlists.first(where: { $0.id == playlist.id })?.songs.count ?? before
        return after > before ? "已加入「\(playlist.name)」" : "已在「\(playlist.name)」中"
    }

    @discardableResult
    func syncSongs(_ songs: [Song], intoPlaylistNamed name: String = "三平台喜欢") -> Int {
        let target: LocalPlaylist
        if let existing = playlists.first(where: { $0.name == name }) {
            target = existing
        } else {
            target = createPlaylist(name: name)
        }
        return addSongs(songs, to: target.id)
    }

    func removeSong(playlistID: UUID, songIdentity: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[idx].songs.removeAll { $0.identityKey == songIdentity }
    }

    @discardableResult
    func removeSongFromAllPlaylists(_ song: Song) -> Int {
        var removed = 0
        for index in playlists.indices {
            let before = playlists[index].songs.count
            playlists[index].songs.removeAll { $0.identityKey == song.identityKey }
            removed += before - playlists[index].songs.count
        }
        return removed
    }

    func addImportedSongs(_ songs: [Song]) {
        var seen = Set(importedSongs.map(\.identityKey))
        importedSongs.append(contentsOf: songs.filter { $0.source == .local && seen.insert($0.identityKey).inserted })
    }

    func updateImportedSong(_ song: Song) {
        guard let index = importedSongs.firstIndex(where: { $0.identityKey == song.identityKey }) else { return }
        importedSongs[index] = song
        for playlistIndex in playlists.indices {
            for songIndex in playlists[playlistIndex].songs.indices where playlists[playlistIndex].songs[songIndex].identityKey == song.identityKey {
                playlists[playlistIndex].songs[songIndex] = song
            }
        }
    }

    @discardableResult
    func removeImportedSong(_ song: Song) -> Bool {
        if let relativePath = song.localRelativePath {
            do {
                try LocalAudioFileManager.shared.deleteFileAndSupport(relativePath: relativePath)
            } catch {
                ATMusicLogger.shared.log("删除本地音频副本失败：\(error.localizedDescription)", level: .error)
                return false
            }
        }
        importedSongs.removeAll { $0.identityKey == song.identityKey }
        _ = removeSongFromAllPlaylists(song)
        return true
    }

    private func save() {
        if let data = try? JSONEncoder().encode(playlists) {
            defaults.set(data, forKey: key)
            UnifiedSongStore.synchronizeLegacy(playlists)
        }
    }

    private func saveImportedSongs() {
        if let data = try? JSONEncoder().encode(importedSongs) {
            defaults.set(data, forKey: importedSongsKey)
        }
    }
}
