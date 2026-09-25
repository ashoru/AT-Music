import SwiftUI
import AVFoundation
import CryptoKit
import UniformTypeIdentifiers
import UIKit

// MARK: - 本地音乐库区块（音乐库页面顶部：本机歌单，可新建 / 播放 / 添加歌曲）

struct LocalMusicSection: View {
    fileprivate enum SyncTarget: String, CaseIterable, Identifiable {
        case netease = "网易云音乐"
        case qq = "QQ音乐"
        case kugou = "酷狗音乐"

        var id: String { rawValue }
    }

    @ObservedObject private var store = LocalLibraryStore.shared
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var theme: ThemeStore
    @AppStorage("atmusic.language") private var languageRaw = AppLanguage.chinese.rawValue

    @State private var showCreate = false
    @State private var showPlaylistOrder = false
    @State private var newName = ""
    @State private var selected: LocalPlaylist?
    @State private var syncing = false
    @State private var syncMessage = ""
    @State private var showSyncPicker = false
    @State private var selectedSyncTargets: Set<SyncTarget> = []
    @State private var showAudioImporter = false
    @State private var showLocalManager = false
    @State private var importingAudio = false
    @State private var importMessage = ""
    @State private var selectedImportedSong: Song?

    private var emptyLocalPlaylistText: String {
        if languageRaw == AppLanguage.english.rawValue {
            return "No local playlists yet\nCreate a playlist and save favorite songs on this device"
        }
        return "还没有本地歌单\n新建一个歌单，把喜欢的歌曲收藏到本机"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("本地音乐库")
                    .font(ATMusicFont.appFont(21, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer(minLength: 8)
                Button {
                    newName = ""
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("新建本地歌单")
                .help("新建本地歌单")
                Button {
                    showPlaylistOrder = true
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("排序本地歌单")
                .help("排序本地歌单")
                Button {
                    showAudioImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("导入本地音乐")
                .help("导入本地音乐")
                Button {
                    showLocalManager = true
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.atmusicAmber)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("管理本地音乐")
                .help("管理本地音乐")
            }
            VStack(alignment: .leading, spacing: 6) {
                GlassButton(
                    title: syncing ? "正在同步歌单…" : "一键同步歌单",
                    systemName: "arrow.triangle.2.circlepath",
                    prominent: true
                ) {
                    showSyncPicker = true
                }
                .disabled(syncing)
                Text("选择两个或三个平台，合并同步到一个本地歌单")
                    .font(ATMusicFont.appFont(11))
                    .foregroundStyle(Color.atmusicComment)
            }
            if !syncMessage.isEmpty {
                Text(syncMessage)
                    .font(ATMusicFont.appFont(12, .medium))
                    .foregroundStyle(Color.atmusicSage)
            }
            if importingAudio {
                HStack(spacing: 8) {
                    ProgressView().tint(Color.atmusicAmber)
                    Text("正在导入本地音乐…")
                        .font(ATMusicFont.appFont(12))
                        .foregroundStyle(Color.atmusicComment)
                }
            } else if !importMessage.isEmpty {
                Text(importMessage)
                    .font(ATMusicFont.appFont(12, .medium))
                    .foregroundStyle(Color.atmusicSage)
            }
            if store.playlists.isEmpty {
                EmptyStateView(
                    icon: "internaldrive",
                    text: emptyLocalPlaylistText
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(store.playlists) { playlist in
                        Button {
                            selected = playlist
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(LinearGradient(colors: [Color.atmusicAmber.opacity(0.75), Color.atmusicAmber.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 56, height: 56)
                                    Image(systemName: "music.note.list")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(playlist.name)
                                        .font(ATMusicFont.appFont(15, .medium))
                                        .foregroundStyle(Color.atmusicLabel)
                                        .lineLimit(1)
                                    Text(atmusicLocalSongCountText(playlist.songs.count))
                                        .font(ATMusicFont.appFont(12))
                                        .foregroundStyle(Color.atmusicComment)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.atmusicComment.opacity(0.6))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                store.movePlaylist(id: playlist.id, offset: -1)
                            } label: {
                                Label("移到前面", systemImage: "arrow.up")
                            }
                            Button {
                                store.movePlaylist(id: playlist.id, offset: 1)
                            } label: {
                                Label("移到后面", systemImage: "arrow.down")
                            }
                            Button(role: .destructive) {
                                ATMusicHaptics.tap()
                                store.deletePlaylist(id: playlist.id)
                                ToastCenter.shared.show("已删除本地歌单")
                            } label: {
                                Label("删除歌单", systemImage: "trash")
                            }
                        }
                        Divider().overlay(Color.atmusicComment.opacity(0.12))
                    }
                }
                .padding(.vertical, 6)
                .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)) }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .atmusicCardShadow(radius: 8, y: 3)
            }
            if !store.importedSongs.isEmpty {
                importedSongsSection
            }
        }
        .alert("新建本地歌单", isPresented: $showCreate) {
            TextField("歌单名称", text: $newName)
            Button("创建") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                let playlist = store.createPlaylist(name: name)
                selected = playlist
                newName = ""
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本地歌单保存在设备上，覆盖安装不会丢失，不依赖平台账号")
        }
        .sheet(isPresented: $showSyncPicker) {
            SyncPlatformPicker(
                selectedTargets: $selectedSyncTargets,
                onCancel: {
                    showSyncPicker = false
                },
                onConfirm: {
                    let targets = selectedSyncTargets
                    showSyncPicker = false
                    Task { await sync(targets: targets) }
                }
            )
        }
        .sheet(isPresented: $showPlaylistOrder) {
            LocalPlaylistOrderSheet()
                .environmentObject(theme)
        }
        .sheet(item: $selected) { playlist in
            LocalPlaylistDetailSheet(playlistID: playlist.id)
                .environmentObject(player)
                .environmentObject(auth)
        }
        .sheet(isPresented: $showAudioImporter) {
            LocalAudioDocumentPicker { urls in
                showAudioImporter = false
                importAudio(urls)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showLocalManager) {
            LocalMusicManagementSheet()
                .environmentObject(player)
                .environmentObject(theme)
        }
        .sheet(item: $selectedImportedSong) { song in
            AddToLocalPlaylistSheet(song: song)
                .environmentObject(theme)
        }
    }

    private var importedSongsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("本地歌曲")
                    .font(ATMusicFont.appFont(18, .bold))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                Text("\(store.importedSongs.count) 首")
                    .font(ATMusicFont.appFont(12))
                    .foregroundStyle(Color.atmusicComment)
            }
            VStack(spacing: 0) {
                ForEach(Array(store.importedSongs.enumerated()), id: \.element.identityKey) { index, song in
                    SongCell(song: song, glassRow: true, playbackContext: store.importedSongs, playbackIndex: index) {
                        player.play(songs: store.importedSongs, startAt: index)
                    }
                    .contextMenu {
                        Button {
                            selectedImportedSong = song
                        } label: {
                            Label("加入本地歌单", systemImage: "plus.circle")
                        }
                        Button(role: .destructive) {
                            if store.removeImportedSong(song) {
                                ToastCenter.shared.show("已删除本地歌曲副本")
                            } else {
                                ToastCenter.shared.show("删除失败，歌曲记录已保留")
                            }
                        } label: {
                            Label("删除本地歌曲副本", systemImage: "trash")
                        }
                    }
                    Divider().overlay(Color.atmusicComment.opacity(0.12))
                }
            }
            .padding(.vertical, 6)
            .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)) }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .atmusicCardShadow(radius: 8, y: 3)
        }
    }

    private func importAudio(_ urls: [URL]) {
        guard !urls.isEmpty, !importingAudio else { return }
        importingAudio = true
        importMessage = ""
        Task {
            let report = await LocalAudioImportService.shared.importFiles(urls)
            await MainActor.run {
                store.addImportedSongs(report.songs)
                importingAudio = false
                importMessage = report.message
                if !report.songs.isEmpty { ATMusicHaptics.success() }
                ToastCenter.shared.show(report.message)
            }
        }
    }

    private func sync(targets: Set<SyncTarget>) async {
        guard !syncing else { return }
        guard targets.count >= 2 else {
            ToastCenter.shared.show("至少选择两个平台")
            return
        }
        syncing = true
        syncMessage = ""
        var songs: [Song] = []
        var details: [String] = []
        if targets.contains(.netease), let user = auth.user, auth.isLoggedIn {
            do {
                let lists = try await NetEaseAPI.shared.userPlaylists(uid: user.uid)
                let liked = lists.first { list in
                    let name = list.name.replacingOccurrences(of: " ", with: "")
                    return name.contains("喜欢") || name.contains("我喜欢")
                }
                if let liked {
                    let neteaseSongs = try await NetEaseAPI.shared.playlistTracks(id: liked.id)
                    songs.append(contentsOf: neteaseSongs)
                    details.append(platformSongCount("网易云", neteaseSongs.count))
                } else {
                    details.append(NSLocalizedString("网易云未找到喜欢歌单", comment: ""))
                }
            } catch {
                ATMusicLogger.shared.log("三平台同步：网易云失败 \(error.localizedDescription)", level: .error)
                details.append(NSLocalizedString("网易云请求失败", comment: ""))
            }
        } else if targets.contains(.netease) {
            details.append(NSLocalizedString("网易云未登录", comment: ""))
        }
        if targets.contains(.netease), !favorites.neteaseFavoriteSongs.isEmpty {
            let cachedIDs = Set(songs.filter { $0.source == .netease }.map(\.id))
            let cached = favorites.neteaseFavoriteSongs.filter { !cachedIDs.contains($0.id) }
            songs.append(contentsOf: cached)
            if !cached.isEmpty { details.append(String(format: NSLocalizedString("网易云缓存补充 %d 首", comment: ""), cached.count)) }
        }
        if targets.contains(.qq), QQMusicAuth.shared.isLoggedIn {
            do {
                let qqSongs = try await QQMusicAPI.shared.favoriteSongs(limit: 0)
                songs.append(contentsOf: qqSongs)
                details.append(platformSongCount("QQ音乐", qqSongs.count))
            } catch {
                ATMusicLogger.shared.log("三平台同步：QQ音乐失败 \(error.localizedDescription)", level: .error)
                details.append(NSLocalizedString("QQ音乐请求失败", comment: ""))
            }
        } else if targets.contains(.qq) {
            details.append(NSLocalizedString("QQ音乐未登录", comment: ""))
        }
        if targets.contains(.kugou), KugouMusicAuth.shared.isLoggedIn {
            do {
                let lists = try await KugouMusicAPI.shared.userPlaylists()
                ATMusicLogger.shared.log("三平台同步：酷狗歌单 \(lists.map(\.name).joined(separator: "|"))", level: .info)
                let liked = lists.first { list in
                    let name = list.name.replacingOccurrences(of: " ", with: "")
                    return name.contains("喜欢") || name.contains("收藏") || name.contains("红心")
                }
                if let liked {
                    let kugouSongs = try await KugouMusicAPI.shared.playlistSongs(listID: liked.id)
                    songs.append(contentsOf: kugouSongs)
                    details.append(platformSongCount("酷狗音乐", kugouSongs.count))
                } else {
                    details.append(NSLocalizedString("酷狗音乐未找到喜欢歌单", comment: ""))
                }
            } catch {
                ATMusicLogger.shared.log("三平台同步：酷狗音乐失败 \(error.localizedDescription)", level: .error)
                details.append(NSLocalizedString("酷狗音乐请求失败", comment: ""))
            }
        } else if targets.contains(.kugou) {
            details.append(NSLocalizedString("酷狗音乐未登录", comment: ""))
        }
        var unique: [Song] = []
        var seen = Set<String>()
        for song in songs where seen.insert(song.identityKey).inserted { unique.append(song) }
        let playlistName: String
        playlistName = targets
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.rawValue)
            .joined(separator: " + ") + "喜欢"
        let added = store.syncSongs(unique, intoPlaylistNamed: playlistName)
        syncing = false
        syncMessage = details.joined(separator: NSLocalizedString("，", comment: "")) + String(format: NSLocalizedString("；合计 %d 首", comment: ""), unique.count)
        ToastCenter.shared.show(unique.isEmpty ? NSLocalizedString("没有获取到该平台的喜欢歌曲", comment: "") : String(format: NSLocalizedString("已同步 %d 首，新增 %d 首到本地歌单“%@”", comment: ""), unique.count, added, playlistName))
    }

    private func platformSongCount(_ platform: String, _ count: Int) -> String {
        String(format: NSLocalizedString("%@ %d 首", comment: ""), NSLocalizedString(platform, comment: ""), count)
    }
}

