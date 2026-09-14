import SwiftUI

/// 分镜卡片 —— 需求里的「可点击添加视频的模块」。
///
/// 整张卡片是一个 `Button`，点击后弹出拍摄 / 导入 / 播放等操作。
/// 在无障碍字号下改为上下布局，避免文字被挤压。
struct ShotCardView: View {
    let shot: Shot
    let clipURL: URL?
    var onTap: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var status: ShotStatus { shot.status() }

    var body: some View {
        Button(action: onTap) {
            content
                .padding(SLSpacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: SLSize.cardCornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: SLSize.cardCornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: SLSize.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(ShotCardButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shot.accessibilityDescription)
        .accessibilityHint(shot.accessibilityActionHint)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var content: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: SLSpacing.medium) {
                ClipThumbnailView(url: clipURL, size: CGSize(width: 132, height: 88))
                details
            }
        } else {
            HStack(alignment: .top, spacing: SLSpacing.medium) {
                ClipThumbnailView(url: clipURL)
                details
                Spacer(minLength: 0)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: SLSpacing.tiny) {
            HStack(alignment: .firstTextBaseline, spacing: SLSpacing.small) {
                Text("镜头 \(shot.paddedNumber)")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer(minLength: SLSpacing.small)

                StatusChip(status: status, compact: true)
            }

            if !shot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(shot.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if shot.hasNote {
                Text(shot.note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            metaRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var metaRow: some View {
        if shot.hasClip {
            HStack(spacing: SLSpacing.small) {
                if let duration = shot.durationText {
                    Label(duration, systemImage: "timer")
                }
                if let recordedAt = shot.recordedAtText {
                    Text(recordedAt)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
            Label("点击拍摄或导入视频", systemImage: "video.badge.plus")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        }
    }
}

#Preview {
    ScrollView {
        VStack(spacing: SLSpacing.medium) {
            ShotCardView(
                shot: Shot(number: 1, title: "开场：城市天际线", note: "无人机慢速上升，配旁白"),
                clipURL: nil,
                onTap: {}
            )
            ShotCardView(
                shot: Shot(
                    number: 2,
                    title: "街景横摇",
                    note: "手持稳定器，注意保持水平",
                    clipFileName: "a.mov",
                    recordedAt: Date(),
                    clipDuration: 12
                ),
                clipURL: nil,
                onTap: {}
            )
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
}
