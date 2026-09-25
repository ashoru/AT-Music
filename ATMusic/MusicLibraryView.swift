import SwiftUI

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
}

struct MusicLibraryHomeView: View {
    var onOpenProfile: () -> Void = {}

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var theme: ThemeStore
    @ObservedObject private var localStore = LocalLibraryStore.shared
    @ObservedObject private var playlistStore = MusicLibraryPlaylistStore.shared
    @ObservedObject private var synology = SynologyAPI.shared
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue

    private var isNativeClean: Bool {
        ATMusicUIStyle(rawValue: uiStyleRaw) == .nativeClean
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
                kind: .local($0.id)
            )
        }
        if !localItems.isEmpty { groups.append(localItems) }

        for group in [playlistStore.netease, playlistStore.qq, playlistStore.kugou, playlistStore.synology] where !group.isEmpty {
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
                        quickAccess
                        playlistsPreview
                    }
                    .padding(.horizontal, isNativeClean ? 24 : 16)
                    .padding(.top, isNativeClean ? 18 : 10)
                    .padding(.bottom, 190)
                    .frame(maxWidth: 860)
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
            Button(action: onOpenProfile) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.atmusicComment.opacity(0.76))
                    .frame(width: 38, height: 38)
                    .background { ATMusicGlass(shape: Circle()) }
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.97))
            .accessibilityLabel("我的")
        }
    }

    private var quickAccess: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("浏览")
                .font(ATMusicFont.appFont(18, .bold))
                .foregroundStyle(Color.atmusicLabel)
            HStack(spacing: 10) {
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
                NavigationLink {
                    SynologyFileLibraryView()
                } label: {
                    MusicLibraryQuickCard(
                        title: "NAS 文件",
                        subtitle: synology.isLoggedIn ? "浏览文件夹" : "未连接",
                        systemImage: "externaldrive.fill",
                        enabled: synology.isLoggedIn
                    )
                }
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.97))
        }
    }


    private var playlistsPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("我的歌单")
                    .font(ATMusicFont.appFont(18, .bold))
                    .foregroundStyle(Color.atmusicLabel)
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

            if homePlaylists.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("还没有歌单")
                            .font(ATMusicFont.appFont(14, .semibold))
                            .foregroundStyle(Color.atmusicLabel)
                        Text("登录音乐平台或新建本地歌单后会显示在这里")
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicComment)
                    }
                    Spacer()
                }
                .padding(14)
                .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(homePlaylists) { item in
                        playlistLink(item)
                        if item.id != homePlaylists.last?.id {
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
    }

    @ViewBuilder
    private func playlistLink(_ item: MusicLibraryPlaylistItem) -> some View {
        switch item.kind {
        case .remote(let playlist):
            NavigationLink {
                PlaylistView(playlist: playlist)
            } label: {
                MusicLibraryPlaylistRow(item: item)
            }
            .buttonStyle(.plain)
        case .local(let id):
            NavigationLink {
                LocalPlaylistBrowserView(playlistID: id)
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
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.atmusicComment.opacity(0.5))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

private enum MusicLibraryPlaylistFilter: String, CaseIterable, Identifiable {
    case all = "全部"
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

    @State private var filter: MusicLibraryPlaylistFilter = .all
    @State private var showAdvancedManagement = false

    private var items: [MusicLibraryPlaylistItem] {
        var result: [MusicLibraryPlaylistItem] = []
        if filter == .all || filter == .local {
            result += localStore.playlists.map {
                MusicLibraryPlaylistItem(
                    id: "local-\($0.id.uuidString)",
                    title: $0.name,
                    subtitle: "本地 · \(atmusicLocalSongCountText($0.songs.count))",
                    coverURL: $0.songs.first?.coverURL,
                    source: .local,
                    kind: .local($0.id)
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

        append(playlistStore.netease, when: .netease)
        append(playlistStore.qq, when: .qq)
        append(playlistStore.kugou, when: .kugou)
        append(playlistStore.synology, when: .synology)
        return result
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
                                } label: {
                                    MusicLibraryPlaylistRow(item: item)
                                }
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            case .local(let id):
                                NavigationLink {
                                    LocalPlaylistBrowserView(playlistID: id)
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
            LibraryView()
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

