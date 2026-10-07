import SwiftUI
import MediaPlayer
import AVKit

/// iPad 专属 Apple Music 风格侧边分栏播放器
/// 左侧：大尺寸专辑封面、完整曲目信息、进度拖拽条、播放控制中控台、音量滑块与 AirPlay 选择器
/// 右侧：实时动态同滚动步歌词 / 待播清单（Queue）分栏无缝切换
struct IPadPlayerView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var clock: PlaybackClock
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var favorites: FavoritesStore
    @ObservedObject private var localLibrary = LocalLibraryStore.shared
    @Environment(\.colorScheme) private var colorScheme

    let song: Song?
    let lyrics: [LyricLine]
    let onFavorite: () -> Void
    let onQueue: () -> Void
    let onComments: () -> Void
    let onSleepTimer: () -> Void
    let onAddToLocalPlaylist: () -> Void
    let onDownload: () -> Void
    let onPlayerSettings: () -> Void
    let onSearchLyrics: () -> Void
    let onDismiss: () -> Void

    @State private var rightPaneMode: RightPaneMode = .lyrics
    @State private var isDraggingScrubber = false
    @State private var scrubProgress: Double = 0
    @State private var autoScrollEnabled = true
    @State private var volume: Float = 0.5

    enum RightPaneMode: String, CaseIterable, Identifiable {
        case lyrics = "实时歌词"
        case queue = "待播清单"

        public var id: String { rawValue }
        public var icon: String {
            switch self {
            case .lyrics: return "quote.bubble.fill"
            case .queue: return "list.bullet"
            }
        }
    }

    init(
        song: Song?,
        lyrics: [LyricLine],
        onFavorite: @escaping () -> Void,
        onQueue: @escaping () -> Void,
        onComments: @escaping () -> Void,
        onSleepTimer: @escaping () -> Void,
        onAddToLocalPlaylist: @escaping () -> Void,
        onDownload: @escaping () -> Void,
        onPlayerSettings: @escaping () -> Void,
        onSearchLyrics: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.song = song
        self.lyrics = lyrics
        self.onFavorite = onFavorite
        self.onQueue = onQueue
        self.onComments = onComments
        self.onSleepTimer = onSleepTimer
        self.onAddToLocalPlaylist = onAddToLocalPlaylist
        self.onDownload = onDownload
        self.onPlayerSettings = onPlayerSettings
        self.onSearchLyrics = onSearchLyrics
        self.onDismiss = onDismiss
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // 流体背景
                CoverBlurBackground(url: song?.coverURL, scheme: colorScheme)
                    .overlay(Color.black.opacity(colorScheme == .dark ? 0.45 : 0.20))
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    topNavigationBar
                        .padding(.horizontal, 28)
                        .padding(.top, 16)
                        .padding(.bottom, 8)

                    // 左右分栏主体
                    HStack(spacing: 36) {
                        // 左栏：封面与播放主控制台
                        leftPlaybackColumn(containerWidth: proxy.size.width)
                            .frame(width: min(max(proxy.size.width * 0.42, 380), 500))

                        // 右栏：歌词 / 播放队列
                        rightContentColumn
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    // MARK: - 顶栏
    private var topNavigationBar: some View {
        HStack(spacing: 16) {
            Button(action: onDismiss) {
                Image(systemName: "chevron.down.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)

            if let song {
                HStack(spacing: 6) {
                    Text(song.source.displayName)
                        .font(ATMusicFont.appFont(11, .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.2)))
                        .foregroundStyle(.white.opacity(0.9))

                    if song.isVIP {
                        Text("VIP")
                            .font(ATMusicFont.appFont(10, .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.atmusicAmber))
                            .foregroundStyle(.black)
                    }
                }
            }

            Spacer()

            // 系统原生 AirPlay 投播
            AirPlayRoutePicker(tintColor: .white.withAlphaComponent(0.85))
                .frame(width: 32, height: 32)

            // 定时关闭
            Button(action: onSleepTimer) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(player.sleepTimerRemaining > 0 ? Color.atmusicAmber : .white.opacity(0.85))
            }
            .buttonStyle(.plain)

            // 收藏状态
            Button(action: onFavorite) {
                Image(systemName: isCurrentFavorited ? "heart.fill" : "heart")
                    .font(.system(size: 19))
                    .foregroundStyle(isCurrentFavorited ? .red : .white.opacity(0.85))
            }
            .buttonStyle(.plain)

            // 更多操作菜单
            Menu {
                Button(action: onAddToLocalPlaylist) {
                    Label("添加到自建歌单", systemImage: "text.badge.plus")
                }
                Button(action: onDownload) {
                    Label("下载本曲", systemImage: "arrow.down.circle")
                }
                Button(action: onSearchLyrics) {
                    Label("手动检索歌词", systemImage: "text.magnifyingglass")
                }
                Button(action: onComments) {
                    Label("查看歌曲评论", systemImage: "text.bubble")
                }
                Divider()
                Button(action: onPlayerSettings) {
                    Label("播放器视觉设置", systemImage: "slider.horizontal.3")
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private var isCurrentFavorited: Bool {
        guard let song else { return false }
        return favorites.contains(song: song) || localLibrary.containsSong(song)
    }

    // MARK: - 左栏（封面 + 控制区）
    private func leftPlaybackColumn(containerWidth: CGFloat) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)

            // 大尺寸专辑封面
            CoverImage(url: song?.coverURL, size: 340, cornerRadius: 20)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 12)
                .scaleEffect(player.isPlaying ? 1.0 : 0.94)
                .animation(.spring(response: 0.45, dampingFraction: 0.75), value: player.isPlaying)
                .padding(.horizontal, 12)

            // 歌曲信息
            VStack(alignment: .leading, spacing: 6) {
                Text(song?.title ?? "未在播放")
                    .font(ATMusicFont.appFont(24, .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(song?.artist ?? "AT Music")
                    .font(ATMusicFont.appFont(17, .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)

            // 进度条
            playbackScrubber
                .padding(.horizontal, 14)

            // 核心播放按钮
            transportControlsRow

            // 快捷音量控制条
            volumeControlRow
                .padding(.horizontal, 14)

            Spacer(minLength: 0)
        }
    }

    // MARK: - 进度条组件
    private var playbackScrubber: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let current = isDraggingScrubber ? scrubProgress * max(clock.duration, 1) : clock.currentTime
                let total = max(clock.duration, 1)
                let pct = min(max(current / total, 0), 1)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .frame(height: 6)

                    Capsule()
                        .fill(Color.atmusicAmber)
                        .frame(width: geo.size.width * CGFloat(pct), height: 6)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            isDraggingScrubber = true
                            let progress = min(max(val.location.x / geo.size.width, 0), 1)
                            scrubProgress = Double(progress)
                        }
                        .onEnded { val in
                            let progress = min(max(val.location.x / geo.size.width, 0), 1)
                            let target = Double(progress) * clock.duration
                            player.seek(to: target)
                            isDraggingScrubber = false
                        }
                )
            }
            .frame(height: 14)

            HStack {
                let current = isDraggingScrubber ? scrubProgress * clock.duration : clock.currentTime
                Text(formatTime(current))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))

                Spacer()

                Text("-\(formatTime(max(clock.duration - current, 0)))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    // MARK: - 播放控制按键行
    private var transportControlsRow: some View {
        HStack(spacing: 32) {
            // 随机播放切换
            Button {
                player.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(player.isShuffled ? Color.atmusicAmber : .white.opacity(0.65))
            }
            .buttonStyle(.plain)

            // 上一曲
            Button {
                player.previousTrack()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            // 播放 / 暂停 大按钮
            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 66, height: 66)
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)

                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.black)
                        .offset(x: player.isPlaying ? 0 : 2)
                }
            }
            .buttonStyle(.plain)

            // 下一曲
            Button {
                player.nextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            // 循环模式切换
            Button {
                player.toggleLoopMode()
            } label: {
                Image(systemName: loopModeIcon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(player.loopMode != .off ? Color.atmusicAmber : .white.opacity(0.65))
            }
            .buttonStyle(.plain)
        }
    }

    private var loopModeIcon: String {
        switch player.loopMode {
        case .single: return "repeat.1"
        case .all: return "repeat"
        case .off: return "repeat"
        }
    }

    // MARK: - 快捷音量控制条
    private var volumeControlRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))

            Slider(value: Binding(
                get: { player.volume },
                set: { player.volume = $0 }
            ), in: 0...1)
            .tint(Color.atmusicAmber)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - 右栏（歌词 / 待播列表）
    private var rightContentColumn: some View {
        VStack(spacing: 16) {
            // 右栏顶部切换标签
            HStack(spacing: 12) {
                ForEach(RightPaneMode.allCases) { mode in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            rightPaneMode = mode
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: mode.icon)
                            Text(mode.rawValue)
                        }
                        .font(ATMusicFont.appFont(14, .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background {
                            if rightPaneMode == mode {
                                Capsule().fill(.white.opacity(0.24))
                            } else {
                                Capsule().fill(.clear)
                            }
                        }
                        .foregroundStyle(rightPaneMode == mode ? .white : .white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                if rightPaneMode == .lyrics {
                    Button {
                        autoScrollEnabled.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: autoScrollEnabled ? "arrow.up.and.down.circle.fill" : "circle")
                            Text(autoScrollEnabled ? "自动居中" : "自由滚动")
                        }
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)

            // 主展示内容
            ZStack {
                if rightPaneMode == .lyrics {
                    liveLyricsScrollView
                } else {
                    inlineQueueListView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .background(.ultraThinMaterial.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
    }

    // MARK: - 实时同步滚动歌词
    private var liveLyricsScrollView: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: false) {
                if lyrics.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.4))
                        Text("纯音乐，请欣赏")
                            .font(ATMusicFont.appFont(16))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, minHeight: 400)
                } else {
                    VStack(alignment: .leading, spacing: 22) {
                        Color.clear.frame(height: 120)

                        ForEach(Array(lyrics.enumerated()), id: \.element.id) { item in
                            let index = item.offset
                            let line = item.element
                            let isCurrent = isCurrentLine(at: index)

                            VStack(alignment: .leading, spacing: 6) {
                                Text(line.text)
                                    .font(ATMusicFont.appFont(isCurrent ? 28 : 20, isCurrent ? .bold : .medium))
                                    .foregroundStyle(isCurrent ? .white : .white.opacity(0.40))
                                    .blur(radius: isCurrent ? 0 : 0.4)
                                    .scaleEffect(isCurrent ? 1.02 : 1.0, anchor: .leading)
                                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isCurrent)

                                if let translation = line.translation, !translation.isEmpty {
                                    Text(translation)
                                        .font(ATMusicFont.appFont(isCurrent ? 16 : 14))
                                        .foregroundStyle(isCurrent ? Color.atmusicAmber.opacity(0.9) : .white.opacity(0.28))
                                }
                            }
                            .id(line.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                player.seek(to: line.time)
                            }
                        }

                        Color.clear.frame(height: 160)
                    }
                    .padding(.horizontal, 32)
                }
            }
            .onChange(of: clock.currentTime) { _, currentTime in
                guard autoScrollEnabled, !lyrics.isEmpty else { return }
                if let currentLineID = findCurrentLineID(at: currentTime) {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        scrollProxy.scrollTo(currentLineID, anchor: .center)
                    }
                }
            }
        }
    }

    private func isCurrentLine(at index: Int) -> Bool {
        guard index < lyrics.count else { return false }
        let current = clock.currentTime
        let lineTime = lyrics[index].time
        let nextTime = index + 1 < lyrics.count ? lyrics[index + 1].time : Double.infinity
        return current >= lineTime && current < nextTime
    }

    private func findCurrentLineID(at time: Double) -> UUID? {
        for (index, line) in lyrics.enumerated() {
            let nextTime = index + 1 < lyrics.count ? lyrics[index + 1].time : Double.infinity
            if time >= line.time && time < nextTime {
                return line.id
            }
        }
        return lyrics.first?.id
    }

    // MARK: - 实时待播列表（Queue）
    private var inlineQueueListView: some View {
        let queuedSongs = player.queue
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                if queuedSongs.isEmpty {
                    Text("当前待播列表为空")
                        .font(ATMusicFont.appFont(15))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 100)
                } else {
                    HStack {
                        Text("即将播放 · \(queuedSongs.count) 首")
                            .font(ATMusicFont.appFont(13, .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        Button("清空列表") {
                            player.clearQueue()
                        }
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicAmber)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                    ForEach(Array(queuedSongs.enumerated()), id: \.element.identityKey) { index, item in
                        let isPlayingThis = (item.identityKey == player.currentSong?.identityKey)

                        HStack(spacing: 14) {
                            CoverImage(url: item.coverURL, size: 44, cornerRadius: 8)
                                .frame(width: 44, height: 44)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(ATMusicFont.appFont(15, isPlayingThis ? .bold : .medium))
                                    .foregroundStyle(isPlayingThis ? Color.atmusicAmber : .white)
                                    .lineLimit(1)

                                Text(item.artist)
                                    .font(ATMusicFont.appFont(12))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .lineLimit(1)
                            }

                            Spacer()

                            if isPlayingThis {
                                Image(systemName: "waveform")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(Color.atmusicAmber)
                                    .symbolEffect(.variableColor.iterative.reversing)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background {
                            if isPlayingThis {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.white.opacity(0.12))
                            } else {
                                Color.clear
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            player.play(songs: queuedSongs, startAt: index)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
