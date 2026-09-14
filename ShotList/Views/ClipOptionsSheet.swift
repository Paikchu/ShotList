import SwiftUI

/// 点开一个分镜后弹出的操作面板：拍摄、导入、播放、分享、编辑、删除。
struct ClipOptionsSheet: View {
    let shot: Shot
    let clipURL: URL?
    var onCapture: () -> Void
    var onImport: () -> Void
    var onPlay: () -> Void
    var onEdit: () -> Void
    var onRemoveClip: () -> Void
    var onDeleteShot: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showRemoveClipConfirm = false
    @State private var showDeleteConfirm = false

    private var status: ShotStatus { shot.status() }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                        .listRowInsets(EdgeInsets(top: SLSpacing.small, leading: SLSpacing.medium, bottom: SLSpacing.small, trailing: SLSpacing.medium))
                        .listRowBackground(Color.clear)
                }

                Section("视频") {
                    Button(action: onCapture) {
                        Label(shot.hasClip ? "重新拍摄" : "用相机拍摄", systemImage: "camera.fill")
                    }
                    .accessibilityHint("打开相机，直接为这个分镜录制视频")

                    Button(action: onImport) {
                        Label(shot.hasClip ? "从相册替换" : "从相册导入", systemImage: "photo.on.rectangle.angled")
                    }
                    .accessibilityHint("从照片图库里选一段已经拍好的视频")

                    if let clipURL {
                        Button(action: onPlay) {
                            Label("播放这段视频", systemImage: "play.circle")
                        }

                        ShareLink(item: clipURL, subject: Text("镜头 \(shot.paddedNumber) \(shot.displayTitle)")) {
                            Label("分享这段视频", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityHint("可以发送到剪映、存储到文件，或隔空投送到电脑")
                    }
                }

                Section("分镜") {
                    Button(action: onEdit) {
                        Label("编辑镜头信息", systemImage: "square.and.pencil")
                    }

                    if shot.hasClip {
                        Button(role: .destructive) {
                            showRemoveClipConfirm = true
                        } label: {
                            Label("删除这段视频", systemImage: "trash.slash")
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("删除整个分镜", systemImage: "trash")
                    }
                } footer: {
                    Text("删除分镜会同时删除它已经拍好的视频，且无法恢复。")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("镜头 \(shot.paddedNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .confirmationDialog(
            "删除这段视频？",
            isPresented: $showRemoveClipConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { onRemoveClip() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("镜头会保留，但已经拍好的视频会被删除。")
        }
        .alert("删除整个分镜？", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) { onDeleteShot() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("镜头 \(shot.paddedNumber) 以及它的视频都会被删除，无法恢复。")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: SLSpacing.medium) {
            ClipThumbnailView(url: clipURL, size: CGSize(width: 108, height: 72))

            VStack(alignment: .leading, spacing: SLSpacing.tiny) {
                Text("镜头 \(shot.paddedNumber)")
                    .font(.headline)
                Text(shot.displayTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                StatusChip(status: status, compact: true)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ClipOptionsSheet(
        shot: Shot(number: 3, title: "咖啡店特写", note: "手冲壶出水特写"),
        clipURL: nil,
        onCapture: {},
        onImport: {},
        onPlay: {},
        onEdit: {},
        onRemoveClip: {},
        onDeleteShot: {}
    )
}
