import SwiftUI

/// 「模板」页：写一段纯文字，镜头面板里点「应用模板」时原样填进内容框。
///
/// 模板就是一段用户自己排版的字——默认是「描述：」「字幕：」「上方角标：」「转场：」四行，
/// 想加想减、换标签都随意。应用只是把这段话整段拷进去，没有变量、没有占位符，
/// 用户在各标签后面写具体内容即可。
///
/// 输入框直接显示当前模板（没有自定义时就是默认模板），不是灰色占位：
/// 用户要的是「在这个基础上改」，占位文字一敲字就没了，没法改。
///
/// 编辑走**本地草稿 + 停手后落盘**，做法同 `FilmStyleView`：打字会连发很多次值，
/// 每敲一个字写一遍 `films.json` 没必要。
struct ShotTemplateSheet: View {
    @EnvironmentObject private var store: ShotStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    /// 草稿是从哪部影片读进来的。
    ///
    /// 初值 `nil`、且落盘前必须与 `currentFilmID` 相等：页面刚出现时 `draft` 还是空串，
    /// 读影片的任务可能还没跑完，此时若去落盘，会把已有的模板**覆盖成空白**。
    /// 这个标记就是那条闸门（与 `FilmStyleView` 同一处理）。
    @State private var loadedFilmID: Film.ID?
    @FocusState private var isEditing: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextEditor(text: $draft)
                        .font(.body)
                        .frame(minHeight: 200)
                        .focused($isEditing)
                        .accessibilityLabel("模板")
                        .padding(.vertical, SLSpacing.small)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: store.currentFilmID) {
            draft = store.shotTemplate
            loadedFilmID = store.currentFilmID
        }
        // 打字会连发很多次：等手停下来再落盘，中途的中间值不写文件。
        // 闸门放在 sleep 之后——睡醒时「读影片」那个任务一定已经跑完了。
        .task(id: draft) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            guard loadedFilmID == store.currentFilmID else { return }
            store.updateShotTemplate(draft)
        }
        // 关掉页面会取消上面那个等待中的任务，最后这一次改动必须在这里补上，
        // 否则「写完立刻关掉」丢掉的就是用户刚敲的那几个字
        .onDisappear {
            guard loadedFilmID == store.currentFilmID else { return }
            store.updateShotTemplate(draft)
        }
    }
}

#Preview {
    ShotTemplateSheet()
        .environmentObject(ShotStore())
}
