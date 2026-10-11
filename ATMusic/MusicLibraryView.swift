import SwiftUI


@MainActor
final class PlaylistActivityStore: ObservableObject {
    static let shared = PlaylistActivityStore()

    @Published private(set) var activity: [String: TimeInterval]
    private let defaults = UserDefaults.standard
    private let key = "atmusic.musicLibrary.playlistActivity.v1"

    private init() {
        activity = defaults.dictionary(forKey: key) as? [String: TimeInterval] ?? [:]
    }

    func mark(_ playlistID: String, at date: Date = Date()) {
        activity[playlistID] = date.timeIntervalSince1970
        defaults.set(activity, forKey: key)
    }

    func timestamp(for playlistID: String) -> TimeInterval {
        activity[playlistID] ?? 0
    }
}

@MainActor
final class MusicLibraryPlaylistStore: ObservableObject {
    static let shared = MusicLibraryPlaylistStore()

    @Published private(set) var netease: [Playlist] = []
    @Published private(set) var qq: [Playlist] = []
    @Published private(set) var kugou: [Playlist] = []
    @Published private(set) var synology: [Playlist] = []
    @Published private(set) var isLoading = false

    private init() {}

    func load(auth: AuthStore, force: Bool = false) async {
        if !force {
            hydrateCachedPlaylists(auth: auth)
        }
        isLoading = netease.isEmpty && qq.isEmpty && kugou.isEmpty && synology.isEmpty

        // 真正的渐进并发：每个平台完成后立刻更新对应区域，
        // 不再等最慢的平台结束才一次性提交整个“我的歌单”。
        let neteaseTask = Task { @MainActor in
            let value = await fetchNetease(auth: auth, force: force)
            netease = SyncedPlaylistOrderStore.shared.ordered(value, source: .netease)
        }
        let qqTask = Task { @MainActor in
            let value = await fetchQQ(force: force)
            qq = SyncedPlaylistOrderStore.shared.ordered(value, source: .qq)
        }
        let kugouTask = Task { @MainActor in
            let value = await fetchKugou(force: force)
            kugou = SyncedPlaylistOrderStore.shared.ordered(value, source: .kugou)
        }
        let synologyTask = Task { @MainActor in
            synology = await fetchSynology(force: force)
        }

        _ = await neteaseTask.value
        _ = await qqTask.value
        _ = await kugouTask.value
        _ = await synologyTask.value
        isLoading = false
    }

    private func hydrateCachedPlaylists(auth: AuthStore) {
        if !auth.playlists.isEmpty {
            netease = SyncedPlaylistOrderStore.shared.ordered(auth.playlists, source: .netease)
        }

        let qqAuth = QQMusicAuth.shared
        let qqAccountID = qqAuth.rawUin.isEmpty ? qqAuth.playlistUin : qqAuth.rawUin
        if qqAuth.isLoggedIn,
           let cached = SyncedPlaylistCache.shared.cachedPlaylists(source: .qq, accountID: qqAccountID) {
            qq = SyncedPlaylistOrderStore.shared.ordered(cached.playlists, source: .qq)
        }

        let kugouAuth = KugouMusicAuth.shared
        if kugouAuth.isLoggedIn,
           let cached = SyncedPlaylistCache.shared.cachedPlaylists(source: .kugou, accountID: kugouAuth.userId) {
            kugou = SyncedPlaylistOrderStore.shared.ordered(cached.playlists, source: .kugou)
        }

        let api = SynologyAPI.shared
        let accountID = api.account.isEmpty ? "synology" : api.account
        if api.isLoggedIn,
           let cached = SyncedPlaylistCache.shared.cachedPlaylists(source: .synology, accountID: accountID) {
            synology = cached.playlists
        }
    }

    private func fetchNetease(auth: AuthStore, force: Bool) async -> [Playlist] {
        await auth.loadLibrary(force: force)
        return auth.playlists
    }

    private func fetchQQ(force: Bool) async -> [Playlist] {
        let auth = QQMusicAuth.shared
        guard auth.isLoggedIn else { return [] }
        let accountID = auth.rawUin.isEmpty ? auth.playlistUin : auth.rawUin
        let cache = SyncedPlaylistCache.shared
        var fallback: [Playlist] = []
        if let cached = cache.cachedPlaylists(source: .qq, accountID: accountID) {
            fallback = cached.playlists
            if !force, cache.isFresh(cached) { return cached.playlists }
        }
        let remote = (try? await QQMusicAPI.shared.userPlaylists(uin: auth.uin)) ?? []
        if !remote.isEmpty {
            cache.savePlaylists(remote, source: .qq, accountID: accountID)
            return remote
        }
        return fallback
    }

    private func fetchKugou(force: Bool) async -> [Playlist] {
        let auth = KugouMusicAuth.shared
        guard auth.isLoggedIn else { return [] }
        let cache = SyncedPlaylistCache.shared
        let accountID = auth.userId
        var fallback: [Playlist] = []
        if let cached = cache.cachedPlaylists(source: .kugou, accountID: accountID) {
            fallback = cached.playlists
            if !force, cache.isFresh(cached) { return cached.playlists }
        }
        let remote = (try? await KugouMusicAPI.shared.userPlaylists()) ?? []
        if !remote.isEmpty {
            cache.savePlaylists(remote, source: .kugou, accountID: accountID)
            return remote
        }
        return fallback
    }

    private func fetchSynology(force: Bool) async -> [Playlist] {
        let api = SynologyAPI.shared
        guard api.isLoggedIn else { return [] }
        let accountID = api.account.isEmpty ? "synology" : api.account
        let cache = SyncedPlaylistCache.shared
        var fallback: [Playlist] = []
        if let cached = cache.cachedPlaylists(source: .synology, accountID: accountID) {
            fallback = cached.playlists
            if !force, cache.isFresh(cached) { return cached.playlists }
        }
        let remote = (try? await api.allPlaylists()) ?? []
        if !remote.isEmpty {
            cache.savePlaylists(remote, source: .synology, accountID: accountID)
            return remote
        }
        return fallback
    }
}

