import SwiftUI
import UIKit

private enum DiscoverRoute: Hashable {
    case topList(TopList)
    case playlist(Playlist)
    case qqTopList(QQTopInfo)
    case kugouTopList(KugouTopInfo)
    case dailySongs([Song])
}

struct DiscoverView: View {
    var onOpenProfile: () -> Void = {}
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared

    @State private var topLists: [TopList] = []
    @State private var dailySongs: [Song] = []
    @State private var personalized: [Playlist] = []

    @State private var loading = true
    @State private var errorMessage: String?
    @State private var navigationPath: [DiscoverRoute] = []
    @State private var legacyRoute: DiscoverRoute?
    @State private var recommendationActionLoading: String?
    @State private var showSectionSort = false
    /// 主页板块顺序（每日推荐 / 排行榜 / 歌单广场，可自定义）
    @State private var homeOrder = SectionOrderStore.load(SectionOrderStore.homeKey, defaults: SectionOrderStore.homeDefaults)

    /// 三个平台都保留每日推荐、排行榜和歌单板块，QQ 歌单板块展示官网推荐的热门歌单。
    private var availableSections: [String] { SectionOrderStore.homeDefaults }
    /// 首页数据源：记住上次选择，下次打开仍保持该平台（默认网易云）
    @AppStorage("atmusic.homeSource") private var homeSourceRaw = SearchProvider.netease.rawValue
    /// 首页范围：聚合全部音源，或锁定单个平台。
    @AppStorage("atmusic.homeScope") private var homeScopeRaw = "single"
    @AppStorage("atmusic.home18DefaultApplied") private var home18DefaultApplied = false
    @AppStorage("atmusic.homeHideUsername") private var homeHideUsername = false
    @AppStorage("atmusic.pauseHomeRendering") private var homeRenderingPaused = false
    @AppStorage("atmusic.homeHeaderHideSort") private var homeHeaderHideSort = false
    @AppStorage("atmusic.homeHeaderHideRefresh") private var homeHeaderHideRefresh = true
    @AppStorage("atmusic.homeWallpaperBlur") private var homeWallpaperBlur = 0.0
    @AppStorage(PlatformPreferenceStore.hidePickerKey) private var hidePlatformPicker = false
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    @AppStorage("atmusic.showSongVIPBadge") private var showSongVIPBadge = true
    private var homeProviders: [SearchProvider] { platformPrefs.enabledSearchProviders }
    /// 首页数据源：网易云 / QQ音乐（与搜索页同一控件样式）
    private var source: SearchProvider {
        guard let saved = SearchProvider(rawValue: homeSourceRaw), homeProviders.contains(saved) else {
            return homeProviders.first ?? .netease
        }
        return saved
    }
    private var isHomeAggregate: Bool { homeScopeRaw == "aggregate" }
    private var isNativeClean: Bool { ATMusicUIStyle(rawValue: uiStyleRaw) == .nativeClean }

    @State private var qqTopLists: [QQTopInfo] = []
    @State private var kugouTopLists: [KugouTopInfo] = []
    /// 歌单广场展开状态：收起显示前 6，展开显示全部
    @State private var playlistsExpanded = false
    /// 聚合首页各平台歌单独立展开；展开后直接在当前页面双列显示。
    @State private var expandedAggregatePlaylistSources = Set<SongSource>()
    /// 首页加载去重：SwiftUI 视图刷新时 .task 可能被重复触发，避免网络请求风暴。
    @State private var activeLoadKey: String?
    @State private var lastLoadedKey = ""
    @State private var lastLoadedAt = Date.distantPast
    /// 首次启动免责声明：确认进入后若加载失败自动刷新
    @AppStorage("atmusic.disclaimerAccepted") private var disclaimerAccepted = false
    /// 网易云歌单广场当前分类（「全部」展示官方精品歌单）
    /// 官方歌单分类列表

