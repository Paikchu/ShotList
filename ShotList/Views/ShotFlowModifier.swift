import PhotosUI
import SwiftUI

/// 可分页弹出（sheet）的流程
///
/// 镜头面板这一页把描述、编号、拍摄、片段都收了，所以只有它一个 sheet——
/// 没有「再套一层的编辑器」。
enum ShotSheet: Identifiable {
    /// - Parameter autoFocusNote: 打开后把光标放进描述输入框（新增 / 插入镜头走这条）
    case options(Shot, autoFocusNote: Bool = false)

    var id: String {
        switch self {
        case .options(let shot, _): return "options-\(shot.id.uuidString)"
        }
    }
}

/// 需要整屏呈现的流程
enum ShotCover: Identifiable {
    case camera(Shot)
    /// 播放某一条片段（1 个镜头可能有很多条）
    case player(shot: Shot, clip: ShotClip, index: Int)

    var id: String {
        switch self {
        case .camera(let shot): return "camera-\(shot.id.uuidString)"
        case .player(_, let clip, _): return "player-\(clip.id.uuidString)"
        }
    }
}

/// 从列表直接进相机的请求，不经过镜头面板。
struct ShotCaptureRequest: Equatable {
    let shotID: Shot.ID
    /// 快速拍摄：镜头是刚新建的空镜头。相机关闭时有片段就接着打开它的描述页，
    /// 一条片段都没有就把它撤销，让「点了快速拍摄又退出」不留痕。
    var isQuick = false
}

private enum ImportFailure: LocalizedError {
    case unsupportedFormat

    var errorDescription: String? {
        "不支持的视频格式"
    }
}

/// 一批导入（可能有多段）的进度。
///
/// 带上 `id` 是为了认领：导入期间用户可能又选了一批，上一批的收尾不能改到下一批的
/// 进度、也不能把下一批的指示器收掉——同类问题见 P2-25。
private struct ImportBatch: Equatable {
    let id: UUID
    let total: Int
    var done = 0

    var text: String {
        total > 1 ? "导入 \(min(done + 1, total)) / \(total)" : "导入中"
    }
}

/// 把「点开分镜 → 拍摄 / 导入 / 播放」的整套弹层流程封装起来，
/// 让「分镜」和「历史」两个标签页共用同一套交互。
///
/// 描述与编号不在这里排队——它们就在镜头面板里改（`ClipOptionsSheet`），
/// 不需要再叠一层编辑页。为了遵守「不叠模态」的原则，切换弹层时先关掉当前弹层，
/// 再在 `onDismiss` 里呈现下一个，而不是在弹层里再套一层。
struct ShotFlowModifier: ViewModifier {
    @Binding var sheet: ShotSheet?
    /// 列表侧发来的「直接拍这个镜头」。收下后立刻清空，是一次性的。
    @Binding var captureRequest: ShotCaptureRequest?

    @EnvironmentObject private var store: ShotStore

    @State private var cover: ShotCover?
    @State private var queuedCover: ShotCover?
    @State private var queuedImportShot: Shot?
    /// 正在快速拍摄的那个新镜头：相机收起时据此收尾（打开描述页或撤销空镜头）。
    @State private var quickShotID: Shot.ID?

    @State private var isPickerPresented = false
    @State private var pickerTarget: Shot?
    /// 这次选片是快速拍摄接力来的：导入全部成功后接着打开描述页。
    /// 每次呈现选片时重新赋值，取消选片留下的值不会带到下一次导入里。
    @State private var pickerOpensDescription = false
    @State private var pickerItems: [PhotosPickerItem] = []

    @State private var importBatch: ImportBatch?
    @State private var importError: String?

