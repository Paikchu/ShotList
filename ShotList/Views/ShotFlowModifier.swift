import PhotosUI
import SwiftUI

/// 可分页弹出（sheet）的流程
enum ShotSheet: Identifiable {
    case options(Shot)
    case editor(Shot)

    var id: String {
        switch self {
        case .options(let shot): return "options-\(shot.id.uuidString)"
        case .editor(let shot): return "editor-\(shot.id.uuidString)"
        }
    }
}

/// 需要整屏呈现的流程
enum ShotCover: Identifiable {
    case camera(Shot)
    case player(Shot)

    var id: String {
        switch self {
        case .camera(let shot): return "camera-\(shot.id.uuidString)"
        case .player(let shot): return "player-\(shot.id.uuidString)"
        }
    }
}

private enum ImportFailure: LocalizedError {
    case unsupportedFormat

    var errorDescription: String? {
        "这个文件不是可用的视频格式。"
    }
}

/// 把「点开分镜 → 拍摄 / 导入 / 播放 / 编辑」的整套弹层流程封装起来，
/// 让「分镜」和「今日」两个标签页共用同一套交互。
///
/// 为了遵守「不叠模态」的原则，切换弹层时先关掉当前弹层，
/// 再在 `onDismiss` 里呈现下一个，而不是在弹层里再套一层。
struct ShotFlowModifier: ViewModifier {
    @Binding var sheet: ShotSheet?

    @EnvironmentObject private var store: ShotStore

    @State private var cover: ShotCover?
    @State private var queuedSheet: ShotSheet?
    @State private var queuedCover: ShotCover?
    @State private var queuedImportShot: Shot?

    @State private var isPickerPresented = false
    @State private var pickerTarget: Shot?
    @State private var pickerItem: PhotosPickerItem?

    @State private var isImporting = false
    @State private var importError: String?

    func body(content: Content) -> some View {
        content
            .sheet(item: $sheet, onDismiss: drainQueue) { item in
                switch item {
                case .options(let shot):
                    optionsSheet(for: shot)
                case .editor(let shot):
                    ShotEditorView(shot: current(shot))
                }
            }
            .fullScreenCover(item: $cover, onDismiss: drainQueue) { item in
                switch item {
                case .camera(let shot):
                    CameraCaptureView(shot: current(shot)) {
                        queuedImportShot = current(shot)
                        cover = nil
                    }
                case .player(let shot):
                    if let url = store.clipURL(for: shot) {
                        ClipPlayerScreen(shot: current(shot), url: url)
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
                Task { await importMovie(item, into: target) }
            }
            .alert("导入失败", isPresented: importErrorBinding) {
                Button("好", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
            .overlay(alignment: .bottom) {
                if isImporting {
                    importingIndicator
                }
            }
    }

    // MARK: - 子视图

    private func optionsSheet(for shot: Shot) -> some View {
        ClipOptionsSheet(
            shot: current(shot),
            clipURL: store.clipURL(for: shot),
            onCapture: {
                queuedCover = .camera(current(shot))
                sheet = nil
            },
            onImport: {
                queuedImportShot = current(shot)
                sheet = nil
            },
            onPlay: {
                queuedCover = .player(current(shot))
                sheet = nil
            },
            onEdit: {
                queuedSheet = .editor(current(shot))
                sheet = nil
            },
            onRemoveClip: {
                store.removeClip(for: shot.id)
                sheet = nil
            },
            onDeleteShot: {
                store.delete(shot)
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
        if let next = queuedSheet {
            queuedSheet = nil
            DispatchQueue.main.async { sheet = next }
            return
        }
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
        withAnimation { isImporting = true }
        defer {
            withAnimation { isImporting = false }
            pickerTarget = nil
        }

        do {
            guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
                throw ImportFailure.unsupportedFormat
            }
            let duration = await VideoMetadata.duration(of: movie.url)
            try store.attachClip(from: movie.url, duration: duration, to: shot.id)
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
