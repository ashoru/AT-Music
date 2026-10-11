import SwiftUI
import UIKit

/// 全新播放器布局与歌词编辑器：
/// 1. 分屏设计：上半区吸顶固定微缩实时真机预览（Sticky Live Preview），下半区独立滑动多功能控制台，彻底解决“无法边调边看”的痛点；
/// 2. 四套播放器（Apple Music / 沉浸式 / 黑胶唱片 / 经典模式）统一归整，随时切换预览；
/// 3. 四套样式的组件坐标、缩放、歌词字体字号、行距、高亮与常规颜色、翻译开关、发光辉光、3D 景深全部支持针对性独立微调并持久化保存。
struct PlayerLayoutEditorSheet: View {
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var clock: PlaybackClock
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var favorites: FavoritesStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appleLayout = AppleMusicLayoutStore.shared

    // 播放器风格与外观
    @AppStorage("atmusic.coverPlayerStyle") private var coverPlayerStyleRaw = ATMusicCoverPlayerStyle.appleMusic.rawValue
    @AppStorage("atmusic.playerButtonStyle") private var playerButtonStyleRaw = ATMusicPlayerButtonStyle.appleMusic.rawValue
    @AppStorage("atmusic.appleMusic.showLyricPreview") private var showLyricPreview = true
    @AppStorage("atmusic.appleMusic.showVolume") private var showVolume = false
    @AppStorage("atmusic.appleMusic.syncWallpaper") private var syncWallpaper = false
    @AppStorage("atmusic.appleMusic.primaryHex") private var primaryHex = ""
    @AppStorage("atmusic.appleMusic.secondaryHex") private var secondaryHex = ""
    @AppStorage("atmusic.appleMusic.accentHex") private var accentHex = ""
    @AppStorage("atmusic.appleMusic.volumeHex") private var volumeHex = ""
    @AppStorage("atmusic.circularCover") private var circularCover = true

    // 歌词字体、排版与色彩设置（四套通用/全局持久化）
    @AppStorage("atmusic.lyricFontSize") private var lyricFontSize = 17
    @AppStorage("atmusic.lyricSpacing") private var lyricLineSpacing = 24
    @AppStorage("atmusic.lyricOffset") private var lyricOffset = 0.0
    @AppStorage("atmusic.lyricTranslation") private var lyricTranslation = true
    @AppStorage("atmusic.lyricAlignRaw") private var lyricAlignRaw = "center"
    @AppStorage("atmusic.lyricTilt") private var lyricTilt = 0
    @AppStorage("atmusic.lyricGradMode") private var lyricGradMode = 0
    @AppStorage("atmusic.lyricColor") private var lyricColorRaw = "accent"
    @AppStorage("atmusic.lyricDimColor") private var lyricDimColorRaw = "dim"
    @AppStorage("atmusic.lyricGlow") private var lyricGlowLevel = 1
    @AppStorage("atmusic.lyricBlurAmount") private var lyricBlurAmount = 1.1

    // 编辑器界面状态
    @State private var editorTab: Int = 0 // 0: 组件布局, 1: 歌词排版, 2: 色彩发光, 3: 预设重置
    @State private var previewMode: Int = 0 // 0: 封面页, 1: 歌词页
    @State private var selectedApplePart: AppleMusicLayoutPart = .cover
    @State private var selectedLegacyPart: PlayerLayoutPart = .cover
    @State private var legacyLayoutData: [String: PlayerLayoutEntry] = PlayerLayoutStore.load()

    private var activeStyle: ATMusicCoverPlayerStyle {
        ATMusicCoverPlayerStyle(rawValue: coverPlayerStyleRaw) ?? .appleMusic
    }

    private var activeLegacyStyle: ATMusicCoverPlayerStyle {
        activeStyle == .vinyl ? .vinyl : (activeStyle == .immersive ? .immersive : .classic)
    }

    private var selectedEntry: Binding<PlayerLayoutEntry> {
        Binding(
            get: {
                if activeStyle == .appleMusic {
                    return appleLayout.entry(for: selectedApplePart)
                }
                return legacyLayoutData[selectedLegacyPart.rawValue] ?? PlayerLayoutStore.defaultEntry(for: selectedLegacyPart, style: activeLegacyStyle)
            },
            set: { newValue in
                if activeStyle == .appleMusic {
                    appleLayout.set(newValue, for: selectedApplePart)
                } else {
                    legacyLayoutData[selectedLegacyPart.rawValue] = newValue
                    PlayerLayoutStore.save(legacyLayoutData, for: activeLegacyStyle)
                }
            }
        )
    }

