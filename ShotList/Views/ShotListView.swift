import SwiftUI

/// 「分镜」标签页：录入编号 1、2、3… 的镜头，并把每个镜头变成可点击添加视频的模块。
struct ShotListView: View {
    @EnvironmentObject private var store: ShotStore

    @State private var sheet: ShotSheet?
    @State private var pendingDeletion: Shot?
    @State private var pendingClear: Shot?

    /// 刚新增的镜头，用来在列表里把它指出来（卡片 accent 描边 + 导轨上段变色）。
    @State private var flashID: Shot.ID?
    /// 已经插进去了、但编辑器还盖在上面——等编辑器关掉再闪。
    /// 否则那一秒的动效全被弹层挡着，用户回来时只看到一张普通卡片。
    @State private var pendingFlashID: Shot.ID?
    @State private var flashTask: Task<Void, Never>?
    /// `-preselectShot` 只生效一次，用户关掉面板后不再弹回来
    @State private var didApplyPreselect = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 影片条常驻：即使这部影片还没有镜头，用户也要能看见标题、
                // 能切换影片、能重制。它不随内容有无而消失。
                FilmBar()
                    .padding(.horizontal, SLSpacing.medium)
                    .padding(.top, SLSpacing.pageTopInset)
                    .padding(.bottom, SLSpacing.small)

                Group {
                    if store.shots.isEmpty {
                        emptyState
                    } else {
                        shotList
                    }
                }
            }
            .navigationTitle("分镜")
            // 标题不单独占一行：inlineLarge 让它和右侧的添加按钮同在一行，
            // 内容起点尽量靠上；「历史」「导出」两页同款，三页起始位置一致
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
        .task { await openPreselectedShot() }
        .confirmationDialog(
            "清空这个镜头的片段？",
            isPresented: Binding(
                get: { pendingClear != nil },
                set: { if !$0 { pendingClear = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingClear
        ) { shot in
            Button("全部清空", role: .destructive) {
                store.removeAllClips(for: shot.id)
                pendingClear = nil
                Haptics.warning()
            }
            Button("取消", role: .cancel) { pendingClear = nil }
        } message: { shot in
            Text("镜头 \(shot.paddedNumber) 的 \(shot.clipCount) 段片段都会被删除，无法恢复。分镜描述和顺序会保留。")
        }
        .onChange(of: sheet?.id) { _, newValue in
            // 编辑器关掉了，这时候用户才真正在看列表
            guard newValue == nil, let target = pendingFlashID else { return }
            pendingFlashID = nil
            flash(target)
        }
    }

    // MARK: - 列表

    private var shotList: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(store.shots) { shot in
                        shotRow(shot)
                            .id(shot.id)
                    }
                    .onMove { source, destination in
                        store.move(fromOffsets: source, toOffset: destination)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            // 行自带的 tiny（4pt）内边距 + List 默认的 1pt 顶部内边距，正好是三页统一的
            // pageTopInset（5pt），所以这里显式置 0，别让默认值再叠一层
            .contentMargins(.top, 0, for: .scrollContent)
            .onChange(of: flashID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.snappy(duration: 0.3)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    /// 一行 = 左侧时间线导轨 + 卡片。
    ///
    /// 行的上下内边距交给卡片自己拿捏（导轨要连着画到行边缘，才能和上下行接成一条线）。
    private func shotRow(_ shot: Shot) -> some View {
        HStack(alignment: .top, spacing: 0) {
            TimelineRail(
                isFirst: shot.id == store.shots.first?.id,
                isLast: shot.id == store.shots.last?.id,
                nodeTopPadding: railNodeTopPadding,
                isHighlighted: shot.id == flashID
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
                showsNumber: false,
                isNew: shot.id == flashID
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
            insert(below: shot)
        } label: {
            Label("在下方插入新镜头", systemImage: "text.insert")
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

            Button(role: .destructive) {
                pendingClear = shot
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
            Label("这部影片还没有分镜", systemImage: "film.stack")
        } description: {
            Text("添加第 1 个镜头，开始搭建这部影片的分镜清单。")
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
        guard let shot = store.addShot() else { return }
        // 新镜头是空的，用户此刻就是要写它——直接把光标放进描述输入框
        sheet = .options(shot, autoFocusNote: true)
    }

    /// 调试启动参数 `-preselectShot <编号>`：直接把某个镜头的面板打开。
    ///
    /// 与 `-preselectTab`（标签页）、`-preselectFilm`（影片）同一套用法，
    /// 供 `Tools/seed-simulator.py` 之后的验收截图停在指定界面上。
    /// 这里不自动聚焦输入框——截图要的是看整页版式，弹出键盘会盖掉半屏。
    ///
    /// 只在启动时做一次：用户关掉面板之后不该再弹回来（那会让人以为点不没）。
    private func openPreselectedShot() async {
        guard !didApplyPreselect else { return }
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-preselectShot"),
              flag + 1 < arguments.count,
              let number = Int(arguments[flag + 1]),
              let target = store.shots.first(where: { $0.number == number })
        else { return }

        didApplyPreselect = true
        // 等标签页与影片条落位再弹：启动瞬间就发 sheet，会和转场抢同一帧。
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        sheet = .options(target)
    }

    /// 在某个镜头后面插入一个空白镜头，并直接进它的面板。
    ///
    /// 插入点之后的编号会整体 +1（编号即位置），磁盘上的片段文件名由 `normalize()`
    /// 一并改好。面板一进来就把光标放进描述输入框，点完立刻能写，
    /// 不用回到列表里去找刚插进来的那张卡。
    private func insert(below shot: Shot) {
        Haptics.impact(.light)
        guard let created = store.insertShot(below: shot.id) else { return }
        pendingFlashID = created.id
        sheet = .options(created, autoFocusNote: true)
    }

    /// 把某个镜头高亮一下再收回。
    ///
    /// 先等一次布局再滚：新增是紧跟数据变更发生的，立刻 `scrollTo` 可能滚到旧位置上。
    private func flash(_ id: Shot.ID) {
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }

            withAnimation(.easeOut(duration: 0.2)) { flashID = id }

            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { flashID = nil }
        }
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
        let created = store.addShots(count: count)
        // 新镜头加在末尾，而用户此刻在列表顶部，不指一下不知道加在哪儿了
        if let first = created.first { flash(first.id) }
    }
}

#Preview {
    ShotListView()
        .environmentObject(ShotStore())
}