    var body: some View {
        let _ = theme.accent
        ATMusicNavigationStackWithPath(path: $navigationPath) {
        ZStack {
            // 主页背景：壁纸/背景色永远在发现页生效（homeMode），同步开启时其他页面也生效
            GlassBackdrop(customColor: theme.customBackground, homeMode: true, wallpaperBlur: CGFloat(homeWallpaperBlur))
            // 实例级 UITabBar 清透风格（固定全透明，无需调节）
            TabBarAppearanceConfigurator()
            if #unavailable(iOS 16.0) {
                NavigationLink(
                    destination: discoverDestination(legacyRoute ?? .dailySongs([])),
                    isActive: Binding(
                        get: { legacyRoute != nil },
                        set: { if !$0 { legacyRoute = nil } }
                    )
                ) {
                    EmptyView()
                }
                .hidden()
            }
            ScrollView(.vertical, showsIndicators: false) {
                if !homeRenderingPaused {
                    VStack(alignment: .leading, spacing: isNativeClean ? 20 : 26) {
                        header
                        if !hidePlatformPicker {
                            providerPicker
                        }
                        if !isHomeAggregate && source == .synology {
                            SynologyAppleHomeSection()
                                .environmentObject(theme)
                                .environmentObject(player)
                        } else if let errorMessage {
                            ErrorStateView(message: errorMessage) {
                                Task { await load(force: true) }
                            }
                        } else if loading {
                            LoadingStateView()
                        } else {
                            // 板块按用户自定义顺序渲染（可拖拽排序）
                            ForEach(homeOrder.filter { availableSections.contains($0) }, id: \.self) { key in
                                switch key {
                                case "每日推荐":
                                    if isHomeAggregate || source == .netease || source == .kugou || !dailySongs.isEmpty {
                                        dailySection
                                    }
                                case "排行榜":
                                    if hasRankData { topListsSection }
                                case "歌单广场":
                                    if isHomeAggregate || !personalized.isEmpty {
                                        personalizedSection
                                    }
                                default:
                                    EmptyView()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, isNativeClean ? 24 : 16)
                    .padding(.top, isNativeClean ? 32 : 8)
                    .padding(.bottom, 190)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
            }
            .atmusicScrollIndicatorsHidden()
            .refreshable {
                guard !homeRenderingPaused else { return }
                await load(force: true)
            }
            .task(id: "\(homeScopeRaw)-\(source.rawValue)-\(homeRenderingPaused)") {
                guard !homeRenderingPaused else { return }
                await load(force: false)
            }
            .onAppear {
                if !home18DefaultApplied {
                    homeScopeRaw = "single"
                    if platformPrefs.isEnabled(SearchProvider.netease) {
                        homeSourceRaw = SearchProvider.netease.rawValue
                    }
                    home18DefaultApplied = true
                }
                guard !homeRenderingPaused else { return }
                guard let saved = SearchProvider(rawValue: homeSourceRaw), homeProviders.contains(saved) else {
                    homeSourceRaw = (homeProviders.first ?? .netease).rawValue
                    return
                }
            }
            // 仅在用户实际修改平台显示时刷新。计算型 publisher 会在视图
            // 重建后回放当前值，曾导致聚合首页重复请求并在滚动时闪烁。
            .onChange(of: platformPrefs.selectedRaw) { _, _ in
                guard !homeRenderingPaused else { return }
                let next = platformPrefs.ensureVisible(source)
                if next != source {
                    homeSourceRaw = next.rawValue
                }
                let enabledSources = Set(homeProviders.map(\.songSource))
                if isHomeAggregate {
                    dailySongs.removeAll { !enabledSources.contains($0.source) }
                    personalized.removeAll { !enabledSources.contains($0.source) }
                    if !enabledSources.contains(.netease) { topLists = [] }
                    if !enabledSources.contains(.qq) { qqTopLists = [] }
                    if !enabledSources.contains(.kugou) { kugouTopLists = [] }
                    Task { await load(force: true) }
                }
            }
            .onChange(of: source) { _, _ in
                guard !homeRenderingPaused else { return }
                homeOrder = SectionOrderStore.load(SectionOrderStore.homeKey, defaults: availableSections)
            }
            .onChange(of: disclaimerAccepted) { _, accepted in
                guard !homeRenderingPaused else { return }
                // 免责声明确认进入后：若首页加载失败则自动刷新（无需手动下拉）
                if accepted, errorMessage != nil {
                    Task { await load(force: true) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .atmusicNeteaseLoginDidUpdate)) { _ in
                guard !homeRenderingPaused else { return }
                guard platformPrefs.isEnabled(SearchProvider.netease) else { return }
                reloadAfterLoginUpdate(.netease)
            }
            .onReceive(NotificationCenter.default.publisher(for: .atmusicQQLoginDidUpdate)) { _ in
                guard !homeRenderingPaused else { return }
                guard platformPrefs.isEnabled(SearchProvider.qq) else { return }
                reloadAfterLoginUpdate(.qq)
            }
            .onReceive(NotificationCenter.default.publisher(for: .atmusicKugouLoginDidUpdate)) { _ in
                guard !homeRenderingPaused else { return }
                guard platformPrefs.isEnabled(SearchProvider.kugou) else { return }
                reloadAfterLoginUpdate(.kugou)
            }
            .sheet(isPresented: $showSectionSort) {
                SectionOrderSheet(
                    title: "主页板块排序",
                    sections: availableSections,
                    order: $homeOrder,
                    platformOrder: Binding(
                        get: { platformPrefs.orderedRaw },
                        set: { platformPrefs.orderedRaw = $0 }
                    )
                )
                    .onDisappear { SectionOrderStore.save(SectionOrderStore.homeKey, homeOrder) }
            }
        }
            .atmusicNavigationDestination(for: DiscoverRoute.self) { route in
                discoverDestination(route)
            }
        }
    }

    @ViewBuilder
    private func discoverDestination(_ route: DiscoverRoute) -> some View {
        switch route {
        case .topList(let topList):
            TopListDetailView(topList: topList)
                .environmentObject(player)
                .environmentObject(auth)
        case .playlist(let playlist):
            PlaylistView(playlist: playlist)
                .environmentObject(player)
                .environmentObject(auth)
        case .qqTopList(let info):
            QQTopListDetailView(topID: info.id, name: info.name)
                .environmentObject(player)
                .environmentObject(auth)
        case .kugouTopList(let info):
            KugouTopListDetailView(topList: info)
                .environmentObject(player)
                .environmentObject(auth)
        case .dailySongs(let songs):
            DailySongsSheet(songs: songs)
                .environmentObject(player)
                .environmentObject(auth)
        }
    }

    private func openRoute(_ route: DiscoverRoute) {
        if #available(iOS 16.0, *) {
            navigationPath.append(route)
        } else {
            legacyRoute = route
        }
    }

    /// 顶部问候区：大标题 + 刷新按钮
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Menu {
                        homePlatformSelectionMenu
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if !isHomeAggregate, let imageName = source.brandImageName {
                                Image(imageName)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: isNativeClean ? 25 : 21, height: isNativeClean ? 25 : 21)
                            } else if isHomeAggregate {
                                Image(systemName: "square.stack.3d.up.fill")
                                    .font(.system(size: isNativeClean ? 20 : 17, weight: .semibold))
                                    .foregroundStyle(Color.atmusicAmber)
                            }
                            Text(LocalizedStringKey(homeHeaderTitle))
                                .font(ATMusicFont.greetingFont(isNativeClean ? 38 : 30, .bold))
                                .foregroundStyle(Color.atmusicLabel)
                            Image(systemName: "chevron.down")
                                .font(.system(size: isNativeClean ? 14 : 12, weight: .bold))
                                .foregroundStyle(Color.atmusicComment)
                        }
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel("切换主页平台")
                    if !homeHideUsername {
                        Text(homeHeaderSubtitle)
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicComment)
                    }
                }
                Spacer()
                HStack(spacing: 10) {
                    if isNativeClean {
                        Button {
                            ATMusicHaptics.tap()
                            onOpenProfile()
                        } label: {
                            AsyncImage(url: auth.user?.avatarURL) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().scaledToFill()
                                } else {
                                    Image(systemName: "person.crop.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(Color.atmusicComment)
                                }
                            }
                            .frame(width: 42, height: 42)
                            .clipShape(Circle())
                            .background { ATMusicGlass(shape: Circle()) }
                        }
                        .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                        .accessibilityLabel("我的")
                    }
                    if !homeHeaderHideSort {
                        GlassIconButton(systemName: "arrow.up.arrow.down") {
                            ATMusicHaptics.tap()
                            showSectionSort = true
                        }
                    }
                    if !homeHeaderHideRefresh {
                        GlassIconButton(systemName: "arrow.clockwise") {
                            ATMusicHaptics.tap()
                            Task { await load(force: true) }
                        }
                    }
                }
            }
        }
        .padding(.top, isNativeClean ? 4 : 8)
    }

    /// 主页平台切换：所有 UI 风格使用同一套紧凑胶囊。
    private var providerPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                homeProviderPill(
                    title: "聚合",
                    systemImage: "square.stack.3d.up.fill",
                    brandImageName: nil,
                    selected: isHomeAggregate,
                    tint: .atmusicAmber
                ) {
                    ATMusicHaptics.select()
                    homeScopeRaw = "aggregate"
                }

                ForEach(homeProviders) { provider in
                    homeProviderPill(
                        title: provider.rawValue,
                        systemImage: provider.brandImageName == nil ? provider.icon : nil,
                        brandImageName: provider.brandImageName,
                        selected: !isHomeAggregate && source == provider,
                        tint: .atmusicAmber
                    ) {
                        ATMusicHaptics.select()
                        homeScopeRaw = "single"
                        homeSourceRaw = provider.rawValue
                    }
                }
            }
            .padding(.vertical, 2)
            .padding(.trailing, isNativeClean ? 24 : 4)
        }
        .atmusicScrollIndicatorsHidden()
    }

    private func homeProviderPill(
        title: String,
        systemImage: String?,
        brandImageName: String?,
        selected: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let brandImageName {
                    Image(brandImageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15, height: 15)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(LocalizedStringKey(title))
                    .font(ATMusicFont.appFont(13, .semibold))
            }
            .atmusicSelectionForeground(selected: selected, accent: tint)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background {
                ATMusicSelectableSurface(selected: selected, shape: Capsule(), accent: tint)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.96))
    }

    private var homeHeaderTitle: String {
        if isHomeAggregate { return "聚合" }
        return source.rawValue
    }

    private var homeHeaderSubtitle: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let greeting: String
        switch hour {
        case 5..<12: greeting = "早上好"
        case 12..<18: greeting = "下午好"
        default: greeting = "晚上好"
        }
        if let nickname = auth.user?.nickname, !nickname.isEmpty {
            return "\(greeting) · \(nickname)"
        }
        return greeting
    }

    /// 每日推荐封面右下角播放状态：当前播放中显示动态指示器，暂停显示暂停，其余显示播放
    @ViewBuilder
    private func dailyPlayStateBadge(for song: Song) -> some View {
        let isCurrent = player.currentSong?.identityKey == song.identityKey
        ZStack {
            if isCurrent && player.isPlaying {
                NowPlayingIndicator()
                    .frame(width: 24, height: 24)
                    .background(.black.opacity(0.45), in: Circle())
            } else {
                Image(systemName: isCurrent ? "pause.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(.black.opacity(0.45), in: Circle())
            }
        }
        .padding(7)
    }

    /// 网易云排行榜：全部榜单保留，热歌榜置顶
    private var neteaseTopLists: [TopList] {
        let preferredIDs = [19_723_756, 3_779_629, 2_884_035, 3_778_678, 60_198]
        let byID = Dictionary(uniqueKeysWithValues: topLists.map { ($0.id, $0) })
        let preferred = preferredIDs.compactMap { byID[$0] }
        if !preferred.isEmpty {
            return preferred
        }
        var list = topLists
        if let hot = list.first(where: { $0.name.contains("热歌榜") }),
           let idx = list.firstIndex(where: { $0.id == hot.id }), idx != 0 {
            list.remove(at: idx)
            list.insert(hot, at: 0)
        }
        return list
    }


    /// 当前平台是否有排行榜数据（网易云用 topLists，QQ 用 qqTopLists）
    private var hasRankData: Bool {
        if isHomeAggregate {
            return !topLists.isEmpty || !qqTopLists.isEmpty || !kugouTopLists.isEmpty
        }
        switch source {
        case .netease: return !topLists.isEmpty
        case .qq: return !qqTopLists.isEmpty
        case .kugou: return !kugouTopLists.isEmpty
        case .synology: return false
        }
    }

    // MARK: - 排行榜

    @ViewBuilder
    private var topListsSection: some View {
        if isHomeAggregate {
            aggregateTopListsSection
        } else {
            singlePlatformTopListsSection
        }
    }

    private var singlePlatformTopListsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "排行榜")
            if !hasRankData {
                EmptyStateView(icon: "chart.bar.xaxis", text: "排行榜暂时没有内容")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        switch source {
                        case .netease:
                            ForEach(neteaseTopLists, id: \.id) { item in
                                aggregateRankCard(name: atmusicChartName(item.name), subtitle: atmusicChartSubtitle(item.updateFrequency), coverURL: item.coverURL) {
                                    openRoute(DiscoverRoute.topList(item))
                                }
                            }
                        case .qq:
                            ForEach(qqTopLists, id: \.id) { item in
                                aggregateRankCard(name: atmusicChartName(item.name), subtitle: atmusicChartSubtitle(item.subTitle), coverURL: item.coverURL) {
                                    openRoute(DiscoverRoute.qqTopList(item))
                                }
                            }
                        case .kugou:
                            ForEach(kugouTopLists, id: \.id) { item in
                                aggregateRankCard(name: atmusicChartName(item.name), subtitle: atmusicChartSubtitle(item.updateFrequency), coverURL: item.coverURL) {
                                    openRoute(DiscoverRoute.kugouTopList(item))
                                }
                            }
                        case .synology:
                            EmptyView()
                        }
                    }
                    .padding(.vertical, 2)
                }
                .padding(.trailing, isNativeClean ? -24 : 0)
            }
        }
        .id("rankTopSection")
    }

    private var aggregateTopListsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "聚合排行榜")
            VStack(alignment: .leading, spacing: 20) {
                if platformPrefs.isEnabled(SearchProvider.netease), !topLists.isEmpty {
                    aggregateRankRow(title: "网易云音乐") {
                        ForEach(neteaseTopLists, id: \.id) { item in
                            aggregateRankCard(name: atmusicChartName(item.name), subtitle: atmusicChartSubtitle(item.updateFrequency), coverURL: item.coverURL) {
                                openRoute(DiscoverRoute.topList(item))
                            }
                        }
                    }
                }
                if platformPrefs.isEnabled(SearchProvider.qq), !qqTopLists.isEmpty {
                    aggregateRankRow(title: "QQ音乐") {
                        ForEach(qqTopLists, id: \.id) { item in
                            aggregateRankCard(name: atmusicChartName(item.name), subtitle: atmusicChartSubtitle(item.subTitle), coverURL: item.coverURL) {
                                openRoute(DiscoverRoute.qqTopList(item))
                            }
                        }
                    }
                }
                if platformPrefs.isEnabled(SearchProvider.kugou), !kugouTopLists.isEmpty {
                    aggregateRankRow(title: "酷狗音乐") {
                        ForEach(kugouTopLists, id: \.id) { item in
                            aggregateRankCard(name: atmusicChartName(item.name), subtitle: atmusicChartSubtitle(item.updateFrequency), coverURL: item.coverURL) {
                                openRoute(DiscoverRoute.kugouTopList(item))
                            }
                        }
                    }
                }
            }
        }
    }

    private func aggregateRankRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(ATMusicFont.appFont(16, .bold))
                .foregroundStyle(Color.atmusicLabel)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    content()
                }
                .padding(.vertical, 2)
            }
            .padding(.trailing, isNativeClean ? -24 : 0)
        }
    }

    private func aggregateRankCard(name: String, subtitle: String, coverURL: URL?, action: @escaping () -> Void) -> some View {
        Button {
            ATMusicHaptics.tap()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                CoverImage(url: coverURL, size: isNativeClean ? 156 : 136, cornerRadius: 16)
                Text(name)
                    .font(ATMusicFont.appFont(isNativeClean ? 14 : 12, .medium))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(2)
                    .frame(width: isNativeClean ? 156 : 136, alignment: .leading)
                Text(subtitle)
                    .font(ATMusicFont.appFont(11, .medium))
                    .foregroundStyle(Color.atmusicComment)
                    .lineLimit(1)
                    .frame(width: isNativeClean ? 156 : 136, alignment: .leading)
            }
            .padding(8)
            .background {
                ATMusicGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.96))
    }


    // MARK: - 每日推荐

    @ViewBuilder
    private var dailySection: some View {
        if isHomeAggregate {
            aggregateRecommendationCards
        } else {
            singlePlatformRecommendationCards
        }
    }


    private var aggregateRecommendationCards: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "推荐")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    recommendationCard(
                        title: "跨平台推荐",
                        subtitle: dailyRecommendationSubtitle,
                        icon: "sparkles",
                        coverURL: dailySongs.first?.coverURL,
                        gradient: [Color(red: 0.23, green: 0.38, blue: 0.82), Color(red: 0.53, green: 0.28, blue: 0.77)],
                        loadingKey: nil
                    ) {
                        openDailyRecommendations()
                    }

                    if homeProviders.contains(.netease) {
                        recommendationCard(
                            title: "红心雷达",
                            subtitle: "网易云 · 根据红心歌曲持续发现",
                            icon: "heart.circle.fill",
                            coverURL: player.currentSong?.coverURL,
                            gradient: [Color(red: 0.84, green: 0.16, blue: 0.38), Color(red: 0.98, green: 0.43, blue: 0.35)],
                            loadingKey: "heartbeat"
                        ) {
                            startHeartbeatMode()
                        }

                        recommendationCard(
                            title: "私人漫游",
                            subtitle: "网易云 · 从喜欢的歌开始漫游",
                            icon: "wave.3.right.circle.fill",
                            coverURL: nil,
                            gradient: [Color(red: 0.16, green: 0.22, blue: 0.42), Color(red: 0.41, green: 0.28, blue: 0.65)],
                            loadingKey: "fm"
                        ) {
                            startPersonalFM()
                        }
                    }

                    if !homeProviders.contains(.netease), homeProviders.contains(.kugou) {
                        recommendationCard(
                            title: "私人漫游",
                            subtitle: "酷狗音乐 · 个性推荐",
                            icon: "wave.3.right.circle.fill",
                            coverURL: nil,
                            gradient: [Color(red: 0.08, green: 0.46, blue: 0.82), Color(red: 0.18, green: 0.72, blue: 0.72)],
                            loadingKey: "kugouFM"
                        ) {
                            startKugouPersonalFM()
                        }
                    }
                }
                .padding(.vertical, 3)
            }
            .padding(.trailing, isNativeClean ? -24 : 0)
        }
    }

    private var singlePlatformRecommendationCards: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "推荐")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    recommendationCard(
                        title: "每日推荐",
                        subtitle: dailyRecommendationSubtitle,
                        icon: "calendar",
                        coverURL: dailySongs.first?.coverURL,
                        gradient: [Color(red: 0.95, green: 0.36, blue: 0.28), Color(red: 0.96, green: 0.68, blue: 0.30)],
                        loadingKey: nil
                    ) {
                        openDailyRecommendations()
                    }

                    if source == .netease {
                        recommendationCard(
                            title: "红心雷达",
                            subtitle: "根据红心歌曲持续发现相似音乐",
                            icon: "heart.circle.fill",
                            coverURL: player.currentSong?.coverURL,
                            gradient: [Color(red: 0.84, green: 0.16, blue: 0.38), Color(red: 0.98, green: 0.43, blue: 0.35)],
                            loadingKey: "heartbeat"
                        ) {
                            startHeartbeatMode()
                        }

                        recommendationCard(
                            title: "私人漫游",
                            subtitle: "从喜欢的歌开始漫游",
                            icon: "wave.3.right.circle.fill",
                            coverURL: nil,
                            gradient: [Color(red: 0.16, green: 0.22, blue: 0.42), Color(red: 0.41, green: 0.28, blue: 0.65)],
                            loadingKey: "fm"
                        ) {
                            startPersonalFM()
                        }
                    } else if source == .kugou {
                        recommendationCard(
                            title: "私人漫游",
                            subtitle: "酷狗音乐个性推荐",
                            icon: "wave.3.right.circle.fill",
                            coverURL: nil,
                            gradient: [Color(red: 0.08, green: 0.46, blue: 0.82), Color(red: 0.18, green: 0.72, blue: 0.72)],
                            loadingKey: "kugouFM"
                        ) {
                            startKugouPersonalFM()
                        }
                    }
                }
                .padding(.vertical, 3)
            }
            .padding(.trailing, isNativeClean ? -24 : 0)
        }
    }


    private var dailyRecommendationSubtitle: String {
        if dailySongs.isEmpty {
            return atmusicLocalized("每天 6:00 更新", "Refreshes at 6:00 daily")
        }
        return String(format: atmusicLocalized("%d 首 · 每天 6:00 更新", "%d songs · refreshes at 6:00 daily"), dailySongs.count)
    }

    private func recommendationCard(
        title: String,
        subtitle: String,
        icon: String,
        coverURL: URL?,
        gradient: [Color],
        loadingKey: String?,
        cardSize: CGFloat? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let resolvedCardSize = cardSize ?? (isNativeClean ? 160 : 168)
        return Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                if let coverURL {
                    CoverImage(url: coverURL, size: resolvedCardSize, cornerRadius: isNativeClean ? 16 : 18)
                        .overlay {
                            LinearGradient(
                                colors: [.black.opacity(0.05), .black.opacity(0.62)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                } else {
                    RoundedRectangle(cornerRadius: isNativeClean ? 16 : 18, style: .continuous)
                        .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(alignment: .topTrailing) {
                            Circle()
                                .fill(.white.opacity(0.16))
                                .frame(width: 92, height: 92)
                                .blur(radius: 3)
                                .offset(x: 24, y: -26)
                        }
                        .overlay(alignment: .center) {
                            Image(systemName: icon)
                                .font(.system(size: 46, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.32))
                                .offset(x: 34, y: -18)
                        }
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .bold))
                        if let loadingKey, recommendationActionLoading == loadingKey {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.72)
                        }
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    Spacer(minLength: 0)
                    Text(LocalizedStringKey(title))
                        .font(ATMusicFont.appFont(isNativeClean ? 20 : 18, .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }
                .padding(14)
            }
            .frame(width: resolvedCardSize, height: resolvedCardSize)
            .clipShape(RoundedRectangle(cornerRadius: isNativeClean ? 16 : 18, style: .continuous))
            .shadow(color: Color.black.opacity(isNativeClean ? 0.06 : 0.12), radius: 16, x: 0, y: 8)
            .contentShape(RoundedRectangle(cornerRadius: isNativeClean ? 16 : 18, style: .continuous))
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.95))
        .disabled(loadingKey != nil && recommendationActionLoading != nil)
    }

    private func openDailyRecommendations() {
        ATMusicHaptics.tap()
        guard !dailySongs.isEmpty else {
            ToastCenter.shared.show("推荐内容正在加载")
            return
        }
        openRoute(.dailySongs(dailySongs))
    }

    private func startPersonalFM() {
        guard auth.isLoggedIn else {
            ToastCenter.shared.show("请先登录网易云音乐")
            return
        }
        guard recommendationActionLoading == nil else { return }
        recommendationActionLoading = "fm"
        Task {
            defer { Task { @MainActor in recommendationActionLoading = nil } }
            do {
                let songs = try await NetEaseAPI.shared.personalFM()
                await MainActor.run {
                    if songs.isEmpty {
                        ToastCenter.shared.show("私人漫游暂时没有推荐")
                    } else {
                        player.play(songs: songs, startAt: 0)
                        ToastCenter.shared.show("已开启私人漫游")
                    }
                }
            } catch {
                await MainActor.run {
                    ATMusicLogger.shared.log("私人漫游加载失败：\(error.localizedDescription)", level: .error)
                    ToastCenter.shared.show("私人漫游加载失败")
                }
            }
        }
    }

    private func startKugouPersonalFM() {
        guard KugouMusicAuth.shared.isLoggedIn else {
            ToastCenter.shared.show("请先登录酷狗音乐")
            return
        }
        guard recommendationActionLoading == nil else { return }
        recommendationActionLoading = "kugouFM"
        Task {
            defer { Task { @MainActor in recommendationActionLoading = nil } }
            do {
                let songs = try await KugouMusicAPI.shared.personalFM(limit: 12)
                await MainActor.run {
                    if songs.isEmpty {
                        ToastCenter.shared.show("私人漫游暂时没有推荐")
                    } else {
                        player.play(songs: songs, startAt: 0)
                        ToastCenter.shared.show("已开启私人漫游")
                    }
                }
            } catch {
                await MainActor.run {
                    ATMusicLogger.shared.log("酷狗私人漫游加载失败：\(error.localizedDescription)", level: .error)
                    ToastCenter.shared.show("私人漫游加载失败")
                }
            }
        }
    }

    private func startHeartbeatMode() {
        guard let uid = auth.user?.uid else {
            ToastCenter.shared.show("请先登录网易云音乐")
            return
        }
        guard recommendationActionLoading == nil else { return }
        recommendationActionLoading = "heartbeat"
        Task {
            defer { Task { @MainActor in recommendationActionLoading = nil } }
            do {
                let playlists = try await NetEaseAPI.shared.userPlaylists(uid: uid)
                let liked = playlists.first(where: { $0.isNetEaseLikedPlaylist })
                let songs: [Song]
                if let liked {
                    let likedSongs = try await NetEaseAPI.shared.playlistTracks(id: liked.id)
                    guard let seed = likedSongs.randomElement() else {
                        await MainActor.run { ToastCenter.shared.show("先收藏一些喜欢的歌曲吧") }
                        return
                    }
                    songs = try await NetEaseAPI.shared.intelligenceList(songID: seed.id, playlistID: liked.id)
                    ATMusicLogger.shared.log("心动模式：喜欢歌单 specialType=\(liked.specialType) id=\(liked.id) seed=\(seed.id) 返回 \(songs.count) 首", level: songs.isEmpty ? .warn : .info)
                } else if let seed = dailySongs.randomElement() ?? player.currentSong {
                    songs = try await NetEaseAPI.shared.simiSongs(id: seed.id)
                    ATMusicLogger.shared.log("心动模式：未找到喜欢歌单，使用相似歌曲兜底 seed=\(seed.id) 返回 \(songs.count) 首", level: songs.isEmpty ? .warn : .info)
                } else {
                    await MainActor.run { ToastCenter.shared.show("先播放或收藏一些歌曲吧") }
                    return
                }
                await MainActor.run {
                    if songs.isEmpty {
                        ToastCenter.shared.show("心动模式暂时不可用")
                    } else {
                        player.play(songs: songs, startAt: 0)
                        ToastCenter.shared.show("已开启心动模式")
                    }
                }
            } catch {
                await MainActor.run {
                    ATMusicLogger.shared.log("心动模式加载失败：\(error.localizedDescription)", level: .error)
                    ToastCenter.shared.show("心动模式加载失败")
                }
            }
        }
    }

    @ViewBuilder
    private var homePlatformSelectionMenu: some View {
        let current = SearchProvider(rawValue: homeSourceRaw) ?? homeProviders.first ?? .netease
        Button {
            ATMusicHaptics.select()
            homeScopeRaw = "aggregate"
        } label: {
            Label("聚合全部音源", systemImage: isHomeAggregate ? "checkmark" : "square.stack.3d.up.fill")
        }
        Divider()
        ForEach(homeProviders) { provider in
            Button {
                ATMusicHaptics.select()
                homeScopeRaw = "single"
                homeSourceRaw = provider.rawValue
            } label: {
                Label(LocalizedStringKey(provider.rawValue), systemImage: !isHomeAggregate && provider == current ? "checkmark" : provider.icon)
            }
        }
    }

    // MARK: - 歌单广场（官方分类 + 双列网格）


    @ViewBuilder
    private var personalizedSection: some View {
        if isHomeAggregate {
            aggregatePersonalizedSection
        } else {
            singlePersonalizedSection
        }
    }

    private var singlePersonalizedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: playlistSectionTitle)
            if visiblePersonalizedPlaylists.isEmpty {
                EmptyStateView(icon: "music.note.list", text: playlistEmptyText)
            } else if isNativeClean && !playlistsExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(visiblePersonalizedPlaylists, id: \.identityKey) { (playlist: Playlist) in
                            Button {
                                ATMusicHaptics.tap()
                                openRoute(DiscoverRoute.playlist(playlist))
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    CoverImage(url: playlist.coverURL, size: 166, cornerRadius: 16)
                                    HStack(spacing: 6) {
                                        Text(playlist.name)
                                            .font(ATMusicFont.appFont(15, .bold))
                                            .foregroundStyle(Color.primary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        SourceBadgeView(source: playlist.source, compact: true)
                                    }
                                    .frame(width: 166, alignment: .leading)
                                    if playlist.trackCount > 0 {
                                        Text(atmusicSongCountText(playlist.trackCount))
                                            .font(ATMusicFont.appFont(12, .medium))
                                            .foregroundStyle(Color.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(width: 166, alignment: .leading)
                            }
                            .buttonStyle(GlassPressButtonStyle(scale: 0.96))
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(visiblePersonalizedPlaylists, id: \.identityKey) { playlist in
                        Button {
                            openRoute(DiscoverRoute.playlist(playlist))
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                CoverImage(url: playlist.coverURL, size: 144, cornerRadius: 18)
                                    .frame(maxWidth: .infinity)
                                HStack(spacing: 6) {
                                    Text(playlist.name)
                                        .font(ATMusicFont.appFont(12, .medium))
                                        .foregroundStyle(Color.atmusicLabel)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    SourceBadgeView(source: playlist.source, compact: true)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                ATMusicGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                        }
                        .buttonStyle(GlassPressButtonStyle(scale: 0.96))
                    }
                }
            }
            if personalized.count > collapsedPlaylistCount {
                Button {
                    ATMusicHaptics.select()
                    withAnimation {
                        playlistsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(playlistsExpanded
                             ? atmusicLocalized("收起歌单广场", "Collapse Playlist Square")
                             : atmusicLocalized("展开全部（\(personalized.count)）", "Show all (\(personalized.count))"))
                            .font(ATMusicFont.appFont(13, .semibold))
                        Image(systemName: playlistsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color.atmusicAmber)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background {
                        if isNativeClean {
                            Capsule().fill(Color.primary.opacity(0.045))
                        } else {
                            ATMusicGlass(shape: Capsule())
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
            }
        }
    }

    /// 聚合首页的歌单按音源分组，每个平台独占一行，避免不同平台的歌单混排。
    private var aggregatePersonalizedSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            SectionHeader(title: "聚合歌单")
            if aggregatePlaylistGroups.isEmpty {
                EmptyStateView(icon: "music.note.list", text: playlistEmptyText)
            } else {
                ForEach(Array(aggregatePlaylistGroups.enumerated()), id: \.element.0) { _, group in
                    let isExpanded = expandedAggregatePlaylistSources.contains(group.0)
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            ATMusicHaptics.select()
                            if isExpanded {
                                expandedAggregatePlaylistSources.remove(group.0)
                            } else {
                                expandedAggregatePlaylistSources.insert(group.0)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text(aggregateSourceTitle(group.0))
                                    .font(ATMusicFont.appFont(16, .bold))
                                    .foregroundStyle(Color.atmusicLabel)
                                Spacer(minLength: 8)
                                SourceBadgeView(source: group.0, compact: true)
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.atmusicComment)
                                    .frame(width: 28, height: 28)
                                    .background(Color.atmusicSecondary.opacity(0.10), in: Circle())
                            }
                        }
                        .buttonStyle(.plain)

                        if isExpanded {
                            LazyVGrid(
                                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                                spacing: 18
                            ) {
                                ForEach(group.1, id: \.identityKey) { playlist in
                                    aggregatePlaylistCard(playlist, expanded: true)
                                }
                            }
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 14) {
                                    ForEach(Array(group.1.prefix(collapsedPlaylistCount).enumerated()), id: \.element.identityKey) { _, playlist in
                                        aggregatePlaylistCard(playlist, expanded: false)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .padding(.trailing, isNativeClean ? -24 : 0)
                        }
                    }
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
            }
        }
    }

    @ViewBuilder
    private func aggregatePlaylistCard(_ playlist: Playlist, expanded: Bool) -> some View {
        let size: CGFloat = expanded ? 164 : (isNativeClean ? 156 : 136)
        Button {
            ATMusicHaptics.tap()
            openRoute(DiscoverRoute.playlist(playlist))
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                CoverImage(url: playlist.coverURL, size: size, cornerRadius: 16)
                Text(playlist.name)
                    .font(ATMusicFont.appFont(isNativeClean ? 14 : 12, .medium))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(2)
                    .frame(width: size, alignment: .leading)
                if playlist.trackCount > 0 {
                    Text(atmusicSongCountText(playlist.trackCount))
                        .font(ATMusicFont.appFont(11, .medium))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(1)
                }
            }
            .frame(width: size, alignment: .leading)
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.96))
    }

    private var aggregatePlaylistGroups: [(SongSource, [Playlist])] {
        let order: [SongSource] = [.netease, .qq, .kugou, .synology]
        let enabledSources = Set(homeProviders.map(\.songSource))
        var grouped: [SongSource: [Playlist]] = [:]
        for item in personalized {
            if enabledSources.contains(item.source) {
                grouped[item.source, default: []].append(item)
            }
        }
        return order.compactMap { source in
            guard let items = grouped[source], !items.isEmpty else { return nil }
            return (source, items)
        }
    }

    private func aggregateSourceTitle(_ source: SongSource) -> String {
        switch source {
        case .netease: return "网易云音乐"
        case .qq: return "QQ音乐"
        case .kugou: return "酷狗音乐"
        case .local: return "本地音乐"
        case .synology: return "群晖 NAS"
        }
    }

    private var playlistSectionTitle: String {
        if isHomeAggregate { return "聚合歌单" }
        switch source {
        case .netease: return "推荐歌单"
        case .qq: return "QQ音乐热门歌单"
        case .kugou: return "歌单广场"
        case .synology: return "群晖 Audio Station"
        }
    }

    private var playlistEmptyText: String {
        if isHomeAggregate { return "暂时没有获取到聚合歌单" }
        switch source {
        case .netease: return "推荐歌单暂时没有内容"
        case .qq: return "QQ音乐热门歌单暂未加载成功\n下拉刷新可重新获取"
        case .kugou: return "歌单广场暂时没有内容"
        case .synology: return "群晖音乐库请在音乐库页面查看"
        }
    }

    private var collapsedPlaylistCount: Int { 6 }

    private var visiblePersonalizedPlaylists: [Playlist] {
        playlistsExpanded ? personalized : Array(personalized.prefix(collapsedPlaylistCount))
    }

    // MARK: - 动作

    @MainActor
    private func load(force: Bool = false) async {
        guard !homeRenderingPaused else { return }
        if isHomeAggregate {
            await loadAggregate(force: force)
            return
        }
        let cache = DiscoverCache.shared
        let requestedSource = source
        let loadKey = requestedSource.rawValue
        if activeLoadKey == loadKey {
            return
        }
        if !force,
           lastLoadedKey == loadKey,
           Date().timeIntervalSince(lastLoadedAt) < 20,
           hasAnyData {
            loading = false
            errorMessage = nil
            return
        }
        activeLoadKey = loadKey
        defer {
            if activeLoadKey == loadKey {
                activeLoadKey = nil
            }
        }
        let cacheable = true
        var workingSnapshot = DiscoverCache.Snapshot()

        if let cached = cache.cached(for: requestedSource), !force, cacheable {
            guard !Task.isCancelled, requestedSource == source else { return }
            workingSnapshot = cached
            apply(cached)
            loading = false
            errorMessage = nil
            lastLoadedKey = loadKey
            lastLoadedAt = Date()
            if cache.isFresh(cached) { return }
            // 缓存过期：先展示旧快照，后台渐进式刷新。
        } else {
            // 只有“刷新当前平台”才保留屏幕上的现有内容。
            // 从另一个平台切过来时绝不能把上一平台的数据混入新平台。
            if force, lastLoadedKey == loadKey, hasAnyData {
                workingSnapshot = currentSnapshot()
            } else if lastLoadedKey != loadKey {
                apply(DiscoverCache.Snapshot())
            }
            loading = workingSnapshot.isEmpty
            errorMessage = nil
        }

        // 单平台采用渐进式并发加载：每日推荐 / 排行榜 / 歌单谁先回来谁先显示。
        workingSnapshot.savedAt = Date()
        let loggedIn = auth.isLoggedIn

        await withTaskGroup(of: DiscoverCache.Snapshot.self) { group in
            switch requestedSource {
            case .netease:
                group.addTask {
                    var part = DiscoverCache.Snapshot()
                    part.topLists = (try? await NetEaseAPI.shared.topLists()) ?? []
                    return part
                }
                group.addTask {
                    var part = DiscoverCache.Snapshot()
                    part.dailySongs = (try? await NetEaseAPI.shared.dailyRecommend()) ?? []
                    return part
                }
                group.addTask {
                    var part = DiscoverCache.Snapshot()
                    part.personalized = await NetEaseAPI.shared.recommendedHomePlaylists(loggedIn: loggedIn, limit: 18)
                    return part
                }

            case .qq:
                group.addTask {
                    var part = DiscoverCache.Snapshot()
                    part.dailySongs = (try? await QQMusicAPI.shared.recommendSongs(limit: 30)) ?? []
                    return part
                }
                group.addTask {
                    var part = DiscoverCache.Snapshot()
                    part.qqTopLists = (try? await QQMusicAPI.shared.topLists()) ?? []
                    return part
                }
                group.addTask {
                    var part = DiscoverCache.Snapshot()
                    part.personalized = (try? await QQMusicAPI.shared.hotPlaylists(limit: 18)) ?? []
                    return part
                }

            case .kugou:
                group.addTask {
                    var part = DiscoverCache.Snapshot()
                    if let songs = try? await KugouMusicAPI.shared.everydayRecommend(limit: 30), !songs.isEmpty {
                        part.dailySongs = songs
                    } else {
                        part.dailySongs = (try? await KugouMusicAPI.shared.searchSongs(keyword: "热门歌曲", limit: 30)) ?? []
                    }
                    return part
                }
                group.addTask {
                    var part = DiscoverCache.Snapshot()
                    part.kugouTopLists = (try? await KugouMusicAPI.shared.topLists(limit: 10)) ?? []
                    return part
                }
                group.addTask {
                    var part = DiscoverCache.Snapshot()
                    part.personalized = (try? await KugouMusicAPI.shared.recommendPlaylists(limit: 12)) ?? []
                    return part
                }

            case .synology:
                group.addTask {
                    await fetchNASHomeSnapshot()
                }
            }

            for await part in group {
                guard !Task.isCancelled, !isHomeAggregate, requestedSource == source else {
                    group.cancelAll()
                    return
                }
                mergeHomeSnapshotPart(part, into: &workingSnapshot)
                if !workingSnapshot.isEmpty {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        apply(workingSnapshot)
                    }
                    loading = false
                    errorMessage = nil
                }
            }
        }

        guard !Task.isCancelled, !isHomeAggregate, requestedSource == source else { return }
        workingSnapshot.savedAt = Date()
        if cacheable, !workingSnapshot.isEmpty {
            cache.save(workingSnapshot, for: requestedSource)
        }
        loading = false
        errorMessage = workingSnapshot.isEmpty ? "暂时没有获取到主页内容" : nil
        lastLoadedKey = loadKey
        lastLoadedAt = Date()
    }

    private func currentSnapshot() -> DiscoverCache.Snapshot {
        var snapshot = DiscoverCache.Snapshot()
        snapshot.dailySongs = dailySongs
        snapshot.topLists = topLists
        snapshot.personalized = personalized
        snapshot.qqTopLists = qqTopLists
        snapshot.kugouTopLists = kugouTopLists
        snapshot.savedAt = Date()
        return snapshot
    }

    private func mergeHomeSnapshotPart(
        _ part: DiscoverCache.Snapshot,
        into snapshot: inout DiscoverCache.Snapshot
    ) {
        if !part.dailySongs.isEmpty { snapshot.dailySongs = part.dailySongs }
        if !part.topLists.isEmpty { snapshot.topLists = part.topLists }
        if !part.personalized.isEmpty { snapshot.personalized = part.personalized }
        if !part.qqTopLists.isEmpty { snapshot.qqTopLists = part.qqTopLists }
        if !part.kugouTopLists.isEmpty { snapshot.kugouTopLists = part.kugouTopLists }
        snapshot.savedAt = Date()
    }

    @MainActor
    private func loadAggregate(force: Bool) async {
        let loadKey = "aggregate"
        if activeLoadKey == loadKey { return }
        if !force,
           lastLoadedKey == loadKey,
           Date().timeIntervalSince(lastLoadedAt) < 20,
           hasAnyData {
            loading = false
            errorMessage = nil
            return
        }
        activeLoadKey = loadKey
        let wasAlreadyAggregate = lastLoadedKey == loadKey
        loading = !(wasAlreadyAggregate && hasAnyData)
        errorMessage = nil
        defer {
            if activeLoadKey == loadKey { activeLoadKey = nil }
        }

        var snapshotsByProvider: [SearchProvider: DiscoverCache.Snapshot] = [:]
        let cache = DiscoverCache.shared

        // 聚合主页无论普通进入还是手动刷新，都先用各平台磁盘快照拼出基线。
        // 这样从单平台切到聚合不会短暂显示上一平台内容，刷新时也不会整页闪空。
        for provider in homeProviders {
            if let cached = cache.cached(for: provider) {
                snapshotsByProvider[provider] = cached
            }
        }
        let cachedSnapshot = combineAggregateSnapshots(
            homeProviders.compactMap { snapshotsByProvider[$0] }
        )
        if !cachedSnapshot.isEmpty {
            apply(cachedSnapshot)
            loading = false
        } else if !wasAlreadyAggregate {
            apply(DiscoverCache.Snapshot())
            loading = true
        }

        let providers = homeProviders
        await withTaskGroup(of: (SearchProvider, DiscoverCache.Snapshot).self) { group in
            for provider in providers {
                group.addTask { [self] in
                    await fetchAggregatePart(for: provider)
                }
            }
            for await (provider, snapshot) in group {
                guard !Task.isCancelled, isHomeAggregate else { return }
                if !snapshot.isEmpty {
                    snapshotsByProvider[provider] = snapshot
                    cache.save(snapshot, for: provider)

                    // 首次安装通常没有任何缓存。旧逻辑必须等所有平台都返回后才结束
                    // Loading，其中一个平台慢就会让聚合主页长时间空白。
                    // 现在任一平台先返回即可立刻展示，后续平台到达时无动画补齐内容。
                    let partialSnapshot = combineAggregateSnapshots(
                        homeProviders.compactMap { snapshotsByProvider[$0] }
                    )
                    if !partialSnapshot.isEmpty {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            apply(partialSnapshot)
                        }
                        loading = false
                        errorMessage = nil
                    }
                }
            }
        }
        guard isHomeAggregate else { return }
        let finalSnapshot = combineAggregateSnapshots(homeProviders.compactMap { snapshotsByProvider[$0] })
        if !finalSnapshot.isEmpty {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                apply(finalSnapshot)
            }
        }
        loading = false
        errorMessage = hasAnyData ? nil : "暂时没有获取到聚合首页内容"
        lastLoadedKey = loadKey
        lastLoadedAt = Date()
    }

    private func combineAggregateSnapshots(_ snapshots: [DiscoverCache.Snapshot]) -> DiscoverCache.Snapshot {
        var result = DiscoverCache.Snapshot()
        result.savedAt = Date()

        var seenSongs = Set<String>()
        result.dailySongs = snapshots.flatMap(\.dailySongs).filter {
            seenSongs.insert($0.identityKey).inserted
        }
        result.topLists = snapshots.flatMap(\.topLists)
        result.qqTopLists = snapshots.flatMap(\.qqTopLists)
        result.kugouTopLists = snapshots.flatMap(\.kugouTopLists)

        var seenPlaylists = Set<String>()
        result.personalized = snapshots.flatMap(\.personalized).filter {
            seenPlaylists.insert($0.identityKey).inserted
        }
        return result
    }

    private func fetchAggregatePart(for provider: SearchProvider) async -> (SearchProvider, DiscoverCache.Snapshot) {
        // 某个平台不可用时不能让聚合首页永远停在等待状态。
        await withTaskGroup(of: (SearchProvider, DiscoverCache.Snapshot).self) { group in
            group.addTask { [self] in
                switch provider {
                case .synology:
                    return (provider, await fetchNASHomeSnapshot())
                case .netease, .qq, .kugou:
                    let snapshot = (try? await fetchSnapshot(for: provider)) ?? DiscoverCache.Snapshot()
                    return (provider, snapshot)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return (provider, DiscoverCache.Snapshot())
            }
            let first = await group.next() ?? (provider, DiscoverCache.Snapshot())
            group.cancelAll()
            return first
        }
    }


    private func reloadAfterLoginUpdate(_ provider: SearchProvider) {
        if isHomeAggregate {
            Task { await load(force: true) }
        } else if source == provider {
            Task { await load(force: true) }
        } else {
            homeScopeRaw = "single"
            homeSourceRaw = provider.rawValue
        }
    }


    private func fetchSnapshot(for source: SearchProvider) async throws -> DiscoverCache.Snapshot {
        var snapshot = DiscoverCache.Snapshot()
        snapshot.savedAt = Date()
        switch source {
        case .qq:
            async let a: [Song] = (try? await QQMusicAPI.shared.recommendSongs(limit: 30)) ?? []
            async let b: [QQTopInfo] = (try? await QQMusicAPI.shared.topLists()) ?? []
            async let c: [Playlist] = (try? await QQMusicAPI.shared.hotPlaylists(limit: 18)) ?? []
            let (dr, tl, pp) = await (a, b, c)
            if pp.isEmpty {
                ATMusicLogger.shared.log("QQ音乐热门歌单为空：保留板块并显示空状态", level: .warn)
            }
            snapshot.dailySongs = dr
            snapshot.qqTopLists = tl
            snapshot.personalized = pp
        case .netease:
            async let a = NetEaseAPI.shared.topLists()
            async let b = NetEaseAPI.shared.dailyRecommend()
            async let c = NetEaseAPI.shared.recommendedHomePlaylists(loggedIn: auth.isLoggedIn, limit: 18)
            let (tl, dr, pp) = try await (a, b, c)
            snapshot.topLists = tl
            snapshot.dailySongs = dr
            snapshot.personalized = pp
        case .kugou:
            async let songs = loadKugouDailySongs(limit: 30)
            async let ranks = KugouMusicAPI.shared.topLists(limit: 10)
            async let playlists = KugouMusicAPI.shared.recommendPlaylists(limit: 12)
            let (daily, top, pp) = try await (songs, ranks, playlists)
            snapshot.dailySongs = daily
            snapshot.kugouTopLists = top
            snapshot.personalized = pp
        case .synology:
            // NAS 内容由音乐库页面按登录状态加载，不参与发现页推荐快照。
            break
        }
        return snapshot
    }


    private func fetchNASHomeSnapshot() async -> DiscoverCache.Snapshot {
        var snapshot = DiscoverCache.Snapshot()
        guard SynologyAPI.shared.isLoggedIn else { return snapshot }
        snapshot.personalized = (try? await SynologyAPI.shared.allPlaylists(pageSize: 18)) ?? []
        if let songs = try? await SynologyAPI.shared.librarySongs() {
            snapshot.dailySongs = Array(songs.prefix(30))
        }
        return snapshot
    }

    private func loadKugouDailySongs(limit: Int) async -> [Song] {
        if let songs = try? await KugouMusicAPI.shared.everydayRecommend(limit: limit), !songs.isEmpty {
            return songs
        }
        return (try? await KugouMusicAPI.shared.searchSongs(keyword: "热门歌曲", limit: limit)) ?? []
    }

    @MainActor
    private func apply(_ snapshot: DiscoverCache.Snapshot) {
        dailySongs = snapshot.dailySongs
        topLists = snapshot.topLists
        personalized = snapshot.personalized
        qqTopLists = snapshot.qqTopLists
        kugouTopLists = snapshot.kugouTopLists
    }

    private var hasAnyData: Bool {
        !dailySongs.isEmpty || !topLists.isEmpty || !personalized.isEmpty
            || !qqTopLists.isEmpty || !kugouTopLists.isEmpty
    }
}

