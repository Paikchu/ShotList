import SwiftUI

/// 影片条：分镜页与历史页共用的顶部组件。
///
/// 一行交代三件事——**这是哪部影片**（标题）、**它进行到哪了**（最后更新 + 进度）、
/// **怎么换一部**（右侧影片菜单）。两个页面用同一个组件，切换影片的交互因此
/// 只需要维护一处。
///
/// 标题为空时画一道虚线（虚线在这套界面里一直是「这里还没有内容」的意思，
/// 见 `NotePlaceholder`），不写「未命名」之类的字——空着本身就是信息。
struct FilmBar: View {
    @EnvironmentObject private var store: ShotStore

    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var isConfirmingRemake = false

    var body: some View {
        CardContainer(padding: SLSpacing.small + 2) {
            HStack(spacing: SLSpacing.small) {
                Button(action: beginTitleEdit) {
                    titleBlock
                }
                .buttonStyle(ShotCardButtonStyle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint("点按修改影片标题")
                .accessibilityAddTraits(.isButton)

                filmMenu
            }
        }
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

    // MARK: - 影片菜单

    /// 用原生 `Menu`：切换影片、重制都在这里。
    ///
    /// 菜单项只放一行「日期 · 标题」，当前影片由 `Picker` 自动打勾——
    /// 不进第二层模态，也不需要自绘列表。
    private var filmMenu: some View {
        Menu {
            Picker("切换影片", selection: currentFilmSelection) {
                ForEach(store.sortedFilms) { item in
                    Text("\(SLDateText.monthDay(item.updatedAt)) · \(item.displayTitle)")
                        .tag(Optional(item.id))
                }
            }

            Divider()

            Button {
                Haptics.impact(.light)
                isConfirmingRemake = true
            } label: {
                // 只写动词。括注「收起当前影片，开一部空白影片」交给确认弹层——
                // 菜单项是原生单行文本，长句会被截断，而弹层里那句话说全了。
                Label("重制", systemImage: "film.stack")
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.primary)
                .frame(width: SLSize.minTouchTarget, height: SLSize.minTouchTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("影片菜单")
        .accessibilityValue(film?.displayTitle ?? "")
        // 需求 4 的安全底线：「载入不会删除当前影片」。菜单里加不了常驻小字
        // （原生菜单只有一列可选中的行），这句话就落在无障碍提示里——
        // 屏幕朗读的用户同样需要知道切换是安全的。
        .accessibilityHint("切换影片、重制影片。切换不会删除当前影片，它仍留在影片库里。")
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

    // MARK: - 动作

    private func beginTitleEdit() {
        Haptics.impact(.light)
        titleDraft = store.currentFilm?.trimmedTitle ?? ""
        isEditingTitle = true
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
