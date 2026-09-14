import SwiftUI

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
}

/// 尺寸常量。
enum SLSize {
    /// Apple HIG 要求的最小触控目标
    static let minTouchTarget: CGFloat = 44
    /// 卡片圆角
    static let cardCornerRadius: CGFloat = 16
    /// 分镜卡片上的视频缩略图
    static let thumbnail = CGSize(width: 92, height: 62)
    /// 卡片上的编号徽标
    static let numberBadge: CGFloat = 32
    /// 相机录制按钮外径
    static let recordButton: CGFloat = 74
}

// MARK: - 可复用组件

/// 状态徽标：图标 + 文字 + 颜色三重表达，不依赖颜色单独传达信息。
struct StatusChip: View {
    let status: ShotStatus
    var compact: Bool = false

    var body: some View {
        Label(status.title, systemImage: status.symbolName)
            .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(status.tint)
            .padding(.horizontal, compact ? SLSpacing.tiny + 2 : SLSpacing.small)
            .padding(.vertical, SLSpacing.tiny)
            .background(status.tint.opacity(0.14), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("拍摄状态：\(status.title)")
    }
}

/// 编号徽标：已拍时填充实心，未拍时描边。
struct NumberBadge: View {
    let number: Int
    let isRecorded: Bool
    var size: CGFloat = SLSize.numberBadge

    var body: some View {
        Text("\(number)")
            .font(.subheadline.weight(.bold).monospacedDigit())
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
            VStack(spacing: 0) {
                Text("\(Int((clamped * 100).rounded()))%")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)
                Text("已完成")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("拍摄进度")
        .accessibilityValue("已完成 \(Int((clamped * 100).rounded()))%")
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

extension TimeInterval {
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

extension Int64 {
    /// 文件体积文本
    var slByteText: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: self)
    }
}
