import SwiftUI
import UIKit

enum RootTab: String, CaseIterable, Identifiable, Hashable {
    case discover
    case featured
    case library
    case profile
    case search

    static var mainTabs: [RootTab] { [.discover, .featured, .library, .profile] }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .discover: return "主页"
        case .featured: return "精选"
        case .library: return "音乐库"
        case .profile: return "我的"
        case .search: return "搜索"
        }
    }

    var icon: String {
        switch self {
        case .discover: return "house.fill"
        case .featured: return "square.grid.2x2.fill"
        case .library: return "rectangle.stack.badge.play"
        case .profile: return "person.crop.circle.fill"
        case .search: return "magnifyingglass"
        }
    }
}
struct RootView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var favorites: FavoritesStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared
    @AppStorage("atmusic.themeMode") private var themeModeRaw = ATMusicThemeMode.system.rawValue

    @State private var selection: RootTab = .discover
    @State private var showPlayer = false
    @Namespace private var nowPlayingTransition
    @AppStorage("atmusic.disclaimerAccepted") private var disclaimerAccepted = false
    /// 底栏是否显示文字（关闭后只显示图标）
    @AppStorage("atmusic.homeSource") private var homeSourceRaw = SearchProvider.netease.rawValue
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    @State private var showWhatsNew = false
    @State private var updateInfo: UpdateChecker.ReleaseInfo?
    @State private var showUpdateAlert = false
    @ObservedObject private var ipaDownloader = IPADownloader.shared
    @State private var showUpdateDownloadOverlay = false
    @State private var updateShareFile: ShareFileItem?
    @State private var updateShareFileURL: URL?
    @State private var updateDownloadError = ""
    @State private var showUpdateDownloadError = false
    @State private var showHomePlatformMenu = false
    // 高频滚动值不能放在 @State 里，否则每一帧都会让整个根视图重建。
    private var themeMode: ATMusicThemeMode {
        ATMusicThemeMode(rawValue: themeModeRaw) ?? .system
    }

    private var uiStyle: ATMusicUIStyle {
        uiStyleRaw == "outline" ? .clear : (ATMusicUIStyle(rawValue: uiStyleRaw) ?? .liquid)
    }

    var body: some View {
        let _ = theme.accent
        Group {
            if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                IPadRootView(
                    selection: $selection,
                    showPlayer: $showPlayer,
                    nowPlayingTransition: nowPlayingTransition
                )
            } else {
                modernSystemTabs
            }
        }
        .preferredColorScheme(themeMode.colorScheme)
        .confirmationDialog("主页平台", isPresented: $showHomePlatformMenu, titleVisibility: .visible) {
            platformSelectionMenu
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if #available(iOS 18.0, *) {
                playerPresentation
                    .navigationTransition(
                        .zoom(
                            sourceID: ATMusicNowPlayingTransitionID.surface,
                            in: nowPlayingTransition
                        )
                    )
            } else {
                playerPresentation
            }
        }
        .overlay(alignment: .bottom) {
            ToastView(center: ToastCenter.shared)
        }
        .onAppear {
            CrashReporter.shared.markLaunchCompleted()
            if disclaimerAccepted, ChangelogStore.shouldShowWhatsNew {
                showWhatsNew = true
            }
        }
        .onChange(of: disclaimerAccepted) { _, accepted in
            if accepted, ChangelogStore.shouldShowWhatsNew {
                showWhatsNew = true
            }
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewSheet()
        }
        .task(id: disclaimerAccepted) {
            guard disclaimerAccepted else { return }
            if let info = await UpdateChecker.checkIfNeeded() {
                updateInfo = info
                showUpdateAlert = true
            }
        }
        .overlay {
            if showUpdateAlert, let info = updateInfo {
                UpdatePromptOverlay(
                    info: info,
                    onOpen: {
                        showUpdateAlert = false
                        if let assetURL = info.assetURL {
                            startUpdateDownload(info: info, assetURL: assetURL)
                        } else {
                            UIApplication.shared.open(info.htmlURL)
                        }
                    },
                    onRemindLater: {
                        UpdateChecker.suppress(version: info.version)
                        showUpdateAlert = false
                    },
                    onDismiss: {
                        showUpdateAlert = false
                    }
                )
                .transition(.opacity)
                .zIndex(20)
            }
        }
        .overlay {
            if showUpdateDownloadOverlay {
                updateDownloadProgressOverlay
                    .zIndex(21)
            }
        }
        .sheet(item: $updateShareFile, onDismiss: cleanupUpdateShareFile) { item in
            ShareSheet(items: [item.url])
        }
        .alert("更新下载失败", isPresented: $showUpdateDownloadError) {
            Button("好", role: .cancel) {}
            Button("打开 GitHub") {
                UIApplication.shared.open(UpdateChecker.releasePageURL)
            }
        } message: {
            Text(updateDownloadError)
        }
    }

    private func startUpdateDownload(info: UpdateChecker.ReleaseInfo, assetURL: URL) {
        showUpdateDownloadOverlay = true
        Task {
            do {
                let url = try await ipaDownloader.download(assetURL: assetURL, version: info.version)
                await MainActor.run {
                    showUpdateDownloadOverlay = false
                    updateShareFileURL = url
                    updateShareFile = ShareFileItem(url: url)
                }
            } catch {
                await MainActor.run {
                    showUpdateDownloadOverlay = false
                    updateDownloadError = error.localizedDescription
                    showUpdateDownloadError = true
                }
            }
        }
    }

    private func cleanupUpdateShareFile() {
        guard let url = updateShareFileURL else { return }
        try? FileManager.default.removeItem(at: url)
        updateShareFile = nil
        updateShareFileURL = nil
    }

    private var updateDownloadProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.atmusicHighlight)
                    Text("正在下载最新版 IPA")
                        .font(ATMusicFont.appFont(15, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                }
                if ipaDownloader.progress >= 0 {
                    ProgressView(value: ipaDownloader.progress)
                        .progressViewStyle(.linear)
                        .tint(Color.atmusicAmber)
                    Text("\(Int(ipaDownloader.progress * 100))%")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                } else {
                    ProgressView().tint(Color.atmusicAmber)
                    Text("正在获取更新…")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                }
            }
            .padding(22)
            .frame(maxWidth: 300)
            .background { ATMusicGlass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)) }
            .atmusicCardShadow(radius: 12, y: 6)
            .padding(32)
        }
    }

    /// iOS 26/27：完全交给系统 TabView + Liquid Glass 导航容器。
    /// 系统负责：搜索独立 prominent tab、滚动收缩、底部 accessory 融合/分离、原生交互动画。
    @available(iOS 26.0, *)
    private var modernSystemTabs: some View {
        TabView(selection: $selection) {
            Tab("主页", systemImage: "house", value: RootTab.discover) {
                DiscoverView(onOpenProfile: { selection = .profile })
            }
            Tab("精选", systemImage: "square.grid.2x2", value: RootTab.featured) {
                FeaturedView(onOpenProfile: { selection = .profile })
            }
            Tab("音乐库", systemImage: "rectangle.stack.badge.play", value: RootTab.library) {
                MusicLibraryHomeView(onOpenProfile: { selection = .profile })
            }
            Tab("我的", systemImage: "person.crop.circle", value: RootTab.profile) {
                ProfileView()
            }
            Tab(value: RootTab.search, role: .search) {
                SearchView()
            }
        }
        .tint(Color.atmusicAmber)
        .modifier(ATMusicSystemTabGlobalStyle(style: uiStyle))
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            if player.currentSong != nil {
                ATMusicNativeTabAccessory(
                    showPlayer: $showPlayer,
                    transitionNamespace: nowPlayingTransition
                )
                .environmentObject(player.clock)
            }
        }
        .background {
            TabBarAppearanceConfigurator(
                hidesSystemTabBarOnLegacy: false,
                hidesSystemTabBarOnModern: false,
                onHomeLongPress: { showHomePlatformMenu = true }
            )
        }
    }

    @ViewBuilder
    private var platformSelectionMenu: some View {
        let current = SearchProvider(rawValue: homeSourceRaw) ?? platformPrefs.enabledSearchProviders.first ?? .netease
        Text("主页平台")
        ForEach(platformPrefs.enabledSearchProviders) { provider in
            Button {
                ATMusicHaptics.select()
                homeSourceRaw = provider.rawValue
            } label: {
                Label(LocalizedStringKey(provider.rawValue), systemImage: provider == current ? "checkmark" : provider.icon)
            }
        }
    }

    @ViewBuilder
    private var playerPresentation: some View {
        ATMusicNowPlayingPresentation {
            PlayerView(isPresented: $showPlayer)
                .environmentObject(favorites)
                .environmentObject(player)
                .environmentObject(player.clock)
                .environmentObject(auth)
        }
    }
}
struct ATMusicNowPlayingPresentation<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        // iOS 26/27 使用系统 presentation / navigationTransition。
        // 不再叠加自定义 dragOffset、阈值判断或 spring 动画。
        content
    }
}

