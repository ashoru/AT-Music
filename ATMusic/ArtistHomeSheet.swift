import SwiftUI

// MARK: - 歌手主页（点击播放器顶部歌手名跳转：热门歌曲 + 专辑）

struct ArtistHomeSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss
    let artistName: String
    var artistSource: SongSource = .netease
    var artistID: String?

    init(artist: Artist) {
        self.artistName = artist.name
        self.artistSource = artist.source
        self.artistID = artist.id
        _artist = State(initialValue: artist)
    }

    init(artistName: String, artistSource: SongSource = .netease) {
        self.artistName = artistName
        self.artistSource = artistSource
        self.artistID = nil
        _artist = State(initialValue: nil)
    }

    @State private var artist: Artist?
    @State private var hotSongs: [Song] = []
    @State private var albums: [Album] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var selectedSection: ArtistHomeSection = .songs

    private enum ArtistHomeSection: String, CaseIterable, Identifiable {
        case songs = "歌曲"
        case albums = "专辑"

        var id: String { rawValue }
    }

    var body: some View {
        ATMusicNavigationStack {
            ZStack {
                // 歌手页沿用主页壁纸，不受“同步到全部页面”开关影响。
                GlassBackdrop(customColor: theme.customBackground, homeMode: true)
                Group {
                    if loading {
                        LoadingStateView()
                    } else if let errorMessage {
                        ErrorStateView(message: errorMessage) {
                            Task { await load() }
                        }
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                artistHeader
                                Picker("歌手内容", selection: $selectedSection) {
                                    ForEach(ArtistHomeSection.allCases) { section in
                                        Text(section.rawValue).tag(section)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .padding(.horizontal, 16)

                                if selectedSection == .songs {
                                    hotSongsSection
                                } else {
                                    albumsSection
                                }
                            }
                            .padding(.top, 6)
                            .padding(.bottom, 16)
                        }
                        .atmusicScrollIndicatorsHidden()
                    }
                }
            }
            .navigationTitle("歌手主页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task { await load() }
        .modifier(ATMusicSheetModifier(detents: [.large], dragIndicator: true))
    }

    private var artistHeader: some View {
        HStack(spacing: 14) {
            AsyncImage(url: artist?.coverURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.atmusicComment)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(Circle())
            .background(Color.atmusicGlassFill, in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(artist?.name ?? artistName)
                    .font(ATMusicFont.appFont(20, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Text(atmusicLocalized("歌曲 \(hotSongs.count) 首 · 专辑 \(albums.count) 张", "Songs: \(hotSongs.count) · Albums: \(albums.count)"))
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var hotSongsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("热门歌曲")
                .font(ATMusicFont.appFont(17, .bold))
                .foregroundStyle(Color.atmusicLabel)
                .padding(.horizontal, 16)
            if !hotSongs.isEmpty {
                HStack(spacing: 10) {
                    Button {
                        ATMusicHaptics.tap()
                        player.play(songs: displayedHotSongs, startAt: 0)
                        dismiss()
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                            .font(ATMusicFont.appFont(13, .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(Color.atmusicAmber))
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                    Button {
                        ATMusicHaptics.tap()
                        player.play(songs: displayedHotSongs.shuffled(), startAt: 0)
                        dismiss()
                    } label: {
                        Label("随机播放", systemImage: "shuffle")
                            .font(ATMusicFont.appFont(13, .semibold))
                            .foregroundStyle(Color.atmusicAmber)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Capsule().strokeBorder(Color.atmusicAmber.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
            }
            if !hotSongs.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.atmusicComment)
                    TextField(atmusicLocalized("搜索歌手歌曲", "Search artist songs"), text: $searchText)
                        .font(ATMusicFont.appFont(14))
                        .autocorrectionDisabled()
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.atmusicComment)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)) }
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
            }
            if hotSongs.isEmpty {
                Text("暂无歌曲")
                    .font(ATMusicFont.appFont(13))
                    .foregroundStyle(Color.atmusicComment)
                    .padding(.horizontal, 16)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(displayedHotSongs.enumerated()), id: \.element.identityKey) { index, song in
                        Button {
                            ATMusicHaptics.tap()
                            player.play(songs: displayedHotSongs, startAt: index)
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(ATMusicFont.appFont(13, .semibold, .rounded))
                                    .foregroundStyle(index < 3 ? Color.atmusicAmber : Color.atmusicComment)
                                    .frame(width: 22)
                                CoverImage(url: song.coverURL, size: 40, cornerRadius: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.name)
                                        .font(ATMusicFont.appFont(14, .medium))
                                        .foregroundStyle(Color.atmusicLabel)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                    Text(song.album)
                                        .font(ATMusicFont.appFont(11))
                                        .foregroundStyle(Color.atmusicComment)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                player.playNext(song)
                            } label: {
                                Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                            Button {
                                player.play(songs: displayedHotSongs, startAt: index)
                            } label: {
                                Label("立即播放", systemImage: "play.fill")
                            }
                        }
                    }
                }
            }
        }
    }

    private var displayedHotSongs: [Song] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return hotSongs }
        return hotSongs.filter { song in
            song.name.lowercased().contains(kw)
                || song.artists.lowercased().contains(kw)
                || song.album.lowercased().contains(kw)
        }
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("专辑")
                .font(ATMusicFont.appFont(17, .bold))
                .foregroundStyle(Color.atmusicLabel)
                .padding(.horizontal, 16)
            if albums.isEmpty {
                Text("暂无专辑")
                    .font(ATMusicFont.appFont(13))
                    .foregroundStyle(Color.atmusicComment)
                    .padding(.horizontal, 16)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 12) {
                    ForEach(albums) { album in
                        NavigationLink {
                            if album.source == .synology {
                                SynologyAlbumView(albumName: album.name, artistName: album.artistName, coverURL: album.coverURL)
                            } else {
                                AlbumDetailView(album: album)
                                    .environmentObject(player)
                                    .environmentObject(theme)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                CoverImage(url: album.coverURL, size: 88, cornerRadius: 12)
                                    .frame(maxWidth: .infinity)
                                Text(album.name)
                                    .font(ATMusicFont.appFont(11, .medium))
                                    .foregroundStyle(Color.atmusicLabel)
                                    .lineLimit(1)
                                if let count = album.trackCount {
                                    Text(atmusicSongCountText(count))
                                        .font(ATMusicFont.appFont(10))
                                        .foregroundStyle(Color.atmusicComment)
                                }
                            }
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
            }
        }
    }

    private func load() async {
        loading = true
        errorMessage = nil
        if artistSource == .qq {
            await loadQQArtist()
        } else if artistSource == .kugou {
            await loadKugouArtist()
        } else {
            await loadNetEaseArtist()
        }
    }

    private func loadNetEaseArtist() async {
        do {
            let id: Int
            if let artistID, let parsed = Int(artistID.replacingOccurrences(of: "netease-", with: "")), parsed > 0 {
                id = parsed
            } else {
                let artists = try await NetEaseAPI.shared.searchArtists(keyword: artistName, limit: 5)
                guard let first = artists.first else {
                    errorMessage = "未找到歌手「\(artistName)」"
                    loading = false
                    return
                }
                artist = first
                id = Int(first.id.replacingOccurrences(of: "netease-", with: "")) ?? 0
            }
            async let songs = (try? NetEaseAPI.shared.artistHotSongs(artistID: id, limit: 5_000)) ?? []
            async let albums = (try? NetEaseAPI.shared.artistAlbums(artistID: id, limit: 5_000)) ?? []
            let (s, a) = await (songs, albums)
            hotSongs = s
            self.albums = a
            // 接口异常时兜底：分页搜索补全歌手歌曲（避免再次退回 30 首）。
            if hotSongs.isEmpty {
                var fallback: [Song] = []
                for offset in stride(from: 0, to: 5_000, by: 30) {
                    let page = (try? await NetEaseAPI.shared.search(keyword: artistName, limit: 30, offset: offset)) ?? []
                    if page.isEmpty { break }
                    fallback.append(contentsOf: page)
                    if page.count < 30 { break }
                }
                hotSongs = fallback
            }
            loading = false
        } catch {
            errorMessage = error.localizedDescription
            loading = false
        }
    }

    /// QQ 歌手：优先用歌手 mid 拉热门歌曲，失败则按歌手名搜索 QQ 歌曲（保证不是网易云数据）
    private func loadQQArtist() async {
        var mid: String? = nil
        if let artistID, !artistID.hasPrefix("qq-") {
            mid = artistID
        } else if let first = (try? await QQMusicAPI.shared.searchArtists(keyword: artistName, limit: 5))?.first {
            artist = first
            mid = first.id
        }
        async let remoteSongs = (try? await QQMusicAPI.shared.artistHotSongs(mid: mid, name: artistName, limit: 5_000)) ?? []
        async let remoteAlbums = (try? await QQMusicAPI.shared.artistAlbums(mid: mid, name: artistName, limit: 5_000)) ?? []
        var songs = await remoteSongs
        albums = await remoteAlbums
        if songs.isEmpty {
            var fallback: [Song] = []
            for offset in stride(from: 0, to: 5_000, by: 30) {
                let page = (try? await QQMusicAPI.shared.searchSongs(keyword: artistName, limit: 30, offset: offset)) ?? []
                if page.isEmpty { break }
                fallback.append(contentsOf: page)
                if page.count < 30 { break }
            }
            var seen = Set<String>()
            songs = fallback.filter { seen.insert($0.identityKey).inserted }
        }
        hotSongs = songs
        if albums.isEmpty {
            albums = albumsFromSongs(songs)
        }
        loading = false
    }

    /// 酷狗歌手主页优先走作者歌曲接口，再补 `singer/song` 和综合搜索结果，
    /// 避免部分歌手页只停在首批 19 首。
    private func loadKugouArtist() async {
        let resolvedArtist: Artist?
        if let artistID,
           !artistID.isEmpty,
           !artistID.hasPrefix("qq-") {
            let rawID = artistID.replacingOccurrences(of: "kugou-", with: "")
            resolvedArtist = artist ?? Artist(id: rawID, name: artistName, coverURL: nil, source: .kugou)
        } else {
            resolvedArtist = (try? await KugouMusicAPI.shared.searchArtists(keyword: artistName, limit: 10))?.first
        }
        if let resolvedArtist {
            artist = resolvedArtist
        }
        var songs: [Song] = []
        var primarySongs: [Song] = []
        if let resolvedArtist,
           !resolvedArtist.id.isEmpty,
           !resolvedArtist.id.hasPrefix("qq-") {
            var seen = Set<String>()
            let pageSize = 100
            let maxSongs = 10_000
            for page in 1...(maxSongs / pageSize) {
                let batch = (try? await KugouMusicAPI.shared.artistSongs(
                    authorID: resolvedArtist.id,
                    page: page,
                    limit: pageSize
                )) ?? []
                if batch.isEmpty { break }
                let before = songs.count
                for song in batch where seen.insert(song.identityKey).inserted {
                    songs.append(song)
                    primarySongs.append(song)
                    if songs.count >= maxSongs { break }
                }
                if songs.count >= maxSongs || songs.count == before {
                    break
                }
            }
        }

        // The author endpoint has historically returned only 19 rows for some
        // accounts/charts. Supplement a short result with paged song search.
        if songs.count < 100 {
            async let exact = KugouMusicAPI.shared.searchSongs(keyword: artistName, limit: 1_000)
            async let works = KugouMusicAPI.shared.searchSongs(keyword: "\(artistName) 歌曲", limit: 1_000)
            let candidates = [
                (try? await exact) ?? [],
                (try? await works) ?? [],
            ]
            var seen = Set(songs.map(\.identityKey))
            for song in candidates.flatMap({ $0 }) {
                guard seen.insert(song.identityKey).inserted else { continue }
                songs.append(song)
            }
        }

        if songs.isEmpty {
            async let exact = KugouMusicAPI.shared.searchSongs(keyword: artistName, limit: 1_000)
            async let hot = KugouMusicAPI.shared.searchSongs(keyword: "\(artistName) 热门", limit: 1_000)
            async let works = KugouMusicAPI.shared.searchSongs(keyword: "\(artistName) 歌曲", limit: 1_000)
            let batches = [
                (try? await exact) ?? [],
                (try? await hot) ?? [],
                (try? await works) ?? [],
            ]
            var seen = Set<String>()
            songs = batches.flatMap { $0 }.filter { song in
                seen.insert(song.identityKey).inserted
            }
        }

        hotSongs = songs
        if hotSongs.isEmpty, !primarySongs.isEmpty {
            hotSongs = primarySongs
        }
        albums = albumsFromSongs(hotSongs)
        ATMusicLogger.shared.log("酷狗歌手主页完成：artist=\(artistName) songs=\(hotSongs.count)", level: .debug)
        loading = false
    }

    private func albumsFromSongs(_ songs: [Song]) -> [Album] {
        var seen = Set<String>()
        return songs.compactMap { song in
            let name = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != "群晖 NAS" else { return nil }
            let key = "\(song.source.rawValue)|\(name.lowercased())|\(song.artists.lowercased())"
            guard seen.insert(key).inserted else { return nil }
            let count = songs.filter { $0.source == song.source && $0.album == song.album }.count
            return Album(id: "\(song.source.rawValue)-artist-album-\(key)", name: name, artistName: song.artists, coverURL: song.coverURL, source: song.source, trackCount: count)
        }
    }
}

