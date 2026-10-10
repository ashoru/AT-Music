import SwiftUI
import UIKit
import AVFoundation

/// 网易云风格沉浸式调色板（已定版）：
/// 1. topColor：精准采样专辑封面顶部边缘/主体背景色，全屏顶部自然与其无缝接壤（无白边、无雾化割裂）
/// 2. bottomColor：精准采样专辑封面底部色彩并深邃下沉，形成沉浸底座，烘托纯白控制按钮与歌词
struct NetEaseAmbientPalette: Equatable {
    var topColor: Color
    var bottomColor: Color
    var isLight: Bool

    static let fallback = NetEaseAmbientPalette(
        topColor: Color(red: 0.18, green: 0.20, blue: 0.22),
        bottomColor: Color(red: 0.08, green: 0.09, blue: 0.10),
        isLight: false
    )

    static func extract(from image: UIImage) -> NetEaseAmbientPalette {
        let size = 48
        let space = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .fallback }

        // 翻转坐标系，使内存中 y=0 对应视觉顶部，y=size-1 对应视觉底部
        ctx.translateBy(x: 0, y: CGFloat(size))
        ctx.scaleBy(x: 1.0, y: -1.0)
        guard let cg = image.cgImage else { return .fallback }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))

        // 1. 采样顶部切片 (y 从 0 到 8，前 18% 行)
        var topR = 0.0, topG = 0.0, topB = 0.0, topCount = 0.0
        let topMaxRow = max(1, Int(Double(size) * 0.18))
        for y in 0..<topMaxRow {
            for x in 0..<size {
                let off = (y * size + x) * 4
                let a = Double(pixels[off + 3]) / 255.0
                guard a > 0.8 else { continue }
                topR += Double(pixels[off]) / 255.0
                topG += Double(pixels[off + 1]) / 255.0
                topB += Double(pixels[off + 2]) / 255.0
                topCount += 1.0
            }
        }

        // 2. 采样底部切片 (y 从 40 到 47，后 18% 行)
        var botR = 0.0, botG = 0.0, botB = 0.0, botCount = 0.0
        let botMinRow = min(size - 1, Int(Double(size) * 0.82))
        for y in botMinRow..<size {
            for x in 0..<size {
                let off = (y * size + x) * 4
                let a = Double(pixels[off + 3]) / 255.0
                guard a > 0.8 else { continue }
                botR += Double(pixels[off]) / 255.0
                botG += Double(pixels[off + 1]) / 255.0
                botB += Double(pixels[off + 2]) / 255.0
                botCount += 1.0
            }
        }

        let rawTop = topCount > 0
            ? RGBColor(r: topR / topCount, g: topG / topCount, b: topB / topCount)
            : (PaletteExtractor.dominantColor(in: image) ?? RGBColor(r: 0.18, g: 0.20, b: 0.22))
        let rawBot = botCount > 0
            ? RGBColor(r: botR / botCount, g: botG / botCount, b: botB / botCount)
            : rawTop

        let topHSL = rawTop.toHSL()
        let botHSL = rawBot.toHSL()

        // 顶部底色：与封面顶部 100% 同色接壤。如果原图极亮，做温和压制（上限 0.70），确保顶栏白色图标清晰
        let topL = min(topHSL.l, 0.70)
        let finalTopRGB = RGBColor.fromHSL(h: topHSL.h, s: topHSL.s, l: topL)

        // 底部底色（网易云精髓）：
        let isUniform = abs(topHSL.h - botHSL.h) < 25 && abs(topHSL.l - botHSL.l) < 0.22
        let botL: Double
        if isUniform {
            botL = min(max(topHSL.l * 0.68, 0.08), 0.32)
        } else {
            botL = min(max(botHSL.l * 0.70, 0.07), 0.26)
        }
        let finalBotRGB = RGBColor.fromHSL(h: botHSL.h, s: botHSL.s, l: botL)

        return NetEaseAmbientPalette(
            topColor: finalTopRGB.color,
            bottomColor: finalBotRGB.color,
            isLight: topHSL.l > 0.60
        )
    }
}

