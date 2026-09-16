import SwiftUI

/// 「剪辑风格」页：一部影片的全局剪辑配置。
///
/// 这一页只放**影片级**的东西——怎么剪（画幅、节奏、音轨）和哪些样式是全局的
/// （常驻图层的位置与文字样式）。每镜具体写什么、数值是多少，仍然写在各个镜头的
/// 分镜描述里，不在这页配。
///
/// 编辑走本地草稿 + 拖后落盘：拖动滑块会连发很多次值，直接每次写一遍
/// `shots.json` 会卡手，所以等手停下来再写（见 `body` 末尾的 `task(id:)`）。
struct FilmStyleView: View {
    @EnvironmentObject private var store: ShotStore

    @State private var draft: FilmStyle = FilmStyle()
    /// 草稿是从哪部影片读进来的。
    ///
    /// 初值 `nil`、且落盘前必须与 `currentFilmID` 相等：页面刚出现时 `draft` 还是
    /// 默认值，读影片的那个任务可能还没跑完，此时若去落盘，会把用户已经配好的
    /// 风格**覆盖成默认值**。这个标记就是那条闸门。
    @State private var loadedFilmID: Film.ID?

    private var sampleCaption: String {
        let note = store.shots.first(where: \.hasNote)?.note
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let note, !note.isEmpty else { return "示例字幕文字" }
        return note.split(separator: "\n").prefix(2).joined(separator: "\n")
    }

