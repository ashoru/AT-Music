import SwiftUI

/// 歌单内排序方式
enum PlaylistSortMode: String, CaseIterable, Identifiable {
    case original = "默认"
    case name = "歌名"
    case duration = "时长"
    var id: String { rawValue }
}

struct PlaylistView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var theme: ThemeStore
    @ObservedObject private var favorites = FavoritesStore.shared

    let playlist: Playlist
    @State private var tracks: [Song] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var resolvedCoverURL: URL?
    @State private var resolvedCreatorName: String?
    @State private var resolvedDescriptionText: String?
    @State private var resolvedPopularity: Int?
    @State private var searchText = ""
    @State private var sortMode: PlaylistSortMode = .original
    @State private var showSearch = false
    @State private var showInfo = false
    @AppStorage("atmusic.homeHeaderHideSort") private var hideSortButton = false
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue

    private var isNativeClean: Bool {
        ATMusicUIStyle(rawValue: uiStyleRaw) == .nativeClean
    }

    private var playlistPopularityText: String? {
        guard let value = resolvedPopularity ?? playlist.popularity, value > 0 else { return nil }
        if value >= 100_000_000 { return String(format: "播放 %.1f 亿", Double(value) / 100_000_000) }
        if value >= 10_000 { return String(format: "播放 %.1f 万", Double(value) / 10_000) }
        return "播放 \(value)"
    }

    private var displayCreatorName: String {
        let resolved = resolvedCreatorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !resolved.isEmpty { return resolved }
        let source = playlist.creatorName.trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty ? playlist.source.atmusicDisplayName : source
    }

    private var displayDescription: String? {
        let resolved = resolvedDescriptionText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !resolved.isEmpty { return resolved }
        let source = playlist.descriptionText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return source.isEmpty ? nil : source
    }

    private var cacheAccountID: String {
        switch playlist.source {
        case .netease:
            return "\(auth.user?.uid ?? 0)"
        case .qq:
            let qqAuth = QQMusicAuth.shared
            return qqAuth.rawUin.isEmpty ? qqAuth.playlistUin : qqAuth.rawUin
        case .kugou:
            return KugouMusicAuth.shared.userId
        case .local:
            return "local"
        case .synology:
            return SynologyAPI.shared.account
        }
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
                        Task { await load(force: true) }
                    }
                } else {
                    List {
                        header
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        Section {
                            ForEach(Array(displayedTracks.enumerated()), id: \.element.identityKey) { index, song in
                                // 1.8.1 的歌单内歌曲是连续列表，不是每首一张独立玻璃卡。
                                PlaylistTrackRow(song: song, playbackContext: displayedTracks, playbackIndex: index) {
                                    player.play(songs: displayedTracks, startAt: index)
                                }
                                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Text("歌曲")
                                    .font(ATMusicFont.appFont(16, .bold))
                                Text(atmusicSongCountText(displayedTracks.count))
                                    .font(ATMusicFont.appFont(12, .medium))
                                    .foregroundStyle(Color.atmusicComment)
                                Spacer()
                            }
                            .textCase(nil)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                        }
                    }
                    .atmusicScrollContentBackgroundHidden()
                    .listStyle(.plain)
                    }
            }
            }
            .navigationTitle(playlist.name)
            .navigationBarTitleDisplayMode(.inline)
            .modifier(PlaylistSearchModifier(enabled: showSearch, text: $searchText))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            ATMusicHaptics.tap()
                            showSearch.toggle()
                            if !showSearch { searchText = "" }
                        } label: {
                            Label(showSearch ? "关闭搜索" : "搜索歌单", systemImage: "magnifyingglass")
                        }

                        if !hideSortButton {
                            Picker("排序", selection: $sortMode) {
                                ForEach(PlaylistSortMode.allCases) { mode in
                                    Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                                }
                            }
                        }

                        if displayDescription != nil || playlistPopularityText != nil {
                            Button {
                                ATMusicHaptics.tap()
                                showInfo = true
                            } label: {
                                Label("歌单信息", systemImage: "info.circle")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("更多")
                }
            }
            .sheet(isPresented: $showInfo) {
                PlaylistInfoSheet(
                    name: playlist.name,
                    source: playlist.source,
                    creator: displayCreatorName,
                    songCount: tracks.isEmpty ? playlist.trackCount : tracks.count,
                    popularity: playlistPopularityText,
                    description: displayDescription
                )
            }
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: isNativeClean ? 14 : 12) {
                CoverImage(url: resolvedCoverURL ?? playlist.coverURL, size: 80, cornerRadius: 14)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(playlist.name)
                            .font(ATMusicFont.appFont(17, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                            .lineLimit(2)
                        SourceBadgeView(source: playlist.source)
                    }

                    Text(displayCreatorName)
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(1)

                    Text(atmusicSongCountText(tracks.isEmpty ? playlist.trackCount : tracks.count))
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                    guard !displayedTracks.isEmpty else { return }
                    player.play(songs: displayedTracks, startAt: 0)
                }
                .disabled(displayedTracks.isEmpty)

                GlassIconButton(systemName: "shuffle", size: 42, active: false) {
                    guard !displayedTracks.isEmpty else { return }
                    player.play(songs: displayedTracks.shuffled(), startAt: 0)
                }
                .disabled(displayedTracks.isEmpty)
                .accessibilityLabel("随机播放")

                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
    }

    /// 歌单内搜索 + 排序后的列表
    private var displayedTracks: [Song] {
        var list = tracks
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !kw.isEmpty {
            list = list.filter { song in
                song.name.lowercased().contains(kw)
                    || song.artists.lowercased().contains(kw)
                    || song.album.lowercased().contains(kw)
            }
        }
        switch sortMode {
        case .original: break
        case .name:
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .duration:
            list.sort { $0.duration < $1.duration }
        }
        return list
    }

    private func load(force: Bool = false) async {
        let cache = SyncedPlaylistCache.shared
        if let cached = cache.cachedSongs(playlist: playlist, accountID: cacheAccountID) {
            tracks = cached.songs
            resolvedCoverURL = cached.songs.first?.coverURL
            loading = false
            if !force, cache.isFresh(cached) {
                return
            }
        } else {
            loading = true
        }
        errorMessage = nil
        ATMusicLogger.shared.log("歌单页面打开 source=\(playlist.source.rawValue) id=\(playlist.id) name=\(playlist.name) advertisedCount=\(playlist.trackCount)", level: .info)
        do {
            if playlist.source == .synology {
                tracks = try await SynologyAPI.shared.playlistSongs(playlistId: playlist.synologyPlaylistId ?? "\(playlist.id)")
            } else if playlist.source == .kugou {
                tracks = try await KugouMusicAPI.shared.playlistSongs(listID: playlist.id)
            } else if playlist.source == .qq {
                tracks = try await QQMusicAPI.shared.playlistSongs(listID: playlist.id)
                // 云端收藏接口临时被风控或返回空时，至少展示已同步到本机的 QQ 收藏，
                // 避免“我的喜欢”进入后变成空白页面。
                if tracks.isEmpty, playlist.id == QQMusicAPI.qqLikedPlaylistID {
                    tracks = favorites.qqFavoriteSongs
                    ATMusicLogger.shared.log("QQ 我的喜欢页面网络结果为空，使用本地收藏回退 count=\(tracks.count)", level: tracks.isEmpty ? .warn : .info)
                }
            } else {
                async let remoteTracks = NetEaseAPI.shared.playlistTracks(id: playlist.id)
                async let metadata = try? NetEaseAPI.shared.playlistMetadata(id: playlist.id)
                tracks = try await remoteTracks
                if let metadata = await metadata {
                    resolvedCreatorName = metadata.creatorName
                    resolvedDescriptionText = metadata.descriptionText
                    resolvedPopularity = metadata.popularity
                }
            }
            if resolvedCoverURL == nil {
                resolvedCoverURL = tracks.first?.coverURL
            }
            if !tracks.isEmpty {
                cache.saveSongs(tracks, playlist: playlist, accountID: cacheAccountID)
            }
            ATMusicLogger.shared.log("歌单页面加载完成 source=\(playlist.source.rawValue) id=\(playlist.id) name=\(playlist.name) count=\(tracks.count) error=无", level: tracks.isEmpty ? .warn : .info)
            loading = false
        } catch {
            if tracks.isEmpty {
                errorMessage = error.localizedDescription
            } else {
                ATMusicLogger.shared.log("歌单页面刷新失败，继续使用缓存 source=\(playlist.source.rawValue) id=\(playlist.id) error=\(error.localizedDescription)", level: .warn)
            }
            ATMusicLogger.shared.log("歌单页面加载失败 source=\(playlist.source.rawValue) id=\(playlist.id) name=\(playlist.name) error=\(error.localizedDescription)", level: .error)
            loading = false
        }
    }
}

