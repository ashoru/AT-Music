import Foundation
import CryptoKit
import UIKit

struct SynologyFolderItem: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case folder
        case song
    }

    let id: String
    let name: String
    let kind: Kind
    let song: Song?
}

struct SynologySearchResult {
    let songs: [Song]
    let artists: [Artist]
    let albums: [Album]
}

/// NAS 文件当前在编辑器中展示的标签快照。
struct SynologyTagMetadata: Equatable {
    var title: String
    var artist: String
    var album: String
    var albumArtist: String = ""
    var genre: String = ""
    var year: String = ""
    var comment: String = ""

    func patch(comparedTo original: SynologyTagMetadata) -> SynologyTagPatch {
        SynologyTagPatch(
            title: title == original.title ? nil : title,
            artist: artist == original.artist ? nil : artist,
            album: album == original.album ? nil : album,
            albumArtist: albumArtist == original.albumArtist ? nil : albumArtist,
            genre: genre == original.genre ? nil : genre,
            year: year == original.year ? nil : year,
            comment: comment == original.comment ? nil : comment
        )
    }
}

/// 只包含用户实际修改过的 NAS 标签。`nil` 表示完全不触碰该标签，空字符串则表示用户明确清空它。
struct SynologyTagPatch {
    let title: String?
    let artist: String?
    let album: String?
    let albumArtist: String?
    let genre: String?
    let year: String?
    let comment: String?

    var isEmpty: Bool {
        [title, artist, album, albumArtist, genre, year, comment].allSatisfy { $0 == nil }
    }
}

struct SynologyMetadataCandidate: Identifiable, Hashable {
    let id: String
    let song: Song
    let providerName: String
}

final class SynologyAPI: ObservableObject {
    static let shared = SynologyAPI()

    @Published var isLoggedIn: Bool = false
    @Published var host: String = ""
    @Published var port: Int = 5000
    @Published var isHTTPS: Bool = false
    @Published var account: String = ""
    /// 全库索引完成后递增，搜索页可据此把首屏远程结果替换为完整本地结果。
    @Published private(set) var libraryIndexRevision: Int = 0
    @Published private(set) var isLibraryIndexLoading: Bool = false

    private let defaults = UserDefaults.standard
    private let hostKey = "atmusic.synology.host"
    private let portKey = "atmusic.synology.port"
    private let httpsKey = "atmusic.synology.https"
    private let accountKey = "atmusic.synology.account"
    private let sidKey = "atmusic.synology.sid"
    private let passwordKey = "atmusic.synology.password"

    private(set) var sid: String = ""
    private var storedPassword: String = ""
    private var configurationGeneration = UUID()
    private let session: URLSession
    /// 搜索索引缓存：首次搜索建立，后续输入关键词只在内存中匹配，不再反复分页请求 NAS。
    private var librarySongsCache: [Song] = []
    private var librarySongsCacheUpdatedAt = Date.distantPast
    private var librarySongsLoadingTask: Task<[Song], Error>?
    private let librarySongsCacheTTL: TimeInterval = 600
    private var didRestorePersistentLibraryIndex = false

    private struct LibraryIndexSnapshot: Codable {
        let version: Int
        let updatedAt: Date
        let songs: [Song]

        init(updatedAt: Date, songs: [Song]) {
            self.version = 2
            self.updatedAt = updatedAt
            self.songs = songs
        }
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)

