import SwiftUI

/// 点开一个镜头后弹出的面板：写分镜描述、写屏幕字幕与角标、改编号，继续拍、再导入，
/// 以及管理已经拍好的每一条片段。
///
/// 描述**就在这一页写**，不再跳一个编辑器页面——点开镜头是为了拍，顺手能改描述才顺手；
/// 单独开一页的结果是「只想改一句话也要跳两层、还得点保存」。
/// 同一页上还留着导出文件名预览与编号：文件名由「影片标题 + 镜头编号 + 片段序号」
/// 决定（不含描述），编号即位置（改动会移动镜头），所以预览跟在「顺序」一节里。
///
/// 文字分成三样，各写各的：**描述**是拍什么（给剪辑侧挑素材用），
/// **字幕**是成片上显示的那句话，**角标文字**是常驻角标上要显示的整段字
/// （例如「热量缺口：1758千卡」）。
/// 三样分开之前字幕和角标只能塞在描述里，剪辑侧分不清一句是画面的说明还是要显示的字，
/// 只能靠改写来猜——那正是「不要自行改写语义」这条要求永远守不住的原因。
///
/// 三样文字与编号都按草稿攒 400 毫秒再落盘：每敲一个字写一次 JSON 没必要，
/// 而编号一变就会触发整段重编号 + 磁盘改名，更不能跟着 Stepper 的每次点击跑。
/// 面板关掉时（点「完成」或去做别的）立即落一次，不漏。
struct ClipOptionsSheet: View {
    /// 点开的那个镜头。只借它定位，展示时始终取仓库里的最新数据。
    let shot: Shot
    var onCapture: () -> Void
    var onImport: () -> Void
    var onPlay: (ShotClip) -> Void
    /// 一进来就把光标放进描述输入框。新增 / 插入镜头后走这条路——
    /// 用户此刻要的就是写描述；从卡片点进来时不抢焦点，那是奔着拍摄来的。
    var autoFocusNote: Bool = false

    @EnvironmentObject private var store: ShotStore
    @Environment(\.dismiss) private var dismiss

    /// 导出格式是用户偏好，导出页也读这个键：预览的文件名与最终导出永远同名。
    @AppStorage(ExportTranscodeOption.storageKey) private var transcodeOption: ExportTranscodeOption = .original

    @State private var clipToDelete: ShotClip?
    @State private var showClearConfirm = false
    @State private var showDeleteConfirm = false

    @State private var draftNote: String
    @State private var draftCaption: String
    @State private var draftBadgeText: String
    /// 用户在这一页拨过的编号；没拨过就是 `nil`，编号一律取仓库当前值。
    ///
    /// 不能像三样文字那样在打开时抄一份：这一页开着期间，这个镜头的编号可能被别的路径改掉
    /// （删除补偿找回镜头时会整库重编号）。过期的副本一旦跟着别的字段一起落盘，
    /// 就会把镜头按旧编号挪回原位，用户明明只改了几个字。
    @State private var numberEdit: Int?
    @State private var draftSaveTask: Task<Void, Never>?
    @FocusState private var isNoteFocused: Bool

    init(
        shot: Shot,
        autoFocusNote: Bool = false,
        onCapture: @escaping () -> Void,
        onImport: @escaping () -> Void,
        onPlay: @escaping (ShotClip) -> Void
    ) {
        self.shot = shot
        self.autoFocusNote = autoFocusNote
        self.onCapture = onCapture
        self.onImport = onImport
        self.onPlay = onPlay
        _draftNote = State(initialValue: shot.note)
        _draftCaption = State(initialValue: shot.caption)
        _draftBadgeText = State(initialValue: shot.badgeText)
    }

    private var live: Shot { store.shot(withID: shot.id) ?? shot }

    /// Stepper 与文件名预览显示的编号：拨过就用拨的，否则跟着仓库。
    private var displayedNumber: Int { numberEdit ?? live.number }

    private var numberBinding: Binding<Int> {
        Binding(get: { displayedNumber }, set: { numberEdit = $0 })
    }

    private var numberRange: ClosedRange<Int> {
        1...max(1, store.shots.count)
    }