/// 聚合首页的完整歌单承载页：让首页保持轻量，所有平台的歌单仍可一处浏览。
private struct AggregatePlaylistLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    let groups: [(SongSource, [Playlist])]
    let onSelect: (Playlist) -> Void

    var body: some View {
        NavigationView {
            List {
                ForEach(Array(groups.enumerated()), id: \.element.0) { _, group in
                    Section {
                        ForEach(group.1, id: \.identityKey) { playlist in
                            Button {
                                onSelect(playlist)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    CoverImage(url: playlist.coverURL, size: 52, cornerRadius: 10)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(playlist.name)
                                            .font(ATMusicFont.appFont(15, .semibold))
                                            .foregroundStyle(Color.atmusicLabel)
                                            .lineLimit(2)
                                        Text(playlist.trackCount > 0 ? atmusicSongCountText(playlist.trackCount) : "歌单")
                                            .font(ATMusicFont.appFont(12))
                                            .foregroundStyle(Color.atmusicComment)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.atmusicComment)
                                }
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack(spacing: 7) {
                            Text(sourceTitle(group.0))
                            SourceBadgeView(source: group.0, compact: true)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("全部歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .modifier(ATMusicSheetModifier(detents: [.large], dragIndicator: true))
    }

    private func sourceTitle(_ source: SongSource) -> String {
        switch source {
        case .netease: return "网易云音乐"
        case .qq: return "QQ音乐"
        case .kugou: return "酷狗音乐"
        case .synology: return "群晖 NAS"
        case .local: return "本地音乐"
        }
    }
}

// MARK: - QQ 峰尖榜详情

struct QQTopListDetailView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var theme: ThemeStore

    let topID: Int
    let name: String
    @State private var tracks: [Song] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var searchText = ""

    init(topID: Int, name: String) {
        self.topID = topID
        self.name = name
    }

    var body: some View {
        let _ = theme.accent
        ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                Group {
                if loading {
                    LoadingStateView()
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await load() }
                    }
                } else {
                    List {
                        Section {
                            HStack(spacing: 12) {
                                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                    guard !filteredTracks.isEmpty else { return }
                                    player.play(songs: filteredTracks, startAt: 0)
                                }
                                GlassButton(title: "随机播放", systemName: "shuffle") {
                                    guard !filteredTracks.isEmpty else { return }
                                    player.play(songs: filteredTracks, startAt: Int.random(in: 0..<filteredTracks.count))
                                }
                            }
                            .listRowBackground(Color.clear)
                            .padding(.vertical, 8)
                        }
                        Section {
                            ForEach(Array(filteredTracks.enumerated()), id: \.element.identityKey) { index, song in
                                SongCell(song: song, glassRow: true) {
                                    player.play(songs: filteredTracks, startAt: index)
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }
                    }
                    .atmusicScrollContentBackgroundHidden()
                    .listStyle(.plain)
                }
            }
            }
            .navigationTitle(atmusicChartName(name))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: atmusicLocalized("搜索榜单歌曲", "Search chart songs"))
        .task { await load() }
    }

    private var filteredTracks: [Song] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return tracks }
        return tracks.filter { song in
            song.name.lowercased().contains(kw)
                || song.artists.lowercased().contains(kw)
                || song.album.lowercased().contains(kw)
        }
    }

    @MainActor
    private func load() async {
        let cache = DetailSongsCache.shared
        let cacheKey = "qq-top-\(topID)"
        if let cached = cache.cachedSongs(for: cacheKey) {
            tracks = cached.songs
            loading = false
            errorMessage = nil
            if cache.isFresh(cached) {
                return
            }
        } else {
            loading = true
            errorMessage = nil
        }
        do {
            let songs = try await QQMusicAPI.shared.topListSongs(topid: topID)
            if !songs.isEmpty {
                tracks = songs
                cache.save(songs, for: cacheKey)
            }
            loading = false
        } catch {
            if tracks.isEmpty {
                errorMessage = error.localizedDescription
            } else {
                ATMusicLogger.shared.log(
                    "QQ 排行榜详情后台刷新失败，继续使用缓存 topID=\(topID) error=\(error.localizedDescription)",
                    level: .warn
                )
            }
            loading = false
        }
    }
}

