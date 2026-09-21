import SwiftUI

/// 「分镜」标签页：录入编号 1、2、3… 的镜头，并把每个镜头变成可点击添加视频的模块。
///
/// 导航栏大标题是当前影片的名字（不再写死「分镜」——标签栏已经标明这是哪一页），
/// 点标题即可改名。加号点一下加一个镜头，长按展开「快速拍摄」卡片（新建镜头直接开拍，拍完落到描述页）；
/// 三点打开影片菜单（切换、改标题、选模板与写剪辑风格、新建影片）。
struct ShotListView: View {
    @EnvironmentObject private var store: ShotStore

    /// 桌面小组件点进来的「快速拍摄」请求（`RootTabView` 收到链接后置位）。收下就清零，一次性。
    @Binding private var quickShootRequest: Bool

    @State private var sheet: ShotSheet?
    /// 快速拍摄：新建镜头后交给 `shotFlow` 直接开相机
    @State private var captureRequest: ShotCaptureRequest?
    /// 长按加号展开的「快速拍摄」卡片
    @State private var isShowingQuickCard = false
    /// 点了卡片：等卡片收起再开相机，免得两个弹层抢同一帧
    @State private var pendingQuickShoot = false
    @State private var pendingDeletion: Shot?
    @State private var pendingClear: Shot?

    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var isConfirmingRemake = false
    @State private var isEditingTemplate = false
    /// 影片菜单里的「剪辑风格」页。调试参数 `-preselectStylePage` 让它在启动后自己弹出（见 `openPreselectedStyle`）。
    @State private var isEditingStyle = false

    /// 刚新增的镜头，用来在列表里把它指出来（卡片 accent 描边 + 导轨上段变色）。
    @State private var flashID: Shot.ID?
    /// 已经插进去了、但编辑器还盖在上面——等编辑器关掉再闪。
    /// 否则那一秒的动效全被弹层挡着，用户回来时只看到一张普通卡片。
    @State private var pendingFlashID: Shot.ID?
    @State private var flashTask: Task<Void, Never>?
    /// `-preselectShot` 只生效一次，用户关掉面板后不再弹回来
    @State private var didApplyPreselect = false

