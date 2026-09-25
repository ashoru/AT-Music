import SwiftUI
import UIKit

@main
struct ATMusicApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var auth = AuthStore()
    @StateObject private var player = PlayerManager()
    @StateObject private var theme = ThemeStore.shared
    @StateObject private var favorites = FavoritesStore.shared
    /// 免责声明确认状态：未确认前主界面在模糊层下方可见，确认后移除门禁
    @AppStorage("atmusic.disclaimerAccepted") private var disclaimerAccepted = false
    @AppStorage("atmusic.language") private var languageRaw = AppLanguage.chinese.rawValue

    init() {
        // 1.8 的页面基准是 Apple 简洁布局。旧版本曾把液态/紧凑样式持久化下来，
        // 只改默认值不会影响已经安装过的用户，所以这里做一次显式迁移。
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "atmusic.reference18LayoutMigrated") {
            defaults.set(ATMusicUIStyle.nativeClean.rawValue, forKey: "atmusic.uiStyle")
            defaults.set(true, forKey: "atmusic.reference18LayoutMigrated")
            ThemeStore.shared.setUIStyle(.nativeClean)
        }
        // 闪退检测：优先初始化，检测上次异常退出并安装崩溃捕获
        _ = CrashReporter.shared
        // 主页暂停只应在设置页打开期间生效，避免异常退出后把暂停状态永久写入本地。
        UserDefaults.standard.set(false, forKey: "atmusic.pauseHomeRendering")
        // 旧版在播放页直接叠加的布局调试条已由真机预览布局编辑器取代。
        UserDefaults.standard.set(false, forKey: PlayerLayoutStore.modeKey)
        // 刷新率交给 iOS / ProMotion 自适应调度，不再强制 120Hz。
        HighRefreshKeeper.registerDefaults()
        UserDefaults.standard.register(defaults: [
            "atmusic.uiStyle": ATMusicUIStyle.nativeClean.rawValue,
            "atmusic.reference18LayoutMigrated": true,
            "atmusic.hideDynamicEffects": false,
            "atmusic.hideLiquidGlass": true,
            "atmusic.hideAppearanceToggle": false,
            "atmusic.coverPlayerStyle": ATMusicCoverPlayerStyle.appleMusic.rawValue,
            "atmusic.appleMusic.showVolume": false,
            "atmusic.homeHideUsername": true,
            "atmusic.homeHeaderHideSort": true,
            "atmusic.homeHeaderHideRefresh": true,
            PlatformPreferenceStore.hidePickerKey: true,
            "atmusic.homeWallpaperBlur": 0.0,
            "atmusic.haptics.enabled": true,
            "atmusic.playback.autoResumeLast": false,
            "atmusic.playback.autoSkipOnFailure": true
        ])
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environmentObject(auth)
                    .environmentObject(player)
                    .environmentObject(theme)
                    .environmentObject(favorites)
                // 未确认前展示首次使用引导页（分页引导 + 免责确认）
                if !disclaimerAccepted {
                    OnboardingView { disclaimerAccepted = true }
                }
            }
            .environment(\.locale, Locale(identifier: languageRaw))
            .task {
                // 先让系统完成首帧，再恢复仅影响已安装用户的数据与媒体偏好。
                await Task.yield()
                player.restorePersistedPlayMode()
                player.resumePersistedPlaybackIfEnabled()
                FontManager.reinstallIfNeeded()
                theme.restoreWallpapersIfNeeded()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
            }
        }
    }
}
