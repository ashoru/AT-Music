import SwiftUI

/// iPad 专属 Apple Music 风格侧边栏与多栏布局根视图
/// 采用 NavigationSplitView 两栏架构，左侧为分类侧边栏，右侧为主工作区，
/// 底部集成迷你播放器与 AirPlay 设备流转，在大屏下展现出媲美 Apple Music 的开阔感与层次感。
struct IPadRootView: View {
    @Binding var selection: RootTab
    @Binding var showPlayer: Bool
    var nowPlayingTransition: Namespace.ID

    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var favorites: FavoritesStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

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
                .navigationTitle("AT Music")
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - 侧边栏列表
    private var sidebarContent: some View {
        VStack(spacing: 0) {
            List {
                Section("发现") {
                    sidebarButton(.discover)
                    sidebarButton(.featured)
                    sidebarButton(.search)
                }

                Section("资料库") {
                    sidebarButton(.library)
                    sidebarButton(.profile)
                }

                Section("音频输出") {
                    HStack {
                        Label("隔空播放 (AirPlay)", systemImage: "airplayaudio")
                            .font(ATMusicFont.appFont(14))
                        Spacer()
                        AirPlayRoutePicker(
                            tintColor: colorScheme == .dark ? .white : .black,
                            activeTintColor: UIColor(Color.atmusicAmber)
                        )
                        .frame(width: 32, height: 32)
                    }
                }
            }
            .listStyle(.sidebar)

            // 侧栏底部固定迷你播放条
            if let song = player.currentSong {
                sidebarMiniPlayer(song: song)
            }
        }
    }

    private func sidebarButton(_ tab: RootTab) -> some View {
        Button {
            selection = tab
        } label: {
            Label(tab.title, systemImage: tab.icon)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 侧栏底置迷你播放组件
    private func sidebarMiniPlayer(song: Song) -> some View {
        HStack(spacing: 12) {
            CoverImage(url: song.coverURL, size: 44, cornerRadius: 8)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(song.title)
                    .font(ATMusicFont.appFont(14, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(1)

                Text(song.artist)
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.atmusicLabel)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)

            Button {
                player.nextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.atmusicComment)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .background(.ultraThinMaterial)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            showPlayer = true
        }
    }

    // MARK: - 右侧主展示区
    private var detailContent: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selection {
                case .discover:
                    DiscoverView(onOpenProfile: { selection = .profile })
                case .featured:
                    FeaturedView(onOpenProfile: { selection = .profile })
                case .library:
                    MusicLibraryHomeView(onOpenProfile: { selection = .profile })
                case .profile:
                    ProfileView()
                case .search:
                    SearchView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 当侧边栏在紧凑分屏下被收起时，在右侧主区域底部浮动展示迷你播放器
            if columnVisibility == .detailOnly, player.currentSong != nil {
                MiniPlayerView(
                    showPlayer: $showPlayer,
                    presentation: .dock,
                    transitionNamespace: nowPlayingTransition,
                    compact: false
                )
                .environmentObject(player.clock)
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}
