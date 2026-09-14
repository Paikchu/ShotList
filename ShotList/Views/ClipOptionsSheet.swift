import SwiftUI

/// 点开一个镜头后弹出的面板：继续拍、再导入，以及管理已经拍好的每一条片段。
///
/// 同一个镜头可以拍很多条，这里逐条列出，可以单独播放、分享、删除，
/// 拍新的一条不会覆盖之前拍好的。
struct ClipOptionsSheet: View {
    /// 点开的那个镜头。只借它定位，展示时始终取仓库里的最新数据。
    let shot: Shot
    var onCapture: () -> Void
    var onImport: () -> Void
    var onPlay: (ShotClip) -> Void
    var onEdit: () -> Void

    @EnvironmentObject private var store: ShotStore
    @Environment(\.dismiss) private var dismiss

    @State private var clipToDelete: ShotClip?
    @State private var showClearConfirm = false
    @State private var showDeleteConfirm = false

    private var live: Shot { store.shot(withID: shot.id) ?? shot }

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
                    Button(action: onCapture) {
                        Label(live.hasClip ? "再拍一条" : "用相机拍摄", systemImage: "camera.fill")
                    }
                    .accessibilityHint("打开相机，给这个镜头再录一条，之前拍的会保留")

                    Button(action: onImport) {
                        Label(live.hasClip ? "从相册再添加一条" : "从相册导入", systemImage: "photo.on.rectangle.angled")
                    }
                    .accessibilityHint("从照片图库里选一段已经拍好的视频加进来")
                }

                if live.hasClip {
                    Section {
                        ForEach(Array(live.clips.enumerated()), id: \.element.id) { index, clip in
                            clipRow(clip, index: index, isLatest: clip.id == live.latestClip?.id)
                        }
                    } header: {
                        Text("已拍片段（\(live.clipCount)）")
                    }
                }

                Section("分镜") {
                    Button(action: onEdit) {
                        Label(live.hasNote ? "编辑分镜描述" : "填写分镜描述", systemImage: "square.and.pencil")
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
            .navigationTitle("镜头 \(live.paddedNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents(live.hasClip ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
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

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center, spacing: SLSpacing.medium) {
            ClipThumbnailView(
                url: store.clipURL(for: live),
                size: SLSize.headerThumbnail,
                durationText: live.durationText,
                takeCount: live.clipCount
            )

            VStack(alignment: .leading, spacing: SLSpacing.tiny) {
                Text("镜头 \(live.paddedNumber)")
                    .font(.headline)
                Text(live.displayDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                Text(statusCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusCaption: String {
        guard live.hasClip else { return "还没拍" }
        return "已拍 \(live.clipCount) 段 · 共 \(live.totalDuration.slDurationText)"
    }

    // MARK: - 单条片段

    private func clipRow(_ clip: ShotClip, index: Int, isLatest: Bool) -> some View {
        let url = store.clipURL(for: clip)

        return HStack(spacing: SLSpacing.medium) {
            Button {
                onPlay(clip)
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
                    onPlay(clip)
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
        onPlay: { _ in },
        onEdit: {}
    )
    .environmentObject(ShotStore())
}