    /// 「沿用上一镜」此刻能补进来的屏幕文字：只含「上一镜有、这一镜的草稿里还空着」的那几项。
    ///
    /// 上一镜是影片里编号排在前一位的镜头，不是「上一个拍过的」，也不受历史页筛选影响；
    /// 每次现取仓库里的值，链式沿用（3 沿用 2、2 沿用 1）时拿到的是 2 改过之后的内容。
    /// 「这一镜有没有写」看草稿而不是仓库：草稿落盘要等 400 毫秒，
    /// 用户刚敲完或刚清空，按钮就该立刻跟着变。
    ///
    /// 刻意做成**一次性把值抄过来**、**只补空项**：连续几个镜头常常共用同一段字幕或读数，
    /// 但「留空」必须只有一种含义——这一镜不出；隐式沿用会让「不想出」没法表达。
    /// 已经写好的那一项不动，免得抄一下就丢掉用户敲的字。描述不带：它是「拍什么」，每镜不同。
    ///
    /// 第一个镜头、上一镜两项都空、或这一镜两项都已写时返回 `nil`，那个按钮就不出现。
    private var inheritableText: (caption: String?, badgeText: String?)? {
        guard let index = store.index(of: live.id), index > 0 else { return nil }
        let previous = store.shots[index - 1]
        let caption = previous.hasCaption && Self.isBlank(draftCaption) ? previous.trimmedCaption : nil
        let badgeText = previous.hasBadgeText && Self.isBlank(draftBadgeText) ? previous.trimmedBadgeText : nil
        guard caption != nil || badgeText != nil else { return nil }
        return (caption, badgeText)
    }

