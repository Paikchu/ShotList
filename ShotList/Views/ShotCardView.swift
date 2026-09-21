import SwiftUI

/// 分镜卡片 —— 需求里的「可点击添加视频的模块」。
///
/// 整张卡片是一个 `Button`，点击后弹出拍摄 / 导入 / 片段管理。
/// 还没拍的镜头上，虚线加号是另一个独立的点击目标（`onCapture`），点它直接进这个镜头的相机；
/// 它不能嵌在卡片那个 `Button` 的标签里（内层按钮会被外层吞掉或双触发），
/// 所以是叠在卡片之上、与缩略图位重合的一层（见 `captureTarget`）。
/// 卡片上只保留编号与分镜内容，时长压在缩略图上、条数标在缩略图左上角，
/// 拍摄时间、总时长、状态徽标都不在这里重复，避免一行字旁边挂三四个标签。
/// 还没拍的镜头也不写「点击拍摄或导入视频」——虚线框加号与可点的整卡已经说明可以加视频，
/// 一句提示在每个未拍镜头上重复一遍只是噪声（无障碍那条更完整的说法在 `accessibilityHint`）。
/// 描述还没写时，描述位置画一道虚线占位（虚线在这套界面里一直是「这里还没有内容」的意思，
/// 见缩略图的虚线框），不写「待填写」之类的文案。
/// 在无障碍字号下改为上下布局，避免文字被挤压。
///
/// **分镜页的卡片一样高**：文字块固定为三行主文字的高度，
/// 已拍还是未拍、内容写了几行都不改变它，一列卡片才不会忽高忽低；
/// 缩略图在卡片里垂直居中。
struct ShotCardView: View {
    let shot: Shot
    let clipURL: URL?
    /// 编号是否由卡片自己承担。
    ///
    /// 「分镜」页把编号放在左侧的时间线节点上，卡片这一行让给分镜描述，因此传 `false`；
    /// 「历史」页没有时间线，编号仍旧由卡片承担。
    var showsNumber: Bool = true
    /// 是不是刚插进来的。用 accent 描边把「就是这一张」指出来，约一秒后由调用方收回。
    var isNew: Bool = false
    /// 卡片按哪条片段展示（缩略图与时长都跟它走）。
    ///
    /// 传 `nil` 时用最近一条——全应用的默认口径；历史页按天翻看时传
    /// 「当天最新的一条」，缩略图就落在选中的那一天。
    var displayClip: ShotClip? = nil
    /// 覆盖角标条数的口径（如「只数当天拍下的几条」）；传 `nil` 时数全部片段。
    var takeCountOverride: Int? = nil
    /// 直接拍这个镜头。只对还没有视频的镜头生效（虚线加号成为独立点击目标，
    /// 并在无障碍里多一个「拍摄」操作）；传 `nil` 则加号与整卡一样只是打开面板。
    var onCapture: (() -> Void)? = nil
    var onTap: () -> Void

    /// 实际展示的片段：外部指定优先，否则回落到最近一条
    private var effectiveClip: ShotClip? { displayClip ?? shot.latestClip }
    private var effectiveTakeCount: Int { takeCountOverride ?? shot.clipCount }

    /// 缩略图走到虚线加号那一支的条件是 `url == nil`（`ClipThumbnailView.isRecorded`），
    /// 这里用同一个判据，加号在哪儿出现、哪儿可点永远一致。
    private var captureAction: (() -> Void)? { clipURL == nil ? onCapture : nil }

    /// 卡片内容与卡片边缘的距离；叠在上面的拍摄点击目标要按它对齐缩略图。
    private static let contentInset = SLSpacing.medium
    /// 无障碍字号下缩略图改为上下布局时的尺寸
    private static let stackedThumbnailSize = CGSize(width: 148, height: 100)

    var accessibilityDescription: String {
        var parts = ["镜头 \(shot.number)"]
        if shot.hasNote { parts.append(shot.displayDetail) }
        if let clip = effectiveClip {
            parts.append("\(effectiveTakeCount) 段")
            if let duration = clip.durationText { parts.append("时长 \(duration)") }
        } else {
            parts.append("未拍")
        }
        return parts.joined(separator: "，")
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: onTap) {
            content
                .padding(Self.contentInset)
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
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint(shot.accessibilityActionHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            // 卡片对读屏是一个合并的按钮，加号不会单独被读到；用自定义操作补上，默认操作仍是打开面板
            if let captureAction {
                Button("拍摄", action: captureAction)
            }
        }
        .overlay(alignment: typeSize.isAccessibilitySize ? .topLeading : .leading) {
            if let captureAction {
                captureTarget(action: captureAction)
            }
        }
    }

    /// 叠在缩略图位置上的透明点击目标，大小与位置跟 `content` 里的缩略图重合。
    /// 对读屏隐藏——它的功能由卡片上的「拍摄」自定义操作承担，不多出一个元素。
    private func captureTarget(action: @escaping () -> Void) -> some View {
        let size = typeSize.isAccessibilitySize ? Self.stackedThumbnailSize : SLSize.thumbnail
        return Button(action: action) {
            Color.clear
                .frame(width: size.width, height: size.height)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(ThumbnailCaptureButtonStyle())
        .padding(Self.contentInset)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: SLSpacing.medium) {
                thumbnail(size: Self.stackedThumbnailSize)
                details
            }
        } else {
            // 缩略图垂直居中；文字块顶部对齐（见 `details`），文字比缩略图高时缩略图仍在卡片正中
            HStack(alignment: .center, spacing: SLSpacing.medium) {
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
            durationText: effectiveClip?.durationText,
            takeCount: effectiveTakeCount
        )
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: SLSpacing.tiny) {
            titleRow

            if showsNumber, shot.hasNote {
                noteText
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 主行：编号（历史页）或分镜内容（分镜页），这一行整行都留给它
    @ViewBuilder
    private var titleRow: some View {
        if showsNumber {
            Text("镜头 \(shot.paddedNumber)")
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // 一块固定三行高的区域：底下垫一个看不见的三行文字撑住高度，
            // 内容不足三行、还没写内容（占位虚线在这块里垂直居中）都不改变卡片高度。
            // 内容常常是逐行的「标签：内容」，字号取小一号，一行才装得下更多字；
            // 看不见的那行必须与真正的文字同一个字体，否则撑出来的高度对不上。
            ZStack(alignment: .topLeading) {
                Text(" ")
                    .font(.subheadline)
                    .lineLimit(3, reservesSpace: true)
                    .hidden()

                if shot.hasNote {
                    Text(shot.note)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    NotePlaceholder()
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
