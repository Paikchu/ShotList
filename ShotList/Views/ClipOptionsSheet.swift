import SwiftUI

/// 点开一个镜头后弹出的面板：写这个镜头的文字内容，继续拍、再导入，
/// 以及管理已经拍好的每一条片段。
///
/// 文字内容**就在这一页写**，不再跳一个编辑器页面——点开镜头是为了拍，顺手能改内容才顺手；
/// 单独开一页的结果是「只想改一句话也要跳两层、还得点保存」。
/// 镜头的编号即位置，调顺序在分镜列表里拖动或上移 / 下移，这一页不再重复放一个编号步进器。
///
/// 文字只有**一个输入框**：描述、字幕、角标、转场……想写什么、按什么格式写都由用户定，
/// 成片交给 AI 粗剪，它读得懂自然语言，不需要在界面上把这几样拆开填。
///
/// 内容自动保存，没有「完成」按钮：按草稿攒 400 毫秒再落盘（每敲一个字写一次 JSON 没必要），
/// 面板被下滑 / 点外面关掉、去拍摄 / 导入 / 播放、或 App 切到后台时立即再落一次，不漏。
struct ClipOptionsSheet: View {
    /// 点开的那个镜头。只借它定位，展示时始终取仓库里的最新数据。
    let shot: Shot
    var onCapture: () -> Void
    var onImport: () -> Void
    var onPlay: (ShotClip) -> Void
    /// 一进来就把光标放进内容输入框。新增 / 插入镜头后走这条路——
    /// 用户此刻要的就是写内容；从卡片点进来时不抢焦点，那是奔着拍摄来的。
    var autoFocusNote: Bool = false

    @EnvironmentObject private var store: ShotStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var clipToDelete: ShotClip?
    @State private var showClearConfirm = false
    @State private var showDeleteConfirm = false

    @State private var draftNote: String
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
    }

    private var live: Shot { store.shot(withID: shot.id) ?? shot }

    /// 套用模板之后内容会变成什么样：已经写的字都保留，只补缺的标签行（见 `Shot.applyingTemplate`）。
    private var templatedContent: String {
        Shot.applyingTemplate(store.shotTemplate, to: draftNote)
    }

    /// 已经是模板的样子时套用不会有任何变化，那个按钮就不必出现，免得点了没反应。
    /// 看的是草稿而不是仓库——刚清空或刚改完的那一刻按钮就该跟着变，不用等落盘。
    private var canApplyTemplate: Bool {
        templatedContent != draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                        .listRowInsets(
                            EdgeInsets(
                                top: 0,
                                leading: SLSpacing.medium,
                                bottom: 0,
                                trailing: SLSpacing.medium
                            )
                        )
                        .listRowBackground(Color.clear)
                }
                .listSectionSpacing(.compact)

                Section {
                    Button(action: { if flushDraft() { onCapture() } }) {
                        Label("拍摄", systemImage: "camera.fill")
                    }

                    Button(action: { if flushDraft() { onImport() } }) {
                        Label("导入", systemImage: "photo.on.rectangle.angled")
                    }
                }

                Section {
                    // 输入框一填上内容占位符就没了，常驻的图标加短标签才认得出这是哪一栏
                    fieldRow("内容", systemImage: "text.alignleft") {
                        TextField("内容", text: $draftNote, axis: .vertical)
                            .lineLimit(4...12)
                            .focused($isNoteFocused)
                            .accessibilityLabel("内容")
                    }

                    // 框里有字也能套：已写的内容保留，只补上缺的标签行；框还空着就是整段模板。
                    if canApplyTemplate {
                        Button {
                            draftNote = templatedContent
                        } label: {
                            Label("应用模板", systemImage: "text.badge.plus")
                        }
                        .accessibilityHint("已写的内容保留")
                    }
                }

                // 片段列表放最后：已拍镜头可能有十几条，摆太靠上会把内容挤到屏幕外，
                // 而「拍摄 / 写内容」才是打开这一页的两个主要目的。
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
            // 首个小节是没有标题的头部：默认的顶部留白会在导航栏与缩略图之间空出一大块，
            // 这里把额外的顶部边距去掉，头部行与下面的间距也一并收紧
            .contentMargins(.top, 0, for: .scrollContent)
            .safeAreaInset(edge: .top) { StorageSaveErrorBanner() }
            .navigationTitle("镜头 \(live.paddedNumber)")
            .navigationBarTitleDisplayMode(.inline)
        }
        // 这一页现在是镜头的正门：头部、拍摄、片段、内容、删除都在这里，
        // medium 那份高度装不下，会在输入框中间截断。
        .presentationDetents([.large])
        // 保存失败的横幅还在时不让下滑关掉：草稿没落盘，关了就丢；先在横幅里点「关闭」
        .interactiveDismissDisabled(store.saveError != nil)
        .presentationDragIndicator(.visible)
        .onChange(of: draftNote) { _, _ in scheduleDraftSave() }
        .onChange(of: scenePhase) { _, phase in
            // 切到后台后随时可能被系统回收，攒着的草稿不能再等那 400 毫秒
            if phase != .active { flushDraft() }
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

    /// 把草稿写回仓库。文字裁掉首尾空白（否则行尾多一个回车就会被当成
    /// 「写过内容」）；基于仓库当前的镜头只改文字，编号沿用仓库值，不会引发移动。
    ///
    /// 与仓库当前值一致时直接返回，所以「同时打开又关掉」不会产生一次多余的写盘。
    @discardableResult
    private func flushDraft() -> Bool {
        draftSaveTask?.cancel()
        draftSaveTask = nil

        let trimmedNote = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedNote != live.trimmedNote else { return true }

        var edited = live
        edited.note = trimmedNote
        return store.update(edited)
    }

    // MARK: - 头部

    /// 面板头部只放导航栏给不了的东西：缩略图、内容、已拍状态。
    ///
    /// 编号不再写第二遍——导航栏标题已经是「镜头 01」，头部再写一遍就是同一个信息
    /// 在同一屏出现两次。内容为空时也不再用 `displayDetail` 回退成「镜头 N」：
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
            note: "描述：手冲壶出水特写，收环境音\n字幕：第 3 杯还是手冲\n水温 92°C\n上方角标：热量缺口：1758千卡"
        ),
        onCapture: {},
        onImport: {},
        onPlay: { _ in }
    )
    .environmentObject(ShotStore())
}