// MARK: - QQ 歌单内歌曲

struct QQPlaylistSongsSheet: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var theme: ThemeStore

    let playlist: Playlist
    @State private var tracks: [Song] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var searchText = ""

    var body: some View {
        let _ = theme.accent
        ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                Group {
                if loading {
                    LoadingStateView()
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await load() }
                    }
                } else {
                    List {
                        Section {
                            HStack(spacing: 12) {
                                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                    guard !filteredTracks.isEmpty else { return }
                                    player.play(songs: filteredTracks, startAt: 0)
                                }
                                GlassButton(title: "随机播放", systemName: "shuffle") {
                                    guard !filteredTracks.isEmpty else { return }
                                    player.play(songs: filteredTracks, startAt: Int.random(in: 0..<filteredTracks.count))
                                }
                            }
                            .listRowBackground(Color.clear)
                            .padding(.vertical, 8)
                        }
                        Section {
                            ForEach(Array(filteredTracks.enumerated()), id: \.element.identityKey) { index, song in
                                SongCell(song: song, glassRow: true) {
                                    player.play(songs: filteredTracks, startAt: index)
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }
                    }
                    .atmusicScrollContentBackgroundHidden()
                    .listStyle(.plain)
                }
            }
            }
            .navigationTitle(playlist.name)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: atmusicLocalized("搜索歌单内歌曲", "Search playlist songs"))
        .task { await load() }
    }

    private var filteredTracks: [Song] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return tracks }
        return tracks.filter { song in
            song.name.lowercased().contains(kw)
                || song.artists.lowercased().contains(kw)
                || song.album.lowercased().contains(kw)
        }
    }

    @MainActor
    private func load() async {
        loading = true
        errorMessage = nil
        do {
            tracks = try await QQMusicAPI.shared.playlistSongs(listID: playlist.id)
            loading = false
        } catch {
            errorMessage = error.localizedDescription
            loading = false
        }
    }
}

