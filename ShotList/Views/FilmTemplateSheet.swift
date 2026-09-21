import SwiftUI

/// 「模板」页：影片模板库。写好几份模板，点一行把它绑定给当前影片。
///
/// 模板是应用级的（见 `FilmTemplate`），这一页同时做两件事：
///
/// - **管理**：加号新建，每行尾的「更多」菜单编辑 / 复制 / 删除；
/// - **绑定**：行是单选，点哪一行当前影片就绑定哪一份并打勾，点「默认」改回内置的四行。
///   页面标题下写着影片名，看得出绑定的是哪一部——创建影片之后随时可以改绑。
///
/// 「默认」是内置的基线：不可编辑、不可删除。想在它的基础上改，新建一份——
/// 新模板预填默认四行，正是「在这个基础上改」。
struct FilmTemplateSheet: View {
    @EnvironmentObject private var store: ShotStore
    @Environment(\.dismiss) private var dismiss

    /// 推入编辑页的模板。新建的那份在编辑页里第一次改动之前不在库里，见 `FilmTemplateEditor`。
    @State private var path: [FilmTemplate] = []
    @State private var pendingDeletion: FilmTemplate?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    defaultRow
                    ForEach(store.templates) { template in
                        templateRow(template)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("模板")
            // 影片名写在标题下：一眼看出点选绑定的是哪部影片
            .navigationSubtitle(store.currentFilm?.displayTitle ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: FilmTemplate.self) { template in
                FilmTemplateEditor(template: template)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.impact(.light)
                        // 还没进库：编辑页里改了名字或内容才会真的存下来，点了加号又退出不留空壳
                        path.append(FilmTemplate())
                    } label: {
                        Label("新建模板", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("删除模板？", isPresented: deletionBinding, presenting: pendingDeletion) { template in
                Button("删除", role: .destructive) {
                    store.deleteTemplate(template.id)
                    Haptics.warning()
                }
                Button("取消", role: .cancel) {}
            } message: { template in
                let count = store.boundFilmCount(of: template.id)
                if count > 0 {
                    Text("\(count) 部影片将改用默认模板。")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 行

    private var defaultRow: some View {
        TemplateSelectRow(
            name: Film.defaultTemplateName,
            preview: FilmTemplate.previewText(of: Film.defaultShotTemplate),
            isSelected: store.boundTemplate == nil
        ) {
            if store.bindTemplate(nil) { Haptics.selection() }
        }
    }

    private func templateRow(_ template: FilmTemplate) -> some View {
        HStack(spacing: SLSpacing.small) {
            TemplateSelectRow(
                name: template.displayName,
                preview: template.previewText,
                isSelected: store.boundTemplate?.id == template.id
            ) {
                if store.bindTemplate(template.id) { Haptics.selection() }
            }

            Menu {
                Button {
                    path.append(template)
                } label: {
                    Label("编辑", systemImage: "pencil")
                }

                Button {
                    if store.duplicateTemplate(template.id) != nil { Haptics.impact(.light) }
                } label: {
                    Label("复制", systemImage: "plus.square.on.square")
                }

                Divider()

                Button(role: .destructive) {
                    pendingDeletion = template
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(width: SLSize.minTouchTarget, height: SLSize.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(template.displayName)，更多")
        }
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { presented in if !presented { pendingDeletion = nil } }
        )
    }
}

/// 一行模板：勾选位 + 名称 + 一行预览。「模板」页与「新建影片」选模板页共用。
///
/// `isSelected` 为 `nil` 时不画勾选位（选模板页里点一行就是新建，没有「当前」的概念）。
private struct TemplateSelectRow: View {
    let name: String
    let preview: String
    var isSelected: Bool?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SLSpacing.small) {
                if let isSelected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .opacity(isSelected ? 1 : 0)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: SLSize.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(preview)
        .accessibilityAddTraits(isSelected == true ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - 编辑页

/// 一份模板的编辑页：名称 + 内容两个输入框，输入自动保存。
///
/// 编辑走**本地草稿 + 停手后落盘**，做法同 `FilmStyleView`：打字会连发很多次值，
/// 每敲一个字写一遍 `films.json` 没必要；离开页面时立即再落一次，不丢最后几个字。
///
/// 草稿在 `init` 里从传入的模板取初值，不必像影片级的编辑页那样等「读影片」的任务、
/// 再用闸门防止把已有内容覆盖成空白。
///
/// 新建的模板（还不在库里）**第一次真的改了东西才存**：名称有字，或内容与预填的不同。
/// 点了加号又原样退出，库里不会留下一份没人要的空壳。
struct FilmTemplateEditor: View {
    let template: FilmTemplate

    @EnvironmentObject private var store: ShotStore

    @State private var name: String
    @State private var content: String

    init(template: FilmTemplate) {
        self.template = template
        _name = State(initialValue: template.name)
        _content = State(initialValue: template.content)
    }

    private struct Draft: Equatable {
        var name: String
        var content: String
    }

    private var draft: Draft { Draft(name: name, content: content) }

    var body: some View {
        List {
            Section {
                TextField("名称", text: $name)
                    .accessibilityLabel("名称")
            } header: {
                SectionHeader(title: "名称", systemImage: "tag")
            }

            Section {
                TextEditor(text: $content)
                    .font(.body)
                    .frame(minHeight: 200)
                    .accessibilityLabel("内容")
                    .padding(.vertical, SLSpacing.small)
            } header: {
                SectionHeader(title: "内容", systemImage: "text.alignleft")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        // 打字会连发很多次：等手停下来再落盘，中途的中间值不写文件
        .task(id: draft) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            save()
        }
        // 关掉页面会取消上面那个等待中的任务，最后这一次改动必须在这里补上，
        // 否则「写完立刻退出」丢掉的就是用户刚敲的那几个字
        .onDisappear { save() }
    }

    private var displayName: String {
        FilmTemplate(name: name).displayName
    }

    private func save() {
        if store.template(withID: template.id) != nil {
            store.updateTemplate(template.id, name: name, content: content)
            return
        }
        let untouched = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && content.trimmingCharacters(in: .whitespacesAndNewlines)
                == template.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !untouched else { return }
        store.addTemplate(FilmTemplate(id: template.id, name: name, content: content))
    }
}

// MARK: - 新建影片：选模板

/// 「新建影片？」对话框里点「从模板新建」弹出的选择页：列出自建模板，点一份就新建影片并绑定它。
///
/// 不列「默认」：选默认就是对话框里的「新建」。
struct FilmTemplatePicker: View {
    var onPick: (FilmTemplate) -> Void

    @EnvironmentObject private var store: ShotStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.templates) { template in
                    TemplateSelectRow(
                        name: template.displayName,
                        preview: template.previewText,
                        isSelected: nil
                    ) {
                        onPick(template)
                        dismiss()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("新建影片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    FilmTemplateSheet()
        .environmentObject(ShotStore())
}