    private var lyricOffsetText: String {
        if lyricOffset == 0 { return "同步" }
        return lyricOffset > 0
            ? "提前 " + String(format: "%.1f", lyricOffset) + "s"
            : "延后 " + String(format: "%.1f", -lyricOffset) + "s"
    }

    private var glowLevelText: String {
        switch lyricGlowLevel {
        case 0: return "关闭"
        case 1: return "柔和"
        case 2: return "标准"
        default: return "强烈"
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(UIColor.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                // 1. 顶栏导航与播放器风格切换
                topNavigationBar
                styleSelectorBar

                Divider().overlay(Color.primary.opacity(0.08))

                // 2. 【上半区：吸顶固定微缩实时真机预览】（手指滑动下半区时始终固定可见，实现“边调边看”）
                stickyLivePreviewHeader
                    .padding(.vertical, 8)
                    .background(Color(UIColor.secondarySystemBackground).opacity(0.85))

                Divider().overlay(Color.primary.opacity(0.08))

                // 3. 【下半区：模块化多功能控制台】（独立滚动区）
                VStack(spacing: 0) {
                    controlTabBar
                        .padding(.top, 8)
                        .padding(.horizontal, 16)

                    ScrollView(showsIndicators: true) {
                        VStack(spacing: 14) {
                            switch editorTab {
                            case 0:
                                componentLayoutTab
                            case 1:
                                lyricsTypographyTab
                            case 2:
                                colorAndGlowTab
                            default:
                                presetAndResetTab
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 40)
                    }
                }
            }
        }
        .onAppear {
            if activeStyle != .appleMusic {
                legacyLayoutData = PlayerLayoutStore.load(for: activeLegacyStyle)
            }
        }
    }

    // MARK: - 顶栏与播放器风格切换

    private var topNavigationBar: some View {
        HStack {
            Button("取消") {
                dismiss()
            }
            .font(ATMusicFont.appFont(15, .medium))
            .foregroundStyle(Color.atmusicComment)

            Spacer()

            Text("播放器与歌词编辑器")
                .font(ATMusicFont.appFont(16, .bold))
                .foregroundStyle(Color.atmusicLabel)

            Spacer()

            Button("完成") {
                ATMusicHaptics.success()
                dismiss()
            }
            .font(ATMusicFont.appFont(15, .bold))
            .foregroundStyle(Color.atmusicAmber)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var styleSelectorBar: some View {
        HStack(spacing: 6) {
            ForEach(ATMusicCoverPlayerStyle.allCases, id: \.self) { style in
                let isSelected = coverPlayerStyleRaw == style.rawValue
                Button {
                    coverPlayerStyleRaw = style.rawValue
                    if style != .appleMusic {
                        legacyLayoutData = PlayerLayoutStore.load(for: activeLegacyStyle)
                    }
                    ATMusicHaptics.select()
                } label: {
                    Text(style.title)
                        .font(ATMusicFont.appFont(12, isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.atmusicLabel)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(
                            isSelected ? Color.atmusicAmber : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - 【上半区：吸顶固定微缩实时真机预览】

    private var stickyLivePreviewHeader: some View {
        HStack(spacing: 16) {
            // 左侧：微缩真机模型（高度固定约 210 pt，保持完美 iPhone 比例）
            miniDeviceModel
                .frame(width: 98, height: 212)
                .shadow(color: Color.black.opacity(0.18), radius: 10, y: 5)

            // 右侧：预览控制面板与即时状态
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("实时预览联动")
                        .font(ATMusicFont.appFont(14, .bold))
                        .foregroundStyle(Color.atmusicLabel)
                    Text("拖动滑杆毫秒级刷新，直视真机效果")
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                        .lineLimit(1)
                }

                // 封面页 / 歌词页 切换胶囊
                HStack(spacing: 4) {
                    previewModeButton(title: "封面页", mode: 0, icon: "photo.fill")
                    previewModeButton(title: "歌词页", mode: 1, icon: "quote.bubble.fill")
                }
                .padding(3)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                // 当前正在编辑的组件标签
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.atmusicAmber)
                    Text("正在调整: \(currentEditingPartName)")
                        .font(ATMusicFont.appFont(12, .semibold))
                        .foregroundStyle(Color.atmusicLabel)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.atmusicAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                // 快捷复位当前组件
                Button {
                    resetCurrentPart()
                    ATMusicHaptics.tap()
                    ToastCenter.shared.show("已复位「\(currentEditingPartName)」")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .bold))
                        Text("复位当前组件")
                            .font(ATMusicFont.appFont(11, .medium))
                    }
                    .foregroundStyle(Color.atmusicComment)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .frame(height: 226)
    }

    private func previewModeButton(title: String, mode: Int, icon: String) -> some View {
        Button {
            previewMode = mode
            ATMusicHaptics.select()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(ATMusicFont.appFont(12, previewMode == mode ? .semibold : .medium))
            }
            .foregroundStyle(previewMode == mode ? Color.white : Color.atmusicLabel)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(previewMode == mode ? Color.atmusicAmber : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var currentEditingPartName: String {
        if editorTab == 1 { return "歌词排版" }
        if editorTab == 2 { return "色彩与发光" }
        if activeStyle == .appleMusic {
            return selectedApplePart.rawValue
        } else {
            return selectedLegacyPart.rawValue
        }
    }

    // MARK: - 微缩真机模型视图

    private var miniDeviceModel: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let corner = w * 0.16

            ZStack {
                // 金属机身边框
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.gray.opacity(0.7), Color.black, Color.gray.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // 黑色边框
                RoundedRectangle(cornerRadius: corner - 1.5, style: .continuous)
                    .fill(Color.black)
                    .padding(1.5)

                // 真机屏幕（内部等比缩放渲染真实播放器）
                ZStack {
                    livePlayerContentView
                }
                .clipShape(RoundedRectangle(cornerRadius: corner - 3, style: .continuous))
                .padding(3)

                // 灵动岛小装饰
                Capsule()
                    .fill(Color.black)
                    .frame(width: w * 0.32, height: 6.5)
                    .offset(y: -h / 2 + 7.5)
            }
        }
    }

    @ViewBuilder
    private var livePlayerContentView: some View {
        let bounds = ATMusicDisplayMetrics.bounds
        let designWidth = bounds.width
        let designHeight = bounds.height
        let scale = 92.0 / designWidth

        GeometryReader { geometry in
            ZStack {
                if activeStyle == .appleMusic {
                    ReferencePlaybackView(
                        song: previewSong,
                        lyrics: previewLyrics,
                        showLyrics: Binding(get: { previewMode == 1 }, set: { _ in }),
                        onFavorite: {},
                        onQueue: {},
                        onComments: {},
                        onSleepTimer: {},
                        onAddToLocalPlaylist: {},
                        onDownload: {},
                        onPlayerSettings: {},
                        onSearchLyrics: {},
                        onSongInfo: {}
                    )
                } else if activeStyle == .immersive {
                    ImmersivePlayerView(
                        song: previewSong,
                        lyrics: previewLyrics,
                        isPresented: .constant(true),
                        previewShowLyrics: previewMode == 1,
                        onOpenSettings: {},
                        onSleepTimer: {},
                        onSongInfo: {},
                        onSearchLyrics: {},
                        onAddToLocalPlaylist: {},
                        onDownload: {}
                    )
                } else {
                    PlayerView(
                        isPresented: .constant(true),
                        previewShowLyrics: previewMode == 1
                    )
                }
            }
            .environmentObject(theme)
            .environmentObject(player)
            .environmentObject(clock)
            .environmentObject(auth)
            .environmentObject(favorites)
            .environment(\.colorScheme, .dark)
            .frame(width: designWidth, height: designHeight)
            .scaleEffect(scale, anchor: .center)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .allowsHitTesting(false)
        }
    }

    private var previewSong: Song {
        player.currentSong ?? Song(
            id: 1999001,
            name: "七里香",
            artists: "周杰伦",
            album: "七里香",
            coverURL: URL(string: "https://p1.music.126.net/14nQjLlh9u5-m-Ld9D-Uwg==/109951165434190875.jpg"),
            duration: 299,
            source: .netease
        )
    }

    private var previewLyrics: [LyricLine] {
        [
            LyricLine(time: 0, text: "秋刀鱼的滋味 猫跟你都想了解"),
            LyricLine(time: 5, text: "初恋的香味就这麼被我们寻回", translation: "The scent of first love was found by us"),
            LyricLine(time: 10, text: "那温暖的阳光 像刚切的白面包"),
            LyricLine(time: 15, text: "窗台蝴蝶 像诗里纷飞的美丽章节")
        ]
    }

    // MARK: - 控制台 Tab 切换栏

    private var controlTabBar: some View {
        HStack(spacing: 8) {
            tabButton(title: "组件布局", index: 0, icon: "square.dashed")
            tabButton(title: "歌词排版", index: 1, icon: "textformat")
            tabButton(title: "色彩发光", index: 2, icon: "paintpalette.fill")
            tabButton(title: "预设重置", index: 3, icon: "arrow.counterclockwise")
        }
    }

    private func tabButton(title: String, index: Int, icon: String) -> some View {
        Button {
            editorTab = index
            ATMusicHaptics.select()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(ATMusicFont.appFont(12, editorTab == index ? .semibold : .medium))
            }
            .foregroundStyle(editorTab == index ? Color.atmusicAmber : Color.atmusicComment)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(editorTab == index ? Color.atmusicAmber.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab 0: 组件布局微调 (位置与尺寸)

    private var componentLayoutTab: some View {
        VStack(spacing: 12) {
            // 组件选择器
            VStack(alignment: .leading, spacing: 8) {
                Text("选择要微调的组件")
                    .font(ATMusicFont.appFont(13, .semibold))
                    .foregroundStyle(Color.atmusicLabel)

                if activeStyle == .appleMusic {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(AppleMusicLayoutPart.allCases) { part in
                                componentPill(name: part.rawValue, isSelected: selectedApplePart == part) {
                                    selectedApplePart = part
                                }
                            }
                        }
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(visibleLegacyParts) { part in
                                componentPill(name: part.rawValue, isSelected: selectedLegacyPart == part) {
                                    selectedLegacyPart = part
                                }
                            }
                        }
                    }
                }
            }
            .padding(14)
            .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }

            // X/Y 偏移、Scale、Rotation、Opacity 滑杆控制板
            VStack(spacing: 10) {
                sliderRow(title: "水平 X", value: selectedEntry.x, range: -180...180, format: "%.0f pt") {
                    selectedEntry.wrappedValue.x = 0
                }
                sliderRow(title: "垂直 Y", value: selectedEntry.y, range: -260...260, format: "%.0f pt") {
                    selectedEntry.wrappedValue.y = 0
                }
                sliderRow(title: "大小缩放", value: selectedEntry.scale, range: 0.3...1.8, step: 0.05, format: "%.2fx") {
                    selectedEntry.wrappedValue.scale = 1.0
                }
                sliderRow(title: "旋转角度", value: selectedEntry.rotation, range: -180...180, format: "%.0f°") {
                    selectedEntry.wrappedValue.rotation = 0
                }
                sliderRow(title: "透明度", value: selectedEntry.opacity, range: 0...1, step: 0.05, format: "%.0f%%", multiplier: 100) {
                    selectedEntry.wrappedValue.opacity = 1.0
                }
            }
            .padding(14)
            .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
        }
    }

    private func componentPill(name: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            ATMusicHaptics.select()
        } label: {
            Text(name)
                .font(ATMusicFont.appFont(12, isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.white : Color.atmusicLabel)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(isSelected ? Color.atmusicAmber : Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func sliderRow(
        title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        step: CGFloat = 1,
        format: String,
        multiplier: CGFloat = 1,
        onReset: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(ATMusicFont.appFont(13, .medium))
                    .foregroundStyle(Color.atmusicLabel)
                Spacer()
                Text(String(format: format, value.wrappedValue * multiplier))
                    .font(ATMusicFont.appFont(12, .semibold, .monospaced))
                    .foregroundStyle(Color.atmusicAmber)
                Button("重置") {
                    onReset()
                    ATMusicHaptics.select()
                }
                .font(ATMusicFont.appFont(11))
                .foregroundStyle(Color.atmusicComment)
            }
            Slider(value: value, in: range, step: step)
                .tint(Color.atmusicAmber)
        }
    }

    // MARK: - Tab 1: 歌词排版定制 (四套播放器专属联动)

    private var lyricsTypographyTab: some View {
        VStack(spacing: 12) {
            VStack(spacing: 14) {
                Toggle("显示双语翻译", isOn: $lyricTranslation)
                    .font(ATMusicFont.appFont(14, .medium))
                    .tint(Color.atmusicAmber)

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                // 字号大小
                VStack(spacing: 4) {
                    HStack {
                        Text("默认歌词字号")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        Text("\(lyricFontSize) pt")
                            .font(ATMusicFont.appFont(12, .semibold, .monospaced))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    Slider(value: Binding(
                        get: { Double(lyricFontSize) },
                        set: { lyricFontSize = Int($0) }
                    ), in: 12...32, step: 1)
                    .tint(Color.atmusicAmber)
                }

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                // 行间距
                VStack(spacing: 4) {
                    HStack {
                        Text("歌词行间距")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        Text("\(lyricLineSpacing) pt")
                            .font(ATMusicFont.appFont(12, .semibold, .monospaced))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    Slider(value: Binding(
                        get: { Double(lyricLineSpacing) },
                        set: { lyricLineSpacing = Int($0) }
                    ), in: 0...40, step: 2)
                    .tint(Color.atmusicAmber)
                }

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                // 对齐方式
                HStack {
                    Text("歌词对齐方式")
                        .font(ATMusicFont.appFont(13, .medium))
                        .foregroundStyle(Color.atmusicLabel)
                    Spacer()
                    Picker("对齐", selection: $lyricAlignRaw) {
                        Text("居中对齐").tag("center")
                        Text("靠左对齐").tag("left")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                // 3D 景深倾斜
                VStack(spacing: 4) {
                    HStack {
                        Text("3D 空间立体景深倾斜")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        Text("\(lyricTilt)°")
                            .font(ATMusicFont.appFont(12, .semibold, .monospaced))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    Slider(value: Binding(
                        get: { Double(lyricTilt) },
                        set: { lyricTilt = Int($0) }
                    ), in: 0...45, step: 1)
                    .tint(Color.atmusicAmber)
                }

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                // 歌词同步时间偏移校准
                VStack(spacing: 4) {
                    HStack {
                        Text("歌词同步偏移校准")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        Text(lyricOffsetText)
                            .font(ATMusicFont.appFont(12, .semibold, .monospaced))
                            .foregroundStyle(Color.atmusicAmber)
                        Button("归零") {
                            lyricOffset = 0
                            ATMusicHaptics.select()
                        }
                        .font(ATMusicFont.appFont(11))
                        .foregroundStyle(Color.atmusicComment)
                    }
                    Slider(value: $lyricOffset, in: -3.0...3.0, step: 0.1)
                        .tint(Color.atmusicAmber)
                }
            }
            .padding(14)
            .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
        }
    }

    // MARK: - Tab 2: 色彩、发光与视觉渲染

    private var colorAndGlowTab: some View {
        VStack(spacing: 12) {
            VStack(spacing: 14) {
                // 高亮颜色模式
                HStack {
                    Text("高亮歌词颜色模式")
                        .font(ATMusicFont.appFont(13, .medium))
                        .foregroundStyle(Color.atmusicLabel)
                    Spacer()
                    Picker("模式", selection: $lyricGradMode) {
                        Text("跟随封面主色").tag(0)
                        Text("自定义颜色").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }

                if lyricGradMode == 1 {
                    HStack {
                        Text("当前高亮行歌词颜色")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        ColorPicker("", selection: Binding(
                            get: {
                                if lyricColorRaw.hasPrefix("#"), let c = Color(hex: lyricColorRaw) { return c }
                                return Color.atmusicAmber
                            },
                            set: { lyricColorRaw = $0.hexString }
                        ), supportsOpacity: false)
                        .labelsHidden()
                    }

                    HStack {
                        Text("常规未播放歌词颜色")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        ColorPicker("", selection: Binding(
                            get: {
                                if lyricDimColorRaw.hasPrefix("#"), let c = Color(hex: lyricDimColorRaw) { return c }
                                return Color.gray.opacity(0.85)
                            },
                            set: { lyricDimColorRaw = $0.hexString }
                        ), supportsOpacity: false)
                        .labelsHidden()
                    }
                }

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                // 歌词辉光强度
                VStack(spacing: 4) {
                    HStack {
                        Text("歌词双层辉光发光强度")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        Text(glowLevelText)
                            .font(ATMusicFont.appFont(12, .semibold))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    Slider(value: Binding(
                        get: { Double(lyricGlowLevel) },
                        set: { lyricGlowLevel = Int($0) }
                    ), in: 0...4, step: 1)
                    .tint(Color.atmusicAmber)
                }

                Divider().overlay(Color.atmusicComment.opacity(0.12))

                // 非当前行高斯虚化模糊
                VStack(spacing: 4) {
                    HStack {
                        Text("非当前行高斯虚化度")
                            .font(ATMusicFont.appFont(13, .medium))
                            .foregroundStyle(Color.atmusicLabel)
                        Spacer()
                        Text(String(format: "%.1f", lyricBlurAmount))
                            .font(ATMusicFont.appFont(12, .semibold, .monospaced))
                            .foregroundStyle(Color.atmusicAmber)
                    }
                    Slider(value: $lyricBlurAmount, in: 0...3.0, step: 0.1)
                        .tint(Color.atmusicAmber)
                }

                // Apple Music 专属调色
                if activeStyle == .appleMusic {
                    Divider().overlay(Color.atmusicComment.opacity(0.12))

                    Toggle("显示音量条", isOn: $showVolume).tint(Color.atmusicAmber).font(ATMusicFont.appFont(13))
                    Toggle("显示封面页歌词预览", isOn: $showLyricPreview).tint(Color.atmusicAmber).font(ATMusicFont.appFont(13))
                    Toggle("同步主页壁纸", isOn: $syncWallpaper).tint(Color.atmusicAmber).font(ATMusicFont.appFont(13))

                    ColorPicker("主图标与当前歌词色", selection: colorBinding(for: $primaryHex, fallback: .white), supportsOpacity: false)
                    ColorPicker("次级文字与时间颜色", selection: colorBinding(for: $secondaryHex, fallback: .gray), supportsOpacity: false)
                    ColorPicker("高亮强调色", selection: colorBinding(for: $accentHex, fallback: Color.atmusicAmber), supportsOpacity: false)
                    ColorPicker("音量条滑动色彩", selection: colorBinding(for: $volumeHex, fallback: .white), supportsOpacity: false)
                }
            }
            .padding(14)
            .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
        }
    }

    private func colorBinding(for hex: Binding<String>, fallback: Color) -> Binding<Color> {
        Binding(
            get: {
                if hex.wrappedValue.hasPrefix("#"), let c = Color(hex: hex.wrappedValue) { return c }
                return fallback
            },
            set: { hex.wrappedValue = $0.hexString }
        )
    }

    // MARK: - Tab 3: 预设与重置

    private var presetAndResetTab: some View {
        VStack(spacing: 12) {
            Button {
                resetCurrentPart()
                ATMusicHaptics.success()
                ToastCenter.shared.show("已恢复当前组件默认")
            } label: {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                    Text("恢复当前组件为默认参数")
                    Spacer()
                }
                .font(ATMusicFont.appFont(14, .semibold))
                .foregroundStyle(Color.atmusicLabel)
                .padding(14)
                .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)) }
            }
            .buttonStyle(.plain)

            Button {
                resetCurrentStyleLayout()
                ATMusicHaptics.success()
                ToastCenter.shared.show("已重置「\(activeStyle.title)」布局为初始状态")
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("重置当前播放器为初始默认布局")
                    Spacer()
                }
                .font(ATMusicFont.appFont(14, .semibold))
                .foregroundStyle(Color.red)
                .padding(14)
                .background { ATMusicSurface(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)) }
            }
            .buttonStyle(.plain)
        }
    }

    private var visibleLegacyParts: [PlayerLayoutPart] {
        switch activeStyle {
        case .vinyl:
            return [.vinylAlbum, .title, .vinylLyricsHeader, .vinylLyricsText, .progress, .controls, .queue]
        case .classic:
            return [.topBack, .topTitle, .topFavorite, .cover, .title, .previewLyric, .progress, .previous, .playPause, .next, .queue, .grabber]
        case .appleMusic:
            return []
        case .immersive:
            if previewMode == 0 {
                return [.cover, .title, .progress, .controls, .loop, .previous, .playPause, .next, .queue]
            } else {
                return [.topTitle, .lyric, .progress, .controls, .loop, .previous, .playPause, .next, .queue]
            }
        }
    }

    private func resetCurrentPart() {
        if activeStyle == .appleMusic {
            appleLayout.reset(selectedApplePart)
        } else {
            legacyLayoutData[selectedLegacyPart.rawValue] = PlayerLayoutStore.defaultEntry(for: selectedLegacyPart, style: activeLegacyStyle)
            PlayerLayoutStore.save(legacyLayoutData, for: activeLegacyStyle)
        }
    }

    private func resetCurrentStyleLayout() {
        if activeStyle == .appleMusic {
            appleLayout.resetAll()
        } else {
            legacyLayoutData = [:]
            PlayerLayoutStore.reset(for: activeLegacyStyle)
        }
    }
}
