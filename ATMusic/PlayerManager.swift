import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

enum PlayMode: String, CaseIterable, Identifiable {
    case sequential
    case repeatOne
    case shuffle

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .sequential: return "repeat"
        case .repeatOne: return "repeat.1"
        case .shuffle: return "shuffle"
        }
    }

    var title: String {
        switch self {
        case .sequential: return "顺序播放"
        case .repeatOne: return "单曲循环"
        case .shuffle: return "随机播放"
        }
    }
}

final class PlaybackClock: ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: Double = 0

    func update(progress: Double? = nil, duration: Double? = nil) {
        let apply = {
            if let progress, abs(progress - self.progress) > 0.01 {
                self.progress = progress
            }
            if let duration, abs(duration - self.duration) > 0.01 {
                self.duration = duration
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }
}

final class PlayerManager: NSObject, ObservableObject {
    @Published var queue: [Song] = []
    @Published var currentIndex = 0
    @Published var isPlaying = false
    @Published var isBuffering = false
    @Published var loadFailed = false
    /// 切歌代次：防止旧歌的 URL 解析任务覆盖新歌（快速切歌时）
    private var loadGeneration = 0
    let clock = PlaybackClock()
    var progress: Double = 0 {
        didSet { clock.update(progress: progress) }
    }
    var duration: Double = 0 {
        didSet { clock.update(duration: duration) }
    }
    @Published var playMode: PlayMode = .sequential {
        didSet {
            guard oldValue != playMode else { return }
            defaults.set(playMode.rawValue, forKey: playModeKey)
        }
    }
    @Published var rate: Double = 1.0
    @Published var sleepTimerEndsAt: Date?
    @Published var sleepTimerRemaining: Int = 0
    @Published var history: [Song] = []
    @Published var playCounts: [String: Int] = [:]
    @Published private(set) var listeningSeconds = 0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var itemStatusObserver: NSKeyValueObservation?
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var equalizerSettingsObserver: NSObjectProtocol?
    private var playbackConfirmed = false
    private var pendingThirdPartyVIPNotice: ThirdPartyVIPNotice?
    private var sessionConfigured = false
    private var systemPlaybackPrepared = false
    private var routeObserverInstalled = false
    private var interruptionObserverInstalled = false
    private var remoteCommandsInstalled = false
    private var playOrder: [Int] = []
    private var orderPosition = 0
    /// 每个来源最多尝试一次，避免备用来源失败后在来源之间来回循环。
    private var attemptedSourceFallbacks: Set<String> = []
    private var sleepTimer: Timer?
    private var lastCountedSongID: String?
    private var lastListeningProgress: Double?
    private var pendingListeningSeconds = 0.0
    private var wasPlayingBeforeInterruption = false
    private var lastPublishedProgress: Double = -1
    private var lastPersistedProgress: Double = -1
    private var lastNowPlayingArtworkKey: String?
    /// 酷狗高音质地址在部分账号/系统上会返回但无法由 AVPlayer 打开；每首歌只自动降级一次。
    private var kugouStandardFallbackSongKey: String?
    /// 第三方地址偶发过期或节点不可用时，按失败域名重试，避免同一节点反复进入播放器。
    private var thirdPartyRetryExcludedHostsBySong: [String: Set<String>] = [:]
    /// 记录已经交给 AVPlayer 的第三方音质，失败后选择下一个更低档位。
    private var attemptedThirdPartyQualitiesBySong: [String: Set<String>] = [:]
    private var activeThirdPartyQuality: ThirdPartyAudioQuality?
    /// 记录 QQ 官方 vkey 已经尝试过的 BR，官方地址实际打不开时继续换档位。
    private var attemptedQQOfficialBRsBySong: [String: Set<String>] = [:]
    private var activeQQOfficialBR: String?
    /// KVO 与 AVPlayerItemFailedToPlayToEndTime 可能同时报告同一次失败。
    private var playbackRecoveryInFlightSongKey: String?
    /// 同一首歌的多个 AVFoundation 失败回调只允许弹一次提示并自动切歌一次。
    private var finalizedFailureSongKey: String?
    /// 播放失败后延迟自动切歌，避免失败回调刚到就立刻跳过歌曲。
    private var failureAutoSkipWorkItem: DispatchWorkItem?
    /// QQ 官方地址返回成功但实际不可播放时，只切换到第三方一次，避免官方/第三方之间循环。
    private var qqThirdPartyFallbackSongKey: String?
    private var playbackConfirmationWorkItem: DispatchWorkItem?
    private var playbackStallWorkItem: DispatchWorkItem?
    private static let nowPlayingArtworkCache = NSCache<NSURL, UIImage>()

    private let historyKey = "atmusic.history"
    private let countsKey = "atmusic.playcounts"
    private let listeningSecondsKey = "atmusic.listeningSeconds"
    private let playbackStateKey = "atmusic.player.playbackState.v1"
    private let audioMixKey = "atmusic.audio.mixothers.v1"
    private let playModeKey = "atmusic.player.playMode"
    private let autoSkipOnFailureKey = "atmusic.playback.autoSkipOnFailure"
    private let autoResumeLastPlaybackKey = "atmusic.playback.autoResumeLast"
    private let thirdPartyVIPNoticeKey = "atmusic.showThirdPartyVIPNotice"
    private let defaults = UserDefaults.standard
    private var didAttemptAutoResume = false

    /// 只要存在启用的自定义音源，就允许官方地址失败后进行兜底解析。
    private var externalSourcesEnabled: Bool {
        UnblockSourceStore.shared.sources.contains(where: \.enabled)
    }

    private struct ThirdPartyVIPNotice {
        let songKey: String
        let message: String
    }

    private struct PersistedPlaybackState: Codable {
        let queue: [Song]
        let currentIndex: Int
        let progress: Double
        let duration: Double
        let savedAt: Date
    }

    var currentSong: Song? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    /// 磁盘播放缓存跟随“播放音质”，避免设置为无损/Hi-Res 时误命中旧的 320k 缓存。
    private func playbackCacheQuality() -> ThirdPartyAudioQuality {
        switch ATMusicAudioQuality.current {
        case .standard: return .kb128
        case .higher, .exhigh: return .kb320
        case .lossless: return .flac
        case .hires: return .hires
        }
    }

    private func nextSongForPrefetch() -> Song? {
        guard queue.count > 1, playMode != .repeatOne else { return nil }
        if playMode == .shuffle {
            guard !playOrder.isEmpty else { return nil }
            let nextPosition = (orderPosition + 1) % playOrder.count
            let index = playOrder[nextPosition]
            return queue.indices.contains(index) ? queue[index] : nil
        }
        let index = (currentIndex + 1) % queue.count
        return queue.indices.contains(index) ? queue[index] : nil
    }

    private func refreshPrefetchTarget() {
        let song = nextSongForPrefetch()
        let quality = playbackCacheQuality()
        Task { @MainActor in
            MusicCacheManager.shared.requestPrefetch(song: song, quality: quality)
        }
    }

    override init() {
        super.init()
        listeningSeconds = defaults.integer(forKey: listeningSecondsKey)
        if let raw = defaults.string(forKey: playModeKey),
           let saved = PlayMode(rawValue: raw) {
            playMode = saved
        }
        loadHistory()
        loadPlayCounts()
        restorePersistedPlaybackState()
        equalizerSettingsObserver = NotificationCenter.default.addObserver(
            forName: ATMusicEqualizer.settingsDidChange,
            object: ATMusicEqualizer.shared,
            queue: .main
        ) { [weak self] _ in
            self?.applyEqualizerToCurrentItem()
        }
    }

    deinit {
        if let equalizerSettingsObserver {
            NotificationCenter.default.removeObserver(equalizerSettingsObserver)
        }
    }

    /// 在首帧之后恢复轻量播放偏好，避免安装后启动阶段触碰系统媒体服务。
    func restorePersistedPlayMode() {
        guard let raw = defaults.string(forKey: playModeKey),
              let saved = PlayMode(rawValue: raw) else { return }
        guard playMode != saved else { return }
        playMode = saved
        if !queue.isEmpty {
            buildPlayOrder()
        }
    }

    // MARK: - 播放控制

    func play(songs: [Song], startAt index: Int = 0) {
        guard !songs.isEmpty else { return }
        guard ensurePlaybackAllowed() else { return }
        queue = songs
        attemptedSourceFallbacks.removeAll()
        currentIndex = min(max(index, 0), songs.count - 1)
        if playMode == .shuffle {
            shuffleVisibleQueueKeepingCurrent()
        } else {
            buildPlayOrder()
        }
        loadCurrent()
    }

    func playSong(_ song: Song, in context: [Song]) {
        play(songs: context, startAt: context.firstIndex(of: song) ?? 0)
    }

    /// 元数据写回后替换队列中的同一首歌曲，让当前播放页和播放队列立即显示新标签。
    /// 不重新加载音频，避免编辑歌曲信息时打断播放。
    func replaceSong(_ updated: Song) {
        let key = updated.identityKey
        for index in queue.indices where queue[index].identityKey == key {
            queue[index] = updated
        }
        for index in history.indices where history[index].identityKey == key {
            history[index] = updated
        }
        updateNowPlaying()
        savePersistedPlaybackState()
    }

    /// 插队播放：把歌曲放到当前歌曲之后，不打断当前播放
    func playNext(_ song: Song) {
        guard !queue.isEmpty else {
            play(songs: [song], startAt: 0)
            return
        }
        let insertAt = currentIndex + 1
        queue.insert(song, at: min(insertAt, queue.count))
        switch playMode {
        case .shuffle:
            playOrder = playOrder.map { $0 >= insertAt ? $0 + 1 : $0 }
            let nextOrderPosition = min(orderPosition + 1, playOrder.count)
            playOrder.insert(min(insertAt, queue.count - 1), at: nextOrderPosition)
        default:
            buildPlayOrder()
        }
        savePersistedPlaybackState()
        refreshPrefetchTarget()
        Task { @MainActor in
            ToastCenter.shared.show("已加入下一首播放")
        }
    }

    /// 可选地恢复上次退出时的歌曲并立即播放，只在每次应用启动时执行一次。
    func resumePersistedPlaybackIfEnabled() {
        guard !didAttemptAutoResume else { return }
        didAttemptAutoResume = true
        guard defaults.object(forKey: autoResumeLastPlaybackKey) as? Bool ?? false,
              currentSong != nil else { return }
        loadCurrent(resumeAt: progress)
    }

    func togglePlayPause() {
        guard ensurePlaybackAllowed() else { return }
        guard let player else {
            guard currentSong != nil else { return }
            loadCurrent(resumeAt: progress)
            return
        }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            player.playImmediately(atRate: Float(rate))
            isPlaying = true
        }
        savePersistedPlaybackState()
        updateNowPlaying()
    }

    func next(manual: Bool = true) {
        guard ensurePlaybackAllowed() else { return }
        guard !queue.isEmpty else { return }
        if playMode == .repeatOne && manual {
            restartCurrent()
            return
        }
        advance()
        loadCurrent()
    }

    func previous() {
        guard ensurePlaybackAllowed() else { return }
        guard !queue.isEmpty else { return }
        // 直接切换到上一首（不再做“播放超过 3 秒先重头播放”的判断）
        if playMode == .shuffle {
            orderPosition = (orderPosition - 1 + playOrder.count) % playOrder.count
            currentIndex = playOrder[orderPosition]
        } else {
            currentIndex = (currentIndex - 1 + queue.count) % queue.count
        }
        loadCurrent()
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, max(duration, 0)))
        progress = clamped
        // 用 seek 完成回调同步真实进度：避免暂停状态下拖动进度后，歌词定位与实际播放位置不一致
        player?.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            guard let self, finished else { return }
            self.performOnMain { [weak self] in
                guard let self else { return }
                let actual = self.player?.currentTime().seconds ?? clamped
                if abs(actual - self.progress) > 0.25 {
                    self.progress = actual
                }
            }
        }
        updateNowPlaying()
        savePersistedPlaybackState()
    }

    func seekBy(_ delta: Double) {
        seek(to: progress + delta)
    }

    func togglePlayMode() {
        let nextMode: PlayMode
        switch playMode {
        case .sequential: nextMode = .repeatOne
        case .repeatOne: nextMode = .shuffle
        case .shuffle: nextMode = .sequential
        }
        setPlayMode(nextMode)
    }

    /// 由播放列表弹框直接选择播放顺序。进入随机播放时不仅改变“下一首”索引，
    /// 也真实重排可见 queue，因此播放队列页面会立即显示新的随机顺序。
    func setPlayMode(_ mode: PlayMode) {
        guard playMode != mode else {
            // 已经处于随机模式时再次选择随机，主动再洗牌一次（当前歌保持不变）。
            if mode == .shuffle {
                shuffleVisibleQueueKeepingCurrent()
                savePersistedPlaybackState()
                refreshPrefetchTarget()
            }
            return
        }
        playMode = mode
        if mode == .shuffle {
            shuffleVisibleQueueKeepingCurrent()
        } else {
            buildPlayOrder()
        }
        savePersistedPlaybackState()
        refreshPrefetchTarget()
    }

    func setRate(_ newRate: Double) {
        rate = newRate
        if isPlaying {
            player?.playImmediately(atRate: Float(newRate))
        }
        updateNowPlaying()
    }

    func playQueueIndex(_ index: Int) {
        guard ensurePlaybackAllowed() else { return }
        guard queue.indices.contains(index) else { return }
        jumpToOrderPosition(index)
    }

    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index), queue.count > 1 else { return }
        let removedID = queue[index].id
        queue.remove(at: index)
        if index < currentIndex {
            currentIndex -= 1
        } else if index == currentIndex {
            currentIndex = min(currentIndex, queue.count - 1)
            loadCurrent()
        }
        buildPlayOrder(avoiding: removedID)
        savePersistedPlaybackState()
        refreshPrefetchTarget()
    }

    /// 调整队列顺序并保持当前歌曲不变。
    func moveQueue(from offsets: IndexSet, to destination: Int) {
        guard !offsets.isEmpty, queue.count > 1 else { return }
        let currentKey = currentSong?.identityKey
        var reordered = queue
        reordered.move(fromOffsets: offsets, toOffset: destination)
        queue = reordered
        if let currentKey, let newIndex = reordered.firstIndex(where: { $0.identityKey == currentKey }) {
            currentIndex = newIndex
        }
        buildPlayOrder()
        savePersistedPlaybackState()
        refreshPrefetchTarget()
    }

    func retryCurrent() {
        guard ensurePlaybackAllowed() else { return }
        loadFailed = false
        loadCurrent()
    }

    /// 删除单条播放历史（含持久化）
    func removeHistory(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            guard history.indices.contains(index) else { continue }
            history.remove(at: index)
        }
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: historyKey)
        }
    }

    /// 清空播放历史（含持久化）
    func clearHistory() {
        history.removeAll()
        defaults.removeObject(forKey: historyKey)
    }

    /// 清空队列，仅保留当前歌曲
    func clearQueue() {
        guard !queue.isEmpty else { return }
        if let current = currentSong {
            queue = [current]
            currentIndex = 0
        } else {
            queue = []
            currentIndex = 0
        }
        buildPlayOrder()
        savePersistedPlaybackState()
        refreshPrefetchTarget()
    }

    // MARK: - 睡眠定时

    func startSleepTimer(minutes: Int) {
        stopSleepTimer()
        sleepTimerEndsAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerRemaining = minutes * 60
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let end = self.sleepTimerEndsAt else { return }
            let remain = Int(end.timeIntervalSinceNow)
            self.sleepTimerRemaining = max(0, remain)
            if remain <= 0 {
                self.stopSleepTimer()
                self.pausePlayback()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sleepTimer = timer
    }

    func stopSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerEndsAt = nil
        sleepTimerRemaining = 0
    }

    var sleepTimerFormatted: String? {
        guard sleepTimerRemaining > 0 else { return nil }
        return String(format: "%d:%02d", sleepTimerRemaining / 60, sleepTimerRemaining % 60)
    }

    private func pausePlayback() {
        player?.pause()
        isPlaying = false
        updateNowPlaying()
    }

    // MARK: - 播放顺序

    private func buildPlayOrder(avoiding removedID: Int? = nil) {
        // 随机模式现在会直接重排 queue，playOrder 始终跟可见列表一致，
        // 避免“界面是 A 顺序、实际下一首却按另一套隐藏索引”的割裂。
        playOrder = Array(queue.indices)
        orderPosition = min(max(currentIndex, 0), max(playOrder.count - 1, 0))
    }

    /// 真实洗牌队列，但保持当前正在播放的歌曲和音频流不变。
    /// 当前歌曲固定到队首，后续歌曲随机排列；这样用户打开播放队列即可看到实际播放顺序。
    private func shuffleVisibleQueueKeepingCurrent() {
        guard queue.count > 1, queue.indices.contains(currentIndex) else {
            buildPlayOrder()
            return
        }
        let current = queue[currentIndex]
        var remaining = queue
        remaining.remove(at: currentIndex)
        remaining.shuffle()
        queue = [current] + remaining
        currentIndex = 0
        playOrder = Array(queue.indices)
        orderPosition = 0
    }

    private func advance() {
        switch playMode {
        case .shuffle:
            guard !playOrder.isEmpty else { return }
            orderPosition = (orderPosition + 1) % playOrder.count
            currentIndex = playOrder[orderPosition]
        default:
            currentIndex = (currentIndex + 1) % queue.count
            orderPosition = currentIndex
        }
    }

    private func jumpToOrderPosition(_ index: Int) {
        currentIndex = index
        if playMode == .shuffle {
            orderPosition = 0
            if let pos = playOrder.firstIndex(of: index) {
                orderPosition = pos
            }
        } else {
            orderPosition = index
        }
        loadCurrent()
    }

    // MARK: - 播放

    private func restartCurrent() {
        guard ensurePlaybackAllowed() else { return }
        seek(to: 0)
        player?.playImmediately(atRate: Float(rate))
        isPlaying = true
        updateNowPlaying()
    }

    private func loadCurrent(resumeAt: Double? = nil, forceKugouStandard: Bool = false) {
        guard ensurePlaybackAllowed() else { return }
        guard let song = currentSong else { return }
        let cacheQuality = playbackCacheQuality()
        loadGeneration += 1
        let generation = loadGeneration
        thirdPartyRetryExcludedHostsBySong.removeValue(forKey: song.identityKey)
        attemptedThirdPartyQualitiesBySong.removeValue(forKey: song.identityKey)
        attemptedQQOfficialBRsBySong.removeValue(forKey: song.identityKey)
        activeThirdPartyQuality = nil
        activeQQOfficialBR = nil
        playbackRecoveryInFlightSongKey = nil
        finalizedFailureSongKey = nil
        failureAutoSkipWorkItem?.cancel()
        failureAutoSkipWorkItem = nil
        playbackStallWorkItem?.cancel()
        playbackStallWorkItem = nil
        qqThirdPartyFallbackSongKey = nil
        let initialProgress = max(0, min(resumeAt ?? 0, max(song.duration, 0)))
        // 切歌立即暂停旧音频，避免新歌加载期间旧歌继续播放造成“切歌卡住”感
        player?.pause()
        duration = song.duration
        progress = initialProgress
        isPlaying = false
        isBuffering = true
        loadFailed = false
        pushHistory(song)
        savePersistedPlaybackState()
        Task {
            await MainActor.run {
                MusicCacheManager.shared.cancelPrefetch()
                MusicCacheManager.shared.markCurrentPlayback(song: song, quality: cacheQuality)
            }
            if song.source != .local {
                let cachedURL = await MainActor.run {
                    MusicCacheManager.shared.cachedURL(for: song, quality: cacheQuality)
                }
                if let cachedURL {
                    await MainActor.run {
                        guard generation == self.loadGeneration,
                              self.currentSong?.identityKey == song.identityKey else { return }
                        ATMusicLogger.shared.log(
                            "播放缓存命中：\(song.name)｜音质=\(cacheQuality.rawValue)",
                            level: .info
                        )
                        self.setupPlayer(url: cachedURL, resumeAt: initialProgress, fromPlaybackCache: true)
                    }
                    return
                }
            }

            var urlString: String?
            var resolvedThirdParty: UnblockService.Resolved?
            var qqOfficialBR: String?
            var attemptedQQOfficialBRs: [String] = []
            // 官方地址失败后，使用已启用的自定义音源兜底。
            let enableUnblock = externalSourcesEnabled
            let strictUnlock = shouldLockOfficialOnly(song)
            let quality = (forceKugouStandard && song.source == .kugou) ? .standard : ATMusicAudioQuality.current
            let thirdPartyQuality = ThirdPartyAudioQuality.current
            ATMusicLogger.shared.log("▶ 开始播放：\(song.name) - \(song.artists)｜平台=\(song.source.rawValue) id=\(song.id) 音质=\(quality.level) 第三方音质=\(thirdPartyQuality.rawValue) 自定义音源=\(enableUnblock ? "开" : "关") 官方受限=\(strictUnlock ? "是" : "否")", level: .info)
            if song.source == .local, let relativePath = song.localRelativePath,
               let localURL = try? ManagedAudioPath.resolve(relativePath) {
                urlString = localURL.absoluteString
            } else if song.source == .synology {
                urlString = SynologyAPI.shared.songURL(song: song)
            } else if song.source == .kugou {
                urlString = try? await KugouMusicAPI.shared.songURL(song: song, quality: quality)
                if urlString == nil {
                    resolvedThirdParty = await kugouFallback(
                        song: song,
                        thirdPartyQuality: thirdPartyQuality,
                        enableUnblock: enableUnblock
                    )
                }
            } else if song.source == .qq, let mid = song.qqMid {
                // QQ 官方地址失败后只走 QQ 第三方音源，不跨平台匹配同名歌曲。
                let officialResult = try? await QQMusicAPI.shared.songURLResult(
                    songmid: mid,
                    mediaMid: song.qqMediaMid,
                    quality: quality
                )
                urlString = officialResult?.url
                qqOfficialBR = officialResult?.br
                attemptedQQOfficialBRs = officialResult?.attemptedBRs ?? []
                if urlString == nil {
                    (urlString, resolvedThirdParty) = await qqFallback(
                        song: song,
                        quality: quality,
                        thirdPartyQuality: thirdPartyQuality,
                        enableUnblock: enableUnblock,
                        strict: strictUnlock
                    )
                }
            } else {
                (urlString, resolvedThirdParty) = await neteaseResolve(
                    song: song,
                    quality: quality,
                    thirdPartyQuality: thirdPartyQuality,
                    enableUnblock: enableUnblock,
                    strict: strictUnlock
                )
            }
            if let resolved = resolvedThirdParty {
                let notice = self.thirdPartyVIPNotice(for: song, sourceTitle: resolved.sourceTitle)
                await MainActor.run {
                    guard generation == self.loadGeneration else { return }
                    self.setupPlayer(
                        url: resolved.url,
                        thirdPartyVIPNotice: notice,
                        resumeAt: initialProgress,
                        isThirdParty: true,
                        thirdPartyQuality: resolved.quality
                    )
                }
                return
            }
            guard let urlString, let url = URL(string: urlString) else {
                await MainActor.run {
                    guard generation == self.loadGeneration else { return }
                    self.isBuffering = false
                    self.loadFailed = true
                    let failureMessage = atmusicLocalized(
                        "播放失败，当前音源暂时无法响应，请稍后重试或切换其他歌曲",
                        "Playback failed. The current source did not respond. Please try again or switch songs."
                    )
                    ATMusicLogger.shared.log("播放失败：\(song.name) - \(failureMessage)｜音质=\(quality.level)", level: .error)
                    self.finishUnrecoverablePlaybackFailure(
                        song: song,
                        reason: "解析播放地址失败",
                        message: failureMessage
                    )
                }
                return
            }
            await MainActor.run {
                guard generation == self.loadGeneration else { return }
                self.setupPlayer(
                    url: url,
                    resumeAt: initialProgress,
                    qqOfficialBR: qqOfficialBR,
                    attemptedQQOfficialBRs: attemptedQQOfficialBRs
                )
            }
        }
    }

    /// 网易云播放地址解析：按设置音质取 URL，VIP/灰色歌曲交给第三方解锁。
    private func neteaseResolve(
        song: Song,
        quality: ATMusicAudioQuality,
        thirdPartyQuality: ThirdPartyAudioQuality = .current,
        enableUnblock: Bool,
        strict: Bool = false
    ) async -> (String?, UnblockService.Resolved?) {
        var urlString: String?
        var resolved: UnblockService.Resolved?
        let infos = try? await NetEaseAPI.shared.songURLInfo(ids: [song.id], level: quality.level)
        var info = infos?[song.id]
        if (info?.url == nil || info?.freeTrial == true), quality != .standard {
            // 高音质拿不到时自动回落到标准音质
            let fallback = try? await NetEaseAPI.shared.songURLInfo(ids: [song.id], level: "standard")
            info = fallback?[song.id]
        }
        ATMusicLogger.shared.log("网易云解析：\(song.name) 音质=\(quality.level) 官方URL=\(info?.url == nil ? "无" : "有") 试听=\(info?.freeTrial == true ? "是" : "否")", level: .debug)
        // 试听片段 / 无 URL 一律不直接播放，交给第三方解锁，避免"只能试听"
        if let u = info?.url, info?.freeTrial != true {
            urlString = u
        }
        if urlString == nil, enableUnblock {
            resolved = await UnblockService.resolve(
                name: song.name,
                artists: song.artists,
                neteaseID: song.id,
                songSource: .netease,
                quality: thirdPartyQuality,
                strict: strict
            )
        }
        ATMusicLogger.shared.log("网易云结果：\(song.name) 官方=\(urlString != nil ? "是" : "否") 第三方=\(resolved != nil ? "命中" : "未用/未命中")", level: .debug)
        return (urlString, resolved)
    }

    /// QQ 歌曲兜底：官方失败后只走 QQ 第三方接口，不跨平台匹配同名歌曲。
    private func qqFallback(
        song: Song,
        quality _: ATMusicAudioQuality,
        thirdPartyQuality: ThirdPartyAudioQuality = .current,
        enableUnblock: Bool,
        strict: Bool = false,
        excludedHosts: Set<String> = []
    ) async -> (String?, UnblockService.Resolved?) {
        guard enableUnblock else {
            ATMusicLogger.shared.log("QQ兜底：\(song.name) 第三方=未启用", level: .debug)
            return (nil, nil)
        }
        let resolved = await UnblockService.resolve(
            name: song.name,
            artists: song.artists,
            // QQ 专属音源要求传数字 songId；mid 仅作为兼容接口的后备参数。
            neteaseID: song.id,
            songSource: .qq,
            qqMid: song.qqMid,
            qqMediaMid: song.qqMediaMid,
            quality: thirdPartyQuality,
            strict: strict,
            excludedHosts: excludedHosts
        )
        ATMusicLogger.shared.log("QQ兜底：\(song.name) QQ第三方=\(resolved != nil ? "命中" : "未命中")", level: .debug)
        return (nil, resolved)
    }

    /// 酷狗兜底：官方播放失败后使用内置音源作为备选。
    private func kugouFallback(
        song: Song,
        thirdPartyQuality: ThirdPartyAudioQuality = .current,
        enableUnblock: Bool
    ) async -> UnblockService.Resolved? {
        guard enableUnblock else { return nil }
        let kugouID = song.kugouHash ?? song.kugouAlbumAudioId ?? ""
        if kugouID.isEmpty {
            ATMusicLogger.shared.log("酷狗兜底跳过：缺少 album_audio_id/hash", level: .debug)
        } else {
            let resolved = await UnblockService.resolve(
                name: song.name,
                artists: song.artists,
                neteaseID: 0,
                songSource: .kugou,
                kugouID: kugouID,
                quality: thirdPartyQuality
            )
            if let resolved {
                ATMusicLogger.shared.log("酷狗兜底：\(song.name) 酷狗音源=命中", level: .debug)
                return resolved
            }
        }

        let strict = shouldLockOfficialOnly(song)
        if let matched = await matchNetEaseSong(
            name: song.name,
            artists: song.artists,
            durationMS: Int(song.duration * 1000),
            strict: strict
        ) {
            let resolved = await UnblockService.resolve(
                name: matched.name,
                artists: matched.artists,
                neteaseID: matched.id,
                songSource: .netease,
                quality: thirdPartyQuality,
                strict: strict
            )
            ATMusicLogger.shared.log("酷狗兜底转网易云音源：\(song.name) -> \(matched.name) 第三方=\(resolved != nil ? "命中" : "未命中")", level: .debug)
            return resolved
        }

        ATMusicLogger.shared.log("酷狗兜底：\(song.name) 第三方=未命中", level: .debug)
        return nil
    }

    /// 不再按歌手硬拦截跨平台兜底，避免 QQ 官方失败后把可播的网易云链路一并阻断。
    private func shouldLockOfficialOnly(_ song: Song) -> Bool {
        false
    }

    /// 在网易云按 歌名+歌手 匹配同名歌曲（QQ vkey 失败时的免费播放兜底）
    private func matchNetEaseSong(name: String, artists: String, durationMS: Int, strict: Bool = false) async -> Song? {
        let keyword = ([name, artists].filter { !$0.isEmpty }).joined(separator: " ")
        guard !keyword.isEmpty,
              let results = try? await NetEaseAPI.shared.search(keyword: keyword, limit: 8),
              !results.isEmpty else { return nil }
        let target = Double(durationMS) / 1000.0
        let artistTokens = artists.lowercased().split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "&" }).map(String.init)
        // 优先：歌手匹配 + 时长接近（兼容 Jay Chou 别名）
        if let hit = results.first(where: { song in
            let durOK = abs(song.duration - target) < 12
            let songArtists = song.artists.lowercased()
            let artistOK = artistTokens.contains { !$0.isEmpty && songArtists.contains($0) }
                || (songArtists.contains("周杰伦") && artists.lowercased().contains("jay chou"))
            return durOK && artistOK
        }) { return hit }
        // 严格模式（周杰伦等版权歌手）：找不到原唱直接放弃，绝不返回翻唱
        if strict { return nil }
        // 其次：仅时长接近（必须足够接近才用，避免张冠李戴）
        if let hit = results.min(by: { abs($0.duration - target) < abs($1.duration - target) }),
           abs(hit.duration - target) < 20 {
            return hit
        }
        // 找不到可靠匹配：宁可播放失败，也不播放错误歌曲
        return nil
    }

    /// 仅在高音质地址已经交给 AVPlayer 但实际无法打开时回退标准音质。
    /// 这样正常账号仍优先使用高音质，兼容部分旧系统或账号返回的不可解码资源。
    @discardableResult
    private func retryKugouAtStandardIfNeeded(error: Error?) -> Bool {
        guard let song = currentSong,
              song.source == .kugou,
              ATMusicAudioQuality.current != .standard,
              kugouStandardFallbackSongKey != song.identityKey else { return false }
        kugouStandardFallbackSongKey = song.identityKey
        let resume = progress
        ATMusicLogger.shared.log("酷狗高音质地址无法打开，自动回退标准音质：歌曲=\(song.name) 系统=\(UIDevice.current.systemVersion) 错误=\(error?.localizedDescription ?? "未知错误")", level: .debug)
        loadCurrent(resumeAt: resume, forceKugouStandard: true)
        return true
    }

    @discardableResult
    private func retryThirdPartyIfNeeded(excludingHost: String? = nil) -> Bool {
        guard let song = currentSong,
              externalSourcesEnabled else { return false }
        if playbackRecoveryInFlightSongKey == song.identityKey {
            return true
        }

        let generation = loadGeneration
        let resume = progress
        let strict = shouldLockOfficialOnly(song)
        let currentQuality = activeThirdPartyQuality ?? ThirdPartyAudioQuality.current
        let attempted = attemptedThirdPartyQualitiesBySong[song.identityKey] ?? []
        guard let thirdPartyQuality = currentQuality.fallbackChain.first(where: {
            !attempted.contains($0.rawValue)
        }) else {
            ATMusicLogger.shared.log(
                "第三方播放地址重试停止：歌曲=\(song.name)｜已无更低可用音质｜当前=\(currentQuality.rawValue)",
                level: .debug
            )
            return false
        }
        attemptedThirdPartyQualitiesBySong[song.identityKey, default: []].insert(thirdPartyQuality.rawValue)
        var excludedHosts = thirdPartyRetryExcludedHostsBySong[song.identityKey] ?? []
        if let excludingHost, !excludingHost.isEmpty {
            excludedHosts.insert(excludingHost.lowercased())
        }
        guard excludedHosts.count <= 6 else {
            ATMusicLogger.shared.log(
                "第三方播放地址重试停止：歌曲=\(song.name)｜已排除域名=\(excludedHosts.sorted().joined(separator: ","))",
                level: .debug
            )
            return false
        }
        thirdPartyRetryExcludedHostsBySong[song.identityKey] = excludedHosts
        playbackRecoveryInFlightSongKey = song.identityKey
        ATMusicLogger.shared.log(
            "第三方播放地址失效，自动降级重试：歌曲=\(song.name)｜音质=\(thirdPartyQuality.rawValue)｜系统=\(UIDevice.current.systemVersion)｜排除域名=\(excludedHosts.sorted().joined(separator: ","))",
            level: .debug
        )
        Task {
            let resolved = await self.resolveThirdParty(
                song: song,
                quality: thirdPartyQuality,
                strict: strict,
                excludedHosts: excludedHosts
            )
            await MainActor.run {
                guard generation == self.loadGeneration,
                      self.currentSong?.identityKey == song.identityKey else {
                    if self.playbackRecoveryInFlightSongKey == song.identityKey {
                        self.playbackRecoveryInFlightSongKey = nil
                    }
                    return
                }
                self.playbackRecoveryInFlightSongKey = nil
                if let resolved {
                    let notice = self.thirdPartyVIPNotice(for: song, sourceTitle: resolved.sourceTitle)
                    self.setupPlayer(
                        url: resolved.url,
                        thirdPartyVIPNotice: notice,
                        resumeAt: resume,
                        isThirdParty: true,
                        thirdPartyQuality: resolved.quality
                    )
                    ATMusicLogger.shared.log(
                        "第三方播放地址重试成功：\(song.name)｜音质=\(resolved.quality.rawValue)｜域名=\(resolved.url.host ?? "?")",
                        level: .info
                    )
                } else {
                    ATMusicLogger.shared.log(
                        "第三方播放地址重试未命中：歌曲=\(song.name)｜已排除域名=\(excludedHosts.sorted().joined(separator: ","))",
                        level: .debug
                    )
                    if self.retryThirdPartyIfNeeded() { return }
                    self.finishUnrecoverablePlaybackFailure(song: song, reason: "第三方播放地址重试失败")
                }
            }
        }
        return true
    }

    @discardableResult
    private func retryQQOfficialIfNeeded() -> Bool {
        guard let song = currentSong,
              song.source == .qq,
              let qqMid = song.qqMid,
              !qqMid.isEmpty else { return false }
        if playbackRecoveryInFlightSongKey == song.identityKey {
            return true
        }

        let officialBRs = ["F000", "M800", "M500", "C400"]
        let attempted = attemptedQQOfficialBRsBySong[song.identityKey] ?? []
        guard let nextBR = officialBRs.first(where: { !attempted.contains($0) }) else {
            return false
        }
        attemptedQQOfficialBRsBySong[song.identityKey, default: []].insert(nextBR)
        playbackRecoveryInFlightSongKey = song.identityKey
        let generation = loadGeneration
        let resume = progress
        ATMusicLogger.shared.log(
            "QQ 官方地址实际不可播放，继续切换官方音质：歌曲=\(song.name)｜BR=\(nextBR)",
            level: .debug
        )
        Task {
            let urlString = try? await QQMusicAPI.shared.songURL(
                songmid: qqMid,
                mediaMid: song.qqMediaMid,
                br: nextBR
            )
            await MainActor.run {
                guard generation == self.loadGeneration,
                      self.currentSong?.identityKey == song.identityKey else {
                    if self.playbackRecoveryInFlightSongKey == song.identityKey {
                        self.playbackRecoveryInFlightSongKey = nil
                    }
                    return
                }
                self.playbackRecoveryInFlightSongKey = nil
                if let urlString, let url = URL(string: urlString) {
                    self.setupPlayer(
                        url: url,
                        resumeAt: resume,
                        qqOfficialBR: nextBR
                    )
                    return
                }
                if self.retryQQOfficialIfNeeded() { return }
                if self.fallbackQQToThirdPartyIfNeeded() { return }
                self.finishUnrecoverablePlaybackFailure(song: song, reason: "QQ 官方音质均不可播放")
            }
        }
        return true
    }

    @discardableResult
    private func fallbackQQToThirdPartyIfNeeded() -> Bool {
        guard let song = currentSong,
              song.source == .qq,
              let qqMid = song.qqMid,
              !qqMid.isEmpty,
              qqThirdPartyFallbackSongKey != song.identityKey,
              externalSourcesEnabled else { return false }
        if playbackRecoveryInFlightSongKey == song.identityKey {
            return true
        }

        qqThirdPartyFallbackSongKey = song.identityKey
        playbackRecoveryInFlightSongKey = song.identityKey
        let generation = loadGeneration
        let resume = progress
        let strict = shouldLockOfficialOnly(song)
        let thirdPartyQuality = ThirdPartyAudioQuality.current
        ATMusicLogger.shared.log(
            "QQ 官方地址实际不可播放，切换第三方解析：歌曲=\(song.name)｜系统=\(UIDevice.current.systemVersion)",
            level: .debug
        )
        Task {
            let (_, resolved) = await self.qqFallback(
                song: song,
                quality: ATMusicAudioQuality.current,
                thirdPartyQuality: thirdPartyQuality,
                enableUnblock: true,
                strict: strict
            )
            await MainActor.run {
                guard generation == self.loadGeneration,
                      self.currentSong?.identityKey == song.identityKey else {
                    if self.playbackRecoveryInFlightSongKey == song.identityKey {
                        self.playbackRecoveryInFlightSongKey = nil
                    }
                    return
                }
                self.playbackRecoveryInFlightSongKey = nil
                if let resolved {
                    let notice = self.thirdPartyVIPNotice(for: song, sourceTitle: resolved.sourceTitle)
                    self.setupPlayer(
                        url: resolved.url,
                        thirdPartyVIPNotice: notice,
                        resumeAt: resume,
                        isThirdParty: true,
                        thirdPartyQuality: resolved.quality
                    )
                    ATMusicLogger.shared.log(
                        "QQ 官方失败后第三方切换成功：\(song.name)｜域名=\(resolved.url.host ?? "?")",
                        level: .info
                    )
                } else {
                    ATMusicLogger.shared.log("QQ 官方失败后 QQ 第三方仍未命中：\(song.name)", level: .debug)
                    self.finishUnrecoverablePlaybackFailure(song: song, reason: "QQ 第三方解析失败")
                }
            }
        }
        return true
    }

    private func setupPlayer(
        url: URL,
        thirdPartyVIPNotice: ThirdPartyVIPNotice? = nil,
        resumeAt: Double = 0,
        isThirdParty: Bool = false,
        thirdPartyQuality: ThirdPartyAudioQuality? = nil,
        qqOfficialBR: String? = nil,
        attemptedQQOfficialBRs: [String] = [],
        fromPlaybackCache: Bool = false
    ) {
        guard ensurePlaybackAllowed(), let loadedSong = currentSong else { return }
        if isThirdParty {
            let quality = thirdPartyQuality ?? ThirdPartyAudioQuality.current
            activeThirdPartyQuality = quality
            activeQQOfficialBR = nil
            if let songKey = currentSong?.identityKey {
                attemptedThirdPartyQualitiesBySong[songKey, default: []].insert(quality.rawValue)
            }
        } else {
            activeThirdPartyQuality = nil
            activeQQOfficialBR = qqOfficialBR
            if let songKey = currentSong?.identityKey, !attemptedQQOfficialBRs.isEmpty {
                attemptedQQOfficialBRsBySong[songKey, default: []].formUnion(attemptedQQOfficialBRs)
            }
        }
        prepareForSystemPlayback()
        configureAudioSession()
        UIApplication.shared.beginReceivingRemoteControlEvents()
        removeCurrentObservers()
        pendingThirdPartyVIPNotice = thirdPartyVIPNotice
        // QQ CDN 地址需要基础请求头；第三方地址也可能落在
        // ptqqmusic.gitv.tv / aqqmusic.tc.qq.com 等 QQ CDN 域名。
        // 这些地址在低系统上如果缺少 Referer/Cookie，常见表现是先进入
        // playing，随后以 AVFoundation -11849 失败。
        let item: AVPlayerItem
        var playbackHeaders: [String: String] = [:]
        if isQQAudioHost(url.host) {
            playbackHeaders = [
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:80.0) Gecko/20100101 Firefox/80.0",
                "Referer": "https://y.qq.com/",
            ]
            let cookie = QQMusicAuth.shared.cookieHeader
            if !cookie.isEmpty {
                playbackHeaders["Cookie"] = cookie
            }
            let asset = AVURLAsset(url: url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": playbackHeaders
            ])
            item = AVPlayerItem(asset: asset)
        } else if url.host?.contains("kugou.com") == true || url.host?.contains("kgimg.com") == true {
            playbackHeaders = [
                "User-Agent": "Android15-1070-11440-46-0-DiscoveryDRADProtocol-wifi",
                "Referer": "https://www.kugou.com/",
            ]
            let cookie = KugouMusicAuth.shared.cookieHeader
            if !cookie.isEmpty { playbackHeaders["Cookie"] = cookie }
            let asset = AVURLAsset(url: url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": playbackHeaders
            ])
            item = AVPlayerItem(asset: asset)
        } else {
            item = AVPlayerItem(url: url)
        }
        let headerKeys = playbackHeaders.keys.sorted().joined(separator: ",")
        ATMusicLogger.shared.log(
            "AVPlayer 准备播放：\(currentSong?.name ?? "?")｜URL=\(playbackURLSummary(url))｜第三方=\(isThirdParty ? "是" : "否")｜headers=\(playbackHeaders.isEmpty ? "未添加" : "已添加")｜headerKeys=\(headerKeys.isEmpty ? "无" : headerKeys)",
            level: .debug
        )
        let player = AVPlayer(playerItem: item)
        // QQ CDN 返回的首包较小，避免 AVPlayer 为了预缓冲过久而表现为
        // “点击后没反应”；真正不可播放时仍由 item 失败回调触发音质降级。
        player.automaticallyWaitsToMinimizeStalling = false
        player.rate = Float(rate)
        self.player = player
        configureEqualizer(for: item)
        playbackConfirmed = false
        itemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            self.performOnMain { [weak self] in
                guard let self,
                      self.player === player,
                      self.currentSong?.identityKey == loadedSong.identityKey,
                      item.status == .failed else { return }
                self.logPlaybackFailure(
                    reason: "AVPlayerItem.status.failed",
                    item: item,
                    url: url,
                    isThirdParty: isThirdParty,
                    playbackHeaders: playbackHeaders
                )
                if fromPlaybackCache {
                    MainActor.assumeIsolated { MusicCacheManager.shared.removeCachedFile(for: loadedSong, quality: self.playbackCacheQuality()) }
                    ATMusicLogger.shared.log("播放缓存损坏，已删除并回退网络：\(loadedSong.name)", level: .debug)
                    self.loadCurrent(resumeAt: self.progress)
                    return
                }
                if isThirdParty && self.retryThirdPartyIfNeeded(excludingHost: url.host) { return }
                if !isThirdParty && self.retryQQOfficialIfNeeded() { return }
                if !isThirdParty && self.fallbackQQToThirdPartyIfNeeded() { return }
                if self.retryKugouAtStandardIfNeeded(error: item.error) { return }
                self.finishUnrecoverablePlaybackFailure(song: loadedSong, reason: "AVPlayerItem 加载失败")
            }
        }
        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            self.performOnMain { [weak self] in
                guard let self, self.player === player else { return }
                if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                    self.isBuffering = true
                    self.playbackStallWorkItem?.cancel()
                    let stall = DispatchWorkItem { [weak self, weak player, weak item] in
                        guard let self,
                              let player,
                              let item,
                              self.player === player,
                              player.currentItem === item,
                              self.currentSong?.identityKey == loadedSong.identityKey,
                              player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                              !self.playbackConfirmed else { return }
                        ATMusicLogger.shared.log(
                            "播放地址长时间未开始：歌曲=\(self.currentSong?.name ?? "?")｜第三方=\(isThirdParty ? "是" : "否")｜URL=\(self.playbackURLSummary(url))",
                            level: .debug
                        )
                        if fromPlaybackCache {
                            MainActor.assumeIsolated { MusicCacheManager.shared.removeCachedFile(for: loadedSong, quality: self.playbackCacheQuality()) }
                            ATMusicLogger.shared.log("播放缓存无响应，已删除并回退网络：\(loadedSong.name)", level: .debug)
                            self.loadCurrent(resumeAt: self.progress)
                            return
                        }
                        if isThirdParty && self.retryThirdPartyIfNeeded(excludingHost: url.host) { return }
                        if !isThirdParty && self.retryQQOfficialIfNeeded() { return }
                        if !isThirdParty && self.fallbackQQToThirdPartyIfNeeded() { return }
                        if self.retryKugouAtStandardIfNeeded(error: item.error) { return }
                        self.finishUnrecoverablePlaybackFailure(
                            song: loadedSong,
                            reason: "播放地址长时间未响应"
                        )
                    }
                    self.playbackStallWorkItem = stall
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: stall)
                    return
                }
                self.playbackStallWorkItem?.cancel()
                self.playbackStallWorkItem = nil
                guard player.timeControlStatus == .playing, !self.playbackConfirmed else { return }
                self.playbackConfirmationWorkItem?.cancel()
                let confirmation = DispatchWorkItem { [weak self, weak player, weak item] in
                    guard let self,
                          let player,
                          let item,
                          self.player === player,
                          player.currentItem === item,
                          player.timeControlStatus == .playing,
                          item.status == .readyToPlay,
                          !self.playbackConfirmed else { return }
                    self.playbackConfirmed = true
                    if let song = self.currentSong {
                        ATMusicLogger.shared.log(
                            "▶ 播放成功确认：\(song.name)｜URL=\(self.playbackURLSummary(url))｜第三方=\(isThirdParty ? "是" : "否")｜itemStatus=\(self.playerItemStatusDescription(item.status))",
                            level: .info
                        )
                    }
                    self.showPendingThirdPartyVIPNoticeIfNeeded()
                    self.refreshPrefetchTarget()
                }
                self.playbackConfirmationWorkItem = confirmation
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: confirmation)
            }
        }
        if resumeAt > 0.5 {
            let seekTime = CMTime(seconds: resumeAt, preferredTimescale: 600)
            player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
            progress = resumeAt
        }
        player.playImmediately(atRate: Float(rate))
        isPlaying = true
        isBuffering = false
        loadFailed = false
        // 修复：播放次数原先在 loadCurrent 里预计数，URL 加载失败/手动重试也会 +1，
        // 导致统计异常；改为真正开始播放时计数，且同一首歌同一会话只计一次。
        if let song = currentSong, lastCountedSongID != song.identityKey {
            bumpPlayCount(song)
            lastCountedSongID = song.identityKey
        }
        lastListeningProgress = nil
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self, let player = self.player else { return }
            if time.seconds.isFinite {
                if let previous = self.lastListeningProgress,
                   self.isPlaying,
                   player.timeControlStatus == .playing {
                    let elapsed = time.seconds - previous
                    if elapsed > 0, elapsed < 0.6 {
                        self.pendingListeningSeconds += elapsed
                        if self.pendingListeningSeconds >= 5 {
                            let wholeSeconds = Int(self.pendingListeningSeconds)
                            self.pendingListeningSeconds -= Double(wholeSeconds)
                            self.listeningSeconds += wholeSeconds
                            self.defaults.set(self.listeningSeconds, forKey: self.listeningSecondsKey)
                        }
                    }
                }
                self.lastListeningProgress = time.seconds
                if abs(time.seconds - self.lastPublishedProgress) >= 0.18 {
                    self.lastPublishedProgress = time.seconds
                    self.progress = time.seconds
                    if abs(time.seconds - self.lastPersistedProgress) >= 2.0 {
                        self.lastPersistedProgress = time.seconds
                        self.savePersistedPlaybackState()
                    }
                }
            }
            if let itemDuration = player.currentItem?.duration, itemDuration.isNumeric {
                let seconds = itemDuration.seconds
                if seconds.isFinite, abs(seconds - self.duration) > 0.25 {
                    self.duration = seconds
                }
            }
            let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            if waiting != self.isBuffering {
                self.isBuffering = waiting
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.playMode == .repeatOne {
                self.restartCurrent()
            } else {
                self.advance()
                self.loadCurrent()
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self,
                  self.player?.currentItem === item,
                  self.currentSong?.identityKey == loadedSong.identityKey else { return }
            self.logPlaybackFailure(
                reason: "AVPlayerItemFailedToPlayToEndTime",
                item: item,
                url: url,
                isThirdParty: isThirdParty,
                playbackHeaders: playbackHeaders
            )
            if fromPlaybackCache {
                MainActor.assumeIsolated { MusicCacheManager.shared.removeCachedFile(for: loadedSong, quality: self.playbackCacheQuality()) }
                ATMusicLogger.shared.log("播放缓存中断，已删除并回退网络：\(loadedSong.name)", level: .debug)
                self.loadCurrent(resumeAt: self.progress)
                return
            }
            if !isThirdParty && self.retryQQOfficialIfNeeded() { return }
            if !isThirdParty && self.fallbackQQToThirdPartyIfNeeded() { return }
            if isThirdParty && self.retryThirdPartyIfNeeded(excludingHost: url.host) { return }
            if self.retryKugouAtStandardIfNeeded(error: item.error) { return }
            self.finishUnrecoverablePlaybackFailure(song: loadedSong, reason: "播放中断失败")
        }
        updateNowPlaying()
    }

    /// AVFoundation KVO callbacks are not guaranteed to arrive on the main
    /// thread. Serialize callbacks that touch ObservableObject state before
    /// reading or mutating the player model.
    private func performOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func finishUnrecoverablePlaybackFailure(
        song: Song?,
        reason: String,
        message: String? = nil
    ) {
        loadFailed = true
        isBuffering = false
        isPlaying = false
        guard let failedSong = song,
              currentSong?.identityKey == failedSong.identityKey,
              finalizedFailureSongKey != failedSong.identityKey else {
            return
        }
        finalizedFailureSongKey = failedSong.identityKey
        if !attemptedSourceFallbacks.contains(failedSong.identityKey) {
            attemptedSourceFallbacks.insert(failedSong.identityKey)
            let occupied = Set(queue.map(\.identityKey))
            if let alternative = UnifiedSongStore.shared.alternateSongs(for: failedSong)
                .first(where: { !occupied.contains($0.identityKey) && !attemptedSourceFallbacks.contains($0.identityKey) }) {
                queue[currentIndex] = alternative
                loadFailed = false
                isBuffering = true
                ATMusicLogger.shared.log("当前来源失败，切换统一库备用来源：\(failedSong.name) -> \(alternative.source.rawValue)", level: .info)
                Task { @MainActor in
                    ToastCenter.shared.show("当前音源不可用，正在切换备用来源", duration: 2)
                }
                loadCurrent()
                return
            }
        }
        let shouldAutoSkip = defaults.object(forKey: autoSkipOnFailureKey) as? Bool ?? true
        let failureMessage: String
        if shouldAutoSkip && queue.count > 1 {
            failureMessage = atmusicLocalized(
                "播放失败，10秒后自动切换到下一首",
                "Playback failed. The next song will start in 10 seconds."
            )
        } else {
            failureMessage = message ?? atmusicLocalized(
                "播放失败，请稍后重试或切换其他歌曲",
                "Playback failed. Please try again later or switch songs."
            )
        }
        Task { @MainActor in
            ToastCenter.shared.show(failureMessage, duration: 3)
        }
        guard shouldAutoSkip, queue.count > 1 else { return }
        ATMusicLogger.shared.log("播放失败自动下一首：\(failedSong.name)｜原因=\(reason)", level: .info)
        let failedSongKey = failedSong.identityKey
        let failedGeneration = loadGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.loadGeneration == failedGeneration,
                  self.currentSong?.identityKey == failedSongKey,
                  self.finalizedFailureSongKey == failedSongKey else {
                return
            }
            self.failureAutoSkipWorkItem = nil
            self.next(manual: false)
        }
        failureAutoSkipWorkItem?.cancel()
        failureAutoSkipWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: workItem)
    }

    private func ensurePlaybackAllowed() -> Bool {
        return true
    }

    /// 统一按当前歌曲平台重新解析第三方地址，失败重试时不跨平台匹配同名歌曲。
    private func resolveThirdParty(
        song: Song,
        quality: ThirdPartyAudioQuality,
        strict: Bool,
        excludedHosts: Set<String> = []
    ) async -> UnblockService.Resolved? {
        switch song.source {
        case .netease:
            return await UnblockService.resolve(
                name: song.name,
                artists: song.artists,
                neteaseID: song.id,
                songSource: .netease,
                quality: quality,
                strict: strict,
                excludedHosts: excludedHosts
            )
        case .qq:
            return await qqFallback(
                song: song,
                quality: ATMusicAudioQuality.current,
                thirdPartyQuality: quality,
                enableUnblock: true,
                strict: strict,
                excludedHosts: excludedHosts
            ).1
        case .kugou:
            let kugouID = song.kugouHash ?? song.kugouAlbumAudioId
            guard let kugouID, !kugouID.isEmpty else { return nil }
            return await UnblockService.resolve(
                name: song.name,
                artists: song.artists,
                neteaseID: 0,
                songSource: .kugou,
                kugouID: kugouID,
                quality: quality,
                excludedHosts: excludedHosts
            )
        case .local:
            return nil
        case .synology:
            return nil
        }
    }

    private func isQQAudioHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host.contains("qq.com")
            || host.contains("qqmusic")
            || host.contains("ptqqmusic")
    }

    private func playbackURLSummary(_ url: URL) -> String {
        let host = url.host ?? "?"
        let path = url.path.isEmpty ? "/" : url.path
        let shortPath = path.count > 72 ? String(path.prefix(72)) + "..." : path
        return "\(host)\(shortPath)"
    }

    private func playerItemStatusDescription(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown: return "unknown"
        case .readyToPlay: return "readyToPlay"
        case .failed: return "failed"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private func sanitizedLogURI(_ rawURI: String?) -> String {
        guard let rawURI, !rawURI.isEmpty else { return "?" }
        if var components = URLComponents(string: rawURI) {
            components.query = nil
            components.fragment = nil
            if let host = components.host {
                let path = components.path.isEmpty ? "/" : components.path
                let shortPath = path.count > 72 ? String(path.prefix(72)) + "..." : path
                return "\(host)\(shortPath)"
            }
            return components.string.map { String($0.prefix(96)) } ?? String(rawURI.prefix(96))
        }
        return String(rawURI.prefix(96))
    }

    private func logPlaybackFailure(
        reason: String,
        item: AVPlayerItem,
        url: URL,
        isThirdParty: Bool,
        playbackHeaders: [String: String]
    ) {
        let error = item.error
        let nsError = error as NSError?
        let errorDescription = error?.localizedDescription ?? "未知错误"
        let errorCode = nsError.map { "\($0.domain):\($0.code)" } ?? "?"
        let eventDetails = item.errorLog()?.events.map { event in
            [
                "domain=\(event.errorDomain)",
                "code=\(event.errorStatusCode)",
                "uri=\(sanitizedLogURI(event.uri))",
                "comment=\(event.errorComment ?? "?")"
            ].joined(separator: " ")
        }.joined(separator: " | ") ?? ""
        let headerKeys = playbackHeaders.keys.sorted().joined(separator: ",")
        ATMusicLogger.shared.log(
            "播放地址加载失败：原因=\(reason)"
                + "｜错误=\(errorDescription)"
                + "｜URL=\(playbackURLSummary(url))"
                + "｜第三方=\(isThirdParty ? "是" : "否")"
                + "｜headers=\(playbackHeaders.isEmpty ? "未添加" : "已添加")"
                + "｜headerKeys=\(headerKeys.isEmpty ? "无" : headerKeys)"
                + "｜itemStatus=\(playerItemStatusDescription(item.status))"
                + "｜NSError=\(errorCode)"
                + "｜AVErrorLog=\(eventDetails.isEmpty ? "无" : eventDetails)",
            level: .error
        )
    }

    private func removeCurrentObservers() {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }
        failureObserver = nil
        itemStatusObserver = nil
        timeControlStatusObserver = nil
        playbackConfirmationWorkItem?.cancel()
        playbackConfirmationWorkItem = nil
        failureAutoSkipWorkItem?.cancel()
        failureAutoSkipWorkItem = nil
        playbackStallWorkItem?.cancel()
        playbackStallWorkItem = nil
        playbackConfirmed = false
        pendingThirdPartyVIPNotice = nil
        lastPublishedProgress = -1
    }

    /// 均衡器通过 AVAudioMix 的音频处理 tap 工作，不改动 URL、队列或播放器状态。
    /// 曲目切换和开关均复用这里的挂载流程，避免让网络请求跑到主线程。
    private func applyEqualizerToCurrentItem() {
        guard let item = player?.currentItem else { return }
        configureEqualizer(for: item)
    }

    private func configureEqualizer(for item: AVPlayerItem) {
        guard ATMusicEqualizer.shared.isEnabled else {
            item.audioMix = nil
            return
        }

        Task { [weak self, weak item] in
            guard let self, let item else { return }
            do {
                let tracks = try await item.asset.load(.tracks)
                guard let track = tracks.first(where: { $0.mediaType == .audio }),
                      let mix = ATMusicEqualizer.shared.makeAudioMix(for: track) else { return }
                self.performOnMain { [weak self, weak item] in
                    guard let self,
                          let item,
                          self.player?.currentItem === item,
                          ATMusicEqualizer.shared.isEnabled else { return }
                    item.audioMix = mix
                }
            } catch {
                ATMusicLogger.shared.log("均衡器音轨加载失败：\(error.localizedDescription)", level: .warn)
            }
        }
    }

    private func thirdPartyVIPNotice(for song: Song, sourceTitle: String) -> ThirdPartyVIPNotice? {
        guard song.isVIP else { return nil }
        guard defaults.object(forKey: thirdPartyVIPNoticeKey) as? Bool ?? true else { return nil }
        guard !hasMembership(for: song.source) else { return nil }
        let sourceName = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = sourceName.isEmpty ? "第三方音源" : "第三方音源「\(sourceName)」"
        return ThirdPartyVIPNotice(
            songKey: song.identityKey,
            message: "当前账号未识别到对应会员，《\(song.name)》已通过\(suffix)播放"
        )
    }

    private func showPendingThirdPartyVIPNoticeIfNeeded() {
        guard let notice = pendingThirdPartyVIPNotice else { return }
        guard currentSong?.identityKey == notice.songKey else {
            pendingThirdPartyVIPNotice = nil
            return
        }
        guard defaults.object(forKey: thirdPartyVIPNoticeKey) as? Bool ?? true else {
            pendingThirdPartyVIPNotice = nil
            return
        }
        Task { @MainActor in
            ToastCenter.shared.show(notice.message)
        }
        ATMusicLogger.shared.log("第三方音源会员歌提醒：\(notice.message)", level: .info)
        pendingThirdPartyVIPNotice = nil
    }

    private func hasMembership(for source: SongSource) -> Bool {
        switch source {
        case .qq:
            return QQMusicAuth.shared.vipBadge != nil
        case .kugou:
            return KugouMusicAuth.shared.vipBadge != nil
        case .local:
            return true
        case .netease:
            guard let data = defaults.data(forKey: "atmusic.user"),
                  let user = try? JSONDecoder().decode(NetEaseUser.self, from: data) else {
                return false
            }
            return user.vipBadge != nil
        case .synology:
            return true
        }
    }

    private func configureAudioSession() {
        if Self.applyAudioMixPreference(mixesWithOthers) {
            sessionConfigured = true
        } else {
            sessionConfigured = false
        }
    }

    @discardableResult
    static func applyAudioMixPreference(_ mixesWithOthers: Bool) -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            // 「与其他音频同时播放」开关：开启时 mixWithOthers，打开其他音频软件也能继续播放；关闭则自动暂停
            if mixesWithOthers {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            } else {
                try session.setCategory(.playback, mode: .default)
            }
            try session.setActive(true)
            return true
        } catch {
            ATMusicLogger.shared.log("音频会话配置失败：\(error.localizedDescription)", level: .error)
            return false
        }
    }

    /// 延后初始化系统音频服务，降低自签安装后首次启动时的兼容性风险。
    /// 播放真正开始前由 setupPlayer 兜底调用，因此不会影响播放器功能。
    private func prepareForSystemPlayback() {
        guard !systemPlaybackPrepared else { return }
        systemPlaybackPrepared = true
        observeInterruptions()
        observeRouteChanges()
        setupRemoteCommands()
    }

    private func observeRouteChanges() {
        guard !routeObserverInstalled else { return }
        routeObserverInstalled = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    /// 输出设备变化（插拔耳机 / 切换扬声器 / 来电路由等）后重新激活会话，避免播放无声
    @objc private func handleRouteChange(_ notification: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleRouteChange(notification)
            }
            return
        }
        sessionConfigured = false
        configureAudioSession()
        if isPlaying, player?.timeControlStatus != .playing {
            player?.playImmediately(atRate: Float(rate))
        }
    }

    // MARK: - 来电/中断处理

    private func observeInterruptions() {
        guard !interruptionObserverInstalled else { return }
        interruptionObserverInstalled = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleInterruption(notification)
            }
            return
        }
        guard let info = notification.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            // 开启「与其他音频同时播放」时，不被其他 App 音频中断，保持继续播放
            guard !mixesWithOthers else { return }
            player?.pause()
            isPlaying = false
        case .ended:
            // 中断结束后系统可能停用了音频会话，重新激活避免无声
            sessionConfigured = false
            configureAudioSession()
            wasPlayingBeforeInterruption = false
            isPlaying = false
            updateNowPlaying()
        @unknown default:
            break
        }
    }

    // MARK: - 播放历史与统计

    private func pushHistory(_ song: Song) {
        history.removeAll { $0.identityKey == song.identityKey }
        history.insert(song, at: 0)
        if history.count > 50 {
            history = Array(history.prefix(50))
        }
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: historyKey)
        }
    }

    private func loadHistory() {
        guard let data = defaults.data(forKey: historyKey),
              let saved = try? JSONDecoder().decode([Song].self, from: data) else { return }
        history = saved
    }

    private func bumpPlayCount(_ song: Song) {
        playCounts[song.identityKey, default: 0] += 1
        if let data = try? JSONEncoder().encode(playCounts) {
            defaults.set(data, forKey: countsKey)
        }
    }

    private func loadPlayCounts() {
        guard let data = defaults.data(forKey: countsKey),
              let saved = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        playCounts = saved
    }

    private func savePersistedPlaybackState() {
        guard !queue.isEmpty, queue.indices.contains(currentIndex) else {
            defaults.removeObject(forKey: playbackStateKey)
            return
        }
        let state = PersistedPlaybackState(
            queue: queue,
            currentIndex: currentIndex,
            progress: progress,
            duration: duration,
            savedAt: Date()
        )
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: playbackStateKey)
        }
    }

    private func restorePersistedPlaybackState() {
        guard let data = defaults.data(forKey: playbackStateKey),
              let saved = try? JSONDecoder().decode(PersistedPlaybackState.self, from: data),
              !saved.queue.isEmpty else { return }
        queue = saved.queue
        currentIndex = min(max(saved.currentIndex, 0), saved.queue.count - 1)
        duration = max(saved.duration, currentSong?.duration ?? 0)
        progress = max(0, min(saved.progress, max(duration, currentSong?.duration ?? 0)))
        isPlaying = false
        isBuffering = false
        loadFailed = false
        buildPlayOrder()
    }

    /// 听歌排行：按播放次数排序的前几首
    var topPlayed: [(song: Song, count: Int)] {
        var result: [(song: Song, count: Int)] = []
        for (key, count) in playCounts {
            if let song = history.first(where: { $0.identityKey == key }) {
                result.append((song, count))
            }
        }
        return result.sorted { $0.count > $1.count }.prefix(8).map { $0 }
    }

    // MARK: - 系统正在播放

    private func updateNowPlaying() {
        guard let song = currentSong else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.name,
            MPMediaItemPropertyArtist: song.artists,
            MPMediaItemPropertyAlbumTitle: song.album,
            MPMediaItemPropertyPlaybackDuration: max(duration, song.duration),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0.0,
        ]
        if let artworkURL = song.coverURL {
            let artworkKey = song.identityKey + "|" + artworkURL.absoluteString
            if let cached = Self.nowPlayingArtworkCache.object(forKey: artworkURL as NSURL) {
                info[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(cached)
            } else if lastNowPlayingArtworkKey != artworkKey {
                lastNowPlayingArtworkKey = artworkKey
                loadNowPlayingArtwork(song: song, key: artworkKey, url: artworkURL)
            }
        } else {
            lastNowPlayingArtworkKey = nil
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// 使用原始封面尺寸响应系统的多个请求，锁屏和控制中心就能拿到足够大的方形 artwork。
    private static func nowPlayingArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { requestedSize in
            guard requestedSize.width > 0, requestedSize.height > 0 else { return image }
            return image
        }
    }

    private func loadNowPlayingArtwork(song: Song, key: String, url: URL) {
        Task.detached(priority: .utility) { [weak self] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.cachePolicy = .returnCacheDataElseLoad
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let image = UIImage(data: data) else { return }

            Self.nowPlayingArtworkCache.setObject(image, forKey: url as NSURL)
            await MainActor.run {
                guard let self,
                      self.currentSong?.identityKey == song.identityKey,
                      self.lastNowPlayingArtworkKey == key else { return }
                var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                updated[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(image)
                MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
            }
        }
    }

    private func setupRemoteCommands() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.performOnMain { [weak self] in
                guard let self else { return }
                guard self.ensurePlaybackAllowed() else { return }
                self.player?.playImmediately(atRate: Float(self.rate))
                self.isPlaying = true
                self.updateNowPlaying()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.performOnMain { [weak self] in
                guard let self else { return }
                self.player?.pause()
                self.isPlaying = false
                self.updateNowPlaying()
            }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.performOnMain { [weak self] in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.performOnMain { [weak self] in self?.previous() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.performOnMain { [weak self] in self?.togglePlayPause() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.performOnMain { [weak self] in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    // MARK: - 与其他音频同时播放

    /// 与其他 App 音频混合播放。默认关闭，让系统把 AT Music 作为主播放 App 显示到锁屏/灵动岛。
    var mixesWithOthers: Bool {
        get { defaults.object(forKey: audioMixKey) as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: audioMixKey)
            sessionConfigured = false
            configureAudioSession()
        }
    }

}
