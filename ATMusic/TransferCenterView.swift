import SwiftUI

// MARK: - 传输中心（离线下载队列 · 本地离线库 · 群晖 NAS 归档上传）

struct TransferCenterView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore
    @ObservedObject private var downloadManager = DownloadManager.shared
    @ObservedObject private var synology = SynologyAPI.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: Int = 0
    @State private var offlineFilter: Int = 0 // 0: 单曲, 1: 专辑, 2: 歌手
    @State private var shareFile: ShareFileItem?

    private var activeDownloadsCount: Int {
        downloadManager.activeDownloads.filter { $0.status != .completed }.count
    }

    private var activeUploadsCount: Int {
        downloadManager.activeUploads.filter { $0.status != .completed }.count
    }

    private var offlineAlbums: [(name: String, artist: String, coverURL: URL?, songs: [Song])] {
        let grouped = Dictionary(grouping: downloadManager.downloadedSongs) { song in
            let album = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
            return album.isEmpty ? "单曲" : album
        }
        return grouped.map { name, songs in
            (name, songs.first?.artists ?? "未知歌手", songs.first?.coverURL, songs)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var offlineArtists: [(name: String, coverURL: URL?, songs: [Song])] {
        var map: [String: [Song]] = [:]
        for song in downloadManager.downloadedSongs {
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

            VStack(spacing: 0) {
                navigationHeader
                tabSelector
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                TabView(selection: $selectedTab) {
                    downloadQueueSection
                        .tag(0)
                    offlineLibrarySection
                        .tag(1)
                    nasUploadSection
                        .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .frame(maxWidth: DeviceLayoutHelper.contentMaxWidth(for: horizontalSizeClass))
            .frame(maxWidth: .infinity)
        }
        .navigationBarHidden(true)
        .sheet(item: $shareFile) { item in
            ShareSheet(items: [item.url])
        }
    }

    // MARK: - 导航栏

    private var navigationHeader: some View {
        HStack(alignment: .center) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                    Text("音乐库")
                        .font(ATMusicFont.appFont(16))
                }
                .foregroundStyle(Color.atmusicAmber)
            }
            .buttonStyle(.plain)

            Spacer()

            Text("传输中心")
                .font(ATMusicFont.appFont(17, .bold))
                .foregroundStyle(Color.atmusicLabel)

            Spacer()

            if selectedTab == 0 && !downloadManager.activeDownloads.isEmpty {
                Button {
                    if downloadManager.isPaused {
                        downloadManager.resumeAllDownloads()
                    } else {
                        downloadManager.pauseAllDownloads()
                    }
                } label: {
                    Image(systemName: downloadManager.isPaused ? "play.circle" : "pause.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.atmusicAmber)
                }
                .buttonStyle(.plain)
            } else if selectedTab == 1 && !downloadManager.downloadedSongs.isEmpty {
                Button {
                    player.play(songs: downloadManager.downloadedSongs, startAt: 0)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.atmusicAmber)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 44, height: 20)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    // MARK: - 顶部标签切换器

    private var tabSelector: some View {
        HStack(spacing: 8) {
            tabButton(title: "下载中\(activeDownloadsCount > 0 ? " (\(activeDownloadsCount))" : "")", index: 0, icon: "arrow.down.circle")
            tabButton(title: "已离线 (\(downloadManager.downloadedSongs.count))", index: 1, icon: "internaldrive")
            tabButton(title: "上传至 NAS\(activeUploadsCount > 0 ? " (\(activeUploadsCount))" : "")", index: 2, icon: "externaldrive")
        }
    }

    private func tabButton(title: String, index: Int, icon: String) -> some View {
        let isSelected = selectedTab == index
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedTab = index
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isSelected ? "\(icon).fill" : icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(ATMusicFont.appFont(13, isSelected ? .bold : .medium))
            }
            .foregroundStyle(isSelected ? Color.white : Color.atmusicComment)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.atmusicAmber)
                } else {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 1. 正在下载视图

    private var downloadQueueSection: some View {
        ScrollView {
            VStack(spacing: 12) {
                if !downloadManager.activeDownloads.isEmpty {
                    downloadGlobalControlBanner
                }

                if downloadManager.activeDownloads.isEmpty {
                    emptyStateView(
                        icon: "arrow.down.circle",
                        title: "暂无正在下载的任务",
                        subtitle: "在歌曲、专辑或歌单中点击下载，即可在此查看实时进度与网速"
                    )
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(downloadManager.activeDownloads) { task in
                            downloadTaskRow(task)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 140)
        }
    }

    private var downloadGlobalControlBanner: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("下载速率")
                        .font(ATMusicFont.appFont(12, .medium))
                        .foregroundStyle(Color.atmusicComment)
                    Text(downloadManager.formattedDownloadSpeed)
                        .font(ATMusicFont.appFont(14, .bold, .monospaced))
                        .foregroundStyle(Color.atmusicAmber)
                }
                Text("剩余 \(activeDownloadsCount) 首歌曲排队中")
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment.opacity(0.8))
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    if downloadManager.isPaused {
                        downloadManager.resumeAllDownloads()
                    } else {
                        downloadManager.pauseAllDownloads()
                    }
                } label: {
                    Text(downloadManager.isPaused ? "全部继续" : "全部暂停")
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    downloadManager.clearFinishedDownloads()
                } label: {
                    Text("清除已完成")
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(Color.atmusicComment)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(.horizontal, 16)
    }

    private func downloadTaskRow(_ task: DownloadTaskItem) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                CoverImage(url: task.song.coverURL, size: 48, cornerRadius: 10)
                SourceBadgeView(source: task.song.source, compact: true)
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(task.song.name)
                        .font(ATMusicFont.appFont(14, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(1)
                    Spacer()
                    Text(task.requestedQuality.displayName)
                        .font(ATMusicFont.appFont(10, .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.atmusicAmber.opacity(0.15), in: Capsule())
                }

                Text(task.song.artists)
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
                    .lineLimit(1)

                ProgressView(value: task.progress)
                    .tint(Color.atmusicAmber)
                    .scaleEffect(x: 1, y: 0.8, anchor: .center)

                HStack {
                    Text(task.statusDescription)
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(task.status == .completed ? Color.atmusicSage : Color.atmusicComment)

                    Spacer()

                    if task.status == .downloading {
                        Text("\(task.formattedProgress) · \(task.formattedSpeed)")
                            .font(ATMusicFont.appFont(10, .regular, .monospaced))
                            .foregroundStyle(Color.atmusicComment)
                    }
                }
            }

            // 控制按键
            HStack(spacing: 10) {
                if task.status == .downloading {
                    Button {
                        downloadManager.pauseDownload(id: task.id)
                    } label: {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    .buttonStyle(.plain)
                } else if task.status == .paused {
                    Button {
                        downloadManager.resumeDownload(id: task.id)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    downloadManager.cancelDownload(id: task.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.atmusicComment.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - 2. 已离线歌曲库视图

    private var offlineLibrarySection: some View {
        ScrollView {
            VStack(spacing: 14) {
                offlineSummaryCard

                if !downloadManager.downloadedSongs.isEmpty {
                    offlineFilterPicker
                }

                if downloadManager.downloadedSongs.isEmpty {
                    emptyStateView(
                        icon: "internaldrive",
                        title: "暂无离线歌曲",
                        subtitle: "下载后的歌曲将自动保存在本机受管沙盒，支持无网络离线 0ms 极速秒播"
                    )
                } else if offlineFilter == 0 {
                    // 单曲列表
                    LazyVStack(spacing: 0) {
                        ForEach(downloadManager.downloadedSongs) { song in
                            SongCell(song: song)
                        }
                    }
                    .padding(.horizontal, 16)
                    .background {
                        ATMusicGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .padding(.horizontal, 16)
                } else if offlineFilter == 1 {
                    // 按专辑聚合
                    LazyVStack(spacing: 10) {
                        ForEach(offlineAlbums, id: \.name) { album in
                            HStack(spacing: 12) {
                                CoverImage(url: album.coverURL, size: 48, cornerRadius: 8)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(album.name)
                                        .font(ATMusicFont.appFont(15, .semibold))
                                        .foregroundStyle(Color.atmusicLabel)
                                    Text("\(album.artist) · \(album.songs.count) 首")
                                        .font(ATMusicFont.appFont(12))
                                        .foregroundStyle(Color.atmusicComment)
                                }
                                Spacer()
                                Button {
                                    player.play(songs: album.songs, startAt: 0)
                                } label: {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 24))
                                        .foregroundStyle(Color.atmusicAmber)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(12)
                            .background {
                                ATMusicGlass(shape: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                } else {
                    // 按歌手聚合
                    LazyVStack(spacing: 10) {
                        ForEach(offlineArtists, id: \.name) { artist in
                            HStack(spacing: 12) {
                                CoverImage(url: artist.coverURL, size: 48, cornerRadius: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(artist.name)
                                        .font(ATMusicFont.appFont(15, .semibold))
                                        .foregroundStyle(Color.atmusicLabel)
                                    Text("\(artist.songs.count) 首离线歌曲")
                                        .font(ATMusicFont.appFont(12))
                                        .foregroundStyle(Color.atmusicComment)
                                }
                                Spacer()
                                Button {
                                    player.play(songs: artist.songs, startAt: 0)
                                } label: {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 24))
                                        .foregroundStyle(Color.atmusicAmber)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(12)
                            .background {
                                ATMusicGlass(shape: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 140)
        }
    }

    private var offlineSummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本地受管离线库")
                        .font(ATMusicFont.appFont(16, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text("已离线 \(downloadManager.downloadedSongs.count) 首歌曲 · 占用设备约 \(downloadManager.formattedDownloadedSize)")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                }
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.atmusicAmber)
            }

            if !downloadManager.downloadedSongs.isEmpty {
                HStack(spacing: 10) {
                    Button {
                        player.play(songs: downloadManager.downloadedSongs, startAt: 0)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11))
                            Text("顺序播放")
                                .font(ATMusicFont.appFont(12, .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.atmusicAmber, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        player.play(songs: downloadManager.downloadedSongs.shuffled(), startAt: 0)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "shuffle")
                                .font(.system(size: 11))
                            Text("随机播放")
                                .font(ATMusicFont.appFont(12, .semibold))
                        }
                        .foregroundStyle(Color.atmusicLabel)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    if synology.isLoggedIn {
                        Button {
                            downloadManager.startBatchUploadToNAS(songs: downloadManager.downloadedSongs)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "externaldrive.badge.plus")
                                    .font(.system(size: 11))
                                Text("全量归档至 NAS")
                                    .font(ATMusicFont.appFont(12, .semibold))
                            }
                            .foregroundStyle(Color.atmusicLabel)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(.horizontal, 16)
    }

    private var offlineFilterPicker: some View {
        HStack(spacing: 8) {
            filterButton(title: "单曲", index: 0)
            filterButton(title: "专辑", index: 1)
            filterButton(title: "歌手", index: 2)
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private func filterButton(title: String, index: Int) -> some View {
        let isSelected = offlineFilter == index
        return Button {
            withAnimation { offlineFilter = index }
        } label: {
            Text(title)
                .font(ATMusicFont.appFont(12, isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.atmusicAmber : Color.atmusicComment)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background {
                    if isSelected {
                        Capsule().fill(Color.atmusicAmber.opacity(0.16))
                    } else {
                        Capsule().fill(Color.clear)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 3. 群晖 NAS 上传归档视图

    private var nasUploadSection: some View {
        ScrollView {
            VStack(spacing: 12) {
                nasStatusCard

                if !downloadManager.activeUploads.isEmpty {
                    uploadGlobalControlBanner
                }

                if downloadManager.activeUploads.isEmpty {
                    emptyStateView(
                        icon: "externaldrive.badge.plus",
                        title: "暂无上传归档任务",
                        subtitle: "在已离线歌曲列表中点击「上传归档到群晖 NAS」，即可自动将音频、同名歌词与封面打包备份至您的 NAS 音乐库"
                    )
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(downloadManager.activeUploads) { task in
                            uploadTaskRow(task)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 140)
        }
    }

    private var nasStatusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: synology.isLoggedIn ? "externaldrive.badge.checkmark" : "externaldrive.trianglebadge.exclamationmark")
                .font(.system(size: 28))
                .foregroundStyle(synology.isLoggedIn ? Color.atmusicSage : Color.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text(synology.isLoggedIn ? "群晖 NAS · 已连接" : "群晖 NAS · 未登录")
                    .font(ATMusicFont.appFont(15, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                if synology.isLoggedIn {
                    Text("\(synology.isLanActive ? "局域网高速直连" : "公网连接") · 归档目录：/music/ATMusic")
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                } else {
                    Text("请先登录群晖账号，以使用歌曲云端双向归档功能")
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                }
            }
            Spacer()
        }
        .padding(14)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .padding(.horizontal, 16)
    }

    private var uploadGlobalControlBanner: some View {
        HStack {
            Text("上传队列（\(activeUploadsCount) 首正在处理）")
                .font(ATMusicFont.appFont(13, .semibold))
                .foregroundStyle(Color.atmusicLabel)
            Spacer()
            Button("清空已完成") {
                downloadManager.clearFinishedUploads()
            }
            .font(ATMusicFont.appFont(12))
            .foregroundStyle(Color.atmusicComment)
        }
        .padding(.horizontal, 16)
    }

    private func uploadTaskRow(_ task: UploadTaskItem) -> some View {
        HStack(spacing: 12) {
            CoverImage(url: task.song.coverURL, size: 48, cornerRadius: 10)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.song.name)
                    .font(ATMusicFont.appFont(14, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(1)

                Text(task.song.artists)
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
                    .lineLimit(1)

                ProgressView(value: task.progress)
                    .tint(Color.atmusicSage)
                    .scaleEffect(x: 1, y: 0.8, anchor: .center)

                HStack {
                    Text(task.statusDescription)
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(task.status == .completed ? Color.atmusicSage : Color.atmusicComment)
                    Spacer()
                    if task.status == .uploadingAudio {
                        Text("\(task.formattedProgress) · \(task.formattedSpeed)")
                            .font(ATMusicFont.appFont(10, .regular, .monospaced))
                            .foregroundStyle(Color.atmusicComment)
                    }
                }
            }

            HStack(spacing: 10) {
                if case .failed = task.status {
                    Button {
                        downloadManager.retryUpload(id: task.id)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    downloadManager.cancelUpload(id: task.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.atmusicComment.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - 空状态辅助视图

    private func emptyStateView(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.atmusicComment.opacity(0.6))
                .padding(.top, 40)
            Text(title)
                .font(ATMusicFont.appFont(16, .bold))
                .foregroundStyle(Color.atmusicLabel)
            Text(subtitle)
                .font(ATMusicFont.appFont(12))
                .foregroundStyle(Color.atmusicComment)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