    var body: some View {
        List {
            previewSection
            pacingSection
            overlaySection
            typographySection
            audioSection
            presetSection
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, -SLSpacing.groupedListTopSlack, for: .scrollContent)
        .navigationTitle("剪辑风格")
        .task(id: store.currentFilmID) {
            draft = store.currentFilm?.style ?? FilmStyle()
            loadedFilmID = store.currentFilmID
        }
        // 拖滑块会连发很多次：等手停下来再落盘，中途的中间值不写文件。
        // 闸门放在 sleep 之后——睡醒时「读影片」那个任务一定已经跑完了。
        .task(id: draft) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            guard loadedFilmID == store.currentFilmID else { return }
            store.updateStyle(draft)
        }
        // 返回上一页会取消上面那个等待中的任务，最后这一次改动必须在这里补上，
        // 否则「拖完立刻返回」丢掉的就是用户刚调好的值
        .onDisappear {
            guard loadedFilmID == store.currentFilmID else { return }
            store.updateStyle(draft)
        }
    }

    // MARK: - 预览

    private var previewSection: some View {
        Section {
            StylePreview(style: draft, sampleCaption: sampleCaption)
                .frame(maxWidth: .infinity)
                .padding(.vertical, SLSpacing.small)

            Text(tailCardSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            SectionHeader(title: "预览", systemImage: "rectangle.on.rectangle")
        } footer: {
            Text("画面里只画了常驻图层的位置和文字样式；每镜写什么由分镜描述决定。")
        }
    }

    private var tailCardSummary: String {
        guard draft.tailCard.isEnabled else { return "片尾卡：关闭" }
        let lines = draft.tailCard.overlay.text
            .replacingOccurrences(of: "\n", with: " / ")
            .replacingOccurrences(of: "{value}", with: "768")
        return "片尾卡：\(slShort(draft.tailCard.duration)) 秒 · 黑底 · \(lines)"
    }

    // MARK: - 画幅与节奏

    private var pacingSection: some View {
        Section {
            Picker("画幅", selection: $draft.canvas) {
                ForEach(FilmCanvas.allCases) { canvas in
                    Text(canvas.title).tag(canvas)
                }
            }
            .accessibilityValue(draft.canvas.detail)

            Picker("帧率", selection: $draft.frameRate) {
                ForEach(FilmFrameRate.allCases) { rate in
                    Text(rate.title).tag(rate)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("帧率")

            durationRow("成片总时长", lower: $draft.pacing.targetMinDuration,
                        upper: $draft.pacing.targetMaxDuration, step: 1, range: 5...120)
            durationRow("单个镜头", lower: $draft.pacing.shotMinDuration,
                        upper: $draft.pacing.shotMaxDuration, step: 0.1, range: 0.3...10)

            if !draft.pacing.normalized.canHost(shotCount: store.shots.count, tailCardDuration: tailCardBudget) {
                Label(
                    "\(store.shots.count) 个镜头按最短 \(slShort(draft.pacing.shotMinDuration)) 秒算也放不进总时长，"
                    + "导出时会有一部分镜头被压缩到下限以下。",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        } header: {
            SectionHeader(title: "画幅与节奏", systemImage: "timer")
        } footer: {
            Text("总时长是硬约束：剪辑按这个区间反推每个镜头分到多长，再从素材里裁出那一段。不含片尾卡。")
        }
    }

    private var tailCardBudget: Double {
        draft.tailCard.isEnabled ? draft.tailCard.duration : 0
    }

    /// 「最短 / 最长」两个步进器并排。做成两行而不是一行四列，
    /// 是为了让每条区间单独成行、读起来是一句话。
    private func durationRow(
        _ title: String,
        lower: Binding<Double>,
        upper: Binding<Double>,
        step: Double,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.tiny) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: SLSpacing.medium) {
                stepper("最短", value: lower, step: step, range: range)
                stepper("最长", value: upper, step: step, range: range)
            }
        }
        .padding(.vertical, SLSpacing.tiny)
    }

    private func stepper(
        _ title: String,
        value: Binding<Double>,
        step: Double,
        range: ClosedRange<Double>
    ) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack(spacing: SLSpacing.tiny) {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("\(slShort(value.wrappedValue)) 秒")
                    .font(.subheadline.monospacedDigit())
            }
        }
        .accessibilityLabel("\(title) \(slShort(value.wrappedValue)) 秒")
    }

    // MARK: - 常驻图层

    private var overlaySection: some View {
        Section {
            overlayRows(
                title: "常驻角标",
                caption: "长挂在画面上的那一条，例如热量缺口",
                overlay: $draft.badge,
                defaultMaxLines: 1
            )

            overlayRows(
                title: "分镜字幕",
                caption: "每一镜的说明文字",
                overlay: $draft.caption,
                defaultMaxLines: 2
            )

            tailCardRows
        } header: {
            SectionHeader(title: "常驻图层", systemImage: "text.below.photo")
        } footer: {
            Text("位置与样式是全局的；每个镜头具体写什么、数值是多少，写在该镜头的分镜描述里。")
        }
    }

    @ViewBuilder
    private func overlayRows(
        title: String,
        caption: String,
        overlay: Binding<OverlayStyle>,
        defaultMaxLines: Int
    ) -> some View {
        Toggle(isOn: overlay.isEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityHint(caption)

        if overlay.wrappedValue.isEnabled {
            Picker("位置", selection: anchorBinding(for: overlay)) {
                ForEach(OverlayAnchor.allCases) { anchor in
                    Text(anchor.title).tag(anchor)
                }
            }

            Picker("文案来源", selection: overlay.contentSource) {
                ForEach(OverlayContentSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .accessibilityHint(overlay.wrappedValue.contentSource.detail)

            TextField("文案模板", text: overlay.text, axis: .vertical)
                .lineLimit(1...3)
                .accessibilityLabel("\(title)文案模板")

            Stepper(value: overlay.maxLines, in: 1...4) {
                Text("最多 \(overlay.wrappedValue.maxLines) 行")
                    .font(.subheadline)
            }
            .accessibilityLabel("\(title)最多几行")
        }
    }

    /// 选位置时把预设比例一起写进 `offsetYRatio`。
    ///
    /// 两个值必须同步改：`anchor` 是给人看的名字，`offsetYRatio` 是导出规格里
    /// 剪辑侧真正用的数。只改名字不改数字，就会出现「写的是画面正中、
    /// 实际还贴在顶部」这种对不上的情况。
    private func anchorBinding(for overlay: Binding<OverlayStyle>) -> Binding<OverlayAnchor> {
        Binding(
            get: { overlay.wrappedValue.anchor },
            set: { anchor in
                overlay.wrappedValue.anchor = anchor
                overlay.wrappedValue.offsetYRatio = anchor.defaultOffsetYRatio
            }
        )
    }

    @ViewBuilder
    private var tailCardRows: some View {
        Toggle(isOn: $draft.tailCard.overlay.isEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("片尾卡").font(.headline)
                Text("全片结尾的一屏结论").font(.caption).foregroundStyle(.secondary)
            }
        }

        if draft.tailCard.isEnabled {
            Stepper(value: $draft.tailCard.duration, in: 0.3...3, step: 0.1) {
                Text("时长 \(slShort(draft.tailCard.duration)) 秒")
                    .font(.subheadline.monospacedDigit())
            }
            .accessibilityLabel("片尾卡时长 \(slShort(draft.tailCard.duration)) 秒")

            TextField("片尾文案", text: $draft.tailCard.overlay.text, axis: .vertical)
                .lineLimit(1...3)
                .accessibilityLabel("片尾卡文案")
        }
    }

    // MARK: - 文字样式

    private var typographySection: some View {
        Section {
            Picker("字体", selection: $draft.typography.family) {
                ForEach(FilmFontFamily.allCases) { family in
                    Text(family.title).tag(family)
                }
            }

            Picker("字重", selection: $draft.typography.weight) {
                ForEach(FilmFontWeight.allCases) { weight in
                    Text(weight.title).tag(weight)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("字重")

            ratioRow("字号", value: $draft.typography.sizeRatio, range: 0.02...0.10, step: 0.001)
            ratioRow("描边", value: $draft.typography.strokeRatio, range: 0...0.012, step: 0.0005)
        } header: {
            SectionHeader(title: "文字样式", systemImage: "character")
        } footer: {
            Text("字号与描边按屏高比例给出，导 4K 和导 1080p 都是同一个观感。没有单独设置样式的图层都用这套。")
        }
    }

    /// 比例类参数：滑块 + 百分比读数。滑块不显示刻度，读数才是准的。
    private func ratioRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.tiny) {
            HStack {
                Text(title).font(.subheadline)
                Spacer(minLength: SLSpacing.small)
                Text(percentText(value.wrappedValue))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(percentText(value.wrappedValue))
        }
        .padding(.vertical, SLSpacing.tiny)
    }

    private func percentText(_ ratio: Double) -> String {
        String(format: "%.1f%%", ratio * 100)
    }

    // MARK: - 音轨

    private var audioSection: some View {
        Section {
            Picker("音轨", selection: $draft.audio.mode) {
                ForEach(FilmAudioMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("音轨")
            .accessibilityHint(draft.audio.mode.detail)

            if draft.audio.mode == .original {
                ratioRow("原声音量", value: $draft.audio.originalGain, range: 0...1, step: 0.05)
            }
        } header: {
            SectionHeader(title: "音轨", systemImage: "waveform")
        } footer: {
            Text(draft.audio.mode.detail)
        }
    }

    // MARK: - 方案

    private var presetSection: some View {
        Section {
            ForEach(FilmStylePreset.all) { preset in
                Button {
                    draft = preset.style
                    store.applyStylePreset(preset)
                    Haptics.selection()
                } label: {
                    HStack(spacing: SLSpacing.medium) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title).font(.headline)
                            Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if draft == preset.style {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .frame(minHeight: SLSize.minTouchTarget)
                }
                .accessibilityHint("把「\(preset.title)」的参数套到这部影片上")
            }
        } header: {
            SectionHeader(title: "方案", systemImage: "wand.and.stars")
        } footer: {
            Text("套用方案会覆盖当前的全部参数，套完还可以逐项再改。")
        }
    }
}

// MARK: - 预览画幅

/// 9:16 画幅预览：按当前风格把常驻图层画在它真实的位置上。
///
/// 预览不接真实素材——素材在另一个页面，这里只需要回答一个问题：
/// 「角标贴在哪儿、字多大」。
private struct StylePreview: View {
    let style: FilmStyle
    let sampleCaption: String

    private let aspect: CGFloat = 9.0 / 16.0

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = width / aspect

            ZStack {
                RoundedRectangle(cornerRadius: SLSize.cardCornerRadius, style: .continuous)
                    .fill(Color(white: 0.16))

                if style.badge.isEnabled {
                    OutlinedText(
                        text: resolved(style.badge.text, fallback: "热量缺口：1500千卡"),
                        typography: style.typography,
                        frameHeight: height,
                        lines: style.badge.maxLines
                    )
                    .position(x: width / 2, y: height * style.badge.offsetYRatio)
                }

                if style.caption.isEnabled {
                    OutlinedText(
                        text: resolved(style.caption.text, fallback: sampleCaption),
                        typography: style.typography,
                        frameHeight: height,
                        lines: style.caption.maxLines
                    )
                    .position(x: width / 2, y: height * style.caption.offsetYRatio)
                }
            }
            .frame(width: width, height: height)
            .overlay(alignment: .bottomTrailing) {
                Text("\(style.canvas.width)×\(style.canvas.height)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(SLSpacing.small)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("剪辑风格预览")
            .accessibilityValue(previewDescription)
        }
        .aspectRatio(aspect, contentMode: .fit)
    }

    /// 模板里没有占位符时用示例文字，免得预览是一块空白。
    private func resolved(_ template: String, fallback: String) -> String {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return trimmed.replacingOccurrences(of: "{value}", with: "1500")
    }

    private var previewDescription: String {
        var parts: [String] = []
        if style.badge.isEnabled { parts.append("角标在\(style.badge.anchor.title)") }
        if style.caption.isEnabled { parts.append("字幕在\(style.caption.anchor.title)") }
        return parts.isEmpty ? "没有开启任何图层" : parts.joined(separator: "，")
    }
}

/// 带描边的文字。
///
/// SwiftUI 没有文字描边，用八向偏移的同字叠加近似：外圈画黑字、中间盖白字。
/// 偏移量按「描边占屏高比例 ÷ 字号占屏高比例 × 预览字号」换算，与成片里
/// 剪辑侧实际用的比例一致——预览看到多粗，导出就是多粗。
private struct OutlinedText: View {
    let text: String
    let typography: TextTypography
    let frameHeight: CGFloat
    let lines: Int

    private var fontSize: CGFloat {
        max(CGFloat(typography.sizeRatio) * frameHeight, 8)
    }

    private var strokeWidth: CGFloat {
        let ratio = (typography.sizeRatio > 0 ? typography.strokeRatio / typography.sizeRatio : 0)
        // 预览很小的时候描边会糊成一片，压到预览字号的 12% 以内保证还能读
        return min(max(CGFloat(ratio) * fontSize, 0.5), fontSize * 0.12)
    }

    private var offsets: [CGSize] {
        let w = strokeWidth
        return [
            CGSize(width: -w, height: 0), CGSize(width: w, height: 0),
            CGSize(width: 0, height: -w), CGSize(width: 0, height: w),
            CGSize(width: -w, height: -w), CGSize(width: w, height: -w),
            CGSize(width: -w, height: w), CGSize(width: w, height: w)
        ]
    }

    var body: some View {
        ZStack {
            ForEach(Array(offsets.enumerated()), id: \.offset) { _, offset in
                label(typography.strokeColorHex)
                    .offset(x: offset.width, y: offset.height)
            }
            label(typography.colorHex)
        }
        .lineLimit(lines)
        .multilineTextAlignment(.center)
        .frame(maxWidth: frameHeight * 9 / 16 * 0.88)
        .accessibilityHidden(true)
    }

    private func label(_ hex: String) -> some View {
        Text(text)
            .font(.system(size: fontSize, weight: typography.weight.swiftUIWeight))
            .foregroundStyle(Color(slHex: hex))
            .multilineTextAlignment(.center)
    }
}

// MARK: - 颜色

nonisolated extension Color {
    /// `#RRGGBB` / `#RGB` 形式的颜色。解析不出来时回退到白色——
    /// 风格配置是从 JSON 读回来的，写坏了一个色值不该让整页崩掉。
    init(slHex hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else {
            self = .white
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

#Preview {
    NavigationStack {
        FilmStyleView()
            .environmentObject(ShotStore())
    }
}
