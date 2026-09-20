import SwiftUI

/// 影片条：历史页顶部的影片切换器。
///
/// 一行交代三件事——**这是哪部影片**（标题）、**它进行到哪了**（最后更新 + 进度）、
/// **怎么换一部**（右侧下拉箭头）。分镜页把标题放进导航栏、把切换影片放进
/// 三点菜单，所以这条只出现在历史页。
///
/// 下拉不是系统 `Menu`：点箭头后从白条下方浮出一块与它同宽的面板
/// （影片清单 + 新建影片入口），悬在下方内容之上、不挤压版式；
/// 点影片载入、点面板外收起。
///
/// 标题为空时画一道虚线（虚线在这套界面里一直是「这里还没有内容」的意思，
/// 见 `NotePlaceholder`），不写「未命名」之类的字——空着本身就是信息。
struct FilmBar: View {
    @EnvironmentObject private var store: ShotStore

    /// 历史页只用来切换影片，不提供改名。分镜页的三点菜单才改标题。
    var allowsRename: Bool = true

    /// 支持调试启动参数 `-expandFilmDropdown`：验收截图直接停在展开态。
    /// 与 `-preselectTab` / `-preselectFilm` 同一套用法。
    @State private var isExpanded =
        ProcessInfo.processInfo.arguments.contains("-expandFilmDropdown")
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var isConfirmingRemake = false

    /// 白条自身的实际高度（含内边距），用来把悬浮面板锚在它的下沿。
    @State private var cardHeight: CGFloat = 0

    /// 白条下沿到滚动区可视区下沿的距离，决定面板最高能有多高。
    /// 面板展开后才由 `outsideTapCatcher` 量；量不到（还没量 / 不在滚动视图里）时为 `nil`，不设上限。
    @State private var spaceBelowBar: CGFloat?
    /// 影片清单全部行加起来的高度，与面板底部固定区的高度：
    /// 清单只能占面板上限减去这一块之外的高度，见 `filmListHeight`。
    @State private var filmListContentHeight: CGFloat = 0
    @State private var panelFooterHeight: CGFloat = 0

