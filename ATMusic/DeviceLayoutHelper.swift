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

    /// 是否处于 iPad 紧凑分屏（1/3 屏或 Slide Over）
    public static func isIPadCompact(_ horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        isIPad && horizontalSizeClass == .compact
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

    /// 依据容器实际像素宽度自适应卡片列数（用于复杂多级分屏如 1/3、1/2、2/3 屏）
    public static func adaptiveCardColumnsByWidth(_ width: CGFloat, spacing: CGFloat = 16) -> [GridItem] {
        if width < 520 {
            // 1/3 屏 / 紧凑窗口：双列
            return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        } else if width < 800 {
            // 1/2 半分屏 / 竖屏：3 列
            return Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3)
        } else if width < 1120 {
            // 2/3 分屏 / 11" 横屏：4 列
            return Array(repeating: GridItem(.flexible(), spacing: spacing), count: 4)
        } else {
            // 12.9" / 13" 横屏大屏：5 列
            return Array(repeating: GridItem(.flexible(), spacing: spacing), count: 5)
        }
    }

    /// 自适应歌曲列表列配置（基于尺寸类与自适应宽度保护）
    /// - iPhone / Compact: 单列直排
    /// - iPad Regular: 采用自适应宽度（最小 280pt），容器空间不足时自动降级为 1 列，杜绝歌名被挤压消失
    public static func songListColumns(
        for horizontalSizeClass: UserInterfaceSizeClass?,
        spacing: CGFloat = 16
    ) -> [GridItem] {
        if isIPadRegular(horizontalSizeClass) {
            return [
                GridItem(.adaptive(minimum: 280, maximum: .infinity), spacing: spacing)
            ]
        } else {
            return [GridItem(.flexible())]
        }
    }

    /// 依据当前容器可用宽度动态分配歌曲网格列（对标 Apple Music iPad 官方流态）
    /// - 容器宽度 < 580pt: 保证 1 列全宽展开（大屏竖屏、1/2 半分屏等场景完美呈现完整歌名、歌手与操作）
    /// - 容器宽度 >= 580pt: 依据 280pt 最小跨度平滑呈现 2~3 列
    public static func songListColumns(
        forAvailableWidth width: CGFloat,
        minWidth: CGFloat = 280,
        spacing: CGFloat = 16
    ) -> [GridItem] {
        if width < 580 {
            return [GridItem(.flexible())]
        } else {
            return [GridItem(.adaptive(minimum: minWidth, maximum: .infinity), spacing: spacing)]
        }
    }

    /// iPad 宽屏下的内容区最大宽度约束（防止横屏内容被无意义拉伸过宽）
    public static func contentMaxWidth(for horizontalSizeClass: UserInterfaceSizeClass?) -> CGFloat? {
        if isIPadRegular(horizontalSizeClass) {
            return 1360
        } else {
            return 860
        }
    }

    /// 每页展示项数自适应（iPad 大屏下展示更多内容以铺满行）
    public static func recommendedItemCount(for horizontalSizeClass: UserInterfaceSizeClass?, compactCount: Int, regularCount: Int) -> Int {
        isIPadRegular(horizontalSizeClass) ? regularCount : compactCount
    }
}