/// 聚合歌手主页：歌曲和专辑严格分栏，内容来自网易云、QQ、酷狗和 NAS。
struct AllSourcesArtistHomeSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var synology = SynologyAPI.shared

    let artistName: String
    let initialSongs: [Song]
    @State private var songs: [Song] = []
    @State private var albums: [Album] = []
    @State private var loading = true
    @State private var selectedSection: ArtistHomeSection = .songs
    /// 聚合歌手页默认展示全部平台，使用 rawValue 存储以便后续扩展新音源而不改页面结构。
    @State private var selectedSourceRaws: Set<String> = Set([
        SongSource.netease.rawValue,
        SongSource.qq.rawValue,
        SongSource.kugou.rawValue,
        SongSource.synology.rawValue
    ])
    @State private var searchText = ""

    private enum ArtistHomeSection: String, CaseIterable, Identifiable {
        case songs = "歌曲"
        case albums = "专辑"
        var id: String { rawValue }
    }

    private var sourceFilterOptions: [SongSource] {
        [.netease, .qq, .kugou, .synology]
    }

    private func sourceTitle(_ source: SongSource) -> String {
        switch source {
        case .netease: return "网易云音乐"
        case .qq: return "QQ音乐"
        case .kugou: return "酷狗音乐"
        case .local: return "本地音乐"
        case .synology: return "群晖 NAS"
        }
    }

    private func toggleSource(_ source: SongSource) {
        if selectedSourceRaws.contains(source.rawValue) {
            guard selectedSourceRaws.count > 1 else {
                ToastCenter.shared.show("至少保留一个平台")
                return
            }
            selectedSourceRaws.remove(source.rawValue)
        } else {
            selectedSourceRaws.insert(source.rawValue)
        }
        ATMusicHaptics.select()
    }

    /// 歌手页只依赖这个统一的音源适配器协议。新增平台时注册一个 loader，页面和分栏无需改动。
    private struct SourceLoader {
        let name: String
        let load: @Sendable (String) async -> ([Song], [Album])
    }

    private static var sourceLoaders: [SourceLoader] {
        [
            SourceLoader(name: SongSource.netease.rawValue) { await Self.loadNetEase(name: $0) },
            SourceLoader(name: SongSource.qq.rawValue) { await Self.loadQQ(name: $0) },
            SourceLoader(name: SongSource.kugou.rawValue) { await Self.loadKugou(name: $0) },
            SourceLoader(name: SongSource.synology.rawValue) { await Self.loadNAS(name: $0) },
        ]
    }

    init(artistName: String, initialSongs: [Song] = []) {
        self.artistName = artistName
        self.initialSongs = initialSongs
    }

    var body: some View {
        ATMusicNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.customBackground, homeMode: true)
                if loading && songs.isEmpty && albums.isEmpty {
                    LoadingStateView()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            header
                            Picker("歌手内容", selection: $selectedSection) {
                                ForEach(ArtistHomeSection.allCases) { section in
                                    Text(section.rawValue).tag(section)
                                }
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal, 16)

                            if selectedSection == .songs {
                                songsSection
                            } else {
                                albumsSection
                            }
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                    }
                    .atmusicScrollIndicatorsHidden()
                }
            }
            .navigationTitle("歌手主页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("全选平台") {
                            selectedSourceRaws = Set(sourceFilterOptions.map(\.rawValue))
                            ATMusicHaptics.select()
                        }
                        Divider()
                        ForEach(sourceFilterOptions, id: \.rawValue) { source in
                            Button {
                                toggleSource(source)
                            } label: {
                                Label(sourceTitle(source), systemImage: selectedSourceRaws.contains(source.rawValue) ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("切换显示平台")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task { await loadAllSources() }
        .onChange(of: synology.libraryIndexRevision) { _, _ in
            Task { await mergeFullNASArtist() }
        }
        .modifier(ATMusicSheetModifier(detents: [.large], dragIndicator: true))
    }

    private var header: some View {
        HStack(spacing: 14) {
            CoverImage(url: songs.first?.coverURL, size: 76, cornerRadius: 38)
            VStack(alignment: .leading, spacing: 6) {
                Text(artistName)
                    .font(ATMusicFont.appFont(21, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(2)
                Text("歌曲 \(visibleSongs.count) 首 · 专辑 \(visibleAlbums.count) 张")
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    private var songsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "全部歌曲")
                Spacer()
                if !filteredSongs.isEmpty {
                    Button {
                        ATMusicHaptics.tap()
                        player.play(songs: filteredSongs, startAt: 0)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                            .font(ATMusicFont.appFont(12, .semibold))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                }
            }
            if !visibleSongs.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.atmusicComment)
                    TextField("搜索歌手歌曲", text: $searchText)
                        .font(ATMusicFont.appFont(14))
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)) }
            }
            LazyVStack(spacing: 0) {
                ForEach(Array(filteredSongs.enumerated()), id: \.element.identityKey) { index, song in
                    SongCell(song: song, glassRow: false, playbackContext: filteredSongs, playbackIndex: index) {
                        player.play(songs: filteredSongs, startAt: index)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "全部专辑")
                .padding(.horizontal, 16)
            if visibleAlbums.isEmpty {
                Text("暂无专辑")
                    .font(ATMusicFont.appFont(13))
                    .foregroundStyle(Color.atmusicComment)
                    .padding(.horizontal, 16)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 14) {
                    ForEach(visibleAlbums) { album in
                        NavigationLink {
                            if album.source == .synology {
                                SynologyAlbumView(albumName: album.name, artistName: album.artistName, coverURL: album.coverURL)
                            } else {
                                AlbumDetailView(album: album)
                                    .environmentObject(player)
                                    .environmentObject(theme)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                CoverImage(url: album.coverURL, size: 110, cornerRadius: 12)
                                Text(album.name)
                                    .font(ATMusicFont.appFont(12, .medium))
                                    .foregroundStyle(Color.atmusicLabel)
                                    .lineLimit(2)
                                HStack(spacing: 4) {
                                    SourceBadgeView(source: album.source, compact: true)
                                    if let count = album.trackCount {
                                        Text(atmusicSongCountText(count))
                                            .font(ATMusicFont.appFont(10))
                                            .foregroundStyle(Color.atmusicComment)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var filteredSongs: [Song] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return visibleSongs }
        return visibleSongs.filter {
            $0.name.lowercased().contains(query)
                || $0.artists.lowercased().contains(query)
                || $0.album.lowercased().contains(query)
        }
    }

    private var visibleSongs: [Song] {
        songs.filter { selectedSourceRaws.contains($0.source.rawValue) }
    }

    private var visibleAlbums: [Album] {
        albums.filter { selectedSourceRaws.contains($0.source.rawValue) }
    }

    private func loadAllSources() async {
        await MainActor.run {
            songs = initialSongs
            loading = initialSongs.isEmpty
        }
        await withTaskGroup(of: ([Song], [Album]).self) { group in
            for loader in Self.sourceLoaders {
                group.addTask { await loader.load(artistName) }
            }
            for await result in group {
                await MainActor.run {
                    merge(songs: result.0, albums: result.1)
                    loading = false
                }
            }
        }
        await mergeFullNASArtist()
        await MainActor.run { loading = false }
    }

    private func mergeFullNASArtist() async {
        guard synology.isLoggedIn else { return }
        guard let all = try? await synology.librarySongs() else { return }
        let matched = all.filter { Self.artistMatches($0.artists, artistName: artistName) }
        await MainActor.run {
            merge(songs: matched, albums: Self.albumsFromSongs(matched))
            loading = false
        }
    }

    @MainActor
    private func merge(songs newSongs: [Song], albums newAlbums: [Album]) {
        var seenSongs = Set(songs.map(\.identityKey))
        songs.append(contentsOf: newSongs.filter { seenSongs.insert($0.identityKey).inserted })
        // 平台专辑接口可能暂时不可用，但歌曲通常仍带有 album 字段；
        // 先从歌曲补出专辑入口，保证平台不会出现“只有 NAS 有专辑”的空状态。
        let albumsToMerge = newAlbums + Self.albumsFromSongs(newSongs)
        var seenAlbums = Set(albums.map { "\($0.source.rawValue)|\($0.name.lowercased())|\($0.artistName.lowercased())" })
        albums.append(contentsOf: albumsToMerge.filter {
            seenAlbums.insert("\($0.source.rawValue)|\($0.name.lowercased())|\($0.artistName.lowercased())").inserted
        })
    }

    private static func loadNetEase(name: String) async -> ([Song], [Album]) {
        guard let artist = try? await NetEaseAPI.shared.searchArtists(keyword: name, limit: 5), let first = artist.first,
              let id = Int(first.id.replacingOccurrences(of: "netease-", with: "")) else { return ([], []) }
        async let songs = (try? await NetEaseAPI.shared.artistHotSongs(artistID: id, limit: 5_000)) ?? []
        async let albums = (try? await NetEaseAPI.shared.artistAlbums(artistID: id, limit: 5_000)) ?? []
        var songList = await songs
        if songList.count < 100 {
            var fallback = songList
            for offset in stride(from: 0, to: 2_000, by: 100) {
                let batch = (try? await NetEaseAPI.shared.search(keyword: name, limit: 100, offset: offset)) ?? []
                if batch.isEmpty { break }
                fallback.append(contentsOf: batch.filter { artistMatches($0.artists, artistName: name) })
                if batch.count < 100 { break }
            }
            songList = deduplicatedSongs(fallback)
        }
        let albumList = await albums
        return (songList, albumList.isEmpty ? albumsFromSongs(songList) : albumList)
    }

    private static func loadQQ(name: String) async -> ([Song], [Album]) {
        let first = (try? await QQMusicAPI.shared.searchArtists(keyword: name, limit: 5))?.first
        let mid = first?.id.hasPrefix("qq-") == false ? first?.id : nil
        async let songs = (try? await QQMusicAPI.shared.artistHotSongs(mid: mid, name: name, limit: 5_000)) ?? []
        async let albums = (try? await QQMusicAPI.shared.artistAlbums(mid: mid, name: name, limit: 5_000)) ?? []
        var songList = await songs
        if songList.count < 100 {
            var fallback = songList
            for offset in stride(from: 0, to: 2_000, by: 30) {
                let batch = (try? await QQMusicAPI.shared.searchSongs(keyword: name, limit: 30, offset: offset)) ?? []
                if batch.isEmpty { break }
                fallback.append(contentsOf: batch.filter { artistMatches($0.artists, artistName: name) })
                if batch.count < 30 { break }
            }
            songList = deduplicatedSongs(fallback)
        }
        let albumList = await albums
        return (songList, albumList.isEmpty ? albumsFromSongs(songList) : albumList)
    }

    private static func loadKugou(name: String) async -> ([Song], [Album]) {
        guard let artist = try? await KugouMusicAPI.shared.searchArtists(keyword: name, limit: 5), let first = artist.first else { return ([], []) }
        let authorID = first.id.replacingOccurrences(of: "kugou-", with: "")
        var songs: [Song] = []
        var seen = Set<String>()
        for page in 1...100 {
            let batch = (try? await KugouMusicAPI.shared.artistSongs(authorID: authorID, page: page, limit: 100)) ?? []
            if batch.isEmpty { break }
            songs.append(contentsOf: batch.filter { seen.insert($0.identityKey).inserted })
                // 酷狗部分歌手接口会返回不足 100 首的短页，不能据此判断已到末尾。
        }
        if songs.count < 100 {
            let fallback = (try? await KugouMusicAPI.shared.searchSongs(keyword: name, limit: 1_000)) ?? []
            songs.append(contentsOf: fallback.filter { artistMatches($0.artists, artistName: name) })
            songs = deduplicatedSongs(songs)
        }
        return (songs, albumsFromSongs(songs))
    }

    private static func loadNAS(name: String) async -> ([Song], [Album]) {
        let result = try? await SynologyAPI.shared.searchAllVariants(keyword: name, limit: 200)
        let songs = result?.songs ?? []
        return (songs, albumsFromSongs(songs))
    }

    private static func artistMatches(_ value: String, artistName: String) -> Bool {
        let query = normalizeArtist(artistName)
        guard !query.isEmpty else { return false }
        let normalizedValue = normalizeArtist(value)
        if normalizedValue == query || normalizedValue.contains(query) || query.contains(normalizedValue) {
            return true
        }
        return value.split { "/／,，、&＆+＋|｜;；".contains($0) }
            .contains { normalizeArtist(String($0)) == query }
    }

    private static func deduplicatedSongs(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.identityKey).inserted }
    }

    private static func normalizeArtist(_ value: String) -> String {
        let simplified = value.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? value
        return simplified.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    private static func albumsFromSongs(_ songs: [Song]) -> [Album] {
        var seen = Set<String>()
        return songs.compactMap { song in
            let name = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != "群晖 NAS" else { return nil }
            let key = "\(song.source.rawValue)|\(name.lowercased())|\(song.artists.lowercased())"
            guard seen.insert(key).inserted else { return nil }
            let count = songs.filter { $0.source == song.source && $0.album == name }.count
            return Album(id: "\(song.source.rawValue)-artist-album-\(key)", name: name, artistName: song.artists, coverURL: song.coverURL, source: song.source, trackCount: count)
        }
    }
}
