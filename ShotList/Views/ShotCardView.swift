import SwiftUI

/// 分镜卡片 —— 需求里的「可点击添加视频的模块」。
///
/// 整张卡片是一个 `Button`，点击后弹出拍摄 / 导入 / 片段管理。
/// 卡片上只保留编号与分镜描述，时长压在缩略图上、条数标在缩略图左上角，
/// 状态徽标不在这里重复，避免一行字旁边挂三四个标签。
/// 在无障碍字号下改为上下布局，避免文字被挤压。
struct ShotCardView: View {
    let shot: Shot
    let clipURL: URL?
    var onTap: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

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
                thumbnail(size: CGSize(width: 148, height: 100))
                details
            }
        } else {
            HStack(alignment: .top, spacing: SLSpacing.medium) {
                thumbnail(size: SLSize.thumbnail)
                details
                Spacer(minLength: 0)
            }
        }
    }

    private func thumbnail(size: CGSize) -> some View {
        ClipThumbnailView(
            url: clipURL,
            size: size,
            durationText: shot.durationText,
            takeCount: shot.clipCount
        )
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: SLSpacing.tiny) {
            HStack(alignment: .firstTextBaseline, spacing: SLSpacing.small) {
                Text("镜头 \(shot.paddedNumber)")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer(minLength: SLSpacing.small)

                if let recordedAt = shot.shortRecordedAtText {
                    Text(recordedAt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }

            if shot.hasNote {
                Text(shot.note)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            metaRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var metaRow: some View {
        if shot.hasClip {
            if shot.clipCount > 1 {
                Text("共 \(shot.clipCount) 段 · 总时长 \(shot.totalDuration.slDurationText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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
                shot: Shot(number: 1, note: "无人机缓慢上升，配一句开场旁白"),
                clipURL: nil,
                onTap: {}
            )
            ShotCardView(
                shot: Shot(
                    number: 2,
                    note: "手持稳定器横摇，保持水平，速度放慢",
                    clips: [
                        ShotClip(fileName: "a.mov", duration: 7, recordedAt: Date()),
                        ShotClip(fileName: "b.mov", duration: 9, recordedAt: Date())
                    ]
                ),
                clipURL: nil,
                onTap: {}
            )
            ShotCardView(
                shot: Shot(
                    number: 3,
                    note: "手冲壶出水特写，收环境音",
                    clips: [ShotClip(fileName: "c.mov", duration: 12, recordedAt: Date())]
                ),
                clipURL: nil,
                onTap: {}
            )
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
}
