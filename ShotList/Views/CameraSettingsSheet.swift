import SwiftUI

/// 拍摄设置：分辨率与帧率。
///
/// 只画选项与回调，可不可用由调用方按当前摄像头算好传进来——这样这一页既能
/// 单独渲染验收，也不会自己跑去问设备。
///
/// 不支持的那些档位照旧列出来但置灰：让人知道「4K 是有的，只是这颗摄像头给不了」，
/// 比直接消失更好懂。
struct CameraSettingsSheet: View {
    /// 当前摄像头支持的档位
    let availableResolutions: [CaptureResolution]
    let availableFrameRates: [CaptureFrameRate]
    /// 当前实际生效的档位（可能与用户选的不同：切到前置摄像头会降一档）
    let resolution: CaptureResolution?
    let frameRate: CaptureFrameRate?

    let isRecording: Bool

    var onSelectResolution: (CaptureResolution) -> Void
    var onSelectFrameRate: (CaptureFrameRate) -> Void
    var onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if isRecording {
                    Section {
                        Label("正在拍摄，停止拍摄后才能修改画质。", systemImage: "record.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    ForEach(CaptureResolution.allCases) { option in
                        row(
                            title: option.title,
                            trailing: isResolutionAvailable(option) ? option.dimensionsText : unavailableNote,
                            isSelected: resolution == option,
                            isEnabled: !isRecording && isResolutionAvailable(option)
                        ) {
                            onSelectResolution(option)
                        }
                    }
                } header: {
                    Text("分辨率")
                } footer: {
                    Text("分辨率越高画面越清晰，文件也越大。")
                }

                Section {
                    ForEach(CaptureFrameRate.allCases) { option in
                        row(
                            title: option.title,
                            trailing: isFrameRateAvailable(option) ? nil : unavailableNote,
                            isSelected: frameRate == option,
                            isEnabled: !isRecording && isFrameRateAvailable(option)
                        ) {
                            onSelectFrameRate(option)
                        }
                    }
                } header: {
                    Text("帧率")
                } footer: {
                    Text("60 fps 画面更顺、方便后期慢放，24 fps 更接近电影的质感。可选的帧率取决于分辨率。")
                }

                Section {
                    Label("单个片段最长 10 分钟；到达上限会自动停止，并提示已保存。", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("拍摄设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onDismiss() }
                }
            }
        }
    }

    // MARK: - 行

    /// 一行一个档位：名称在前，右侧是它的规格（不可用时写「不支持」），
    /// 选中项在最右打个勾。名称与规格排成一行，六行选项才不用滚动。
    private func row(
        title: String,
        trailing: String?,
        isSelected: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: SLSpacing.small) {
                Text(title)
                    .foregroundStyle(isEnabled ? .primary : .secondary)

                Spacer(minLength: SLSpacing.small)

                if let trailing {
                    Text(trailing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(minHeight: SLSize.minTouchTarget)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(trailing.map { "\(title)，\($0)" } ?? title)
        .accessibilityValue(isSelected ? "已选择" : (isEnabled ? "未选择" : "不可用"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - 可用性

    private func isResolutionAvailable(_ option: CaptureResolution) -> Bool {
        availableResolutions.contains(option)
    }

    private func isFrameRateAvailable(_ option: CaptureFrameRate) -> Bool {
        availableFrameRates.contains(option)
    }

    private var unavailableNote: String {
        availableFrameRates.isEmpty ? "这台摄像头不支持" : "该分辨率下不支持"
    }
}

#Preview {
    CameraSettingsSheet(
        availableResolutions: [.uhd4K, .hd1080, .hd720],
        availableFrameRates: [.fps24, .fps30],
        resolution: .hd1080,
        frameRate: .fps30,
        isRecording: false,
        onSelectResolution: { _ in },
        onSelectFrameRate: { _ in },
        onDismiss: {}
    )
}
