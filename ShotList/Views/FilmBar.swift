import SwiftUI

/// 影片条：历史页顶部的影片切换器。
///
/// 一行交代三件事——**这是哪部影片**（标题）、**它进行到哪了**（最后更新 + 进度）、
/// **怎么换一部**（右侧下拉箭头）。分镜页把标题放进导航栏、把切换影片放进
/// 三点菜单，所以这条只出现在历史页。
///
/// 下拉不是系统 `Menu`：点箭头后从白条下方浮出一块与它同宽的面板
/// （影片清单 + 重制入口），悬在下方内容之上、不挤压版式；
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
                    .padding(.top, cardHeight + SLSpacing.tiny)
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
                .accessibilityHint("点按修改影片标题")
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

    /// 与白条同宽、悬浮在其下方的影片清单：当前影片打勾，末尾是重制入口。
    private var dropdownPanel: some View {
        VStack(spacing: 0) {
            ForEach(store.sortedFilms) { film in
                dropdownRow(film)
            }

            rowDivider

            if allowsRename {
                actionRow(title: "修改标题", systemImage: "pencil") {
                    titleDraft = store.currentFilm?.trimmedTitle ?? ""
                    isEditingTitle = true
                }
            }

            actionRow(title: "重制", systemImage: "film.stack") {
                isConfirmingRemake = true
            }
        }
        .padding(SLSpacing.small + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: SLSize.cardCornerRadius, style: .continuous)
        )
        // 悬浮感：柔和投影把面板从下方内容上托起来。
        .shadow(color: .black.opacity(0.14), radius: 18, x: 0, y: 10)
    }

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

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// 「9月14日更新 · 2/5 已拍」；标题为空时前面换成一句提示
    private var subtitle: String {
        guard let film else { return "还没有影片" }
        let progress = film.progressText(recordedCount: store.recordedCount(of: film))
        guard film.shots.isEmpty else {
            return "\(SLDateText.monthDay(film.updatedAt))更新 · \(progress)"
        }
        return film.hasTitle ? "还没添加镜头" : "点这里给影片起个名字"
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

/// 切换影片、改标题、重制。
///
/// 分镜页三点按钮的入口，保留系统 `Menu`（历史页的影片条已换成与白条同宽的
/// 自展开面板，见 `FilmBar`）。菜单项只放一行「日期 · 标题」，
/// 当前影片由 `Picker` 自动打勾——不进第二层模态，也不需要自绘列表。
///
/// 改标题弹窗和重制确认挂在外层（`filmActionDialogs`），不挂在 `Menu` 上：
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
            Picker("切换影片", selection: currentFilmSelection) {
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
                    Label("修改标题", systemImage: "pencil")
                }
            }

            Button {
                Haptics.impact(.light)
                isConfirmingRemake = true
            } label: {
                // 只写动词。括注「收起当前影片，开一部空白影片」交给确认弹层——
                // 菜单项是原生单行文本，长句会被截断，而弹层里那句话说全了。
                Label("重制", systemImage: "film.stack")
            }
        } label: {
            label()
        }
        .accessibilityLabel("影片菜单")
        .accessibilityValue(store.currentFilm?.displayTitle ?? "")
        // 需求 4 的安全底线：「载入不会删除当前影片」。菜单里加不了常驻小字
        // （原生菜单只有一列可选中的行），这句话就落在无障碍提示里——
        // 屏幕朗读的用户同样需要知道切换是安全的。
        .accessibilityHint(
            showsTitleEdit
            ? "切换影片、修改标题、重制影片。切换不会删除当前影片，它仍留在影片库里。"
            : "切换影片、重制影片。切换不会删除当前影片，它仍留在影片库里。"
        )
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

/// 改标题弹窗 + 重制确认。分镜页和历史页共用，避免两套文案。
private struct FilmActionDialogs: ViewModifier {
    @EnvironmentObject private var store: ShotStore

    @Binding var isEditingTitle: Bool
    @Binding var titleDraft: String
    @Binding var isConfirmingRemake: Bool

    func body(content: Content) -> some View {
        content
            .alert("影片标题", isPresented: $isEditingTitle) {
                TextField("给这部影片起个名字", text: $titleDraft)
                Button("保存", action: commitTitle)
                Button("取消", role: .cancel) {}
            } message: {
                Text("留空也可以，之后在影片菜单里按日期找得到。")
            }
            .confirmationDialog(
                "重制当前影片？",
                isPresented: $isConfirmingRemake,
                titleVisibility: .visible
            ) {
                Button("开一部空白影片") { remake() }
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

    /// 「重制」这个词本身就暗示会丢东西，所以这里必须把「东西去哪了」说清楚。
    /// 确认按钮同理——写「开一部空白影片」，而不是复述一遍「重制」。
    private var remakeMessage: String {
        guard let film = store.currentFilm else { return "现在打开一部空白影片。" }
        let subject = film.hasTitle ? "《\(film.trimmedTitle)》" : "当前影片"
        return "\(subject)会留在影片库里，随时可以载入继续拍。现在打开一部空白影片。"
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
