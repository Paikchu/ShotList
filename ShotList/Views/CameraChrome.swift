import SwiftUI

/// 取景界面上的静止内容。
///
/// 抽成一个值类型，界面外壳就不再依赖相机对象：能单独渲染、单独验收，
/// 也不会为了画一行字去构造一台真相机。
nonisolated struct CameraChromeState: Equatable {
    /// 「16」
    var shotNumber: String
    /// 分镜描述
    var note: String
    /// 这个镜头已经拍了几条
    var savedTakeCount: Int
    var isRecording: Bool
    var elapsed: TimeInterval
    var isTorchOn: Bool
    var isTorchAvailable: Bool
    /// 正在把回看的片段存进分镜，此时不接受新的录制操作
    var isSaving: Bool
    var zoomScale: ZoomScale
    var zoomFactor: CGFloat
    /// 顶栏上的紧凑画质写法，例如「4K·30」
    var settingsText: String?
    /// 画质的完整说法，供无障碍朗读
    var settingsAccessibilityText: String?
    /// 长按取景画面后是否锁住了对焦与曝光
    var isFocusLocked: Bool

    var hasNote: Bool {
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

}

/// 取景页上统一的圆形图标外观（关闭、补光、切换摄像头都是它）。
struct CameraCircleGlyph: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .font(.headline)
            .frame(width: SLSize.minTouchTarget, height: SLSize.minTouchTarget)
            .background(.ultraThinMaterial, in: Circle())
    }
}

/// 取景界面的外壳：顶部（关闭 / 镜头编号 / 画质）、分镜描述、焦距档位、
/// 对焦锁定提示、录制指示、底部控制。
///
/// 只管画与回调，不碰相机对象——相机状态由 `CameraCaptureView` 组装成
/// `CameraChromeState` 传进来。
struct CameraChrome: View {
    let state: CameraChromeState
    /// 描述是否展开
    @Binding var isNoteExpanded: Bool

    var onClose: () -> Void
    var onToggleNote: () -> Void
    var onOpenSettings: () -> Void
    var onToggleTorch: () -> Void
    var onToggleRecording: () -> Void
    var onSwitchCamera: () -> Void
    var onSelectZoom: (CGFloat) -> Void
    var onUnlockFocus: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBlinking = false
    /// 展开后描述内容实际有多高，用来在「按内容自适应」与「到了上限就滚动」之间取值
    @State private var noteContentHeight: CGFloat = 0

    /// 展开后的描述最多占多高。取景画面是这一页的主角，
    /// 再长的描述也不能把它挤没，超出的部分在卡片里滚动。
    private let expandedNoteMaxHeight: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            topBar
            noteCard
                .padding(.horizontal, SLSpacing.medium)
                .padding(.top, SLSpacing.small)

            Spacer(minLength: 0)

            if state.isFocusLocked {
                focusLockChip
                    .padding(.bottom, SLSpacing.small)
                    .transition(.opacity)
            }

            if state.isRecording {
                recordingIndicator
                    .padding(.bottom, SLSpacing.small)
            }

            zoomPills
                .padding(.bottom, SLSpacing.small)

