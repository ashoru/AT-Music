import SwiftUI

// MARK: - 流式标签布局（热搜标签云）

@available(iOS 16, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension SearchProvider {
    /// 主题色渐变：网易云红 / QQ 绿 / 群晖深蓝
    var tint: LinearGradient {
        switch self {
        case .netease: return LinearGradient(
            colors: [Color(red: 0.93, green: 0.22, blue: 0.16), Color(red: 0.80, green: 0.15, blue: 0.12)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        case .qq: return LinearGradient(
            colors: [Color(red: 0.15, green: 0.78, blue: 0.55), Color(red: 0.05, green: 0.58, blue: 0.42)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        case .kugou: return LinearGradient(
            colors: [Color(red: 0.12, green: 0.58, blue: 0.95), Color(red: 0.02, green: 0.32, blue: 0.72)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        case .synology: return LinearGradient(
            colors: [Color(red: 0.08, green: 0.45, blue: 0.85), Color(red: 0.02, green: 0.25, blue: 0.60)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

enum SearchResultType: String, CaseIterable, Identifiable {
    case song = "歌曲"
    case artist = "歌手"
    case album = "专辑"
    case playlist = "歌单"

    var id: String { rawValue }
}

private struct SynologySearchEntry: Identifiable {
    let id: String
    let names: [String]
    let subtitle: String
    let coverURL: URL?
}

private struct SynologyArtistSelection: Identifiable {
    let id: String
    let name: String
    let coverURL: URL?
}

private struct SynologyAlbumSelection: Identifiable {
    let id: String
    let name: String
    let artistName: String
    let coverURL: URL?
}

/// 聚合“综合”页的完整快照。
///
/// 必须使用单个 State 原子提交，不能将歌曲、歌手、专辑和歌单分别写入
/// 多个 State。后者会让 SwiftUI 在同一次网络回包中连续重建整棵结果视图，
/// 真机上会表现为结果反复闪烁。
private struct AggregateOverviewSnapshot {
    let songs: [Song]
    let artists: [Artist]
    let albums: [Album]
    let playlists: [Playlist]
}

struct SearchView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    @State private var keyword = ""
    @AppStorage("atmusic.search.provider") private var providerRaw = SearchProvider.netease.rawValue
    @State private var provider: SearchProvider = .netease
    /// 搜索页聚合当前“平台显示”中启用的音源；关闭的平台不参与搜索，也不出现在筛选器里。
    @State private var aggregateSearch = true
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared
    @ObservedObject private var synology = SynologyAPI.shared
    private var searchProviders: [SearchProvider] { platformPrefs.enabledSearchProviders }
    @State private var resultType: SearchResultType = .song
    /// 聚合搜索默认展示 1.8 风格的综合结果；分类胶囊仍可切换到单一类型。
    @State private var aggregateOverview = true
    @State private var songResults: [Song] = []
    @State private var artistResults: [Artist] = []
    @State private var albumResults: [Album] = []
    @State private var playlistResults: [Playlist] = []
    // 综合页只接收一个原子快照；分类页仍使用上面四组实时结果。
    @State private var overviewSnapshot: AggregateOverviewSnapshot?
    @State private var synologyArtistEntries: [SynologySearchEntry] = []
    @State private var synologyAlbumEntries: [SynologySearchEntry] = []
    @State private var synologySearchSongs: [Song] = []
    @State private var hotWordsByProvider: [SearchProvider: [String]] = [:]
    @State private var hotLoadingProviders: Set<SearchProvider> = []
    @State private var hotUnavailableProviders: Set<SearchProvider> = []
    /// 热搜也做代际保护：平台范围变化后，旧请求晚回包不能污染当前空搜索页。
    @State private var hotWordsGeneration = 0
    @State private var searching = false
    @State private var errorMessage: String?
    @State private var showAddToPlaylist: Song?
    @State private var selectedArtist: Artist?
    @State private var selectedSynologyArtist: SynologyArtistSelection?
    @State private var selectedSynologyAlbum: SynologyAlbumSelection?
    /// 搜索结果页没有额外包裹 NavigationStack；歌单统一用详情页弹层打开，
    /// 这样聚合搜索和单平台搜索的歌单都能稳定进入详情。
    @State private var selectedPlaylist: Playlist?
    @State private var selectedAlbum: Album?
    @ObservedObject private var historyStore = SearchHistoryStore.shared
    @State private var debounceTask: Task<Void, Never>?
    @State private var searchTask: Task<Void, Never>?
    @State private var nasIndexRefreshTask: Task<Void, Never>?
    /// 平台/聚合范围经常会在同一次点击里连续改变两个状态；合并成一次搜索。
    @State private var scopeRefreshTask: Task<Void, Never>?
    /// 点击热搜/历史记录时 keyword 会同步变化；该标记用于跳过这一次输入 debounce，
    /// 因为按钮本身已经立即发起搜索。
    @State private var immediateKeyword: String?
    /// 同一关键词、范围和分类只允许一个在途请求。输入框提交、索引通知和
    /// 页面事件偶尔会在同一帧同时到达，若全部放行会让新旧结果互相覆盖。
    @State private var activeSearchKey: String?
    /// 每次搜索递增；网络层无法立即取消时，用它拒绝旧请求的迟到回包。
    @State private var searchGeneration = 0
    /// UIKit 输入框控制器（提交拼音、收起键盘等由它统一处理）
    @State private var searchController = SearchFieldController()

    private var isNativeClean: Bool {
        ATMusicUIStyle(rawValue: uiStyleRaw) == .nativeClean
    }

    private var searchScopeName: String {
        aggregateSearch ? "聚合" : provider.rawValue
    }

    private var totalSearchResultCount: Int {
        songResults.count + artistResults.count + albumResults.count + playlistResults.count
    }

    private var overviewResultCount: Int {
        overviewSongs.count + overviewArtists.count + overviewAlbums.count + overviewPlaylists.count
    }

    private var overviewSongs: [Song] { overviewSnapshot?.songs ?? [] }
    private var overviewArtists: [Artist] { overviewSnapshot?.artists ?? [] }
    private var overviewAlbums: [Album] { overviewSnapshot?.albums ?? [] }
    private var overviewPlaylists: [Playlist] { overviewSnapshot?.playlists ?? [] }
    private var hasOverviewSnapshot: Bool { overviewSnapshot != nil }

    /// 空搜索页聚合已启用的平台热搜。搜索范围严格是“聚合”或“单一平台”，
    /// 不保留历史的多选状态，以免显示与实际请求范围不一致。
    private var referenceHotWords: [String] {
        var seen = Set<String>()
        var words: [String] = []
        for source in searchProviders {
            for word in hotWordsByProvider[source] ?? [] {
                let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seen.insert(trimmed.localizedLowercase).inserted else { continue }
                words.append(trimmed)
                if words.count == 10 { return words }
            }
        }
        return words
    }

    private func isEnabledAggregateSource(_ source: SongSource, in enabled: Set<SearchProvider>) -> Bool {
        guard let provider = source.searchProvider else { return true }
        return enabled.contains(provider)
    }

    private func resetOverviewSnapshot() {
        overviewSnapshot = nil
    }

    private func filterOverviewSnapshot(enabledProviders: Set<SearchProvider>) {
        guard let snapshot = overviewSnapshot else { return }
        overviewSnapshot = AggregateOverviewSnapshot(
            songs: snapshot.songs.filter { isEnabledAggregateSource($0.source, in: enabledProviders) },
            artists: snapshot.artists.filter { isEnabledAggregateSource($0.source, in: enabledProviders) },
            albums: snapshot.albums.filter { isEnabledAggregateSource($0.source, in: enabledProviders) },
            playlists: snapshot.playlists.filter { isEnabledAggregateSource($0.source, in: enabledProviders) }
        )
    }

    private func captureOverviewSnapshot(from result: AggregatedSearchResult, localPlaylists: [Playlist]) {
        overviewSnapshot = AggregateOverviewSnapshot(
            songs: result.songs,
            artists: result.artists,
            albums: result.albums,
            playlists: localPlaylists + result.playlists
        )
    }

    /// 流式回包期间只追加新项目，保留屏幕上已显示项目的位置和视图身份。
    /// 最终结果仍会按相关性一次性排序提交。
    private func stableAppend<Element>(
        current: [Element],
        incoming: [Element],
        identity: (Element) -> String
    ) -> [Element] {
        var seen = Set(current.map(identity))
        var result = current
        result.append(contentsOf: incoming.filter { seen.insert(identity($0)).inserted })
        return result
    }

    /// 立即使当前请求失效。网络层即使不能立刻取消，generation 也会拒绝迟到回包。
    private func invalidateSearchPipeline(cancelDebounce: Bool = true) {
        if cancelDebounce { debounceTask?.cancel() }
        scopeRefreshTask?.cancel()
        nasIndexRefreshTask?.cancel()
        searchTask?.cancel()
        searchGeneration &+= 1
        activeSearchKey = nil
        searching = false
    }

    private func clearSearchResults() {
        songResults = []
        artistResults = []
        albumResults = []
        playlistResults = []
        resetOverviewSnapshot()
        synologyArtistEntries = []
        synologyAlbumEntries = []
        synologySearchSongs = []
        errorMessage = nil
    }

    /// 平台和“聚合/单平台”经常在一次菜单操作中连续变化。短暂合并后只按最终状态搜一次。
    private func scheduleScopeRefresh(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        scopeRefreshTask?.cancel()
        scopeRefreshTask = Task {
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            guard keyword.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            await startSearch(trimmed)
        }
    }

    /// 热搜/历史/歌手名点击：立即搜索，同时抑制由 keyword 赋值产生的那一次 debounce。
    private func runImmediateSearch(_ text: String, updateKeyword: Bool = false, recordHistory: Bool = true) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        debounceTask?.cancel()
        nasIndexRefreshTask?.cancel()
        if updateKeyword, keyword != trimmed {
            immediateKeyword = trimmed
            keyword = trimmed
        }
        if recordHistory { historyStore.record(trimmed) }
        Task { await startSearch(trimmed) }
    }

    /// NAS 索引可能在很短时间内连续发布分页进度。合并这些通知，等索引稳定
    /// 后只补搜一次；执行前再次确认关键词没有变化，避免旧 NAS 事件顶掉新搜索。
    private func scheduleNASIndexRefresh(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        nasIndexRefreshTask?.cancel()
        nasIndexRefreshTask = Task {
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            guard keyword.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            await startSearch(trimmed)
        }
    }

    var body: some View {
        let _ = theme.accent
        ZStack(alignment: .top) {
            // 页面背景：同步开启时显示壁纸/背景色，否则默认氛围渐变
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
            // 实例级 UITabBar 清透风格（固定全透明，无需调节）
            TabBarAppearanceConfigurator()
            VStack(spacing: 0) {
                headerTitle
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                searchField
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)

                contentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .task {
            await loadAllHotWords()
        }
        .onChange(of: keyword) { _, newValue in
            debounceTask?.cancel()
            nasIndexRefreshTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)

            // 程序化点击热搜/历史记录已经立即搜索，不再额外安排 400ms debounce。
            if immediateKeyword == trimmed {
                immediateKeyword = nil
                return
            }
            immediateKeyword = nil

            guard !trimmed.isEmpty else {
                invalidateSearchPipeline(cancelDebounce: false)
                clearSearchResults()
                return
            }

            // 用户已经输入了新关键词，立即让旧请求失效；旧结果可暂时留在屏幕上，
            // 等新搜索原子提交后再替换，避免输入过程中整页闪空。
            invalidateSearchPipeline(cancelDebounce: false)
            searching = true
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await startSearch(trimmed)
            }
        }
        .onChange(of: provider) { _, _ in
            providerRaw = provider.rawValue
            // 聚合模式只关心 enabledSearchProviders；provider 只是下次单平台搜索的备用值，
            // 不能因为它变化就清空/重搜当前聚合页。
            guard !aggregateSearch else { return }
            invalidateSearchPipeline()
            aggregateOverview = false
            if provider == .synology { resultType = .song }
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            searching = true
            scheduleScopeRefresh(trimmed)
        }
        .onChange(of: aggregateSearch) { _, enabled in
            invalidateSearchPipeline()
            aggregateOverview = enabled
            if !enabled, provider == .synology { resultType = .song }
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            searching = true
            scheduleScopeRefresh(trimmed)
        }
        .onChange(of: synology.libraryIndexRevision) { _, _ in
            // 首次搜索先显示 Audio Station 的快速结果；完整 NAS 索引完成后，
            // 自动重搜当前关键词，把曲库后部的歌曲、歌手和专辑补进来。
            let nasParticipates = aggregateSearch
                ? searchProviders.contains(.synology)
                : provider == .synology
            guard nasParticipates, !synology.isLibraryIndexLoading else { return }
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            scheduleNASIndexRefresh(trimmed)
        }
        .onChange(of: synology.isLibraryIndexLoading) { _, loading in
            // 索引按分页更新 revision；只在整次索引结束后补搜一次，不能每页
            // 都重启聚合搜索，否则结果会在多组快照之间持续闪烁。
            guard !loading else { return }
            let nasParticipates = aggregateSearch
                ? searchProviders.contains(.synology)
                : provider == .synology
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard nasParticipates, !trimmed.isEmpty else { return }
            scheduleNASIndexRefresh(trimmed)
        }
        .onAppear {
            provider = platformPrefs.ensureVisible(SearchProvider(rawValue: providerRaw) ?? .netease)
        }
        // 直接观察值变化，不能订阅计算型 AnyPublisher。后者在视图重建时会
        // 重新订阅并立即回放当前值，形成“结果更新 → 重绘 → 再次搜索”的循环。
        .onChange(of: platformPrefs.selectedRaw) { _, _ in
            let next = platformPrefs.ensureVisible(provider)
            if next != provider {
                provider = next
            }
            if aggregateSearch {
                let enabled = Set(searchProviders)
                songResults.removeAll { !isEnabledAggregateSource($0.source, in: enabled) }
                playlistResults.removeAll { !isEnabledAggregateSource($0.source, in: enabled) }
                artistResults.removeAll { !isEnabledAggregateSource($0.source, in: enabled) }
                albumResults.removeAll { !isEnabledAggregateSource($0.source, in: enabled) }
                filterOverviewSnapshot(enabledProviders: enabled)
                Task { await loadAllHotWords() }
                let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    invalidateSearchPipeline()
                    searching = true
                    scheduleScopeRefresh(trimmed)
                }
            } else {
                Task { await loadAllHotWords() }
            }
        }
        .sheet(item: $showAddToPlaylist) { song in
            AddToLocalPlaylistSheet(song: song)
                .environmentObject(theme)
        }
        .sheet(item: $selectedArtist) { artist in
            AllSourcesArtistHomeSheet(
                artistName: artist.name,
                initialSongs: songResults.filter { $0.artists.localizedCaseInsensitiveContains(artist.name) }
            )
                .environmentObject(player)
                .environmentObject(theme)
        }
        .sheet(item: $selectedSynologyArtist) { artist in
            ATMusicNavigationStack {
                AllSourcesArtistHomeSheet(artistName: artist.name, initialSongs: synologySearchSongs)
            }
            .environmentObject(player)
            .environmentObject(theme)
        }
        .sheet(item: $selectedSynologyAlbum) { album in
            ATMusicNavigationStack {
                SynologyAlbumView(
                    albumName: album.name,
                    artistName: album.artistName,
                    coverURL: album.coverURL,
                    initialSongs: synologySearchSongs
                )
            }
            .environmentObject(player)
        }
        .sheet(item: $selectedPlaylist) { playlist in
            ATMusicNavigationStack {
                PlaylistView(playlist: playlist)
            }
            .environmentObject(player)
            .environmentObject(auth)
            .environmentObject(theme)
        }
        .sheet(item: $selectedAlbum) { album in
            AlbumDetailView(album: album)
                .environmentObject(player)
                .environmentObject(theme)
        }
    }

    // MARK: - 顶部标题

    private var headerTitle: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(keyword.isEmpty ? "搜索" : keyword)
                .font(ATMusicFont.appFont(keyword.isEmpty ? 32 : 42, .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .foregroundStyle(Color.atmusicLabel)
            Spacer(minLength: 0)
            if isNativeClean {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.atmusicComment.opacity(0.7))
                    .frame(width: 36, height: 36)
                    .background { ATMusicGlass(shape: Circle()) }
                    .clipShape(Circle())
                    .accessibilityLabel("账户")
            }
        }
    }

    // MARK: - 内容区（热搜 / 分类+结果 固定占满剩余高度，切换不引起布局跳动）

    @ViewBuilder
    private var contentArea: some View {
        if keyword.isEmpty {
            // 所有主题沿用 1.8 的搜索首屏层级，避免切换主题后交互变成另一套。
            referenceSearchLanding
        } else {
            VStack(spacing: 0) {
                providerPicker
                typeTabs
                resultsArea
            }
        }
    }

    // MARK: - 搜索框（液态玻璃胶囊）

    private var searchField: some View {
        // 音源选择统一置于结果区，输入框保持 1.8 的简洁层级。
        referenceSearchField
    }

    private var standardSearchField: some View {
        HStack(spacing: 10) {
            searchScopeMenu
            // UIKit 输入框：回车/点搜索时先 unmarkText 强制提交拼音，再读取最新文本，
            // 根治 SwiftUI TextField 在中文组字中 onSubmit 后输入消失、搜索无结果的问题
            SearchTextField(
                text: $keyword,
                controller: searchController,
                placeholder: atmusicLocalized("搜索歌曲、歌手、专辑", "Search songs, artists, or albums"),
                textColor: UIColor.atmusicLabel,
                onSubmit: { text in
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    runImmediateSearch(trimmed, updateKeyword: true)
                }
            )
            .frame(height: 32)
            .frame(maxWidth: .infinity)
            ZStack {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.atmusicAmber)
                    .opacity(searching ? 1 : 0)
            }
            .frame(width: 20, height: 22)
            .animation(nil, value: searching)
            ZStack {
                Button {
                    keyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.atmusicComment.opacity(0.85))
                }
                .buttonStyle(.plain)
                .opacity(keyword.isEmpty ? 0 : 1)
                .disabled(keyword.isEmpty)
            }
            .frame(width: 20, height: 22)
            Button {
                // 先提交拼音再读取，避免组字中读到旧值或输入被清空
                let text = searchController.commit()
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                runImmediateSearch(trimmed, updateKeyword: true)
            } label: {
            Text(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "搜索" : keyword)
                    .font(ATMusicFont.appFont(13, .semibold))
                    .foregroundStyle(Color.atmusicAmber)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .background { ATMusicGlass(shape: Capsule()) }
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.9))
            .frame(width: 54, height: 30)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 6)
        .background {
            ATMusicGlass(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .atmusicCardShadow(radius: 4, y: 2)
        .frame(maxWidth: .infinity)
    }

    /// 复刻 1.8.1 的简洁搜索框：视觉上只保留放大镜和输入区；聚合/单平台
    /// 选择仍可由放大镜按钮打开，因此 NAS 与多平台能力不会消失。
    private var referenceSearchField: some View {
        HStack(spacing: 10) {
            Menu {
                Button {
                    aggregateSearch = true
                    ATMusicHaptics.tap()
                } label: {
                    Label("聚合搜索", systemImage: aggregateSearch ? "checkmark" : "square.stack.3d.up.fill")
                }
                Divider()
                ForEach(searchProviders) { source in
                    Button {
                        aggregateSearch = false
                        provider = source
                        ATMusicHaptics.tap()
                    } label: {
                        Label(source.rawValue, systemImage: !aggregateSearch && provider == source ? "checkmark" : source.icon)
                    }
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.atmusicComment)
                    .frame(width: 25, height: 32)
            }
            .menuStyle(.borderlessButton)

            SearchTextField(
                text: $keyword,
                controller: searchController,
                placeholder: atmusicLocalized("搜索歌曲、歌手、专辑", "Search songs, artists, or albums"),
                textColor: UIColor.atmusicLabel,
                onSubmit: { text in
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    runImmediateSearch(trimmed, updateKeyword: true)
                }
            )
            .frame(height: 34)

            if searching {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20)
            } else if !keyword.isEmpty {
                Button {
                    keyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.atmusicComment.opacity(0.78))
                }
                .buttonStyle(.plain)
                .frame(width: 20)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background { ATMusicSurface(shape: Capsule()) }
        .overlay { Capsule().strokeBorder(Color.atmusicComment.opacity(0.16), lineWidth: 0.7) }
        .clipShape(Capsule())
        .frame(maxWidth: .infinity)
    }

    /// 搜索框左侧音源切换：默认全网聚合，也可直接锁定单个平台。
    private var searchScopeMenu: some View {
        Menu {
            Button {
                ATMusicHaptics.tap()
                aggregateSearch = true
            } label: {
                Label("聚合", systemImage: aggregateSearch ? "checkmark" : "square.stack.3d.up.fill")
            }

            Divider()

            ForEach(searchProviders) { source in
                Button {
                    ATMusicHaptics.tap()
                    aggregateSearch = false
                    if source != provider {
                        provider = source
                    }
                } label: {
                    Label(source.rawValue, systemImage: !aggregateSearch && source == provider ? "checkmark" : source.icon)
                }
            }
        } label: {
            HStack(spacing: 4) {
                if aggregateSearch {
                    Image(systemName: "square.stack.3d.up.fill")
                } else if let imageName = provider.brandImageName {
                    Image(imageName)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: provider.icon)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(aggregateSearch ? AnyShapeStyle(Color.atmusicAmber) : AnyShapeStyle(provider.tint))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(aggregateSearch ? "全网搜索" : "\(provider.rawValue)搜索")
    }

    // MARK: - 平台选择（1.8 搜索平台胶囊）

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("搜索平台")
                    .font(ATMusicFont.appFont(15, .medium))
                    .foregroundStyle(Color.atmusicComment)
                Spacer(minLength: 0)
                Text(aggregateSearch ? "聚合" : provider.rawValue)
                    .font(ATMusicFont.appFont(15, .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    searchPlatformPill(title: "聚合", systemImage: "checkmark", selected: aggregateSearch) {
                        aggregateSearch = true
                        aggregateOverview = true
                        ATMusicHaptics.tap()
                    }
                    ForEach(searchProviders) { item in
                        searchPlatformPill(
                            title: item.rawValue,
                            systemImage: item.brandImageName == nil ? item.icon : nil,
                            selected: !aggregateSearch && provider == item
                        ) {
                            ATMusicHaptics.tap()
                            // 搜索平台是单选：要么全网聚合，要么锁定一个平台。
                            // 不再在聚合页内增减平台，避免一次点按触发多轮并发请求。
                            if aggregateSearch || provider != item {
                                aggregateSearch = false
                                provider = item
                            }
                        }
                    }
                }
                .padding(.horizontal, 1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private func searchPlatformPill(title: String, systemImage: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if title == "聚合" {
                    Image(systemName: selected ? "checkmark" : "square.stack.3d.up.fill")
                        .font(.system(size: 13, weight: .bold))
                } else if let imageName = SearchProvider(rawValue: title)?.brandImageName {
                    Image(imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15, height: 15)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(ATMusicFont.appFont(15, .semibold))
            }
            .atmusicSelectionForeground(selected: selected, accent: .atmusicAmber)
            .padding(.horizontal, 18)
            .frame(height: 44)
            .background {
                ATMusicSelectableSurface(selected: selected, shape: Capsule(), accent: .atmusicAmber)
            }
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.95))
    }

    // MARK: - 分类选择（歌曲 / 歌手 / 专辑）

    private var typeTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
            if aggregateSearch {
                Button {
                    ATMusicHaptics.tap()
                    aggregateOverview = true
                } label: {
                    Text("综合")
                        .font(ATMusicFont.appFont(15, .semibold))
                        .atmusicSelectionForeground(selected: aggregateOverview, accent: .atmusicAmber)
                        .padding(.horizontal, 24)
                        .frame(height: 44)
                        .background {
                            ATMusicSelectableSurface(selected: aggregateOverview, shape: Capsule(), accent: .atmusicAmber)
                        }
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.95))
            }
            ForEach(SearchResultType.allCases) { type in
                Button {
                    ATMusicHaptics.tap()
                    let wasOverview = aggregateOverview
                    if aggregateSearch {
                        selectAggregateResultType(type)
                        return
                    }
                    aggregateOverview = false
                    guard resultType != type || wasOverview else { return }
                    resultType = type
                    let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    // 切换分类：清空该分类旧结果并立即进入加载态，避免显示过期数据或空态闪烁
                    invalidateSearchPipeline()
                    switch type {
                    case .song: songResults = []
                    case .artist: artistResults = []
                    case .album: albumResults = []
                    case .playlist: playlistResults = []
                    }
                    errorMessage = nil
                    searching = true
                    runImmediateSearch(trimmed, recordHistory: false)
                } label: {
                    Text(LocalizedStringKey(type.rawValue))
                        .font(ATMusicFont.appFont(15, .semibold))
                        .atmusicSelectionForeground(selected: !aggregateOverview && resultType == type, accent: .atmusicAmber)
                        .padding(.horizontal, 24)
                        .frame(height: 44)
                        .background {
                            ATMusicSelectableSurface(
                                selected: !aggregateOverview && resultType == type,
                                shape: Capsule(),
                                accent: .atmusicAmber
                            )
                        }
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.95))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: - 热搜（排名卡片）

    private var hotSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SearchHistorySection { word in
                    searchController.dismissKeyboard()
                    runImmediateSearch(word, updateKeyword: true)
                }
                ForEach(aggregateSearch ? searchProviders : [provider]) { source in
                    hotProviderSection(source)
                }
                Spacer().frame(height: 130)
            }
            .padding(.horizontal, 20)
        }
        .atmusicScrollIndicatorsHidden()
        .atmusicScrollDismissesKeyboard()
    }

    /// 参考 1.8.1 搜索空态：说明图标、引导文案、双列热门词与历史搜索。
    private var referenceSearchLanding: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 58, weight: .light))
                        .foregroundStyle(Color.atmusicComment.opacity(0.75))
                    Text("搜索歌曲、歌手、专辑或歌单")
                        .font(ATMusicFont.appFont(20, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text("使用搜索框开始，聚合搜索也可以切换到单个平台。")
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicComment)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 76)
                .padding(.bottom, 30)

                HStack {
                    Label("热门搜索", systemImage: "flame.fill")
                        .font(ATMusicFont.appFont(18, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                    Spacer()
                    referenceSearchScopeMenu
                }

                if referenceHotWords.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在汇总各平台热搜…")
                            .font(ATMusicFont.appFont(13))
                            .foregroundStyle(Color.atmusicComment)
                    }
                    .padding(.vertical, 18)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(referenceHotWords, id: \.self) { word in
                            Button {
                                searchController.dismissKeyboard()
                                runImmediateSearch(word, updateKeyword: true)
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                    Text(word)
                                        .font(ATMusicFont.appFont(14, .medium))
                                        .foregroundStyle(Color.atmusicLabel)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 44)
                                .background { ATMusicSurface(shape: Capsule()) }
                                .overlay { Capsule().strokeBorder(Color.atmusicComment.opacity(0.13), lineWidth: 0.7) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 16)
                }

                SearchHistorySection { word in
                    searchController.dismissKeyboard()
                    runImmediateSearch(word, updateKeyword: true)
                }
                .padding(.top, 28)
                Spacer().frame(height: 160)
            }
            .padding(.horizontal, 24)
        }
        .atmusicScrollIndicatorsHidden()
        .atmusicScrollDismissesKeyboard()
    }

    private var referenceSearchScopeMenu: some View {
        Menu {
            Button {
                aggregateSearch = true
                ATMusicHaptics.tap()
            } label: {
                Label("聚合", systemImage: aggregateSearch ? "checkmark" : "square.stack.3d.up.fill")
            }
            Divider()
            ForEach(searchProviders) { source in
                Button {
                    aggregateSearch = false
                    provider = source
                } label: {
                    Label(source.rawValue, systemImage: !aggregateSearch && provider == source ? "checkmark" : source.icon)
                }
            }
        } label: {
            Text(aggregateSearch ? "聚合" : provider.rawValue)
                .font(ATMusicFont.appFont(13, .medium))
                .foregroundStyle(Color.atmusicComment)
        }
        .menuStyle(.borderlessButton)
    }

    @ViewBuilder
    private func hotProviderSection(_ source: SearchProvider) -> some View {
        SectionHeader(title: "\(source.rawValue)热搜")
        if let words = hotWordsByProvider[source], !words.isEmpty {
            if #available(iOS 16, *) {
                FlowLayout(spacing: 10) {
                    ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                        hotTag(index: index, word: word)
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                        hotTag(index: index, word: word)
                    }
                }
            }
        } else if hotLoadingProviders.contains(source) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在加载\(source.rawValue)热搜…")
                    .font(ATMusicFont.appFont(13))
                    .foregroundStyle(Color.atmusicComment)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
        } else {
            Text(source == .synology ? "NAS 没有公共热搜接口，请直接输入关键词搜索本地音乐" : "暂时没有获取到热搜，直接输入关键词即可搜索")
                .font(ATMusicFont.appFont(13))
                .foregroundStyle(Color.atmusicComment)
                .padding(.vertical, 8)
        }
    }

    /// 热搜前三名渐变配色（更亮眼：橙红 / 金黄 / 冰蓝）
    private let hotRankColors: [[Color]] = [
        [Color(red: 1.00, green: 0.62, blue: 0.18), Color(red: 0.95, green: 0.25, blue: 0.18)],
        [Color(red: 1.00, green: 0.82, blue: 0.30), Color(red: 0.98, green: 0.56, blue: 0.12)],
        [Color(red: 0.55, green: 0.85, blue: 1.00), Color(red: 0.30, green: 0.52, blue: 0.98)],
    ]
    private let hotRankIcons = ["crown.fill", "flame.fill", "sparkles"]

    /// 热搜标签：前三名渐变发光圆标（更亮眼），其余为普通序号
    private func hotTag(index: Int, word: String) -> some View {
        let top3 = index < 3
        return Button {
            ATMusicHaptics.tap()
            searchController.dismissKeyboard()
            runImmediateSearch(word, updateKeyword: true)
        } label: {
            HStack(spacing: 7) {
                if top3 {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: hotRankColors[index],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 24, height: 24)
                            .shadow(color: hotRankColors[index][0].opacity(0.6), radius: 6, y: 2)
                            .overlay {
                                Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1)
                            }
                        Image(systemName: hotRankIcons[index])
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                } else {
                    Text("\(index + 1)")
                        .font(ATMusicFont.appFont(11, .bold, .rounded))
                        .foregroundStyle(Color.atmusicComment)
                        .frame(width: 18, height: 18)
                }
                Text(word)
                    .font(ATMusicFont.appFont(top3 ? 15 : 14, top3 ? .bold : .medium))
                    .foregroundStyle(top3 ? Color.atmusicLabel : Color.atmusicComment)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                ATMusicGlass(shape: Capsule())
            }
            .overlay {
                if top3 {
                    Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.8)
                }
            }
        }
        .buttonStyle(GlassPressButtonStyle(scale: 0.92))
    }

    // MARK: - 结果区

    @ViewBuilder
    private var resultsArea: some View {
        if provider == .synology && !aggregateSearch {
            synologySearchResultsArea
        } else if aggregateSearch && aggregateOverview {
            allSearchResultsArea
        } else {
            switch resultType {
            case .song: songResultsArea
            case .artist: artistResultsArea
            case .album: albumResultsArea
            case .playlist: playlistResultsArea
            }
        }
    }

    private var playlistResultsArea: some View {
        Group {
            if let errorMessage, playlistResults.isEmpty {
                ErrorStateView(message: errorMessage) { submitSearch() }
            } else if searching && playlistResults.isEmpty {
                LoadingStateView()
            } else if playlistResults.isEmpty {
                EmptyStateView(icon: "music.note.list", text: "未找到相关歌单")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 22) {
                        ForEach(playlistResults, id: \.identityKey) { playlist in
                            Button {
                                ATMusicHaptics.tap()
                                selectedPlaylist = playlist
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    CoverImage(url: playlist.coverURL, size: 150, cornerRadius: 14)
                                    Text(playlist.name)
                                        .font(ATMusicFont.appFont(15, .medium))
                                        .foregroundStyle(Color.atmusicLabel)
                                        .lineLimit(2)
                                    Text("\(playlist.source.atmusicDisplayName) · \(playlist.trackCount) 首")
                                        .font(ATMusicFont.appFont(12))
                                        .foregroundStyle(Color.atmusicComment)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 180)
                }
                .atmusicScrollIndicatorsHidden()
                .atmusicScrollDismissesKeyboard()
            }
        }
    }

    private func playlistResultRow(_ playlist: Playlist) -> some View {
        HStack(spacing: 12) {
            CoverImage(url: playlist.coverURL, size: 52, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(ATMusicFont.appFont(15, .medium))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(1)
                Text("\(playlist.trackCount) 首")
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
            }
            Spacer()
            SourceBadgeView(source: playlist.source, compact: true)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Color.atmusicComment)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            if !isNativeClean {
                ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    /// 1.8 的聚合结果页：一次搜索同时给出四类结果，按内容分区而不是按音源分组。
    /// 每一行保留来源徽标，点歌手/专辑/歌单仍进入对应详情页。
    private var allSearchResultsArea: some View {
        let hasResults = hasOverviewSnapshot && (!overviewSongs.isEmpty || !overviewArtists.isEmpty || !overviewAlbums.isEmpty || !overviewPlaylists.isEmpty)
        return Group {
            if let errorMessage, !hasResults {
                ErrorStateView(message: errorMessage) { submitSearch() }
            } else if searching && !hasResults {
                LoadingStateView()
            } else if !hasResults {
                EmptyStateView(icon: "magnifyingglass", text: "未找到相关内容")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        aggregateSummary

                        if !overviewSongs.isEmpty {
                            aggregateSongSection
                        }
                        if !overviewArtists.isEmpty {
                            aggregateArtistSection
                        }
                        if !overviewAlbums.isEmpty {
                            aggregateAlbumSection
                        }
                        if !overviewPlaylists.isEmpty {
                            aggregatePlaylistSection
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 180)
                }
                .atmusicScrollIndicatorsHidden()
                .atmusicScrollDismissesKeyboard()
                .overlay(alignment: .top) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.atmusicAmber)
                        .padding(.top, 4)
                        .opacity(searching ? 1 : 0)
                }
            }
        }
    }

    private var aggregateSummary: some View {
        Text("找到 \(overviewResultCount) 项 · \(searchScopeName)")
            .font(ATMusicFont.appFont(14))
            .foregroundStyle(Color.atmusicComment)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 从“综合”进入某个分类时，必须在同一个事务里同时切页面和灌入快照。
    /// 否则 albumResults / playlistResults 仍为空，第一次进入“更多专辑/更多歌单”会显示空页，
    /// 直到用户再切一次分类才被补齐。
    private func selectAggregateResultType(_ type: SearchResultType) {
        aggregateOverview = false
        resultType = type
        guard let snapshot = overviewSnapshot else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            switch type {
            case .song:
                songResults = snapshot.songs
            case .artist:
                artistResults = snapshot.artists
            case .album:
                albumResults = snapshot.albums
            case .playlist:
                playlistResults = snapshot.playlists
            }
        }
    }

    private func aggregateSectionHeader(_ title: String, count: Int, icon: String, type: SearchResultType) -> some View {
        Button {
            ATMusicHaptics.tap()
            selectAggregateResultType(type)
        } label: {
            HStack(spacing: 7) {
                Text(title)
                    .font(ATMusicFont.appFont(28, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.atmusicComment)
                Text("\(count)")
                    .font(ATMusicFont.appFont(13, .medium))
                    .foregroundStyle(Color.atmusicComment)
                Spacer(minLength: 0)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var aggregateArtistSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            aggregateSectionHeader("歌手", count: overviewArtists.count, icon: "person.2.fill", type: .artist)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
                ForEach(Array(overviewArtists.prefix(3)), id: \.identityKey) { artist in
                    Button {
                        ATMusicHaptics.tap()
                        openArtist(artist)
                    } label: {
                        VStack(spacing: 6) {
                            CoverImage(url: artist.coverURL, size: 92, cornerRadius: 46)
                            Text(artist.name)
                                .font(ATMusicFont.appFont(13, .medium))
                                .foregroundStyle(Color.atmusicLabel)
                                .lineLimit(1)
                            Text(artist.source.atmusicDisplayName)
                                .font(ATMusicFont.appFont(11))
                                .foregroundStyle(Color.atmusicComment)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.98))
                }
            }
        }
    }

    private var aggregateAlbumSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            aggregateSectionHeader("专辑", count: overviewAlbums.count, icon: "square.stack.fill", type: .album)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
                ForEach(Array(overviewAlbums.prefix(3)), id: \.identityKey) { album in
                    Button {
                        ATMusicHaptics.tap()
                        openAlbum(album)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            CoverImage(url: album.coverURL, size: 106, cornerRadius: 12)
                            Text(album.name)
                                .font(ATMusicFont.appFont(13, .medium))
                                .foregroundStyle(Color.atmusicLabel)
                                .lineLimit(2)
                            Text(album.artistName.isEmpty ? "未知歌手" : album.artistName)
                                .font(ATMusicFont.appFont(11))
                                .foregroundStyle(Color.atmusicComment)
                                .lineLimit(1)
                            Text(album.source.atmusicDisplayName)
                                .font(ATMusicFont.appFont(11))
                                .foregroundStyle(Color.atmusicComment)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.98))
                }
            }
        }
    }

    private var aggregatePlaylistSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            aggregateSectionHeader("歌单", count: overviewPlaylists.count, icon: "music.note.list", type: .playlist)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
                ForEach(Array(overviewPlaylists.prefix(3)), id: \.identityKey) { playlist in
                    Button {
                        ATMusicHaptics.tap()
                        selectedPlaylist = playlist
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            CoverImage(url: playlist.coverURL, size: 106, cornerRadius: 12)
                            Text(playlist.name)
                                .font(ATMusicFont.appFont(13, .medium))
                                .foregroundStyle(Color.atmusicLabel)
                                .lineLimit(2)
                            Text("\(playlist.source.atmusicDisplayName) · \(playlist.trackCount) 首")
                                .font(ATMusicFont.appFont(11))
                                .foregroundStyle(Color.atmusicComment)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.98))
                }
            }
        }
    }

    private var aggregateSongSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                aggregateSectionHeader("歌曲", count: overviewSongs.count, icon: "music.note", type: .song)
                Button {
                    ATMusicHaptics.tap()
                    player.play(songs: overviewSongs, startAt: 0)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background { ATMusicSurface(shape: Capsule()) }
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
            }
            ForEach(Array(overviewSongs.prefix(6).enumerated()), id: \.element.identityKey) { index, song in
                SongCell(song: song, suppressNativeCleanRowGlass: isNativeClean) {
                    ATMusicHaptics.tap()
                    player.play(songs: overviewSongs, startAt: index)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background {
                    if !isNativeClean {
                        ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var synologySearchResultsArea: some View {
        switch resultType {
        case .song:
            synologySongResultsArea
        case .artist:
            synologyArtistResultsArea
        case .album:
            synologyAlbumResultsArea
        case .playlist:
            synologyPlaylistResultsArea
        }
    }

    private var synologySongResultsArea: some View {
        Group {
            if let errorMessage, songResults.isEmpty {
                ErrorStateView(message: errorMessage) { submitSearch() }
            } else if searching && songResults.isEmpty {
                LoadingStateView()
            } else if songResults.isEmpty {
                EmptyStateView(icon: "music.note", text: "群晖 NAS 未找到相关歌曲")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("歌曲")
                                .font(ATMusicFont.appFont(17, .bold))
                                .foregroundStyle(Color.atmusicLabel)
                            Spacer()
                            Button {
                                ATMusicHaptics.tap()
                                player.play(songs: songResults, startAt: 0)
                            } label: {
                                Label("播放全部", systemImage: "play.fill")
                                    .font(ATMusicFont.appFont(12, .semibold))
                                    .foregroundStyle(Color.atmusicAmber)
                            }
                            .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                        }
                        ForEach(Array(songResults.enumerated()), id: \.element.identityKey) { index, song in
                            SongCell(song: song, suppressNativeCleanRowGlass: isNativeClean) {
                                player.play(songs: songResults, startAt: index)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 180)
                }
                .atmusicScrollIndicatorsHidden()
                .atmusicScrollDismissesKeyboard()
            }
        }
    }

    private var synologyArtistResultsArea: some View {
        Group {
            if let errorMessage, synologyArtistEntries.isEmpty {
                ErrorStateView(message: errorMessage) { submitSearch() }
            } else if searching && synologyArtistEntries.isEmpty {
                LoadingStateView()
            } else if synologyArtistEntries.isEmpty {
                EmptyStateView(icon: "person.crop.circle", text: "群晖 NAS 未找到相关歌手")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        synologyEntrySection(title: "歌手", entries: synologyArtistEntries, icon: "person.crop.circle") { entry in
                            let name = entry.names.first ?? entry.subtitle
                            selectedSynologyArtist = SynologyArtistSelection(id: entry.id, name: name, coverURL: entry.coverURL)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 180)
                }
                .atmusicScrollIndicatorsHidden()
                .atmusicScrollDismissesKeyboard()
            }
        }
    }

    private var synologyAlbumResultsArea: some View {
        Group {
            if let errorMessage, synologyAlbumEntries.isEmpty {
                ErrorStateView(message: errorMessage) { submitSearch() }
            } else if searching && synologyAlbumEntries.isEmpty {
                LoadingStateView()
            } else if synologyAlbumEntries.isEmpty {
                EmptyStateView(icon: "square.stack", text: "群晖 NAS 未找到相关专辑")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        synologyEntrySection(title: "专辑", entries: synologyAlbumEntries, icon: "square.stack") { entry in
                            selectedSynologyAlbum = SynologyAlbumSelection(
                                id: entry.id,
                                name: entry.names.first ?? "未命名专辑",
                                artistName: entry.subtitle,
                                coverURL: entry.coverURL
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 180)
                }
                .atmusicScrollIndicatorsHidden()
                .atmusicScrollDismissesKeyboard()
            }
        }
    }

    private var synologyPlaylistResultsArea: some View {
        playlistResultsArea
    }

    private func synologyEntrySection(title: String, entries: [SynologySearchEntry], icon: String, action: @escaping (SynologySearchEntry) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ATMusicFont.appFont(17, .bold))
                .foregroundStyle(Color.atmusicLabel)
            ForEach(entries) { entry in
                Button { action(entry) } label: {
                    HStack(spacing: 12) {
                        if let coverURL = entry.coverURL {
                            CoverImage(url: coverURL, size: 46, cornerRadius: title == "歌手" ? 23 : 6)
                        } else {
                            Image(systemName: icon)
                                .font(.system(size: 21))
                                .foregroundStyle(Color.atmusicComment)
                                .frame(width: 46, height: 46)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.names.joined(separator: " / "))
                                .font(ATMusicFont.appFont(15, .medium))
                                .foregroundStyle(Color.atmusicLabel)
                                .lineLimit(2)
                            SourceBadgeView(source: .synology, compact: true)
                            if !entry.subtitle.isEmpty {
                                Text(entry.subtitle)
                                    .font(ATMusicFont.appFont(12))
                                    .foregroundStyle(Color.atmusicComment)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(Color.atmusicComment)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var songResultsArea: some View {
        Group {
            if let errorMessage, songResults.isEmpty {
                ErrorStateView(message: errorMessage) { submitSearch() }
            } else if searching && songResults.isEmpty {
                LoadingStateView()
            } else if songResults.isEmpty {
                EmptyStateView(icon: "music.note", text: "\(searchScopeName)未找到相关歌曲")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Text(atmusicLocalized("找到 \(songResults.count) 首 · \(searchScopeName)", aggregateSearch ? "Found \(songResults.count) songs · All sources" : "Found \(songResults.count) songs · \(atmusicPlatformName(provider) )"))
                                .font(ATMusicFont.appFont(12))
                                .foregroundStyle(Color.atmusicComment)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                                .truncationMode(.tail)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                .layoutPriority(1)
                            Button {
                                ATMusicHaptics.tap()
                                player.play(songs: songResults, startAt: 0)
                            } label: {
                                Label("播放全部", systemImage: "play.fill")
                                    .font(ATMusicFont.appFont(12, .semibold))
                                    .foregroundStyle(Color.atmusicAmber)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background { ATMusicSurface(shape: Capsule()) }
                            }
                            .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        ForEach(Array(songResults.enumerated()), id: \.element.identityKey) { index, song in
                            SongCell(song: song, suppressNativeCleanRowGlass: isNativeClean) {
                                ATMusicHaptics.tap()
                                player.play(songs: songResults, startAt: index)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background {
                                ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 180)
                }
                .atmusicScrollIndicatorsHidden()
                .atmusicScrollDismissesKeyboard()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.atmusicAmber)
                        .padding(.top, 10)
                        .opacity(searching && songResults.isEmpty ? 1 : 0)
                }
            }
        }
    }

    private var artistResultsArea: some View {
        Group {
            if let errorMessage, artistResults.isEmpty {
                ErrorStateView(message: errorMessage) { submitSearch() }
            } else if searching && artistResults.isEmpty {
                LoadingStateView()
            } else if artistResults.isEmpty {
                EmptyStateView(icon: "person.crop.circle", text: "\(searchScopeName)未找到相关歌手")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(atmusicLocalized("找到 \(artistResults.count) 位 · \(searchScopeName)", aggregateSearch ? "Found \(artistResults.count) artists · All sources" : "Found \(artistResults.count) artists · \(atmusicPlatformName(provider) )"))
                                .font(ATMusicFont.appFont(12))
                                .foregroundStyle(Color.atmusicComment)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                                .truncationMode(.tail)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                .layoutPriority(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 24) {
                            ForEach(artistResults, id: \.identityKey) { artist in
                                Button {
                                    ATMusicHaptics.tap()
                                    searchController.dismissKeyboard()
                                    openArtist(artist)
                                } label: {
                                    VStack(spacing: 8) {
                                        CoverImage(url: artist.coverURL, size: 136, cornerRadius: 68)
                                        Text(artist.name)
                                            .font(ATMusicFont.appFont(15, .medium))
                                            .foregroundStyle(Color.atmusicLabel)
                                            .lineLimit(1)
                                        SourceBadgeView(source: artist.source, compact: true)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 180)
                }
                .atmusicScrollIndicatorsHidden()
                .atmusicScrollDismissesKeyboard()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.atmusicAmber)
                        .padding(.top, 10)
                        .opacity(searching && artistResults.isEmpty ? 1 : 0)
                }
            }
        }
    }

    private var albumResultsArea: some View {
        Group {
            if let errorMessage, albumResults.isEmpty {
                ErrorStateView(message: errorMessage) { submitSearch() }
            } else if searching && albumResults.isEmpty {
                LoadingStateView()
            } else if albumResults.isEmpty {
                EmptyStateView(icon: "square.stack", text: "\(searchScopeName)未找到相关专辑")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(atmusicLocalized("找到 \(albumResults.count) 张 · \(searchScopeName)", aggregateSearch ? "Found \(albumResults.count) albums · All sources" : "Found \(albumResults.count) albums · \(atmusicPlatformName(provider) )"))
                                .font(ATMusicFont.appFont(12))
                                .foregroundStyle(Color.atmusicComment)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                                .truncationMode(.tail)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                .layoutPriority(1)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 22) {
                            ForEach(albumResults, id: \.identityKey) { album in
                                Button {
                                    ATMusicHaptics.tap()
                                    searchController.dismissKeyboard()
                                    openAlbum(album)
                                } label: {
                                    VStack(alignment: .leading, spacing: 7) {
                                        CoverImage(url: album.coverURL, size: 150, cornerRadius: 14)
                                        Text(album.name)
                                            .font(ATMusicFont.appFont(15, .medium))
                                            .foregroundStyle(Color.atmusicLabel)
                                            .lineLimit(2)
                                        Text(album.artistName.isEmpty ? "未知歌手" : album.artistName)
                                            .font(ATMusicFont.appFont(12))
                                            .foregroundStyle(Color.atmusicComment)
                                            .lineLimit(1)
                                        SourceBadgeView(source: album.source, compact: true)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 180)
                }
                .atmusicScrollIndicatorsHidden()
                .atmusicScrollDismissesKeyboard()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.atmusicAmber)
                        .padding(.top, 10)
                        .opacity(searching && albumResults.isEmpty ? 1 : 0)
                }
            }
        }
    }

    // MARK: - 动作

    private func openAlbum(_ album: Album) {
        ATMusicHaptics.tap()
        searchController.dismissKeyboard()
        if album.source == .synology {
            let searchSongs = songResults.filter { $0.source == .synology }
            selectedSynologyAlbum = SynologyAlbumSelection(
                id: album.id,
                name: album.name,
                artistName: album.artistName,
                coverURL: album.coverURL
            )
            // NAS 搜索结果先作为详情页首屏候选，完整目录随后由详情页补齐。
            synologySearchSongs = searchSongs
        } else {
            selectedAlbum = album
        }
    }

    private func openArtist(_ artist: Artist) {
        ATMusicHaptics.tap()
        searchController.dismissKeyboard()
        if artist.source == .synology {
            synologySearchSongs = songResults.filter { $0.source == .synology }
            selectedSynologyArtist = SynologyArtistSelection(
                id: artist.id,
                name: artist.name,
                coverURL: artist.coverURL
            )
        } else {
            selectedArtist = artist
        }
    }

    /// 重新搜索（错误重试按钮调用：读取当前输入框文本）
    private func submitSearch() {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        runImmediateSearch(trimmed)
    }

    /// 点击歌手 / 专辑：以其名称搜索歌曲
    private func searchBy(_ name: String) {
        ATMusicHaptics.tap()
        searchController.dismissKeyboard()
        resultType = .song
        runImmediateSearch(name, updateKeyword: true)
    }

    /// 并发加载各平台热搜。NAS 没有公共热搜接口，直接标记为不可用，不能把空数组当成“还在加载”。
    private func loadAllHotWords() async {
        hotWordsGeneration &+= 1
        let generation = hotWordsGeneration
        let providers = aggregateSearch ? searchProviders : [provider]
        hotLoadingProviders = Set(providers.filter { $0 != .synology })
        hotUnavailableProviders = Set(providers.filter { $0 == .synology })
        hotWordsByProvider = hotWordsByProvider.filter { providers.contains($0.key) }

        for source in providers where source != .synology {
            Task {
                let words: [String]?
                switch source {
                case .netease:
                    words = try? await NetEaseAPI.shared.hotSearch()
                case .qq:
                    words = try? await QQMusicAPI.shared.hotKeys()
                case .kugou:
                    let values = await KugouMusicAPI.shared.hotWords()
                    words = values.isEmpty ? nil : values
                case .synology:
                    words = nil
                }
                await MainActor.run {
                    guard hotWordsGeneration == generation else { return }
                    hotLoadingProviders.remove(source)
                    if let words, !words.isEmpty {
                        hotWordsByProvider[source] = Array(words.prefix(20))
                        hotUnavailableProviders.remove(source)
                    } else {
                        hotUnavailableProviders.insert(source)
                    }
                }
            }
        }
    }

    private func makeSynologyArtistEntries(_ artists: [Artist], songs: [Song]) -> [SynologySearchEntry] {
        var entries: [SynologySearchEntry] = []
        var indexes: [String: Int] = [:]
        for artist in artists {
            let key = synologyCanonicalName(artist.name)
            guard !key.isEmpty else { continue }
            if let index = indexes[key] {
                if !entries[index].names.contains(artist.name) {
                    entries[index] = SynologySearchEntry(id: entries[index].id, names: entries[index].names + [artist.name], subtitle: entries[index].subtitle, coverURL: entries[index].coverURL)
                }
            } else {
                let cover = artist.coverURL ?? songs.first(where: { $0.artists.localizedCaseInsensitiveContains(artist.name) })?.coverURL
                let names = synologyAliases(for: key, existing: [artist.name])
                indexes[key] = entries.count
                entries.append(SynologySearchEntry(id: "artist-\(key)", names: names, subtitle: "群晖音乐库歌手", coverURL: cover))
            }
        }
        return entries
    }

    private func makeSynologyAlbumEntries(_ albums: [Album], songs: [Song]) -> [SynologySearchEntry] {
        var entries: [SynologySearchEntry] = []
        var indexes: [String: Int] = [:]
        for album in albums {
            let key = synologyCanonicalName(album.name + "|" + album.artistName)
            guard !key.isEmpty else { continue }
            let cover = album.coverURL ?? songs.first(where: { $0.album == album.name })?.coverURL
            if let index = indexes[key] {
                if !entries[index].names.contains(album.name) {
                    entries[index] = SynologySearchEntry(id: entries[index].id, names: entries[index].names + [album.name], subtitle: entries[index].subtitle, coverURL: entries[index].coverURL ?? cover)
                }
            } else {
                indexes[key] = entries.count
                entries.append(SynologySearchEntry(id: "album-\(key)", names: [album.name], subtitle: album.artistName, coverURL: cover))
            }
        }
        return entries
    }

    private func synologyCanonicalName(_ value: String) -> String {
        let simplified = value.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? value
        return simplified
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private func synologyAliases(for key: String, existing: [String]) -> [String] {
        return existing
    }

    private func fetchAllSearchResults(provider: SearchProvider, keyword: String) async throws -> (songs: [Song], artists: [Artist], albums: [Album]) {
        switch provider {
        case .netease:
            async let songs = NetEaseAPI.shared.search(keyword: keyword, limit: 40)
            async let artists = NetEaseAPI.shared.searchArtists(keyword: keyword)
            async let albums = NetEaseAPI.shared.searchAlbums(keyword: keyword)
            return try await (songs, artists, albums)
        case .qq:
            async let songs = QQMusicAPI.shared.searchSongs(keyword: keyword)
            async let artists = QQMusicAPI.shared.searchArtists(keyword: keyword)
            async let albums = QQMusicAPI.shared.searchAlbums(keyword: keyword)
            return try await (songs, artists, albums)
        case .kugou:
            async let songs = KugouMusicAPI.shared.searchSongs(keyword: keyword, limit: 40)
            async let artists = KugouMusicAPI.shared.searchArtists(keyword: keyword)
            async let albums = KugouMusicAPI.shared.searchAlbums(keyword: keyword)
            return try await (songs, artists, albums)
        case .synology:
            let result = try await SynologyAPI.shared.searchAllVariants(keyword: keyword, limit: 200)
            return (result.songs, result.artists, result.albums)
        }
    }

    /// 搜索页只请求当前选中的分类。之前每次输入都会同时请求歌曲、歌手、专辑三套接口，
    /// 结果页实际上只显示其中一类，造成了明显的网络和 UI 重建开销。
    private func fetchSelectedSearchResult(provider: SearchProvider, type: SearchResultType, keyword: String) async throws -> (songs: [Song], artists: [Artist], albums: [Album]) {
        switch (provider, type) {
        case (.netease, .song):
            return (try await NetEaseAPI.shared.search(keyword: keyword, limit: 40), [], [])
        case (.netease, .artist):
            return ([], try await NetEaseAPI.shared.searchArtists(keyword: keyword), [])
        case (.netease, .album):
            return ([], [], try await NetEaseAPI.shared.searchAlbums(keyword: keyword))
        case (.qq, .song):
            return (try await QQMusicAPI.shared.searchSongs(keyword: keyword), [], [])
        case (.qq, .artist):
            return ([], try await QQMusicAPI.shared.searchArtists(keyword: keyword), [])
        case (.qq, .album):
            return ([], [], try await QQMusicAPI.shared.searchAlbums(keyword: keyword))
        case (.kugou, .song):
            return (try await KugouMusicAPI.shared.searchSongs(keyword: keyword, limit: 40), [], [])
        case (.kugou, .artist):
            return ([], try await KugouMusicAPI.shared.searchArtists(keyword: keyword), [])
        case (.kugou, .album):
            return ([], [], try await KugouMusicAPI.shared.searchAlbums(keyword: keyword))
        case (.synology, _), (_, .playlist):
            return ([], [], [])
        }
    }

    private func startSearch(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 所有搜索结果必须对应当前可见输入；延迟 NAS/旧 UI 任务不能反向覆盖新关键词。
        guard keyword.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
        let selectedProvider = provider
        let selectedType = resultType
        let selectedAggregate = aggregateSearch
        let selectedProviders = selectedAggregate ? searchProviders : [selectedProvider]
        let providerKey = selectedProviders.map(\.rawValue).joined(separator: ",")
        let requestKey = "\(trimmed.lowercased())|\(selectedAggregate)|\(providerKey)|\(selectedType.rawValue)"
        // 同一请求仍在执行时直接合并。真机日志曾显示同一关键词在一秒内被
        // 索引通知等事件触发 3～4 次，这是综合结果反复闪烁的直接原因。
        guard activeSearchKey != requestKey else {
            ATMusicLogger.shared.log("合并重复搜索：\(requestKey)", level: .debug)
            return
        }
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        activeSearchKey = requestKey
        searchTask = Task {
            await MainActor.run {
                searching = true
                errorMessage = nil
            }
            ATMusicLogger.shared.log("搜索：\(selectedProvider.rawValue) [\(selectedType.rawValue)] \(trimmed)", level: .info)
            defer {
                Task { @MainActor in
                    guard searchGeneration == generation else { return }
                    if activeSearchKey == requestKey { activeSearchKey = nil }
                    if !Task.isCancelled { searching = false }
                }
            }
            if selectedAggregate {
                let localPlaylists = await MainActor.run {
                    auth.playlists.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
                }
                let aggregate = await AggregatedSearchService.shared.searchStreaming(keyword: trimmed, providers: selectedProviders) { partial in
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard aggregateSearch, searchGeneration == generation else { return }
                        // 综合页等待全部平台结束后一次性提交结果。多平台中途回包只在
                        // 用户已进入某个分类时更新，防止综合页不断重排、玻璃层反复重建。
                        if !aggregateOverview {
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                switch resultType {
                                case .song:
                                    songResults = stableAppend(
                                        current: songResults,
                                        incoming: partial.songs,
                                        identity: { $0.identityKey }
                                    )
                                case .artist:
                                    artistResults = stableAppend(
                                        current: artistResults,
                                        incoming: partial.artists,
                                        identity: { "\($0.source.rawValue)|\($0.id)" }
                                    )
                                case .album:
                                    albumResults = stableAppend(
                                        current: albumResults,
                                        incoming: partial.albums,
                                        identity: { "\($0.source.rawValue)|\($0.id)" }
                                    )
                                case .playlist:
                                    playlistResults = stableAppend(
                                        current: playlistResults,
                                        incoming: localPlaylists + partial.playlists,
                                        identity: { $0.identityKey }
                                    )
                                }
                            }
                        }
                        // 已有任一音源返回结果时，先清除“全部音源失败”的错误状态。
                        if errorMessage != nil,
                           (!partial.songs.isEmpty || !partial.artists.isEmpty || !partial.albums.isEmpty || !partial.playlists.isEmpty) {
                            errorMessage = nil
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard aggregateSearch, searchGeneration == generation else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        // 综合页只提交一个完整快照，避免四组结果的连续写入
                        // 让整页在一帧内反复拆除/重建。若用户此时已进入分类，
                        // 只更新当前可见的那一组结果。
                        if !aggregateOverview {
                            switch resultType {
                            case .song: songResults = aggregate.songs
                            case .artist: artistResults = aggregate.artists
                            case .album: albumResults = aggregate.albums
                            case .playlist: playlistResults = localPlaylists + aggregate.playlists
                            }
                        }
                        captureOverviewSnapshot(from: aggregate, localPlaylists: localPlaylists)
                    }
                    errorMessage = aggregate.songs.isEmpty && aggregate.artists.isEmpty && aggregate.albums.isEmpty && aggregate.playlists.isEmpty && !aggregate.failedProviders.isEmpty
                        ? "当前音源暂时不可用，请稍后重试" : nil
                    if !aggregate.songs.isEmpty { ATMusicHaptics.success() }
                }
                ATMusicLogger.shared.log("聚合搜索完成：\(trimmed) 音源=\(selectedProviders.count) 歌曲\(aggregate.songs.count)/歌手\(aggregate.artists.count)/专辑\(aggregate.albums.count)/歌单\(aggregate.playlists.count)", level: .info)
                return
            }
            if selectedType == .playlist, selectedProvider != .synology {
                let remote: [Playlist]
                switch selectedProvider {
                case .netease:
                    remote = (try? await NetEaseAPI.shared.searchPlaylists(keyword: trimmed, limit: 40)) ?? []
                case .qq:
                    remote = (try? await QQMusicAPI.shared.searchPlaylists(keyword: trimmed, limit: 40)) ?? []
                case .kugou:
                    remote = (try? await KugouMusicAPI.shared.searchPlaylists(keyword: trimmed, limit: 40)) ?? []
                case .synology:
                    remote = []
                }
                let local = await MainActor.run {
                    auth.playlists.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard provider == selectedProvider, resultType == selectedType else { return }
                    playlistResults = local + remote
                }
                return
            }
            if selectedProvider != .synology {
                do {
                    let result = try await fetchSelectedSearchResult(provider: selectedProvider, type: selectedType, keyword: trimmed)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider else { return }
                        songResults = result.songs
                        artistResults = result.artists
                        albumResults = result.albums
                        errorMessage = nil
                    }
                    ATMusicLogger.shared.log("搜索完成：\(selectedProvider.rawValue) 全部分类 \(trimmed) 结果=歌曲\(result.songs.count)/歌手\(result.artists.count)/专辑\(result.albums.count)", level: .info)
                } catch {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider else { return }
                        errorMessage = error.localizedDescription
                    }
                }
                return
            }
            do {
                switch (selectedProvider, selectedType) {
                case (.netease, .song):
                    let songs = try await NetEaseAPI.shared.search(keyword: trimmed, limit: 40)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider, resultType == selectedType else { return }
                        songResults = songs
                        if !songs.isEmpty { ATMusicHaptics.success() }
                    }
                case (.netease, .artist):
                    let artists = try await NetEaseAPI.shared.searchArtists(keyword: trimmed)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider, resultType == selectedType else { return }
                        artistResults = artists
                    }
                case (.netease, .album):
                    let albums = try await NetEaseAPI.shared.searchAlbums(keyword: trimmed)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider, resultType == selectedType else { return }
                        albumResults = albums
                    }
                case (.qq, .song):
                    let songs = try await QQMusicAPI.shared.searchSongs(keyword: trimmed)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider, resultType == selectedType else { return }
                        songResults = songs
                        if !songs.isEmpty { ATMusicHaptics.success() }
                    }
                case (.qq, .artist):
                    let artists = try await QQMusicAPI.shared.searchArtists(keyword: trimmed)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider, resultType == selectedType else { return }
                        artistResults = artists
                    }
                case (.qq, .album):
                    let albums = try await QQMusicAPI.shared.searchAlbums(keyword: trimmed)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider, resultType == selectedType else { return }
                        albumResults = albums
                    }
                case (.kugou, .song):
                    let songs = try await KugouMusicAPI.shared.searchSongs(keyword: trimmed, limit: 40)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider, resultType == selectedType else { return }
                        songResults = songs
                        if !songs.isEmpty { ATMusicHaptics.success() }
                    }
                case (.kugou, .artist):
                    let artists = try await KugouMusicAPI.shared.searchArtists(keyword: trimmed)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider, resultType == selectedType else { return }
                        artistResults = artists
                    }
                case (.kugou, .album):
                    let albums = try await KugouMusicAPI.shared.searchAlbums(keyword: trimmed)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider, resultType == selectedType else { return }
                        albumResults = albums
                    }
                case (.synology, .song), (.synology, .artist), (.synology, .album):
                    let result = try await SynologyAPI.shared.searchAllVariants(keyword: trimmed, limit: 200)
                    let songs = result.songs
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider, resultType == selectedType else { return }
                        songResults = songs
                        synologySearchSongs = songs
                        synologyArtistEntries = makeSynologyArtistEntries(result.artists, songs: songs)
                        synologyAlbumEntries = makeSynologyAlbumEntries(result.albums, songs: songs)
                        if !songs.isEmpty { ATMusicHaptics.success() }
                    }
                case (.synology, .playlist):
                    let playlists = try await SynologyAPI.shared.allPlaylists()
                    let matches = playlists.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard provider == selectedProvider, resultType == selectedType else { return }
                        playlistResults = matches
                    }
                case (.netease, .playlist), (.qq, .playlist), (.kugou, .playlist):
                    break
                }
                let count = await MainActor.run {
                    switch selectedType {
                    case .song: return songResults.count
                    case .artist: return selectedProvider == .synology ? synologyArtistEntries.count : artistResults.count
                    case .album: return selectedProvider == .synology ? synologyAlbumEntries.count : albumResults.count
                    case .playlist: return playlistResults.count
                    }
                }
                ATMusicLogger.shared.log("搜索完成：\(selectedProvider.rawValue) [\(selectedType.rawValue)] \(trimmed) 结果=\(count)", level: .info)
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard provider == selectedProvider else { return }
                    errorMessage = error.localizedDescription
                }
                ATMusicLogger.shared.log("搜索失败：\(selectedProvider.rawValue) \(trimmed) - \(error.localizedDescription)", level: .error)
            }
        }
        await searchTask?.value
    }
}

