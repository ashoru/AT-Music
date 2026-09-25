import SwiftUI
import UIKit

struct SynologyMusicView: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var synology = SynologyAPI.shared

    @State private var songs: [Song] = []
    @State private var playlists: [Playlist] = []
    @State private var selectedTab: Int = 0 // 0: 歌曲, 1: 歌单
    @State private var searchText: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showConfigSheet = false

    var body: some View {
        ZStack {
            GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)

            if !synology.isLoggedIn {
                notConnectedView
            } else if isLoading && songs.isEmpty && playlists.isEmpty {
                LoadingStateView()
            } else if let errorMessage, songs.isEmpty {
                ErrorStateView(message: errorMessage) {
                    Task { await loadData() }
                }
            } else {
                contentList
            }
        }
        .navigationTitle("群晖音乐库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showConfigSheet = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                }
            }
        }
        .sheet(isPresented: $showConfigSheet) {
            SynologyLoginSheet()
                .environmentObject(theme)
        }
        .task {
            if synology.isLoggedIn {
                await loadData()
            }
        }
        .onChange(of: synology.libraryIndexRevision) { _, _ in
            guard synology.isLoggedIn else { return }
            Task { await loadData() }
        }
    }

    private var notConnectedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "server.rack")
                .font(.system(size: 64))
                .foregroundStyle(Color.atmusicAmber)

            Text("尚未连接群晖 NAS")
                .font(ATMusicFont.appFont(18, .bold))
                .foregroundStyle(Color.atmusicLabel)

            Text("连接您的群晖 Audio Station 套件\n即可在 AT Music 中流畅播放您的私有高品质音乐")
                .font(ATMusicFont.appFont(13))
                .foregroundStyle(Color.atmusicComment)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            Button {
                showConfigSheet = true
            } label: {
                Text("配置群晖服务器")
                    .font(ATMusicFont.appFont(15, .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(Color.atmusicAmber, in: Capsule())
            }
            .buttonStyle(GlassPressButtonStyle())
        }
        .padding(32)
    }

    private var contentList: some View {
        List {
            headerSection
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            if selectedTab == 0 {
                // 歌曲列表
                Section {
                    ForEach(Array(displayedSongs.enumerated()), id: \.element.identityKey) { index, song in
                        SongCell(song: song, glassRow: true, playbackContext: displayedSongs, playbackIndex: index) {
                            player.play(songs: displayedSongs, startAt: index)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            } else {
                // 歌单列表
                Section {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            PlaylistView(playlist: playlist)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 20))
                                    .foregroundStyle(Color.atmusicAmber)
                                    .frame(width: 44, height: 44)
                                    .background(Color.atmusicAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(playlist.name)
                                        .font(ATMusicFont.appFont(15, .semibold))
                                        .foregroundStyle(Color.atmusicLabel)
                                    Text("群晖云端歌单")
                                        .font(ATMusicFont.appFont(12))
                                        .foregroundStyle(Color.atmusicComment)
                                }
                                Spacer()
                            }
                            .padding(10)
                            .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .refreshable {
            await loadData()
        }
    }

    private var headerSection: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.atmusicAmber)
                    .frame(width: 60, height: 60)
                    .background(Color.atmusicAmber.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(synology.account.isEmpty ? "群晖 NAS" : "\(synology.account) 的 NAS")
                        .font(ATMusicFont.appFont(17, .bold))
                        .foregroundStyle(Color.atmusicLabel)

                    Text("\(songs.count) 首音乐 · \(playlists.count) 个歌单")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                }
                Spacer()
            }

            if selectedTab == 0 && !displayedSongs.isEmpty {
                HStack(spacing: 10) {
                    GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                        player.play(songs: displayedSongs, startAt: 0)
                    }
                    GlassButton(title: "随机播放", systemName: "shuffle") {
                        if !displayedSongs.isEmpty {
                            let rnd = Int.random(in: 0..<displayedSongs.count)
                            player.play(songs: displayedSongs, startAt: rnd)
                        }
                    }
                }
            }

            // 搜索框与 Tab 切换
            VStack(spacing: 10) {
                Picker("", selection: $selectedTab) {
                    Text("全部歌曲 (\(songs.count))").tag(0)
                    Text("NAS 歌单 (\(playlists.count))").tag(1)
                }
                .pickerStyle(.segmented)

                if selectedTab == 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.atmusicComment)
                        TextField("在群晖音乐库中搜索", text: $searchText)
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
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(14)
        .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)) }
    }

    private var displayedSongs: [Song] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if kw.isEmpty {
            return songs
        }
        return songs.filter { song in
            song.name.lowercased().contains(kw)
                || song.artists.lowercased().contains(kw)
                || song.album.lowercased().contains(kw)
        }
    }

    private func loadData() async {
        isLoading = true
        errorMessage = nil
        do {
            async let fetchedSongs = synology.songs(offset: 0, limit: 1000)
            async let fetchedPlaylists = synology.allPlaylists()
            let (s, p) = try await (fetchedSongs, fetchedPlaylists)
            songs = s
            playlists = p
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}

/// NAS 歌曲信息：先以半屏卡片展示，点某一个标签才进入对应的全屏编辑页。
/// 不会在打开时自动用在线结果覆盖任何已有字段。
struct SynologyMetadataEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerManager
    let song: Song

    @State private var metadata: SynologyTagMetadata
    @State private var originalMetadata: SynologyTagMetadata
    @State private var selectedCoverURL: URL?
    @State private var selectedCoverData: Data?
    @State private var selectedCoverSource = ""
    @State private var editingField: SongMetadataField?
    @State private var showCoverSearch = false
    @State private var isSaving = false
    @State private var message = ""

    init(song: Song) {
        self.song = song
        let snapshot = SynologyTagMetadata(
            title: Self.editableValue(song.name, placeholders: ["", "未知歌曲"]),
            artist: Self.editableValue(song.artists, placeholders: ["", "未知艺术家"]),
            album: Self.editableValue(song.album, placeholders: ["", "群晖 NAS"]),
            albumArtist: song.albumArtist ?? "",
            genre: song.genre ?? "",
            year: song.year ?? "",
            comment: song.comment ?? ""
        )
        _metadata = State(initialValue: snapshot)
        _originalMetadata = State(initialValue: snapshot)
    }

    private var displayedCoverURL: URL? { selectedCoverURL ?? song.coverURL }
    private var changedTagCount: Int {
        let patch = metadata.patch(comparedTo: originalMetadata)
        return [patch.title, patch.artist, patch.album, patch.albumArtist, patch.genre, patch.year, patch.comment].compactMap { $0 }.count
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    songFileSummary
                    Divider().overlay(Color.atmusicSecondary.opacity(0.26))
                    tagRows
                    if !message.isEmpty {
                        Text(message)
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicComment)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 14)
                    }
                    actionButtons
                }
                .padding(.top, 10)
            }
            .background(Color.atmusicBackground.ignoresSafeArea())
            .navigationTitle("歌曲信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
        .modifier(ATMusicSheetModifier(detents: [.medium, .large], dragIndicator: true))
        .fullScreenCover(item: $editingField) { field in
            SongMetadataFieldEditor(field: field, initialValue: value(for: field)) { value in
                set(value, for: field)
            }
        }
        .fullScreenCover(isPresented: $showCoverSearch) {
            SongCoverSearchGridSheet(song: song) { candidate in
                selectedCoverURL = candidate.song.coverURL
                selectedCoverData = nil
                selectedCoverSource = candidate.providerName
            } onPickData: { data in
                selectedCoverData = data
                selectedCoverURL = nil
                selectedCoverSource = "本机图片"
            }
        }
    }

    private var songFileSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            MetadataStaticRow(title: "文件路径", value: song.synologyPath ?? "未读取到原文件路径", multiline: true)
            MetadataStaticRow(title: "来源", value: "群晖 NAS")
            MetadataStaticRow(title: "格式", value: fileExtension.isEmpty ? "音频文件" : fileExtension.uppercased())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private var tagRows: some View {
        VStack(spacing: 0) {
            Button { showCoverSearch = true } label: {
                HStack(spacing: 16) {
                    Text("封面").foregroundStyle(Color.atmusicComment)
                    Spacer()
                    Group {
                        if let selectedCoverData, let image = UIImage(data: selectedCoverData) {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            CoverImage(url: displayedCoverURL, size: 48, cornerRadius: 8)
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Image(systemName: "pencil").foregroundStyle(Color.atmusicComment)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            if !selectedCoverSource.isEmpty {
                Text("待写入封面：\(selectedCoverSource)")
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicAmber)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 20).padding(.bottom, 6)
            }
            ForEach(SongMetadataField.allCases) { field in
                Divider().padding(.leading, 20).overlay(Color.atmusicSecondary.opacity(0.26))
                Button { editingField = field } label: {
                    HStack(spacing: 14) {
                        Text(field.title).foregroundStyle(Color.atmusicComment)
                        Spacer(minLength: 16)
                        Text(value(for: field).isEmpty ? "未填写" : value(for: field))
                            .foregroundStyle(value(for: field).isEmpty ? Color.atmusicComment.opacity(0.7) : Color.atmusicLabel)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(field == .comment ? 2 : 1)
                        Image(systemName: "pencil").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.atmusicComment)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 15)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                Task { await save() }
            } label: {
                HStack {
                    if isSaving { ProgressView().tint(.white) }
                    Text(isSaving ? "写入中…" : changedTagCount == 0 && selectedCoverURL == nil && selectedCoverData == nil ? "没有待保存的改动" : "写入 NAS")
                }
                .font(ATMusicFont.appFont(16, .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .foregroundStyle(Color.atmusicLabel)
            .background {
                ATMusicLiquidSelectionSurface(
                    shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
                    accent: .atmusicAmber
                )
            }
            .buttonStyle(.plain)
            .opacity(isSaving || (changedTagCount == 0 && selectedCoverURL == nil && selectedCoverData == nil) ? 0.55 : 1)
            .disabled(isSaving || (changedTagCount == 0 && selectedCoverURL == nil && selectedCoverData == nil))
            Button("取消") { dismiss() }
                .foregroundStyle(Color.atmusicLabel)
                .padding(.vertical, 8)
        }
        .padding(20)
    }

    private var fileExtension: String {
        ((song.synologyPath ?? "") as NSString).pathExtension
    }

    private func value(for field: SongMetadataField) -> String {
        switch field {
        case .title: return metadata.title
        case .artist: return metadata.artist
        case .album: return metadata.album
        case .albumArtist: return metadata.albumArtist
        case .genre: return metadata.genre
        case .year: return metadata.year
        case .comment: return metadata.comment
        }
    }

    private func set(_ value: String, for field: SongMetadataField) {
        switch field {
        case .title: metadata.title = value
        case .artist: metadata.artist = value
        case .album: metadata.album = value
        case .albumArtist: metadata.albumArtist = value
        case .genre: metadata.genre = value
        case .year: metadata.year = value
        case .comment: metadata.comment = value
        }
    }

    private func save() async {
        let patch = metadata.patch(comparedTo: originalMetadata)
        guard !patch.isEmpty || selectedCoverURL != nil || selectedCoverData != nil else { return }
        let wroteTags = !patch.isEmpty
        await MainActor.run { isSaving = true; message = "正在将已编辑字段写入 NAS…" }
        do {
            try await SynologyAPI.shared.applyMetadata(song: song, patch: patch, coverURL: selectedCoverURL, coverData: selectedCoverData)
            let refreshedCover = SynologyAPI.shared.coverURL(
                songId: song.synologyId ?? "\(song.id)",
                cacheBust: UUID().uuidString
            )
            let updatedSong = Song(
                id: song.id,
                name: metadata.title.isEmpty ? "未知歌曲" : metadata.title,
                artists: metadata.artist.isEmpty ? "未知艺术家" : metadata.artist,
                album: metadata.album.isEmpty ? "群晖 NAS" : metadata.album,
                coverURL: refreshedCover ?? song.coverURL,
                duration: song.duration,
                source: song.source,
                synologyId: song.synologyId,
                synologyServerScope: song.synologyServerScope,
                synologyPath: song.synologyPath,
                albumArtist: metadata.albumArtist.isEmpty ? nil : metadata.albumArtist,
                genre: metadata.genre.isEmpty ? nil : metadata.genre,
                year: metadata.year.isEmpty ? nil : metadata.year,
                comment: metadata.comment.isEmpty ? nil : metadata.comment,
                fee: song.fee
            )
            await MainActor.run {
                player.replaceSong(updatedSong)
            }
            await MainActor.run {
                originalMetadata = metadata
                selectedCoverURL = nil
                selectedCoverData = nil
                ToastCenter.shared.show(wroteTags ? "已写入修改的歌曲标签" : "已写入封面")
                dismiss()
            }
        } catch {
            await MainActor.run { message = "写入失败：\(error.localizedDescription)" }
        }
        await MainActor.run { isSaving = false }
    }

    private static func editableValue(_ value: String, placeholders: [String]) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return placeholders.contains(trimmed) ? "" : trimmed
    }
}

enum SongMetadataField: String, CaseIterable, Identifiable {
    case title, artist, album, albumArtist, genre, year, comment
    var id: String { rawValue }
    var title: String {
        switch self {
        case .title: return "歌曲标题"
        case .artist: return "演出者"
        case .album: return "专辑名称"
        case .albumArtist: return "专辑演出者"
        case .genre: return "流派"
        case .year: return "专辑年份"
        case .comment: return "备注"
        }
    }
    var keyboard: UIKeyboardType { self == .year ? .numberPad : .default }
    var multiline: Bool { self == .comment }
}

struct MetadataStaticRow: View {
    let title: String
    let value: String
    var multiline = false
    var body: some View {
        HStack(alignment: multiline ? .top : .firstTextBaseline, spacing: 16) {
            Text(title).foregroundStyle(Color.atmusicComment).frame(width: 74, alignment: .leading)
            Text(value).foregroundStyle(Color.atmusicLabel).multilineTextAlignment(.leading).lineLimit(multiline ? 4 : 1)
            Spacer(minLength: 0)
        }
        .font(ATMusicFont.appFont(14))
    }
}

struct SongMetadataFieldEditor: View {
    @Environment(\.dismiss) private var dismiss
    let field: SongMetadataField
    @State private var value: String
    let onSave: (String) -> Void

    init(field: SongMetadataField, initialValue: String, onSave: @escaping (String) -> Void) {
        self.field = field
        _value = State(initialValue: initialValue)
        self.onSave = onSave
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 18) {
                Text("只会保存“\(field.title)”这一项，其他标签保持原样。")
                    .font(ATMusicFont.appFont(14))
                    .foregroundStyle(Color.atmusicComment)
                if field.multiline {
                    TextEditor(text: $value)
                        .padding(10)
                        .frame(minHeight: 180)
                        .background(Color.atmusicCard)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    TextField(field.title, text: $value)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(field.keyboard)
                }
                Spacer()
            }
            .padding(20)
            .background(Color.atmusicBackground.ignoresSafeArea())
            .navigationTitle(field.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(value.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
            }
        }
    }
}

/// 封面独立使用全屏搜索网格；点击图片只选中封面，不会自动改动任何歌曲标签。
struct SongCoverSearchGridSheet: View {
    @Environment(\.dismiss) private var dismiss
    let song: Song
    let onSelect: (SynologyMetadataCandidate) -> Void
    let onPickData: (Data) -> Void

    @State private var keyword: String
    @State private var candidates: [SynologyMetadataCandidate] = []
    @State private var isLoading = false
    @State private var showPhotoPicker = false

    init(song: Song, onSelect: @escaping (SynologyMetadataCandidate) -> Void, onPickData: @escaping (Data) -> Void) {
        self.song = song
        self.onSelect = onSelect
        self.onPickData = onPickData
        _keyword = State(initialValue: [song.artists, song.album, song.name].filter { !$0.isEmpty }.joined(separator: " "))
    }

    private var covers: [SynologyMetadataCandidate] { candidates.filter { $0.song.coverURL != nil } }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("歌手、专辑或歌曲", text: $keyword)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    Button("搜索") { Task { await search() } }
                        .font(ATMusicFont.appFont(14, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background {
                            ATMusicLiquidSelectionSurface(shape: Capsule(), accent: .atmusicAmber)
                        }
                        .buttonStyle(.plain)
                }
                .padding(12)
                if isLoading { ProgressView("正在搜索在线封面…").padding(.bottom, 8) }
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                        ForEach(covers) { candidate in
                            Button {
                                onSelect(candidate)
                                dismiss()
                            } label: {
                                ZStack(alignment: .bottomLeading) {
                                    AsyncImage(url: candidate.song.coverURL) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: { Color.atmusicCard.overlay(ProgressView()) }
                                    Text(candidate.providerName)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 4)
                                        .background(.black.opacity(0.58))
                                }
                                .aspectRatio(1, contentMode: .fit)
                                .clipped()
                            }
                            .buttonStyle(.plain)
                        }
                        Button { showPhotoPicker = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 34, weight: .medium))
                                .foregroundStyle(Color.atmusicAmber)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .aspectRatio(1, contentMode: .fit)
                                .background(Color.atmusicCard)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .background(Color.atmusicBackground.ignoresSafeArea())
            .navigationTitle("选择歌曲封面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task { await search() }
            .sheet(isPresented: $showPhotoPicker) {
                WallpaperPhotoPicker { data in
                    onPickData(data)
                    showPhotoPicker = false
                    dismiss()
                }
            }
        }
    }

    private func search() async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await MainActor.run { isLoading = true }
        let seed = Song(id: 0, name: trimmed, artists: "", album: "", coverURL: nil, duration: song.duration, source: .synology)
        let found = await SynologyAPI.shared.metadataCandidates(for: seed)
        await MainActor.run { candidates = found; isLoading = false }
    }
}

