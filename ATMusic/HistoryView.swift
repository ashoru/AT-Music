import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isMultiSelecting = false
    @State private var selectedSongKeys: Set<String> = []
    @State private var dragStartIndex: Int? = nil
    @State private var initialSelectedKeysOnDrag: Set<String>? = nil
    @State private var dragTargetSelected = true
    @State private var lastDragIndex: Int? = nil
    @State private var showBatchAddToPlaylist = false

    private var selectedSongs: [Song] {
        player.history.filter { selectedSongKeys.contains($0.identityKey) }
    }

    private func toggleSelection(_ song: Song) {
        if selectedSongKeys.contains(song.identityKey) {
            selectedSongKeys.remove(song.identityKey)
        } else {
            selectedSongKeys.insert(song.identityKey)
        }
    }

    private func handleDragChange(startIndex: Int, deltaRows: Int) {
        let keys = player.history.map(\.identityKey)
        guard startIndex >= 0, startIndex < keys.count else { return }
        if dragStartIndex == nil {
            dragStartIndex = startIndex
            initialSelectedKeysOnDrag = selectedSongKeys
            let willSelect = !selectedSongKeys.contains(keys[startIndex])
            dragTargetSelected = willSelect
            lastDragIndex = nil
        }
        guard let start = dragStartIndex, let initial = initialSelectedKeysOnDrag else { return }
        let current = min(max(0, start + deltaRows), keys.count - 1)
        guard current != lastDragIndex else { return }
        lastDragIndex = current
        ATMusicHaptics.select()

        let low = min(start, current)
        let high = max(start, current)
        var updated = initial
        for idx in low...high {
            let k = keys[idx]
            if dragTargetSelected {
                updated.insert(k)
            } else {
                updated.remove(k)
            }
        }
        selectedSongKeys = updated
    }

    private func handleDragEnd() {
        dragStartIndex = nil
        initialSelectedKeysOnDrag = nil
        lastDragIndex = nil
    }

    @ViewBuilder
    private func historySongRow(song: Song, index: Int) -> some View {
        if isMultiSelecting {
            let isSelected = selectedSongKeys.contains(song.identityKey)
            HStack(spacing: 8) {
                MultiSelectCheckmark(
                    isSelected: isSelected,
                    index: index,
                    rowHeight: 52,
                    onToggle: {
                        toggleSelection(song)
                        ATMusicHaptics.tap()
                    },
                    onDragChange: { startIdx, deltaRows in
                        handleDragChange(startIndex: startIdx, deltaRows: deltaRows)
                    },
                    onDragEnd: {
                        handleDragEnd()
                    }
                )
                SongCell(song: song, glassRow: true) {}
            }
            .contentShape(Rectangle())
            .onTapGesture {
                toggleSelection(song)
                ATMusicHaptics.tap()
            }
        } else {
            SongCell(song: song, glassRow: false, playbackContext: player.history, playbackIndex: index) {
                player.play(songs: player.history, startAt: index)
            }
        }
    }

    var body: some View {
        ATMusicNavigationStack {
            ZStack {
                GlassBackdrop(customColor: theme.backgroundSyncAll ? theme.customBackground : nil)
                if player.history.isEmpty {
                    EmptyStateView(icon: "clock.arrow.circlepath", text: "暂无播放历史")
                } else if DeviceLayoutHelper.isIPadRegular(horizontalSizeClass) {
                    ScrollView {
                        LazyVGrid(columns: DeviceLayoutHelper.songListColumns(for: horizontalSizeClass, spacing: 16), spacing: 8) {
                            ForEach(Array(player.history.enumerated()), id: \.element.identityKey) { index, song in
                                historySongRow(song: song, index: index)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.primary.opacity(0.03))
                                }
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 16)
                        .padding(.bottom, 120)
                    }
                    .frame(maxWidth: DeviceLayoutHelper.contentMaxWidth(for: horizontalSizeClass))
                    .frame(maxWidth: .infinity)
                } else {
                    List {
                        ForEach(Array(player.history.enumerated()), id: \.element.identityKey) { index, song in
                            historySongRow(song: song, index: index)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                        .onDelete { offsets in
                            player.removeHistory(at: offsets)
                        }
                    }
                    .atmusicScrollContentBackgroundHidden()
                    .listStyle(.plain)
                }

                if isMultiSelecting && !selectedSongKeys.isEmpty {
                    VStack {
                        Spacer()
                        UniversalBatchActionBar(
                            selectedCount: selectedSongKeys.count,
                            totalCount: player.history.count,
                            actions: [
                                BatchActionItem(id: "play", title: "播放", systemImage: "play.fill") {
                                    let songs = selectedSongs
                                    player.play(songs: songs, startAt: 0)
                                    isMultiSelecting = false
                                    selectedSongKeys.removeAll()
                                },
                                BatchActionItem(id: "playNext", title: "下一首", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                    let songs = selectedSongs
                                    player.playNext(songs: songs)
                                    isMultiSelecting = false
                                    selectedSongKeys.removeAll()
                                },
                                BatchActionItem(id: "queue", title: "加队列", systemImage: "text.badge.plus") {
                                    let songs = selectedSongs
                                    player.appendToQueue(songs: songs)
                                    isMultiSelecting = false
                                    selectedSongKeys.removeAll()
                                },
                                BatchActionItem(id: "playlist", title: "加歌单", systemImage: "folder.badge.plus") {
                                    showBatchAddToPlaylist = true
                                },
                                BatchActionItem(id: "download", title: "下载", systemImage: "arrow.down.circle") {
                                    let songs = selectedSongs
                                    DownloadManager.shared.startBatchDownload(songs: songs)
                                    isMultiSelecting = false
                                    selectedSongKeys.removeAll()
                                },
                                BatchActionItem(id: "delete", title: "移除记录", systemImage: "trash", tint: Color.red) {
                                    let songs = selectedSongs
                                    player.removeHistory(songs: songs)
                                    isMultiSelecting = false
                                    selectedSongKeys.removeAll()
                                }
                            ]
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .navigationTitle(isMultiSelecting ? (selectedSongKeys.isEmpty ? "选择歌曲" : "已选 \(selectedSongKeys.count) 首") : "最近播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if isMultiSelecting {
                        HStack(spacing: 12) {
                            Button(selectedSongKeys.count == player.history.count && !player.history.isEmpty ? "取消全选" : "全选") {
                                ATMusicHaptics.tap()
                                if selectedSongKeys.count == player.history.count {
                                    selectedSongKeys.removeAll()
                                } else {
                                    selectedSongKeys = Set(player.history.map(\.identityKey))
                                }
                            }
                            .font(ATMusicFont.appFont(13, .semibold))
                            .foregroundStyle(Color.atmusicAmber)

                            Button("完成") {
                                ATMusicHaptics.tap()
                                isMultiSelecting = false
                                selectedSongKeys.removeAll()
                            }
                            .font(ATMusicFont.appFont(13, .semibold))
                        }
                    } else {
                        HStack(spacing: 12) {
                            if !player.history.isEmpty {
                                Button {
                                    ATMusicHaptics.select()
                                    isMultiSelecting = true
                                } label: {
                                    Text("多选")
                                        .font(ATMusicFont.appFont(13, .medium))
                                }

                                Button("清空") {
                                    player.clearHistory()
                                }
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showBatchAddToPlaylist) {
                AddToPlaylistSheet(songs: selectedSongs)
                    .environmentObject(theme)
            }
        }
    }
}