private struct MusicLibraryPlaylistItem: Identifiable {
    enum Kind {
        case remote(Playlist)
        case local(UUID)
    }

    let id: String
    let title: String
    let subtitle: String
    let coverURL: URL?
    let source: SongSource
    let kind: Kind
    var fallbackActivity: TimeInterval = 0

    var semanticPriority: Int {
        switch kind {
        case .local:
            let value = title.lowercased()
            return Self.looksLikeFavorite(value) ? 0 : 2
        case .remote(let playlist):
            if playlist.isNetEaseLikedPlaylist { return 1 }
            if playlist.source == .qq, playlist.id == QQMusicAPI.qqLikedPlaylistID { return 1 }
            return Self.looksLikeFavorite(playlist.name.lowercased()) ? 1 : 2
        }
    }

    private static func looksLikeFavorite(_ value: String) -> Bool {
        value.contains("红心")
            || value.contains("我喜欢")
            || value.contains("我的喜欢")
            || value.contains("喜欢的音乐")
            || value.contains("我的收藏")
            || value.contains("收藏歌单")
            || value.contains("liked")
            || value.contains("favorite")
    }
}

struct MusicLibraryHomeView: View {
    var onOpenProfile: () -> Void = {}

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var localStore = LocalLibraryStore.shared
    @ObservedObject private var playlistStore = MusicLibraryPlaylistStore.shared
    @ObservedObject private var favPlaylistStore = FavoritePlaylistStore.shared
    @ObservedObject private var activityStore = PlaylistActivityStore.shared
    @ObservedObject private var synology = SynologyAPI.shared
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared
    @ObservedObject private var favorites = FavoritesStore.shared
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    @State private var playlistFilter: String = "全部"
    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""

    private var allFavoriteSongs: [Song] {
        var songs: [Song] = []
        var seen = Set<String>()
        if let localFav = localStore.playlists.first(where: { $0.name == "我的收藏歌单" || $0.name == "三平台喜欢" }) {
            for song in localFav.songs where !seen.contains(song.identityKey) {
                seen.insert(song.identityKey)
                songs.append(song)
            }
        }
        for song in favorites.neteaseFavoriteSongs where !seen.contains(song.identityKey) {
            seen.insert(song.identityKey)
            songs.append(song)
        }
        for song in favorites.qqFavoriteSongs where !seen.contains(song.identityKey) {
            seen.insert(song.identityKey)
            songs.append(song)
        }
        for song in favorites.kugouFavoriteSongs where !seen.contains(song.identityKey) {
            seen.insert(song.identityKey)
            songs.append(song)
        }
        for song in favorites.synologyFavoriteSongs where !seen.contains(song.identityKey) {
            seen.insert(song.identityKey)
            songs.append(song)
        }
        return songs
    }

    private var isNativeClean: Bool {
        ATMusicUIStyle(rawValue: uiStyleRaw) == .nativeClean
    }


    private var filteredPlaylists: [MusicLibraryPlaylistItem] {
        let all = homePlaylists
        switch playlistFilter {
        case "本地":
            return all.filter { $0.source == .local }
        case "网易云":
            return all.filter { $0.source == .netease }
        case "QQ":
            return all.filter { $0.source == .qq }
        case "酷狗":
            return all.filter { $0.source == .kugou }
        case "NAS":
            return all.filter { $0.source == .synology }
        default:
            return all
        }
    }

    private var homePlaylists: [MusicLibraryPlaylistItem] {
        var groups: [[MusicLibraryPlaylistItem]] = []

        let localItems = localStore.playlists.map {
            MusicLibraryPlaylistItem(
                id: "local-\($0.id.uuidString)",
                title: $0.name,
                subtitle: "本地 · \(atmusicLocalSongCountText($0.songs.count))",
                coverURL: $0.songs.first?.coverURL,
                source: .local,
                kind: .local($0.id),
                fallbackActivity: $0.createdAt.timeIntervalSince1970
            )
        }
        if !localItems.isEmpty { groups.append(localItems) }

        let remoteGroups: [[Playlist]] = [
            platformPrefs.isEnabled(SearchProvider.netease) ? playlistStore.netease : [],
            platformPrefs.isEnabled(SearchProvider.qq) ? playlistStore.qq : [],
            platformPrefs.isEnabled(SearchProvider.kugou) ? playlistStore.kugou : [],
            platformPrefs.isEnabled(SearchProvider.synology) ? playlistStore.synology : []
        ]
        for group in remoteGroups where !group.isEmpty {
            groups.append(group.map { playlist in
                MusicLibraryPlaylistItem(
                    id: "\(playlist.source.rawValue)-\(playlist.id)",
                    title: playlist.name,
                    subtitle: "\(playlist.source.atmusicDisplayName) · \(atmusicSongCountText(playlist.trackCount))",
                    coverURL: playlist.coverURL,
                    source: playlist.source,
                    kind: .remote(playlist)
                )
            })
        }

        var result: [MusicLibraryPlaylistItem] = []
        var index = 0
        while result.count < 8 {
            var appended = false
            for group in groups where index < group.count {
                result.append(group[index])
                appended = true
                if result.count == 8 { break }
            }
            if !appended { break }
            index += 1
        }
        return result
    }

