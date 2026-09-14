import SwiftUI
import UIKit

/// 分镜卡片左侧的视频位。
///
/// - 已拍：显示视频首帧，并在右下角标注时长；
/// - 未拍：显示虚线框 + 加号，提示这里可以添加视频。
struct ClipThumbnailView: View {
    let url: URL?
    var size: CGSize = SLSize.thumbnail
    var showsPlayGlyph: Bool = true

    @State private var image: UIImage?

    private var isRecorded: Bool { url != nil }

    var body: some View {
        ZStack {
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

            if isRecorded, showsPlayGlyph, image != nil {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(width: size.width, height: size.height)
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
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let cached = ThumbnailLoader.shared.cachedThumbnail(for: url) {
                image = cached
                return
            }
            image = nil
            ThumbnailLoader.shared.thumbnail(for: url) { loaded in
                image = loaded
            }
        }
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