    init(quickShootRequest: Binding<Bool> = .constant(false)) {
        _quickShootRequest = quickShootRequest
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.shots.isEmpty {
                    emptyState
                } else {
                    shotList
                }
            }
            // 不设 `navigationTitle`：标题由 `filmTitleButton` 自己画（见该属性）。留着它
            // 会在标题行再画一份系统大标题，两份叠着——实测那一份既盖住按钮又吃掉点击。
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar { toolbarContent }
            // 挂在导航栈里面：外面那一层已经有 `shotFlow` 的镜头面板 sheet
            .sheet(isPresented: $isEditingTemplate) {
                FilmTemplateSheet()
            }
            .sheet(isPresented: $isEditingStyle) {
                FilmStyleView()
            }
            .filmActionDialogs(
                isEditingTitle: $isEditingTitle,
                titleDraft: $titleDraft,
                isConfirmingRemake: $isConfirmingRemake
            )
            .alert("删除镜头？", isPresented: deletionBinding, presenting: pendingDeletion) { shot in
                Button("删除", role: .destructive) { store.delete(shot) }
                Button("取消", role: .cancel) {}
            } message: { shot in
                if shot.hasClip {
                    Text("\(shot.clipCount) 段视频将被删除，无法恢复。")
                }
            }
        }
        .shotFlow(sheet: $sheet, captureRequest: $captureRequest)
        .task { await openPreselectedShot() }
        .task { await openPreselectedStyle() }
        .confirmationDialog(
            "清空片段？",
            isPresented: Binding(
                get: { pendingClear != nil },
                set: { if !$0 { pendingClear = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingClear
        ) { shot in
            Button("清空", role: .destructive) {
                store.removeAllClips(for: shot.id)
                pendingClear = nil
                Haptics.warning()
            }
            Button("取消", role: .cancel) { pendingClear = nil }
        } message: { shot in
            Text("\(shot.clipCount) 段视频将被删除，无法恢复。")
        }
        .onChange(of: isShowingQuickCard) { _, isShown in
            guard !isShown, pendingQuickShoot else { return }
            pendingQuickShoot = false
            // 卡片收起的转场没走完就弹相机，相机会被系统丢掉：页面停在半路，
            // 相机页的深色外观却已经生效。等转场走完再开。
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                quickShoot()
            }
        }
        // `initial`：从别的标签切过来时这一页才刚创建，请求在出现之前就已经置位了
        .onChange(of: quickShootRequest, initial: true) { _, requested in
            guard requested else { return }
            quickShootRequest = false
            Task { await quickShootFromWidget() }
        }
        .onChange(of: sheet?.id) { _, newValue in
            // 编辑器关掉了，这时候用户才真正在看列表
            guard newValue == nil, let target = pendingFlashID else { return }
            pendingFlashID = nil
            // 快速拍摄被取消时新镜头已经撤销，没有东西可指
            guard store.shot(withID: target) != nil else { return }
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
                isNew: shot.id == flashID,
                onCapture: {
                    // 未拍镜头的虚线加号：不经过镜头面板，直接进这个镜头的相机
                    Haptics.impact(.light)
                    captureRequest = ShotCaptureRequest(shotID: shot.id)
                }
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
            Label("编辑", systemImage: "square.and.pencil")
        }

        Button {
            insert(below: shot)
        } label: {
            Label("在下方插入", systemImage: "text.insert")
        }

        Button {
            store.duplicate(shot)
            Haptics.impact(.light)
        } label: {
            Label("在下方复制", systemImage: "plus.square.on.square")
        }

        let index = store.index(of: shot.id)
        if store.shots.count > 1, let index {
            Section {
                Button {
                    move(from: index, to: index - 1)
                } label: {
                    Label("上移", systemImage: "arrow.up")
                }
                .disabled(index == 0)

                Button {
                    move(from: index, to: index + 1)
                } label: {
                    Label("下移", systemImage: "arrow.down")
                }
                .disabled(index == store.shots.count - 1)
            }
        }

        let urls = store.clipURLs(for: shot)
        if !urls.isEmpty {
            ShareLink(
                items: urls,
                // 内容是多行的，邮件主题只取第一行
                subject: Text("镜头 \(shot.paddedNumber) \(shot.displayDetail.components(separatedBy: .newlines)[0])")
            ) {
                Label("分享", systemImage: "square.and.arrow.up")
            }

            Button(role: .destructive) {
                pendingClear = shot
            } label: {
                Label("清空片段", systemImage: "trash.slash")
            }
        }

        Divider()

        Button(role: .destructive) {
            pendingDeletion = shot
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    // MARK: - 空状态

    /// 还没有镜头时的整页提示。
    ///
    /// **必须放在滚动容器里。** 当时分镜页的标题改名按钮还挂在 `largeTitle` 位、占据整条
    /// 标题行；实测（iOS 26.5 / iPhone 17 Pro Max）当根页内容不是滚动容器时——也就是
    /// 这里把 `ContentUnavailableView` 直接铺在根上——整条导航栏的触摸会被吃掉：
    /// 右上角的加号、三点以及标题按钮全都点不动，而且没有任何反馈。列表状态没有这个
    /// 问题，因为那一份内容本身就是 `List`。去掉标题按钮或把它换成滚动容器后都恢复
    /// 正常，所以这里与列表状态保持一致（详见 P1-9）。标题按钮后来改挂 `.topBarLeading`
    /// 位（P2-38），这个滚动容器保持不动：它同时决定空状态的内容版式（居中 + 满屏），
    /// 拿掉会一并动到版式和导航栏触摸，没必要为已经修好的问题重开风险。
    ///
    /// `containerRelativeFrame` 让它仍然占满一屏（居中版式与改前逐像素一致），
    /// 内容不满一屏时也不回弹。
    private var emptyState: some View {
        ScrollView {
            ContentUnavailableView {
                Label("无镜头", systemImage: "film.stack")
            } actions: {
                Button { addShot() } label: {
                    Label("添加", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .containerRelativeFrame(.vertical)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - 导航栏

    private var filmTitle: String {
        store.currentFilm?.displayTitle ?? "分镜"
    }

    /// 点标题改名。放在 `.topBarLeading` 位。
    ///
    /// **为什么是 `.topBarLeading` 而不是 `.largeTitle`（P2-38）。** 早先挂在 `.largeTitle` 位，
    /// 根页内容是 `List` 时那个槽位交给内容的可点矩形只剩底部约 10pt 一条：实测标题墨迹在
    /// y 70.7–102（点），而只有 y=104/108 两个点能触发改名弹窗，点标题正中（y=85）没有任何反应；
    /// 同一时刻右上角的加号、三点都正常。把 action 换成别的、换成 `onTapGesture`、换成真
    /// UIKit 控件、换 `.principal` 都一样——触摸根本到不了按钮。对照：空状态下同一个槽位正常，
    /// 换成 `.topBarLeading` 后列表/空两种状态都正常（实测 y=72/84/96 均可触发）。
    ///
    /// **宽度必须显式给。** 交给槽位自己协商时内容会被压到 36pt 宽（`minimumScaleFactor` 把字
    /// 缩成一小团）；显式 `frame(width:)` 后按 34pt 排。高度交给内容自身（`fixedSize`），
    /// 命中矩形与绘制矩形重合——这正是大标题槽做不到的那一步。
    ///
    /// **左边缘落在工具栏前导槽的 24pt 上，比历史页的「历史记录」右 4.3pt**（实测标题墨迹
    /// 25.33pt vs 21.00pt）。大标题槽的内容左边缘是 20pt、工具栏前导槽是 24pt，这是系统版式
    /// 差异。试过把内容往左顶（负内边距 / 负偏移 4.4pt）：墨迹左端停在 24.00pt 不动，墨宽却从
    /// 132.67pt 缩到 129.67pt——工具栏宿主把 item 的内容裁在它的布局原点，画到 24pt 左边的部分
    /// 被直接切掉，第一个字会缺一角。也就是说工具栏槽里做不到 20pt 前导，这类常量就不留了。
    ///
    /// **要关掉工具栏项的共享背景。** 换到工具栏槽位后，iOS 26 会给这个 `Button` 套一层玻璃胶囊，
    /// 尺寸跟着上面那个 230pt 的框走——标题右侧拖出一大片空白，整体也就不再像「页面标题」而像一个
    /// 控件（历史页的标题是纯文本，两页放一起很跳）。`sharedBackgroundVisibility(.hidden)`（iOS 26）
    /// 只关背景，按钮本身与无障碍语义都留着，不用退成 `Text` + 手势。
    ///
    /// 宽度用 `SLSize.inlineTitleMaxWidth` 封顶：影片名是用户起的，过长时先缩到 0.7 再截断，
    /// 不会压到右边的「添加」「影片菜单」上。
    ///
    private var filmTitleButton: some View {
        Button(action: beginTitleEdit) {
            Text(filmTitle)
                .font(.largeTitle.bold())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: SLSize.inlineTitleMaxWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("重命名")
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            filmTitleButton
        }
        .sharedBackgroundVisibility(.hidden)

        // 加号不用 `Button` / `Menu`：长按要展开自己的卡片，系统 `Menu` 只能显示成固定的小气泡；
        // 而工具栏里的 `Button` 收不到 SwiftUI 的长按手势（实测：长按松手只触发点击、新增一个镜头）。
        // 所以用 `Image` 挂点按与长按，按钮语义交给无障碍修饰补齐。
        ToolbarItem(placement: .topBarTrailing) {
            Image(systemName: "plus")
                .frame(minWidth: SLSize.minTouchTarget, minHeight: SLSize.minTouchTarget)
                .contentShape(Rectangle())
                .onTapGesture { addShot() }
                .onLongPressGesture(minimumDuration: 0.35) {
                    Haptics.impact(.medium)
                    isShowingQuickCard = true
                }
                .popover(isPresented: $isShowingQuickCard) {
                    QuickShootCard {
                        pendingQuickShoot = true
                        isShowingQuickCard = false
                    }
                    .presentationCompactAdaptation(.popover)
                }
                .accessibilityElement()
                .accessibilityLabel("添加")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("长按快速拍摄")
                .accessibilityAction { addShot() }
                .accessibilityAction(named: "快速拍摄") { quickShoot() }
        }

        ToolbarItem(placement: .topBarTrailing) {
            FilmSwitcherMenu(
                isEditingTitle: $isEditingTitle,
                titleDraft: $titleDraft,
                isConfirmingRemake: $isConfirmingRemake,
                isEditingTemplate: $isEditingTemplate,
                isEditingStyle: $isEditingStyle
            ) {
                Label("影片", systemImage: "ellipsis.circle")
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

    private func beginTitleEdit() {
        Haptics.impact(.light)
        titleDraft = store.currentFilm?.trimmedTitle ?? ""
        isEditingTitle = true
    }

    private func addShot() {
        Haptics.impact(.light)
        guard let shot = store.addShot() else { return }
        // 新镜头是空的，用户此刻就是要写它——直接把光标放进描述输入框
        sheet = .options(shot, autoFocusNote: true)
    }

    /// 快速拍摄：先拍后写。新建一个空镜头，直接进它的相机；
    /// 拍完落到描述页、取消则撤销，收尾在 `ShotFlowModifier`。
    ///
    /// 新镜头加在末尾，用户此刻多半在列表顶部：先记下要指的镜头，
    /// 等描述页关掉（已有的 `onChange(of: sheet?.id)`）再滚过去高亮，
    /// 与「在下方插入」同一套做法。
    private func quickShoot() {
        Haptics.impact(.light)
        guard let shot = store.addShot() else { return }
        pendingFlashID = shot.id
        captureRequest = ShotCaptureRequest(shotID: shot.id, isQuick: true)
    }

    /// 桌面小组件点进来：先收起这一页自己开着的面板，等界面空下来再走快速拍摄。
    ///
    /// 镜头面板、模板页与剪辑风格页都是自动保存的，收起不丢已写的内容。别的弹层（相机、播放页、选片、
    /// 确认弹窗……）不去打断：等不到界面空下来就放弃这次请求，也就不新建镜头。
    private func quickShootFromWidget() async {
        sheet = nil
        isEditingTemplate = false
        isEditingStyle = false
        isShowingQuickCard = false
        // 冷启动时页面与转场还没落位，弹层收起也要一个转场的时间：与卡片收起、
        // `-preselectShot` 一样先等 400 毫秒，再判断界面是不是空的
        try? await Task.sleep(for: .milliseconds(400))
        guard await ModalPresentation.waitUntilIdle() else { return }
        quickShoot()
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

    /// 调试启动参数 `-preselectStylePage`：启动后直接停在「剪辑风格」页。
    ///
    /// 与 `-preselectShot` 同一套用法：等标签页与影片条落位再弹，启动瞬间就发 sheet 会和转场抢同一帧。
    private func openPreselectedStyle() async {
        guard ProcessInfo.processInfo.arguments.contains("-preselectStylePage") else { return }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        isEditingStyle = true
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
}

/// 长按加号展开的卡片：一张 2×2 个图标大小的方卡，整张可点。
private struct QuickShootCard: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: SLSpacing.small) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
                Text("快速拍摄")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .frame(width: 132, height: 132)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ShotListView()
        .environmentObject(ShotStore())
}