// MARK: - 每日推荐全部歌曲

struct DailySongsSheet: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var theme: ThemeStore

    let songs: [Song]
    @State private var searchText = ""

    var body: some View {
        let _ = theme.accent
        ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                Group {
                if songs.isEmpty {
                    EmptyStateView(icon: "sparkles", text: "今日推荐加载中，下拉刷新试试")
                } else {
                    List {
                    Section {
                        HStack(spacing: 12) {
                            GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                guard !filteredSongs.isEmpty else { return }
                                player.play(songs: filteredSongs, startAt: 0)
                            }
                            GlassButton(title: "随机播放", systemName: "shuffle") {
                                guard !filteredSongs.isEmpty else { return }
                                player.play(songs: filteredSongs, startAt: Int.random(in: 0..<filteredSongs.count))
                            }
                        }
                        .listRowBackground(Color.clear)
                        .padding(.vertical, 8)
                    }
                    Section {
                        ForEach(Array(filteredSongs.enumerated()), id: \.element.identityKey) { index, song in
                            SongCell(song: song, glassRow: true) {
                                ATMusicHaptics.tap()
                                player.play(songs: filteredSongs, startAt: index)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                }
                .atmusicScrollContentBackgroundHidden()
                .listStyle(.plain)
                }
            }
            }
            .navigationTitle("今日推荐")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: atmusicLocalized("搜索每日推荐", "Search daily recommendations"))
    }

    private var filteredSongs: [Song] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return songs }
        return songs.filter { song in
            song.name.lowercased().contains(kw)
                || song.artists.lowercased().contains(kw)
                || song.album.lowercased().contains(kw)
        }
    }
}
// MARK: - 排行榜详情

