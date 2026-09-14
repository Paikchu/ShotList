import SwiftUI

/// 编辑分镜。编号即拍摄顺序，改编号会把镜头移动到对应位置。
struct ShotEditorView: View {
    let shot: Shot

    @EnvironmentObject private var store: ShotStore
    @Environment(\.dismiss) private var dismiss

    @State private var note: String
    @State private var number: Int
    @FocusState private var isNoteFocused: Bool

    init(shot: Shot) {
        self.shot = shot
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
                    TextField(
                        "例如：无人机缓慢上升，配一句开场旁白",
                        text: $note,
                        axis: .vertical
                    )
                    .lineLimit(3...10)
                    .focused($isNoteFocused)
                    .accessibilityLabel("分镜描述")
                } header: {
                    Text("分镜描述")
                } footer: {
                    Text("写清这个镜头要拍什么：画面内容、运镜方式、口播要点、道具。导出时会用这段描述给视频命名。")
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
                if note.isEmpty { isNoteFocused = true }
            }
        }
    }

    private func save() {
        var edited = shot
        edited.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.number = min(max(number, numberRange.lowerBound), numberRange.upperBound)
        store.update(edited)
        dismiss()
    }
}

#Preview {
    ShotEditorView(shot: Shot(number: 2, note: "手持稳定器横摇，保持水平，速度放慢"))
        .environmentObject(ShotStore())
}