private struct LocalPlaylistOrderSheet: View {
    @ObservedObject private var store = LocalLibraryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .active

    var body: some View {
        ATMusicNavigationStack {
            List {
                ForEach(store.playlists) { playlist in
                    HStack(spacing: 12) {
                        Image(systemName: "music.note.list")
                            .foregroundStyle(Color.atmusicAmber)
                        Text(playlist.name)
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        Text(atmusicLocalSongCountText(playlist.songs.count))
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicComment)
                    }
                }
                .onMove { offsets, destination in
                    store.movePlaylists(from: offsets, to: destination)
                }
            }
            .environment(\.editMode, $editMode)
            .listStyle(.plain)
            .atmusicScrollContentBackgroundHidden()
            .navigationTitle("歌单排序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

fileprivate struct SyncPlatformPicker: View {
    @Binding var selectedTargets: Set<LocalMusicSection.SyncTarget>
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var canConfirm: Bool {
        selectedTargets.count >= 2
    }

    var body: some View {
        ATMusicNavigationStack {
            List {
                Section {
                    ForEach(LocalMusicSection.SyncTarget.allCases) { target in
                        Toggle(isOn: Binding(
                            get: { selectedTargets.contains(target) },
                            set: { isSelected in
                                if isSelected {
                                    selectedTargets.insert(target)
                                } else {
                                    selectedTargets.remove(target)
                                }
                            }
                        )) {
                            Label(target.rawValue, systemImage: icon(for: target))
                        }
                    }
                } header: {
                    Text("同步平台")
                } footer: {
                    Text(LocalizedStringKey(canConfirm ? "所选平台的喜欢歌曲会合并到同一个本地歌单。" : "至少选择两个平台。"))
                }
            }
            .navigationTitle("一键同步歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始同步", action: onConfirm)
                        .disabled(!canConfirm)
                }
            }
        }
        .onAppear {
            selectedTargets = []
        }
    }

    private func icon(for target: LocalMusicSection.SyncTarget) -> String {
        switch target {
        case .netease: return "music.note"
        case .qq: return "q.circle"
        case .kugou: return "dog"
        }
    }
}

// MARK: - 本地歌单详情（播放全部 / 单曲播放 / 移除歌曲 / 添加歌曲）

struct LocalPlaylistDetailSheet: View {
    @ObservedObject private var store = LocalLibraryStore.shared
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss

