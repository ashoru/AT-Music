import Foundation

/// 聚合搜索的单个平台结果。每个平台独立失败，避免一个音源超时拖住全部结果。
struct AggregatedSearchResult {
    var songs: [Song] = []
    var artists: [Artist] = []
    var albums: [Album] = []
    var playlists: [Playlist] = []
    var succeededProviders: Set<SearchProvider> = []
    var failedProviders: [SearchProvider] = []
}

/// 聚合搜索的相关性评分。
/// 分数越小越靠前：完全匹配 > 前缀匹配 > 包含匹配 > 弱匹配。
/// 搜索字段优先级为主名称（歌名/歌手/专辑名）高于副信息（歌手/专辑）。
enum SearchResultRelevance {
    static func score(keyword: String, primary: String, secondary: [String] = []) -> Int {
        let query = normalize(keyword)
        guard !query.isEmpty else { return 10_000 }

        var best = matchScore(query: query, value: primary, base: 0)
        for value in secondary {
            best = min(best, matchScore(query: query, value: value, base: 20))
        }
        return best
    }

    private static func matchScore(query: String, value: String, base: Int) -> Int {
        let normalizedValue = normalize(value)
        guard !normalizedValue.isEmpty else { return 10_000 }
        if normalizedValue == query { return base }
        if normalizedValue.hasPrefix(query) {
            return base + 100 + min(normalizedValue.count - query.count, 80)
        }
        if let range = normalizedValue.range(of: query) {
            let offset = normalizedValue.distance(from: normalizedValue.startIndex, to: range.lowerBound)
            return base + 300 + min(offset, 80) + min(normalizedValue.count - query.count, 80)
        }
        return 10_000
    }