struct TopListDetailView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var auth: AuthStore

    let topList: TopList
    @State private var tracks: [Song] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var searchText = ""

    init(topList: TopList) {
        self.topList = topList
    }

    var body: some View {
        let _ = theme.accent
        ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                Group {
                if loading {
                    LoadingStateView()
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await load() }
                    }
                } else {
                    List {
                        header
                        Section {
                            HStack(spacing: 12) {
                                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                    guard !filteredTracks.isEmpty else { return }
                                    player.play(songs: filteredTracks, startAt: 0)
                                }
                                GlassButton(title: "随机播放", systemName: "shuffle") {
                                    guard !filteredTracks.isEmpty else { return }
                                    player.play(songs: filteredTracks, startAt: Int.random(in: 0..<filteredTracks.count))
                                }
                            }
                            .listRowBackground(Color.clear)
                            .padding(.vertical, 8)
                        }
                        Section {
                            ForEach(Array(filteredTracks.enumerated()), id: \.element.identityKey) { index, song in
                                SongCell(song: song, glassRow: true) {
                                    player.play(songs: filteredTracks, startAt: index)
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }
                    }
                    .atmusicScrollContentBackgroundHidden()
                    .listStyle(.plain)
                }
            }
            }
            .navigationTitle(atmusicChartName(topList.name))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: atmusicLocalized("搜索榜单歌曲", "Search chart songs"))
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            CoverImage(url: topList.coverURL, size: 88, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 6) {
                Text(atmusicChartName(topList.name))
                    .font(ATMusicFont.appFont(18, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                Text(atmusicChartSubtitle(topList.updateFrequency))
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
                Text(atmusicSongCountText(tracks.count))
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
            }
            Spacer()
        }
        .padding(14)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .atmusicCardShadow(radius: 8, y: 3)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var filteredTracks: [Song] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return tracks }
        return tracks.filter { song in
            song.name.lowercased().contains(kw)
                || song.artists.lowercased().contains(kw)
                || song.album.lowercased().contains(kw)
        }
    }

    @MainActor
    private func load() async {
        let cache = DetailSongsCache.shared
        let cacheKey = "netease-top-\(topList.id)"
        if let cached = cache.cachedSongs(for: cacheKey) {
            tracks = cached.songs
            loading = false
            errorMessage = nil
            if cache.isFresh(cached) {
                return
            }
        } else {
            loading = true
            errorMessage = nil
        }
        do {
            let songs = try await NetEaseAPI.shared.playlistTracks(id: topList.id)
            if !songs.isEmpty {
                tracks = songs
                cache.save(songs, for: cacheKey)
            }
            loading = false
        } catch {
            if tracks.isEmpty {
                errorMessage = error.localizedDescription
            } else {
                ATMusicLogger.shared.log(
                    "网易云排行榜详情后台刷新失败，继续使用缓存 id=\(topList.id) error=\(error.localizedDescription)",
                    level: .warn
                )
            }
            loading = false
        }
    }
}

