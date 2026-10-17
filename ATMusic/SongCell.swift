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
    /// 收藏列表模式：非 nil 时尾部显示红心按钮（替代时长），点击切换收藏
    var favoriteToggle: (() -> Void)? = nil
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
            if DownloadManager.shared.isDownloaded(song: song) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.atmusicAmber)
            } else if DownloadManager.shared.isDownloading(song: song) {
                ProgressView()
                    .scaleEffect(0.65)
                    .frame(width: 14, height: 14)
            }
            SourceBadgeView(source: song.source, compact: true)
            if let favoriteToggle {
                Button(action: favoriteToggle) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .frame(minWidth: 42, alignment: .trailing)
            } else {
                Text(song.formattedDuration)
                    .font(ATMusicFont.appFont(12, .regular, .monospaced))
                    .foregroundStyle(Color.atmusicComment)
                    .frame(minWidth: 42, alignment: .trailing)
            }
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
                if DownloadManager.shared.isDownloaded(song: song) {
                    if SynologyAPI.shared.isLoggedIn {
                        Button {
                            DownloadManager.shared.startUploadToNAS(song: song)
                        } label: {
                            Label("上传到群晖 NAS", systemImage: "externaldrive.badge.plus")
                        }
                    }
                    if let url = DownloadManager.shared.localAudioURL(for: song) {
                        Button {
                            shareFile = ShareFileItem(url: url)
                        } label: {
                            Label("分享 / 导出音频文件", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button(role: .destructive) {
                        DownloadManager.shared.removeDownloaded(song: song)
                    } label: {
                        Label("从本地移除下载", systemImage: "trash")
                    }
                } else {
                    Button {
                        downloadSong()
                    } label: {
                        Label(song.source == .synology ? "离线下载到本机" : "离线下载歌曲", systemImage: "arrow.down.circle")
                    }
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
    private func downloadSong() {
        let quality: DownloadQuality
        if UserDefaults.standard.object(forKey: ThirdPartyAudioQuality.downloadStorageKey) == nil {
            quality = ThirdPartyAudioQuality.current
        } else {
            quality = DownloadQuality(sourceValue: downloadQualityRaw) ?? ThirdPartyAudioQuality.current
        }
        ATMusicHaptics.medium()
        DownloadManager.shared.startDownload(song: song, quality: quality)
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