            bottomControls
        }
        .foregroundStyle(.white)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.isFocusLocked)
    }

    // MARK: - 顶部

    private var topBar: some View {
        ZStack {
            // 标题单独一层：左右两侧的按钮宽度不一样（关闭 44、画质更宽），
            // 挤在一行里排会把「镜头 16」推离屏幕中心。
            shotChip

            HStack(spacing: SLSpacing.small) {
                Button { onClose() } label: {
                    CameraCircleGlyph(name: "xmark")
                }
                .accessibilityLabel("关闭")

                Spacer(minLength: 0)

                Button { onOpenSettings() } label: {
                    settingsGlyph
                }
                .accessibilityLabel("拍摄设置")
                .accessibilityValue(state.settingsAccessibilityText ?? "")
            }
        }
        .padding(.horizontal, SLSpacing.medium)
        .padding(.top, SLSpacing.small)
    }

    private var shotChip: some View {
        VStack(spacing: 0) {
            Text("镜头 \(state.shotNumber)")
                .font(.subheadline.weight(.semibold))
            // 已存条数：叠层图标 + 数字，不写「已拍 N 条」
            if state.savedTakeCount > 0 {
                IconValue(systemImage: "square.stack.3d.up.fill", text: "\(state.savedTakeCount)")
                    .font(.caption2)
                    .opacity(0.85)
            }
        }
        .padding(.horizontal, SLSpacing.medium)
        .padding(.vertical, SLSpacing.small)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            state.savedTakeCount > 0
            ? "镜头 \(state.shotNumber)，已拍 \(state.savedTakeCount) 条"
            : "镜头 \(state.shotNumber)"
        )
    }

    private var settingsGlyph: some View {
        HStack(spacing: SLSpacing.tiny) {
            Image(systemName: "slider.horizontal.3")
            if let settingsText = state.settingsText {
                Text(settingsText)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, SLSpacing.small + 2)
        .frame(minHeight: SLSize.minTouchTarget)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - 分镜描述

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: SLSpacing.small) {
            noteHeader
            noteBody
        }
        .padding(SLSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { cardBackground.fill(.ultraThinMaterial) }
        .overlay { cardBackground.strokeBorder(.white.opacity(0.12)) }
        .contentShape(cardBackground)
        .onTapGesture {
            // 展开时才可点：展开后卡片里有滚动视图，再让整张卡片响应点击会跟滚动打架
            guard !isNoteExpanded else { return }
            onToggleNote()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("描述")
        .accessibilityValue(state.hasNote ? state.note : "无")
        .accessibilityHint(isNoteExpanded ? "收起" : "展开")
    }

    private var cardBackground: RoundedRectangle {
        RoundedRectangle(cornerRadius: SLSize.cardCornerRadius, style: .continuous)
    }

    private var noteHeader: some View {
        HStack(spacing: SLSpacing.small) {
            // 图标即标签，名称留给读屏
            Image(systemName: "text.alignleft")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
                .accessibilityHidden(true)

            Spacer(minLength: 0)

            noteHeaderAccessory
        }
    }

    @ViewBuilder
    private var noteHeaderAccessory: some View {
        if isNoteExpanded {
            Button { onToggleNote() } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(minWidth: SLSize.minTouchTarget, minHeight: SLSpacing.large)
            }
            .accessibilityLabel("收起")
        } else if state.hasNote {
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var noteBody: some View {
        if state.hasNote {
            if isNoteExpanded {
                // 高度跟着内容走、到了上限才滚动：`ScrollView` 会占满给它的高度，
                // 直接 `.frame(maxHeight:)` 会让短描述也撑出一个空荡荡的大卡片。
                ScrollView {
                    noteText
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            noteContentHeight = height
                        }
                }
                .frame(height: min(max(noteContentHeight, 1), expandedNoteMaxHeight))
                .scrollBounceBehavior(.basedOnSize)
            } else {
                noteText
                    .lineLimit(3)
            }
        } else {
            emptyNote
        }
    }

    /// 描述还没写时的占位：虚线的含义全应用统一——这里还没有内容，不再另写一句话。
    private var emptyNote: some View {
        NotePlaceholder(width: 96)
            .frame(minHeight: SLSpacing.large, alignment: .leading)
    }

    private var noteText: some View {
        Text(state.note)
            .font(.callout)
            .lineSpacing(3)
            .multilineTextAlignment(.leading)
    }

    // MARK: - 焦距

    @ViewBuilder
    private var zoomPills: some View {
        if state.zoomScale.isZoomable {
            HStack(spacing: SLSpacing.small) {
                ForEach(state.zoomScale.stops(current: state.zoomFactor)) { stop in
                    zoomPill(stop)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: state.zoomFactor)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("焦距")
        }
    }

    private func zoomPill(_ stop: ZoomStop) -> some View {
        // 当前这一档就是倍率与它相等的那个：双指缩放时 stops(current:) 会拿当前倍率
        // 顶替最接近的档位，所以「被顶替的那一格」也会自然成为选中的那一格。
        let isCurrent = abs(stop.factor - state.zoomFactor) < 0.001

        return Button {
            onSelectZoom(stop.factor)
        } label: {
            Text(stop.text)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(isCurrent ? Color.black : Color.white)
                .frame(minWidth: 56, minHeight: SLSize.minTouchTarget)
                .background {
                    Capsule()
                        .fill(isCurrent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.black.opacity(0.35)))
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("焦距 \(stop.text)")
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    // MARK: - 对焦锁定

    private var focusLockChip: some View {
        Button { onUnlockFocus() } label: {
            Label("AE/AF 锁定", systemImage: "lock.fill")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, SLSpacing.medium)
                .frame(minHeight: SLSize.minTouchTarget)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("解锁")
    }

    // MARK: - 录制

    private var recordingIndicator: some View {
        HStack(spacing: SLSpacing.small) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .opacity(isBlinking && !reduceMotion ? 0.25 : 1)
            Text(Self.timeText(state.elapsed))
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, SLSpacing.medium)
        .padding(.vertical, SLSpacing.small)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在拍摄")
        .accessibilityValue(Self.timeText(state.elapsed))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                isBlinking = true
            }
        }
        .onDisappear { isBlinking = false }
    }

    private var bottomControls: some View {
        HStack {
            Button { onToggleTorch() } label: {
                CameraCircleGlyph(name: state.isTorchOn ? "bolt.fill" : "bolt.slash.fill")
            }
            .disabled(!state.isTorchAvailable)
            .opacity(state.isTorchAvailable ? 1 : 0.35)
            .accessibilityLabel(state.isTorchOn ? "关闭补光灯" : "打开补光灯")

            Spacer(minLength: 0)

            recordButton

            Spacer(minLength: 0)

            Button { onSwitchCamera() } label: {
                CameraCircleGlyph(name: "arrow.triangle.2.circlepath.camera.fill")
            }
            .disabled(state.isRecording)
            .opacity(state.isRecording ? 0.35 : 1)
            .accessibilityLabel("切换摄像头")
        }
        .padding(.horizontal, SLSpacing.huge)
        .padding(.top, SLSpacing.large)
        .padding(.bottom, SLSpacing.large)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
    }

    private var recordButton: some View {
        Button {
            onToggleRecording()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 5)
                    .frame(width: SLSize.recordButton, height: SLSize.recordButton)
                RoundedRectangle(cornerRadius: state.isRecording ? 6 : 28, style: .continuous)
                    .fill(.red)
                    .frame(
                        width: state.isRecording ? 32 : SLSize.recordButton - 18,
                        height: state.isRecording ? 32 : SLSize.recordButton - 18
                    )
            }
            .frame(width: SLSize.recordButton, height: SLSize.recordButton)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(state.isSaving)
        .accessibilityLabel(state.isRecording ? "停止" : "拍摄")
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: state.isRecording)
    }

    static func timeText(_ elapsed: TimeInterval) -> String {
        let total = Int(elapsed.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// 对焦框：点按取景画面后出现在手指点的位置。
///
/// 锁定后不淡出，并在框里挂一把锁——「我按住的那个点还锁着」这件事得看得见。
struct FocusReticle: View {
    let state: FocusReticleState
    /// 显示屏尺寸，用来把归一化位置换算成屏幕坐标
    let containerSize: CGSize

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let size: CGFloat = 76

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(state.isLocked ? Color.yellow : Color.white, lineWidth: state.isLocked ? 2 : 1.5)
            .frame(width: size, height: size)
            .overlay {
                if state.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 2)
            .position(state.position(in: containerSize, edgeInset: size / 2 + SLSpacing.small))
            .transition(reduceMotion ? .opacity : .scale(scale: 1.25).combined(with: .opacity))
            .accessibilityHidden(true)
    }
}