    var body: some View {
        CardContainer(padding: SLSpacing.small + 2) {
            header
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: FilmBarHeightKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(FilmBarHeightKey.self) { cardHeight = $0 }
        // 悬浮面板：锚在白条下沿，同宽、浮在下方内容之上。
        .overlay(alignment: .topLeading) {
            if isExpanded {
                dropdownPanel
                    .padding(.top, cardHeight + Self.panelGap)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // 展开时把整块卡片（连同铺满滚动区的点击收起层）抬到后面的进度卡之上。
        .zIndex(isExpanded ? 1 : 0)
        .background {
            if isExpanded {
                outsideTapCatcher
            }
        }
        .animation(.spring(duration: 0.32), value: isExpanded)
        .filmActionDialogs(
            isEditingTitle: $isEditingTitle,
            titleDraft: $titleDraft,
            isConfirmingRemake: $isConfirmingRemake
        )
    }

    private var header: some View {
        HStack(spacing: SLSpacing.small) {
            if allowsRename {
                Button(action: beginTitleEdit) {
                    titleBlock
                }
                .buttonStyle(ShotCardButtonStyle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint("重命名")
                .accessibilityAddTraits(.isButton)
            } else {
                titleBlock
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel)
            }

            chevron
        }
    }

    private var chevron: some View {
        Button {
            Haptics.impact(.light)
            isExpanded.toggle()
        } label: {
            Image(systemName: "chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.primary)
                .frame(width: SLSize.minTouchTarget, height: SLSize.minTouchTarget)
                .contentShape(Rectangle())
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
        .accessibilityLabel(isExpanded ? "收起影片列表" : "展开影片列表")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - 悬浮面板

    /// 与白条同宽、悬浮在其下方的影片清单：当前影片打勾，末尾是新建影片入口。
    ///
    /// 面板挂在 `.overlay` 里，不参与外层 `ScrollView` 的内容高度，超出屏幕的部分既画不出来
    /// 也滚不到。所以影片多到放不下时，清单在面板内部滚动；新建影片等操作行固定在清单下面，
    /// 不随清单滚走。
    private var dropdownPanel: some View {
        VStack(spacing: 0) {
            filmList

            VStack(spacing: 0) {
                rowDivider

                if allowsRename {
                    actionRow(title: "重命名", systemImage: "pencil") {
                        titleDraft = store.currentFilm?.trimmedTitle ?? ""
                        isEditingTitle = true
                    }
                }

                actionRow(title: "新建影片", systemImage: "film.stack") {
                    isConfirmingRemake = true
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                panelFooterHeight = height
            }
        }
        .padding(Self.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: SLSize.cardCornerRadius, style: .continuous)
        )
        // 悬浮感：柔和投影把面板从下方内容上托起来。
        .shadow(color: .black.opacity(0.14), radius: 18, x: 0, y: 10)
    }

    /// 高度跟着内容走、到了上限才滚动：`ScrollView` 会占满给它的高度，
    /// 直接 `.frame(maxHeight:)` 会让只有两三部影片时也撑出一个空荡荡的大面板
    /// （做法同 `CameraChrome.noteBody`）。
    private var filmList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(store.sortedFilms) { film in
                    dropdownRow(film)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                filmListContentHeight = height
            }
        }
        .frame(height: filmListHeight)
        .scrollBounceBehavior(.basedOnSize)
    }

    /// 清单的实际高度：内容多高就多高，但面板整体不能超出滚动区可视区的下沿，
    /// 且至少留一行——空间小到极端（横屏）时也不至于把清单压没。
    private var filmListHeight: CGFloat {
        let content = max(filmListContentHeight, 1)
        guard let spaceBelowBar else { return content }
        let panelMaxHeight = spaceBelowBar - Self.panelGap - Self.panelBottomMargin
        let room = panelMaxHeight - Self.panelPadding * 2 - panelFooterHeight
        return min(content, max(room, SLSize.minTouchTarget))
    }

    private static let panelPadding: CGFloat = SLSpacing.small + 2
    /// 面板与白条下沿的间隙。
    private static let panelGap: CGFloat = SLSpacing.tiny
    /// 面板下沿与滚动区可视区下沿之间留的空，别让投影和圆角贴着标签栏。
    private static let panelBottomMargin: CGFloat = SLSpacing.medium

    private func dropdownRow(_ film: Film) -> some View {
        let isCurrent = film.id == store.currentFilmID
        return Button {
            if !isCurrent, store.loadFilm(film.id) { Haptics.selection() }
            isExpanded = false
        } label: {
            HStack(spacing: SLSpacing.small) {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isCurrent ? 1 : 0)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                Text("\(SLDateText.monthDay(film.updatedAt)) · \(film.displayTitle)")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: SLSize.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    private func actionRow(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.impact(.light)
            isExpanded = false
            action()
        } label: {
            HStack(spacing: SLSpacing.small) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: SLSize.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rowDivider: some View {
        Divider()
            .padding(.vertical, SLSpacing.tiny)
            .accessibilityHidden(true)
    }

    /// 铺满整个滚动区的透明点击层：面板外任意位置点一下就收起。
    ///
    /// 放在 `.background` 里（卡片内容仍在它上面，行照常可点），靠 `zIndex`
    /// 抬到同屏后面的卡片之上——否则后面那些不透明的卡片会把触摸截走。
    ///
    /// 范围取外层 `ScrollView` 的可视区（`bounds(of: .scrollView)` 直接换算到本视图
    /// 坐标系，随滚动自动跟随），再向四周多铺 `outsideTapBleed`：内容会延伸到导航栏、
    /// 标签栏下面，而 `.scrollView` 的可视区不含这两带。多出滚动视图的部分收不到触摸。
    /// 不在滚动视图里时退化为白条自身。
    private var outsideTapCatcher: some View {
        GeometryReader { proxy in
            let viewport = (proxy.bounds(of: .scrollView) ?? proxy.frame(in: .local))
                .insetBy(dx: -Self.outsideTapBleed, dy: -Self.outsideTapBleed)
            Color.clear
                .contentShape(Rectangle())
                .frame(width: viewport.width, height: viewport.height)
                .position(x: viewport.midX, y: viewport.midY)
                .onTapGesture { isExpanded = false }
        }
        // 顺带量出白条下沿到可视区下沿还剩多少空间，给面板定高度上限。
        // 这一层只在展开时存在，所以收起状态下滚动不会触发任何重新布局。
        .onGeometryChange(for: CGFloat?.self) { proxy in
            proxy.bounds(of: .scrollView).map { $0.maxY - proxy.size.height }
        } action: { spaceBelowBar = $0 }
        .accessibilityHidden(true)
    }

    /// 点击收起层向四周多铺的距离，只需大于导航栏 / 标签栏所占的高度，不是测量值。
    private static let outsideTapBleed: CGFloat = 200

    // MARK: - 标题区

    private var film: Film? { store.currentFilm }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let film, film.hasTitle {
                Text(film.displayTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                // 还没有标题：占位一道虚线，高度与 headline 一行对齐
                NotePlaceholder(width: 108)
                    .frame(height: 22, alignment: .center)
            }

            subtitleRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// 「9月14日 · ✓ 2/5」：已拍进度用勾选图标加数字，不写「已拍」。没有镜头时写「无镜头」。
    @ViewBuilder
    private var subtitleRow: some View {
        Group {
            if let film, !film.shots.isEmpty {
                HStack(spacing: SLSpacing.small) {
                    Text(SLDateText.monthDay(film.updatedAt))
                    IconValue(
                        systemImage: "checkmark.circle",
                        text: film.progressText(recordedCount: store.recordedCount(of: film))
                    )
                }
            } else {
                Text("无镜头")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// 读屏用的副行：日期与已拍进度都要说出来，图标本身不朗读
    private var subtitle: String {
        guard let film, !film.shots.isEmpty else { return "无镜头" }
        let progress = film.progressText(recordedCount: store.recordedCount(of: film))
        return "\(SLDateText.monthDay(film.updatedAt))，已拍 \(progress)"
    }

    private var accessibilityLabel: String {
        guard let film else { return "当前影片" }
        return "当前影片 \(film.displayTitle)，\(subtitle)"
    }

    private func beginTitleEdit() {
        Haptics.impact(.light)
        titleDraft = store.currentFilm?.trimmedTitle ?? ""
        isEditingTitle = true
    }
}

// MARK: - 影片菜单

/// 白条实际高度（含内边距），供悬浮面板锚定下沿用。
private struct FilmBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 切换影片、改标题、新建影片。
///
/// 分镜页三点按钮的入口，保留系统 `Menu`（历史页的影片条已换成与白条同宽的
/// 自展开面板，见 `FilmBar`）。菜单项只放一行「日期 · 标题」，
/// 当前影片由 `Picker` 自动打勾——不进第二层模态，也不需要自绘列表。
///
/// 改标题弹窗和新建影片确认挂在外层（`filmActionDialogs`），不挂在 `Menu` 上：
/// 菜单一关掉，挂在它身上的弹层有时会一起被收掉。
struct FilmSwitcherMenu<MenuLabel: View>: View {
    @EnvironmentObject private var store: ShotStore

    var showsTitleEdit: Bool = true

    @Binding var isEditingTitle: Bool
    @Binding var titleDraft: String
    @Binding var isConfirmingRemake: Bool

    @ViewBuilder var label: () -> MenuLabel

    var body: some View {
        Menu {
            Picker("影片", selection: currentFilmSelection) {
                ForEach(store.sortedFilms) { item in
                    Text("\(SLDateText.monthDay(item.updatedAt)) · \(item.displayTitle)")
                        .tag(Optional(item.id))
                }
            }

            Divider()

            if showsTitleEdit {
                Button {
                    Haptics.impact(.light)
                    titleDraft = store.currentFilm?.trimmedTitle ?? ""
                    isEditingTitle = true
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
            }

            Button {
                Haptics.impact(.light)
                isConfirmingRemake = true
            } label: {
                // 只写动作，后果交给确认弹层
                Label("新建影片", systemImage: "film.stack")
            }
        } label: {
            label()
        }
        .accessibilityLabel("影片")
        .accessibilityValue(store.currentFilm?.displayTitle ?? "")
    }

    /// 选中即载入：把这部影片设为当前影片，分镜页接着编辑它。
    ///
    /// 切换不是覆盖——旧影片原样留在库里，再选一次就能回来。
    private var currentFilmSelection: Binding<UUID?> {
        Binding(
            get: { store.currentFilmID },
            set: { id in
                guard let id, id != store.currentFilmID else { return }
                if store.loadFilm(id) { Haptics.selection() }
            }
        )
    }
}

/// 改标题弹窗 + 新建影片确认。分镜页和历史页共用，避免两套文案。
private struct FilmActionDialogs: ViewModifier {
    @EnvironmentObject private var store: ShotStore

    @Binding var isEditingTitle: Bool
    @Binding var titleDraft: String
    @Binding var isConfirmingRemake: Bool

    func body(content: Content) -> some View {
        content
            .alert("重命名", isPresented: $isEditingTitle) {
                TextField("影片名称", text: $titleDraft)
                Button("保存", action: commitTitle)
                Button("取消", role: .cancel) {}
            }
            .alert(
                "新建影片？",
                isPresented: $isConfirmingRemake
            ) {
                Button("新建") { remake() }
                Button("取消", role: .cancel) {}
            } message: {
                Text(remakeMessage)
            }
    }

    private func commitTitle() {
        guard let id = store.currentFilmID else { return }
        store.renameFilm(id, to: titleDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        Haptics.selection()
    }

    private func remake() {
        store.remakeCurrentFilm()
        Haptics.success()
    }

    /// 「新建影片」不会覆盖当前影片，只用一句话说清「东西去哪了」。
    private var remakeMessage: String {
        guard let film = store.currentFilm, film.hasTitle else { return "当前影片将保留在影片库。" }
        return "《\(film.trimmedTitle)》将保留在影片库。"
    }
}

extension View {
    func filmActionDialogs(
        isEditingTitle: Binding<Bool>,
        titleDraft: Binding<String>,
        isConfirmingRemake: Binding<Bool>
    ) -> some View {
        modifier(
            FilmActionDialogs(
                isEditingTitle: isEditingTitle,
                titleDraft: titleDraft,
                isConfirmingRemake: isConfirmingRemake
            )
        )
    }
}

#Preview {
    ScrollView {
        VStack(spacing: SLSpacing.medium) {
            FilmBar()
            FilmBar()
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
    .environmentObject(ShotStore())
}