/// 主页/音乐库内嵌的 NAS 内容。它不使用 List，避免嵌套 ScrollView 时出现空白，
/// 同时不提供登录按钮，账号配置统一放在「我的 → 账号与登录」。
struct SynologyHomeSection: View {
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var synology = SynologyAPI.shared

    @State private var songs: [Song] = []
    @State private var playlists: [Playlist] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var displayedSongs: [Song] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return songs }
        return songs.filter {
            $0.name.lowercased().contains(keyword)
                || $0.artists.lowercased().contains(keyword)
                || $0.album.lowercased().contains(keyword)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !synology.isLoggedIn {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.atmusicAmber)
                    Text("群晖 NAS 尚未连接")
                        .font(ATMusicFont.appFont(15, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text("请前往“我的” → “账号与登录”配置群晖 Audio Station")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }
            } else if isLoading && songs.isEmpty && playlists.isEmpty {
                LoadingStateView()
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else if let errorMessage, songs.isEmpty && playlists.isEmpty {
                ErrorStateView(message: errorMessage) {
                    Task { await load() }
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(Color.atmusicAmber)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("群晖音乐库")
                            .font(ATMusicFont.appFont(17, .bold))
                            .foregroundStyle(Color.atmusicLabel)
                        Text("\(songs.count) 首音乐 · \(playlists.count) 个歌单")
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicComment)
                    }
                    Spacer()
                    if !displayedSongs.isEmpty {
                        Button {
                            player.play(songs: displayedSongs, startAt: 0)
                        } label: {
                            Image(systemName: "play.fill")
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(Color.atmusicAmber, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
                .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)) }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.atmusicComment)
                    TextField("在群晖音乐库中搜索", text: $searchText)
                        .font(ATMusicFont.appFont(14))
                        .autocorrectionDisabled()
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.atmusicComment)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

                if displayedSongs.isEmpty {
                    Text(searchText.isEmpty ? "群晖音乐库暂无歌曲" : "没有找到匹配的歌曲")
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicComment)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    SectionHeader(title: "歌曲")
                    ForEach(Array(displayedSongs.prefix(30).enumerated()), id: \.element.identityKey) { index, song in
                        SongCell(song: song, glassRow: true, playbackContext: displayedSongs, playbackIndex: index) {
                            player.play(songs: displayedSongs, startAt: index)
                        }
                    }
                }

                if !playlists.isEmpty {
                    SectionHeader(title: "歌单")
                    ForEach(playlists.prefix(10)) { playlist in
                        NavigationLink {
                            PlaylistView(playlist: playlist)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "music.note.list")
                                    .foregroundStyle(Color.atmusicAmber)
                                Text(playlist.name)
                                    .font(ATMusicFont.appFont(14, .semibold))
                                    .foregroundStyle(Color.atmusicLabel)
                                Spacer()
                                Text("\(playlist.trackCount) 首")
                                    .font(ATMusicFont.appFont(12))
                                    .foregroundStyle(Color.atmusicComment)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(Color.atmusicComment)
                            }
                            .padding(12)
                            .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)) }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .task {
            await load()
        }
    }

    private func load() async {
        guard synology.isLoggedIn else { return }
        isLoading = true
        errorMessage = nil
        do {
            async let fetchedSongs = synology.songs(offset: 0, limit: 1000)
            async let fetchedPlaylists = synology.allPlaylists()
            let (newSongs, newPlaylists) = try await (fetchedSongs, fetchedPlaylists)
            songs = newSongs
            playlists = newPlaylists
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}

/// NAS 首页：信息结构参考 Plexamp，控件保持 Apple Music 式原生排版。
struct SynologyAppleHomeSection: View {
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var synology = SynologyAPI.shared
    @ObservedObject private var favorites = FavoritesStore.shared

    @State private var songs: [Song] = []
    @State private var playlists: [Playlist] = []
    @State private var playlistPreviewSongs: [String: Song] = [:]
    @State private var todayRecommendations: [Song] = []
    @State private var recommendationsUpdatedAt = Date.distantPast
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var nasHistory: [Song] {
        player.history.filter { $0.source == .synology }
    }

    private var frequentArtistSongs: [Song] {
        let songs = nasHistory.isEmpty ? self.songs : nasHistory
        var seen = Set<String>()
        return songs.filter {
            let artist = $0.artists.trimmingCharacters(in: .whitespacesAndNewlines)
            return !artist.isEmpty && seen.insert(artist).inserted
        }.prefix(10).map { $0 }
    }

    private var frequentAlbums: [Song] {
        var seen = Set<String>()
        return (nasHistory.isEmpty ? songs : nasHistory).filter { seen.insert($0.album).inserted }.prefix(10).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !synology.isLoggedIn {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.atmusicAmber)
                    Text("群晖 NAS 尚未连接")
                        .font(ATMusicFont.appFont(16, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text("请前往“我的” → “账号与登录”配置 Audio Station")
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicComment)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 45)
            } else if isLoading && songs.isEmpty {
                LoadingStateView()
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else if let errorMessage, songs.isEmpty {
                ErrorStateView(message: errorMessage) { Task { await load() } }
            } else {
                // 与在线平台统一：推荐 → 歌单 → 最近内容 → 专辑 / 歌手。
                synologySongSection(title: "今日推荐", songs: Array(todayRecommendations.prefix(12)), destination: SynologyRecommendationView(initialSongs: todayRecommendations))
                synologyPlaylistSection
                synologySongSection(title: "最近播放", songs: Array(nasHistory.prefix(12)), destination: SynologySongCollectionView(title: "最近播放", songs: nasHistory))
                synologySongSection(title: "我最喜欢", songs: Array(favorites.synologyFavoriteSongs.prefix(12)), destination: SynologySongCollectionView(title: "我最喜欢", songs: favorites.synologyFavoriteSongs))
                synologyAlbumSection
                synologyArtistSection
            }
        }
        .task {
            if synology.isLoggedIn { await load() }
        }
    }

    @ViewBuilder
    private func synologySongSection<Destination: View>(title: String, songs: [Song], destination: Destination) -> some View {
        if !songs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                synologySectionHeader(title: title, destination: destination)
                GeometryReader { proxy in
                    let cardWidth = min(160, max(150, (proxy.size.width - 14) / 2))
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(Array(songs.enumerated()), id: \.element.identityKey) { index, song in
                                Button {
                                    player.play(songs: songs, startAt: index)
                                } label: {
                                    SynologySquareTile(coverURL: song.coverURL, title: song.name, subtitle: song.artists)
                                }
                                .frame(width: cardWidth)
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(height: 212)
            }
        }
    }

    private var synologyAlbumSection: some View {
        Group {
            if !frequentAlbums.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    synologySectionHeader(title: "常听专辑", destination: SynologyAlbumCollectionView(songs: songs))
                    GeometryReader { proxy in
                        let cardWidth = min(160, max(150, (proxy.size.width - 14) / 2))
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(frequentAlbums) { song in
                                    NavigationLink {
                                        SynologyAlbumView(albumName: song.album, artistName: song.artists, coverURL: song.coverURL)
                                    } label: {
                                        SynologySquareTile(coverURL: song.coverURL, title: song.album, subtitle: song.artists)
                                    }
                                    .frame(width: cardWidth)
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(height: 212)
                }
            }
        }
    }

    private var synologyArtistSection: some View {
        Group {
            if !frequentArtistSongs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    synologySectionHeader(title: "常听歌手", destination: SynologyArtistCollectionView(songs: songs))
                    GeometryReader { proxy in
                        let cardWidth = min(160, max(150, (proxy.size.width - 14) / 2))
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(frequentArtistSongs) { song in
                                    NavigationLink {
                                        SynologyArtistView(artistName: song.artists, coverURL: song.coverURL, initialSongs: self.songs)
                                    } label: {
                                        SynologySquareTile(coverURL: song.coverURL, title: song.artists, subtitle: "歌手", circularCover: true)
                                    }
                                    .frame(width: cardWidth)
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(height: 212)
                }
            }
        }
    }

    private var synologyPlaylistSection: some View {
        Group {
            if !playlists.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    synologySectionHeader(title: "歌单", destination: SynologyPlaylistCollectionView(playlists: playlists))
                    GeometryReader { proxy in
                        let cardWidth = min(160, max(150, (proxy.size.width - 14) / 2))
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(playlists.prefix(8)) { playlist in
                            NavigationLink { PlaylistView(playlist: playlist) } label: {
                                let playlistID = playlist.synologyPlaylistId ?? "\(playlist.id)"
                                SynologySquareTile(
                                    coverURL: playlistPreviewSongs[playlistID]?.coverURL ?? playlist.coverURL,
                                    title: playlist.name,
                                    subtitle: "\(playlist.trackCount) 首"
                                )
                            }
                            .frame(width: cardWidth)
                            .buttonStyle(.plain)
                        }
                            }
                        }
                    }
                    .frame(height: 212)
                }
            }
        }
    }

    private func synologySectionHeader<Destination: View>(title: String, destination: Destination) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(ATMusicFont.appFont(20, .bold))
                .foregroundStyle(Color.atmusicLabel)
            Spacer()
            NavigationLink {
                destination
            } label: {
                HStack(spacing: 4) {
                    Text("查看全部")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                }
                .font(ATMusicFont.appFont(12, .semibold))
                .foregroundStyle(Color.atmusicComment)
            }
            .buttonStyle(.plain)
        }
    }

    private func load() async {
        guard synology.isLoggedIn else { return }
        isLoading = true
        errorMessage = nil
        do {
            // 首页只先取一批足够首屏展示的歌曲；完整库随后静默补齐，
            // 避免大 NAS 曲库把“主页可见时间”绑在 1000 首歌曲请求上。
            async let initialSongs = synology.songs(offset: 0, limit: 240)
            async let fetchedPlaylists = synology.allPlaylists()
            let loadedSongs = try await initialSongs
            let loadedPlaylists = try await fetchedPlaylists

            songs = loadedSongs
            playlists = loadedPlaylists
            if todayRecommendations.isEmpty || Date().timeIntervalSince(recommendationsUpdatedAt) >= 600 {
                todayRecommendations = Array(loadedSongs.shuffled().prefix(20))
                recommendationsUpdatedAt = Date()
            }
            isLoading = false

            // 封面预览属于增强信息，不阻塞首屏。
            var previews: [String: Song] = [:]
            await withTaskGroup(of: (String, Song?).self) { group in
                for playlist in loadedPlaylists.prefix(8) {
                    let playlistID = playlist.synologyPlaylistId ?? "\(playlist.id)"
                    group.addTask {
                        let song = (try? await synology.playlistSongs(playlistId: playlistID, limit: 1))?.first
                        return (playlistID, song)
                    }
                }
                for await (playlistID, song) in group {
                    if let song { previews[playlistID] = song }
                }
            }
            playlistPreviewSongs = previews

            // 完整库静默补齐，用于常听专辑/歌手及进入集合页后的完整内容。
            if let fullLibrary = try? await synology.songs(offset: 0, limit: 1000),
               fullLibrary.count > loadedSongs.count {
                songs = fullLibrary
            }
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func songsForAlbum(_ album: Song) -> [Song] {
        songs.filter { $0.album == album.album && $0.artists == album.artists }
    }
}

struct SynologySongCollectionView: View {
    @EnvironmentObject private var player: PlayerManager
    let title: String
    let songs: [Song]

    var body: some View {
        List {
            if !songs.isEmpty {
                Button {
                    ATMusicHaptics.tap()
                    player.play(songs: songs, startAt: 0)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
            }
            ForEach(Array(songs.enumerated()), id: \.element.identityKey) { index, song in
                SongCell(song: song, glassRow: false, playbackContext: songs, playbackIndex: index) {
                    player.play(songs: songs, startAt: index)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 今日推荐独立页面：保持当前推荐十分钟，支持右上角手动换一批。
struct SynologyRecommendationView: View {
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var synology = SynologyAPI.shared

    let initialSongs: [Song]
    @State private var songs: [Song]
    @State private var updatedAt = Date.distantPast
    @State private var isRefreshing = false
    @State private var refreshGeneration = 0

    init(initialSongs: [Song]) {
        self.initialSongs = initialSongs
        _songs = State(initialValue: initialSongs)
    }

    var body: some View {
        List {
            if !songs.isEmpty {
                Button {
                    ATMusicHaptics.tap()
                    player.play(songs: songs, startAt: 0)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                }
                .buttonStyle(GlassPressButtonStyle(scale: 0.97))
            }
            ForEach(Array(songs.enumerated()), id: \.element.identityKey) { index, song in
                SongCell(song: song, glassRow: false, playbackContext: songs, playbackIndex: index) {
                    player.play(songs: songs, startAt: index)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .overlay {
            if isRefreshing && songs.isEmpty { LoadingStateView() }
        }
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .navigationTitle("今日推荐")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refresh(force: true) }
                } label: {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
            }
        }
        .task {
            await refresh(force: false)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 600_000_000_000)
                    await refresh(force: true)
                } catch {
                    break
                }
            }
        }
    }

    private func refresh(force: Bool) async {
        guard synology.isLoggedIn else { return }
        guard force || songs.isEmpty || Date().timeIntervalSince(updatedAt) >= 600 else { return }

        await MainActor.run { isRefreshing = true }
        defer { Task { @MainActor in isRefreshing = false } }

        // 先立即换一批，点击按钮时不会因为 NAS 网络请求而看起来“没反应”。
        if force, !songs.isEmpty {
            let immediateSongs = Array(songs.shuffled().prefix(20))
            await MainActor.run {
                songs = immediateSongs
                updatedAt = Date()
                refreshGeneration += 1
            }
        }

        // 手动刷新跳过十分钟缓存，后台拿最新目录后再更新一次推荐。
        guard let library = try? await synology.librarySongs(forceRefresh: force), !library.isEmpty else { return }
        let refreshedSongs = Array(library.shuffled().prefix(20))
        await MainActor.run {
            songs = refreshedSongs
            updatedAt = Date()
            refreshGeneration += 1
        }
    }
}

/// 歌单全部页面：用 Apple Music 风格的封面列表和顶部搜索栏展示。
struct SynologyPlaylistCollectionView: View {
    @ObservedObject private var synology = SynologyAPI.shared

    @State private var playlists: [Playlist]
    @State private var previewSongs: [String: Song] = [:]
    @State private var query = ""

    init(playlists: [Playlist]) {
        _playlists = State(initialValue: playlists)
    }

    private var filteredPlaylists: [Playlist] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return playlists }
        return playlists.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
    }

    var body: some View {
        List {
            ForEach(filteredPlaylists) { playlist in
                NavigationLink { PlaylistView(playlist: playlist) } label: {
                    let playlistID = playlist.synologyPlaylistId ?? "\(playlist.id)"
                    SynologyLibraryRow(
                        coverURL: previewSongs[playlistID]?.coverURL ?? playlist.coverURL,
                        title: playlist.name,
                        subtitle: "\(playlist.trackCount) 首",
                        systemImage: "music.note.list"
                    )
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .overlay {
            if playlists.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.atmusicComment)
                    Text("暂无歌单")
                        .font(ATMusicFont.appFont(14))
                        .foregroundStyle(Color.atmusicComment)
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索歌单")
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .navigationTitle("歌单")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadPreviews() }
    }

    private func loadPreviews() async {
        guard synology.isLoggedIn else { return }
        await withTaskGroup(of: (String, Song?).self) { group in
            for playlist in playlists {
                let playlistID = playlist.synologyPlaylistId ?? "\(playlist.id)"
                group.addTask {
                    (playlistID, (try? await synology.playlistSongs(playlistId: playlistID, limit: 1))?.first)
                }
            }
            for await (playlistID, song) in group {
                if let song { previewSongs[playlistID] = song }
            }
        }
    }
}

/// 常听专辑全部页面：封面、专辑名、歌手和歌曲数保持统一行式排版。
struct SynologyAlbumCollectionView: View {
    let songs: [Song]
    @State private var query = ""

    private var albums: [Song] {
        var seen = Set<String>()
        let unique = songs.filter { seen.insert("\($0.album)|\($0.artists)").inserted && !$0.album.isEmpty }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return unique }
        return unique.filter { $0.album.localizedCaseInsensitiveContains(keyword) || $0.artists.localizedCaseInsensitiveContains(keyword) }
    }

    var body: some View {
        List {
            ForEach(albums) { album in
                NavigationLink {
                    SynologyAlbumView(albumName: album.album, artistName: album.artists, coverURL: album.coverURL)
                } label: {
                    SynologyLibraryRow(
                        coverURL: album.coverURL,
                        title: album.album,
                        subtitle: album.artists,
                        systemImage: "square.stack"
                    )
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .overlay {
            if albums.isEmpty {
                Text("暂无专辑")
                    .font(ATMusicFont.appFont(14))
                    .foregroundStyle(Color.atmusicComment)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索专辑")
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .navigationTitle("常听专辑")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 常听歌手全部页面：圆形头像列表，点击进入歌手详情。
struct SynologyArtistCollectionView: View {
    let songs: [Song]
    @State private var query = ""

    private var artists: [(name: String, song: Song)] {
        var seen = Set<String>()
        var result: [(name: String, song: Song)] = []
        for song in songs {
            for name in song.artists.components(separatedBy: " / ") {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
                result.append((trimmed, song))
            }
        }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return result }
        return result.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
    }

    var body: some View {
        List {
            ForEach(artists, id: \.name) { artist in
                NavigationLink {
                    SynologyArtistView(artistName: artist.name, coverURL: artist.song.coverURL, initialSongs: songs)
                } label: {
                    SynologyLibraryRow(
                        coverURL: artist.song.coverURL,
                        title: artist.name,
                        subtitle: "歌手",
                        circular: true,
                        systemImage: "person.crop.circle"
                    )
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .overlay {
            if artists.isEmpty {
                Text("暂无歌手")
                    .font(ATMusicFont.appFont(14))
                    .foregroundStyle(Color.atmusicComment)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索歌手")
        .atmusicScrollContentBackgroundHidden()
        .listStyle(.plain)
        .navigationTitle("常听歌手")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SynologySquareTile: View {
    let coverURL: URL?
    let title: String
    let subtitle: String
    var circularCover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { proxy in
                CoverImage(url: coverURL, size: proxy.size.width, cornerRadius: circularCover ? proxy.size.width / 2 : 10)
            }
            .aspectRatio(1, contentMode: .fit)
            Text(title)
                .font(ATMusicFont.appFont(13, .medium))
                .foregroundStyle(Color.atmusicLabel)
                .lineLimit(1)
            Text(subtitle)
                .font(ATMusicFont.appFont(11))
                .foregroundStyle(Color.atmusicComment)
                .lineLimit(1)
        }
    }
}

private struct SynologyLibraryRow: View {
    let coverURL: URL?
    let title: String
    let subtitle: String
    var circular = false
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                CoverImage(url: coverURL, size: 46, cornerRadius: circular ? 23 : 10)
                if coverURL == nil {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                        .padding(7)
                        .background { ATMusicGlass(shape: Circle()) }
                        .offset(x: 3, y: 3)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(ATMusicFont.appFont(15, .medium))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(1)
                Text(subtitle)
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.atmusicComment)
        }
        .frame(minHeight: 64)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.atmusicComment.opacity(0.18))
                .frame(height: 0.5)
                .padding(.leading, 58)
        }
    }
}

private enum SynologyLibraryCategory: String, CaseIterable, Identifiable {
    case playlists = "歌单"
    case folders = "文件夹"
    case artists = "歌手"

    var id: String { rawValue }
}

/// DS audio 风格的 NAS 音乐库入口：分类保留，默认从文件夹开始浏览。
struct SynologyLibrarySection: View {
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var synology = SynologyAPI.shared

    @State private var category: SynologyLibraryCategory = .folders
    @State private var folderItems: [SynologyFolderItem] = []
    @State private var folderPreviewSongs: [String: Song] = [:]
    @State private var songs: [Song] = []
    @State private var playlists: [Playlist] = []
    @State private var playlistPreviewSongs: [String: Song] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(categoryRaw: String = "文件夹") {
        _category = State(initialValue: SynologyLibraryCategory(rawValue: categoryRaw) ?? .folders)
    }

    private var albums: [Song] {
        var seen = Set<String>()
        return songs.filter { seen.insert("\($0.album)|\($0.artists)").inserted }
    }

    private var artists: [(name: String, coverURL: URL?)] {
        var seen = Set<String>()
        return songs.flatMap { song in
            song.artists.components(separatedBy: " / ").map { (name: $0, coverURL: song.coverURL) }
        }.filter {
            !$0.name.isEmpty && seen.insert($0.name).inserted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !synology.isLoggedIn {
                Text("请前往“我的” → “账号与登录”连接群晖 NAS")
                    .font(ATMusicFont.appFont(13))
                    .foregroundStyle(Color.atmusicComment)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 20)
            } else {
                Picker("音乐库", selection: $category) {
                    ForEach(SynologyLibraryCategory.allCases) { category in
                        Text(category.rawValue).tag(category)
                    }
                }
                .pickerStyle(.segmented)
                if isLoading && songs.isEmpty && folderItems.isEmpty && playlists.isEmpty {
                    LoadingStateView()
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if let errorMessage, songs.isEmpty && folderItems.isEmpty && playlists.isEmpty {
                    ErrorStateView(message: errorMessage) { Task { await load() } }
                } else {
                    categoryContent
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch category {
                case .folders:
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "音乐文件夹")
                ForEach(folderItems) { item in
                    if item.kind == .folder {
                        NavigationLink {
                            SynologyFolderView(
                                folderID: item.id,
                                title: item.name,
                                breadcrumbs: ["NAS", item.name]
                            )
                        } label: {
                            SynologyLibraryRow(
                                coverURL: folderPreviewSongs[item.id]?.coverURL,
                                title: item.name,
                                subtitle: "文件夹",
                                systemImage: "folder.fill"
                            )
                        }
                        .buttonStyle(.plain)
                    } else if let song = item.song {
                        SongCell(song: song, glassRow: false) {
                            player.play(songs: [song])
                        }
                    }
                }
                if folderItems.isEmpty {
                    Text("根目录没有可显示的文件夹")
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicComment)
                }
            }
        case .playlists:
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "歌单")
                ForEach(playlists) { playlist in
                    NavigationLink { PlaylistView(playlist: playlist) } label: {
                        let playlistID = playlist.synologyPlaylistId ?? "\(playlist.id)"
                        SynologyLibraryRow(
                            coverURL: playlistPreviewSongs[playlistID]?.coverURL ?? playlist.coverURL,
                            title: playlist.name,
                            subtitle: "\(playlist.trackCount) 首",
                            systemImage: "music.note.list"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        case .artists:
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "歌手")
                ForEach(artists, id: \.name) { artist in
                    NavigationLink {
                        SynologyArtistView(artistName: artist.name, coverURL: artist.coverURL, initialSongs: songs)
                    } label: {
                        SynologyLibraryRow(
                            coverURL: artist.coverURL,
                            title: artist.name,
                            subtitle: "歌手",
                            circular: true,
                            systemImage: "person.crop.circle"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func load() async {
        guard synology.isLoggedIn else { return }
        isLoading = true
        errorMessage = nil
        do {
            async let root = synology.folderItems(limit: 200)
            async let allSongs = synology.songs(offset: 0, limit: 1000)
            async let loadedPlaylists = synology.allPlaylists()
            let (newRoot, newSongs, newPlaylists) = try await (root, allSongs, loadedPlaylists)
            folderItems = newRoot
            songs = newSongs
            playlists = newPlaylists
            var previews: [String: Song] = [:]
            await withTaskGroup(of: (String, Song?).self) { group in
                for item in newRoot where item.kind == .folder {
                    group.addTask {
                        (item.id, (try? await synology.folderItems(folderID: item.id, limit: 1))?.compactMap(\.song).first)
                    }
                }
                for await (folderID, song) in group {
                    if let song { previews[folderID] = song }
                }
            }
            folderPreviewSongs = previews
            var playlistPreviews: [String: Song] = [:]
            await withTaskGroup(of: (String, Song?).self) { group in
                for playlist in newPlaylists {
                    let playlistID = playlist.synologyPlaylistId ?? "\(playlist.id)"
                    group.addTask {
                        (playlistID, (try? await synology.playlistSongs(playlistId: playlistID, limit: 1))?.first)
                    }
                }
                for await (playlistID, song) in group {
                    if let song { playlistPreviews[playlistID] = song }
                }
            }
            playlistPreviewSongs = playlistPreviews
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}

struct SynologyFolderView: View {
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var synology = SynologyAPI.shared

    let folderID: String?
    let title: String
    let breadcrumbs: [String]
    @State private var items: [SynologyFolderItem] = []

    init(folderID: String?, title: String, breadcrumbs: [String] = ["NAS"]) {
        self.folderID = folderID
        self.title = title
        self.breadcrumbs = breadcrumbs
    }
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var query = ""

    private var displayedItems: [SynologyFolderItem] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = keyword.isEmpty ? items : items.filter { item in
            if item.name.lowercased().contains(keyword) { return true }
            if let song = item.song {
                return song.name.lowercased().contains(keyword)
                    || song.artists.lowercased().contains(keyword)
                    || song.album.lowercased().contains(keyword)
            }
            return false
        }
        return filtered.sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                return lhs.kind == .folder
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var songs: [Song] {
        displayedItems.compactMap(\.song)
    }

    var body: some View {
        ZStack {
            GlassBackdrop()
            if !synology.isLoggedIn {
                EmptyStateView(icon: "externaldrive.badge.xmark", text: "请先在“我的”中连接群晖 NAS")
            } else if isLoading {
                LoadingStateView()
            } else if let errorMessage {
                ErrorStateView(message: errorMessage) { Task { await load() } }
            } else {
                List {
                    Section {
                        Text(breadcrumbs.joined(separator: " / "))
                            .font(ATMusicFont.appFont(11, .medium))
                            .foregroundStyle(Color.atmusicComment)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    if !songs.isEmpty {
                        Section {
                            HStack(spacing: 10) {
                                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                    player.play(songs: songs, startAt: 0)
                                }
                                GlassButton(title: "随机播放", systemName: "shuffle") {
                                    player.play(songs: songs.shuffled(), startAt: 0)
                                }
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }

                    Section {
                        ForEach(displayedItems) { item in
                            if item.kind == .folder {
                                NavigationLink {
                                    SynologyFolderView(
                                        folderID: item.id,
                                        title: item.name,
                                        breadcrumbs: breadcrumbs + [item.name]
                                    )
                                } label: {
                                    SynologyLibraryRow(
                                        coverURL: nil,
                                        title: item.name,
                                        subtitle: "文件夹",
                                        systemImage: "folder.fill"
                                    )
                                }
                                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            } else if let song = item.song {
                                let index = songs.firstIndex(of: song) ?? 0
                                SongCell(song: song, glassRow: false, playbackContext: songs, playbackIndex: index) {
                                    player.play(songs: songs, startAt: index)
                                }
                            }
                        }
                    }
                }
                .atmusicScrollContentBackgroundHidden()
                .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索当前文件夹")
        .task { if synology.isLoggedIn { await load() } }
    }

    private func load() async {
        guard synology.isLoggedIn else {
            isLoading = false
            return
        }
        isLoading = items.isEmpty
        errorMessage = nil
        do {
            items = try await synology.folderItems(folderID: folderID, limit: 500)
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}

/// NAS 歌手详情：使用歌手歌曲中的第一张封面作为头像，并把该歌手的专辑与歌曲分区展示。
struct SynologyArtistView: View {
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var synology = SynologyAPI.shared

    let artistName: String
    let coverURL: URL?
    let initialSongs: [Song]
    @State private var songs: [Song] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedSection: ArtistDetailSection = .songs

    private enum ArtistDetailSection: String, CaseIterable, Identifiable {
        case songs = "歌曲"
        case albums = "专辑"

        var id: String { rawValue }
    }

    init(artistName: String, coverURL: URL?, initialSongs: [Song] = []) {
        self.artistName = artistName
        self.coverURL = coverURL
        self.initialSongs = initialSongs
    }

    private var albums: [Song] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.album).inserted }
    }

    var body: some View {
        ZStack {
            if isLoading {
                LoadingStateView()
            } else if let errorMessage, songs.isEmpty {
                ErrorStateView(message: errorMessage) { Task { await load() } }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        artistHeader
                        Picker("歌手内容", selection: $selectedSection) {
                            ForEach(ArtistDetailSection.allCases) { section in
                                Text(section.rawValue).tag(section)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.top, 2)

                        if selectedSection == .songs {
                            songsSection
                        } else if !albums.isEmpty {
                            albumSection
                        } else {
                            Text("该歌手暂无专辑")
                                .font(ATMusicFont.appFont(13))
                                .foregroundStyle(Color.atmusicComment)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 36)
                }
                .atmusicScrollIndicatorsHidden()
            }
        }
        .navigationTitle(artistName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var artistHeader: some View {
        HStack(spacing: 14) {
            CoverImage(url: songs.first?.coverURL ?? coverURL, size: 84, cornerRadius: 42)
            VStack(alignment: .leading, spacing: 6) {
                Text(artistName)
                    .font(ATMusicFont.appFont(22, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                    .lineLimit(2)
                Text("\(albums.count) 张专辑 · \(songs.count) 首歌曲")
                    .font(ATMusicFont.appFont(13))
                    .foregroundStyle(Color.atmusicComment)
            }
            Spacer(minLength: 0)
        }
    }

    private var albumSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "专辑")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 16) {
                ForEach(albums) { album in
                    NavigationLink {
                        SynologyAlbumView(albumName: album.album, artistName: artistName, coverURL: album.coverURL)
                    } label: {
                        SynologySquareTile(coverURL: album.coverURL, title: album.album, subtitle: "\(songsForAlbum(album).count) 首")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var songsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "歌曲")
                Spacer()
            if !songs.isEmpty {
                    Button {
                        ATMusicHaptics.tap()
                        player.play(songs: songs, startAt: 0)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                            .font(ATMusicFont.appFont(12, .semibold))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    .buttonStyle(GlassPressButtonStyle(scale: 0.97))
                }
            }
            if songs.isEmpty {
                Text("该歌手暂无歌曲")
                    .font(ATMusicFont.appFont(13))
                    .foregroundStyle(Color.atmusicComment)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(songs.enumerated()), id: \.element.identityKey) { index, song in
                    SongCell(song: song, glassRow: false, playbackContext: songs, playbackIndex: index) {
                        player.play(songs: songs, startAt: index)
                    }
                    }
                }
            }
        }
    }

    private func songsForAlbum(_ album: Song) -> [Song] {
        songs.filter { $0.album == album.album }
    }

    private func load() async {
        guard synology.isLoggedIn else {
            isLoading = false
            errorMessage = "请先连接群晖 NAS"
            return
        }
        let names = [artistName, simplifiedArtistName(artistName)]
        let matches: ([Song]) -> [Song] = { source in
            source.filter { song in
                let songArtists = song.artists.components(separatedBy: " / ")
                return songArtists.contains { name in
                    names.contains { normalizedArtistName($0) == normalizedArtistName(name) }
                }
            }
        }

        // 从搜索结果、音乐库列表或首页传入的歌曲先展示，避免歌手页首屏等待完整 NAS 目录。
        let preview = matches(initialSongs)
        if !preview.isEmpty {
            songs = preview
            isLoading = false
        }

        do {
            let allSongs = try await synology.librarySongs()
            let loadedSongs = matches(allSongs)
            if !loadedSongs.isEmpty || preview.isEmpty {
                songs = loadedSongs
            }
            isLoading = false
        } catch {
            if preview.isEmpty {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func normalizedArtistName(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        let simplified = String(folded.map { character in
            switch character {
            case "倫": return "伦"; case "傑": return "杰"; case "華": return "华"; case "樂": return "乐"
            case "臺": return "台"; case "灣": return "湾"; case "國": return "国"; case "龍": return "龙"
            default: return character
            }
        })
        let compact = simplified.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        if compact == "jaychou" { return "周杰伦" }
        return compact
    }

    private func simplifiedArtistName(_ value: String) -> String {
        String(value.map { character in
            switch character {
            case "倫": return "伦"; case "傑": return "杰"; case "華": return "华"; case "樂": return "乐"
            case "臺": return "台"; case "灣": return "湾"; case "國": return "国"; case "龍": return "龙"
            default: return character
            }
        })
    }
}

/// NAS 专辑详情，结构与 Apple Music 的专辑页一致：头部封面、播放操作、歌曲列表。
struct SynologyAlbumView: View {
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var synology = SynologyAPI.shared

    let albumName: String
    let artistName: String
    let coverURL: URL?
    /// 搜索页打开专辑时传入的首批歌曲，用于先渲染详情页，避免等待完整 NAS 索引。
    var initialSongs: [Song] = []
    @State private var tracks: [Song] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            if isLoading {
                LoadingStateView()
            } else if let errorMessage, tracks.isEmpty {
                ErrorStateView(message: errorMessage) { Task { await load() } }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        albumHeader
                        if !tracks.isEmpty {
                            HStack(spacing: 10) {
                                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                    player.play(songs: tracks, startAt: 0)
                                }
                                GlassButton(title: "随机播放", systemName: "shuffle") {
                                    player.play(songs: tracks, startAt: Int.random(in: 0..<tracks.count))
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "歌曲")
                            ForEach(Array(tracks.enumerated()), id: \.element.identityKey) { index, song in
                                SongCell(song: song, glassRow: false, playbackContext: tracks, playbackIndex: index) {
                                    player.play(songs: tracks, startAt: index)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 36)
                }
                .atmusicScrollIndicatorsHidden()
            }
        }
        .navigationTitle(albumName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var albumHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 16) {
                CoverImage(url: tracks.first?.coverURL ?? coverURL, size: 170, cornerRadius: 12)
                VStack(alignment: .leading, spacing: 7) {
                    Text(albumName)
                        .font(ATMusicFont.appFont(24, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(3)
                    Text(artistName.isEmpty ? "未知歌手" : artistName)
                        .font(ATMusicFont.appFont(15, .medium))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(2)
                    Text("\(tracks.count) 首歌曲")
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicComment)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
        }
    }

    private func load() async {
        guard synology.isLoggedIn else {
            isLoading = false
            errorMessage = "请先连接群晖 NAS"
            return
        }
        let seededTracks = matchingSongs(in: initialSongs)
        if !seededTracks.isEmpty {
            await MainActor.run {
                tracks = seededTracks
                isLoading = false
                errorMessage = nil
            }
        }
        do {
            let allSongs = try await synology.librarySongs()
            var matches = matchingSongs(in: allSongs)
            if matches.isEmpty {
                // 某些 DSM 版本的完整歌曲接口字段不全，使用专辑搜索结果兜底，
                // 并允许同一张专辑的歌手字段存在简繁体或合作艺人差异。
                let remote = try? await synology.searchAllVariants(keyword: albumName, limit: 200)
                matches = matchingSongs(in: remote?.songs ?? [])
                if matches.isEmpty {
                    let normalizedAlbum = normalize(albumName)
                    matches = (remote?.songs ?? []).filter { normalize($0.album) == normalizedAlbum }
                }
            }
            await MainActor.run {
                if !matches.isEmpty || seededTracks.isEmpty {
                    tracks = matches
                }
                isLoading = false
                errorMessage = tracks.isEmpty ? "未找到专辑歌曲" : nil
            }
        } catch {
            await MainActor.run {
                // 已经有搜索结果时保留首屏内容，不因后台目录刷新失败而把详情页变成错误页。
                isLoading = false
                if tracks.isEmpty {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func matchingSongs(in songs: [Song]) -> [Song] {
        let normalizedAlbum = normalize(albumName)
        let normalizedArtist = normalize(artistName)
        guard !normalizedAlbum.isEmpty else { return [] }
        let albumMatches = songs.filter { normalize($0.album) == normalizedAlbum }
        guard !albumMatches.isEmpty else { return [] }
        guard !normalizedArtist.isEmpty else { return albumMatches }
        let artistMatches = albumMatches.filter {
            let actualArtist = normalize($0.artists)
            return actualArtist.contains(normalizedArtist) || normalizedArtist.contains(actualArtist)
        }
        return artistMatches.isEmpty ? albumMatches : artistMatches
    }

    private func normalize(_ value: String) -> String {
        let simplified = value.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? value
        return simplified
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
