import SwiftUI
import UIKit

/// 分镜卡片左侧的视频位。
///
/// - 已拍：显示视频首帧，右下角压一条时长，同一个镜头拍了多条时左上角标注条数；
/// - 未拍：显示虚线框 + 加号，提示这里可以添加视频。
///
/// 角标一律用 `overlay(alignment:)` 叠在画面上，而不是在 `ZStack` 里用
/// 无限画幅对齐 —— 首帧是 `scaledToFill` 铺满的，会比外框高出一截，
/// 放在 ZStack 里会把角标一起顶出可视区域。
struct ClipThumbnailView: View {
    let url: URL?
    var size: CGSize = SLSize.thumbnail
    var showsPlayGlyph: Bool = true
    /// 叠加在缩略图右下角的时长，例如「0:06」
    var durationText: String?
    /// 这个镜头一共拍了几条，超过 1 条时在左上角标注
    var takeCount: Int = 1

    @State private var image: UIImage?

    private var isRecorded: Bool { url != nil }

    var body: some View {
        picture
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .center) {
                if isRecorded, showsPlayGlyph, image != nil {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.35))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isRecorded, let durationText {
                    ThumbnailChip { Text(durationText) }
                }
            }
            .overlay(alignment: .topLeading) {
                if isRecorded, takeCount > 1 {
                    ThumbnailChip {
                        HStack(spacing: 2) {
                            Image(systemName: "square.stack.3d.up.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text("\(takeCount)")
                                .monospacedDigit()
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if !isRecorded {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            Color.accentColor.opacity(0.55),
                            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                        )
                }
            }
            .accessibilityHidden(true)
            .task(id: url) { await loadImage() }
    }

    @ViewBuilder
    private var picture: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else if isRecorded {
            Color(.tertiarySystemFill)
                .overlay {
                    ProgressView().controlSize(.small)
                }
        } else {
            Color(.tertiarySystemFill)
                .overlay {
                    Image(systemName: "plus")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
        }
    }

    private func loadImage() async {
        guard let url else {
            image = nil
            return
        }
        if let cached = ThumbnailLoader.shared.cachedThumbnail(for: url) {
            image = cached
            return
        }
        image = nil

        let loaded = await ThumbnailLoader.shared.thumbnail(for: url)

        // `.task(id: url)` 在 url 变化时会取消上一个任务。被取消说明这张图
        // 已经不是当前要显示的那张了，迟到的结果必须丢掉，否则会盖住新图。
        guard !Task.isCancelled else { return }
        image = loaded
    }
}

/// 压在缩略图上的小标签（时长、条数）。深色半透明底 + 白色文字，
/// 在亮画面和暗画面上都能读清。
struct ThumbnailChip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(4)
    }
}

/// 卡片按下的轻微反馈；开启「减弱动态效果」时不做缩放。
struct ShotCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
