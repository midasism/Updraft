import AppKit
import SwiftUI

/// 全局视觉规范：间距、圆角、色彩与字体层级统一从这里走。
/// 只承载视觉常量与容器修饰器，不包含任何业务逻辑。
/// 颜色全部走语义化 NSColor / 系统色，深浅色模式自动适配。
enum Theme {

    // MARK: - 间距（8 点网格）

    enum Spacing {
        /// 微间距：图标与文字、行内元素
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        /// 组件内部留白
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        /// 区块间距
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - 圆角（连续曲率，向系统质感看齐）

    enum Radius {
        /// 按钮、标签、警示条
        static let small: CGFloat = 6
        /// 卡片、分组容器
        static let medium: CGFloat = 10
        /// 应用图标占位
        static let icon: CGFloat = 9
    }

    // MARK: - 颜色

    enum Colors {
        /// 卡片 / 分组容器底
        static let card = Color(nsColor: .controlBackgroundColor)
        /// 卡片描边：比阴影更克制的分层方式
        static let cardBorder = Color.primary.opacity(0.06)
        /// 文本底色（日志区）
        static let textSurface = Color(nsColor: .textBackgroundColor)
        /// 可更新 / 需注意
        static let attention = Color(nsColor: .systemOrange)
        /// 成功 / 已是最新
        static let success = Color(nsColor: .systemGreen)
        /// 警示条底色
        static let attentionWash = Color(nsColor: .systemOrange).opacity(0.08)
    }

    // MARK: - 字体层级（系统字体，Dynamic Type 友好的固定层级）

    enum Fonts {
        /// 页面 / 面板主标题
        static let title = Font.system(size: 16, weight: .semibold)
        /// 面板标题（sheet 内）
        static let panelTitle = Font.system(size: 15, weight: .semibold)
        /// 列表主文案
        static let body = Font.system(size: 13, weight: .medium)
        /// 辅助说明
        static let caption = Font.system(size: 12, weight: .regular)
        /// 弱化的补充信息
        static let note = Font.system(size: 11, weight: .regular)
        /// 统计大数字：圆角数字更有温度
        static let statValue = Font.system(size: 26, weight: .semibold, design: .rounded)
        /// 日志等宽
        static let mono = Font.system(size: 11, design: .monospaced)
    }
}

// MARK: - 卡片容器

/// 卡片容器：浅底 + 细描边 + 连续圆角，取代纯色块的分层方式。
private struct CardContainer: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.Colors.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(Theme.Colors.cardBorder, lineWidth: 1)
            )
    }
}

extension View {
    /// 统一的卡片外观（底色 + 描边 + 连续圆角）。
    func cardContainer() -> some View {
        modifier(CardContainer())
    }
}