        host = defaults.string(forKey: hostKey) ?? ""
        port = defaults.integer(forKey: portKey) == 0 ? 5000 : defaults.integer(forKey: portKey)
        isHTTPS = defaults.bool(forKey: httpsKey)
        account = defaults.string(forKey: accountKey) ?? ""
        let credentials = SecureCredentialStore.shared
        let passwordDestination = "synology.password." + currentServerScope
        _ = credentials.migrateLegacyPassword(defaults: defaults, destinationKey: passwordDestination)
        // 兼容 Gemini 开发版的单槽钥匙串；仅针对启动时已保存的连接迁移。
        if credentials.secret(for: passwordDestination) == nil,
           let old = credentials.secret(for: "synology.password"),
           credentials.setSecret(old, for: passwordDestination) {
            credentials.deleteSecret(for: "synology.password")
        }
        storedPassword = credentials.secret(for: passwordDestination) ?? defaults.string(forKey: passwordKey) ?? ""
        sid = credentials.secret(for: "synology.sid." + currentServerScope) ?? defaults.string(forKey: sidKey) ?? ""
        if !sid.isEmpty {
            rememberLegacySession(sid)
            if credentials.setSecret(sid, for: "synology.sid." + currentServerScope) {
                defaults.removeObject(forKey: sidKey)
            }
        }
        isLoggedIn = !sid.isEmpty && !host.isEmpty
    }

    var baseURL: String {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmedHost
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
        let scheme = isHTTPS ? "https" : "http"
        return "\(scheme)://\(cleaned):\(port)"
    }

    // MARK: - 鉴权

    var currentServerScope: String {
        NASSourceScope.make(host: host, port: port, https: isHTTPS, account: account)
    }
    var savedPassword: String { storedPassword }

    private func sessionFingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func rememberLegacySession(_ token: String) {
        // 只记录会话摘要和已知所属连接，帮助旧歌单安全升级；绝不把历史歌单猜配到新服务器。
        defaults.set(currentServerScope, forKey: "atmusic.synology.sessionScope." + sessionFingerprint(token))
    }
    func accepts(song: Song) -> Bool {
        guard song.source == .synology else { return false }
        if let scope = song.synologyServerScope { return scope == currentServerScope }
        guard let cover = song.coverURL,
              let parts = URLComponents(url: cover, resolvingAgainstBaseURL: false),
              let base = URLComponents(string: baseURL), parts.host == base.host,
              parts.port == base.port, parts.scheme == base.scheme,
              let token = parts.queryItems?.first(where: { $0.name == "_sid" })?.value else { return false }
        return defaults.string(forKey: "atmusic.synology.sessionScope." + sessionFingerprint(token)) == currentServerScope
    }

    func saveConfiguration(host: String, port: Int, isHTTPS: Bool, account: String, password: String) throws {
        let scope = NASSourceScope.make(host: host, port: port, https: isHTTPS, account: account)
        guard SecureCredentialStore.shared.setSecret(password, for: "synology.password." + scope) else {
            throw SynologyError.loginFailed("密码未能安全保存，请解锁设备后重试；原连接和密码未删除")
        }
        if scope != currentServerScope {
            configurationGeneration = UUID()
            librarySongsLoadingTask?.cancel()
            librarySongsLoadingTask = nil
            librarySongsCache.removeAll()
            librarySongsCacheUpdatedAt = .distantPast
            didRestorePersistentLibraryIndex = false
            sid = ""
            isLoggedIn = false
            defaults.removeObject(forKey: sidKey)
        }
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.isHTTPS = isHTTPS
        self.account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        self.storedPassword = password

        defaults.set(self.host, forKey: hostKey)
        defaults.set(self.port, forKey: portKey)
        defaults.set(self.isHTTPS, forKey: httpsKey)
        defaults.set(self.account, forKey: accountKey)
        defaults.removeObject(forKey: passwordKey)
    }

    /// 登录群晖 Audio Station (SYNO.API.Auth)
    func login(otpCode: String? = nil) async throws {
        guard !host.isEmpty else { throw SynologyError.missingConfiguration("服务器地址未配置") }
        guard !account.isEmpty else { throw SynologyError.missingConfiguration("账号未填写") }
        guard !storedPassword.isEmpty else { throw SynologyError.missingConfiguration("密码未填写") }

        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.API.Auth"),
            URLQueryItem(name: "version", value: "3"),
            URLQueryItem(name: "method", value: "login"),
            URLQueryItem(name: "account", value: account),
            URLQueryItem(name: "passwd", value: storedPassword),
            URLQueryItem(name: "session", value: "AudioStation"),
            URLQueryItem(name: "format", value: "sid"),
            URLQueryItem(name: "otp_code", value: otpCode)
        ].filter { $0.value != nil }

        let json = try await get("/webapi/auth.cgi", query: queryItems, authenticated: false)
        guard let data = json["data"] as? [String: Any], let newSid = data["sid"] as? String, !newSid.isEmpty else {
            throw SynologyError.loginFailed("未能获取到有效会话令牌")
        }

        guard SecureCredentialStore.shared.setSecret(newSid, for: "synology.sid." + currentServerScope) else {
            throw SynologyError.loginFailed("会话无法安全保存，请解锁设备后重试")
        }
        self.sid = newSid
        rememberLegacySession(newSid)
        defaults.removeObject(forKey: sidKey)
        librarySongsCache.removeAll()
        librarySongsCacheUpdatedAt = .distantPast
        didRestorePersistentLibraryIndex = false
        await MainActor.run {
            self.isLoggedIn = true
        }
        ATMusicLogger.shared.log("群晖 NAS 登录成功", level: .info)
    }

    /// 退出登录
    func logout() async {
        let scope = currentServerScope
        if !sid.isEmpty {
            let query = [
                URLQueryItem(name: "api", value: "SYNO.API.Auth"),
                URLQueryItem(name: "version", value: "1"),
                URLQueryItem(name: "method", value: "logout"),
                URLQueryItem(name: "session", value: "AudioStation")
            ]
            _ = try? await get("/webapi/auth.cgi", query: query, authenticated: true)
        }
        guard scope == currentServerScope else { return }
        configurationGeneration = UUID()
        librarySongsLoadingTask?.cancel()
        librarySongsLoadingTask = nil
        sid = ""
        SecureCredentialStore.shared.deleteSecret(for: "synology.sid." + scope)
        librarySongsCache.removeAll()
        librarySongsCacheUpdatedAt = .distantPast
        didRestorePersistentLibraryIndex = false
        defaults.removeObject(forKey: sidKey)
        await MainActor.run {
            isLoggedIn = false
        }
        ATMusicLogger.shared.log("群晖 NAS 已注销登录", level: .info)
    }

    // MARK: - 资源地址构造

    /// 构造音频播放直链 (SYNO.AudioStation.Stream)
    func songURL(song: Song) -> String? {
        guard accepts(song: song), isLoggedIn, !sid.isEmpty, let synoId = song.synologyId ?? (song.source == .synology ? "\(song.id)" : nil) else {
            return nil
        }
        var url = URLComponents(string: baseURL + "/webapi/AudioStation/stream.cgi/0.mp3")
        url?.queryItems = [URLQueryItem(name: "api", value: "SYNO.AudioStation.Stream"),
            URLQueryItem(name: "version", value: "2"), URLQueryItem(name: "method", value: "stream"),
            URLQueryItem(name: "id", value: synoId), URLQueryItem(name: "_sid", value: sid)]
        return url?.url?.absoluteString
    }

    /// 构造封面图直链 (SYNO.AudioStation.Cover)
    func coverURL(songId: String, cacheBust: String? = nil) -> URL? {
        guard !sid.isEmpty else { return nil }
        let encodedId = songId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? songId
        var urlStr = "\(baseURL)/webapi/AudioStation/cover.cgi?api=SYNO.AudioStation.Cover&version=1&method=getsongcover&library=all&id=\(encodedId)&_sid=\(sid)"
        if let cacheBust, !cacheBust.isEmpty {
            urlStr += "&_atmusic_refresh=\(cacheBust.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cacheBust)"
        }
        return URL(string: urlStr)
    }

    func coverURL(albumName: String, artistName: String) -> URL? {
        guard !sid.isEmpty else { return nil }
        let albumEnc = albumName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? albumName
        let artistEnc = artistName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? artistName
        let urlStr = "\(baseURL)/webapi/AudioStation/cover.cgi?api=SYNO.AudioStation.Cover&version=1&method=getcover&library=all&album_name=\(albumEnc)&artist_name=\(artistEnc)&_sid=\(sid)"
        return URL(string: urlStr)
    }

    // MARK: - 数据读取

    /// 获取歌曲列表 (SYNO.AudioStation.Song)
    func songs(offset: Int = 0, limit: Int = 100, sort: String = "title") async throws -> [Song] {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.AudioStation.Song"),
            URLQueryItem(name: "version", value: "3"),
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "sort_by", value: sort),
            URLQueryItem(name: "sort_direction", value: "ASC"),
            URLQueryItem(name: "library", value: "all"),
            URLQueryItem(name: "additional", value: "song_tag,song_audio")
        ]

        let json = try await get("/webapi/AudioStation/song.cgi", query: query, authenticated: true)
        guard let data = json["data"] as? [String: Any], let songsArray = data["songs"] as? [[String: Any]] else {
            return []
        }

        return songsArray.compactMap { self.parseSong($0) }
    }

    /// 分页读取完整音乐库。Audio Station 的搜索接口在不同 DSM/Audio Station 版本上
    /// 返回字段并不一致，因此搜索时会用这份完整目录做本地兜底匹配。
    func librarySongs(pageSize: Int = 500, forceRefresh: Bool = false) async throws -> [Song] {
        restorePersistentLibraryIndexIfNeeded()
        if !forceRefresh,
           !librarySongsCache.isEmpty,
           Date().timeIntervalSince(librarySongsCacheUpdatedAt) < librarySongsCacheTTL {
            return librarySongsCache
        }

        if let loadingTask = librarySongsLoadingTask {
            return try await loadingTask.value
        }

        let safePageSize = max(50, min(pageSize, 1000))
        await MainActor.run {
            self.isLibraryIndexLoading = true
        }
        let loadingTask = Task { [weak self] () throws -> [Song] in
            guard let self else { return [] }
            var result: [Song] = []
            var offset = 0
            // 不用固定 20,000 首截断；只用较高安全上限防止异常 NAS 无限返回同一页。
            while result.count < 100_000 {
                let page = try await self.songs(offset: offset, limit: safePageSize, sort: "title")
                if page.isEmpty { break }
                result.append(contentsOf: page)
                offset += page.count
                if page.count < safePageSize { break }
            }
            var seen = Set<String>()
            return result.filter { seen.insert($0.identityKey).inserted }
        }
        librarySongsLoadingTask = loadingTask
        defer {
            librarySongsLoadingTask = nil
            Task { @MainActor in
                self.isLibraryIndexLoading = false
            }
        }
        do {
            let result = try await loadingTask.value
            librarySongsCache = result
            librarySongsCacheUpdatedAt = Date()
            persistLibraryIndex()
            await MainActor.run {
                self.libraryIndexRevision &+= 1
            }
            return result
        } catch {
            throw error
        }
    }

    private var persistentLibraryIndexFile: AtomicLibraryFile<LibraryIndexSnapshot> {
        let key = sessionFingerprint(currentServerScope)
        let directory = AtomicLibraryFile<LibraryIndexSnapshot>.defaultDirectory
            .appendingPathComponent("NASIndexes", isDirectory: true)
        return AtomicLibraryFile(url: directory.appendingPathComponent("\(key).json"))
    }

    private func restorePersistentLibraryIndexIfNeeded() {
        guard !didRestorePersistentLibraryIndex else { return }
        didRestorePersistentLibraryIndex = true
        guard !currentServerScope.isEmpty,
              let snapshot = try? persistentLibraryIndexFile.read(),
              snapshot.version == 2,
              !snapshot.songs.isEmpty else { return }
        librarySongsCache = snapshot.songs
        librarySongsCacheUpdatedAt = snapshot.updatedAt
    }

    private func persistLibraryIndex() {
        guard !librarySongsCache.isEmpty else { return }
        let snapshot = LibraryIndexSnapshot(updatedAt: librarySongsCacheUpdatedAt, songs: librarySongsCache)
        try? persistentLibraryIndexFile.write(snapshot)
    }

    /// 搜索群晖音乐
    func search(keyword: String, limit: Int = 50) async throws -> [Song] {
        try await searchAll(keyword: keyword, limit: limit).songs
    }

    /// 搜索歌曲、歌手、专辑。Audio Station Search 接口一次返回三类结果。
    func searchAll(keyword: String, limit: Int = 50) async throws -> SynologySearchResult {
        guard !keyword.isEmpty else {
            return SynologySearchResult(songs: [], artists: [], albums: [])
        }
        let query: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.AudioStation.Search"),
            URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "sort_by", value: "title"),
            URLQueryItem(name: "sort_direction", value: "ASC"),
            URLQueryItem(name: "library", value: "all"),
            URLQueryItem(name: "additional", value: "song_tag,song_audio")
        ]

        let json = try await get("/webapi/AudioStation/search.cgi", query: query, authenticated: true)
        guard let data = json["data"] as? [String: Any] else {
            return SynologySearchResult(songs: [], artists: [], albums: [])
        }

        let songs = (data["songs"] as? [[String: Any]] ?? []).compactMap { self.parseSong($0) }
        let artists = (data["artists"] as? [[String: Any]] ?? []).compactMap { item -> Artist? in
            guard let name = Self.stringValue(item["name"]), !name.isEmpty else { return nil }
            return Artist(id: "synology-artist-\(Self.stableID(name))", name: name, coverURL: nil, source: .synology)
        }
        let albums = (data["albums"] as? [[String: Any]] ?? []).compactMap { item -> Album? in
            guard let name = Self.stringValue(item["name"]), !name.isEmpty else { return nil }
            let artist = Self.stringValue(item["display_artist"]) ?? Self.stringValue(item["album_artist"]) ?? Self.stringValue(item["artist"]) ?? ""
            return Album(id: "synology-album-\(Self.stableID(name + artist))", name: name, artistName: artist, coverURL: nil, source: .synology, trackCount: nil)
        }
        return SynologySearchResult(songs: songs, artists: artists, albums: albums)
    }

    /// 同时尝试常见的简繁体/英文别名，再合并结果。
    func searchAllVariants(keyword: String, limit: Int = 50) async throws -> SynologySearchResult {
        restorePersistentLibraryIndexIfNeeded()
        if !librarySongsCache.isEmpty,
           Date().timeIntervalSince(librarySongsCacheUpdatedAt) >= librarySongsCacheTTL,
           librarySongsLoadingTask == nil {
            // 先用旧索引完成当前输入，再后台刷新，避免 TTL 到期造成搜索卡顿。
            Task { [weak self] in
                _ = try? await self?.librarySongs(forceRefresh: true)
            }
        }
        let variants = Self.searchVariants(for: keyword)
        if librarySongsCache.isEmpty {
            // 首次搜索先返回 Audio Station 结果，完整目录索引放到后台建立，避免首搜卡住界面。
            let remoteResult = await remoteSearchResult(variants: variants, limit: limit)
            if librarySongsLoadingTask == nil {
                Task { [weak self] in
                    _ = try? await self?.librarySongs()
                }
            }
            return remoteResult
        }

        // 先查本地索引：建立过索引后，普通搜索直接内存命中，避免每次输入都等待 NAS 网络请求。
        let localResult = (try? await librarySearchResult(keyword: keyword, limit: max(limit, 200)))
            ?? SynologySearchResult(songs: [], artists: [], albums: [])
        if !localResult.songs.isEmpty || !localResult.artists.isEmpty || !localResult.albums.isEmpty {
            return localResult
        }

        // 本地没有命中时再查远程简繁体变体；某个变体失败不会影响其它结果。
        return await remoteSearchResult(variants: variants, limit: limit)
    }

    private func remoteSearchResult(variants: [String], limit: Int) async -> SynologySearchResult {
        guard let primary = variants.first else {
            return SynologySearchResult(songs: [], artists: [], albums: [])
        }

        // 首次搜索先使用原始关键词；Audio Station 的搜索接口本身支持繁简体和标题匹配，
        // 不再为了等待所有变体而延迟首屏。只有原始关键词无结果时才尝试其它变体。
        if let result = try? await searchAll(keyword: primary, limit: limit),
           !result.songs.isEmpty || !result.artists.isEmpty || !result.albums.isEmpty {
            return result
        }

        var songs: [Song] = []
        var artists: [Artist] = []
        var albums: [Album] = []
        for variant in variants.dropFirst() {
            guard let result = try? await searchAll(keyword: variant, limit: limit) else { continue }
            songs.append(contentsOf: result.songs)
            artists.append(contentsOf: result.artists)
            albums.append(contentsOf: result.albums)
            if !songs.isEmpty || !artists.isEmpty || !albums.isEmpty { break }
        }
        return SynologySearchResult(
            songs: Self.uniqueSongs(songs),
            artists: Self.uniqueArtists(artists),
            albums: Self.uniqueAlbums(albums)
        )
    }

    private func librarySearchResult(keyword: String, limit: Int) async throws -> SynologySearchResult {
        // 搜索优先使用已落盘索引，不因为索引超过 10 分钟就阻塞当前结果；
        // 新索引由后续的库刷新流程更新，保证输入关键词时始终保持即时响应。
        restorePersistentLibraryIndexIfNeeded()
        let library = librarySongsCache
        let variants = Self.searchVariants(for: keyword).map(Self.normalizedSearchValue)
        guard !variants.isEmpty else { return SynologySearchResult(songs: [], artists: [], albums: []) }

        func matches(_ value: String) -> Bool {
            let normalized = Self.normalizedSearchValue(value)
            return variants.contains { query in
                !query.isEmpty && (normalized.contains(query) || query.contains(normalized))
            }
        }

        let matchedSongs = library.filter { song in
            matches(song.name) || matches(song.artists) || matches(song.album)
        }.sorted { lhs, rhs in
            let leftScore = SearchResultRelevance.score(keyword: keyword, primary: lhs.name, secondary: [lhs.artists, lhs.album])
            let rightScore = SearchResultRelevance.score(keyword: keyword, primary: rhs.name, secondary: [rhs.artists, rhs.album])
            if leftScore != rightScore { return leftScore < rightScore }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        // 歌手和专辑必须从完整命中集合生成，不能再用 limit * 3 截断，
        // 否则同一歌手后面的歌曲/专辑会永远不会出现在搜索结果里。
        let limitedSongs = matchedSongs
        var artists: [Artist] = []
        var seenArtists = Set<String>()
        for song in limitedSongs {
            for name in song.artists.components(separatedBy: " / ") where !name.isEmpty {
                guard seenArtists.insert(name.lowercased()).inserted else { continue }
                artists.append(Artist(
                    id: "synology-artist-\(Self.stableID(name))",
                    name: name,
                    coverURL: song.coverURL,
                    source: .synology
                ))
            }
        }

        var albums: [Album] = []
        var seenAlbums = Set<String>()
        for song in limitedSongs where !song.album.isEmpty {
            let key = "\(song.album)|\(song.artists)".lowercased()
            guard seenAlbums.insert(key).inserted else { continue }
            albums.append(Album(
                id: "synology-album-\(Self.stableID(key))",
                name: song.album,
                artistName: song.artists,
                coverURL: song.coverURL,
                source: .synology,
                trackCount: nil
            ))
        }
        return SynologySearchResult(
            songs: Array(limitedSongs.prefix(max(limit, 1))),
            artists: artists,
            albums: albums
        )
    }

    /// 获取 Audio Station 文件夹内容。根目录不传 id，子目录传入 folder id。
    func folderItems(folderID: String? = nil, offset: Int = 0, limit: Int = 100) async throws -> [SynologyFolderItem] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.AudioStation.Folder"),
            URLQueryItem(name: "version", value: "3"),
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "library", value: "all"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "sort_by", value: "title"),
            URLQueryItem(name: "sort_direction", value: "ASC"),
            URLQueryItem(name: "additional", value: "song_tag,song_audio")
        ]
        if let folderID, !folderID.isEmpty {
            query.append(URLQueryItem(name: "id", value: folderID))
        }

        let json = try await get("/webapi/AudioStation/folder.cgi", query: query, authenticated: true)
        guard let data = json["data"] as? [String: Any], let items = data["items"] as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let id = Self.stringValue(item["id"]), !id.isEmpty else { return nil }
            let title = Self.stringValue(item["title"]) ?? Self.stringValue(item["name"]) ?? "未命名"
            let type = Self.stringValue(item["type"])?.lowercased()
            if type == "folder" || type == "directory" {
                return SynologyFolderItem(id: id, name: title, kind: .folder, song: nil)
            }
            guard let song = self.parseSong(item) else { return nil }
            return SynologyFolderItem(id: id, name: title, kind: .song, song: song)
        }
    }

    /// 获取歌单列表 (SYNO.AudioStation.Playlist)
    func playlists(offset: Int = 0, limit: Int = 100) async throws -> [Playlist] {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.AudioStation.Playlist"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "library", value: "all")
        ]

        let json = try await get("/webapi/AudioStation/playlist.cgi", query: query, authenticated: true)
        guard let data = json["data"] as? [String: Any], let list = data["playlists"] as? [[String: Any]] else {
            return []
        }

        return list.compactMap { item -> Playlist? in
            guard let idStr = Self.stringValue(item["id"]), !idStr.isEmpty else { return nil }
            let name = Self.stringValue(item["name"]) ?? Self.stringValue(item["title"]) ?? "未命名歌单"
            let count = Self.intValue(item["song_count"])
                ?? Self.intValue(item["songCount"])
                ?? Self.intValue(item["trackCount"])
                ?? Self.intValue(item["count"])
                ?? 0
            return Playlist(
                id: Self.stableID(idStr),
                name: name,
                coverURL: nil,
                trackCount: count,
                source: .synology,
                synologyPlaylistId: idStr
            )
        }
    }

    /// 分页读取全部 NAS 歌单。Audio Station 的 list 接口一次只返回一页，
    /// 不能把首页数量误当成完整歌单列表。
    func allPlaylists(pageSize: Int = 100) async throws -> [Playlist] {
        let safePageSize = max(20, min(pageSize, 500))
        var result: [Playlist] = []
        var offset = 0
        while result.count < 20_000 {
            let page = try await playlists(offset: offset, limit: safePageSize)
            if page.isEmpty { break }
            result.append(contentsOf: page)
            offset += page.count
            if page.count < safePageSize { break }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.synologyPlaylistId ?? "\($0.id)").inserted }
    }

    /// 获取指定歌单内的歌曲
    func playlistSongs(playlistId: String, limit: Int = 500) async throws -> [Song] {
        let safePageSize = max(1, min(limit, 500))
        if limit < 500 {
            return try await playlistSongPage(playlistId: playlistId, offset: 0, limit: safePageSize)
        }

        var result: [Song] = []
        var offset = 0
        while result.count < 100_000 {
            let page = try await playlistSongPage(playlistId: playlistId, offset: offset, limit: safePageSize)
            if page.isEmpty { break }
            let previousCount = result.count
            result.append(contentsOf: page)
            result = Self.uniqueSongs(result)
            if result.count == previousCount || page.count < safePageSize { break }
            offset += page.count
        }
        return result
    }

    private func playlistSongPage(playlistId: String, offset: Int, limit: Int) async throws -> [Song] {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.AudioStation.Playlist"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "getinfo"),
            URLQueryItem(name: "id", value: playlistId),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "library", value: "all"),
            URLQueryItem(name: "additional", value: "songs_song_tag,songs_song_audio")
        ]

        let json = try await get("/webapi/AudioStation/playlist.cgi", query: query, authenticated: true)
        guard let data = json["data"] as? [String: Any],
              let playlistsArray = data["playlists"] as? [[String: Any]],
              let first = playlistsArray.first,
              let additional = first["additional"] as? [String: Any],
              let songsArray = additional["songs"] as? [[String: Any]] else {
            return []
        }

        return songsArray.compactMap { self.parseSong($0) }
    }

    /// 获取歌词 (SYNO.AudioStation.Lyrics)
    func lyrics(song: Song) async throws -> String? {
        guard accepts(song: song) else { return nil }
        guard let synoId = song.synologyId ?? (song.source == .synology ? "\(song.id)" : nil) else {
            return nil
        }
        let query: [URLQueryItem] = [
            URLQueryItem(name: "api", value: "SYNO.AudioStation.Lyrics"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "getlyrics"),
            URLQueryItem(name: "id", value: synoId)
        ]

        do {
            let json = try await get("/webapi/AudioStation/lyrics.cgi", query: query, authenticated: true)
            if let data = json["data"] as? [String: Any] {
                for key in ["lyrics", "lyric", "lrc", "content"] {
                    if let lyrics = data[key] as? String, !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return lyrics
                    }
                }
            }
        } catch {}
        return nil
    }

    // MARK: - 私有解析辅助

    private func parseSong(_ dict: [String: Any]) -> Song? {
        guard let synoId = dict["id"] as? String ?? (dict["id"] as? Int).map(String.init) else {
            return nil
        }

        let additional = dict["additional"] as? [String: Any]
        let tag = (additional?["song_tag"] as? [String: Any]) ?? (dict["song_tag"] as? [String: Any])
        let audio = (additional?["song_audio"] as? [String: Any]) ?? (dict["song_audio"] as? [String: Any])

        // `additional.song_tag` 是 Audio Station 从文件标签读取出的值；列表顶层字段
        // 可能仍是媒体索引的旧快照。标签刚刚写入后优先使用 song_tag，避免文件已经
        // 改好却在客户端看起来“完全没变化”。
        let rawTitle = Self.stringValue(tag?["title"])
            ?? Self.stringValue(dict["title"])
            ?? Self.stringValue(dict["name"])
            ?? ""
        let path = dict["path"] as? String ?? ""
        let filename = (path as NSString).lastPathComponent
        let cleanName = filename.replacingOccurrences(of: "\\.[^.]+$", with: "", options: .regularExpression)
        let name = rawTitle.isEmpty ? (cleanName.isEmpty ? "未知歌曲" : cleanName) : rawTitle

        let artist = (Self.stringValue(tag?["artist"]) ?? Self.stringValue(dict["artist"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let album = (Self.stringValue(tag?["album"]) ?? Self.stringValue(dict["album"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let duration = Self.doubleValue(audio?["duration"])
            ?? Self.doubleValue(dict["duration"])
            ?? 0

        let numericId = Self.stableID(synoId)
        let cover = coverURL(songId: synoId)

        return Song(
            id: numericId,
            name: name,
            artists: artist.isEmpty ? "未知艺术家" : artist,
            album: album.isEmpty ? "群晖 NAS" : album,
            coverURL: cover,
            duration: duration,
            source: .synology,
            synologyId: synoId,
            synologyServerScope: currentServerScope,
            synologyPath: path.isEmpty ? nil : path,
            albumArtist: Self.stringValue(tag?["album_artist"]),
            genre: Self.stringValue(tag?["genre"]),
            year: Self.stringValue(tag?["year"]),
            comment: Self.stringValue(tag?["comment"])
        )
    }

    // MARK: - NAS 元数据写回

    /// 并发从已接入的平台寻找当前 NAS 歌曲的候选信息，并按标题/歌手相似度排序。
    func metadataCandidates(for song: Song) async -> [SynologyMetadataCandidate] {
        let keyword = [song.name, song.artists].filter { !$0.isEmpty }.joined(separator: " ")
        async let netease = try? NetEaseAPI.shared.search(keyword: keyword, limit: 20)
        async let qq = try? QQMusicAPI.shared.searchSongs(keyword: keyword, limit: 20, offset: 0)
        async let kugou = try? KugouMusicAPI.shared.searchSongs(keyword: keyword, limit: 20)
        let results = await [("网易云音乐", netease ?? []), ("QQ音乐", qq ?? []), ("酷狗音乐", kugou ?? [])]

        let normalizedTitle = Self.metadataNormalized(song.name)
        let normalizedArtist = Self.metadataNormalized(song.artists)
        var seen = Set<String>()
        var candidates: [(SynologyMetadataCandidate, Int)] = []
        for (provider, songs) in results {
            for item in songs {
                let key = "\(provider)|\(Self.metadataNormalized(item.name))|\(Self.metadataNormalized(item.artists))|\(Self.metadataNormalized(item.album))"
                guard seen.insert(key).inserted else { continue }
                let title = Self.metadataNormalized(item.name)
                let artist = Self.metadataNormalized(item.artists)
                var score = 0
                if title == normalizedTitle { score += 100 }
                else if title.contains(normalizedTitle) || normalizedTitle.contains(title) { score += 45 }
                if artist == normalizedArtist { score += 70 }
                else if artist.contains(normalizedArtist) || normalizedArtist.contains(artist) { score += 30 }
                if item.duration > 0, song.duration > 0 {
                    let difference = abs(item.duration - song.duration)
                    if difference <= 2 { score += 25 }
                    else if difference <= 8 { score += 10 }
                }
                let candidate = SynologyMetadataCandidate(id: "\(provider)-\(item.identityKey)", song: item, providerName: provider)
                candidates.append((candidate, score))
            }
        }
        return candidates.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.song.name.localizedCaseInsensitiveCompare(rhs.0.song.name) == .orderedAscending
        }.map(\.0)
    }

    /// 从候选来源取得歌词；平台没有歌词时返回 nil，不影响标签写回。
    func onlineLyrics(for song: Song) async -> String? {
        switch song.source {
        case .netease:
            return try? await NetEaseAPI.shared.lyric(id: song.id)
        case .qq:
            guard let mid = song.qqMid else { return nil }
            return try? await QQMusicAPI.shared.lyric(songmid: mid)
        case .kugou:
            guard let hash = song.kugouHash else { return nil }
            let text = await KugouMusicAPI.shared.lyric(hash: hash, duration: song.duration)
            return text.isEmpty ? nil : text
        case .local:
            return nil
        case .synology:
            return nil
        }
    }

    /// 按字段差异写回 NAS 标签。
    ///
    /// Audio Station 的 tag_editor.cgi 并不是标准 WebAPI：它要求的 data 与网页版编辑器完全一致，
    /// 必须包含 audioInfos、完整标签和 coverType/coverPath。以前只传 patch 会被服务端判作无效数据，
    /// 尤其带封面时会等待后再失败。这里先载入原始标签并只覆盖用户实际修改的字段。
    func applyMetadata(song: Song, patch: SynologyTagPatch, coverURL: URL? = nil, coverData: Data? = nil, lyrics: String? = nil) async throws {
        guard accepts(song: song), let path = song.synologyPath, !path.isEmpty else {
            throw SynologyError.missingConfiguration("当前 NAS 歌曲没有可写入的原文件路径，请重新扫描音乐库")
        }
        // Audio Station 只会对这些容器实际写回音乐标签；对不支持的文件提前报错，
        // 不把服务端的空成功响应当成“已经保存”。
        let writableExtensions: Set<String> = ["mp3", "m4a", "m4b", "ogg", "flac", "aiff"]
        let fileExtension = (path as NSString).pathExtension.lowercased()
        guard writableExtensions.contains(fileExtension) else {
            let displayType = fileExtension.isEmpty ? "该文件" : fileExtension.uppercased()
            throw SynologyError.networkError("Audio Station 不支持写入 \(displayType) 的歌曲标签（仅支持 MP3、M4A、M4B、OGG、FLAC、AIFF）")
        }
        var coverType: String?
        var coverPath: String?
        if let coverData {
            coverType = "image_from_folder"
            coverPath = try await uploadCover(optimizedCoverData(coverData), for: path)
        } else if let coverURL {
            // 交给 NAS 直接获取在线封面，避免手机先下载原图、再上传一遍造成长时间卡住。
            coverType = "image_from_URL"
            coverPath = coverURL.absoluteString
        }

        let lyricsWasRequested = lyrics != nil
        let hasLyrics = lyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard !patch.isEmpty || coverPath != nil || lyricsWasRequested else { return }

        var previousCoverDigest: String?
        if coverPath != nil {
            previousCoverDigest = try? await coverDigest(song: song)
        }

        if !patch.isEmpty || coverPath != nil || lyricsWasRequested {
            var tag = try await tagEditorPayload(path: path, song: song, patch: patch, lyricsOverride: lyrics)
            if let coverType, let coverPath {
                tag["coverType"] = coverType
                tag["coverPath"] = coverPath
            }
            guard JSONSerialization.isValidJSONObject([tag]) else { throw SynologyError.decodingError }
            let payload = try JSONSerialization.data(withJSONObject: [tag], options: [])
            guard let payloadString = String(data: payload, encoding: .utf8) else { throw SynologyError.decodingError }
            let result = try await postForm("/webman/3rdparty/AudioStation/tagEditorUI/tag_editor.cgi", form: [
                "_sid": sid,
                "action": "apply",
                "data": payloadString
            ], authenticated: false, acceptsMissingSuccess: true)
            try validateTagEditorWrite(result)
            if !patch.isEmpty {
                try await verifyTagEditorWrite(path: path, patch: patch)
            }
            if coverPath != nil {
                try await verifyCoverWrite(song: song, previousDigest: previousCoverDigest)
            }
        }
        if let lyrics, lyricsWasRequested {
            // Audio Station 的歌词有独立 API。tag_editor.cgi 同时带 lyrics 可以兼容部分 DSM，
            // 这里再用官方 SYNO.AudioStation.Lyrics 写一次并回读，避免出现只在编辑器内存中变化。
            try await saveLyrics(song: song, lyrics: lyrics)
        }
        librarySongsCache.removeAll()
        librarySongsCacheUpdatedAt = .distantPast
        await MainActor.run {
            self.libraryIndexRevision &+= 1
        }
    }

    private struct TagEditorSnapshot {
        let file: [String: Any]
        let lyrics: String?
    }

    /// 读取网页端标签编辑器的原始状态。这里故意不用 Audio Station 的歌曲列表缓存，
    /// 因为后者会滞后于文件标签的实际写入。
    private func loadTagEditorSnapshot(path: String) async throws -> TagEditorSnapshot {
        // Audio Station 的 load 与 apply 参数不同：
        // load 直接接收 audioInfos=<JSON array>；只有 apply 才接收 data=<JSON array>。
        let loadRequest = try JSONSerialization.data(withJSONObject: [["path": path]])
        guard let loadData = String(data: loadRequest, encoding: .utf8) else { throw SynologyError.decodingError }
        let loaded = try await postForm("/webman/3rdparty/AudioStation/tagEditorUI/tag_editor.cgi", form: [
            "_sid": sid,
            "action": "load",
            "audioInfos": loadData
        ], authenticated: false, acceptsMissingSuccess: true)
        if let readFailCount = Self.intValue(loaded["read_fail_count"]), readFailCount > 0 {
            throw SynologyError.networkError("Audio Station 无法读取原歌曲标签，已停止写入以避免误报成功")
        }
        guard let file = (loaded["files"] as? [[String: Any]])?.first else {
            throw SynologyError.networkError("Audio Station 没有返回原歌曲标签，已停止写入")
        }
        return TagEditorSnapshot(file: file, lyrics: Self.stringValue(loaded["lyrics"]))
    }

    private func loadTagEditorFile(path: String) async throws -> [String: Any] {
        try await loadTagEditorSnapshot(path: path).file
    }

    private func tagEditorPayload(path: String, song: Song, patch: SynologyTagPatch, lyricsOverride: String? = nil) async throws -> [String: Any] {
        let snapshot = try await loadTagEditorSnapshot(path: path)
        let file = snapshot.file

        // 这是 Audio Station 网页端的真实协议：audioInfos 不只是路径，
        // 还要带上 load 返回的原始标签。DSM 某些版本即使只给 path 也会返回
        // success，但不会真正把外层字段写回音频文件。
        var audioInfo = file
        audioInfo["path"] = path
        var result: [String: Any] = [
            "audioInfos": [audioInfo],
            "title": Self.stringValue(file["title"]) ?? song.name,
            "artist": Self.stringValue(file["artist"]) ?? song.artists,
            "album": Self.stringValue(file["album"]) ?? song.album,
            "comment": Self.stringValue(file["comment"]) ?? song.comment ?? "",
            "genre": Self.stringValue(file["genre"]) ?? song.genre ?? "",
            "track": Self.stringValue(file["track"]) ?? "",
            "disc": Self.stringValue(file["disc"]) ?? "",
            "year": Self.stringValue(file["year"]) ?? song.year ?? "",
            "album_artist": Self.stringValue(file["album_artist"]) ?? song.albumArtist ?? "",
            "composer": Self.stringValue(file["composer"]) ?? "",
            "codePage": "SYNO_NO_CODE_PAGE_CONVERT",
            "coverType": "original_image",
            "coverPath": ""
        ]
        // 网页编辑器每次保存都会连同现有歌词一并提交。保留 load 返回的原值，
        // 既贴合协议，也避免仅编辑标签时意外丢失歌词。
        if let lyrics = lyricsOverride, !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result["lyrics"] = lyrics
        } else if let lyrics = snapshot.lyrics {
            result["lyrics"] = lyrics
        }
        if let value = patch.title { result["title"] = value }
        if let value = patch.artist { result["artist"] = value }
        if let value = patch.album { result["album"] = value }
        if let value = patch.albumArtist { result["album_artist"] = value }
        if let value = patch.genre { result["genre"] = value }
        if let value = patch.year { result["year"] = value }
        if let value = patch.comment { result["comment"] = value }
        return result
    }

    private func validateTagEditorWrite(_ result: [String: Any]) throws {
        if let failures = result["write_fail_files"] as? [[String: Any]], let failure = failures.first {
            let reason = Self.stringValue(failure["error_reason"]) ?? "unknown"
            throw SynologyError.networkError(Self.tagEditorFailureMessage(reason))
        }
        if let failures = result["write_fail_files"] as? [String], let failure = failures.first {
            throw SynologyError.networkError("Audio Station 未能写入文件（\(failure)）")
        }
        if let readFailCount = Self.intValue(result["read_fail_count"]), readFailCount > 0 {
            throw SynologyError.networkError("Audio Station 报告标签读取失败，未确认写入成功")
        }
        if result["success"] as? Bool == false {
            throw SynologyError.networkError("Audio Station 未确认写入成功")
        }
        let hasReturnedFile = (result["files"] as? [[String: Any]])?.isEmpty == false
        guard result["success"] as? Bool == true || hasReturnedFile else {
            throw SynologyError.networkError("Audio Station 返回结果不完整，未确认标签已写入")
        }
    }

    private static func tagEditorFailureMessage(_ reason: String) -> String {
        switch reason {
        case "error_noprivilege": return "当前 NAS 账号没有修改该音乐文件的权限"
        case "error_fs_ro": return "音乐文件所在磁盘为只读状态"
        case "error_file_not_exist": return "原音乐文件已移动或不存在"
        default: return "Audio Station 未能写入文件（\(reason)）"
        }
    }

    /// apply 返回成功仍不能直接提示用户成功：重新 load 一次，确认用户修改的字段真的落到了文件标签中。
    /// 少数 NAS 写标签后索引有极短延迟，因此做两次轻量重试。
    private func verifyTagEditorWrite(path: String, patch: SynologyTagPatch, lyrics: String? = nil) async throws {
        let expected: [(String, String, String?)] = [
            ("歌曲标题", "title", patch.title),
            ("演出者", "artist", patch.artist),
            ("专辑名称", "album", patch.album),
            ("专辑演出者", "album_artist", patch.albumArtist),
            ("流派", "genre", patch.genre),
            ("专辑年份", "year", patch.year),
            ("备注", "comment", patch.comment)
        ]
        let checks = expected.compactMap { item -> (String, String, String)? in
            guard let value = item.2 else { return nil }
            return (item.0, item.1, value)
        }
        guard !checks.isEmpty || (lyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) else { return }

        var lastMismatch = checks.map { $0.0 }
        for delay in [UInt64(0), 300_000_000, 900_000_000] {
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            let snapshot = try await loadTagEditorSnapshot(path: path)
            let file = snapshot.file
            let mismatches = checks.compactMap { label, key, expectedValue -> String? in
                let actual = Self.stringValue(file[key]) ?? ""
                return actual == expectedValue ? nil : label
            }
            var allMismatches = mismatches
            if let expectedLyrics = lyrics, !expectedLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let actualLyrics = snapshot.lyrics ?? ""
                if normalizedLyrics(actualLyrics) != normalizedLyrics(expectedLyrics) {
                    allMismatches.append("歌词")
                }
            }
            if allMismatches.isEmpty { return }
            lastMismatch = allMismatches
        }
        throw SynologyError.networkError("NAS 返回成功，但回读标签仍未变化：\(lastMismatch.joined(separator: "、"))")
    }

    /// 封面接口可能命中 NAS 的缓存，因此每次回读都加一个只用于校验的随机参数。
    /// 只要回读到的图片摘要与保存前不同，才向用户报告封面已写入。
    private func verifyCoverWrite(song: Song, previousDigest: String?) async throws {
        var lastDigest: String?
        for delay in [UInt64(0), 400_000_000, 1_000_000_000] {
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            if let digest = try? await coverDigest(song: song) {
                lastDigest = digest
                if previousDigest == nil || digest != previousDigest {
                    return
                }
            }
        }
        if lastDigest == nil {
            throw SynologyError.networkError("NAS 返回成功，但无法回读封面确认写入结果")
        }
        throw SynologyError.networkError("NAS 返回成功，但回读封面仍未变化，请确认账号有音乐标签写入权限")
    }

    private func coverDigest(song: Song) async throws -> String? {
        guard let songID = song.synologyId ?? (song.source == .synology ? "\(song.id)" : nil),
              var components = URLComponents(string: baseURL + "/webapi/AudioStation/cover.cgi") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.AudioStation.Cover"),
            URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "method", value: "getsongcover"),
            URLQueryItem(name: "library", value: "all"),
            URLQueryItem(name: "id", value: songID),
            URLQueryItem(name: "_sid", value: sid),
            URLQueryItem(name: "_atmusic_verify", value: UUID().uuidString)
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("ATMusic/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func normalizedLyrics(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Audio Station 的歌词接口在不同 DSM 版本中接受 lyrics/content 两种字段，按顺序兼容尝试。
    func saveLyrics(song: Song, lyrics: String) async throws {
        guard accepts(song: song), let synoId = song.synologyId ?? (song.source == .synology ? "\(song.id)" : nil) else {
            throw SynologyError.missingConfiguration("当前歌曲不是可写入的 NAS 歌曲")
        }
        var lastError: Error = SynologyError.networkError("歌词写入失败")
        for key in ["lyrics", "content"] {
            do {
                _ = try await postForm("/webapi/AudioStation/lyrics.cgi", form: [
                    "api": "SYNO.AudioStation.Lyrics",
                    "version": "2",
                    "method": "setlyrics",
                    "library": "all",
                    "id": synoId,
                    key: lyrics
                ], authenticated: true)
                for delay in [UInt64(0), 300_000_000, 900_000_000] {
                    if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                    if let saved = try? await self.lyrics(song: song),
                       normalizedLyrics(saved) == normalizedLyrics(lyrics) {
                        return
                    }
                }
                lastError = SynologyError.networkError("NAS 返回成功，但回读歌词仍未变化")
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func uploadCover(_ data: Data, for path: String) async throws -> String {
        guard !sid.isEmpty else { throw SynologyError.unauthenticated }
        let folder = (path as NSString).deletingLastPathComponent
        let filename = ".atmusic-cover-\(Self.stableID(path)).jpg"
        let boundary = "ATMusic-\(UUID().uuidString)"
        var components = URLComponents(string: baseURL + "/webapi/entry.cgi")
        components?.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.Upload"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "upload"),
            URLQueryItem(name: "path", value: folder),
            URLQueryItem(name: "create_parents", value: "false"),
            URLQueryItem(name: "overwrite", value: "true"),
            URLQueryItem(name: "_sid", value: sid)
        ]
        guard let url = components?.url else { throw SynologyError.invalidURL("封面上传地址无效") }
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("ATMusic/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (responseData, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              (json["success"] as? Bool ?? false) else {
            throw SynologyError.apiError(-1, "NAS 没有允许上传封面，请检查 File Station 权限")
        }
        return folder + "/" + filename
    }

    /// 将本机选图限制到合理尺寸再上传。原图（常见为数 MB 的 HEIC/JPEG）不再阻塞 NAS 写入。
    private func optimizedCoverData(_ data: Data) -> Data {
        guard let image = UIImage(data: data) else { return data }
        let maxSide: CGFloat = 1_600
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide else { return image.jpegData(compressionQuality: 0.86) ?? data }
        let scale = maxSide / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.86) ?? data
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func searchVariants(for keyword: String) -> [String] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        var variants = [trimmed]
        let converted = simplifiedVariant(trimmed)
        if converted != trimmed { variants.append(converted) }
        if let traditional = trimmed.applyingTransform(StringTransform("Hans-Hant"), reverse: false), traditional != trimmed {
            variants.append(traditional)
        }
        return Array(NSOrderedSet(array: variants)) as? [String] ?? variants
    }

    private static func simplifiedVariant(_ value: String) -> String {
        let table: [Character: Character] = [
            "倫": "伦", "華": "华", "樂": "乐", "臺": "台", "灣": "湾", "國": "国", "龍": "龙",
            "劉": "刘", "張": "张", "陳": "陈", "黃": "黄", "楊": "杨", "趙": "赵", "吳": "吴",
            "學": "学", "電": "电", "風": "风", "愛": "爱", "萬": "万", "東": "东", "後": "后",
            "來": "来", "與": "与", "這": "这", "們": "们", "見": "见", "說": "说", "聽": "听",
            "時": "时", "會": "会", "點": "点", "兒": "儿", "雲": "云", "蘇": "苏", "鄧": "邓",
            "偉": "伟", "傑": "杰", "葉": "叶", "鄭": "郑", "錢": "钱", "鍾": "钟", "劍": "剑"
        ]
        let mapped = String(value.map { table[$0] ?? $0 })
        return mapped.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? mapped
    }

    private static func normalizedSearchValue(_ value: String) -> String {
        let simplified = simplifiedVariant(value)
        return simplified
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func uniqueSongs(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.identityKey).inserted }
    }

    private static func uniqueArtists(_ artists: [Artist]) -> [Artist] {
        var seen = Set<String>()
        return artists.filter { seen.insert($0.name.lowercased()).inserted }
    }

    private static func uniqueAlbums(_ albums: [Album]) -> [Album] {
        var seen = Set<String>()
        return albums.filter { seen.insert(($0.name + "|" + $0.artistName).lowercased()).inserted }
    }

    /// String.hashValue 会在每次进程启动时变化，不能作为持久化歌单/歌曲 ID。
    private static func stableID(_ value: String) -> Int {
        if let number = Int(value), number != Int.min {
            return number == 0 ? 1 : abs(number)
        }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash & 0x7fff_ffff_ffff_ffff) == 0 ? 1 : Int(hash & 0x7fff_ffff_ffff_ffff)
    }

    // MARK: - 网络底层

    private func get(_ path: String, query: [URLQueryItem], authenticated: Bool = true) async throws -> [String: Any] {
        let generation = configurationGeneration
        guard let urlBase = URL(string: baseURL + path) else {
            throw SynologyError.invalidURL("无效的请求地址: \(baseURL + path)")
        }

        var components = URLComponents(url: urlBase, resolvingAgainstBaseURL: false)
        var items = query
        if authenticated {
            if sid.isEmpty { throw SynologyError.unauthenticated }
            items.append(URLQueryItem(name: "_sid", value: sid))
        }
        components?.queryItems = items

        guard let finalURL = components?.url else {
            throw SynologyError.invalidURL("构造 URL 失败")
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        request.setValue("ATMusic/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard generation == configurationGeneration else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else {
            throw SynologyError.networkError("未能建立 HTTP 连接")
        }

        guard http.statusCode == 200 else {
            throw SynologyError.httpStatus(http.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SynologyError.decodingError
        }

        let success = json["success"] as? Bool ?? false
        if !success {
            let errorDict = json["error"] as? [String: Any]
            let code = errorDict?["code"] as? Int ?? -1
            if code == 105 || code == 106 || code == 119 {
                // Session 过期
                await MainActor.run { self.isLoggedIn = false }
                throw SynologyError.sessionExpired
            }
            throw SynologyError.apiError(code, Self.describeErrorCode(code))
        }

        return json
    }

    private func postForm(_ path: String, form: [String: String], authenticated: Bool, acceptsMissingSuccess: Bool = false) async throws -> [String: Any] {
        let generation = configurationGeneration
        guard let url = URL(string: baseURL + path) else { throw SynologyError.invalidURL("无效的请求地址") }
        var values = form
        if authenticated {
            guard !sid.isEmpty else { throw SynologyError.unauthenticated }
            values["_sid"] = sid
        }
        let body = values.map { "\(Self.formEscape($0.key))=\(Self.formEscape($0.value))" }.joined(separator: "&")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("ATMusic/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard generation == configurationGeneration else { throw CancellationError() }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SynologyError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SynologyError.decodingError }
        if let success = json["success"] as? Bool, !success {
            let code = (json["error"] as? [String: Any])?["code"] as? Int ?? -1
            throw SynologyError.apiError(code, Self.describeErrorCode(code))
        }
        if !acceptsMissingSuccess && json["success"] == nil {
            throw SynologyError.decodingError
        }
        return json
    }

    private static func formEscape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._* ")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: " ", with: "+") ?? value
    }

    private static func metadataNormalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[\\(\\)\\[\\]\\-_/·•]", with: "", options: .regularExpression)
            .lowercased()
    }

    private static func describeErrorCode(_ code: Int) -> String {
        switch code {
        case 100: return "未知错误"
        case 101: return "无效参数"
        case 102: return "该 API 服务不存在"
        case 103: return "该方法不存在"
        case 104: return "API 版本不支持"
        case 105: return "登录权限失效或会话已过期"
        case 106: return "会话中断，请重新登录"
        case 400: return "用户名或密码错误"
        case 401: return "账户已被禁用"
        case 402: return "无权限访问该服务"
        case 403: return "需要两步验证 (OTP) 验证码"
        case 404: return "两步验证失败"
        default: return "错误代码 (\(code))"
        }
    }
}

enum SynologyError: LocalizedError {
    case missingConfiguration(String)
    case invalidURL(String)
    case networkError(String)
    case httpStatus(Int)
    case decodingError
    case loginFailed(String)
    case unauthenticated
    case sessionExpired
    case apiError(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let msg): return msg
        case .invalidURL(let msg): return msg
        case .networkError(let msg): return msg
        case .httpStatus(let code): return "群晖服务器响应错误 HTTP \(code)"
        case .decodingError: return "解析群晖数据失败"
        case .loginFailed(let msg): return msg
        case .unauthenticated: return "尚未登录群晖 NAS"
        case .sessionExpired: return "群晖登录已过期，请重新登录"
        case .apiError(_, let msg): return "群晖服务错误: \(msg)"
        }
    }
}
