import SwiftUI

private enum LibraryRoute: Hashable {
    case playlist(Playlist)
}

enum LibraryProvider: String, CaseIterable, Identifiable, Hashable {
    case netease = "网易云音乐"
    case qq = "QQ音乐"
    case kugou = "酷狗音乐"
    case synology = "群晖 NAS"

    var id: String { rawValue }

    var tint: LinearGradient {
        switch self {
        case .netease:
            return LinearGradient(colors: [Color(red: 0.93, green: 0.22, blue: 0.16), Color(red: 0.80, green: 0.15, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .qq:
            return LinearGradient(colors: [Color(red: 0.15, green: 0.78, blue: 0.55), Color(red: 0.05, green: 0.58, blue: 0.42)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .kugou:
            return LinearGradient(colors: [Color(red: 0.12, green: 0.58, blue: 0.95), Color(red: 0.02, green: 0.32, blue: 0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .synology:
            return LinearGradient(colors: [Color(red: 0.08, green: 0.45, blue: 0.85), Color(red: 0.02, green: 0.25, blue: 0.60)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    var icon: String {
        switch self {
        case .netease: return "cloud.fill"
        case .qq: return "play.rectangle.fill"
        case .kugou: return "music.note"
        case .synology: return "externaldrive.fill"
        }
    }

    var brandImageName: String? {
        switch self {
        case .netease: return "BrandNetease"
        case .qq: return "BrandQQ"
        case .kugou: return "BrandKugou"
        case .synology: return nil
        }
    }
}

private extension LibraryProvider {
    var songSource: SongSource {
        switch self {
        case .netease: return .netease
        case .qq: return .qq
        case .kugou: return .kugou
        case .synology: return .synology
        }
    }
}

struct LibraryView: View {
    var onOpenProfile: () -> Void = {}
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var favorites: FavoritesStore
    @ObservedObject private var qqAuth = QQMusicAuth.shared
    @ObservedObject private var kugouAuth = KugouMusicAuth.shared
    @ObservedObject private var synology = SynologyAPI.shared
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared

    @State private var showHistory = false
    @State private var showSectionSort = false
    @State private var showSyncedPlaylistSort = false
    /// 音乐库板块顺序（本地音乐库 / 我的歌单 / 最近播放，可自定义）
    @State private var libraryOrder = SectionOrderStore.load(SectionOrderStore.libraryKey, defaults: SectionOrderStore.libraryDefaults)
    @State private var navigationPath: [LibraryRoute] = []
    @State private var legacyRoute: LibraryRoute?
    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""
    @State private var pendingDelete: Playlist?
    @State private var showDeleteConfirm = false
    @State private var source: LibraryProvider = .netease
    @AppStorage("atmusic.homeHeaderHideSort") private var hideSortButton = false
    @AppStorage(PlatformPreferenceStore.hidePickerKey) private var hidePlatformPicker = false
    @State private var qqPlaylists: [Playlist] = []
    @State private var qqLoading = false
    @State private var qqSavedAt = Date.distantPast
    @State private var kugouPlaylists: [Playlist] = []
    @State private var kugouLoading = false
    @State private var kugouSavedAt = Date.distantPast
    @State private var synologyPlaylists: [Playlist] = []
    @State private var synologyLoading = false
    @State private var expandedPlaylistProviders: Set<LibraryProvider> = []
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    private var libraryProviders: [LibraryProvider] { platformPrefs.enabledLibraryProviders }

    private var orderedNeteasePlaylists: [Playlist] {
        SyncedPlaylistOrderStore.shared.ordered(auth.playlists, source: .netease)
    }

    private var orderedQQPlaylists: [Playlist] {
        SyncedPlaylistOrderStore.shared.ordered(qqPlaylists, source: .qq)
    }

    private var orderedKugouPlaylists: [Playlist] {
        SyncedPlaylistOrderStore.shared.ordered(kugouPlaylists, source: .kugou)
    }

    private var qqCacheAccountID: String {
        let raw = qqAuth.rawUin
        return raw.isEmpty ? qqAuth.playlistUin : raw
    }

    private var kugouCacheAccountID: String {
        kugouAuth.userId
    }

    private var syncedPlaylistBinding: Binding<[Playlist]> {
        Binding(
            get: {
                switch source {
                case .netease: return orderedNeteasePlaylists
                case .qq: return orderedQQPlaylists
                case .kugou: return orderedKugouPlaylists
                case .synology: return []
                }
            },
            set: { value in
                switch source {
                case .netease: auth.playlists = value
                case .qq: qqPlaylists = value
                case .kugou: kugouPlaylists = value
                case .synology: break
                }
                SyncedPlaylistOrderStore.shared.save(value, source: source.songSource)
            }
        )
    }

    private var isNativeClean: Bool {
        ATMusicUIStyle(rawValue: uiStyleRaw) == .nativeClean
    }

    var body: some View {
        let _ = theme.accent
        ATMusicNavigationStackWithPath(path: $navigationPath) {
        ZStack {
            // 页面背景：同步开启时显示壁纸/背景色，否则默认氛围渐变
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            // 实例级 UITabBar 清透风格（固定全透明，无需调节）
            TabBarAppearanceConfigurator()
            if #unavailable(iOS 16.0) {
                NavigationLink(
                    destination: libraryDestination(legacyRoute ?? .playlist(Playlist(id: 0, name: "", coverURL: nil))),
                    isActive: Binding(
                        get: { legacyRoute != nil },
                        set: { if !$0 { legacyRoute = nil } }
                    )
                ) {
                    EmptyView()
                }
                .hidden()
            }
            ScrollView {
                // These are a few coarse sections, each already containing whole lists.
                // Lazy estimates of section heights can move the scroll anchor on re-entry.
                VStack(alignment: .leading, spacing: isNativeClean ? 30 : 24) {
                    if isNativeClean {
                        appleHeader
                    } else {
                        header
                    }
                    // 聚合歌单页：最近播放 / 我的歌单 / 本地音乐库三个主模块可排序。
                    ForEach(libraryOrder, id: \.self) { key in
                        switch key {
                        case "本地音乐库":
                            LocalMusicSection()
                        case "我的歌单":
                            aggregatedPlaylistsSection
                        case "最近播放":
                            historySection
                        default:
                            EmptyView()
                        }
                    }
                }
                .padding(.horizontal, isNativeClean ? 24 : 16)
                .padding(.top, isNativeClean ? 20 : 8)
                .padding(.bottom, 190)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .atmusicScrollIndicatorsHidden()
            .refreshable {
                await refreshAllSources(force: true)
            }
        }
        .task {
            source = platformPrefs.ensureVisible(source)
            await refreshAllSources(force: false)
        }
        .onAppear {
            source = platformPrefs.ensureVisible(source)
        }
        .onReceive(NotificationCenter.default.publisher(for: .atmusicNeteaseLoginDidUpdate)) { _ in
            guard platformPrefs.isEnabled(SearchProvider.netease) else { return }
            Task { await auth.loadLibrary(force: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .atmusicQQLoginDidUpdate)) { _ in
            guard platformPrefs.isEnabled(SearchProvider.qq) else { return }
            Task { await loadQQPlaylists(force: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .atmusicKugouLoginDidUpdate)) { _ in
            guard platformPrefs.isEnabled(SearchProvider.kugou) else { return }
            Task { await loadKugouPlaylists(force: true) }
        }
        .sheet(isPresented: $showHistory) {
            HistoryView()
                .environmentObject(player)
                .environmentObject(auth)
                .environmentObject(theme)
        }
        .sheet(isPresented: $showSectionSort) {
            SectionOrderSheet(
                title: "歌单页面排序",
                sections: SectionOrderStore.libraryDefaults,
                order: $libraryOrder,
                platformOrder: Binding(
                    get: { platformPrefs.orderedRaw },
                    set: { platformPrefs.orderedRaw = $0 }
                )
            )
                .onDisappear { SectionOrderStore.save(SectionOrderStore.libraryKey, libraryOrder) }
        }
        .sheet(isPresented: $showSyncedPlaylistSort) {
            SyncedPlaylistOrderSheet(
                title: "\(source.rawValue)歌单排序",
                source: source.songSource,
                playlists: syncedPlaylistBinding
            )
            .environmentObject(theme)
        }
        .alert("新建歌单", isPresented: $showCreatePlaylist) {
            TextField("歌单名称", text: $newPlaylistName)
            Button("创建") { createPlaylist() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("输入歌单名称，创建后同步到\(source.rawValue)")
        }
        .confirmationDialog("确定删除歌单「\(pendingDelete?.name ?? "")」吗？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) { confirmDeletePlaylist() }
            Button("取消", role: .cancel) {}
        }
        .atmusicNavigationDestination(for: LibraryRoute.self) { route in
            libraryDestination(route)
        }
    }
    }

    @ViewBuilder
    private func libraryDestination(_ route: LibraryRoute) -> some View {
        switch route {
        case .playlist(let playlist):
            PlaylistView(playlist: playlist)
                .environmentObject(player)
                .environmentObject(auth)
                .environmentObject(theme)
        }
    }

    private func openRoute(_ route: LibraryRoute) {
        if #available(iOS 16.0, *) {
            navigationPath.append(route)
        } else {
            legacyRoute = route
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                    libraryTitleButton
                    Text(librarySubtitle)
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicComment)
                }
                Spacer()
                HStack(spacing: 10) {
                    if !hideSortButton {
                        GlassIconButton(systemName: "arrow.up.arrow.down") {
                            ATMusicHaptics.tap()
                            showSectionSort = true
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private var appleHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center) {
                libraryTitleButton
                Spacer(minLength: 12)
                Button(action: onOpenProfile) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.atmusicComment.opacity(0.72))
                        .frame(width: 36, height: 36)
                        .background { ATMusicGlass(shape: Circle()) }
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("我的")
            }
            Text(librarySubtitle)
                .font(ATMusicFont.appFont(12, .medium))
                .foregroundStyle(Color.atmusicComment)
                .lineLimit(1)
            Rectangle()
                .fill(Color.atmusicLabel.opacity(0.10))
                .frame(height: 1)
        }
        .padding(.top, 4)
    }

    private var librarySubtitle: String {
        atmusicLocalized("平台同步 · 本地歌单 · 高级管理", "Platform sync · Local playlists · Advanced management")
    }

    private var libraryTitleButton: some View {
        Text("歌单管理")
            .font(ATMusicFont.appFont(isNativeClean ? 34 : 30, .bold))
            .foregroundStyle(Color.atmusicLabel)
    }

    // MARK: - 聚合歌单

    private var aggregatedPlaylistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "我的歌单")
            VStack(spacing: 12) {
                ForEach(libraryProviders) { provider in
                    compactProviderBlock(provider)
                }
            }
        }
    }

    @ViewBuilder
    private func compactProviderBlock(_ provider: LibraryProvider) -> some View {
        let all = playlistsForProvider(provider)
        let expanded = expandedPlaylistProviders.contains(provider)
        let visible = expanded ? all : Array(all.prefix(4))
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                providerIcon(provider)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(provider.rawValue))
                        .font(ATMusicFont.appFont(15, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text(providerStatusText(provider, count: all.count))
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                }
                Spacer(minLength: 8)
                if (provider == .netease && auth.isLoggedIn) || (provider == .qq && qqAuth.isLoggedIn) {
                    Button {
                        source = provider
                        newPlaylistName = ""
                        showCreatePlaylist = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.atmusicAmber)
                            .frame(width: 32, height: 32)
                            .background { ATMusicGlass(shape: Circle()) }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider().overlay(Color.atmusicComment.opacity(0.12))

            if providerIsLoading(provider) {
                HStack { Spacer(); ProgressView().tint(Color.atmusicAmber); Spacer() }
                    .padding(.vertical, 18)
            } else if !providerIsAvailable(provider) {
                compactProviderEmpty(providerLoginText(provider), icon: provider.icon)
            } else if all.isEmpty {
                compactProviderEmpty(providerEmptyText(provider), icon: provider.icon)
            } else {
                ForEach(visible) { playlist in
                    Button {
                        source = provider
                        openRoute(LibraryRoute.playlist(playlist))
                    } label: {
                        HStack(spacing: 11) {
                            CoverImage(url: playlist.coverURL, size: 46, cornerRadius: 10)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(playlist.name)
                                    .font(ATMusicFont.appFont(14, .medium))
                                    .foregroundStyle(Color.atmusicLabel)
                                    .lineLimit(1)
                                Text(atmusicSongCountText(playlist.trackCount))
                                    .font(ATMusicFont.appFont(11))
                                    .foregroundStyle(Color.atmusicComment)
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.atmusicComment.opacity(0.55))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if provider == .netease || provider == .qq {
                            Button(role: .destructive) {
                                source = provider
                                requestDelete(playlist)
                            } label: {
                                Label("删除歌单", systemImage: "trash")
                            }
                        }
                    }
                    if playlist.id != visible.last?.id {
                        Divider().overlay(Color.atmusicComment.opacity(0.10)).padding(.leading, 70)
                    }
                }

                if all.count > 4 {
                    Divider().overlay(Color.atmusicComment.opacity(0.10))
                    Button {
                        withAnimation {
                            if expanded { expandedPlaylistProviders.remove(provider) }
                            else { expandedPlaylistProviders.insert(provider) }
                        }
                    } label: {
                        HStack {
                            Text(expanded ? "收起" : "查看全部 \(all.count) 个")
                            Spacer()
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        }
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background { ATMusicGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)) }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .atmusicCardShadow(radius: isNativeClean ? 2 : 7, y: isNativeClean ? 1 : 3)
    }

    @ViewBuilder
    private func providerIcon(_ provider: LibraryProvider) -> some View {
        if let brand = provider.brandImageName {
            Image(brand)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .padding(7)
                .background { ATMusicGlass(shape: RoundedRectangle(cornerRadius: 10, style: .continuous)) }
        } else {
            Image(systemName: provider.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.atmusicAmber)
                .frame(width: 38, height: 38)
                .background { ATMusicGlass(shape: RoundedRectangle(cornerRadius: 10, style: .continuous)) }
        }
    }

    private func compactProviderEmpty(_ text: String, icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(Color.atmusicComment.opacity(0.65))
            Text(text)
                .font(ATMusicFont.appFont(12))
                .foregroundStyle(Color.atmusicComment)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private func playlistsForProvider(_ provider: LibraryProvider) -> [Playlist] {
        switch provider {
        case .netease: return orderedNeteasePlaylists
        case .qq: return orderedQQPlaylists
        case .kugou: return orderedKugouPlaylists
        case .synology: return synologyPlaylists
        }
    }

    private func providerIsLoading(_ provider: LibraryProvider) -> Bool {
        switch provider {
        case .netease: return false
        case .qq: return qqLoading
        case .kugou: return kugouLoading
        case .synology: return synologyLoading
        }
    }

    private func providerIsAvailable(_ provider: LibraryProvider) -> Bool {
        switch provider {
        case .netease: return auth.isLoggedIn
        case .qq: return qqAuth.isLoggedIn
        case .kugou: return kugouAuth.isLoggedIn
        case .synology: return synology.isLoggedIn
        }
    }

    private func providerStatusText(_ provider: LibraryProvider, count: Int) -> String {
        guard providerIsAvailable(provider) else { return "未登录" }
        if providerIsLoading(provider) { return "正在同步…" }
        return "已同步 \(count) 个歌单"
    }

    private func providerLoginText(_ provider: LibraryProvider) -> String {
        switch provider {
        case .netease: return "登录网易云音乐后显示歌单"
        case .qq: return "登录 QQ 音乐后显示歌单"
        case .kugou: return "登录酷狗音乐后显示歌单"
        case .synology: return "连接群晖 Audio Station 后显示歌单"
        }
    }

    private func providerEmptyText(_ provider: LibraryProvider) -> String {
        "暂无歌单"
    }

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "我的歌单", trailing: auth.isLoggedIn ? "新建" : nil) {
                if auth.isLoggedIn {
                    ATMusicHaptics.tap()
                    newPlaylistName = ""
                    showCreatePlaylist = true
                }
            }
            if !auth.isLoggedIn {
                EmptyStateView(icon: "music.note.list", text: "登录网易云音乐后即可查看你的歌单")
            } else if auth.playlists.isEmpty {
                createPlaylistCard
            } else {
                VStack(spacing: 0) {
                    ForEach(orderedNeteasePlaylists) { playlist in
                        Button {
                            openRoute(LibraryRoute.playlist(playlist))
                        } label: {
                            HStack(spacing: 12) {
                                CoverImage(url: playlist.coverURL, size: 56, cornerRadius: 12)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(playlist.name)
                                        .font(ATMusicFont.appFont(15, .medium))
                                        .foregroundStyle(Color.atmusicLabel)
                                        .lineLimit(1)
                                    Text(atmusicSongCountText(playlist.trackCount))
                                        .font(ATMusicFont.appFont(12))
                                        .foregroundStyle(Color.atmusicComment)
                                }
                                Spacer(minLength: 8)
                                if !isNativeClean { SourceBadgeView(source: playlist.source, compact: true) }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.atmusicComment.opacity(0.6))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                ATMusicHaptics.tap()
                                requestDelete(playlist)
                            } label: {
                                Label("删除歌单", systemImage: "trash")
                            }
                        }
                        Divider().overlay(Color.atmusicComment.opacity(0.12))
                    }
                    // 新建歌单行
                    Button {
                        ATMusicHaptics.tap()
                        newPlaylistName = ""
                        showCreatePlaylist = true
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
                                    .foregroundStyle(Color.atmusicComment.opacity(0.45))
                                    .frame(width: 56, height: 56)
                                Image(systemName: "plus")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(Color.atmusicComment)
                            }
                            Text("新建歌单")
                                .font(ATMusicFont.appFont(15, .medium))
                                .foregroundStyle(Color.atmusicComment)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 6)
                .background {
                                        ATMusicGlass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .atmusicCardShadow(radius: 9, y: 3)
            }
        }
    }

    private var createPlaylistCard: some View {
        Button {
            ATMusicHaptics.tap()
            newPlaylistName = ""
            showCreatePlaylist = true
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .foregroundStyle(Color.atmusicComment.opacity(0.45))
                        .frame(width: 160, height: 160)
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Color.atmusicComment)
                }
                Text("新建歌单")
                    .font(ATMusicFont.appFont(12, .medium))
                    .foregroundStyle(Color.atmusicComment)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background {
                                ATMusicGlass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .buttonStyle(.plain)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "最近播放", trailing: "查看全部") {
                showHistory = true
            }
            if player.history.isEmpty {
                EmptyStateView(icon: "clock.arrow.circlepath", text: "暂无播放记录")
            } else {
                VStack(spacing: 0) {
                    ForEach(player.history.prefix(5), id: \.identityKey) { song in
                        SongCell(song: song, suppressNativeCleanRowGlass: isNativeClean) {
                            playFromHistory(song)
                        }
                        Divider().overlay(Color.atmusicComment.opacity(0.15))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background {
                                        ATMusicGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .atmusicCardShadow(radius: 8, y: 3)
            }
        }
    }

    /// 平台选择（网易云 / QQ音乐，样式与主页一致）
    private var providerPicker: some View {
        HStack(spacing: 4) {
            ForEach(libraryProviders) { p in
                Button {
                    ATMusicHaptics.tap()
                    if source != p { source = p }
                } label: {
                    HStack(spacing: 6) {
                        if let brandImageName = p.brandImageName {
                            Image(brandImageName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: p.icon)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(LocalizedStringKey(p.rawValue))
                            .font(ATMusicFont.appFont(13, .semibold))
                    }
                    .atmusicSelectionForeground(selected: source == p, accent: .atmusicAmber)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background {
                        ATMusicSelectableSurface(
                            selected: source == p,
                            shape: Capsule(),
                            accent: .atmusicAmber
                        )
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
                .background { ATMusicSurface(shape: Capsule()) }
                .clipShape(Capsule())
        .atmusicCardShadow(radius: isNativeClean ? 1 : 6, y: isNativeClean ? 0.5 : 2)
    }

    private func refreshAllSources(force: Bool) async {
        for provider in libraryProviders {
            switch provider {
            case .netease:
                await auth.loadLibrary(force: force)
            case .qq:
                await loadQQPlaylists(force: force)
            case .kugou:
                await loadKugouPlaylists(force: force)
            case .synology:
                await loadSynologyPlaylists(force: force)
            }
        }
    }

    private func refreshCurrentSource(force: Bool) async {
        switch source {
        case .netease:
            await auth.loadLibrary(force: force)
        case .qq:
            await loadQQPlaylists(force: force)
        case .kugou:
            await loadKugouPlaylists(force: force)
        case .synology:
            break
        }
    }

    /// QQ 模式整体内容：用户歌单（创建 + 收藏同步）
    private var qqSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            qqPlaylistsSection
        }
    }

    /// 酷狗模式整体内容：只保留同步歌单
    private var kugouSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            kugouPlaylistsSection
        }
    }

    private var qqPlaylistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "我的 QQ 歌单", trailing: qqAuth.isLoggedIn ? (qqPlaylists.isEmpty ? "新建" : "新建 · \(qqPlaylists.count) 个") : nil) {
                if qqAuth.isLoggedIn {
                    ATMusicHaptics.tap()
                    newPlaylistName = ""
                    showCreatePlaylist = true
                }
            }
            if !qqAuth.isLoggedIn {
                EmptyStateView(icon: "music.note.list", text: "登录 QQ 音乐后即可查看你的歌单")
            } else if qqLoading {
                LoadingStateView()
            } else if qqPlaylists.isEmpty {
                EmptyStateView(icon: "music.note.list", text: "暂无 QQ 歌单")
            } else {
                VStack(spacing: 0) {
                    ForEach(orderedQQPlaylists) { playlist in
                        Button {
                            openRoute(LibraryRoute.playlist(playlist))
                        } label: {
                            HStack(spacing: 12) {
                                CoverImage(url: playlist.coverURL, size: 56, cornerRadius: 12)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(playlist.name)
                                        .font(ATMusicFont.appFont(15, .medium))
                                        .foregroundStyle(Color.atmusicLabel)
                                        .lineLimit(1)
                                    Text(atmusicSongCountText(playlist.trackCount))
                                        .font(ATMusicFont.appFont(12))
                                        .foregroundStyle(Color.atmusicComment)
                                }
                                Spacer(minLength: 8)
                                if !isNativeClean { SourceBadgeView(source: playlist.source, compact: true) }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.atmusicComment.opacity(0.6))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                ATMusicHaptics.tap()
                                requestDelete(playlist)
                            } label: {
                                Label("删除歌单", systemImage: "trash")
                            }
                        }
                        Divider().overlay(Color.atmusicComment.opacity(0.12))
                    }
                }
                .padding(.vertical, 6)
                .background {
                                        ATMusicGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .atmusicCardShadow(radius: 8, y: 3)
            }
        }
    }

    private var kugouPlaylistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "我的酷狗歌单", trailing: kugouAuth.isLoggedIn ? "\(kugouPlaylists.count) 个" : nil)
            if !kugouAuth.isLoggedIn {
                EmptyStateView(icon: "music.note.list", text: "登录酷狗音乐后即可同步云端歌单")
            } else if kugouLoading {
                LoadingStateView()
            } else if kugouPlaylists.isEmpty {
                EmptyStateView(icon: "music.note.list", text: "暂未同步到酷狗歌单，下拉刷新试试")
            } else {
                VStack(spacing: 0) {
                    ForEach(orderedKugouPlaylists) { playlist in
                        Button {
                            openRoute(LibraryRoute.playlist(playlist))
                        } label: {
                            HStack(spacing: 12) {
                                CoverImage(url: playlist.coverURL, size: 56, cornerRadius: 12)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(playlist.name)
                                        .font(ATMusicFont.appFont(15, .medium))
                                        .foregroundStyle(Color.atmusicLabel)
                                        .lineLimit(1)
                                    Text(atmusicSongCountText(playlist.trackCount))
                                        .font(ATMusicFont.appFont(12))
                                        .foregroundStyle(Color.atmusicComment)
                                }
                                Spacer(minLength: 8)
                                if !isNativeClean { SourceBadgeView(source: playlist.source, compact: true) }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.atmusicComment.opacity(0.6))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Color.atmusicComment.opacity(0.12))
                    }
                }
                .padding(.vertical, 6)
                .background {
                    ATMusicGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .atmusicCardShadow(radius: 8, y: 3)
            }
        }
    }

    // MARK: - 歌单新建 / 删除

    private func loadQQPlaylists(force: Bool = false) async {
        guard qqAuth.isLoggedIn else {
            qqPlaylists = []
            qqLoading = false
            return
        }
        let cache = SyncedPlaylistCache.shared
        if qqPlaylists.isEmpty,
           let cached = cache.cachedPlaylists(source: .qq, accountID: qqCacheAccountID) {
            qqPlaylists = cached.playlists
            qqSavedAt = cached.savedAt
        }
        // 持久化缓存仍新鲜时直接展示；下拉刷新会跳过缓存。
        if !force, !qqPlaylists.isEmpty, Date().timeIntervalSince(qqSavedAt) < cache.playlistTTL { return }
        qqLoading = qqPlaylists.isEmpty
        let list = (try? await QQMusicAPI.shared.userPlaylists(uin: qqAuth.uin)) ?? []
        if !list.isEmpty {
            qqPlaylists = list
            cache.savePlaylists(list, source: .qq, accountID: qqCacheAccountID)
        }
        await favorites.syncQQFromCloud()
        if !list.isEmpty { qqSavedAt = Date() }
        qqLoading = false
        // 封面兜底：歌单封面缺失时默认取第一首歌曲封面（列表先展示，封面后台补齐）
        if !list.isEmpty { await fillQQPlaylistCovers(list) }
        if !qqPlaylists.isEmpty {
            cache.savePlaylists(qqPlaylists, source: .qq, accountID: qqCacheAccountID)
        }
    }

    private func loadKugouPlaylists(force: Bool = false) async {
        guard kugouAuth.isLoggedIn else {
            kugouPlaylists = []
            kugouLoading = false
            return
        }
        let cache = SyncedPlaylistCache.shared
        if kugouPlaylists.isEmpty,
           let cached = cache.cachedPlaylists(source: .kugou, accountID: kugouCacheAccountID) {
            kugouPlaylists = cached.playlists
            kugouSavedAt = cached.savedAt
        }
        if !force, !kugouPlaylists.isEmpty, Date().timeIntervalSince(kugouSavedAt) < cache.playlistTTL { return }
        kugouLoading = kugouPlaylists.isEmpty
        do {
            let list = try await KugouMusicAPI.shared.userPlaylists()
            if !list.isEmpty {
                kugouPlaylists = list
                kugouSavedAt = Date()
                cache.savePlaylists(list, source: .kugou, accountID: kugouCacheAccountID)
            }
        } catch {
            ATMusicLogger.shared.log("酷狗歌单同步失败：\(error.localizedDescription)", level: .error)
            if kugouPlaylists.isEmpty { kugouPlaylists = [] }
        }
        kugouLoading = false
    }

    private func loadSynologyPlaylists(force: Bool = false) async {
        guard synology.isLoggedIn else {
            synologyPlaylists = []
            synologyLoading = false
            return
        }
        if !force, !synologyPlaylists.isEmpty { return }
        synologyLoading = synologyPlaylists.isEmpty
        do {
            synologyPlaylists = try await synology.allPlaylists()
        } catch {
            ATMusicLogger.shared.log("群晖歌单同步失败：\(error.localizedDescription)", level: .warn)
            if synologyPlaylists.isEmpty { synologyPlaylists = [] }
        }
        synologyLoading = false
    }

    private func fillQQPlaylistCovers(_ list: [Playlist]) async {
        let missing = list.filter { $0.coverURL == nil }
        guard !missing.isEmpty else { return }
        var covers: [Int: URL] = [:]
        await withTaskGroup(of: (Int, URL?).self) { group in
            for playlist in missing {
                group.addTask {
                    let cover = try? await QQMusicAPI.shared.firstSongCover(listID: playlist.id)
                    return (playlist.id, cover)
                }
            }
            for await (id, url) in group {
                if let url { covers[id] = url }
            }
        }
        for i in qqPlaylists.indices where qqPlaylists[i].coverURL == nil {
            if let url = covers[qqPlaylists[i].id] { qqPlaylists[i].coverURL = url }
        }
    }

    private func createPlaylist() {
        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            ToastCenter.shared.show("请输入歌单名称")
            return
        }
        switch source {
        case .netease:
            guard auth.isLoggedIn else {
                ToastCenter.shared.show("请先登录后再创建歌单")
                return
            }
            Task {
                do {
                    _ = try await NetEaseAPI.shared.createPlaylist(name: name)
                    ToastCenter.shared.show("歌单「\(name)」已创建")
                    newPlaylistName = ""
                    await auth.loadLibrary()
                } catch {
                    ToastCenter.shared.show("创建失败：\(error.localizedDescription)")
                }
            }
        case .qq:
            guard qqAuth.isLoggedIn else {
                ToastCenter.shared.show("请先登录 QQ 音乐后再创建歌单")
                return
            }
            Task {
                do {
                    let ok = try await QQMusicAPI.shared.createPlaylist(name: name)
                    if ok {
                        ToastCenter.shared.show("歌单「\(name)」已创建")
                        newPlaylistName = ""
                        await loadQQPlaylists(force: true)
                    } else {
                        ToastCenter.shared.show("创建失败，请确认已登录 QQ 音乐")
                    }
                } catch {
                    ToastCenter.shared.show("创建失败：\(error.localizedDescription)")
                }
            }
        case .kugou:
            ToastCenter.shared.show("酷狗歌单暂不支持新建")
        case .synology:
            ToastCenter.shared.show("群晖歌单请在 Audio Station 中管理")
        }
    }

    private func requestDelete(_ playlist: Playlist) {
        pendingDelete = playlist
        showDeleteConfirm = true
    }

    private func confirmDeletePlaylist() {
        guard let playlist = pendingDelete else { return }
        switch source {
        case .netease:
            Task {
                do {
                    let ok = try await NetEaseAPI.shared.deletePlaylist(id: playlist.id)
                    if ok {
                        ToastCenter.shared.show("已删除歌单「\(playlist.name)」")
                        await auth.loadLibrary()
                    } else {
                        ToastCenter.shared.show("删除失败，请稍后再试")
                    }
                } catch {
                    ToastCenter.shared.show("删除失败：\(error.localizedDescription)")
                }
            }
        case .qq:
            Task {
                do {
                    let ok = try await QQMusicAPI.shared.deletePlaylist(dirid: playlist.id)
                    if ok {
                        ToastCenter.shared.show("已删除歌单「\(playlist.name)」")
                        await loadQQPlaylists(force: true)
                    } else {
                        ToastCenter.shared.show("删除失败，请确认已登录 QQ 音乐")
                    }
                } catch {
                    ToastCenter.shared.show("删除失败：\(error.localizedDescription)")
                }
            }
        case .kugou:
            ToastCenter.shared.show("酷狗歌单暂不支持删除")
        case .synology:
            ToastCenter.shared.show("群晖歌单请在 Audio Station 中管理")
        }
    }

    private func playFromHistory(_ song: Song) {
        if let index = player.history.firstIndex(of: song) {
            player.play(songs: player.history, startAt: index)
        }
    }
}