    /// 与 `Shot.hasCaption` / `hasBadgeText` 同一口径：去首尾空白后为空就算没写。
    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 与导出结果同一套命名规则：改编号或换影片时，这里实时看到最终文件名。
    ///
    /// 文件名是「影片标题-镜头编号[-片段序号]」，**不含描述**：描述是给剪辑侧读的
    /// 整句话，进文件名会又长又容易重名，所以它在 CSV 与指南里，不在这里。
    ///
    /// 扩展名取自该镜头主素材的真实格式（相册导入的 mp4 导出后仍是 mp4）；
    /// 导出页选了转码格式时换成转码后的容器——预览与打包读的是同一个函数，
    /// 不会出现「预览写 .mp4、导出却是 .mov」。
    /// 镜头拍了多条时，主素材（按拍摄时间选择的最新一条）带片段序号，
    /// 与 `ExportPackageBuilder.build` 的落盘命名保持一致；只拍一条时不带。
    private var previewFileName: String {
        ExportPackageBuilder.exportedFileName(
            filmTitle: store.currentFilm?.exportTitleToken ?? "",
            number: displayedNumber,
            takeIndex: live.clipCount > 1 ? live.latestTakeIndex : nil,
            fileExtension: transcodeOption.exportedFileExtension(sourceExtension: live.mainFileExtension)
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                        .listRowInsets(
                            EdgeInsets(
                                top: SLSpacing.small,
                                leading: SLSpacing.medium,
                                bottom: SLSpacing.small,
                                trailing: SLSpacing.medium
                            )
                        )
                        .listRowBackground(Color.clear)
                }

                Section {
                    Button(action: { if flushDraft() { onCapture() } }) {
                        Label("拍摄", systemImage: "camera.fill")
                    }

                    Button(action: { if flushDraft() { onImport() } }) {
                        Label("导入", systemImage: "photo.on.rectangle.angled")
                    }
                }

                Section {
                    // 三个输入框都是自由文本，一填上内容占位符就没了。常驻的图标加短标签
                    // 才分得清哪条是描述、字幕、角标，不会填错位置。
                    fieldRow("描述", systemImage: "text.alignleft") {
                        TextField("描述", text: $draftNote, axis: .vertical)
                            .lineLimit(3...8)
                            .focused($isNoteFocused)
                            .accessibilityLabel("描述")
                    }

                    fieldRow("字幕", systemImage: "captions.bubble") {
                        TextField("字幕", text: $draftCaption, axis: .vertical)
                            .lineLimit(2...5)
                            .accessibilityLabel("字幕")
                    }

                    fieldRow("角标", systemImage: "tag") {
                        TextField("角标", text: $draftBadgeText, axis: .vertical)
                            .lineLimit(1...3)
                            .accessibilityLabel("角标")
                    }

                    if let inheritable = inheritableText {
                        Button {
                            if let caption = inheritable.caption { draftCaption = caption }
                            if let badgeText = inheritable.badgeText { draftBadgeText = badgeText }
                        } label: {
                            Label("沿用上一镜", systemImage: "arrow.turn.left.up")
                        }
                        .accessibilityHint("复制上一镜的字幕和角标，只补没写的")
                    }
                }

                Section {
                    Stepper(value: numberBinding, in: numberRange) {
                        HStack {
                            Label("编号", systemImage: "number")
                            Spacer()
                            Text("\(displayedNumber)")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("编号")
                    .accessibilityValue("\(displayedNumber)")

                    // 导出文件名跟在编号这一节：名字由「影片标题 + 编号 + 片段序号」组成，
                    // 描述不再参与。放在描述输入框下面会让人以为改描述就能改名。
                    LabeledContent {
                        Text(previewFileName)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } label: {
                        Label("文件名", systemImage: "doc.text")
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("文件名")
                    .accessibilityValue(previewFileName)
                }

                // 片段列表放最后：已拍镜头可能有十几条，摆太靠上会把描述挤到屏幕外，
                // 而「拍摄 / 写描述」才是打开这一页的两个主要目的。
                if live.hasClip {
                    Section {
                        ForEach(Array(live.clips.enumerated()), id: \.element.id) { index, clip in
                            clipRow(clip, index: index, isLatest: clip.id == live.latestClip?.id)
                        }
                    } header: {
                        Text("片段（\(live.clipCount)）")
                    }
                }

                Section {
                    if live.hasClip {
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Label("清空片段", systemImage: "trash.slash")
                        }
                    }

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("删除镜头", systemImage: "trash")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .safeAreaInset(edge: .top) { StorageSaveErrorBanner() }
            .navigationTitle("镜头 \(live.paddedNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { if flushDraft() { dismiss() } }
                }
            }
        }
        // 这一页现在是镜头的正门：头部、拍摄、片段、描述、顺序、删除都在这里，
        // medium 那份高度装不下，会在输入框中间截断。
        .presentationDetents([.large])
        .interactiveDismissDisabled(store.saveError != nil)
        .presentationDragIndicator(.visible)
        .onChange(of: draftNote) { _, _ in scheduleDraftSave() }
        .onChange(of: draftCaption) { _, _ in scheduleDraftSave() }
        .onChange(of: draftBadgeText) { _, _ in scheduleDraftSave() }
        .onChange(of: numberEdit) { _, edit in
            // 落盘成功后 `numberEdit` 会被清回 nil，那不是用户操作，不必再排一次写盘
            if edit != nil { scheduleDraftSave() }
        }
        .task {
            // 等弹层落位再把光标放进去，否则键盘会和转场打架
            guard autoFocusNote else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            isNoteFocused = true
        }
        .onDisappear { flushDraft() }
        .confirmationDialog(
            deleteClipTitle,
            isPresented: deleteClipBinding,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let clipToDelete {
                    store.removeClip(clipToDelete.id, from: live.id)
                }
                clipToDelete = nil
            }
            Button("取消", role: .cancel) { clipToDelete = nil }
        } message: {
            Text("无法恢复。")
        }
        .confirmationDialog(
            "清空片段？",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) { store.removeAllClips(for: live.id) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(live.clipCount) 段视频将被删除，无法恢复。")
        }
        .alert("删除镜头？", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                store.delete(live)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            if live.hasClip {
                Text("\(live.clipCount) 段视频将被删除，无法恢复。")
            }
        }
    }

