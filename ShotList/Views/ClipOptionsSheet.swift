import SwiftUI

/// 点开一个镜头后弹出的面板：写分镜描述、改编号，继续拍、再导入，
/// 以及管理已经拍好的每一条片段。
///
/// 描述**就在这一页写**，不再跳一个编辑器页面——点开镜头是为了拍，顺手能改描述才顺手；
/// 单独开一页的结果是「只想改一句话也要跳两层、还得点保存」。
/// 同一页上还留着导出文件名预览与编号，这两样原本是编辑器页的职责：
/// 文件名由描述派生（改描述要能立刻看到会不会太长），编号即位置（改动会移动镜头）。
///
/// 描述与编号都按草稿攒 400 毫秒再落盘：每敲一个字写一次 JSON 没必要，
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

    @State private var clipToDelete: ShotClip?
    @State private var showClearConfirm = false
    @State private var showDeleteConfirm = false

    @State private var draftNote: String
    @State private var draftNumber: Int
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
        _draftNumber = State(initialValue: shot.number)
    }

    private var live: Shot { store.shot(withID: shot.id) ?? shot }

    private var numberRange: ClosedRange<Int> {
        1...max(1, store.shots.count)
    }

    /// 与导出结果同一套命名规则：边打字边看到最终文件名。
    ///
    /// 扩展名取自该镜头主素材的真实格式（相册导入的 mp4 导出后仍是 mp4）。
    /// 镜头拍了多条时，主素材（按拍摄时间选择的最新一条）带子片段号，
    /// 与 `ExportPackageBuilder.build` 的落盘命名保持一致；只拍一条时不带。
    private var previewFileName: String {
        ExportPackageBuilder.exportedFileName(
            number: draftNumber,
            takeIndex: live.clipCount > 1 ? live.latestTakeIndex : nil,
            note: draftNote,
            fileExtension: live.mainFileExtension
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

                Section("拍摄") {
                    Button(action: { if flushDraft() { onCapture() } }) {
                        Label(live.hasClip ? "再拍一条" : "用相机拍摄", systemImage: "camera.fill")
                    }
                    .accessibilityHint("打开相机，给这个镜头再录一条，之前拍的会保留")

                    Button(action: { if flushDraft() { onImport() } }) {
                        Label(live.hasClip ? "从相册再添加一条" : "从相册导入", systemImage: "photo.on.rectangle.angled")
                    }
                    .accessibilityHint("从照片图库里选一段已经拍好的视频加进来")
                }

                Section("分镜描述") {
                    TextField(
                        "例如：无人机缓慢上升，配一句开场旁白",
                        text: $draftNote,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                    .focused($isNoteFocused)
                    .accessibilityLabel("分镜描述")

                    LabeledContent {
                        Text(previewFileName)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } label: {
                        Label("导出文件名", systemImage: "doc.text")
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("导出文件名")
                    .accessibilityValue(previewFileName)
                }

                Section("顺序") {
                    Stepper(value: $draftNumber, in: numberRange) {
                        HStack {
                            Text("镜头编号")
                            Spacer()
                            Text("\(draftNumber)")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("镜头编号")
                    .accessibilityValue("\(draftNumber)")
                }

                // 片段列表放最后：已拍镜头可能有十几条，摆太靠上会把描述挤到屏幕外，
                // 而「拍摄 / 写描述」才是打开这一页的两个主要目的。
                if live.hasClip {
                    Section {
                        ForEach(Array(live.clips.enumerated()), id: \.element.id) { index, clip in
                            clipRow(clip, index: index, isLatest: clip.id == live.latestClip?.id)
                        }
                    } header: {
                        Text("已拍片段（\(live.clipCount)）")
                    }
                }

                Section {
                    if live.hasClip {
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Label("清空这个镜头的 \(live.clipCount) 段片段", systemImage: "trash.slash")
                        }
                    }

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("删除整个分镜", systemImage: "trash")
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
        .onChange(of: draftNumber) { _, _ in scheduleDraftSave() }
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
            Text("只删除这一条，镜头和其它片段都会保留。")
        }
        .confirmationDialog(
            "清空这个镜头的片段？",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("全部清空", role: .destructive) { store.removeAllClips(for: live.id) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(live.clipCount) 段片段都会被删除，无法恢复。")
        }
        .alert("删除整个分镜？", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                store.delete(live)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                live.hasClip
                ? "镜头 \(live.paddedNumber) 以及它的 \(live.clipCount) 段片段都会被删除，无法恢复。"
                : "镜头 \(live.paddedNumber) 会被删除。"
            )
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

    /// 把草稿写回仓库。描述裁掉首尾空白，编号夹进有效区间。
    ///
    /// 与仓库当前值一致时直接返回，所以「同时打开又关掉」不会产生一次多余的写盘。
    @discardableResult
    private func flushDraft() -> Bool {
        draftSaveTask?.cancel()
        draftSaveTask = nil

        guard draftNote != live.note || draftNumber != live.number else { return true }
        let trimmed = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let clamped = min(max(draftNumber, numberRange.lowerBound), numberRange.upperBound)
        guard trimmed != live.note || clamped != live.number else { return true }

        var edited = live
        edited.note = trimmed
        edited.number = clamped
        return store.update(edited)
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
                    Text("已拍 \(live.clipCount) 段 · 共 \(live.totalDuration.slDurationText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            .accessibilityHint("播放这一条")

            Menu {
                Button {
                    if flushDraft() { onPlay(clip) }
                } label: {
                    Label("播放这一条", systemImage: "play.circle")
                }

                if let url {
                    ShareLink(item: url, subject: Text("镜头 \(live.paddedNumber) 第 \(index + 1) 条")) {
                        Label("分享这一条", systemImage: "square.and.arrow.up")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    clipToDelete = clip
                } label: {
                    Label("删除这一条", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(width: SLSize.minTouchTarget, height: SLSize.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("第 \(index + 1) 条片段的更多操作")
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
            return "删除这一条？"
        }
        return "删除第 \(index + 1) 条？"
    }
}

#Preview {
    ClipOptionsSheet(
        shot: Shot(number: 3, note: "手冲壶出水特写，收环境音"),
        onCapture: {},
        onImport: {},
        onPlay: { _ in }
    )
    .environmentObject(ShotStore())
}