// MARK: - 酷狗排行榜详情

struct KugouTopListDetailView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss

    let topList: KugouTopInfo
    @State private var tracks: [Song] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var searchText = ""

    init(topList: KugouTopInfo) {
        self.topList = topList
    }

    var body: some View {
        let _ = theme.accent
        ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                Group {
                if loading {
                    LoadingStateView()
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await load() }
                    }
                } else if tracks.isEmpty {
                    EmptyStateView(icon: "music.note.list", text: atmusicLocalized("该排行榜暂无歌曲", "This chart has no songs yet"))
                } else {
                    List {
                        header
                        Section {
                            HStack(spacing: 12) {
                                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                    guard !filteredTracks.isEmpty else { return }
                                    player.play(songs: filteredTracks, startAt: 0)
                                }
                                GlassButton(title: "随机播放", systemName: "shuffle") {
                                    guard !filteredTracks.isEmpty else { return }
                                    player.play(songs: filteredTracks, startAt: Int.random(in: 0..<filteredTracks.count))
                                }
                            }
                            .listRowBackground(Color.clear)
                            .padding(.vertical, 8)
                        }
                        Section {
                            ForEach(Array(filteredTracks.enumerated()), id: \.element.identityKey) { index, song in
                                SongCell(song: song, glassRow: true) {
                                    player.play(songs: filteredTracks, startAt: index)
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }
                    }
                    .atmusicScrollContentBackgroundHidden()
                    .listStyle(.plain)
                }
            }
            }
            .navigationTitle(atmusicChartName(topList.name))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: atmusicLocalized("搜索榜单歌曲", "Search chart songs"))
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            CoverImage(url: topList.coverURL, size: 88, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 6) {
                Text(atmusicChartName(topList.name))
                    .font(ATMusicFont.appFont(18, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(2)
                if !topList.updateFrequency.isEmpty {
                    Text(atmusicChartSubtitle(topList.updateFrequency))
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                }
                Text(atmusicSongCountText(tracks.count))
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .atmusicCardShadow(radius: 8, y: 3)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var filteredTracks: [Song] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return tracks }
        return tracks.filter { song in
            song.name.lowercased().contains(kw)
                || song.artists.lowercased().contains(kw)
                || song.album.lowercased().contains(kw)
        }
    }

    @MainActor
    private func load() async {
        let cache = DetailSongsCache.shared
        let cacheKey = "kugou-top-\(topList.id)"
        if let cached = cache.cachedSongs(for: cacheKey) {
            tracks = cached.songs
            loading = false
            errorMessage = nil
            if cache.isFresh(cached) {
                return
            }
        } else {
            loading = true
            errorMessage = nil
        }
        do {
            let songs = try await KugouMusicAPI.shared.rankSongs(rankID: topList.id)
            if !songs.isEmpty {
                tracks = songs
                cache.save(songs, for: cacheKey)
            }
            loading = false
        } catch {
            if tracks.isEmpty {
                errorMessage = error.localizedDescription
            } else {
                ATMusicLogger.shared.log(
                    "酷狗排行榜详情后台刷新失败，继续使用缓存 id=\(topList.id) error=\(error.localizedDescription)",
                    level: .warn
                )
            }
            loading = false
        }
    }
}

