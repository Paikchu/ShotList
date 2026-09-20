import SwiftUI

/// 「剪辑风格」页：写一段话，说清这条片子该怎么剪。
///
/// 这一页以前是一组旋钮（画幅、帧率、节奏、图层位置、字号、音轨…），导出成
/// `剪辑规格.json`。现在改成**一段描述**——消费它的本来就是能读自然语言的剪辑工具，
/// 为每种风格加一个旋钮既加不完，也表达不了旋钮之外的偏好（「快切不拖沓」
/// 「别加音乐」这类要求没有对应的控件，却是用户真正想说的事）。
///
/// 输入框留空时显示一段完整示例（`FilmStylePrompt.placeholder`），
/// 下面再列一遍「可以写这些」。示例是**灰色占位**，不会被当成已填内容写进文件。
///
/// 编辑走**本地草稿 + 拖后落盘**：打字会连发很多次值，每敲一个字写一遍
/// `films.json` 会卡手，所以等手停下来再写（见 `body` 末尾的 `task(id:)`）。
struct FilmStyleView: View {
    @EnvironmentObject private var store: ShotStore

    @State private var draft: String = ""
    /// 草稿是从哪部影片读进来的。
    ///
    /// 初值 `nil`、且落盘前必须与 `currentFilmID` 相等：页面刚出现时 `draft` 还是
    /// 空串，读影片的那个任务可能还没跑完，此时若去落盘，会把用户已经写好的
    /// 风格**覆盖成空白**。这个标记就是那条闸门。
    @State private var loadedFilmID: Film.ID?
    @FocusState private var isEditing: Bool

    var body: some View {
        List {
            Section {
                editor
            } header: {
                SectionHeader(title: "风格描述", systemImage: "text.alignleft")
            }

            Section {
                // 一行短词并排，只提示「能写哪几类」
                Text(FilmStylePrompt.guidance.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } header: {
                SectionHeader(title: "可写", systemImage: "list.bullet")
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, -SLSpacing.groupedListTopSlack, for: .scrollContent)
        .navigationTitle("剪辑风格")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.currentFilmID) {
            draft = store.currentFilm?.stylePrompt ?? ""
            loadedFilmID = store.currentFilmID
        }
        // 打字会连发很多次：等手停下来再落盘，中途的中间值不写文件。
        // 闸门放在 sleep 之后——睡醒时「读影片」那个任务一定已经跑完了。
        .task(id: draft) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            guard loadedFilmID == store.currentFilmID else { return }
            store.updateStylePrompt(draft)
        }
        // 返回上一页会取消上面那个等待中的任务，最后这一次改动必须在这里补上，
        // 否则「写完立刻返回」丢掉的就是用户刚敲的那几个字
        .onDisappear {
            guard loadedFilmID == store.currentFilmID else { return }
            store.updateStylePrompt(draft)
        }
    }

    /// 输入框 + 占位示例。
    ///
    /// `TextEditor` 没有原生占位，所以自己叠一层：只在真的没写字时显示，
    /// 并且 `allowsHitTesting(false)`——点到示例文字上也该把光标放进输入框。
    /// 左侧内缩 5pt 是为了跟 `TextEditor` 内部的文字缩进对齐，
    /// 否则一敲字示例消失、正文会往左跳一下。
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(FilmStylePrompt.placeholder)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 200)
                .focused($isEditing)
                .accessibilityLabel("剪辑风格")
        }
        .padding(.vertical, SLSpacing.small)
    }
}

#Preview {
    NavigationStack {
        FilmStyleView()
            .environmentObject(ShotStore())
    }
}
