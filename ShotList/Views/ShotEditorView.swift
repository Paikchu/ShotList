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

    /// 与导出结果同一套命名规则：边打字边看到最终文件名。
    ///
    /// 扩展名取自该镜头主素材的真实格式（相册导入的 mp4 导出后仍是 mp4），
    /// 没有片段时按 mov 兜底。
    private var previewFileName: String {
        ExportPackageBuilder.mainFileName(
            number: number,
            note: note,
            fileExtension: store.shot(withID: shot.id)?.mainFileExtension ?? "mov"
        )
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

                    LabeledContent {
                        Text(previewFileName)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } label: {
                        Label("导出文件名", systemImage: "doc.text")
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("导出文件名")
                    .accessibilityValue(previewFileName)
                } header: {
                    Text("分镜描述")
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