private struct HomeUnifiedSearchSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared

    @State private var keyword = ""
    @State private var results: [Song] = []
    @State private var searching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var debounceTask: Task<Void, Never>?
    @State private var searchController = SearchFieldController()

    private var providers: [SearchProvider] {
        platformPrefs.enabledSearchProviders
    }

    var body: some View {
        ATMusicNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            VStack(spacing: 12) {
                searchField
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .navigationTitle("全平台搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .onChange(of: keyword) { _, newValue in
            debounceTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                results = []
                errorMessage = nil
                return
            }
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 420_000_000)
                guard !Task.isCancelled else { return }
                await startSearch(trimmed)
            }
        }
        .onDisappear {
            debounceTask?.cancel()
            searchTask?.cancel()
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.atmusicComment)
            SearchTextField(
                text: $keyword,
                controller: searchController,
                placeholder: atmusicLocalized("搜索三平台歌曲", "Search across three platforms"),
                textColor: UIColor.atmusicLabel,
                onSubmit: { text in
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    debounceTask?.cancel()
                    Task { await startSearch(trimmed) }
                }
            )
            .frame(height: 34)
            .frame(maxWidth: .infinity)

            ZStack {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.atmusicAmber)
                    .opacity(searching ? 1 : 0)
            }
            .frame(width: 20, height: 22)
            .animation(nil, value: searching)

            ZStack {
                Button {
                    keyword = ""
                    results = []
                    errorMessage = nil
                    debounceTask?.cancel()
                    searchTask?.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.atmusicComment.opacity(0.85))
                }
                .buttonStyle(.plain)
                .opacity(keyword.isEmpty ? 0 : 1)
                .disabled(keyword.isEmpty)
            }
            .frame(width: 20, height: 22)

            Button {
                let text = searchController.commit()
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                debounceTask?.cancel()
                Task { await startSearch(trimmed) }
            } label: {
                Text("搜索")
                    .font(ATMusicFont.appFont(13, .semibold))
                    .foregroundStyle(Color.atmusicAmber)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background { ATMusicGlass(shape: Capsule()) }
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.9))
            .frame(width: 54, height: 30)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .atmusicCardShadow(radius: 8, y: 3)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyStateView(icon: "magnifyingglass", text: "输入歌名后会同时搜索网易云、QQ音乐和酷狗音乐")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, results.isEmpty {
            ErrorStateView(message: errorMessage) {
                Task { await startSearch(keyword) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searching && results.isEmpty {
            LoadingStateView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            EmptyStateView(icon: "music.note", text: "暂未找到相关歌曲")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Text(atmusicLocalized("找到 \(results.count) 首 · 全平台", "Found \(results.count) songs · All Platforms"))
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicComment)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .truncationMode(.tail)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                        Button {
                            ATMusicHaptics.tap()
                            player.play(songs: results, startAt: 0)
                        } label: {
                            Label("播放全部", systemImage: "play.fill")
                                .font(ATMusicFont.appFont(12, .semibold))
                                .foregroundStyle(Color.atmusicAmber)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background { ATMusicGlass(shape: Capsule()) }
                        }
                        .buttonStyle(.plain)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)

                    ForEach(Array(results.enumerated()), id: \.element.identityKey) { index, song in
                        SongCell(song: song) {
                            ATMusicHaptics.tap()
                            player.play(songs: results, startAt: index)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 120)
            }
            .atmusicScrollIndicatorsHidden()
            .atmusicScrollDismissesKeyboard()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @MainActor
    private func startSearch(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchTask?.cancel()
        searchTask = Task {
            searching = true
            errorMessage = nil
            ATMusicLogger.shared.log("主页聚合搜索：\(trimmed)", level: .info)
            defer { if !Task.isCancelled { searching = false } }

            let enabledProviders = providers
            async let netease: [Song] = searchSongs(on: .netease, keyword: trimmed, enabledProviders: enabledProviders)
            async let qq: [Song] = searchSongs(on: .qq, keyword: trimmed, enabledProviders: enabledProviders)
            async let kugou: [Song] = searchSongs(on: .kugou, keyword: trimmed, enabledProviders: enabledProviders)

            let merged = await (netease + qq + kugou)
            guard !Task.isCancelled else { return }
            results = deduplicated(merged)
            if results.isEmpty {
                errorMessage = "三个平台都没有返回可展示的歌曲"
            } else {
                ATMusicHaptics.success()
            }
            ATMusicLogger.shared.log("主页聚合搜索完成：\(trimmed) 结果=\(results.count)", level: .info)
        }
        await searchTask?.value
    }

    private func searchSongs(on provider: SearchProvider, keyword: String, enabledProviders: [SearchProvider]) async -> [Song] {
        guard enabledProviders.contains(provider) else { return [] }
        switch provider {
        case .netease:
            return (try? await NetEaseAPI.shared.search(keyword: keyword, limit: 30)) ?? []
        case .qq:
            return (try? await QQMusicAPI.shared.searchSongs(keyword: keyword, limit: 30)) ?? []
        case .kugou:
            return (try? await KugouMusicAPI.shared.searchSongs(keyword: keyword, limit: 30)) ?? []
        case .synology:
            return (try? await SynologyAPI.shared.search(keyword: keyword, limit: 30)) ?? []
        }
    }

    private func deduplicated(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        var output: [Song] = []
        for song in songs {
            let key = "\(song.source.rawValue)-\(song.name.lowercased())-\(song.artists.lowercased())"
            if seen.insert(key).inserted {
                output.append(song)
            }
        }
        return output
    }
}