    static func normalize(_ value: String) -> String {
        SongIdentityNormalizer.toSimplified(value)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct AggregatedSearchPartial {
    let provider: SearchProvider
    let songs: [Song]
    let artists: [Artist]
    let albums: [Album]
    let playlists: [Playlist]
    let succeeded: Bool
}

/// 搜索页使用的并发聚合层。它不改变原有单平台搜索，只在用户主动选择“聚合”时启用。
final class AggregatedSearchService: @unchecked Sendable {
    static let shared = AggregatedSearchService()
    private init() {}

    func search(keyword: String, providers: [SearchProvider], limit: Int = 40) async -> AggregatedSearchResult {
        let partials = await collectPartials(keyword: keyword, providers: providers, limit: limit)
        return Self.makeResult(partials: partials, keyword: keyword)
    }

    /// 流式聚合搜索：每个平台回包都会产生一份按匹配度重排的最新集合。
    /// 搜索页会按所在视图决定展示策略：分类页实时消费，综合页只采纳首屏与最终结果。
    func searchStreaming(
        keyword: String,
        providers: [SearchProvider],
        limit: Int = 40,
        onUpdate: @escaping @Sendable (AggregatedSearchResult) async -> Void
    ) async -> AggregatedSearchResult {
        let partials = await withTaskGroup(of: AggregatedSearchPartial.self, returning: [AggregatedSearchPartial].self) { group in
            for provider in providers {
                group.addTask { await Self.searchProvider(provider, keyword: keyword, limit: limit) }
            }
            var values: [AggregatedSearchPartial] = []
            for await partial in group {
                values.append(partial)
                await onUpdate(Self.makeResult(partials: values, keyword: keyword))
            }
            return values
        }
        return Self.makeResult(partials: partials, keyword: keyword)
    }

    private func collectPartials(keyword: String, providers: [SearchProvider], limit: Int) async -> [AggregatedSearchPartial] {
        await withTaskGroup(of: AggregatedSearchPartial.self, returning: [AggregatedSearchPartial].self) { group in
            for provider in providers {
                group.addTask { await Self.searchProvider(provider, keyword: keyword, limit: limit) }
            }
            var values: [AggregatedSearchPartial] = []
            for await partial in group { values.append(partial) }
            return values
        }
    }

    private static func makeResult(partials: [AggregatedSearchPartial], keyword: String) -> AggregatedSearchResult {
        var result = AggregatedSearchResult()
        for partial in partials {
            if partial.succeeded { result.succeededProviders.insert(partial.provider) }
            else { result.failedProviders.append(partial.provider) }
        }

        // 不再按平台拼接。先按相关性评分，再用各平台接口返回的原始名次作为稳定的次排序，
        // 这样完全匹配的结果会跨平台交错显示，而不会被某一个平台整组占据顶部。
        result.songs = Self.uniqueSongs(Self.rankSongs(
            partials.flatMap { partial in
                partial.songs.enumerated().map { (song: $0.element, backendRank: $0.offset) }
            }, keyword: keyword
        ))
        result.artists = Self.uniqueArtists(Self.rankArtists(
            partials.flatMap { partial in
                partial.artists.enumerated().map { (artist: $0.element, backendRank: $0.offset) }
            }, keyword: keyword
        ))
        result.albums = Self.uniqueAlbums(Self.rankAlbums(
            partials.flatMap { partial in
                partial.albums.enumerated().map { (album: $0.element, backendRank: $0.offset) }
            }, keyword: keyword
        ))
        result.playlists = Self.uniquePlaylists(Self.rankPlaylists(
            partials.flatMap { partial in
                partial.playlists.enumerated().map { (playlist: $0.element, backendRank: $0.offset) }
            }, keyword: keyword
        ))
        return result
    }

    private static func rankSongs(_ candidates: [(song: Song, backendRank: Int)], keyword: String) -> [Song] {
        candidates.sorted {
            let lhs = SearchResultRelevance.score(keyword: keyword, primary: $0.song.name, secondary: [$0.song.artists, $0.song.album])
            let rhs = SearchResultRelevance.score(keyword: keyword, primary: $1.song.name, secondary: [$1.song.artists, $1.song.album])
            return relevanceOrder(lhs: lhs, rhs: rhs, leftRank: $0.backendRank, rightRank: $1.backendRank, leftName: $0.song.name, rightName: $1.song.name)
        }.map(\.song)
    }

    private static func rankArtists(_ candidates: [(artist: Artist, backendRank: Int)], keyword: String) -> [Artist] {
        candidates.sorted {
            let lhs = SearchResultRelevance.score(keyword: keyword, primary: $0.artist.name)
            let rhs = SearchResultRelevance.score(keyword: keyword, primary: $1.artist.name)
            return relevanceOrder(lhs: lhs, rhs: rhs, leftRank: $0.backendRank, rightRank: $1.backendRank, leftName: $0.artist.name, rightName: $1.artist.name)
        }.map(\.artist)
    }

    private static func rankAlbums(_ candidates: [(album: Album, backendRank: Int)], keyword: String) -> [Album] {
        candidates.sorted {
            let lhs = SearchResultRelevance.score(keyword: keyword, primary: $0.album.name, secondary: [$0.album.artistName])
            let rhs = SearchResultRelevance.score(keyword: keyword, primary: $1.album.name, secondary: [$1.album.artistName])
            return relevanceOrder(lhs: lhs, rhs: rhs, leftRank: $0.backendRank, rightRank: $1.backendRank, leftName: $0.album.name, rightName: $1.album.name)
        }.map(\.album)
    }

    private static func rankPlaylists(_ candidates: [(playlist: Playlist, backendRank: Int)], keyword: String) -> [Playlist] {
        candidates.sorted {
            let lhs = SearchResultRelevance.score(keyword: keyword, primary: $0.playlist.name, secondary: [$0.playlist.creatorName])
            let rhs = SearchResultRelevance.score(keyword: keyword, primary: $1.playlist.name, secondary: [$1.playlist.creatorName])
            if lhs != rhs { return lhs < rhs }
            let leftPopularity = $0.playlist.popularity ?? 0
            let rightPopularity = $1.playlist.popularity ?? 0
            if leftPopularity != rightPopularity { return leftPopularity > rightPopularity }
            if $0.playlist.trackCount != $1.playlist.trackCount {
                return $0.playlist.trackCount > $1.playlist.trackCount
            }
            return relevanceOrder(lhs: lhs, rhs: rhs, leftRank: $0.backendRank, rightRank: $1.backendRank, leftName: $0.playlist.name, rightName: $1.playlist.name)
        }.map(\.playlist)
    }

    private static func relevanceOrder(lhs: Int, rhs: Int, leftRank: Int, rightRank: Int, leftName: String, rightName: String) -> Bool {
        if lhs != rhs { return lhs < rhs }
        if leftRank != rightRank { return leftRank < rightRank }
        return SearchResultRelevance.normalize(leftName) < SearchResultRelevance.normalize(rightName)
    }

    private static func searchProvider(_ provider: SearchProvider, keyword: String, limit: Int) async -> AggregatedSearchPartial {
        switch provider {
        case .netease:
            async let songs = safe { try await NetEaseAPI.shared.search(keyword: keyword, limit: limit) }
            async let artists = safe { try await NetEaseAPI.shared.searchArtists(keyword: keyword, limit: limit) }
            async let albums = safe { try await NetEaseAPI.shared.searchAlbums(keyword: keyword, limit: limit) }
            async let playlists = safe { try await NetEaseAPI.shared.searchPlaylists(keyword: keyword, limit: limit) }
            let values = await (songs, artists, albums, playlists)
            return AggregatedSearchPartial(provider: provider, songs: values.0 ?? [], artists: values.1 ?? [], albums: values.2 ?? [], playlists: values.3 ?? [], succeeded: values.0 != nil || values.1 != nil || values.2 != nil || values.3 != nil)
        case .qq:
            async let songs = safe { try await QQMusicAPI.shared.searchSongs(keyword: keyword) }
            async let artists = safe { try await QQMusicAPI.shared.searchArtists(keyword: keyword, limit: limit) }
            async let albums = safe { try await QQMusicAPI.shared.searchAlbums(keyword: keyword, limit: limit) }
            async let playlists = safe { try await QQMusicAPI.shared.searchPlaylists(keyword: keyword, limit: limit) }
            let values = await (songs, artists, albums, playlists)
            return AggregatedSearchPartial(provider: provider, songs: values.0 ?? [], artists: values.1 ?? [], albums: values.2 ?? [], playlists: values.3 ?? [], succeeded: values.0 != nil || values.1 != nil || values.2 != nil || values.3 != nil)
        case .kugou:
            async let songs = safe { try await KugouMusicAPI.shared.searchSongs(keyword: keyword, limit: limit) }
            async let artists = safe { try await KugouMusicAPI.shared.searchArtists(keyword: keyword, limit: limit) }
            async let albums = safe { try await KugouMusicAPI.shared.searchAlbums(keyword: keyword, limit: limit) }
            async let playlists = safe { try await KugouMusicAPI.shared.searchPlaylists(keyword: keyword, limit: limit) }
            let values = await (songs, artists, albums, playlists)
            return AggregatedSearchPartial(provider: provider, songs: values.0 ?? [], artists: values.1 ?? [], albums: values.2 ?? [], playlists: values.3 ?? [], succeeded: values.0 != nil || values.1 != nil || values.2 != nil || values.3 != nil)
        case .synology:
            // NAS 本地索引完成后返回完整命中集合；远程首屏也适当放大，
            // 避免目标歌曲恰好落在前 40 条之外。
            async let index = safe { try await SynologyAPI.shared.searchAllVariants(keyword: keyword, limit: max(limit, 200)) }
            async let allPlaylists = safe { try await SynologyAPI.shared.allPlaylists() }
            let value = await index
            let playlists = (await allPlaylists)?.filter {
                $0.name.localizedCaseInsensitiveContains(keyword)
            } ?? []
            return AggregatedSearchPartial(provider: provider, songs: value?.songs ?? [], artists: value?.artists ?? [], albums: value?.albums ?? [], playlists: playlists, succeeded: value != nil || !playlists.isEmpty)
        }
    }

    /// 上游接口偶尔会保持连接但永不返回。单个分类超时不能让整个聚合搜索
    /// 的加载指示器永久转动；其他平台结果仍可正常完成。
    private static func safe<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async -> Value? {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask { try? await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            }
            let value = await group.next() ?? nil
            group.cancelAll()
            return value
        }
    }

    private static func uniqueSongs(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.identityKey).inserted }
    }

    private static func uniqueArtists(_ artists: [Artist]) -> [Artist] {
        var seen = Set<String>()
        return artists.filter {
            let key = "\($0.source.rawValue)|\(SongIdentityNormalizer.toSimplified($0.name).lowercased())"
            return seen.insert(key).inserted
        }
    }

    private static func uniqueAlbums(_ albums: [Album]) -> [Album] {
        var seen = Set<String>()
        return albums.filter {
            let key = "\($0.source.rawValue)|\(SongIdentityNormalizer.toSimplified($0.name).lowercased())|\(SongIdentityNormalizer.toSimplified($0.artistName).lowercased())"
            return seen.insert(key).inserted
        }
    }

    private static func uniquePlaylists(_ playlists: [Playlist]) -> [Playlist] {
        var seen = Set<String>()
        return playlists.filter {
            let key = "\($0.source.rawValue)|\(SearchResultRelevance.normalize($0.name))"
            return seen.insert(key).inserted
        }
    }
}