    /// 图标 + 短标签 + 输入框。图标与标签常驻，占位只留字段名。
    private func fieldRow<Field: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder field: () -> Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.footnote)
                .foregroundStyle(.secondary)
            field()
        }
    }

    // MARK: - 草稿落盘

    /// 攒一下再写：手停 400 毫秒才落盘。
    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            flushDraft()
        }
    }

    /// 把草稿写回仓库。三样文字都裁掉首尾空白（否则行尾多一个回车就会被当成
    /// 「写过字幕」），拨过的编号夹进有效区间；没拨过编号就沿用仓库当前值，
    /// 不会把它当成一次移动。
    ///
    /// 与仓库当前值一致时直接返回，所以「同时打开又关掉」不会产生一次多余的写盘。
    @discardableResult
    private func flushDraft() -> Bool {
        draftSaveTask?.cancel()
        draftSaveTask = nil

        let trimmedNote = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCaption = draftCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBadgeText = draftBadgeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = numberEdit.map { min(max($0, numberRange.lowerBound), numberRange.upperBound) } ?? live.number

        guard trimmedNote != live.trimmedNote
            || trimmedCaption != live.trimmedCaption
            || trimmedBadgeText != live.trimmedBadgeText
            || number != live.number
        else {
            // 拨过又拨回去：与仓库一致，不必再保留这份编辑，否则之后仓库编号变了仍会被它盖回
            numberEdit = nil
            return true
        }

        var edited = live
        edited.note = trimmedNote
        edited.caption = trimmedCaption
        edited.badgeText = trimmedBadgeText
        edited.number = number
        guard store.update(edited) else { return false }
        numberEdit = nil
        return true
    }

    // MARK: - 头部

    /// 面板头部只放导航栏给不了的东西：缩略图、分镜描述、已拍状态。
    ///
    /// 编号不再写第二遍——导航栏标题已经是「镜头 01」，头部再写一遍就是同一个信息
    /// 在同一屏出现两次。描述为空时也不再用 `displayDetail` 回退成「镜头 N」：
    /// 那个回退会让头部冒出一行「镜头 1」，跟上面那行编号长得几乎一样，像是另一条数据；
    /// 空着就画一道虚线（与分镜卡片同一套语言：虚线表示这里还没有内容）。
    /// 「还没拍」同样不写：缩略图位置本身就是虚线框加号，已经说明这里没有视频，
    /// 而面板里「拍摄」那一节的动作名（用相机拍摄 / 再拍一条）也在说同一件事。
    private var header: some View {
        HStack(alignment: .center, spacing: SLSpacing.medium) {
            ClipThumbnailView(
                url: store.clipURL(for: live),
                size: SLSize.headerThumbnail,
                durationText: live.durationText,
                takeCount: live.clipCount
            )

            VStack(alignment: .leading, spacing: SLSpacing.tiny) {
                if live.hasNote {
                    Text(live.note)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    NotePlaceholder()
                }

                if live.hasClip {
                    HStack(spacing: SLSpacing.small) {
                        IconValue(systemImage: "square.stack.3d.up", text: "\(live.clipCount)")
                        IconValue(systemImage: "clock", text: live.totalDuration.slDurationText)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(live.clipCount) 段，\(live.totalDuration.slDurationText)")
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 单条片段

    private func clipRow(_ clip: ShotClip, index: Int, isLatest: Bool) -> some View {
        let url = store.clipURL(for: clip)

        return HStack(spacing: SLSpacing.medium) {
            Button {
                if flushDraft() { onPlay(clip) }
            } label: {
                HStack(spacing: SLSpacing.medium) {
                    ClipThumbnailView(
                        url: url,
                        size: SLSize.clipRowThumbnail,
                        durationText: clip.durationText
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: SLSpacing.small) {
                            Text("第 \(index + 1) 条")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)

                            if isLatest {
                                Text("最新")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }
                        }

                        Text(clip.shortRecordedAtText())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("第 \(index + 1) 条片段\(isLatest ? "，最新一条" : "")")
            .accessibilityValue(
                [clip.durationText.map { "时长 \($0)" }, clip.recordedAtText]
                    .compactMap { $0 }
                    .joined(separator: "，")
            )
            .accessibilityHint("播放")

            Menu {
                Button {
                    if flushDraft() { onPlay(clip) }
                } label: {
                    Label("播放", systemImage: "play.circle")
                }

                if let url {
                    ShareLink(item: url, subject: Text("镜头 \(live.paddedNumber) 第 \(index + 1) 条")) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    clipToDelete = clip
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(width: SLSize.minTouchTarget, height: SLSize.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("第 \(index + 1) 条，更多")
        }
    }

    // MARK: - 绑定

    private var deleteClipBinding: Binding<Bool> {
        Binding(
            get: { clipToDelete != nil },
            set: { presented in if !presented { clipToDelete = nil } }
        )
    }

    private var deleteClipTitle: String {
        guard let clipToDelete, let index = live.clips.firstIndex(where: { $0.id == clipToDelete.id }) else {
            return "删除片段？"
        }
        return "删除第 \(index + 1) 条？"
    }
}

#Preview {
    ClipOptionsSheet(
        shot: Shot(
            number: 3,
            note: "手冲壶出水特写，收环境音",
            caption: "第 3 杯还是手冲\n水温 92°C",
            badgeText: "热量缺口：1758千卡"
        ),
        onCapture: {},
        onImport: {},
        onPlay: { _ in }
    )
    .environmentObject(ShotStore())
}