    var body: some View {
        let _ = theme.accent
        ATMusicNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: isNativeClean ? 26 : 22) {
                        header
                        favoriteHeroCard
                        quickAccess
                        favoritePlaylistsSection
                        playlistsPreview
                    }
                    .padding(.horizontal, isNativeClean ? 24 : 16)
                    .padding(.top, isNativeClean ? 18 : 10)
                    .padding(.bottom, 190)
                    .frame(maxWidth: DeviceLayoutHelper.contentMaxWidth(for: horizontalSizeClass))
                    .frame(maxWidth: .infinity)
                }
                .atmusicScrollIndicatorsHidden()
                .refreshable { await playlistStore.load(auth: auth, force: true) }
            }
            .navigationBarHidden(true)
        }
        .task { await playlistStore.load(auth: auth, force: false) }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("音乐库")
                    .font(ATMusicFont.appFont(isNativeClean ? 34 : 30, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                Text("自己的音乐，一处找到")
                    .font(ATMusicFont.appFont(12, .medium))
                    .foregroundStyle(Color.atmusicComment)
            }
            Spacer()
        }
    }

    private var favoriteHeroCard: some View {
        NavigationLink {
            UnifiedFavoritesDetailView()
        } label: {
            HStack(spacing: 15) {
                // 封面展示：前几首歌曲的封面缩略图或高质感红心微光背景
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.94, green: 0.22, blue: 0.35), Color(red: 0.88, green: 0.14, blue: 0.45)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 80, height: 80)
                        .shadow(color: Color.red.opacity(0.28), radius: 8, y: 4)

                    let covers = Array(allFavoriteSongs.compactMap(\.coverURL).prefix(4))
                    if covers.count >= 4 {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                            ForEach(0..<4, id: \.self) { idx in
                                CoverImage(url: covers[idx], size: 36, cornerRadius: 4)
                            }
                        }
                        .frame(width: 74, height: 74)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.black.opacity(0.22))
                            Image(systemName: "heart.fill")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(.white)
                                .shadow(radius: 4)
                        }
                    } else if let firstCover = covers.first {
                        CoverImage(url: firstCover, size: 80, cornerRadius: 18)
                            .overlay {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.black.opacity(0.24))
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 28, weight: .bold))
                                    .foregroundStyle(.white)
                                    .shadow(radius: 4)
                            }
                    } else {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("我喜欢的音乐")
                        .font(ATMusicFont.appFont(18, .bold))
                        .foregroundStyle(Color.atmusicLabel)

                    Text("\(allFavoriteSongs.count) 首歌曲 · 同步本地与平台红心")
                        .font(ATMusicFont.appFont(12, .medium))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Button {
                            if !allFavoriteSongs.isEmpty {
                                player.play(songs: allFavoriteSongs, startAt: 0)
                                ATMusicHaptics.tap()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text("播放全部")
                                    .font(ATMusicFont.appFont(12, .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Color.atmusicAmber, in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Button {
                            if !allFavoriteSongs.isEmpty {
                                player.play(songs: allFavoriteSongs.shuffled(), startAt: 0)
                                ATMusicHaptics.tap()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "shuffle")
                                    .font(.system(size: 10, weight: .bold))
                                Text("随机播放")
                                    .font(ATMusicFont.appFont(12, .semibold))
                            }
                            .foregroundStyle(Color.atmusicLabel)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 2)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.atmusicComment.opacity(0.6))
            }
            .padding(14)
            .background {
                ATMusicGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.98))
    }

    private var quickAccess: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("快捷浏览")
                .font(ATMusicFont.appFont(16, .bold))
                .foregroundStyle(Color.atmusicLabel)

            // 若 NAS 已连接展示 2x2 四宫格；若未连接则自动隐藏 NAS，3 个入口平分横排，不占版面
            if synology.isLoggedIn {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    recentCard
                    localCard
                    favPlaylistsCard
                    nasCard
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
            } else {
                HStack(spacing: 10) {
                    recentCard
                    localCard
                    favPlaylistsCard
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
            }
        }
    }

    private var recentCard: some View {
        NavigationLink {
            MusicLibraryHistoryView()
        } label: {
            MusicLibraryQuickCard(
                title: "最近播放",
                subtitle: "\(player.history.count) 首",
                systemImage: "clock.arrow.circlepath",
                enabled: true
            )
        }
    }

    private var localCard: some View {
        NavigationLink {
            LocalMusicBrowserView()
        } label: {
            MusicLibraryQuickCard(
                title: "本地音乐",
                subtitle: "\(localStore.importedSongs.count) 首",
                systemImage: "internaldrive.fill",
                enabled: true
            )
        }
    }

    private var favPlaylistsCard: some View {
        NavigationLink {
            MusicLibraryAllPlaylistsView()
        } label: {
            MusicLibraryQuickCard(
                title: "收藏歌单",
                subtitle: "\(favPlaylistStore.playlists.count) 个",
                systemImage: "heart.rectangle.fill",
                enabled: true
            )
        }
    }

    private var nasCard: some View {
        NavigationLink {
            SynologyFileLibraryView()
        } label: {
            MusicLibraryQuickCard(
                title: "NAS 文件",
                subtitle: "浏览文件夹",
                systemImage: "externaldrive.fill",
                enabled: true
            )
        }
    }


    private var favoritePlaylistsSection: some View {
        Group {
            if !favPlaylistStore.playlists.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("收藏歌单")
                            .font(ATMusicFont.appFont(18, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                        Text("\(favPlaylistStore.playlists.count)")
                            .font(ATMusicFont.appFont(12, .medium))
                            .foregroundStyle(Color.atmusicComment)
                        Spacer()
                        NavigationLink {
                            MusicLibraryAllPlaylistsView()
                        } label: {
                            HStack(spacing: 4) {
                                Text("全部")
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .font(ATMusicFont.appFont(13, .semibold))
                            .foregroundStyle(Color.atmusicComment)
                        }
                        .buttonStyle(.plain)
                    }

                    if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                        LazyVGrid(columns: DeviceLayoutHelper.adaptiveCardColumns(for: horizontalSizeClass, minWidth: 160, maxWidth: 240, spacing: 16), spacing: 18) {
                            ForEach(favPlaylistStore.playlists, id: \.identityKey) { playlist in
                                NavigationLink {
                                    PlaylistView(playlist: playlist)
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        CoverImage(url: playlist.coverURL, size: 180, cornerRadius: 14)
                                            .aspectRatio(1, contentMode: .fit)
                                            .frame(maxWidth: .infinity)
                                        Text(playlist.name)
                                            .font(ATMusicFont.appFont(14, .semibold))
                                            .foregroundStyle(Color.atmusicLabel)
                                            .lineLimit(1)
                                        HStack(spacing: 4) {
                                            SourceBadgeView(source: playlist.source)
                                            Text(playlist.creatorName.isEmpty ? playlist.source.atmusicDisplayName : playlist.creatorName)
                                                .font(ATMusicFont.appFont(12))
                                                .foregroundStyle(Color.atmusicComment)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        favPlaylistStore.remove(playlist)
                                    } label: {
                                        Label("取消收藏", systemImage: "heart.slash")
                                    }
                                }
                            }
                        }
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(favPlaylistStore.playlists, id: \.identityKey) { playlist in
                                    NavigationLink {
                                        PlaylistView(playlist: playlist)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            CoverImage(url: playlist.coverURL, size: 124, cornerRadius: 12)
                                                .frame(width: 124, height: 124)
                                                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                                            Text(playlist.name)
                                                .font(ATMusicFont.appFont(13, .semibold))
                                                .foregroundStyle(Color.atmusicLabel)
                                                .lineLimit(1)
                                                .frame(width: 124, alignment: .leading)
                                            HStack(spacing: 4) {
                                                SourceBadgeView(source: playlist.source)
                                                Text(playlist.creatorName.isEmpty ? playlist.source.atmusicDisplayName : playlist.creatorName)
                                                    .font(ATMusicFont.appFont(11.5, .medium))
                                                    .foregroundStyle(Color.atmusicComment)
                                                    .lineLimit(1)
                                            }
                                            .frame(width: 124, alignment: .leading)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            favPlaylistStore.remove(playlist)
                                        } label: {
                                            Label("取消收藏", systemImage: "heart.slash")
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                    }
                }
            }
        }
    }

    private var availableFilterTags: [String] {
        var tags = ["全部", "本地"]
        if platformPrefs.isEnabled(SearchProvider.netease) { tags.append("网易云") }
        if platformPrefs.isEnabled(SearchProvider.qq) { tags.append("QQ") }
        if platformPrefs.isEnabled(SearchProvider.kugou) { tags.append("酷狗") }
        if platformPrefs.isEnabled(SearchProvider.synology) { tags.append("NAS") }
        return tags
    }

    private var playlistsPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("我的歌单")
                    .font(ATMusicFont.appFont(18, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                HStack(spacing: 12) {
                    Button {
                        newPlaylistName = ""
                        showCreatePlaylist = true
                        ATMusicHaptics.tap()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                            Text("新建")
                                .font(ATMusicFont.appFont(13, .semibold))
                        }
                        .foregroundStyle(Color.atmusicAmber)
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        MusicLibraryAllPlaylistsView()
                    } label: {
                        HStack(spacing: 4) {
                            Text("全部")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .font(ATMusicFont.appFont(13, .semibold))
                        .foregroundStyle(Color.atmusicComment)
                    }
                    .buttonStyle(.plain)
                }
            }

            // 分类胶囊筛选行 [ 全部 / 本地 / 网易云 / QQ / 酷狗 ]
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(availableFilterTags, id: \.self) { tag in
                        let isSelected = playlistFilter == tag
                        Button {
                            playlistFilter = tag
                            ATMusicHaptics.select()
                        } label: {
                            Text(tag)
                                .font(ATMusicFont.appFont(12, isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? Color.white : Color.atmusicLabel)
                                .padding(.horizontal, 12)
                                .frame(height: 28)
                                .background(
                                    isSelected ? Color.atmusicAmber : Color.primary.opacity(0.06),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 1)
            }

            let displayList = filteredPlaylists
            if displayList.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlistFilter == "全部" ? "还没有歌单" : "没有\(playlistFilter)分类歌单")
                            .font(ATMusicFont.appFont(14, .semibold))
                            .foregroundStyle(Color.atmusicLabel)
                        Text(playlistFilter == "本地" ? "点击右上角「新建」可创建本地歌单" : "登录平台或新建歌单后会显示在这里")
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicComment)
                    }
                    Spacer()
                }
                .padding(14)
                .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
            } else if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                LazyVGrid(columns: DeviceLayoutHelper.adaptiveCardColumns(for: horizontalSizeClass, minWidth: 160, maxWidth: 240, spacing: 16), spacing: 18) {
                    ForEach(displayList) { item in
                        iPadPlaylistItemCard(item)
                    }
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(displayList) { item in
                        playlistLink(item)
                        if item.id != displayList.last?.id {
                            Divider()
                                .overlay(Color.atmusicComment.opacity(0.12))
                                .padding(.leading, 66)
                        }
                    }
                }
                .padding(.vertical, 4)
                .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)) }
            }
        }
        .alert("新建本地歌单", isPresented: $showCreatePlaylist) {
            TextField("歌单名称", text: $newPlaylistName)
            Button("取消", role: .cancel) {}
            Button("创建") {
                let trimmed = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                _ = localStore.createPlaylist(name: trimmed)
                ATMusicHaptics.success()
                ToastCenter.shared.show("已创建歌单「\(trimmed)」")
            }
        }
    }

    @ViewBuilder
    private func iPadPlaylistItemCard(_ item: MusicLibraryPlaylistItem) -> some View {
        switch item.kind {
        case .remote(let playlist):
            NavigationLink {
                PlaylistView(playlist: playlist)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    CoverImage(url: item.coverURL, size: 180, cornerRadius: 14)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                    Text(item.title)
                        .font(ATMusicFont.appFont(14, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
        case .local(let id):
            NavigationLink {
                LocalPlaylistBrowserView(playlistID: id)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    CoverImage(url: item.coverURL, size: 180, cornerRadius: 14)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                    Text(item.title)
                        .font(ATMusicFont.appFont(14, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func playlistLink(_ item: MusicLibraryPlaylistItem) -> some View {
        switch item.kind {
        case .remote(let playlist):
            NavigationLink {
                PlaylistView(playlist: playlist)
                    .onAppear { activityStore.mark(item.id) }
            } label: {
                MusicLibraryPlaylistRow(item: item)
            }
            .buttonStyle(.plain)
        case .local(let id):
            NavigationLink {
                LocalPlaylistBrowserView(playlistID: id)
                    .onAppear { activityStore.mark(item.id) }
            } label: {
                MusicLibraryPlaylistRow(item: item)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct MusicLibraryQuickCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(enabled ? Color.atmusicAmber : Color.atmusicComment)
            Text(title)
                .font(ATMusicFont.appFont(14, .semibold))
                .foregroundStyle(Color.atmusicLabel)
                .lineLimit(1)
            Text(subtitle)
                .font(ATMusicFont.appFont(10))
                .foregroundStyle(Color.atmusicComment)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .padding(12)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
        .opacity(enabled ? 1 : 0.72)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct MusicLibraryPlaylistRow: View {
    let item: MusicLibraryPlaylistItem

    var body: some View {
        HStack(spacing: 12) {
            if item.source == .local, item.coverURL == nil {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.atmusicAmber.opacity(0.12))
                    Image(systemName: "music.note.list")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                }
                .frame(width: 50, height: 50)
            } else {
                CoverImage(url: item.coverURL, size: 50, cornerRadius: 11)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(ATMusicFont.appFont(14, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if item.source != .local {
                SourceBadgeView(source: item.source, compact: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

private enum MusicLibraryPlaylistFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case favorites = "收藏"
    case local = "本地"
    case netease = "网易云"
    case qq = "QQ"
    case kugou = "酷狗"
    case synology = "NAS"
    var id: String { rawValue }
}

struct MusicLibraryHistoryView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        ZStack {
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            if player.history.isEmpty {
                EmptyStateView(icon: "clock.arrow.circlepath", text: "暂无播放历史")
            } else {
                List {
                    ForEach(Array(player.history.enumerated()), id: \.element.identityKey) { index, song in
                        SongCell(song: song, glassRow: false, playbackContext: player.history, playbackIndex: index) {
                            player.play(songs: player.history, startAt: index)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    .onDelete { offsets in
                        player.removeHistory(at: offsets)
                    }
                }
                .atmusicScrollContentBackgroundHidden()
                .listStyle(.plain)
            }
        }
        .navigationTitle("最近播放")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !player.history.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") {
                        ATMusicHaptics.tap()
                        player.clearHistory()
                    }
                }
            }
        }
    }
}

struct MusicLibraryAllPlaylistsView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var localStore = LocalLibraryStore.shared
    @ObservedObject private var playlistStore = MusicLibraryPlaylistStore.shared
    @ObservedObject private var activityStore = PlaylistActivityStore.shared
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared

    @State private var filter: MusicLibraryPlaylistFilter = .all
    @State private var searchText = ""
    @State private var showAdvancedManagement = false

    private var items: [MusicLibraryPlaylistItem] {
        var result: [MusicLibraryPlaylistItem] = []
        if filter == .all || filter == .favorites {
            result += FavoritePlaylistStore.shared.playlists.map {
                MusicLibraryPlaylistItem(
                    id: "fav-\($0.identityKey)",
                    title: $0.name,
                    subtitle: "收藏 · \($0.source.atmusicDisplayName) · \(atmusicSongCountText($0.trackCount))",
                    coverURL: $0.coverURL,
                    source: $0.source,
                    kind: .remote($0)
                )
            }
        }

        if filter == .all || filter == .local {
            result += localStore.playlists.map {
                MusicLibraryPlaylistItem(
                    id: "local-\($0.id.uuidString)",
                    title: $0.name,
                    subtitle: "本地 · \(atmusicLocalSongCountText($0.songs.count))",
                    coverURL: $0.songs.first?.coverURL,
                    source: .local,
                    kind: .local($0.id),
                    fallbackActivity: $0.createdAt.timeIntervalSince1970
                )
            }
        }

        func append(_ playlists: [Playlist], when target: MusicLibraryPlaylistFilter) {
            guard filter == .all || filter == target else { return }
            result += playlists.map {
                MusicLibraryPlaylistItem(
                    id: "\($0.source.rawValue)-\($0.id)",
                    title: $0.name,
                    subtitle: "\($0.source.atmusicDisplayName) · \(atmusicSongCountText($0.trackCount))",
                    coverURL: $0.coverURL,
                    source: $0.source,
                    kind: .remote($0)
                )
            }
        }

        if platformPrefs.isEnabled(SearchProvider.netease) { append(playlistStore.netease, when: .netease) }
        if platformPrefs.isEnabled(SearchProvider.qq) { append(playlistStore.qq, when: .qq) }
        if platformPrefs.isEnabled(SearchProvider.kugou) { append(playlistStore.kugou, when: .kugou) }
        if platformPrefs.isEnabled(SearchProvider.synology) { append(playlistStore.synology, when: .synology) }

        let stableIndex = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($0.element.id, $0.offset) })
        result.sort { lhs, rhs in
            if lhs.semanticPriority != rhs.semanticPriority {
                return lhs.semanticPriority < rhs.semanticPriority
            }
            let leftActivity = max(activityStore.timestamp(for: lhs.id), lhs.fallbackActivity)
            let rightActivity = max(activityStore.timestamp(for: rhs.id), rhs.fallbackActivity)
            if leftActivity != rightActivity {
                return leftActivity > rightActivity
            }
            return (stableIndex[lhs.id] ?? 0) < (stableIndex[rhs.id] ?? 0)
        }

        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return result }
        return result.filter { item in
            item.title.lowercased().contains(keyword)
                || item.subtitle.lowercased().contains(keyword)
        }
    }

    var body: some View {
        ZStack {
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(MusicLibraryPlaylistFilter.allCases) { option in
                            let selected = filter == option
                            Button {
                                ATMusicHaptics.select()
                                filter = option
                            } label: {
                                Text(option.rawValue)
                                    .font(ATMusicFont.appFont(13, .semibold))
                                    .atmusicSelectionForeground(selected: selected, accent: .atmusicAmber)
                                    .padding(.horizontal, 14)
                                    .frame(height: 36)
                                    .background {
                                        ATMusicSelectableSurface(selected: selected, shape: Capsule(), accent: .atmusicAmber)
                                    }
                            }
                            .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                List {
                    if items.isEmpty {
                        EmptyStateView(icon: "music.note.list", text: "这个分类还没有歌单")
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(items) { item in
                            switch item.kind {
                            case .remote(let playlist):
                                NavigationLink {
                                    PlaylistView(playlist: playlist)
                                        .onAppear { activityStore.mark(item.id) }
                                } label: {
                                    MusicLibraryPlaylistRow(item: item)
                                }
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            case .local(let id):
                                NavigationLink {
                                    LocalPlaylistBrowserView(playlistID: id)
                                        .onAppear { activityStore.mark(item.id) }
                                } label: {
                                    MusicLibraryPlaylistRow(item: item)
                                }
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }
                    }
                }
                .atmusicScrollContentBackgroundHidden()
                .listStyle(.plain)
            }
        }
        .navigationTitle("全部歌单")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索歌单名称"
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showAdvancedManagement = true
                    } label: {
                        Label("歌单管理", systemImage: "slider.horizontal.3")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showAdvancedManagement) {
            LibraryView(showsCloseButton: true)
                .environmentObject(player)
                .environmentObject(auth)
                .environmentObject(theme)
        }
        .task { await playlistStore.load(auth: auth, force: false) }
        .refreshable { await playlistStore.load(auth: auth, force: true) }
    }
}


struct LocalMusicBrowserView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore
    @ObservedObject private var store = LocalLibraryStore.shared

    @State private var showImporter = false
    @State private var showManager = false
    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""
    @State private var importing = false
    @State private var importMessage = ""

    private var albums: [(name: String, artist: String, coverURL: URL?, songs: [Song])] {
        let grouped = Dictionary(grouping: store.importedSongs) { song in
            let album = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
            return album.isEmpty ? "未知专辑" : album
        }
        return grouped.map { name, songs in
            (name, songs.first?.artists ?? "", songs.first?.coverURL, songs)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var artists: [(name: String, coverURL: URL?, songs: [Song])] {
        var map: [String: [Song]] = [:]
        for song in store.importedSongs {
            let names = song.artists
                .components(separatedBy: " / ")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for name in names.isEmpty ? ["未知艺术家"] : names {
                map[name, default: []].append(song)
            }
        }
        return map.map { name, songs in (name, songs.first?.coverURL, songs) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ZStack {
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            List {
                if importing {
                    HStack(spacing: 10) {
                        ProgressView().tint(Color.atmusicAmber)
                        Text("正在导入本地音乐…")
                            .font(ATMusicFont.appFont(13))
                            .foregroundStyle(Color.atmusicComment)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else if !importMessage.isEmpty {
                    Text(importMessage)
                        .font(ATMusicFont.appFont(12, .medium))
                        .foregroundStyle(Color.atmusicSage)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                Section("浏览") {
                    NavigationLink {
                        LocalFileCollectionView(songs: store.importedSongs)
                    } label: {
                        MusicBrowseRow(
                            coverURL: store.importedSongs.first?.coverURL,
                            title: "文件",
                            subtitle: "\(store.importedSongs.count) 个音频文件",
                            systemImage: "doc.on.doc"
                        )
                    }

                    NavigationLink {
                        LocalAlbumCollectionView(albums: albums)
                    } label: {
                        MusicBrowseRow(
                            coverURL: albums.first?.coverURL,
                            title: "专辑",
                            subtitle: "\(albums.count) 个",
                            systemImage: "square.stack"
                        )
                    }

                    NavigationLink {
                        LocalArtistCollectionView(artists: artists)
                    } label: {
                        MusicBrowseRow(
                            coverURL: artists.first?.coverURL,
                            title: "歌手",
                            subtitle: "\(artists.count) 位",
                            systemImage: "person.2"
                        )
                    }

                    NavigationLink {
                        LocalPlaylistCollectionView()
                    } label: {
                        MusicBrowseRow(
                            coverURL: store.playlists.first?.songs.first?.coverURL,
                            title: "本地歌单",
                            subtitle: "\(store.playlists.count) 个",
                            systemImage: "music.note.list"
                        )
                    }
                }
            }
            .atmusicScrollContentBackgroundHidden()
            .listStyle(.plain)
        }
        .navigationTitle("本地音乐")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showImporter = true
                    } label: {
                        Label("导入音乐", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        newPlaylistName = ""
                        showCreatePlaylist = true
                    } label: {
                        Label("新建本地歌单", systemImage: "plus")
                    }
                    Button {
                        showManager = true
                    } label: {
                        Label("管理本地音乐", systemImage: "folder.badge.gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showImporter) {
            LocalAudioDocumentPicker { urls in
                showImporter = false
                importFiles(urls)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showManager) {
            LocalMusicManagementSheet()
                .environmentObject(player)
                .environmentObject(theme)
        }
        .alert("新建本地歌单", isPresented: $showCreatePlaylist) {
            TextField("歌单名称", text: $newPlaylistName)
            Button("创建") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                _ = store.createPlaylist(name: name)
                ATMusicHaptics.success()
                newPlaylistName = ""
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        importing = true
        importMessage = ""
        Task {
            let report = await LocalAudioImportService.shared.importFiles(urls)
            store.addImportedSongs(report.songs)
            importing = false
            importMessage = report.message
            report.importedCount > 0 ? ATMusicHaptics.success() : ATMusicHaptics.tap()
        }
    }
}

private struct MusicBrowseRow: View {
    let coverURL: URL?
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            if let coverURL {
                CoverImage(url: coverURL, size: 50, cornerRadius: 11)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.atmusicAmber.opacity(0.10))
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                }
                .frame(width: 50, height: 50)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(ATMusicFont.appFont(14, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
                Text(subtitle)
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.atmusicComment.opacity(0.55))
        }
        .frame(minHeight: 58)
    }
}

struct LocalFileCollectionView: View {
    @EnvironmentObject private var player: PlayerManager
    let songs: [Song]
    @State private var query = ""

    private var displayedSongs: [Song] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sorted = songs.sorted {
            originalFilename(for: $0).localizedStandardCompare(originalFilename(for: $1)) == .orderedAscending
        }
        guard !keyword.isEmpty else { return sorted }
        return sorted.filter { song in
            originalFilename(for: song).lowercased().contains(keyword)
                || song.name.lowercased().contains(keyword)
                || song.artists.lowercased().contains(keyword)
                || song.album.lowercased().contains(keyword)
        }
    }

    var body: some View {
        ZStack {
            GlassBackdrop()
            List {
                if !displayedSongs.isEmpty {
                    Section {
                        HStack(spacing: 10) {
                            GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                player.play(songs: displayedSongs, startAt: 0)
                            }
                            GlassButton(title: "随机播放", systemName: "shuffle") {
                                player.play(songs: displayedSongs.shuffled(), startAt: 0)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                Section {
                    ForEach(Array(displayedSongs.enumerated()), id: \.element.identityKey) { index, song in
                        Button {
                            ATMusicHaptics.tap()
                            player.play(songs: displayedSongs, startAt: index)
                        } label: {
                            HStack(spacing: 12) {
                                CoverImage(url: song.coverURL, size: 46, cornerRadius: 9)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(originalFilename(for: song))
                                        .font(ATMusicFont.appFont(14, .medium))
                                        .foregroundStyle(Color.atmusicLabel)
                                        .lineLimit(1)
                                    Text(fileSubtitle(for: song))
                                        .font(ATMusicFont.appFont(11))
                                        .foregroundStyle(Color.atmusicComment)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(song.formattedDuration)
                                    .font(ATMusicFont.appFont(11, .regular, .monospaced))
                                    .foregroundStyle(Color.atmusicComment)
                            }
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(GlassPressButtonStyle(scale: 0.985))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            }
            .atmusicScrollContentBackgroundHidden()
            .listStyle(.plain)
        }
        .navigationTitle("文件")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索本地文件")
    }

    private func originalFilename(for song: Song) -> String {
        guard let path = song.localRelativePath,
              let file = LocalAudioFileManager.shared.file(relativePath: path) else {
            return song.name
        }
        return file.originalFilename
    }

    private func fileSubtitle(for song: Song) -> String {
        let artist = song.artists.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
        if !artist.isEmpty, !album.isEmpty { return "\(artist) · \(album)" }
        if !artist.isEmpty { return artist }
        if !album.isEmpty { return album }
        return "本地音频"
    }
}

struct LocalSongCollectionView: View {
    @EnvironmentObject private var player: PlayerManager
    let title: String
    let songs: [Song]
    @State private var query = ""

    private var filteredSongs: [Song] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return songs }
        return songs.filter {
            $0.name.lowercased().contains(keyword)
                || $0.artists.lowercased().contains(keyword)
                || $0.album.lowercased().contains(keyword)
        }
    }

    var body: some View {
        List {
            if !filteredSongs.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                            player.play(songs: filteredSongs, startAt: 0)
                        }
                        GlassButton(title: "随机播放", systemName: "shuffle") {
                            player.play(songs: filteredSongs.shuffled(), startAt: 0)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            Section {
                ForEach(Array(filteredSongs.enumerated()), id: \.element.identityKey) { index, song in
                    SongCell(song: song, glassRow: false, playbackContext: filteredSongs, playbackIndex: index) {
                        player.play(songs: filteredSongs, startAt: index)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索歌曲")
    }
}


struct LocalAlbumCollectionView: View {
    let albums: [(name: String, artist: String, coverURL: URL?, songs: [Song])]

    var body: some View {
        List {
            ForEach(Array(albums.enumerated()), id: \.offset) { _, album in
                NavigationLink {
                    LocalSongCollectionView(title: album.name, songs: album.songs)
                } label: {
                    MusicBrowseRow(
                        coverURL: album.coverURL,
                        title: album.name,
                        subtitle: album.artist.isEmpty ? "\(album.songs.count) 首" : "\(album.artist) · \(album.songs.count) 首",
                        systemImage: "square.stack"
                    )
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .navigationTitle("专辑")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LocalArtistCollectionView: View {
    let artists: [(name: String, coverURL: URL?, songs: [Song])]

    var body: some View {
        List {
            ForEach(Array(artists.enumerated()), id: \.offset) { _, artist in
                NavigationLink {
                    LocalSongCollectionView(title: artist.name, songs: artist.songs)
                } label: {
                    MusicBrowseRow(
                        coverURL: artist.coverURL,
                        title: artist.name,
                        subtitle: "\(artist.songs.count) 首",
                        systemImage: "person.crop.circle"
                    )
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .navigationTitle("歌手")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LocalPlaylistCollectionView: View {
    @ObservedObject private var store = LocalLibraryStore.shared

    var body: some View {
        List {
            ForEach(store.playlists) { playlist in
                NavigationLink {
                    LocalPlaylistBrowserView(playlistID: playlist.id)
                } label: {
                    MusicBrowseRow(
                        coverURL: playlist.songs.first?.coverURL,
                        title: playlist.name,
                        subtitle: "\(playlist.songs.count) 首",
                        systemImage: "music.note.list"
                    )
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .navigationTitle("本地歌单")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LocalPlaylistBrowserView: View {
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var store = LocalLibraryStore.shared

    let playlistID: UUID
    @State private var query = ""

    private var playlist: LocalPlaylist? {
        store.playlists.first { $0.id == playlistID }
    }

    private var songs: [Song] {
        guard let playlist else { return [] }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return playlist.songs }
        return playlist.songs.filter {
            $0.name.lowercased().contains(keyword)
                || $0.artists.lowercased().contains(keyword)
                || $0.album.lowercased().contains(keyword)
        }
    }

    var body: some View {
        List {
            if !songs.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                            player.play(songs: songs, startAt: 0)
                        }
                        GlassButton(title: "随机播放", systemName: "shuffle") {
                            player.play(songs: songs.shuffled(), startAt: 0)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }

            Section {
                ForEach(Array(songs.enumerated()), id: \.element.identityKey) { index, song in
                    SongCell(song: song, glassRow: false, playbackContext: songs, playbackIndex: index) {
                        player.play(songs: songs, startAt: index)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .navigationTitle(playlist?.name ?? "本地歌单")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索歌单歌曲")
    }
}

struct SynologyFileLibraryView: View {
    @ObservedObject private var synology = SynologyAPI.shared

    var body: some View {
        if synology.isLoggedIn {
            SynologyFolderView(folderID: nil, title: "NAS 文件")
        } else {
            EmptyStateView(
                icon: "externaldrive.badge.exclamationmark",
                text: "尚未连接群晖 NAS\n请前往“我的” → “账号与登录”完成连接"
            )
            .navigationTitle("NAS 文件")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}


// MARK: - 统一我喜欢的音乐详情页

struct UnifiedFavoritesDetailView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore
    @ObservedObject private var localStore = LocalLibraryStore.shared
    @ObservedObject private var favorites = FavoritesStore.shared
    @State private var query = ""

    private var allSongs: [Song] {
        var songs: [Song] = []
        var seen = Set<String>()
        if let localFav = localStore.playlists.first(where: { $0.name == "我的收藏歌单" || $0.name == "三平台喜欢" }) {
            for song in localFav.songs where !seen.contains(song.identityKey) {
                seen.insert(song.identityKey)
                songs.append(song)
            }
        }
        for song in favorites.neteaseFavoriteSongs where !seen.contains(song.identityKey) {
            seen.insert(song.identityKey)
            songs.append(song)
        }
        for song in favorites.qqFavoriteSongs where !seen.contains(song.identityKey) {
            seen.insert(song.identityKey)
            songs.append(song)
        }
        for song in favorites.kugouFavoriteSongs where !seen.contains(song.identityKey) {
            seen.insert(song.identityKey)
            songs.append(song)
        }
        for song in favorites.synologyFavoriteSongs where !seen.contains(song.identityKey) {
            seen.insert(song.identityKey)
            songs.append(song)
        }
        return songs
    }

    private var displayedSongs: [Song] {
        let kw = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return allSongs }
        return allSongs.filter {
            $0.name.lowercased().contains(kw)
                || $0.artists.lowercased().contains(kw)
                || $0.album.lowercased().contains(kw)
        }
    }

    var body: some View {
        ZStack {
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            List {
                if !displayedSongs.isEmpty {
                    Section {
                        HStack(spacing: 10) {
                            GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                player.play(songs: displayedSongs, startAt: 0)
                            }
                            GlassButton(title: "随机播放", systemName: "shuffle") {
                                player.play(songs: displayedSongs.shuffled(), startAt: 0)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }

                Section {
                    ForEach(Array(displayedSongs.enumerated()), id: \.element.identityKey) { index, song in
                        HStack(spacing: 12) {
                            CoverImage(url: song.coverURL, size: 48, cornerRadius: 8)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(song.name)
                                    .font(ATMusicFont.appFont(15, .semibold))
                                    .foregroundStyle(Color.atmusicLabel)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    SourceBadgeView(source: song.source, compact: true)
                                    Text("\(song.artists) · \(song.album)")
                                        .font(ATMusicFont.appFont(12))
                                        .foregroundStyle(Color.atmusicComment)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Button {
                                Task {
                                    await favorites.toggleFavorite(song)
                                }
                            } label: {
                                Image(systemName: "heart.fill")
                                    .foregroundStyle(.red)
                                    .font(.system(size: 16))
                            }
                            .buttonStyle(.plain)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            player.play(songs: displayedSongs, startAt: index)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task {
                                    await favorites.toggleFavorite(song)
                                }
                            } label: {
                                Label("取消收藏", systemImage: "heart.slash")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("\(displayedSongs.count) 首歌曲")
                            .font(ATMusicFont.appFont(12, .medium))
                            .foregroundStyle(Color.atmusicComment)
                        Spacer()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "搜索收藏歌曲")
            .atmusicScrollContentBackgroundHidden()
        }
        .navigationTitle("我喜欢的音乐")
        .navigationBarTitleDisplayMode(.large)
    }
}
