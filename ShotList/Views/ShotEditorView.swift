import SwiftUI

/// 编辑镜头信息。编号即拍摄顺序，改编号会把镜头移动到对应位置。
struct ShotEditorView: View {
    let shot: Shot

    @EnvironmentObject private var store: ShotStore
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var note: String
    @State private var number: Int
    @FocusState private var focusedField: Field?

    private enum Field { case title, note }

    init(shot: Shot) {
        self.shot = shot
        _title = State(initialValue: shot.title)
        _note = State(initialValue: shot.note)
        _number = State(initialValue: shot.number)
    }

    private var numberRange: ClosedRange<Int> {
        1...max(1, store.shots.count)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如：开场 · 城市天际线", text: $title, axis: .vertical)
                        .lineLimit(1...3)
                        .focused($focusedField, equals: .title)
                        .submitLabel(.done)
                        .accessibilityLabel("镜头标题")
                } header: {
                    Text("镜头标题")
                } footer: {
                    Text("留空时会显示为「镜头 \(shot.number)」。")
                }

                Section {
                    TextField("运镜方式、口播要点、道具…", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focusedField, equals: .note)
                        .accessibilityLabel("拍摄备注")
                } header: {
                    Text("拍摄备注")
                }

                Section {
                    Stepper(value: $number, in: numberRange) {
                        HStack {
                            Text("镜头编号")
                            Spacer()
                            Text("\(number)")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("镜头编号")
                    .accessibilityValue("\(number)")
                } header: {
                    Text("顺序")
                } footer: {
                    Text("编号决定拍摄顺序和导出时的文件名前缀。改为其它数字，这个镜头会被移动到对应位置。")
                }
            }
            .navigationTitle("编辑镜头")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                if title.isEmpty && note.isEmpty {
                    focusedField = .title
                }
            }
        }
    }

    private func save() {
        var edited = shot
        edited.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.number = min(max(number, numberRange.lowerBound), numberRange.upperBound)
        store.update(edited)
        dismiss()
    }
}

#Preview {
    ShotEditorView(shot: Shot(number: 2, title: "街景横摇", note: "手持稳定器，保持水平"))
        .environmentObject(ShotStore())
}
