import SwiftUI
import MediaPlayer
import AVKit

/// iPad 侧边栏导航目的地项（对标 Apple Music iPad 完整资料库层级）
enum IPadSidebarDestination: Hashable, Identifiable {
    case tab(RootTab)
    case transferCenter
    case localMusic
    case history
    case favorites
    case synology
    case settings

    var id: String {
        switch self {
        case .tab(let tab): return "tab-\(tab.rawValue)"
        case .transferCenter: return "transferCenter"
        case .localMusic: return "localMusic"
        case .history: return "history"
        case .favorites: return "favorites"
        case .synology: return "synology"
        case .settings: return "settings"
        }
    }

    var title: String {
        switch self {
        case .tab(let tab): return tab.title
        case .transferCenter: return "传输中心"
        case .localMusic: return "本地音乐"
        case .history: return "最近播放"
        case .favorites: return "我喜欢的音乐"
        case .synology: return "群晖 NAS"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .tab(let tab): return tab.icon
        case .transferCenter: return "arrow.down.circle.fill"
        case .localMusic: return "internaldrive.fill"
        case .history: return "clock.fill"
        case .favorites: return "heart.fill"
        case .synology: return "externaldrive.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

/// iPad 专属 Apple Music 官方级多栏与自适应架构根视图
/// 采用 NavigationSplitView 双栏/多栏架构，完美兼容 1/3 屏、1/2 半分屏、大分屏、横屏与竖屏；
/// 严格遵循 Apple Music iPadOS 人机交互规范，并完整支持软件 4 套 UI 调节（liquid、clear、compact、nativeClean）。
struct IPadRootView: View {
    @Binding var selection: RootTab
    @Binding var showPlayer: Bool
    var nowPlayingTransition: Namespace.ID

    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var favorites: FavoritesStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    @ObservedObject private var downloadManager = DownloadManager.shared
    @ObservedObject private var synology = SynologyAPI.shared

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var activeDestination: IPadSidebarDestination = .tab(.discover)
    @State private var showSettingsSheet = false
    /// 详情重建计数：点侧栏行就 +1，详情用 .id() 重建、回到该页根部
    ///（正在看的歌单是详情页自己导航栈里推上去的，只换目的地清不掉它）。
    @State private var detailResetID = 0

    private var uiStyle: ATMusicUIStyle {
        uiStyleRaw == "outline" ? .clear : (ATMusicUIStyle(rawValue: uiStyleRaw) ?? .liquid)
    }

    private var isNativeClean: Bool { uiStyle == .nativeClean }
    private var isCompact: Bool { uiStyle == .compact }

    init(
        selection: Binding<RootTab>,
        showPlayer: Binding<Bool>,
        nowPlayingTransition: Namespace.ID
    ) {
        self._selection = selection
        self._showPlayer = showPlayer
        self.nowPlayingTransition = nowPlayingTransition
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 320)
        } detail: {
            detailHostContent
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            syncDestinationFromSelection()
        }
        .onChange(of: selection) { _ in
            syncDestinationFromSelection()
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView()
                .environmentObject(theme)
                .environmentObject(player)
                .environmentObject(auth)
                .modifier(SettingsLiquidSheetPresentation())
        }
    }

    private func syncDestinationFromSelection() {
        if case .tab(let currentTab) = activeDestination, currentTab == selection {
            return
        }
        activeDestination = .tab(selection)
    }

    // MARK: - 侧边栏主体 (对标 Apple Music iPad)

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            List {
                // 1. 顶部直达（对标 Apple Music：搜索 / 主页 / 电台，无分组标题；
                // 咱们没有电台功能，第三行是精选乐馆）。
                Section {
                    sidebarRow(for: .tab(.search), customTitle: "全网搜索")
                    sidebarRow(for: .tab(.discover), customTitle: "主页")
                    sidebarRow(for: .tab(.featured), customTitle: "精选乐馆")
                }

                // 2. 资料库大类（Apple Music 的 Library 分组可折叠，咱们的分组暂不支持折叠，样式先对齐；
                // 传输中心 / 本地音乐 / 群晖 NAS 是咱们的功能，全保留）。
                Section("资料库") {
                    sidebarRow(for: .tab(.library), customTitle: "音乐库")
                    sidebarRow(for: .favorites)
                    sidebarRow(for: .history)
                    sidebarRow(for: .transferCenter, badgeCount: activeTransferCount)
                    sidebarRow(for: .localMusic)
                    if synology.isLoggedIn {
                        sidebarRow(for: .synology)
                    }
                }

                // 3. 偏好设置（Apple Music 的设置在系统设置里；咱们自带设置页，保留为侧栏末行）。
                Section {
                    sidebarRow(for: .settings, customTitle: "偏好设置")
                }
            }
            .listStyle(.sidebar)

            // 侧栏底部账户（对标 Apple Music 侧栏底部的头像 + 名字，点开个人中心；
            // 隔空播放已移到悬浮胶囊右侧，不再占侧栏一行）。
            sidebarProfileFooter
        }
    }

    private var activeTransferCount: Int {
        downloadManager.activeDownloads.filter { $0.status != .completed }.count +
        downloadManager.activeUploads.filter { $0.status != .completed }.count
    }

    // MARK: - 侧栏行项（四种 UI 风格联动高亮）

    @ViewBuilder
    private func sidebarRow(for destination: IPadSidebarDestination, customTitle: String? = nil, badgeCount: Int = 0) -> some View {
        let isSelected = activeDestination == destination
        let title = customTitle ?? destination.title

        Button {
            ATMusicHaptics.select()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                detailResetID += 1
                activeDestination = destination
                if case .tab(let tab) = destination {
                    selection = tab
                }
            }
        } label: {
            HStack(spacing: isCompact ? 8 : 12) {
                Image(systemName: destination.icon)
                    .font(.system(size: isCompact ? 15 : 17, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? Color.atmusicAmber : Color.atmusicLabel)
                    .frame(width: 24, alignment: .center)

                Text(title)
                    .font(ATMusicFont.appFont(isCompact ? 13 : 15, isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.atmusicLabel : Color.atmusicLabel.opacity(0.85))

                Spacer(minLength: 4)

                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(ATMusicFont.appFont(11, .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.atmusicAmber, in: Capsule())
                }
            }
            .padding(.vertical, isCompact ? 5 : 7)
            .padding(.horizontal, isCompact ? 8 : 10)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    sidebarSelectionBackground
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var sidebarSelectionBackground: some View {
        switch uiStyle {
        case .liquid:
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.atmusicAmber.opacity(0.16))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.atmusicAmber.opacity(0.25), lineWidth: 1)
                }
        case .clear:
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.atmusicAmber, lineWidth: 1.2)
        case .compact:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        case .nativeClean:
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07))
        }
    }



    // MARK: - 侧栏底部账户（对标 Apple Music 侧栏底部的头像 + 名字）

    private var sidebarProfileFooter: some View {
        Button {
            ATMusicHaptics.select()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                detailResetID += 1
                activeDestination = .tab(.profile)
                selection = .profile
            }
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: auth.user?.avatarURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Circle()
                            .fill(Color.atmusicAmber.opacity(0.18))
                            .overlay {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(Color.atmusicAmber)
                            }
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(auth.user?.nickname ?? "我的")
                        .font(ATMusicFont.appFont(15, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(1)
                    Text(auth.isLoggedIn ? "已登录" : "点击登录")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.atmusicComment)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    /// 胶囊的底：与手机迷你播放器完全一致的构造（MiniPlayerView.swift dock）——
    /// ATMusicGlass + 斜向高光 + 亮边描边；阴影与裁剪照手机的做法放在胶囊外面。
    /// 之前 iPad 这边自己拼的 thinMaterial + 竖向渐变，透明度和玻璃感都跟手机不一样，
    /// 所以直接照搬手机那套（形状仍是真胶囊，iPad / Apple Music 的形态）。
    private var capsuleBackground: some View {
        ATMusicGlass(shape: Capsule(), forceLiquid: false)
            .overlay {
                LinearGradient(
                    colors: [.white.opacity(0.25), .clear, .white.opacity(0.05)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.45), .white.opacity(0.08)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
            }
    }

    // MARK: - 悬浮播放胶囊（对标 Apple Music iPad：全屏底部居中的独立胶囊）

    /// Apple Music iPad 的迷你播放器是内容区底部居中的独立悬浮胶囊（没在播也显示），
    /// 不贴在侧栏底部、也不只在侧栏折叠时才出现。胶囊排列也是苹果的顺序：
    /// 左边上一首 / 播放 / 下一首，中间封面 + 歌名 / 歌手，右边隔空播放。
    /// 封面后的光晕、裁剪与投影都照手机迷你播放器的做法。
    /// 尺寸分两档（内容区宽 ≥740 为横屏档）：横屏封面 48、播放键 26、按键框 44、
    /// 胶囊限宽 600，不拉太长、内容不拥挤；竖屏保持 64 高那档。
    private func floatingPlayerCapsule(isWide: Bool) -> some View {
        let coverSize: CGFloat = isWide ? 48 : 40
        let playSize: CGFloat = isWide ? 26 : 20
        let skipSize: CGFloat = isWide ? 20 : 16
        let buttonFrame: CGFloat = isWide ? 44 : 38
        let titleSize: CGFloat = isWide ? 17 : 16
        let artistSize: CGFloat = isWide ? 14 : 13
        return Button {
            if player.currentSong != nil {
                ATMusicHaptics.tap()
                showPlayer = true
            }
        } label: {
            HStack(spacing: isWide ? 14 : 10) {
                HStack(spacing: isWide ? 4 : 2) {
                    capsuleTransportButton(systemName: "backward.fill", size: skipSize, frame: buttonFrame) { player.previous() }
                    capsuleTransportButton(systemName: player.isPlaying ? "pause.fill" : "play.fill", size: playSize, frame: buttonFrame) { player.togglePlayPause() }
                    capsuleTransportButton(systemName: "forward.fill", size: skipSize, frame: buttonFrame) { player.next() }
                }
                .disabled(player.currentSong == nil)
                .opacity(player.currentSong == nil ? 0.35 : 1)

                if let song = player.currentSong {
                    ZStack {
                        Circle()
                            .fill(theme.accent.highlight.opacity(0.32))
                            .frame(width: coverSize + 6, height: coverSize + 6)
                            .blur(radius: 9)
                        CoverImage(url: song.coverURL, size: coverSize, cornerRadius: 8)
                            .frame(width: coverSize, height: coverSize)
                    }
                    .frame(width: coverSize + 6, height: coverSize + 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .font(ATMusicFont.appFont(titleSize, .semibold))
                            .foregroundStyle(Color.atmusicLabel)
                            .lineLimit(1)
                        Text(song.artist)
                            .font(ATMusicFont.appFont(artistSize))
                            .foregroundStyle(Color.atmusicComment)
                            .lineLimit(1)
                    }
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                        Image(systemName: "music.note")
                            .font(.system(size: 17))
                            .foregroundStyle(Color.atmusicComment)
                    }
                    .frame(width: coverSize + 6, height: coverSize + 6)
                    Text("未在播放")
                        .font(ATMusicFont.appFont(titleSize, .semibold))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                AirPlayRoutePicker(
                    tintColor: colorScheme == .dark ? .white : .black,
                    activeTintColor: UIColor(Color.atmusicAmber)
                )
                .frame(width: 32, height: 32)
            }
            .padding(.leading, isWide ? 20 : 14)
            .padding(.trailing, isWide ? 16 : 10)
            .padding(.vertical, 12)
            .background { capsuleBackground }
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.97))
        .iPadTransitionSource(in: nowPlayingTransition)
    }

    private func capsuleTransportButton(systemName: String, size: CGFloat, frame: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            ATMusicHaptics.tap()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Color.atmusicLabel)
                .frame(width: frame, height: frame)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 右侧主展示区 (Detail Content)

    @ViewBuilder
    private var detailHostContent: some View {
        GeometryReader { proxy in
            // 横屏内容区宽（约 894）与竖屏（约 534）用 740 分界。
            let isWide = proxy.size.width >= 740
            ZStack(alignment: .bottom) {
                detailMainView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // 注意：这里不能再给内容留底部空带——详情页自己的滚动内容
                    // 已有 120~190 的底部留白（主页 190），最后一行不会被胶囊盖住；
                    // 容器再缩 100 会把背景（GlassBackdrop）也截断，底部露出一截
                    // 系统白底，胶囊浮在白条上、磨砂效果全看不见（158 版教训）。
                    // 内容与背景都要伸到底、压到胶囊下面，磨砂才能透出底下的模糊影子。
                    .id(detailResetID)

                // 悬浮播放胶囊：横屏全屏、1/2 分屏、1/3 分屏、侧栏折叠，全部在内容区底部居中常驻
                //（对标 Apple Music：竖屏宽约内容区 88%，两侧各留约 32；横屏限宽 600，不拉太长；
                // 没在播时显示“未在播放”，也不消失；胶囊在详情 ZStack 最上层，所有页面都有）。
                floatingPlayerCapsule(isWide: isWide)
                    .frame(maxWidth: isWide ? 600 : .infinity)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder
    private var detailMainView: some View {
        switch activeSidebarItemClean {
        case .tab(.discover):
            DiscoverView(onOpenProfile: { activeDestination = .tab(.profile); selection = .profile })
        case .tab(.featured):
            FeaturedView(onOpenProfile: { activeDestination = .tab(.profile); selection = .profile })
        case .tab(.library):
            MusicLibraryHomeView(onOpenProfile: { activeDestination = .tab(.profile); selection = .profile })
        case .tab(.profile):
            ProfileView()
        case .tab(.search):
            SearchView()
        case .transferCenter:
            ATMusicNavigationStack {
                TransferCenterView()
            }
            .environmentObject(player)
            .environmentObject(theme)
            .environmentObject(auth)
        case .localMusic:
            ATMusicNavigationStack {
                LocalMusicBrowserView()
            }
            .environmentObject(player)
            .environmentObject(theme)
            .environmentObject(auth)
        case .history:
            ATMusicNavigationStack {
                MusicLibraryHistoryView()
            }
            .environmentObject(player)
            .environmentObject(theme)
        case .favorites:
            ATMusicNavigationStack {
                UnifiedFavoritesDetailView()
            }
            .environmentObject(player)
            .environmentObject(theme)
            .environmentObject(favorites)
        case .synology:
            ATMusicNavigationStack {
                SynologyFileLibraryView()
            }
            .environmentObject(player)
            .environmentObject(theme)
        case .settings:
            AnyView(
                SettingsView()
                    .environmentObject(theme)
                    .environmentObject(player)
                    .environmentObject(auth)
                    .environmentObject(favorites)
            )
        }
    }

    private var activeSidebarItemClean: IPadSidebarDestination {
        activeDestination
    }
}

private extension View {
    @ViewBuilder
    func iPadTransitionSource(in namespace: Namespace.ID?) -> some View {
        if let namespace, #available(iOS 18.0, *) {
            self.matchedTransitionSource(id: ATMusicNowPlayingTransitionID.surface, in: namespace)
        } else {
            self
        }
    }
}
