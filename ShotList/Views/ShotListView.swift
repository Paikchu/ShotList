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
            .toolbarTitleDisplayMode(.inlineLarge)
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
                    shotRow(shot)
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

    /// 一行 = 左侧时间线导轨 + 卡片。
    ///
    /// 行的上下内边距交给卡片自己拿捏（导轨要连着画到行边缘，才能和上下行接成一条线）。
    private func shotRow(_ shot: Shot) -> some View {
        HStack(alignment: .top, spacing: 0) {
            TimelineRail(
                isFirst: shot.id == store.shots.first?.id,
                isLast: shot.id == store.shots.last?.id,
                nodeTopPadding: railNodeTopPadding
            ) {
                NumberBadge(
                    number: shot.number,
                    isRecorded: shot.hasClip,
                    size: SLSize.timelineNode
                )
            }

            ShotCardView(
                shot: shot,
                clipURL: store.clipURL(for: shot),
                showsNumber: false
            ) {
                Haptics.impact(.light)
                sheet = .options(shot)
            }
            .padding(.vertical, SLSpacing.tiny)
        }
        .listRowInsets(
            EdgeInsets(
                top: 0,
                leading: 0,
                bottom: 0,
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

    /// 节点上沿距行顶的距离：行内边距 4 + 卡片内边距 16 + 首行文字半高 10 − 节点半径
    private var railNodeTopPadding: CGFloat {
        SLSpacing.tiny + SLSpacing.medium + 10 - SLSize.timelineNode / 2
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

        let index = store.index(of: shot.id)
        if store.shots.count > 1, let index {
            Section {
                Button {
                    move(from: index, to: index - 1)
                } label: {
                    Label("上移一位", systemImage: "arrow.up")
                }
                .disabled(index == 0)

                Button {
                    move(from: index, to: index + 1)
                } label: {
                    Label("下移一位", systemImage: "arrow.down")
                }
                .disabled(index == store.shots.count - 1)
            }
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

    /// 上下挪一位。`move(fromOffsets:toOffset:)` 的目标位置是「要插到谁前面」，
    /// 往下挪时因为元素先被摘掉了，目标位要再往后一格。
    private func move(from index: Int, to target: Int) {
        Haptics.impact(.light)
        store.move(
            fromOffsets: IndexSet(integer: index),
            toOffset: target > index ? target + 1 : target
        )
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
