import SwiftUI

// 界面语言约定（需求 R-1，完整对照表见 Docs/requirements）：
// - 按钮与菜单项只写动词或动宾短语；有通用图标的操作以图标为主，名称放进无障碍标签。
// - 状态与统计用「图标 + 数字」（`IconValue`），不写「已拍 3 / 5 个镜头」这类句子。
// - 空状态只有图标、一个名词短语和至多一个按钮；确认弹层正文只写波及数量与不可恢复。
// - 错误提示写「失败 + 用户能执行的一步」；设计理由与实现取舍不进界面，留在代码注释里。

/// 设计常量。间距统一为 8pt 网格（4pt 仅用于细调）。
enum SLSpacing {
    /// 4pt
    static let tiny: CGFloat = 4
    /// 8pt
    static let small: CGFloat = 8
    /// 16pt
    static let medium: CGFloat = 16
    /// 24pt
    static let large: CGFloat = 24
    /// 32pt
    static let huge: CGFloat = 32

    /// 三个标签页首个内容块上沿距导航栏底部的统一留白（5pt）。
    ///
    /// 三页容器各不相同（分镜＝`List(.plain)`、历史＝`ScrollView`、导出＝`List(.insetGrouped)`），
    /// 各自默认的顶部内边距并不一样：实测同样不加边距时，历史的首张卡片最贴顶，
    /// 分镜的首张卡片要低 1pt，导出的首块内容比统一基准高 5pt。三页都用
    /// `.contentMargins(.top, …)` 显式指定，让首个内容块的上沿落在同一条水平线上：
    /// - **分镜**：行自带 `tiny`（4pt）纵向内边距（时间线导轨要从行顶画到行底），
    ///   加上 List 默认的 1pt，正好 5pt → 不额外加边距；
    /// - **历史**：补 `pageTopInset`；
    /// - **导出**：首块是没有小节标题的素材卡片，与历史一样补 `pageTopInset`。
    static let pageTopInset: CGFloat = 5

    /// `List(.insetGrouped)` 首个小节带标题时，标题默认比统一基准多出的 7pt
    /// （「剪辑风格」页用负的内容边距收回去）。
    static let groupedListTopSlack: CGFloat = 7
}

/// 尺寸常量。
enum SLSize {
    /// Apple HIG 要求的最小触控目标
    static let minTouchTarget: CGFloat = 44
    /// 卡片圆角
    static let cardCornerRadius: CGFloat = 16
    /// 分镜卡片上的视频缩略图
    static let thumbnail = CGSize(width: 100, height: 68)
    /// 片段列表里的缩略图
    static let clipRowThumbnail = CGSize(width: 84, height: 57)
    /// 镜头面板头部的缩略图
    static let headerThumbnail = CGSize(width: 108, height: 72)
    /// 卡片上的编号徽标
    static let numberBadge: CGFloat = 32
    /// 时间线导轨的列宽（竖线与节点都在这条列里居中）
    static let timelineRailWidth: CGFloat = 38
    /// 时间线上的编号节点直径
    static let timelineNode: CGFloat = 26
    /// 相机录制按钮外径
    static let recordButton: CGFloat = 74
    /// 分镜页导航栏标题（影片名）的最大宽度。
    ///
    /// 影片名是用户自己起的，可能很长，而这一栏右边还有「添加」「影片菜单」两个按钮。
    /// 上限按最窄的 iPhone 竖屏算：宽度 375pt − 右侧按钮组（约 116pt）− 标题左边距 20pt
    /// ≈ 230pt。超出时先按 `minimumScaleFactor` 缩到 0.7，再长才截断，不会压到右侧按钮上。
    /// 「历史记录」「导出」是系统标题，由系统自己排版，用不到这个值。
    static let inlineTitleMaxWidth: CGFloat = 230
}

// MARK: - 可复用组件

/// 编号徽标：已拍时填充实心，未拍时描边。
struct NumberBadge: View {
    let number: Int
    let isRecorded: Bool
    var size: CGFloat = SLSize.numberBadge

