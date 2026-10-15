import SwiftUI

struct SongCell: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    @AppStorage("atmusic.showSongVIPBadge") private var showSongVIPBadge = true
    @AppStorage(ThirdPartyAudioQuality.downloadStorageKey) private var downloadQualityRaw = ThirdPartyAudioQuality.kb320.rawValue
    private let downloadFeatureUnlocked = true

    let song: Song
    var showCover = true
    /// 保留旧调用参数兼容；歌曲行统一使用 1.8.1 的连续紧凑样式，不再渲染单独玻璃卡片。
    var glassRow = false
    /// 需要整体玻璃容器时，单行保持纯净背景
    var suppressNativeCleanRowGlass = false
    var playbackContext: [Song] = []
    var playbackIndex: Int?
    var trackNumber: Int? = nil
    /// 副标题覆盖；nil 时按默认规则显示艺人/专辑
    var subtitleText: String? = nil
    var onTap: (() -> Void)?

    @State private var showAddToPlaylist = false
    @State private var shareFile: ShareFileItem?

    private var isCurrent: Bool {
        player.currentSong?.identityKey == song.identityKey
    }

    private var isNativeClean: Bool {
        ATMusicUIStyle(rawValue: uiStyleRaw) == .nativeClean
    }

    // MARK: - 四风格统一行规格（nativeClean 严格对标 Apple Music 列表）
    private var rowMinHeight: CGFloat { isNativeClean ? 56 : 64 }
    private var coverSize: CGFloat { isNativeClean ? 44 : 46 }
    private var coverRadius: CGFloat { isNativeClean ? 8 : 10 }
    private var subtitleFontSize: CGFloat { isNativeClean ? 13 : 12 }
    private var dividerLeading: CGFloat {
        (trackNumber != nil ? 38 : 0) + (showCover ? coverSize + 12 : 0)
    }
    private var resolvedSubtitle: String {
        if let subtitleText { return subtitleText }
        return song.artists.isEmpty ? song.album : song.artists
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            if let trackNumber {
                Text("\(trackNumber)")
                    .font(ATMusicFont.appFont(14, isCurrent ? .bold : .medium, .monospaced))
                    .foregroundStyle(isCurrent ? Color.atmusicAmber : Color.atmusicComment)
                    .frame(width: 26, alignment: .center)
            }
            if showCover {
                CoverImage(url: song.coverURL, size: coverSize, cornerRadius: coverRadius)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(song.name)
                        .font(ATMusicFont.appFont(15, isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Color.atmusicAmber : Color.atmusicLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Text(resolvedSubtitle)
                    .font(ATMusicFont.appFont(subtitleFontSize))
                    .foregroundStyle(Color.atmusicComment)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            if isCurrent && player.isPlaying {
                NowPlayingIndicator()
            }
            if showSongVIPBadge, song.isVIP {
                SongVIPBadgeView()
            }
            SourceBadgeView(source: song.source, compact: true)
            Text(song.formattedDuration)
                .font(ATMusicFont.appFont(12, .regular, .monospaced))
                .foregroundStyle(Color.atmusicComment)
                .frame(minWidth: 42, alignment: .trailing)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: rowMinHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
        .contextMenu {
            Button {
                player.playNext(song)
            } label: {
                Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button {
                showAddToPlaylist = true
            } label: {
                Label("添加到歌单", systemImage: "text.badge.plus")
            }
            if downloadFeatureUnlocked {
                Button {
                    Task { await downloadSong() }
                } label: {
                    Label("下载歌曲", systemImage: "arrow.down.circle")
                }
            }
            if !isCurrent {
                Button {
                    if let playbackIndex, !playbackContext.isEmpty {
                        player.play(songs: playbackContext, startAt: playbackIndex)
                    } else if let index = player.queue.firstIndex(of: song) {
                        player.playQueueIndex(index)
                    } else {
                        player.play(songs: [song], startAt: 0)
                    }
                } label: {
                    Label("立即播放", systemImage: "play.fill")
                }
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            AddToLocalPlaylistSheet(song: song)
                .environmentObject(theme)
        }
        .sheet(item: $shareFile) { item in
            ShareSheet(items: [item.url])
        }
    }

    @MainActor
    private func downloadSong() async {
        let quality: DownloadQuality
        if UserDefaults.standard.object(forKey: ThirdPartyAudioQuality.downloadStorageKey) == nil {
            quality = ThirdPartyAudioQuality.current
        } else {
            quality = DownloadQuality(sourceValue: downloadQualityRaw) ?? ThirdPartyAudioQuality.current
        }
        ATMusicHaptics.medium()
        ToastCenter.shared.show("开始下载：\(song.name)（\(quality.displayName)）")
        let result = await DownloadManager.shared.download(song: song, quality: quality)
        switch result {
        case .success(let downloaded):
            if downloaded.downgraded {
                ToastCenter.shared.show("目标音质不可用，已降级为 \(downloaded.actualQuality.displayName)", duration: 3)
            }
            shareFile = ShareFileItem(url: downloaded.url)
        case .failure(let error):
            ToastCenter.shared.show("下载失败：\(error.localizedDescription)", duration: 3)
        }
    }

    var body: some View {
        let _ = theme.accent
        rowContent
        // 行内细分隔线同时覆盖 List 与 LazyVStack 场景，确保专辑、歌手、NAS 文件夹和播放队列一致。
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.atmusicComment.opacity(0.18))
                .frame(height: 0.5)
                .padding(.leading, dividerLeading)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        // 高频滚动时单元格会反复进入/离开可视区域；不再为每一行建立入场动画状态，
        // 避免 LazyVStack/List 批量复用时触发成百次布局和合成。
    }
}