/// 专辑详情页：点击搜索结果直接进入专辑内容，不再把专辑名当作歌曲关键词重新搜索。
struct AlbumDetailView: View {
    let album: Album
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @State private var tracks: [Song] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showArtistHome = false

    var body: some View {
        ATMusicNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                if isLoading {
                    LoadingStateView()
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) { Task { await load() } }
                } else {
                    List {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 14) {
                                CoverImage(url: album.coverURL, size: 92, cornerRadius: 16)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(album.name)
                                        .font(ATMusicFont.appFont(19, .bold))
                                        .foregroundStyle(Color.atmusicLabel)
                                        .lineLimit(2)
                                    Button {
                                        guard !album.artistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                                        ATMusicHaptics.tap()
                                        showArtistHome = true
                                    } label: {
                                        HStack(spacing: 4) {
                                            Text(album.artistName.isEmpty ? "未知歌手" : album.artistName)
                                            if !album.artistName.isEmpty {
                                                Image(systemName: "chevron.right")
                                                    .font(.system(size: 9, weight: .bold))
                                            }
                                        }
                                        .font(ATMusicFont.appFont(13))
                                        .foregroundStyle(album.artistName.isEmpty ? Color.atmusicComment : Color.atmusicAmber)
                                    }
                                    .buttonStyle(.plain)
                                    Text(atmusicSongCountText(tracks.count))
                                        .font(ATMusicFont.appFont(12))
                                        .foregroundStyle(Color.atmusicComment)
                                }
                                Spacer(minLength: 0)
                            }
                            if !tracks.isEmpty {
                                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                    player.play(songs: tracks, startAt: 0)
                                }
                            }
                        }
                        .padding(.vertical, 10)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                        ForEach(Array(tracks.enumerated()), id: \.element.identityKey) { index, song in
                            SongCell(song: song, glassRow: true, playbackContext: tracks, playbackIndex: index) {
                                player.play(songs: tracks, startAt: index)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .atmusicScrollContentBackgroundHidden()
                }
            }
            .navigationTitle(album.name)
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await load() }
        .sheet(isPresented: $showArtistHome) {
            ArtistHomeSheet(artistName: album.artistName, artistSource: album.source)
                .environmentObject(player)
                .environmentObject(theme)
        }
    }

    private func load() async {
        let cache = DetailSongsCache.shared
        let cacheKey = "album-\(album.source.rawValue)-\(album.id)"
        if let cached = cache.cachedSongs(for: cacheKey) {
            await MainActor.run {
                tracks = cached.songs
                isLoading = false
                errorMessage = nil
            }
            if cache.isFresh(cached) {
                return
            }
        }
        await MainActor.run {
            if tracks.isEmpty {
                isLoading = true
            }
            errorMessage = nil
        }
        let result: [Song]
            switch album.source {
            case .netease:
                let id = Int(album.id.replacingOccurrences(of: "netease-", with: ""))
                let direct: [Song]
                if let id {
                    direct = (try? await NetEaseAPI.shared.albumSongs(albumID: id)) ?? []
                } else {
                    direct = []
                }
                if !direct.isEmpty {
                    result = direct
                } else {
                    result = await searchFallbackSongs(
                        queries: [albumSearchQuery, album.name],
                        search: { query in
                            (try? await NetEaseAPI.shared.search(keyword: query, limit: 100)) ?? []
                        }
                    )
                }
            case .qq:
                result = await searchFallbackSongs(
                    queries: [albumSearchQuery, album.name],
                    search: { query in
                        (try? await QQMusicAPI.shared.searchSongs(keyword: query, limit: 100)) ?? []
                    }
                )
            case .kugou:
                result = await searchFallbackSongs(
                    queries: [albumSearchQuery, album.name],
                    search: { query in
                        (try? await KugouMusicAPI.shared.searchSongs(keyword: query, limit: 100)) ?? []
                    }
                )
            case .local:
                result = LocalLibraryStore.shared.importedSongs.filter {
                    $0.album.localizedCaseInsensitiveContains(album.name)
                        && $0.artists.localizedCaseInsensitiveContains(album.artistName)
                }
            case .synology:
                result = []
            }
            if !result.isEmpty {
                cache.save(result, for: cacheKey)
            }
            await MainActor.run {
                tracks = result
                isLoading = false
                if result.isEmpty { errorMessage = "未找到专辑歌曲" }
            }
    }

    private var albumSearchQuery: String {
        let artist = album.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        return artist.isEmpty ? album.name : "\(artist) \(album.name)"
    }

    private func searchFallbackSongs(
        queries: [String],
        search: (String) async -> [Song]
    ) async -> [Song] {
        guard !album.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ATMusicLogger.shared.log(
                "专辑详情筛选跳过：缺少专辑名，平台=\(album.source.rawValue)",
                level: .debug
            )
            return []
        }
        var tried = Set<String>()
        var albumOnlyCandidates: [Song] = []
        for query in queries {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, tried.insert(trimmed).inserted else { continue }
            let songs = await search(trimmed)
            let matches = songs.filter(albumSongMatches)
            let albumOnlyMatches = songs.filter { albumNamesMatch($0.album, album.name) }
            ATMusicLogger.shared.log(
                "专辑详情筛选：平台=\(album.source.rawValue) 查询=\(trimmed) 原始=\(songs.count) 专辑歌手匹配=\(matches.count) 专辑名匹配=\(albumOnlyMatches.count)",
                level: .debug
            )
            if !matches.isEmpty {
                var seen = Set<String>()
                return matches.filter { seen.insert($0.identityKey).inserted }
            }
            // QQ / 酷狗等搜索记录中的歌手名偶尔会附带别名、制作人或为空。
            // 已确认专辑名命中时宁可退化为“同专辑名”结果，也不能把详情页显示成空白。
            albumOnlyCandidates.append(contentsOf: albumOnlyMatches)
        }
        var seen = Set<String>()
        let fallback = albumOnlyCandidates.filter { seen.insert($0.identityKey).inserted }
        if !fallback.isEmpty {
            ATMusicLogger.shared.log(
                "专辑详情采用专辑名回退：平台=\(album.source.rawValue) 专辑=\(album.name) 数量=\(fallback.count)",
                level: .info
            )
        }
        return fallback
    }

    private func albumSongMatches(_ song: Song) -> Bool {
        guard albumNamesMatch(song.album, album.name) else { return false }
        // 部分 QQ / 酷狗搜索专辑接口不会返回歌手字段；这时仍可凭专辑名进入，
        // 否则详情页会被过严的过滤条件错误显示为空。
        if normalizedArtist(album.artistName).isEmpty { return true }
        return artistsMatch(expected: album.artistName, actual: song.artists)
    }

    private func normalizedArtist(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: #"[（(].*?[）)]"#, with: "", options: .regularExpression)
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private func artistTokens(_ value: String) -> [String] {
        let separators = CharacterSet(charactersIn: "/／,，、&＆+＋|｜;；")
        return value
            .components(separatedBy: separators)
            .map(normalizedArtist)
            .filter { !$0.isEmpty }
    }

    private func artistsMatch(expected: String, actual: String) -> Bool {
        let expectedTokens = artistTokens(expected)
        let actualTokens = artistTokens(actual)
        guard !expectedTokens.isEmpty, !actualTokens.isEmpty else { return false }

        // A song may add a featured artist, so one exact primary-artist token is
        // sufficient. Prefix matching is limited to longer names to avoid
        // treating an unrelated short name as the same artist.
        return expectedTokens.contains { expectedToken in
            actualTokens.contains { actualToken in
                if expectedToken == actualToken { return true }
                guard min(expectedToken.count, actualToken.count) >= 3 else { return false }
                return expectedToken.hasPrefix(actualToken) || actualToken.hasPrefix(expectedToken)
            }
        }
    }

    private func albumNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
        func normalized(_ value: String) -> String {
            value
                .lowercased()
                .replacingOccurrences(of: "（", with: "(")
                .replacingOccurrences(of: "）", with: ")")
                .replacingOccurrences(of: "[（(].*?[）)]", with: "", options: .regularExpression)
                .filter { !$0.isWhitespace && $0 != "-" && $0 != "·" }
        }
        let a = normalized(lhs)
        let b = normalized(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }
}