    var body: some View {
        Text("\(number)")
            .font(.subheadline.weight(.bold).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(isRecorded ? Color.white : Color.accentColor)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(isRecorded ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.accentColor.opacity(0.12)))
            }
            .overlay {
                Circle().strokeBorder(Color.accentColor.opacity(isRecorded ? 0 : 0.35), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

/// 描述还没写时的占位：一道虚线。
///
/// 虚线在这套界面里一直是「这里还没有内容」的意思（缩略图的虚线框也是它），
/// 所以不必写「待填写」之类的文案。分镜卡片与镜头面板头部共用这一个，
/// 免得两处的虚线长度、疏密各走各的。
struct NotePlaceholder: View {
    var width: CGFloat = 96

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 1))
            path.addLine(to: CGPoint(x: width, y: 1))
        }
        .stroke(
            Color.secondary.opacity(0.4),
            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
        )
        .frame(width: width, height: 2)
        .accessibilityHidden(true)
    }
}

/// 时间线导轨：卡片左侧的一条竖线，加一个节点。
///
/// 每一行画「上段竖线 + 节点 + 下段竖线」三截，一行的下段正好接上下一行的上段，
/// 于是整份清单看起来是一条贯通到底的竖线——顺序感就来自这条不断的线。
/// 首行不画上段、末行不画下段，让线从第一个镜头开始、到最后一个镜头结束。
struct TimelineRail<Node: View>: View {
    var isFirst: Bool
    var isLast: Bool
    /// 节点上沿距行顶的距离，用来把节点对齐到卡片里的第一行文字
    var nodeTopPadding: CGFloat
    /// 这一行是不是刚插进来的：上段竖线改用 accent，把「这条线是刚接上的」指出来。
    ///
    /// 只改上段、不改下段——新镜头是从上一个镜头后面「接」出来的，
    /// 它和下面那个镜头的关系并没有变化。
    var isHighlighted: Bool = false
    @ViewBuilder var node: Node

    private let lineWidth: CGFloat = 2

    var body: some View {
        VStack(spacing: 0) {
            if isFirst {
                Color.clear.frame(height: nodeTopPadding)
            } else {
                line(highlighted: isHighlighted).frame(height: nodeTopPadding)
            }

            node

            if isLast {
                Color.clear.frame(maxHeight: .infinity)
            } else {
                line().frame(maxHeight: .infinity)
            }
        }
        .frame(width: SLSize.timelineRailWidth)
        .accessibilityHidden(true)
    }

    private func line(highlighted: Bool = false) -> some View {
        Rectangle()
            .fill(highlighted ? Color.accentColor : Color.primary.opacity(0.12))
            .frame(width: lineWidth)
    }
}

/// 浅色卡片容器，用于各个标签页的分组内容。
struct CardContainer<Content: View>: View {
    var padding: CGFloat = SLSpacing.medium
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: SLSize.cardCornerRadius, style: .continuous))
    }
}

/// 圆形进度环，使用语义色并支持「减弱动态效果」。
struct ProgressRing: View {
    let progress: Double
    var size: CGFloat = 92
    var lineWidth: CGFloat = 10

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var clamped: Double { min(max(progress, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: clamped)
        }
        .frame(width: size, height: size)
        .overlay {
            Text("\(Int((clamped * 100).rounded()))%")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("拍摄进度")
        .accessibilityValue("\(Int((clamped * 100).rounded()))%")
    }
}

/// 「图标 + 数值」：统计与状态的统一写法，图标代替「已拍」「总时长」这类字眼。
///
/// 字号与颜色从外层继承；图标对读屏隐藏，调用方在外层给出完整的朗读文本。
struct IconValue: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: SLSpacing.tiny) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(text)
        }
    }
}

/// 小节标题
struct SectionHeader: View {
    let title: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: SLSpacing.small) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

nonisolated extension TimeInterval {
    /// 「3 分 20 秒」形式
    var slDurationText: String {
        let total = Int(rounded())
        let minutes = total / 60
        let seconds = total % 60
        if minutes == 0 { return "\(seconds) 秒" }
        if seconds == 0 { return "\(minutes) 分" }
        return "\(minutes) 分 \(seconds) 秒"
    }
}

nonisolated extension Int64 {
    /// 文件体积文本
    var slByteText: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: self)
    }
}
