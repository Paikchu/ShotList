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

private enum ImportFailure: LocalizedError {
    case unsupportedFormat

    var errorDescription: String? {
        "这个文件不是可用的视频格式。"
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

    @EnvironmentObject private var store: ShotStore

    @State private var cover: ShotCover?
    @State private var queuedCover: ShotCover?
    @State private var queuedImportShot: Shot?

    @State private var isPickerPresented = false
    @State private var pickerTarget: Shot?
    @State private var pickerItem: PhotosPickerItem?

    @State private var activeImports = 0
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
                selection: $pickerItem,
                matching: .videos,
                photoLibrary: .shared()
            )
            .onChange(of: pickerItem) { _, newValue in
                guard let item = newValue, let target = pickerTarget else { return }
                pickerItem = nil
                pickerTarget = nil
                Task { await importMovie(item, into: target) }
            }
            .alert("导入失败", isPresented: importErrorBinding) {
                Button("好", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
            .overlay(alignment: .bottom) {
                if activeImports > 0 {
                    importingIndicator
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

    private var importingIndicator: some View {
        HStack(spacing: SLSpacing.small) {
            ProgressView()
            Text("正在导入视频…")
                .font(.subheadline)
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
            DispatchQueue.main.async {
                pickerTarget = shot
                isPickerPresented = true
            }
        }
    }

    @MainActor
    private func importMovie(_ item: PhotosPickerItem, into shot: Shot) async {
        withAnimation { activeImports += 1 }
        defer {
            withAnimation { activeImports -= 1 }
        }

        do {
            guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
                throw ImportFailure.unsupportedFormat
            }
            try await movie.save(to: store, shotID: shot.id)
            Haptics.success()
        } catch {
            Haptics.error()
            importError = "没能导入这段视频：\(error.localizedDescription)"
        }
    }
}

extension View {
    /// 挂载整套分镜操作流程
    func shotFlow(sheet: Binding<ShotSheet?>) -> some View {
        modifier(ShotFlowModifier(sheet: sheet))
    }
}