struct PlatformPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let current: SearchProvider
    let providers: [SearchProvider]
    let onSelect: (SearchProvider) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("选择主页平台")
                .font(ATMusicFont.appFont(19, .bold))
                .foregroundStyle(Color.atmusicLabel)
            ForEach(providers) { provider in
                Button {
                    onSelect(provider)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: provider == current ? "checkmark.circle.fill" : provider.icon)
                            .foregroundStyle(provider == current ? Color.atmusicAmber : Color.atmusicComment)
                        Text(LocalizedStringKey(provider.rawValue))
                            .font(ATMusicFont.appFont(15, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background {
                        ATMusicSelectableSurface(
                            selected: provider == current,
                            shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
                            accent: .atmusicAmber
                        )
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .background(Color.clear)
        .modifier(PlatformPickerPresentation(providersCount: providers.count))
    }
}

/// 精选页歌单数据来源：可切换的「聚合 / 网易云 / QQ / 酷狗」四种歌单浏览模式。
/// 与主页（DiscoverView）左上角平台切换保持一致：左上角标题即当前来源，点击弹出切换菜单。
enum FeaturedSource: String, CaseIterable, Identifiable, Hashable {
    case aggregate
    case netease
    case qq
    case kugou

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aggregate: return "聚合"
        case .netease: return "网易云音乐"
        case .qq: return "QQ音乐"
        case .kugou: return "酷狗音乐"
        }
    }

    /// 单平台来源对应的歌单 source；聚合模式为 nil。
    var songSource: SongSource? {
        switch self {
        case .aggregate: return nil
        case .netease: return .netease
        case .qq: return .qq
        case .kugou: return .kugou
        }
    }

    var brandImageName: String? {
        switch self {
        case .aggregate: return nil
        case .netease: return "BrandNetease"
        case .qq: return "BrandQQ"
        case .kugou: return "BrandKugou"
        }
    }

    /// 聚合模式在左上角使用的系统图标（无品牌图）。
    var aggregateIcon: String { "square.stack.3d.up.fill" }

    /// 切换菜单里使用的系统图标。
    var menuIcon: String {
        switch self {
        case .aggregate: return "square.stack.3d.up.fill"
        case .netease: return "cloud.fill"
        case .qq: return "play.rectangle.fill"
        case .kugou: return "music.note"
        }
    }

    /// 精选页通用分类（非网易云来源不再请求网易云远程分类，直接使用这份固定分类）。
    static let commonCategories = [
        "华语", "欧美", "日语", "韩语", "粤语", "小语种",
        "流行", "摇滚", "民谣", "电子", "舞曲", "说唱", "轻音乐", "爵士", "乡村", "古典", "民族", "英伦", "金属", "朋克", "蓝调", "雷鬼", "拉丁", "另类/独立", "世界音乐", "New Age", "古风", "BGM", "嘻哈", "网络歌曲", "DJ", "R&B/Soul",
        "清晨", "夜晚", "学习", "工作", "午休", "下午茶", "地铁", "驾车", "运动", "旅行", "散步", "酒吧",
        "怀旧", "清新", "浪漫", "性感", "伤感", "治愈", "放松", "孤独", "感动", "兴奋", "快乐", "安静", "思念",
        "综艺", "影视原声", "ACG", "儿童", "校园", "游戏", "翻唱", "器乐", "亲子", "公益", "婚礼", "派对", "音乐播客"
    ]

    /// 各来源的默认分类胶囊（含固定入口：全部 / 推荐歌单 / 精品歌单）。
    static func defaultCategories(for source: FeaturedSource) -> [String] {
        var merged: [String] = ["全部", "推荐歌单", "精品歌单"]
        for name in commonCategories {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !merged.contains(trimmed) else { continue }
            merged.append(trimmed)
        }
        return merged
    }
}

