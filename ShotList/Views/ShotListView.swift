import SwiftUI

/// 「分镜」标签页：录入编号 1、2、3… 的镜头，并把每个镜头变成可点击添加视频的模块。
struct ShotListView: View {
    @EnvironmentObject private var store: ShotStore

    @State private var sheet: ShotSheet?
    @State private var pendingDeletion: Shot?

    var body: some View {
        NavigationStack {
            Group {
                if store.shots.isEmpty {
                    emptyState
                } else {
                    shotList
                }
            }
            .navigationTitle("分镜")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .alert("删除这个分镜？", isPresented: deletionBinding, presenting: pendingDeletion) { shot in
                Button("删除", role: .destructive) { store.delete(shot) }
                Button("取消", role: .cancel) {}
            } message: { shot in
                Text(
                    shot.hasClip
                    ? "镜头 \(shot.paddedNumber) 已经拍好了 \(shot.clipCount) 段视频，删除后它们也会一起消失，无法恢复。"
                    : "镜头 \(shot.paddedNumber) 会被删除。"
                )
            }
        }
        .shotFlow(sheet: $sheet)
    }

    // MARK: - 列表

    private var shotList: some View {
        List {
            Section {
                ForEach(store.shots) { shot in
                    ShotCardView(shot: shot, clipURL: store.clipURL(for: shot)) {
                        Haptics.impact(.light)
                        sheet = .options(shot)
                    }
                    .listRowInsets(
                        EdgeInsets(
                            top: SLSpacing.tiny,
                            leading: SLSpacing.medium,
                            bottom: SLSpacing.tiny,
                            trailing: SLSpacing.medium
                        )
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeletion = shot
                        } label: {
                            Label("删除", systemImage: "trash")
                        }

                        Button {
                            sheet = .editor(shot)
                        } label: {
                            Label("编辑", systemImage: "square.and.pencil")
                        }
                        .tint(.indigo)
                    }
                    .contextMenu {
                        contextMenu(for: shot)
                    }
                }
                .onMove { source, destination in
                    store.move(fromOffsets: source, toOffset: destination)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func contextMenu(for shot: Shot) -> some View {
        Button {
            sheet = .options(shot)
        } label: {
            Label(
                shot.hasClip ? "查看或继续拍" : "添加视频",
                systemImage: "video.badge.plus"
            )
        }

        Button {
            sheet = .editor(shot)
        } label: {
            Label("编辑分镜描述", systemImage: "square.and.pencil")
        }

        Button {
            store.duplicate(shot)
            Haptics.impact(.light)
        } label: {
            Label("在下方复制一个", systemImage: "plus.square.on.square")
        }

        let urls = store.clipURLs(for: shot)
        if !urls.isEmpty {
            ShareLink(
                items: urls,
                subject: Text("镜头 \(shot.paddedNumber) \(shot.displayDetail)")
            ) {
                Label(
                    shot.clipCount > 1 ? "分享这 \(shot.clipCount) 段视频" : "分享视频",
                    systemImage: "square.and.arrow.up"
                )
            }

            Button {
                store.removeAllClips(for: shot.id)
                Haptics.warning()
            } label: {
                Label("清空片段（保留分镜）", systemImage: "trash.slash")
            }
        }

        Divider()

        Button(role: .destructive) {
            pendingDeletion = shot
        } label: {
            Label("删除分镜", systemImage: "trash")
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有分镜", systemImage: "film.stack")
        } description: {
            Text("添加第 1 个镜头，开始搭建你的 Vlog 分镜清单。")
        } actions: {
            Button("添加分镜") { addShot() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if !store.shots.isEmpty {
                EditButton()
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                addShot()
            } label: {
                Label("添加分镜", systemImage: "plus")
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section("批量录入") {
                    Button { addShots(count: 3) } label: {
                        Label("一次添加 3 个镜头", systemImage: "square.grid.3x3")
                    }
                    Button { addShots(count: 5) } label: {
                        Label("一次添加 5 个镜头", systemImage: "square.grid.3x3.fill")
                    }
                    Button { addShots(count: 10) } label: {
                        Label("一次添加 10 个镜头", systemImage: "rectangle.grid.2x2")
                    }
                }
            } label: {
                Label("更多添加方式", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: - 动作

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { presented in if !presented { pendingDeletion = nil } }
        )
    }

    private func addShot() {
        Haptics.impact(.light)
        let shot = store.addShot()
        sheet = .editor(shot)
    }

    private func addShots(count: Int) {
        Haptics.impact(.light)
        store.addShots(count: count)
    }
}

#Preview {
    ShotListView()
        .environmentObject(ShotStore())
}