private struct PlaylistSearchModifier: ViewModifier {
    let enabled: Bool
    @Binding var text: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.searchable(
                text: $text,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: LocalizedStringKey("搜索歌单内歌曲")
            )
        } else {
            content
        }
    }
}

private struct PlaylistInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    let source: SongSource
    let creator: String
    let songCount: Int
    let popularity: String?
    let description: String?

    var body: some View {
        ATMusicNavigationStack {
            List {
                Section {
                    LabeledContent("来源", value: source.atmusicDisplayName)
                    LabeledContent("创建者", value: creator)
                    LabeledContent("歌曲", value: "\(songCount) 首")
                    if let popularity { LabeledContent("热度", value: popularity) }
                }
                if let description, !description.isEmpty {
                    Section("简介") {
                        Text(description)
                            .font(ATMusicFont.appFont(13))
                            .foregroundStyle(Color.atmusicLabel)
                            .textSelection(.enabled)
                    }
                }
            }
            .atmusicScrollContentBackgroundHidden()
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

/// 1.8.1 歌单详情中的紧凑歌曲行：连续排列、统一行高、只用细分隔线区分歌曲。
private struct PlaylistTrackRow: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore
    @AppStorage("atmusic.showSongVIPBadge") private var showSongVIPBadge = true
    @AppStorage(ThirdPartyAudioQuality.downloadStorageKey) private var downloadQualityRaw = ThirdPartyAudioQuality.kb320.rawValue

    @State private var showAddToPlaylist = false
    @State private var shareFile: ShareFileItem?

    let song: Song
    let playbackContext: [Song]
    let playbackIndex: Int
    let onTap: () -> Void

    private var isCurrent: Bool { player.currentSong?.identityKey == song.identityKey }

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: song.coverURL, size: 46, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(song.name)
                        .font(ATMusicFont.appFont(15, isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Color.atmusicAmber : Color.atmusicLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(song.artists.isEmpty ? song.album : song.artists)
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.atmusicComment.opacity(0.18))
                .frame(height: 0.5)
                .padding(.leading, 58)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
            Button {
                player.playNext(song)
            } label: {
                Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button {
                player.play(songs: playbackContext, startAt: playbackIndex)
            } label: {
                Label("立即播放", systemImage: "play.fill")
            }
            Divider()
            Button {
                showAddToPlaylist = true
            } label: {
                Label("加入歌单", systemImage: "text.badge.plus")
            }
            Button {
                Task { await downloadSong() }
            } label: {
                Label("下载歌曲", systemImage: "arrow.down.circle")
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
}
