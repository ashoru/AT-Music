import SwiftUI

/// NAS 歌词批量写回流水线。
///
/// 场景：曲库几千首 NAS 歌曲，很多只有音频没有内嵌歌词；逐首点「搜索歌词」根本不现实。
/// 这里做成一台小流水线：先读现有歌词判断要不要动，再跨源匹配（网易/QQ/酷狗），
/// 命中后经 Audio Station 标签通道把歌词写进**原始音频文件**，最后回读确认。
/// 全程逐首处理、可随时中止，失败项可一键重试，避免给 NAS 和第三方接口造成压力。
struct NASLyricsBatchSheet: View {
    enum Strategy: Int, CaseIterable, Identifiable {
        case missingOnly
        case overwriteAll

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .missingOnly: return "只补缺失"
            case .overwriteAll: return "全部重写"
            }
        }
        var hint: String {
            switch self {
            case .missingOnly: return "已有歌词的歌曲直接跳过，最安全"
            case .overwriteAll: return "用匹配到的在线歌词覆盖 NAS 上现有歌词"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: ThemeStore
    @ObservedObject private var synology = SynologyAPI.shared
    @StateObject private var runner = NASLyricsBatchRunner()

    @State private var strategy: Strategy = .missingOnly
    @State private var limit: Int = 50
    @State private var isPreparing = false
    @State private var message = ""

    private let limitOptions: [Int] = [20, 50, 100, 300]

    var body: some View {
        ZStack {
            Color.atmusicBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 14) {
                        introCard
                        if !runner.isRunning && runner.items.isEmpty {
                            optionsCard
                        }
                        if !runner.items.isEmpty {
                            progressCard
                            itemList
                        }
                        if !message.isEmpty {
                            Text(message)
                                .font(ATMusicFont.appFont(12))
                                .foregroundStyle(Color.atmusicComment)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }
                        actionBar
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 26)
                }
            }
        }
        .modifier(ATMusicSheetModifier(detents: [.large], dragIndicator: true))
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.atmusicAmber)
                .frame(width: 38, height: 38)
                .background(Color.atmusicAmber.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("歌词批量写回 NAS")
                    .font(ATMusicFont.appFont(16, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                Text("跨源匹配 · 写入原文件 · 回读校验")
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)
            }
            Spacer()
            Button {
                ATMusicHaptics.tap()
                if runner.isRunning { runner.cancel() }
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.atmusicComment.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("它会做什么", systemImage: "info.circle")
                .font(ATMusicFont.appFont(12, .semibold))
                .foregroundStyle(Color.atmusicAmber)
            Text("逐首读取 NAS 现有歌词 → 按歌名/歌手/专辑/时长跨源匹配（宁缺毋滥，低置信不写）→ 命中后写入原音频文件并回读确认。"
                 + "本地播放界面里校准过的歌词，请用播放页的「歌词同步校准」逐曲烘焙写回。")
                .font(ATMusicFont.appFont(12))
                .foregroundStyle(Color.atmusicComment)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("写入策略")
                    .font(ATMusicFont.appFont(12, .semibold))
                    .foregroundStyle(Color.atmusicComment)
                Picker("写入策略", selection: $strategy) {
                    ForEach(Strategy.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                Text(strategy.hint)
                    .font(ATMusicFont.appFont(10))
                    .foregroundStyle(Color.atmusicComment.opacity(0.85))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("本次处理上限")
                    .font(ATMusicFont.appFont(12, .semibold))
                    .foregroundStyle(Color.atmusicComment)
                HStack(spacing: 8) {
                    ForEach(limitOptions, id: \.self) { value in
                        Button {
                            ATMusicHaptics.select()
                            limit = value
                        } label: {
                            Text("\(value) 首")
                                .font(ATMusicFont.appFont(12, limit == value ? .semibold : .regular))
                                .foregroundStyle(limit == value ? Color.atmusicLabel : Color.atmusicComment)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    limit == value ? Color.atmusicAmber.opacity(0.18) : Color.primary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !synology.isLoggedIn {
                Text("尚未连接群晖 NAS，请先在「设置 → 群晖 NAS」登录。")
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)
            }
        }
        .padding(14)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(runner.isRunning ? "正在处理…" : "处理结果")
                    .font(ATMusicFont.appFont(13, .semibold))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                Text("\(runner.processedCount)/\(runner.items.count)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.atmusicAmber)
            }
            ProgressView(value: Double(runner.processedCount), total: Double(max(1, runner.items.count)))
                .tint(Color.atmusicAmber)
            if !runner.summary.isEmpty {
                Text(runner.summary)
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)
            }
        }
        .padding(14)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
    }

    private var itemList: some View {
        LazyVStack(spacing: 6) {
            ForEach(runner.items) { item in
                HStack(spacing: 10) {
                    statusIcon(item.state)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.song.name)
                            .font(ATMusicFont.appFont(13))
                            .foregroundStyle(Color.atmusicLabel)
                            .lineLimit(1)
                        Text(item.detail.isEmpty ? (item.song.artists.isEmpty ? item.state.title : item.song.artists) : item.detail)
                            .font(ATMusicFont.appFont(10))
                            .foregroundStyle(Color.atmusicComment)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(item.state.title)
                        .font(ATMusicFont.appFont(10, .medium))
                        .foregroundStyle(item.state.color)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ state: NASLyricsBatchRunner.ItemState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle.dotted").font(.system(size: 13)).foregroundStyle(Color.atmusicComment.opacity(0.6))
        case .checking, .matching, .writing:
            ProgressView().controlSize(.mini)
        case .written:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Color.green)
        case .skipped:
            Image(systemName: "minus.circle").font(.system(size: 13)).foregroundStyle(Color.atmusicComment)
        case .noMatch:
            Image(systemName: "questionmark.circle").font(.system(size: 13)).foregroundStyle(Color.orange)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Color.red.opacity(0.85))
        }
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            if runner.isRunning {
                GlassButton(title: "中止处理", systemName: "stop.circle") {
                    runner.cancel()
                }
            } else if runner.hasFailures {
                GlassButton(title: "重试失败项（\(runner.failureCount)）", systemName: "arrow.clockwise", prominent: true) {
                    runner.retryFailures()
                }
                GlassButton(title: "重新开始", systemName: "gobackward") {
                    runner.reset()
                }
            } else {
                GlassButton(
                    title: isPreparing ? "正在读取 NAS 曲库…" : "开始批量匹配写回",
                    systemName: "text.badge.checkmark",
                    prominent: true
                ) {
                    start()
                }
                .disabled(isPreparing || !synology.isLoggedIn)
                .opacity(isPreparing || !synology.isLoggedIn ? 0.5 : 1)
            }
        }
    }

    // MARK: - 动作

    private func start() {
        guard !isPreparing else { return }
        isPreparing = true
        message = ""
        Task {
            do {
                let songs = try await Self.loadLibrarySongs(maxCount: 2000)
                await MainActor.run {
                    isPreparing = false
                    if songs.isEmpty {
                        message = "NAS 曲库为空，请先在群晖音乐库中确认歌曲索引。"
                        return
                    }
                    let ordered = Self.prioritized(songs)
                    runner.start(songs: Array(ordered.prefix(limit)), strategy: strategy)
                }
            } catch {
                await MainActor.run {
                    isPreparing = false
                    message = "读取 NAS 曲库失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 分页读取曲库：Audio Station 单页有条数上限，几百上千首的库必须翻页，
    /// 否则这一轮会「只看到前 500 首」。
    private static func loadLibrarySongs(maxCount: Int) async throws -> [Song] {
        var collected: [Song] = []
        var offset = 0
        let pageSize = 500
        var seen = Set<String>()
        while collected.count < maxCount {
            let page = try await SynologyAPI.shared.songs(offset: offset, limit: pageSize)
            if page.isEmpty { break }
            var added = 0
            for song in page where seen.insert(song.identityKey).inserted {
                collected.append(song)
                added += 1
            }
            if page.count < pageSize || added == 0 { break }
            offset += page.count
        }
        return collected
    }

    /// 没有曲目号的歌优先（多半是散装文件），让这一轮先啃硬骨头。
    private static func prioritized(_ songs: [Song]) -> [Song] {
        songs.sorted { lhs, rhs in
            if (lhs.trackNumber > 0) != (rhs.trackNumber > 0) { return !(lhs.trackNumber > 0) }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

// MARK: - 运行器

@MainActor
final class NASLyricsBatchRunner: ObservableObject {
    enum ItemState {
        case pending
        case checking
        case matching
        case writing
        case written
        case skipped
        case noMatch
        case failed

        var title: String {
            switch self {
            case .pending: return "待处理"
            case .checking: return "读取中"
            case .matching: return "匹配中"
            case .writing: return "写入中"
            case .written: return "已写回"
            case .skipped: return "跳过"
            case .noMatch: return "未匹配"
            case .failed: return "失败"
            }
        }

        var color: Color {
            switch self {
            case .written: return .green
            case .failed: return .red
            case .noMatch: return .orange
            case .skipped: return Color.atmusicComment
            case .pending, .checking, .matching, .writing: return Color.atmusicComment.opacity(0.8)
            }
        }

        var isTerminal: Bool {
            switch self {
            case .written, .skipped, .noMatch, .failed: return true
            default: return false
            }
        }
    }

    struct Item: Identifiable {
        let id: String
        let song: Song
        var state: ItemState = .pending
        var detail: String = ""

        var isFailure: Bool { state == .failed }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false
    @Published private(set) var summary: String = ""

    private var task: Task<Void, Never>?
    private var strategy: NASLyricsBatchSheet.Strategy = .missingOnly

    var processedCount: Int { items.filter { $0.state.isTerminal }.count }
    var hasFailures: Bool { items.contains(where: { $0.isFailure }) }
    var failureCount: Int { items.filter { $0.isFailure }.count }

    func start(songs: [Song], strategy: NASLyricsBatchSheet.Strategy) {
        guard !isRunning else { return }
        self.strategy = strategy
        items = songs.map { Item(id: $0.identityKey, song: $0) }
        summary = ""
        isRunning = true
        task = Task { [weak self] in
            await self?.run(overwriteAll: strategy == .overwriteAll)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        summary = "已中止：处理 \(processedCount)/\(items.count) 首"
        ATMusicLogger.shared.log("🎵 NAS 歌词批量写回被用户中止（\(processedCount)/\(items.count)）", level: .info)
    }

    func reset() {
        task?.cancel()
        task = nil
        items = []
        summary = ""
        isRunning = false
    }

    func retryFailures() {
        guard !isRunning else { return }
        let retrySongs = items.filter { $0.isFailure }.map { $0.song }
        guard !retrySongs.isEmpty else { return }
        for index in items.indices where items[index].isFailure {
            items[index].state = .pending
            items[index].detail = ""
        }
        isRunning = true
        task = Task { [weak self] in
            await self?.run(overwriteAll: self?.strategy == .overwriteAll, onlyFailures: true)
        }
    }

    private func update(_ id: String, state: ItemState, detail: String? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
        if let detail { items[index].detail = detail }
    }

    private func run(overwriteAll: Bool, onlyFailures: Bool = false) async {
        var written = 0
        var skipped = 0
        var unmatched = 0
        var failed = 0
        let targets = items.filter { !onlyFailures || $0.state == .pending }

        for item in targets {
            if Task.isCancelled { break }
            let song = item.song
            update(item.id, state: .checking)

            // 1. 现有歌词检查
            var existing = ""
            if !overwriteAll {
                existing = (try? await SynologyAPI.shared.lyrics(song: song)) ?? ""
                if !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    skipped += 1
                    update(item.id, state: .skipped, detail: "已有歌词，按策略跳过")
                    continue
                }
            }
            if Task.isCancelled { break }

            // 1.5 容器不可写就别白跑一趟：Audio Station 只对部分格式真正落盘标签
            let writableExtensions: Set<String> = ["mp3", "m4a", "m4b", "ogg", "flac", "aiff"]
            let ext = ((song.synologyPath ?? "") as NSString).pathExtension.lowercased()
            guard !ext.isEmpty, writableExtensions.contains(ext) else {
                skipped += 1
                update(item.id, state: .skipped,
                       detail: ext.isEmpty ? "缺少原文件路径，无法写回" : "\(ext.uppercased()) 不支持写入歌词标签")
                continue
            }

            // 2. 跨源匹配
            update(item.id, state: .matching)
            guard let match = await SongLyricsLoader.matchOnlineLyrics(for: song) else {
                unmatched += 1
                update(item.id, state: .noMatch, detail: "没有高置信匹配结果")
                continue
            }
            if Task.isCancelled { break }

            // 3. 写入原文件并回读校验
            update(item.id, state: .writing, detail: "\(match.provider) · 置信 \(match.score)")
            do {
                try await SynologyAPI.shared.applyMetadata(
                    song: song,
                    patch: LyricWriteback.emptyPatch(),
                    lyrics: match.lrc
                )
                ATMusicCacheCoordinator.shared.cacheLyric(for: song, content: match.lrc)
                written += 1
                let lineCount = match.lrc.components(separatedBy: "\n").count
                update(item.id, state: .written, detail: "\(match.provider) · \(lineCount) 行")
            } catch {
                failed += 1
                update(item.id, state: .failed, detail: error.localizedDescription)
                ATMusicLogger.shared.log("⚠️ NAS 歌词写回失败：\(song.name) - \(error.localizedDescription)", level: .error)
            }
        }

        let cancelled = Task.isCancelled
        isRunning = false
        summary = "写回 \(written) 首 · 跳过 \(skipped) 首 · 未匹配 \(unmatched) 首 · 失败 \(failed) 首" + (cancelled ? "（已中止）" : "")
        ATMusicLogger.shared.log("🎵 NAS 歌词批量写回结束：\(summary)", level: .info)
        if written > 0 {
            ToastCenter.shared.show("歌词写回完成：\(written) 首")
        }
    }
}
