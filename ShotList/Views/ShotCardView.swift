import SwiftUI

/// 分镜卡片 —— 需求里的「可点击添加视频的模块」。
///
/// 整张卡片是一个 `Button`，点击后弹出拍摄 / 导入 / 片段管理。
/// 卡片上只保留编号与分镜描述，时长压在缩略图上、条数标在缩略图左上角，
/// 状态徽标不在这里重复，避免一行字旁边挂三四个标签。
/// 还没拍的镜头也不写「点击拍摄或导入视频」——虚线框加号与可点的整卡已经说明可以加视频，
/// 一句提示在每个未拍镜头上重复一遍只是噪声（无障碍那条更完整的说法在 `accessibilityHint`）。
/// 描述还没写时，描述位置画一道虚线占位（虚线在这套界面里一直是「这里还没有内容」的意思，
/// 见缩略图的虚线框），不写「待填写」之类的文案。
/// 在无障碍字号下改为上下布局，避免文字被挤压。
struct ShotCardView: View {
    let shot: Shot
    let clipURL: URL?
    /// 编号是否由卡片自己承担。
    ///
    /// 「分镜」页把编号放在左侧的时间线节点上，卡片这一行让给分镜描述，因此传 `false`；
    /// 「今日」页没有时间线，编号仍旧由卡片承担。
    var showsNumber: Bool = true
    /// 是不是刚插进来的。用 accent 描边把「就是这一张」指出来，约一秒后由调用方收回。
    var isNew: Bool = false
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
                        .strokeBorder(
                            isNew ? Color.accentColor : Color.primary.opacity(0.06),
                            lineWidth: isNew ? 1.5 : 1
                        )
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
            HStack(alignment: hasTextContent ? .top : .center, spacing: SLSpacing.medium) {
                thumbnail(size: SLSize.thumbnail)
                details
                Spacer(minLength: 0)
            }
        }
    }

    /// 卡片有没有真正的文字内容。
    ///
    /// 只用来决定缩略图与文字块的垂直对齐：分镜页还没写描述时只剩一行占位，
    /// 这一行跟缩略图居中对齐才不会吊在顶上；写了描述（最多三行）就顶部对齐。
    private var hasTextContent: Bool { showsNumber || shot.hasNote }

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
            titleRow

            if showsNumber, shot.hasNote {
                noteText
            }

            metaRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 主行：编号（今日页）或分镜描述（分镜页），这一行整行都留给它
    @ViewBuilder
    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: SLSpacing.small) {
            if showsNumber {
                Text("镜头 \(shot.paddedNumber)")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else if shot.hasNote {
                Text(shot.note)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                NotePlaceholder()
            }

            Spacer(minLength: 0)
        }
    }

    private var noteText: some View {
        Text(shot.note)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 卡片末行：左侧总时长（拍过不止一条时才有）、右侧最近一次拍摄时间。
    ///
    /// 未拍的镜头**整行不画**。这里原本是一句「点击拍摄或导入视频」，但左侧虚线框里的
    /// 加号、以及「整张卡片可点」已经表达了同一件事，VoiceOver 那边还有更完整的
    /// `accessibilityActionHint`；真正的问题是一行挂一句提示语，列表里每个还没拍的
    /// 镜头都会重复一遍。
    @ViewBuilder
    private var metaRow: some View {
        if shot.hasClip {
            HStack(alignment: .firstTextBaseline, spacing: SLSpacing.small) {
                if shot.clipCount > 1 {
                    // 条数已经标在缩略图角标上，这里只补一个总数
                    Text("总时长 \(shot.totalDuration.slDurationText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: SLSpacing.small)

                if let recordedAt = shot.shortRecordedAtText {
                    Text(recordedAt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
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
            // 描述还没写：占位虚线
            ShotCardView(
                shot: Shot(number: 4, note: ""),
                clipURL: nil,
                onTap: {}
            )
            // 刚插进来的：accent 描边
            ShotCardView(
                shot: Shot(number: 5, note: ""),
                clipURL: nil,
                isNew: true,
                onTap: {}
            )
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
}