    func body(content: Content) -> some View {
        content
            .sheet(item: $sheet, onDismiss: drainQueue) { item in
                switch item {
                case .options(let shot, let autoFocusNote):
                    optionsSheet(for: shot, autoFocusNote: autoFocusNote)
                }
            }
            .fullScreenCover(item: $cover, onDismiss: drainQueue) { item in
                switch item {
                case .camera(let shot):
                    CameraCaptureView(shot: current(shot)) {
                        queuedImportShot = current(shot)
                        cover = nil
                    }
                case .player(let shot, let clip, let index):
                    if let url = store.clipURL(for: clip) {
                        ClipPlayerScreen(
                            shot: current(shot),
                            clip: clip,
                            takeIndex: index,
                            url: url
                        )
                    } else {
                        Color.black.ignoresSafeArea()
                    }
                }
            }
            .photosPicker(
                isPresented: $isPickerPresented,
                selection: $pickerItems,
                matching: .videos,
                // 让系统直接给出相册里的**原片**。
                //
                // 默认的 `.automatic` 会为了「兼容」先转一次码：一段两分钟的 4K 素材
                // 要等好几分钟，画质还会被降一档，而这段时间里 App 拿不到任何回调，
                // 界面上只剩一个转圈。`.current` 明确要求不转码，系统只需把原文件
                // 交出来（同卷是 APFS 克隆，几乎瞬时）。
                //
                // 需要小体积或更兼容的格式时，不必在这里压一遍——导出页可以按需选
                // 格式（`ExportTranscodeOption`）：导入只做一次，导出可以反复换。
                preferredItemEncoding: .current,
                photoLibrary: .shared()
            )
            .onChange(of: captureRequest) { _, request in
                guard let request else { return }
                captureRequest = nil
                startCapture(request)
            }
            .onChange(of: pickerItems) { _, newValue in
                guard !newValue.isEmpty, let target = pickerTarget else { return }
                // 同步取走本次选择与目标：导入任务结束不再触碰后续的选择（P2-25）。
                let items = newValue
                let opensDescription = pickerOpensDescription
                pickerItems = []
                pickerTarget = nil
                pickerOpensDescription = false
                Task { await importMovies(items, into: target, opensDescription: opensDescription) }
            }
            .alert("导入失败", isPresented: importErrorBinding) {
                Button("好", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
            .overlay(alignment: .bottom) {
                if let batch = importBatch {
                    importingIndicator(batch)
                }
            }
    }

    // MARK: - 子视图

    private func optionsSheet(for shot: Shot, autoFocusNote: Bool) -> some View {
        ClipOptionsSheet(
            shot: current(shot),
            autoFocusNote: autoFocusNote,
            onCapture: {
                queuedCover = .camera(current(shot))
                sheet = nil
            },
            onImport: {
                queuedImportShot = current(shot)
                sheet = nil
            },
            onPlay: { clip in
                let live = current(shot)
                queuedCover = .player(
                    shot: live,
                    clip: clip,
                    index: store.takeIndex(of: clip, in: live)
                )
                sheet = nil
            }
        )
    }

    private func importingIndicator(_ batch: ImportBatch) -> some View {
        HStack(spacing: SLSpacing.small) {
            ProgressView()
            Text(batch.text)
                .font(.subheadline)
                // 数字跳动时胶囊宽度不跟着抖
                .monospacedDigit()
        }
        .padding(.horizontal, SLSpacing.medium)
        .padding(.vertical, SLSpacing.small + 2)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(Color.primary.opacity(0.08)) }
        .padding(.bottom, SLSpacing.large)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }

    // MARK: - 状态流转

    /// 始终取仓库里的最新数据，避免弹层里拿着过期快照
    private func current(_ shot: Shot) -> Shot {
        store.shot(withID: shot.id) ?? shot
    }

    private var importErrorBinding: Binding<Bool> {
        Binding(
            get: { importError != nil },
            set: { presented in if !presented { importError = nil } }
        )
    }

    /// 当前弹层关闭后，接着呈现排队中的下一个
    private func drainQueue() {
        if let next = queuedCover {
            queuedCover = nil
            DispatchQueue.main.async { cover = next }
            return
        }
        if let shot = queuedImportShot {
            queuedImportShot = nil
            // 快速拍摄在相机里改走导入：收尾交给选片之后的导入（`importMovies`）
            pickerOpensDescription = shot.id == quickShotID
            quickShotID = nil
            DispatchQueue.main.async {
                pickerTarget = shot
                isPickerPresented = true
            }
            return
        }
        finishQuickShoot()
    }

    /// 列表直接进相机。请求来自列表本身（加号卡片、未拍镜头的虚线加号），
    /// 此刻列表上没有别的弹层，不必排队。
    private func startCapture(_ request: ShotCaptureRequest) {
        guard let shot = store.shot(withID: request.shotID) else { return }
        quickShotID = request.isQuick ? shot.id : nil
        cover = .camera(shot)
    }

    /// 相机收起后的快速拍摄收尾：拍到了就接着写描述，一条都没有就撤销这个空镜头。
    ///
    /// 「点了快速拍摄又退出」是取消，不该在列表末尾留一个没人要的空镜头；
    /// 「保存并再拍」之后再关闭则已经有片段，同样落到描述页。
    private func finishQuickShoot() {
        guard let id = quickShotID else { return }
        quickShotID = nil
        guard let shot = store.shot(withID: id) else { return }

        if shot.hasClip {
            DispatchQueue.main.async { sheet = .options(shot, autoFocusNote: true) }
        } else {
            store.delete(shot)
        }
    }

    /// 一次选中一到多段视频，按选择顺序连续导入同一个镜头。
    ///
    /// 顺序即时间：每段落地时取当前时间，所以后选的更新，仍然是主素材。
    /// 单段失败不打断后面的——已经落地的片段都算数，最后统一报一次。
    @MainActor
    private func importMovies(
        _ items: [PhotosPickerItem],
        into shot: Shot,
        opensDescription: Bool
    ) async {
        let batch = ImportBatch(id: UUID(), total: items.count)
        withAnimation { importBatch = batch }
        defer {
            // 只收回自己那一批的指示器：期间可能已经开了新的一批（P2-25 同类）
            if importBatch?.id == batch.id {
                withAnimation { importBatch = nil }
            }
        }

        // 一段一段来、失败不打断：推进本身在 MovieImporter 里，单独有测试
        let failures = await MovieImporter.run(items) { index in
            if importBatch?.id == batch.id { importBatch?.done = index }
        } onEach: { item in
            guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
                throw ImportFailure.unsupportedFormat
            }
            try await movie.save(to: store, shotID: shot.id)
        }

        if failures.isEmpty {
            Haptics.success()
            // 导入期间用户可能已经去开了别的弹层，那时不去抢
            if opensDescription, sheet == nil, cover == nil {
                sheet = .options(current(shot), autoFocusNote: true)
            }
        } else {
            Haptics.error()
            importError = importFailureMessage(failures, of: items.count)
        }
    }

    private func importFailureMessage(_ failures: [String], of total: Int) -> String {
        let reason = failures.first ?? ""
        if total == 1 { return reason }
        return "\(failures.count) / \(total) 段失败：\(reason)"
    }
}

extension View {
    /// 挂载整套分镜操作流程
    ///
    /// - Parameter captureRequest: 列表要「直接拍某个镜头」时写入；不需要这个入口的页面不传。
    func shotFlow(
        sheet: Binding<ShotSheet?>,
        captureRequest: Binding<ShotCaptureRequest?> = .constant(nil)
    ) -> some View {
        modifier(ShotFlowModifier(sheet: sheet, captureRequest: captureRequest))
    }
}
