import SwiftUI
import UIKit

/// 设备形态与自适应布局辅助工具
/// 确保 iPadOS 享有媲美 Apple Music 的大屏多栏网格体验，同时 100% 保持 iPhone 原有界面的紧凑设计。
public struct DeviceLayoutHelper {
    /// 是否为 iPad 设备形态
    public static var isIPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    /// 当前环境是否应当使用 iPad 宽屏多栏/侧栏布局
    /// 仅在物理 iPad 且处于 regular 尺寸类（全屏或大分屏）时生效；
    /// 当处于 iPad 1/3 窄分屏（Slide Over / 紧凑模式）或 iPhone 时，自动回退到原生单栏 TabView 体验。
    public static func isIPadRegular(_ horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        isIPad && horizontalSizeClass == .regular
    }

    /// 自适应歌单/专辑网格列配置
    /// - iPhone / Compact: 保持 2 列
    /// - iPad Regular: 依据屏幕宽度自适应 3 ~ 6 列（卡片宽度 160 ~ 240pt）
    public static func adaptiveCardColumns(
        for horizontalSizeClass: UserInterfaceSizeClass?,
        minWidth: CGFloat = 160,
        maxWidth: CGFloat = 240,
        spacing: CGFloat = 16
    ) -> [GridItem] {
        if isIPadRegular(horizontalSizeClass) {
            return [GridItem(.adaptive(minimum: minWidth, maximum: maxWidth), spacing: spacing)]
        } else {
            return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        }
    }

    /// 自适应歌曲列表列配置
    /// - iPhone / Compact: 单列直排
    /// - iPad Regular: 左右双列并排（类似 iPadOS Apple Music 歌单与搜索歌曲展示）
    public static func songListColumns(
        for horizontalSizeClass: UserInterfaceSizeClass?,
        spacing: CGFloat = 16
    ) -> [GridItem] {
        if isIPadRegular(horizontalSizeClass) {
            return [
                GridItem(.flexible(), spacing: spacing),
                GridItem(.flexible(), spacing: spacing)
            ]
        } else {
            return [GridItem(.flexible())]
        }
    }

    /// iPad 宽屏下的内容区最大宽度约束（防止横屏内容被无意义拉伸过宽）
    public static func contentMaxWidth(for horizontalSizeClass: UserInterfaceSizeClass?) -> CGFloat? {
        if isIPadRegular(horizontalSizeClass) {
            return 1280
        } else {
            return 860
        }
    }

    /// 每页展示项数自适应（iPad 大屏下展示更多内容以铺满行）
    public static func recommendedItemCount(for horizontalSizeClass: UserInterfaceSizeClass?, compactCount: Int, regularCount: Int) -> Int {
        isIPadRegular(horizontalSizeClass) ? regularCount : compactCount
    }
}