/// 沉浸式专辑播放器：
/// 1. 全局按键 UI 和强调色可调节（支持软件全局主题色、进度条强调色、主/副按钮颜色、液态/玻璃样式）
/// 2. 播放页面和歌词页面的封面、歌名、进度条、各控制按钮、歌词等全部支持播放器布局编辑器拖动与调整
/// 3. 播放封面页面完全删除顶部下拉收起箭头与右上角省略号（更沉浸通透，下拉任意位置收起播放器）
/// 4. 歌词模式顶部展示小专辑图 + 歌名/歌手（点击返回封面），下潜隐藏控制栏后歌词直接延展至屏幕最底端
struct ImmersivePlayerView: View {
    let song: Song?
    let lyrics: [LyricLine]
    @Binding var isPresented: Bool
    var onOpenSettings: () -> Void = {}
    var onSleepTimer: () -> Void = {}
    var onSongInfo: () -> Void = {}
    var onSearchLyrics: () -> Void = {}
    var onAddToLocalPlaylist: () -> Void = {}
    var onDownload: () -> Void = {}

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var clock: PlaybackClock
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var auth: AuthStore

    // 全局外观配置
    @AppStorage("atmusic.playerButtonStyle") private var playerButtonStyleRaw = ATMusicPlayerButtonStyle.glass.rawValue
    @AppStorage("atmusic.playerPrimaryButtonColorHex") private var playerPrimaryButtonColorHex = ""
    @AppStorage("atmusic.playerMainIconColorHex") private var playerMainIconColorHex = ""
    @AppStorage("atmusic.playerSecondaryIconColorHex") private var playerSecondaryIconColorHex = ""
    @AppStorage("atmusic.progressAccentHex") private var progressAccentHex = ""
    @AppStorage("atmusic.uiStyle") private var uiStyleRaw = ATMusicUIStyle.liquid.rawValue
    @AppStorage("atmusic.playerControlsUseCoverColor") private var controlsUseCoverColor = true

    // 播放器布局数据（支持布局编辑器自由调整 X/Y/大小/旋转/透明度）
    @State private var layoutData: [String: PlayerLayoutEntry] = PlayerLayoutStore.load(for: .immersive)

    @State private var palette: NetEaseAmbientPalette = .fallback
    @State private var showLyrics = false
    @State private var hideControls = false
    @State private var autoHideTimer: Task<Void, Never>?
    @State private var showQueue = false
    @State private var showComments = false
    @State private var showArtistHome = false
    @State private var isDraggingSlider = false
    @State private var sliderDragSeconds: Double = 0

    // MARK: - 全局 UI 与强调色属性
    private var uiStyle: ATMusicUIStyle {
        ATMusicUIStyle(rawValue: uiStyleRaw) ?? .liquid
    }
    private var isLiquid: Bool {
        uiStyle == .liquid
    }
    private var playerButtonStyle: ATMusicPlayerButtonStyle {
        ATMusicPlayerButtonStyle(rawValue: playerButtonStyleRaw) ?? .glass
    }
    private var accentColor: Color {
        if playerPrimaryButtonColorHex.hasPrefix("#"), let color = Color(hex: playerPrimaryButtonColorHex) {
            return color
        }
        return theme.accent.highlight
    }
    private var progressAccent: Color {
        if progressAccentHex.hasPrefix("#"), let color = Color(hex: progressAccentHex) {
            return color
        }
        return accentColor
    }
    private var mainIconColor: Color {
        if playerMainIconColorHex.hasPrefix("#"), let color = Color(hex: playerMainIconColorHex) {
            return color
        }
        return .white
    }
    private var secondaryIconColor: Color {
        if playerSecondaryIconColorHex.hasPrefix("#"), let color = Color(hex: playerSecondaryIconColorHex) {
            return color
        }
        return .white.opacity(0.85)
    }

    private func layoutEntry(_ part: PlayerLayoutPart) -> PlayerLayoutEntry {
        layoutData[part.rawValue] ?? PlayerLayoutStore.defaultEntry(for: part, style: .immersive)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // 1. 全屏双色氛围渐变底色（定版效果）
                LinearGradient(
                    colors: [palette.topColor, palette.bottomColor],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.55), value: palette)