/// 网易云风格的“精选”主页面：左上角可在「聚合 / 网易云 / QQ / 酷狗」四种歌单之间切换，
/// 支持顶部搜索歌单、分类胶囊和双列歌单网格，下拉刷新；网易云来源支持分页加载。
struct FeaturedView: View {
    var onOpenProfile: () -> Void = {}
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var player: PlayerManager

    @AppStorage("atmusic.featuredSource") private var featuredSourceRaw = FeaturedSource.netease.rawValue

    @State private var categories = FeaturedSource.defaultCategories(for: .netease)
    @State private var selectedCategory = "全部"
    @State private var query = ""
    @State private var playlists: [Playlist] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var nextOffset = 0
    @State private var hasMorePlaylists = true

    private let pageSize = 40

    private var featuredSource: FeaturedSource {
        FeaturedSource(rawValue: featuredSourceRaw) ?? .netease
    }

    private var isAggregate: Bool { featuredSource == .aggregate }

    /// 来源 / 分类 / 关键词任一变化都会触发重载。
    private var reloadTaskID: String {
        "\(featuredSource.rawValue)|\(selectedCategory)|\(query)"
    }

    var body: some View {
        ATMusicNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                VStack(alignment: .leading, spacing: 0) {
                    header
                    featuredSearchField
                        .padding(.horizontal, 24)
                        .padding(.bottom, 14)
                    categoryChips
                        .padding(.bottom, 12)

                    ScrollView {
                        if isLoading && playlists.isEmpty {
                            LoadingStateView()
                                .frame(maxWidth: .infinity, minHeight: 260)
                        } else if let errorMessage, playlists.isEmpty {
                            ErrorStateView(message: errorMessage) { Task { await load(reset: true) } }
                                .frame(maxWidth: .infinity, minHeight: 260)
                        } else if playlists.isEmpty {
                            Text("暂无匹配歌单")
                                .font(ATMusicFont.appFont(14))
                                .foregroundStyle(Color.atmusicComment)
                                .frame(maxWidth: .infinity, minHeight: 260)
                        } else {
                            playlistGrid
                            if isLoadingMore {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                            }
                        }
                    }
                    .atmusicScrollIndicatorsHidden()
                    .refreshable { await load(reset: true) }
                }
            }
            .onAppear {
                categories = FeaturedSource.defaultCategories(for: featuredSource)
            }
            .onChange(of: featuredSource) { _, newValue in
                selectedCategory = "全部"
                query = ""
                categories = FeaturedSource.defaultCategories(for: newValue)
                playlists = []
                isLoading = true
                errorMessage = nil
                if newValue == .netease {
                    Task { await enrichCategoriesFromNetEase() }
                }
            }
            .task {
                if featuredSource == .netease {
                    await enrichCategoriesFromNetEase()
                }
            }
            .task(id: reloadTaskID) {
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled else { return }
                }
                await load(reset: true)
            }
        }
    }

    /// 左上角：当前来源品牌图标 + 标题 + 下拉箭头，点击弹出「聚合 / 网易云 / QQ / 酷狗」切换菜单。
    private var header: some View {
        HStack(alignment: .center) {
            Menu {
                ForEach(FeaturedSource.allCases) { source in
                    Button {
                        guard source != featuredSource else { return }
                        ATMusicHaptics.select()
                        featuredSourceRaw = source.rawValue
                    } label: {
                        Label(source.title, systemImage: source == featuredSource ? "checkmark" : source.menuIcon)
                    }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let imageName = featuredSource.brandImageName {
                        Image(imageName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                    } else {
                        Image(systemName: featuredSource.aggregateIcon)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    Text(featuredSource.title)
                        .font(ATMusicFont.appFont(30, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.atmusicComment)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("切换精选平台")

            Spacer(minLength: 0)
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
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    private var featuredSearchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.atmusicComment)
            TextField("搜索歌单", text: $query)
                .font(ATMusicFont.appFont(16))
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background {
            ATMusicGlass(shape: Capsule())
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(categories, id: \.self) { category in
                    Button {
                        guard selectedCategory != category else { return }
                        ATMusicHaptics.select()
                        selectedCategory = category
                    } label: {
                        Text(category)
                            .font(ATMusicFont.appFont(13, .medium))
                            .atmusicSelectionForeground(selected: selectedCategory == category, accent: .atmusicAmber)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 8)
                            .background {
                                ATMusicSelectableSurface(
                                    selected: selectedCategory == category,
                                    shape: Capsule(),
                                    accent: .atmusicAmber
                                )
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var playlistGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
            spacing: 18
        ) {
            ForEach(playlists, id: \.identityKey) { playlist in
                NavigationLink {
                    PlaylistView(playlist: playlist)
                        .environmentObject(auth)
                        .environmentObject(player)
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        CoverImage(url: playlist.coverURL, size: 170, cornerRadius: 14)
                            .frame(maxWidth: .infinity)
                        HStack(spacing: 5) {
                            Text(playlist.name)
                                .font(ATMusicFont.appFont(13, .medium))
                                .foregroundStyle(Color.atmusicLabel)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            if isAggregate {
                                SourceBadgeView(source: playlist.source, compact: true)
                            }
                        }
                        Text(playlistSubtitle(playlist))
                            .font(ATMusicFont.appFont(11))
                            .foregroundStyle(Color.atmusicComment)
                            .lineLimit(1)
                    }
                    .padding(8)
                    .background {
                        ATMusicGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .buttonStyle(.plain)
                .onAppear {
                    guard playlist.identityKey == playlists.last?.identityKey else { return }
                    Task { await loadMoreIfNeeded() }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 190)
    }

    private func playlistSubtitle(_ playlist: Playlist) -> String {
        if playlist.trackCount > 0 {
            return atmusicSongCountText(playlist.trackCount)
        }
        switch featuredSource {
        case .aggregate: return playlist.source.atmusicDisplayName
        case .netease: return "网易云音乐精选"
        case .qq: return "QQ音乐精选"
        case .kugou: return "酷狗音乐精选"
        }
    }

    private func load(reset: Bool) async {
        if reset {
            isLoading = true
            isLoadingMore = false
            nextOffset = 0
            hasMorePlaylists = true
            playlists = []
        } else {
            guard !isLoading, !isLoadingMore, hasMorePlaylists else { return }
            isLoadingMore = true
        }
        errorMessage = nil
        do {
            let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let loaded: [Playlist]
            switch featuredSource {
            case .netease:
                loaded = try await loadNetEase(keyword: keyword)
            case .qq:
                loaded = try await loadQQ(keyword: keyword)
            case .kugou:
                loaded = try await loadKugou(keyword: keyword)
            case .aggregate:
                loaded = try await loadAggregate(keyword: keyword)
            }
            guard !Task.isCancelled else { return }
            let countBeforeMerge = playlists.count
            var seen = Set(playlists.map { "\($0.source.rawValue)|\($0.id)" })
            playlists.append(contentsOf: loaded.filter {
                seen.insert("\($0.source.rawValue)|\($0.id)").inserted
            })
            nextOffset += loaded.count
            // 网易 / QQ / 酷狗搜索与分类、酷狗歌单广场均支持 offset 分页；
            // QQ 热门歌单（官网推荐位）一次取完，返回空页或重复页即停止翻页。
            hasMorePlaylists = !loaded.isEmpty && playlists.count > countBeforeMerge
            isLoading = false
            isLoadingMore = false
        } catch {
            isLoading = false
            isLoadingMore = false
            errorMessage = error.localizedDescription
        }
    }

    private func loadMoreIfNeeded() async {
        await load(reset: false)
    }

    private func loadNetEase(keyword: String) async throws -> [Playlist] {
        if !keyword.isEmpty {
            return try await NetEaseAPI.shared.searchPlaylists(keyword: keyword, limit: pageSize, offset: nextOffset)
        }
        switch selectedCategory {
        case "精品歌单":
            return try await NetEaseAPI.shared.highQualityPlaylists(cat: "全部", limit: pageSize, offset: nextOffset)
        case "全部", "推荐歌单":
            return try await NetEaseAPI.shared.playlistSquare(cat: "全部", order: "hot", limit: pageSize, offset: nextOffset)
        default:
            return try await NetEaseAPI.shared.playlistSquare(cat: selectedCategory, order: "hot", limit: pageSize, offset: nextOffset)
        }
    }

    private func loadQQ(keyword: String) async throws -> [Playlist] {
        if !keyword.isEmpty {
            return try await QQMusicAPI.shared.searchPlaylists(keyword: keyword, limit: pageSize, offset: nextOffset)
        }
        switch selectedCategory {
        case "精品歌单":
            return try await QQMusicAPI.shared.searchPlaylists(keyword: "精选", limit: pageSize, offset: nextOffset)
        case "全部", "推荐歌单":
            return try await QQMusicAPI.shared.allPlaylists(limit: pageSize, offset: nextOffset)
        default:
            return try await QQMusicAPI.shared.searchPlaylists(keyword: selectedCategory, limit: pageSize, offset: nextOffset)
        }
    }

    private func loadKugou(keyword: String) async throws -> [Playlist] {
        if !keyword.isEmpty {
            return try await KugouMusicAPI.shared.searchPlaylists(keyword: keyword, limit: pageSize, offset: nextOffset)
        }
        switch selectedCategory {
        case "精品歌单":
            return try await KugouMusicAPI.shared.searchPlaylists(keyword: "精选", limit: pageSize, offset: nextOffset)
        case "全部", "推荐歌单":
            return try await KugouMusicAPI.shared.recommendPlaylists(limit: pageSize, offset: nextOffset)
        default:
            return try await KugouMusicAPI.shared.searchPlaylists(keyword: selectedCategory, limit: pageSize, offset: nextOffset)
        }
    }

    /// 聚合：三平台并行拉取后合并，单卡附带平台徽标。
    private func loadAggregate(keyword: String) async throws -> [Playlist] {
        if !keyword.isEmpty {
            async let netease: [Playlist] = (try? await NetEaseAPI.shared.searchPlaylists(keyword: keyword, limit: pageSize, offset: nextOffset)) ?? []
            async let qq: [Playlist] = (try? await QQMusicAPI.shared.searchPlaylists(keyword: keyword, limit: pageSize, offset: nextOffset)) ?? []
            async let kugou: [Playlist] = (try? await KugouMusicAPI.shared.searchPlaylists(keyword: keyword, limit: pageSize, offset: nextOffset)) ?? []
            let (n, q, k) = try await (netease, qq, kugou)
            return interleave(n, q, k)
        }
        switch selectedCategory {
        case "精品歌单":
            async let netease: [Playlist] = (try? await NetEaseAPI.shared.highQualityPlaylists(cat: "全部", limit: pageSize, offset: nextOffset)) ?? []
            async let qq: [Playlist] = (try? await QQMusicAPI.shared.searchPlaylists(keyword: "精选", limit: pageSize, offset: nextOffset)) ?? []
            async let kugou: [Playlist] = (try? await KugouMusicAPI.shared.searchPlaylists(keyword: "精选", limit: pageSize, offset: nextOffset)) ?? []
            let (n, q, k) = try await (netease, qq, kugou)
            return interleave(n, q, k)
        case "全部", "推荐歌单":
            async let netease: [Playlist] = (try? await NetEaseAPI.shared.playlistSquare(cat: "全部", order: "hot", limit: pageSize, offset: nextOffset)) ?? []
            async let qq: [Playlist] = (try? await QQMusicAPI.shared.allPlaylists(limit: pageSize, offset: nextOffset)) ?? []
            async let kugou: [Playlist] = (try? await KugouMusicAPI.shared.recommendPlaylists(limit: pageSize, offset: nextOffset)) ?? []
            let (n, q, k) = try await (netease, qq, kugou)
            return interleave(n, q, k)
        default:
            async let netease: [Playlist] = (try? await NetEaseAPI.shared.playlistSquare(cat: selectedCategory, order: "hot", limit: pageSize, offset: nextOffset)) ?? []
            async let qq: [Playlist] = (try? await QQMusicAPI.shared.searchPlaylists(keyword: selectedCategory, limit: pageSize, offset: nextOffset)) ?? []
            async let kugou: [Playlist] = (try? await KugouMusicAPI.shared.searchPlaylists(keyword: selectedCategory, limit: pageSize, offset: nextOffset)) ?? []
            let (n, q, k) = try await (netease, qq, kugou)
            return interleave(n, q, k)
        }
    }

    /// 聚合歌单各平台交叉轮流显示：网易 → QQ → 酷狗 → 网易 → …
    private func interleave(_ arrays: [Playlist]...) -> [Playlist] {
        var result: [Playlist] = []
        let maxCount = arrays.map(\.count).max() ?? 0
        for i in 0..<maxCount {
            for arr in arrays where i < arr.count {
                result.append(arr[i])
            }
        }
        return result
    }
    /// 网易云来源远程分类丰富：接口正常时使用服务端全部分类；失败时保留通用分类兜底。
    private func enrichCategoriesFromNetEase() async {
        guard featuredSource == .netease else { return }
        let remote = await NetEaseAPI.shared.playlistCatlist()
        guard !Task.isCancelled else { return }
        var merged: [String] = ["全部", "推荐歌单", "精品歌单"]
        for name in remote + FeaturedSource.commonCategories {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !merged.contains(trimmed) else { continue }
            merged.append(trimmed)
        }
        categories = merged
    }
}

private struct ClearSheetBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.presentationBackground(.clear)
        } else {
            content
        }
    }
}

private struct ATMusicSystemTabGlobalStyle: ViewModifier {
    let style: ATMusicUIStyle

    @ViewBuilder
    func body(content: Content) -> some View {
        switch style {
        case .liquid:
            // 不指定背景，让 iOS 26/27 使用系统原生 Liquid Glass。
            content
        case .clear:
            content
                .toolbarBackground(.ultraThinMaterial, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        case .compact:
            content
                .toolbarBackground(Color.atmusicGlassFill.opacity(0.82), for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        case .nativeClean:
            content
                .toolbarBackground(Color(uiColor: .systemBackground).opacity(0.94), for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        }
    }
}

@available(iOS 26.0, *)
private struct ATMusicNativeTabAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Binding var showPlayer: Bool
    let transitionNamespace: Namespace.ID

    var body: some View {
        MiniPlayerView(
            showPlayer: $showPlayer,
            presentation: .accessory,
            transitionNamespace: transitionNamespace,
            compact: placement == .inline
        )
        // expanded = 位于 TabBar 上方；inline = 已被系统融合进收缩后的 TabBar。
        .padding(.horizontal, placement == .expanded ? 10 : 2)
    }
}

private struct PlatformPickerPresentation: ViewModifier {
    let providersCount: Int

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .modifier(ClearSheetBackground())
                .presentationDetents([.height(CGFloat(116 + providersCount * 60))])
                .presentationDragIndicator(.visible)
        } else {
            content
        }
    }
}

private struct VisualEffectBlur: UIViewRepresentable {
    var style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}

private struct UpdatePromptOverlay: View {
    let info: UpdateChecker.ReleaseInfo
    let onOpen: () -> Void
    let onRemindLater: () -> Void
    let onDismiss: () -> Void

    private var details: String {
        let body = info.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? "本次更新暂无详细说明。" : body
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("发现新版本")
                            .font(ATMusicFont.appFont(20, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                        Text("AT Music \(info.version)")
                            .font(ATMusicFont.appFont(13, .semibold))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    Spacer(minLength: 8)
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.atmusicComment)
                            .frame(width: 30, height: 30)
                            .background(Color.atmusicGlassFill, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }

                Divider()
                    .overlay(Color.atmusicComment.opacity(0.16))
                    .padding(.vertical, 14)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("更新内容")
                            .font(ATMusicFont.appFont(14, .semibold))
                            .foregroundStyle(Color.atmusicLabel)
                        Text(details)
                            .font(ATMusicFont.appFont(13))
                            .foregroundStyle(Color.atmusicComment)
                            .fixedSize(horizontal: false, vertical: true)
                        if let imageURL = info.notesImageURL {
                            AsyncImage(url: imageURL) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFit()
                                } else if phase.error == nil {
                                    ProgressView().frame(maxWidth: .infinity, minHeight: 70)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)

                VStack(spacing: 10) {
                    Button(action: onOpen) {
                        Text("立即更新")
                            .font(ATMusicFont.appFont(14, .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(Color.atmusicAmber))
                    }
                    .buttonStyle(.plain)

                    Button("以后再说", action: onRemindLater)
                        .font(ATMusicFont.appFont(13, .semibold))
                        .foregroundStyle(Color.atmusicComment)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .buttonStyle(.plain)
                }
                .padding(.top, 18)
            }
            .padding(20)
            .frame(maxWidth: 360)
            .background {
                ATMusicGlass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .atmusicCardShadow(radius: 16, y: 8)
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - 系统 TabBar 清透风格（实例级配置）
// 系统 TabView 创建之后，`UITabBar.appearance()` 全局代理对已存在的实例不再生效，
// 旧系统页面仍可通过 TabBarAppearanceConfigurator 隐藏系统栏；
// iOS 26/27 默认保留系统原生 Liquid Glass TabBar，不再覆盖其外观。

struct TabBarAppearanceConfigurator: UIViewControllerRepresentable {
    var hidesSystemTabBarOnLegacy = true
    var hidesSystemTabBarOnModern = false
    var onHomeLongPress: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onHomeLongPress: onHomeLongPress)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        // 纯外观配置视图：禁止拦截触摸，避免透明全屏视图吃掉页面按钮点击
        controller.view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            Self.apply(
                from: controller,
                hidesSystemTabBarOnLegacy: hidesSystemTabBarOnLegacy,
                hidesSystemTabBarOnModern: hidesSystemTabBarOnModern,
                coordinator: context.coordinator
            )
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.onHomeLongPress = onHomeLongPress
        DispatchQueue.main.async {
            Self.apply(
                from: uiViewController,
                hidesSystemTabBarOnLegacy: hidesSystemTabBarOnLegacy,
                hidesSystemTabBarOnModern: hidesSystemTabBarOnModern,
                coordinator: context.coordinator
            )
        }
    }

    /// 固定清透风格：全透明背景、无阴影；选中态用主题色，
    /// 材质与模糊完全交给系统对底层页面内容的渲染，不再支持手动调节透明度
    private static func apply(
        from controller: UIViewController,
        hidesSystemTabBarOnLegacy: Bool,
        hidesSystemTabBarOnModern: Bool,
        coordinator: Coordinator
    ) {
        guard let tabBar = controller.tabBarController?.tabBar else { return }
        installHomeLongPress(on: tabBar, coordinator: coordinator)
        if #available(iOS 26, *) {
            if hidesSystemTabBarOnModern {
                tabBar.isHidden = true
                tabBar.isTranslucent = true
            } else {
                // iOS 26/27 使用系统原生 Liquid Glass TabBar；不要覆盖其材质/scroll-edge 外观。
                tabBar.isHidden = false
            }
            return
        } else if hidesSystemTabBarOnLegacy {
            tabBar.isHidden = true
            tabBar.isTranslucent = true
            return
        } else {
            tabBar.isHidden = false
        }
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        // 超薄材质模糊：与迷你播放器一致的清透玻璃透明度
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        appearance.backgroundColor = .clear
        appearance.shadowColor = .clear
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.tintColor = UIColor.atmusicAmber
        tabBar.isTranslucent = true
    }

    private static func installHomeLongPress(on tabBar: UITabBar, coordinator: Coordinator) {
        let controls = tabBar.subviews
            .flatMap { descendants(of: $0) }
            .compactMap { $0 as? UIControl }
            .filter { !$0.isHidden && $0.alpha > 0 && $0.bounds.width > 0 }
            .sorted { $0.frame.minX < $1.frame.minX }
        guard let homeButton = controls.first else { return }
        guard homeButton.gestureRecognizers?.contains(where: { $0.name == Coordinator.gestureName }) != true else { return }

        let gesture = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleHomeLongPress(_:)))
        gesture.name = Coordinator.gestureName
        gesture.minimumPressDuration = 0.45
        gesture.cancelsTouchesInView = true
        homeButton.addGestureRecognizer(gesture)
    }

    private static func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    final class Coordinator: NSObject {
        static let gestureName = "atmusic.homePlatformLongPress"
        var onHomeLongPress: (() -> Void)?

        init(onHomeLongPress: (() -> Void)?) {
            self.onHomeLongPress = onHomeLongPress
        }

        @objc func handleHomeLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began else { return }
            ATMusicHaptics.select()
            onHomeLongPress?()
        }
    }
}
