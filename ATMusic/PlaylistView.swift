import SwiftUI

/// 歌单内排序方式
enum PlaylistSortMode: String, CaseIterable, Identifiable {
    case original = "默认"
    case name = "歌名"
    case duration = "时长"
    var id: String { rawValue }
}

struct PlaylistView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var favorites = FavoritesStore.shared
    @ObservedObject private var favoritePlaylists = FavoritePlaylistStore.shared

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
    @State private var showInfo = false
    @State private var isBatchDownloading = false
    @State private var isBatchUploading = false
    @State private var showNASPlaylistEditor = false
    @State private var showNASPlaylistDelete = false

    @MainActor
    private func batchDownloadPlaylist() {
        guard !displayedTracks.isEmpty else { return }
        isBatchDownloading = true
        ATMusicHaptics.medium()
        let quality: DownloadQuality
        let downloadQualityRaw = UserDefaults.standard.string(forKey: ThirdPartyAudioQuality.downloadStorageKey) ?? ThirdPartyAudioQuality.kb320.rawValue
        if UserDefaults.standard.object(forKey: ThirdPartyAudioQuality.downloadStorageKey) == nil {
            quality = ThirdPartyAudioQuality.current
        } else {
            quality = DownloadQuality(sourceValue: downloadQualityRaw) ?? ThirdPartyAudioQuality.current
        }
        DownloadManager.shared.startBatchDownload(songs: displayedTracks, quality: quality)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            isBatchDownloading = false
        }
    }

    @MainActor
    private func batchUploadPlaylistToNAS() {
        guard !displayedTracks.isEmpty, !isBatchUploading else { return }
        isBatchUploading = true
        ATMusicHaptics.medium()
        DownloadManager.shared.startBatchUploadToNAS(songs: displayedTracks)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            isBatchUploading = false
        }
    }
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
                } else if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                    iPadPlaylistLayout
                } else {
                    List {
                        header
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        Section {
                            ForEach(Array(displayedTracks.enumerated()), id: \.element.identityKey) { index, song in
                                // 1.8.1 的歌单内歌曲是连续列表，不是每首一张独立玻璃卡。
                                SongCell(song: song, playbackContext: displayedTracks, playbackIndex: index) {
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
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        favoritePlaylists.toggle(playlist)
                    } label: {
                        let isFav = favoritePlaylists.isFavorite(playlist)
                        Image(systemName: isFav ? "heart.fill" : "heart")
                            .foregroundStyle(isFav ? Color.red : Color.primary)
                    }
                    .accessibilityLabel(favoritePlaylists.isFavorite(playlist) ? "取消收藏歌单" : "收藏歌单")

                    Menu {
                        if !hideSortButton {
                            Picker("排序", selection: $sortMode) {
                                ForEach(PlaylistSortMode.allCases) { mode in
                                    Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                                }
                            }
                        }

                        Button {
                            batchDownloadPlaylist()
                        } label: {
                            Label(isBatchDownloading ? "正在加入下载..." : "下载全部歌曲", systemImage: "arrow.down.circle")
                        }
                        .disabled(displayedTracks.isEmpty || isBatchDownloading)

                        if playlist.source == .synology {
                            Button {
                                showNASPlaylistEditor = true
                            } label: {
                                Label("管理 NAS 歌单曲目", systemImage: "slider.horizontal.3")
                            }
                            Button(role: .destructive) {
                                showNASPlaylistDelete = true
                            } label: {
                                Label("删除 NAS 歌单", systemImage: "trash")
                            }
                        }

                        if SynologyAPI.shared.isLoggedIn && playlist.source != .synology {
                            Button {
                                batchUploadPlaylistToNAS()
                            } label: {
                                Label(isBatchUploading ? "正在加入归档..." : "全单归档至群晖 NAS", systemImage: "externaldrive.badge.plus")
                            }
                            .disabled(displayedTracks.isEmpty || isBatchUploading)
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
            .sheet(isPresented: $showNASPlaylistEditor) {
                NASPlaylistEditorSheet(playlist: playlist) { updated in
                    Task { await load(force: true) }
                    if updated == nil {
                        Task { await MainActor.run { dismissAfterDelete() } }
                    }
                }
            }
            .confirmationDialog("删除这个 NAS 歌单？", isPresented: $showNASPlaylistDelete, titleVisibility: .visible) {
                Button("删除「\(playlist.name)」", role: .destructive) {
                    Task {
                        try? await SynologyAPI.shared.deleteNASPlaylist(id: playlist.synologyPlaylistId ?? "\(playlist.id)")
                        SynologyAPI.shared.invalidateAllFolderCaches()
                        await MainActor.run {
                            ToastCenter.shared.show("歌单已删除")
                            dismissAfterDelete()
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("歌单会从 Audio Station 移除，歌曲文件本身不受影响。")
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

    private var iPadPlaylistLayout: some View {
        GeometryReader { proxy in
            let availableWidth = proxy.size.width
            if availableWidth >= 740 {
                widePlaylistLayout(availableWidth: availableWidth)
            } else {
                compactPlaylistLayout(availableWidth: availableWidth)
            }
        }
    }

    private func widePlaylistLayout(availableWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 28) {
            // 左栏：固定封面与歌单主要信息 (类似 Apple Music iPad 宽屏两栏)
            VStack(alignment: .leading, spacing: 18) {
                CoverImage(url: resolvedCoverURL ?? playlist.coverURL, size: 220, cornerRadius: 20)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: 220, height: 220)
                    .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 8)

                VStack(alignment: .leading, spacing: 6) {
                    Text(playlist.name)
                        .font(ATMusicFont.appFont(22, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        SourceBadgeView(source: playlist.source)
                        Text(displayCreatorName)
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicComment)
                    }

                    Text(atmusicSongCountText(tracks.isEmpty ? playlist.trackCount : tracks.count))
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment.opacity(0.85))

                    if let popularity = playlistPopularityText {
                        Text(popularity)
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                }

                HStack(spacing: 12) {
                    GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                        guard !displayedTracks.isEmpty else { return }
                        player.play(songs: displayedTracks, startAt: 0)
                    }
                    .disabled(displayedTracks.isEmpty)

                    GlassIconButton(systemName: "shuffle", size: 44, active: false) {
                        guard !displayedTracks.isEmpty else { return }
                        player.play(songs: displayedTracks.shuffled(), startAt: 0)
                    }
                    .disabled(displayedTracks.isEmpty)
                }

                playlistSearchRow

                if let desc = displayDescription {
                    Text(desc)
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(4)
                }

                Spacer(minLength: 0)
            }
            .frame(width: 240)
            .padding(.leading, 28)
            .padding(.top, 24)

            // 右栏：自适应网格或流畅滚动歌曲列表
            let rightWidth = availableWidth - 240 - 28 - 28 - 28
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("歌曲列表 (\(displayedTracks.count))")
                            .font(ATMusicFont.appFont(16, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                    }
                    .padding(.top, 24)

                    LazyVGrid(columns: DeviceLayoutHelper.songListColumns(forAvailableWidth: rightWidth, minWidth: 280, spacing: 14), spacing: 8) {
                        ForEach(Array(displayedTracks.enumerated()), id: \.element.identityKey) { index, song in
                            SongCell(song: song, playbackContext: displayedTracks, playbackIndex: index) {
                                player.play(songs: displayedTracks, startAt: index)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.primary.opacity(0.03))
                            }
                        }
                    }
                }
                .padding(.trailing, 28)
                .padding(.bottom, 120)
            }
        }
    }

    private func compactPlaylistLayout(availableWidth: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 顶部横向摘要横幅卡片：针对 iPad 竖屏、半分屏优化，杜绝左栏挤压
                HStack(alignment: .top, spacing: 16) {
                    CoverImage(url: resolvedCoverURL ?? playlist.coverURL, size: 130, cornerRadius: 16)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(width: 130, height: 130)
                        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 5)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(playlist.name)
                            .font(ATMusicFont.appFont(18, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                            .lineLimit(2)

                        HStack(spacing: 6) {
                            SourceBadgeView(source: playlist.source)
                            Text(displayCreatorName)
                                .font(ATMusicFont.appFont(12, .medium))
                                .foregroundStyle(Color.atmusicComment)
                        }

                        Text(atmusicSongCountText(tracks.isEmpty ? playlist.trackCount : tracks.count))
                            .font(ATMusicFont.appFont(11))
                            .foregroundStyle(Color.atmusicComment)

                        Spacer(minLength: 4)

                        HStack(spacing: 10) {
                            GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                guard !displayedTracks.isEmpty else { return }
                                player.play(songs: displayedTracks, startAt: 0)
                            }
                            .disabled(displayedTracks.isEmpty)

                            GlassIconButton(systemName: "shuffle", size: 38, active: false) {
                                guard !displayedTracks.isEmpty else { return }
                                player.play(songs: displayedTracks.shuffled(), startAt: 0)
                            }
                            .disabled(displayedTracks.isEmpty)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                playlistSearchRow
                    .padding(.horizontal, 20)

                HStack {
                    Text("歌曲列表 (\(displayedTracks.count))")
                        .font(ATMusicFont.appFont(16, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                    Spacer()
                }
                .padding(.horizontal, 20)

                LazyVGrid(columns: DeviceLayoutHelper.songListColumns(forAvailableWidth: availableWidth - 40, minWidth: 280, spacing: 12), spacing: 6) {
                    ForEach(Array(displayedTracks.enumerated()), id: \.element.identityKey) { index, song in
                        SongCell(song: song, playbackContext: displayedTracks, playbackIndex: index) {
                            player.play(songs: displayedTracks, startAt: index)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.primary.opacity(0.03))
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
            }
        }
    }

    /// 歌单内搜索框：播放全部下方独立一行（四种 UI 风格跟随主题）
    private var playlistSearchRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.atmusicComment)
            TextField("搜索歌单内歌曲", text: $searchText)
                .font(ATMusicFont.appFont(14))
                .tint(Color.atmusicAmber)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    ATMusicHaptics.tap()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.atmusicComment)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background {
            ATMusicSurface(shape: Capsule())
        }
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

            playlistSearchRow
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

    private func dismissAfterDelete() {
        dismiss()
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