                if showLyrics {
                    // 2. 歌词模式（全屏歌词流 + 智能隐藏控制栏 + 顶部小封面标题栏）
                    ZStack(alignment: .bottom) {
                        // 歌词流视图：铺满从顶栏下方到屏幕物理最底端的全部空间
                        lyricsContainer(geo: geo)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.lyric)))

                        // 下半部控制栏浮动在歌词下方；当下潜隐藏时，整体滑出屏幕底部 (offset 200, opacity 0)
                        bottomControlsDock(geo: geo)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, (geo.safeAreaInsets.top > 0 ? geo.safeAreaInsets.top : 20) + 48)
                    .transition(.opacity)

                    // 歌词模式顶栏（小封面+歌名歌手，点击返回封面；右侧更多菜单）
                    lyricsTopBar(geo: geo)
                        .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.topTitle)))
                } else {
                    // 3. 封面模式（完全删除原下拉收起箭头和右上角省略号，支持下滑手势收起）
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: max(16, geo.safeAreaInsets.top))

                        fullWidthCover(width: geo.size.width)
                            .padding(.top, -10)
                            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.cover)))
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))

                        Spacer(minLength: 8)

                        // 歌曲信息与交互行（歌名+歌手+红心+评论，已删除 quote.bubble）
                        songInfoAndActions
                            .padding(.horizontal, 24)
                            .padding(.bottom, 14)
                            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.title)))

                        // 进度条与播放控制栏
                        bottomControlsDock(geo: geo)
                    }
                    .transition(.opacity)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 25)
                            .onEnded { val in
                                // 封面模式下滑手势收起播放器
                                if !showLyrics && val.translation.height > 60 && abs(val.translation.height) > abs(val.translation.width) {
                                    ATMusicHaptics.tap()
                                    isPresented = false
                                }
                            }
                    )
                }
            }
        }
        .task(id: song?.identityKey) {
            await extractPalette()
        }
        .onChange(of: showLyrics) { _, isShowing in
            if isShowing {
                hideControls = false
                scheduleAutoHide(seconds: 3.5)
            } else {
                autoHideTimer?.cancel()
                hideControls = false
            }
        }
        .onDisappear {
            autoHideTimer?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .atmusicPlayerLayoutDidChange)) { note in
            guard let rawStyle = note.userInfo?["style"] as? String,
                  rawStyle == ATMusicCoverPlayerStyle.immersive.rawValue,
                  let incoming = note.userInfo?["data"] as? [String: PlayerLayoutEntry] else { return }
            layoutData = incoming
        }
        .sheet(isPresented: $showQueue) {
            QueueView()
                .environmentObject(player)
                .environmentObject(theme)
        }
        .sheet(isPresented: $showComments) {
            if let song {
                CommentsSheet(song: song)
                    .environmentObject(theme)
            }
        }
        .sheet(isPresented: $showArtistHome) {
            if let song {
                AllSourcesArtistHomeSheet(artistName: song.artists, initialSongs: [song])
                    .environmentObject(player)
                    .environmentObject(theme)
            }
        }
    }

    // MARK: - 智能倒计时隐藏控制栏
    private func scheduleAutoHide(seconds: Double = 3.5) {
        autoHideTimer?.cancel()
        guard showLyrics else { return }
        autoHideTimer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, showLyrics else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                hideControls = true
            }
        }
    }

    // MARK: - 动态色彩提取（定版算法）
    private func extractPalette() async {
        guard let url = song?.coverURL else {
            withAnimation(.easeInOut(duration: 0.45)) {
                palette = .fallback
            }
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { return }
            let extracted = NetEaseAmbientPalette.extract(from: image)
            withAnimation(.easeInOut(duration: 0.55)) {
                palette = extracted
            }
        } catch {
            // 静默保持当前
        }
    }

    // MARK: - 歌词模式顶栏（小封面+歌名歌手，点击返回封面；右侧更多菜单）
    private func lyricsTopBar(geo: GeometryProxy) -> some View {
        HStack(spacing: 12) {
            Button {
                ATMusicHaptics.tap()
                withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
                    showLyrics = false
                    hideControls = false
                }
            } label: {
                CoverImage(
                    url: song?.coverURL,
                    size: 44,
                    cornerRadius: 8
                )
                .shadow(color: .black.opacity(0.28), radius: 6, y: 3)
            }
            .buttonStyle(.plain)

            Button {
                ATMusicHaptics.tap()
                withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
                    showLyrics = false
                    hideControls = false
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song?.name ?? "未在播放")
                        .font(ATMusicFont.appFont(15, .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(song?.artists.isEmpty == false ? song!.artists : "未知歌手")
                        .font(ATMusicFont.appFont(12.5, .medium))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            // 红心收藏按钮（位于右上角省略号左边）
            if let song {
                let liked = favorites.isLiked(song)
                Button {
                    ATMusicHaptics.tap()
                    Task { await favorites.toggle(song) }
                } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(liked ? accentColor : secondaryIconColor)
                        .frame(width: 40, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(liked ? "取消喜欢" : "喜欢")
            }

            moreOptionsMenu
        }
        .padding(.horizontal, 20)
        .padding(.top, geo.safeAreaInsets.top > 0 ? geo.safeAreaInsets.top : 8)
        .frame(height: (geo.safeAreaInsets.top > 0 ? geo.safeAreaInsets.top : 8) + 48)
    }

    // 右上角 Apple Music 更多操作菜单
    private var moreOptionsMenu: some View {
        Menu {
            Button("定时关闭", action: onSleepTimer)
            Button("歌曲信息", action: onSongInfo)
            Button("搜索歌词", action: onSearchLyrics)
            Button("添加到歌单", action: onAddToLocalPlaylist)
            Button("下载歌曲", action: onDownload)
            Button("播放器设置", action: onOpenSettings)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(mainIconColor.opacity(0.88))
                .frame(width: 44, height: 44, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .accessibilityLabel("播放器更多")
    }

    // MARK: - 封面模式：全宽 1:1 封面（定版双向柔和消融）
    private func fullWidthCover(width: CGFloat) -> some View {
        CoverImage(
            url: song?.coverURL,
            size: width,
            cornerRadius: 0,
            width: width,
            height: width
        )
        .clipped()
        .id(song?.identityKey ?? "empty")
        // 定版顶底双向柔和消融遮罩
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black, location: 0.15),
                    .init(color: .black, location: 0.72),
                    .init(color: .clear, location: 0.98)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .frame(width: width, height: width)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.32)) {
                showLyrics = true
            }
        }
    }

    // MARK: - 歌词流容器（全屏自适应；控制栏下潜后歌词直达屏幕底部）
    private func lyricsContainer(geo: GeometryProxy) -> some View {
        LyricsSection(
            lyrics: lyrics,
            accent: accentColor,
            secondary: .white.opacity(0.65),
            alignment: .center,
            onTapLine: { line in
                ATMusicHaptics.tap()
                player.seek(to: line.time)
                scheduleAutoHide(seconds: 3.5)
            }
        )
        .padding(.horizontal, 20)
        .padding(.bottom, hideControls ? max(12, geo.safeAreaInsets.bottom) : 170)
        // 核心动态渐隐遮罩：
        // 控制栏显示时：歌词在控制栏上方渐隐 (0.65~0.78)，互不遮挡；
        // 控制栏下潜后：歌词直接铺满延展至屏幕最底端 (0.94~0.99)！
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black, location: 0.06),
                    .init(color: .black, location: hideControls ? 0.94 : 0.65),
                    .init(color: .clear, location: hideControls ? 0.99 : 0.78)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: hideControls)
        // 手势监听：上滑歌词隐藏控制栏；下滑歌词恢复显示并重启倒计时
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { val in
                    if val.translation.height < -15 {
                        // 上滑：立即下滑隐藏进度条和控制按钮
                        if !hideControls {
                            autoHideTimer?.cancel()
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                                hideControls = true
                            }
                        }
                    } else if val.translation.height > 15 {
                        // 下滑：恢复显示原下半部分进度条和控制按钮，并重启倒计时
                        if hideControls {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                                hideControls = false
                            }
                        }
                        scheduleAutoHide(seconds: 3.5)
                    }
                }
        )
        .onTapGesture {
            // 点击空白处切替控制栏显示状态
            ATMusicHaptics.tap()
            withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                hideControls.toggle()
            }
            if !hideControls {
                scheduleAutoHide(seconds: 3.5)
            } else {
                autoHideTimer?.cancel()
            }
        }
    }

    // MARK: - 歌曲信息与操作行（已删除 quote.bubble 气泡按键）
    private var songInfoAndActions: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                // 歌名 + VIP 标签
                HStack(spacing: 6) {
                    Text(song?.name ?? "未在播放")
                        .font(ATMusicFont.appFont(21, .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text("VIP")
                        .font(ATMusicFont.appFont(10, .bold))
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Color.white.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                }

                // 歌手名（点击打开歌手页）
                Button {
                    ATMusicHaptics.tap()
                    showArtistHome = true
                } label: {
                    HStack(spacing: 3) {
                        Text(song?.artists.isEmpty == false ? song!.artists : "未知歌手")
                            .font(ATMusicFont.appFont(14, .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 8)

            // 红心收藏（支持全局强调色/红心色）
            if let song {
                let liked = favorites.isLiked(song)
                Button {
                    ATMusicHaptics.tap()
                    Task { await favorites.toggle(song) }
                } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(liked ? accentColor : secondaryIconColor)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
            }

            // 评论按钮
            Button {
                ATMusicHaptics.tap()
                showComments = true
            } label: {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(secondaryIconColor)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 下半部控制区域（进度条 + 播放五键）
    private func bottomControlsDock(geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            progressSection
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.progress)))

            controlsSection
                .padding(.horizontal, 28)
                .padding(.bottom, geo.safeAreaInsets.bottom > 0 ? geo.safeAreaInsets.bottom + 8 : 24)
                .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.controls)))
        }
        // 歌词模式下如果处于隐藏状态，整体向下滑出屏幕并隐去
        .offset(y: (showLyrics && hideControls) ? 200 : 0)
        .opacity((showLyrics && hideControls) ? 0 : 1)
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: hideControls)
    }

    // MARK: - 极细进度条与时间/音质（支持全局强调色和样式调节）
    private var progressSection: some View {
        VStack(spacing: 7) {
            GeometryReader { pGeo in
                let current = isDraggingSlider ? sliderDragSeconds : clock.progress
                let total = max(player.duration, 1)
                let pct = min(max(current / total, 0), 1)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.20))
                        .frame(height: 2.5)

                    Capsule()
                        .fill(progressAccent)
                        .frame(width: pGeo.size.width * CGFloat(pct), height: 2.5)

                    Circle()
                        .fill(progressAccent)
                        .frame(width: 7, height: 7)
                        .offset(x: max(0, min(pGeo.size.width * CGFloat(pct) - 3.5, pGeo.size.width - 7)))
                }
                .frame(height: 18)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            isDraggingSlider = true
                            let ratio = min(max(val.location.x / pGeo.size.width, 0), 1)
                            sliderDragSeconds = Double(ratio) * total
                        }
                        .onEnded { val in
                            let ratio = min(max(val.location.x / pGeo.size.width, 0), 1)
                            let target = Double(ratio) * total
                            player.seek(to: target)
                            isDraggingSlider = false
                            scheduleAutoHide(seconds: 3.5)
                        }
                )
            }
            .frame(height: 18)

            HStack {
                Text(atmusicTimeString(isDraggingSlider ? sliderDragSeconds : clock.progress))
                    .font(ATMusicFont.appFont(11.5, .medium, .monospaced))
                    .foregroundStyle(.white.opacity(0.68))

                Spacer()

                Text("高清臻音")
                    .font(ATMusicFont.appFont(10.5, .medium))
                    .foregroundStyle(.white.opacity(0.65))

                Spacer()

                Text(atmusicTimeString(player.duration))
                    .font(ATMusicFont.appFont(11.5, .medium, .monospaced))
                    .foregroundStyle(.white.opacity(0.68))
            }
        }
    }

    // MARK: - 按钮基底表面（支持全局液态玻璃与样式调整）
    @ViewBuilder
    private func playerButtonSurface(size: CGFloat, active: Bool = false, primary: Bool = false) -> some View {
        ZStack {
            if active && !primary {
                ATMusicLiquidSelectionSurface(shape: Circle(), accent: accentColor)
            } else {
                ATMusicGlass(shape: Circle(), forceLiquid: isLiquid)
            }
            if primary {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [accentColor.opacity(0.62), accentColor.opacity(0.40)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            Circle()
                .strokeBorder(
                    active || primary ? accentColor.opacity(0.52) : (isLiquid ? Color.white.opacity(0.35) : Color.white.opacity(0.12)),
                    lineWidth: primary ? 1.1 : 0.8
                )
        }
        .frame(width: size, height: size)
    }

    // MARK: - 核心五键控制栏（支持全局 UI 样式、强调色和每个按键独立布局编辑）
    private var controlsSection: some View {
        HStack(alignment: .center) {
            // 循环模式
            Button {
                ATMusicHaptics.tap()
                player.togglePlayMode()
                scheduleAutoHide(seconds: 3.5)
            } label: {
                Image(systemName: player.playMode.icon)
                    .font(.system(size: playerButtonStyle == .appleMusic ? 21 : 16, weight: .semibold))
                    .foregroundStyle(player.playMode == .shuffle ? accentColor : secondaryIconColor)
                    .frame(width: 44, height: 44)
                    .background {
                        if playerButtonStyle == .glass {
                            playerButtonSurface(size: 44, active: player.playMode == .shuffle)
                        }
                    }
                    .clipShape(Circle())
            }
            .buttonStyle(GlassPressButtonStyle())
            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.loop)))

            Spacer()

            // 上一首
            Button {
                ATMusicHaptics.tap()
                player.previous()
                scheduleAutoHide(seconds: 3.5)
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: playerButtonStyle == .appleMusic ? 24 : 18, weight: .bold))
                    .foregroundStyle(mainIconColor)
                    .frame(width: 44, height: 44)
                    .background {
                        if playerButtonStyle == .glass {
                            playerButtonSurface(size: 44)
                        }
                    }
                    .clipShape(Circle())
            }
            .buttonStyle(GlassPressButtonStyle())
            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.previous)))

            Spacer()

            // 播放 / 暂停大键
            Button {
                ATMusicHaptics.tap()
                player.togglePlayPause()
                scheduleAutoHide(seconds: 3.5)
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: playerButtonStyle == .appleMusic ? 38 : 28, weight: .bold))
                    .foregroundStyle(playerButtonStyle == .appleMusic ? mainIconColor : .white)
                    .frame(width: 68, height: 68)
                    .background {
                        if playerButtonStyle == .glass {
                            playerButtonSurface(size: 68, primary: true)
                        }
                    }
                    .clipShape(Circle())
            }
            .buttonStyle(GlassPressButtonStyle(scale: 0.92))
            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.playPause)))

            Spacer()

            // 下一首
            Button {
                ATMusicHaptics.tap()
                player.next()
                scheduleAutoHide(seconds: 3.5)
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: playerButtonStyle == .appleMusic ? 24 : 18, weight: .bold))
                    .foregroundStyle(mainIconColor)
                    .frame(width: 44, height: 44)
                    .background {
                        if playerButtonStyle == .glass {
                            playerButtonSurface(size: 44)
                        }
                    }
                    .clipShape(Circle())
            }
            .buttonStyle(GlassPressButtonStyle())
            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.next)))

            Spacer()

            // 播放队列
            Button {
                ATMusicHaptics.tap()
                showQueue = true
            } label: {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: playerButtonStyle == .appleMusic ? 21 : 16, weight: .semibold))
                    .foregroundStyle(secondaryIconColor)
                    .frame(width: 44, height: 44)
                    .background {
                        if playerButtonStyle == .glass {
                            playerButtonSurface(size: 44)
                        }
                    }
                    .clipShape(Circle())
            }
            .buttonStyle(GlassPressButtonStyle())
            .modifier(AppleMusicLayoutTransform(entry: layoutEntry(.queue)))
        }
    }
}