    let playlistID: UUID

    @State private var showSearchAdd = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var playlistSearchText = ""
    @State private var multiSelectMode = false
    @State private var selectedSongKeys: Set<String> = []
    @State private var showAddSelectedDestination = false

    private var playlist: LocalPlaylist? {
        store.playlists.first { $0.id == playlistID }
    }

    private var visibleSongs: [(offset: Int, element: Song)] {
        guard let playlist else { return [] }
        let keyword = playlistSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let songs = Array(playlist.songs.enumerated())
        guard !keyword.isEmpty else { return songs }
        return songs.filter { _, song in
            song.name.lowercased().contains(keyword)
                || song.artists.lowercased().contains(keyword)
                || song.album.lowercased().contains(keyword)
        }
    }

    var body: some View {
        ATMusicNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                Group {
                if let playlist {
                    List {
                        Section {
                            HStack(spacing: 12) {
                                GlassButton(title: "播放全部", systemName: "play.fill", prominent: true) {
                                    let songs = store.playbackSongs(for: playlistID)
                                    guard !songs.isEmpty else { return }
                                    player.play(songs: songs, startAt: 0)
                                }
                                GlassButton(title: "随机播放", systemName: "shuffle") {
                                    let songs = store.playbackSongs(for: playlistID)
                                    guard !songs.isEmpty else { return }
                                    player.play(songs: songs.shuffled(), startAt: 0)
                                }
                            }
                        }
                        .listRowBackground(Color.clear)
                        Section {
                            if visibleSongs.isEmpty {
                                EmptyStateView(icon: "magnifyingglass", text: "没有找到匹配歌曲")
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                            } else {
                                ForEach(visibleSongs, id: \.element.identityKey) { index, song in
                                    if multiSelectMode {
                                        HStack(spacing: 10) {
                                            Image(systemName: selectedSongKeys.contains(song.identityKey) ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 20, weight: .semibold))
                                                .foregroundStyle(selectedSongKeys.contains(song.identityKey) ? Color.atmusicAmber : Color.atmusicComment)
                                            SongCell(song: song, glassRow: true) {
                                                toggleSelection(song)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            toggleSelection(song)
                                        }
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                    } else {
                                        let resolvedSongs = store.playbackSongs(for: playlistID)
                                        SongCell(song: song, glassRow: true, playbackContext: resolvedSongs, playbackIndex: index) {
                                            player.play(songs: resolvedSongs, startAt: index)
                                        }
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .swipeActions(edge: .trailing) {
                                            Button(role: .destructive) {
                                                ATMusicHaptics.tap()
                                                store.removeSong(playlistID: playlistID, songIdentity: song.identityKey)
                                            } label: {
                                                Label("移除", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .atmusicScrollContentBackgroundHidden()
                    .listStyle(.plain)
                    .searchable(text: $playlistSearchText, placement: .navigationBarDrawer(displayMode: .always), prompt: LocalizedStringKey("搜索本地歌单歌曲"))
                } else {
                    EmptyStateView(icon: "music.note.list", text: "歌单不存在或已删除")
                }
            }
            }
            .navigationTitle(playlist?.name ?? "本地歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            multiSelectMode.toggle()
                            if !multiSelectMode {
                                selectedSongKeys.removeAll()
                            }
                        } label: {
                            Label(multiSelectMode ? "退出多选" : "多选编辑", systemImage: multiSelectMode ? "xmark.circle" : "checklist")
                        }
                        if multiSelectMode {
                            Button(role: .destructive) {
                                removeSelectedSongs()
                            } label: {
                                Label("移除选中歌曲", systemImage: "trash")
                            }
                            .disabled(selectedSongKeys.isEmpty)
                            Button {
                                showAddSelectedDestination = true
                            } label: {
                                Label("添加到其他本地歌单", systemImage: "folder.badge.plus")
                            }
                            .disabled(selectedSongKeys.isEmpty || !hasOtherPlaylist)
                        }
                        Button {
                            if let song = player.currentSong {
                                store.addSong(song, to: playlistID)
                                ATMusicHaptics.success()
                                ToastCenter.shared.show("已加入本地歌单")
                            } else {
                                ToastCenter.shared.show("当前没有播放中的歌曲")
                            }
                        } label: {
                            Label("添加当前播放歌曲", systemImage: "plus.circle")
                        }
                        Button {
                            showSearchAdd = true
                        } label: {
                            Label("搜索添加歌曲", systemImage: "magnifyingglass")
                        }
                        Menu("播放来源") {
                            ForEach(PlaylistSourceStrategy.allCases) { strategy in
                                Button {
                                    store.setSourceStrategy(strategy, for: playlistID)
                                } label: {
                                    Label(strategy.title, systemImage: playlist?.sourceStrategy == strategy ? "checkmark" : "circle")
                                }
                            }
                        }
                        Button {
                            renameText = playlist?.name ?? ""
                            showRename = true
                        } label: {
                            Label("重命名歌单", systemImage: "pencil")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
            }
        }
        .sheet(isPresented: $showSearchAdd) {
            LocalSearchAddSheet(playlistID: playlistID)
                .environmentObject(player)
                .environmentObject(auth)
        }
        .alert("重命名歌单", isPresented: $showRename) {
            TextField("歌单名称", text: $renameText)
            Button("保存") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                store.renamePlaylist(id: playlistID, name: name)
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "添加 \(selectedSongKeys.count) 首歌曲到其他本地歌单",
            isPresented: $showAddSelectedDestination,
            titleVisibility: .visible
        ) {
            ForEach(store.playlists.filter { $0.id != playlistID }) { target in
                Button(target.name) {
                    addSelectedSongs(to: target.id)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已选歌曲会复制到目标歌单，当前歌单中的歌曲不会被移除。")
        }
        .modifier(ATMusicSheetModifier(detents: [.medium, .large], dragIndicator: true))
    }

    private var hasOtherPlaylist: Bool {
        store.playlists.contains { $0.id != playlistID }
    }

    private func toggleSelection(_ song: Song) {
        ATMusicHaptics.select()
        if selectedSongKeys.contains(song.identityKey) {
            selectedSongKeys.remove(song.identityKey)
        } else {
            selectedSongKeys.insert(song.identityKey)
        }
    }

    private func removeSelectedSongs() {
        guard !selectedSongKeys.isEmpty else { return }
        let count = selectedSongKeys.count
        selectedSongKeys.forEach { key in
            store.removeSong(playlistID: playlistID, songIdentity: key)
        }
        selectedSongKeys.removeAll()
        multiSelectMode = false
        ATMusicHaptics.success()
        ToastCenter.shared.show("已移除 \(count) 首歌曲")
    }

    private func addSelectedSongs(to destinationID: UUID) {
        guard let playlist else { return }
        let songs = playlist.songs.filter { selectedSongKeys.contains($0.identityKey) }
        let added = store.addSongs(songs, to: destinationID)
        selectedSongKeys.removeAll()
        multiSelectMode = false
        ATMusicHaptics.success()
        let targetName = store.playlists.first(where: { $0.id == destinationID })?.name ?? "目标歌单"
        ToastCenter.shared.show(added == songs.count
            ? "已添加 \(added) 首到「\(targetName)」"
            : "已添加 \(added) 首到「\(targetName)」（重复歌曲已跳过）")
    }
}

// MARK: - 本地歌单搜索添加（网易云 / QQ 音乐）

struct LocalSearchAddSheet: View {
    @ObservedObject private var store = LocalLibraryStore.shared
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    let playlistID: UUID
    @State private var keyword = ""
    @State private var results: [Song] = []
    @State private var searching = false
    @State private var provider: SearchProvider = .netease
    private var searchProviders: [SearchProvider] { platformPrefs.enabledSearchProviders }
    @State private var task: Task<Void, Never>?

    var body: some View {
        ATMusicNavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField(atmusicLocalized("输入歌名搜索", "Search by song title"), text: $keyword)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.atmusicGlassFill))
                        .submitLabel(.search)
                        .onSubmit { runSearch() }
                    Button {
                        runSearch()
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Color.atmusicAmber))
                    }
                }
                .padding(12)
                Picker("平台", selection: $provider) {
                    ForEach(searchProviders) { p in
                        Text(LocalizedStringKey(p.rawValue)).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                if searching {
                    Spacer()
                    ProgressView().tint(Color.atmusicAmber)
                    Spacer()
                } else if results.isEmpty {
                    Spacer()
                    Text("输入歌名搜索，点击结果加入本地歌单")
                        .font(ATMusicFont.appFont(13))
                        .foregroundStyle(Color.atmusicComment)
                    Spacer()
                } else {
                    List {
                        ForEach(Array(results.enumerated()), id: \.element.identityKey) { index, song in
                            SongCell(song: song, glassRow: true) {
                                store.addSong(song, to: playlistID)
                                ATMusicHaptics.success()
                                ToastCenter.shared.show("已加入本地歌单")
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("添加歌曲")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .modifier(ATMusicSheetModifier(detents: [.medium, .large], dragIndicator: true))
        .onAppear {
            provider = platformPrefs.ensureVisible(provider)
        }
        .onChange(of: platformPrefs.selectedRaw) { _, _ in
            let next = platformPrefs.ensureVisible(provider)
            if next != provider { provider = next }
        }
    }

    private func runSearch() {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        task?.cancel()
        task = Task {
            searching = true
            defer { if !Task.isCancelled { searching = false } }
            do {
                let songs: [Song]
                switch provider {
                case .netease:
                    songs = try await NetEaseAPI.shared.search(keyword: trimmed, limit: 30)
                case .qq:
                    songs = try await QQMusicAPI.shared.searchSongs(keyword: trimmed)
                case .kugou:
                    songs = try await KugouMusicAPI.shared.searchSongs(keyword: trimmed)
                case .synology:
                    songs = try await SynologyAPI.shared.search(keyword: trimmed, limit: 30)
                }
                guard !Task.isCancelled else { return }
                results = songs
            } catch {
                guard !Task.isCancelled else { return }
                ToastCenter.shared.show("搜索失败，请稍后再试")
            }
        }
    }

}


// MARK: - 加入本地歌单（播放页入口：选择已创建的本地歌单，或新建并加入）

struct AddToLocalPlaylistSheet: View {
    @ObservedObject private var store = LocalLibraryStore.shared
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss

    let song: Song
    @State private var showCreateField = false
    @State private var newName = ""
    @State private var message: String?

    var body: some View {
        let _ = theme.accent
        ATMusicNavigationStack {
            List {
                if store.playlists.isEmpty {
                    Text("还没有本地歌单，先创建一个吧")
                        .foregroundStyle(Color.atmusicComment)
                } else {
                    Section("选择本地歌单") {
                        ForEach(store.playlists) { playlist in
                            Button {
                                store.addSong(song, to: playlist.id)
                                ATMusicHaptics.success()
                                ToastCenter.shared.show("已加入「\(playlist.name)」")
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(LinearGradient(colors: [Color.atmusicAmber.opacity(0.75), Color.atmusicAmber.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                            .frame(width: 40, height: 40)
                                        Image(systemName: "music.note.list")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(.white)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name)
                                            .font(ATMusicFont.appFont(15, .medium))
                                            .foregroundStyle(Color.atmusicLabel)
                                            .lineLimit(1)
                                        Text(atmusicLocalSongCountText(playlist.songs.count))
                                            .font(ATMusicFont.appFont(11))
                                            .foregroundStyle(Color.atmusicComment)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 15))
                                        .foregroundStyle(Color.atmusicAmber)
                                }
                            }
                        }
                    }
                }

                if showCreateField {
                    Section("新建本地歌单") {
                        TextField("歌单名称", text: $newName)
                            .submitLabel(.done)
                        Button {
                            createAndAdd()
                        } label: {
                            Text("创建并加入")
                                .font(ATMusicFont.appFont(15, .semibold))
                                .foregroundStyle(Color.atmusicAmber)
                        }
                    }
                } else {
                    Section {
                        Button {
                            showCreateField = true
                        } label: {
                            Label("新建歌单并加入", systemImage: "plus.circle")
                        }
                    }
                }

                if let message {
                    Section {
                        Text(message)
                            .font(ATMusicFont.appFont(13))
                            .foregroundStyle(Color.atmusicSage)
                    }
                }
            }
            .navigationTitle("加入本地歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .modifier(ATMusicSheetModifier(detents: [.medium, .large], dragIndicator: true))
        .onAppear {
            if store.playlists.isEmpty {
                ToastCenter.shared.show(store.addToDefaultFavorites(song))
                ATMusicHaptics.success()
                dismiss()
            }
        }
    }

    private func createAndAdd() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let playlist = store.createPlaylist(name: name)
        store.addSong(song, to: playlist.id)
        ATMusicHaptics.success()
        ToastCenter.shared.show("已创建「\(name)」并加入")
        dismiss()
    }
}

// MARK: - 本地音乐管理

struct LocalMusicManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: PlayerManager
    @ObservedObject private var store = LocalLibraryStore.shared
    @State private var searchText = ""
    @State private var editingSong: Song?
    @State private var pendingDelete: Song?
    @State private var showDeleteConfirmation = false

    private var filteredSongs: [Song] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return store.importedSongs }
        return store.importedSongs.filter {
            $0.name.lowercased().contains(keyword)
                || $0.artists.lowercased().contains(keyword)
                || $0.album.lowercased().contains(keyword)
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    if filteredSongs.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "music.note")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                            Text(searchText.isEmpty ? "还没有本地歌曲" : "没有匹配的本地歌曲")
                                .foregroundStyle(.secondary)
                            Text(searchText.isEmpty ? "点击音乐库右上角的导入按钮添加音频" : "尝试搜索标题、歌手或专辑")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    } else {
                        ForEach(filteredSongs, id: \.identityKey) { song in
                            Button {
                                editingSong = song
                            } label: {
                                HStack(spacing: 12) {
                                    CoverImage(url: song.coverURL, size: 48, cornerRadius: 8)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(song.name)
                                            .foregroundStyle(Color.atmusicLabel)
                                            .lineLimit(1)
                                        Text("\(song.artists) · \(song.album)")
                                            .font(.caption)
                                            .foregroundStyle(Color.atmusicComment)
                                            .lineLimit(1)
                                        Text(song.formattedDuration)
                                            .font(.caption2)
                                            .foregroundStyle(Color.atmusicComment.opacity(0.8))
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.atmusicComment.opacity(0.55))
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                deleteButton(for: song)
                            }
                            .contextMenu {
                                Button {
                                    editingSong = song
                                } label: {
                                    Label("编辑标签和封面", systemImage: "pencil")
                                }
                                Button {
                                    let index = filteredSongs.firstIndex(where: { $0.identityKey == song.identityKey }) ?? 0
                                    player.play(songs: filteredSongs, startAt: index)
                                } label: {
                                    Label("播放", systemImage: "play.fill")
                                }
                                deleteButton(for: song)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("本地歌曲")
                        Spacer()
                        Text("\(store.importedSongs.count) 首")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("这里管理的是应用内副本。删除后不会影响原始文件，也不会删除平台上的歌曲。")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "搜索本地歌曲")
            .navigationTitle("本地音乐管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $editingSong) { song in
                LocalSongMetadataEditorSheet(song: song) { updated in
                    let saved = store.updateImportedSong(updated)
                    if saved { player.replaceSong(updated) }
                    return saved
                }
            }
            .confirmationDialog("删除本地歌曲？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("删除应用内副本", role: .destructive) {
                    guard let song = pendingDelete else { return }
                    if store.removeImportedSong(song) {
                        ToastCenter.shared.show("已删除本地歌曲副本")
                    } else {
                        ToastCenter.shared.show("删除失败，歌曲记录已保留")
                    }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("原始文件不会被删除，但应用内复制的音频、封面和歌词会移入回收隔离目录。")
            }
        }
    }

    @ViewBuilder
    private func deleteButton(for song: Song) -> some View {
        Button(role: .destructive) {
            pendingDelete = song
            showDeleteConfirmation = true
        } label: {
            Label("删除本地歌曲副本", systemImage: "trash")
        }
    }
}

struct LocalSongMetadataEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let song: Song
    let onSave: (Song) -> Bool

    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var albumArtist: String
    @State private var genre: String
    @State private var year: String
    @State private var comment: String
    @State private var coverURL: URL?
    @State private var coverData: Data?
    @State private var editingField: SongMetadataField?
    @State private var showCoverSearch = false
    @State private var saving = false
    @State private var message = ""

    init(song: Song, onSave: @escaping (Song) -> Bool) {
        self.song = song
        self.onSave = onSave
        _title = State(initialValue: song.name)
        _artist = State(initialValue: song.artists)
        _album = State(initialValue: song.album)
        _albumArtist = State(initialValue: song.albumArtist ?? "")
        _genre = State(initialValue: song.genre ?? "")
        _year = State(initialValue: song.year ?? "")
        _comment = State(initialValue: song.comment ?? "")
        _coverURL = State(initialValue: song.coverURL)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        MetadataStaticRow(title: "文件路径", value: song.localRelativePath ?? "未知", multiline: true)
                        MetadataStaticRow(title: "来源", value: "导入的本地音乐")
                        MetadataStaticRow(title: "格式", value: ((song.localRelativePath ?? "") as NSString).pathExtension.uppercased().isEmpty ? "音频文件" : ((song.localRelativePath ?? "") as NSString).pathExtension.uppercased())
                    }
                    .padding(.horizontal, 20).padding(.vertical, 18)
                    Divider().overlay(Color.atmusicSecondary.opacity(0.26))
                    localTagRows
                    if !message.isEmpty {
                        Text(message)
                            .font(ATMusicFont.appFont(12))
                            .foregroundStyle(Color.atmusicComment)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20).padding(.top, 14)
                    }
                    VStack(spacing: 10) {
                        Button(saving ? "保存中…" : "保存已修改的标签") { save() }
                            .font(ATMusicFont.appFont(15, .semibold))
                            .foregroundStyle(Color.atmusicLabel)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background {
                                ATMusicLiquidSelectionSurface(
                                    shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
                                    accent: .atmusicAmber
                                )
                            }
                            .buttonStyle(.plain)
                            .opacity(saving ? 0.55 : 1)
                            .disabled(saving)
                        Button("取消") { dismiss() }.foregroundStyle(Color.atmusicLabel)
                    }
                    .padding(20)
                }
                .padding(.top, 10)
            }
            .background(Color.atmusicBackground.ignoresSafeArea())
            .navigationTitle("歌曲信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
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
                coverURL = candidate.song.coverURL
                coverData = nil
            } onPickData: { data in
                coverData = data
                coverURL = nil
            }
        }
    }