// MARK: - 搜索输入框（UIKit 封装：根治中文输入法提交问题）
// SwiftUI TextField 在中文拼音组字中触发 onSubmit 时，binding 可能尚未拿到提交后的文本，
// 且提交瞬间的状态更新可能丢弃未上屏的组字，表现为“输入内容消失、搜索无结果”。
// 改用 UITextField 后：
//  1) 回车/点搜索前先 unmarkText() 强制把拼音提交为汉字，再直接读 field.text（必定最新）；
//  2) 输入内容由 UIKit 持有，SwiftUI 重绘不会清空输入框。

/// 搜索输入框控制器：持有 UITextField 弱引用，供“搜索”按钮与热搜标签操作
final class SearchFieldController {
    weak var textField: UITextField?

    /// 提交拼音组字并返回最新文本，同时收起键盘（点“搜索”按钮调用）
    func commit() -> String {
        guard let field = textField else { return "" }
        if field.markedTextRange != nil {
            field.unmarkText()
        }
        let text = field.text ?? ""
        field.resignFirstResponder()
        return text
    }

    /// 收起键盘（点热搜标签 / 歌手 / 专辑时调用）
    func dismissKeyboard() {
        textField?.resignFirstResponder()
    }
}

struct SearchTextField: UIViewRepresentable {
    @Binding var text: String
    let controller: SearchFieldController
    var placeholder: String = ""
    let textColor: UIColor
    let onSubmit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = NSLocalizedString(placeholder, comment: "")
        field.font = ATMusicFont.appUIFont(15)
        field.textColor = textColor
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.returnKeyType = .search
        field.clearButtonMode = .never
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.text = text
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        controller.textField = field
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        // 同步最新绑定值；同时刷新 coordinator 持有的父视图，保证闭包/绑定始终是最新实例。
        // 关键：中文/日文 IME 组字期间，UITextField 内部的 marked text 才是真实输入状态，
        // SwiftUI 绑定仍停留在上一次已提交文本。此时绝不能反向覆盖 uiView.text，
        // 否则拼音输入到一半会被旧 keyword 清掉。
        context.coordinator.parent = self
        if uiView.markedTextRange == nil, uiView.text != text {
            uiView.text = text
        }
        uiView.font = ATMusicFont.appUIFont(15)
        uiView.textColor = textColor
        uiView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        uiView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SearchTextField

        init(_ parent: SearchTextField) {
            self.parent = parent
        }

        @objc func textChanged(_ field: UITextField) {
            // 中文/日文等输入法组字期间不要把拼音中间态写回 SwiftUI，
            // 否则 400ms debounce 可能对尚未提交的 marked text 发网络请求。
            guard field.markedTextRange == nil else { return }
            let value = field.text ?? ""
            if parent.text != value { parent.text = value }
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            // 输入法回车：先强制提交拼音再读取，确保拿到完整中文文本
            if field.markedTextRange != nil {
                field.unmarkText()
            }
            let text = field.text ?? ""
            parent.onSubmit(text)
            field.resignFirstResponder()
            return true
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            let value = field.text ?? ""
            if parent.text != value { parent.text = value }
        }
    }
}