    private var localTagRows: some View {
        VStack(spacing: 0) {
            Button { showCoverSearch = true } label: {
                HStack(spacing: 16) {
                    Text("封面").foregroundStyle(Color.atmusicComment)
                    Spacer()
                    Group {
                        if let coverData, let image = UIImage(data: coverData) {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            CoverImage(url: coverURL, size: 48, cornerRadius: 8)
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Image(systemName: "pencil").foregroundStyle(Color.atmusicComment)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
            .buttonStyle(.plain)
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
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func value(for field: SongMetadataField) -> String {
        switch field {
        case .title: return title
        case .artist: return artist
        case .album: return album
        case .albumArtist: return albumArtist
        case .genre: return genre
        case .year: return year
        case .comment: return comment
        }
    }

    private func set(_ value: String, for field: SongMetadataField) {
        switch field {
        case .title: title = value
        case .artist: artist = value
        case .album: album = value
        case .albumArtist: albumArtist = value
        case .genre: genre = value
        case .year: year = value
        case .comment: comment = value
        }
    }

    private func save() {
        saving = true
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
        var updatedCoverURL = coverURL
        do {
            if let coverData, let image = UIImage(data: coverData),
               let jpeg = image.jpegData(compressionQuality: 0.92),
               let relativePath = song.localRelativePath {
                let baseName = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
                let previousCoverURL = coverURL
                updatedCoverURL = try LocalAudioFileManager.shared.writeSupportData(
                    jpeg,
                    relativePath: "ATMusicAudio/Artwork/\(baseName)-\(UUID().uuidString).jpg"
                )
                if let previousCoverURL, previousCoverURL != updatedCoverURL {
                    LocalAudioFileManager.shared.removeManagedArtworkIfNeeded(previousCoverURL)
                }
            }
            let updated = Song(
                id: song.id,
                name: trimmedTitle,
                artists: trimmedArtist.isEmpty ? "未知艺术家" : trimmedArtist,
                album: trimmedAlbum.isEmpty ? "未知专辑" : trimmedAlbum,
                coverURL: updatedCoverURL,
                duration: song.duration,
                source: .local,
                localRelativePath: song.localRelativePath,
                albumArtist: albumArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : albumArtist.trimmingCharacters(in: .whitespacesAndNewlines),
                genre: genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : genre.trimmingCharacters(in: .whitespacesAndNewlines),
                year: year.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : year.trimmingCharacters(in: .whitespacesAndNewlines),
                comment: comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : comment.trimmingCharacters(in: .whitespacesAndNewlines),
                fee: song.fee
            )
            guard onSave(updated) else {
                saving = false
                message = "保存失败：本地音乐库未能读回新标签"
                return
            }
            if let updatedCoverURL, updatedCoverURL.isFileURL,
               !FileManager.default.fileExists(atPath: updatedCoverURL.path) {
                saving = false
                message = "保存失败：新封面文件校验失败"
                return
            }
            ATMusicHaptics.success()
            ToastCenter.shared.show("本地歌曲信息已更新")
            dismiss()
        } catch {
            saving = false
            message = "保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 本地音频导入

struct LocalAudioImportReport: Sendable {
    let songs: [Song]
    let importedCount: Int
    let duplicateCount: Int
    let failedCount: Int

    var message: String {
        "已导入 \(importedCount) 首，重复 \(duplicateCount) 首，失败 \(failedCount) 首"
    }
}

final class LocalAudioImportService: @unchecked Sendable {
    static let shared = LocalAudioImportService()
    private let manager = LocalAudioFileManager.shared
    private let supportedExtensions: Set<String> = ["mp3", "m4a", "mp4", "aac", "alac", "flac", "wav", "aiff", "aif"]

    private init() {}

    func importFiles(_ urls: [URL]) async -> LocalAudioImportReport {
        var songs: [Song] = []
        var duplicateCount = 0
        var failedCount = 0
        for url in urls {
            do {
                guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
                    throw LibraryStorageError.unsupportedSchema
                }
                let hash = try sha256(of: url)
                if manager.findDuplicate(sha256: hash) != nil {
                    duplicateCount += 1
                    continue
                }
                let metadata = readMetadata(from: url)
                let songID = stableID(hash)
                let record = try manager.registerFile(
                    sourceTempURL: url,
                    songId: "local-\(hash)",
                    originalFilename: url.lastPathComponent,
                    kind: .userImported,
                    sha256: hash
                )
                var coverURL: URL?
                if let artwork = metadata.artwork {
                    let coverPath = "ATMusicAudio/Artwork/\(record.id).jpg"
                    coverURL = try manager.writeSupportData(artwork, relativePath: coverPath)
                }
                let lrcPath = url.deletingPathExtension().lastPathComponent + ".lrc"
                if let lrcURL = url.deletingLastPathComponent().appendingPathComponent(lrcPath) as URL?,
                   let lrcData = try? Data(contentsOf: lrcURL), !lrcData.isEmpty {
                    let localLRCPath = (record.relativePath as NSString).deletingPathExtension + ".lrc"
                    _ = try? manager.writeSupportData(lrcData, relativePath: localLRCPath)
                }
                songs.append(Song(
                    id: songID,
                    name: metadata.title,
                    artists: metadata.artist,
                    album: metadata.album,
                    coverURL: coverURL,
                    duration: metadata.duration,
                    source: .local,
                    localRelativePath: record.relativePath
                ))
            } catch {
                failedCount += 1
                ATMusicLogger.shared.log("本地音频导入失败：\(url.lastPathComponent) \(error.localizedDescription)", level: .warn)
            }
        }
        return LocalAudioImportReport(songs: songs, importedCount: songs.count, duplicateCount: duplicateCount, failedCount: failedCount)
    }

    private struct Metadata {
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval
        let artwork: Data?
    }

    private func readMetadata(from url: URL) -> Metadata {
        let asset = AVURLAsset(url: url)
        let values = asset.commonMetadata
        func string(for key: AVMetadataKey) -> String? {
            guard let item = values.first(where: { $0.commonKey == key }) else { return nil }
            if let value = item.stringValue { return value }
            if let number = item.numberValue { return number.stringValue }
            return nil
        }
        let titleValue = string(for: .commonKeyTitle)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = titleValue?.isEmpty == false ? titleValue! : url.deletingPathExtension().lastPathComponent
        let artistValue = string(for: .commonKeyArtist)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artistValue?.isEmpty == false ? artistValue! : "未知艺术家"
        let album = string(for: .commonKeyAlbumName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artwork = values.first(where: { $0.commonKey == .commonKeyArtwork })?.dataValue
        let duration = asset.duration.isNumeric && asset.duration.seconds.isFinite ? max(0, asset.duration.seconds) : 0
        return Metadata(title: title, artist: artist, album: album, duration: duration, artwork: artwork)
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func stableID(_ value: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }
        let result = Int(hash & 0x7fff_ffff_ffff_ffff)
        return result == 0 ? 1 : result
    }
}

extension LocalAudioFileManager {
    func removeManagedArtworkIfNeeded(_ url: URL) {
        guard url.isFileURL else { return }
        let root = ManagedAudioPath.documents
            .appendingPathComponent("ATMusicAudio/Artwork", isDirectory: true)
            .standardizedFileURL
        let target = url.standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { return }
        try? FileManager.default.removeItem(at: target)
    }

    func writeSupportData(_ data: Data, relativePath: String) throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: temp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temp) }
        return try copySupportFile(sourceURL: temp, relativePath: relativePath)
    }
}

struct LocalAudioDocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: LocalAudioDocumentPicker
        init(_ parent: LocalAudioDocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls)
        }
    }
}
