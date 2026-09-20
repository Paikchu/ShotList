import AVFoundation
import AVKit
import SwiftUI

/// 应用内相机，直接为某个分镜录制视频。
///
/// 权限在用户点开相机时才申请，并且先给出自定义说明再触发系统弹窗。
/// 没有摄像头时（例如 iOS 模拟器）给出「改用相册导入」的降级路径。
///
/// 取景页上除了录制本身，还要能看见这一条要拍什么（分镜描述），
/// 并把取景控制交到手上：点按对焦、长按锁定、双指调焦距、设置里选分辨率与帧率。
/// 界面外壳在 `CameraChrome`，这一层负责相机状态与手势的接线。
struct CameraCaptureView: View {
    let shot: Shot
    /// 请求改用相册导入（由父视图负责关掉相机并拉起相册）
    var onRequestImport: () -> Void

    @EnvironmentObject private var store: ShotStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    @StateObject private var recorder = CameraRecorder()

    @State private var authorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var showsPrePermission = false

    @State private var reviewURL: URL?
    @State private var reviewPlayer: AVPlayer?
    /// 回看期间在后台切音频、解析时长的两条在途任务。
    ///
    /// 都要能被「重拍」和关页面取消：切完音频才开始播，而页面可能在这中间就没了。
    @State private var playbackTask: Task<Void, Never>?
    @State private var durationTask: Task<TimeInterval?, Never>?
    @State private var isSaving = false
    @State private var isVisible = false
    @State private var errorMessage: String?
    /// 这一条是撞上体积/时长上限自动停止的，需要在回看页告诉用户
    @State private var reachedRecordingLimit = false

    // MARK: - 取景控制状态

    @State private var focusReticle: FocusReticleState?
    @State private var lastFocusPoint: PreviewFocusPoint?
    @State private var reticleTask: Task<Void, Never>?
    @State private var pinchStartZoom: CGFloat?
    @State private var isNoteExpanded = false
    @State private var isShowingSettings = false

    /// 这个镜头已经存了几条
    private var savedTakeCount: Int {
        store.shot(withID: shot.id)?.clipCount ?? 0
    }

    /// 正在回看的这一条会存成第几条
    private var reviewTakeIndex: Int { savedTakeCount + 1 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isSaving)
        .onAppear { isVisible = true }
        .task { await bootstrap() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // 用户可能刚去「设置」里改了摄像头权限，回到前台重新读一次，
                // 免得界面还停在「权限已关闭」，非要关掉相机重进
                refreshAuthorization()
            default:
                // 切到后台、来电等场景先把已经拍到的部分保存下来
                if recorder.isRecording { recorder.stopRecording() }
            }
        }
        .onChange(of: recorder.settingsError) { _, message in
            guard let message else { return }
            recorder.settingsError = nil
            errorMessage = message
        }
        .onDisappear {
            isVisible = false
            reticleTask?.cancel()
            cancelReviewTasks()
            // `stop()` 会摘掉录制回调：正在录的那一条就此作废，收尾回调会把
            // 临时文件删掉，不会再回到这个已经消失的页面上执行「进入回看」
            // （那会把音频会话切成播放模式，而归还焦点的代码早就跑完了）。
            recorder.stop()
            recorder.detachPreviewLayer()
            reviewPlayer?.pause()
            reviewPlayer = nil

            // 回看到一半直接把页面关掉（下拉关闭 / 被父视图收走）时，
            // 这条还没保存的临时片段也要一起回收
            if !isSaving, let url = reviewURL {
                try? FileManager.default.removeItem(at: url)
                reviewURL = nil
            }
        }
        .alert("拍摄出现问题", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("已达录制上限", isPresented: $reachedRecordingLimit) {
            Button("好", role: .cancel) {}
        } message: {
            Text("这段已保存，可以回看或重拍。")
        }
        .sheet(isPresented: $isShowingSettings) { settingsSheet }
    }

    // MARK: - 分支内容

    @ViewBuilder
    private var content: some View {
        if let reviewURL {
            reviewScreen(url: reviewURL)
        } else if authorization == .denied || authorization == .restricted {
            permissionDeniedScreen
        } else if showsPrePermission {
            prePermissionScreen
        } else {
            switch recorder.status {
            case .ready:
                captureScreen
            case .unavailable(let message):
                unavailableScreen(message: message)
            case .idle, .configuring:
                loadingScreen
            }
        }
    }

    // MARK: - 拍摄

    private var captureScreen: some View {
        ZStack {
            // 取景画面与对焦框同处一层并一起铺满整屏：对焦框的位置是按取景视图量的
            // 归一化坐标，两层必须落在同一块画布上，否则手指点中间、框画到别处。
            ZStack {
                CameraPreview(recorder: recorder, onFocus: handleFocus, onPinch: handlePinch)

                if let focusReticle {
                    GeometryReader { proxy in
                        FocusReticle(state: focusReticle, containerSize: proxy.size)
                    }
                    .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()

            CameraChrome(
                state: chromeState,
                isNoteExpanded: $isNoteExpanded,
                onClose: { dismiss() },
                onToggleNote: { isNoteExpanded.toggle() },
                onOpenSettings: { isShowingSettings = true },
                onToggleTorch: { recorder.toggleTorch() },
                onToggleRecording: { toggleRecording() },
                onSwitchCamera: { recorder.switchCamera() },
                onSelectZoom: { recorder.setZoom($0, ramped: true) },
                onUnlockFocus: { unlockFocus() }
            )
        }
    }

    private var chromeState: CameraChromeState {
        CameraChromeState(
            shotNumber: shot.paddedNumber,
            note: shot.note,
            savedTakeCount: savedTakeCount,
            isRecording: recorder.isRecording,
            elapsed: recorder.elapsed,
            isTorchOn: recorder.isTorchOn,
            isTorchAvailable: recorder.isTorchAvailable,
            isSaving: isSaving,
            zoomScale: recorder.zoomScale,
            zoomFactor: recorder.zoomFactor,
            settingsText: CaptureSettingsText.compactSummary(
                resolution: recorder.resolution,
                frameRate: recorder.frameRate
            ),
            settingsAccessibilityText: CaptureSettingsText.summary(
                resolution: recorder.resolution,
                frameRate: recorder.frameRate
            ),
            isFocusLocked: recorder.isFocusLocked
        )
    }

    // MARK: - 取景控制

    /// 点按对焦，长按锁定对焦与曝光。
    private func handleFocus(_ point: PreviewFocusPoint, lock: Bool) {
        recorder.focus(atDevicePoint: point.devicePoint, lock: lock)
        lastFocusPoint = point
        Haptics.impact(lock ? .medium : .light)
        showReticle(FocusReticleState(normalizedPoint: point.normalizedPoint, isLocked: lock))
    }

    private func unlockFocus() {
        let devicePoint = lastFocusPoint?.devicePoint ?? CGPoint(x: 0.5, y: 0.5)
        recorder.focus(atDevicePoint: devicePoint, lock: false)
        showReticle(
            FocusReticleState(
                normalizedPoint: lastFocusPoint?.normalizedPoint ?? CGPoint(x: 0.5, y: 0.5),
                isLocked: false
            )
        )
    }

    /// 双指缩放：跟手走，松手时吸到最近的档位。
    private func handlePinch(scale: CGFloat, state: UIGestureRecognizer.State) {
        switch state {
        case .began:
            pinchStartZoom = recorder.zoomFactor
        case .changed:
            guard let start = pinchStartZoom else { return }
            recorder.setZoom(recorder.zoomScale.clamped(start * scale), ramped: false)
        default:
            pinchStartZoom = nil
            if let stop = recorder.zoomScale.stopToSnap(to: recorder.zoomFactor) {
                recorder.setZoom(stop.factor, ramped: false)
            }
        }
    }

    private func showReticle(_ state: FocusReticleState) {
        reticleTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            focusReticle = state
        }

        // 锁定状态留着，让「我按住的那个点还锁着」一直看得见；普通对焦过一会儿自己淡出
        guard !state.isLocked else { return }
        reticleTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
                focusReticle = nil
            }
        }
    }

    // MARK: - 设置

    private var settingsSheet: some View {
        let selected = recorder.resolution ?? recorder.formatCatalog.resolutions.first

        return CameraSettingsSheet(
            availableResolutions: recorder.formatCatalog.resolutions,
            availableFrameRates: selected.map { recorder.formatCatalog.frameRates(for: $0) } ?? [],
            resolution: recorder.resolution,
            frameRate: recorder.frameRate,
            isRecording: recorder.isRecording,
            onSelectResolution: { resolution in
                // 换分辨率时帧率可能不再可用（4K 多数只到 30），跟着退到最接近的一档，
                // 而不是让用户自己再发现一次「60 fps 变灰了」
                let frameRate = CaptureFrameRate.closest(
                    to: recorder.frameRate ?? .preferred,
                    among: recorder.formatCatalog.frameRates(for: resolution)
                ) ?? .preferred
                recorder.applyCaptureSettings(resolution: resolution, frameRate: frameRate)
            },
            onSelectFrameRate: { frameRate in
                guard let resolution = selected else { return }
                recorder.applyCaptureSettings(resolution: resolution, frameRate: frameRate)
            },
            onDismiss: { isShowingSettings = false }
        )
        // 整屏呈现：六个档位加上说明在半屏里放不下，截断在「帧率」中间反而像坏了
        .presentationDetents([.large])
    }

    // MARK: - 回看

    private func reviewScreen(url: URL) -> some View {
        VStack(spacing: SLSpacing.medium) {
            HStack {
                Button("重拍") { retake() }
                    .disabled(isSaving)
                    .frame(minHeight: SLSize.minTouchTarget)
                Spacer()
                Text("回看第 \(reviewTakeIndex) 条")
                    .font(.headline)
                Spacer()
                Button("使用这条") { save(url, continuing: false) }
                    .fontWeight(.semibold)
                    .frame(minHeight: SLSize.minTouchTarget)
                    .disabled(isSaving)
            }
            .padding(.horizontal, SLSpacing.medium)
            .padding(.top, SLSpacing.small)

            ZStack {
                if let reviewPlayer {
                    VideoPlayer(player: reviewPlayer)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, SLSpacing.medium)
            .overlay {
                if isSaving {
                    ZStack {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(.black.opacity(0.45))
                        VStack(spacing: SLSpacing.small) {
                            ProgressView().tint(.white)
                            Text("正在保存到分镜…")
                                .font(.subheadline)
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, SLSpacing.medium)
                    .accessibilityElement(children: .combine)
                }
            }

            VStack(spacing: SLSpacing.small) {
                Button {
                    save(url, continuing: true)
                } label: {
                    Label("保存并继续拍下一条", systemImage: "arrow.triangle.2.circlepath.camera")
                        .frame(maxWidth: .infinity, minHeight: SLSize.minTouchTarget)
                }
                .buttonStyle(.bordered)
                .disabled(isSaving)
                .accessibilityHint("这段会存成第 \(reviewTakeIndex) 条，然后回到取景继续拍同一个镜头")
            }
            .padding(.horizontal, SLSpacing.medium)
            .padding(.bottom, SLSpacing.large)
        }
        .foregroundStyle(.white)
    }

    // MARK: - 权限与降级

    private var prePermissionScreen: some View {
        messageScreen(
            symbol: "camera.fill",
            symbolTint: Color.accentColor,
            title: "需要摄像头权限",
            message: "分镜助手只会用摄像头录制你的分镜视频。视频保存在这台 iPhone 上，不会上传到任何地方。",
            primaryTitle: "允许使用摄像头",
            primaryAction: { requestAccess() },
            showsImport: true
        )
    }

    private var permissionDeniedScreen: some View {
        messageScreen(
            symbol: "camera.badge.ellipsis",
            symbolTint: .orange,
            title: "摄像头权限已关闭",
            message: "要使用相机拍摄，请到「设置」里允许分镜助手访问摄像头。你也可以先用相册里的视频完成这个分镜。",
            primaryTitle: "前往设置",
            primaryAction: {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            },
            showsImport: true
        )
    }

    private func unavailableScreen(message: String) -> some View {
        messageScreen(
            symbol: "video.slash",
            symbolTint: .secondary,
            title: "无法使用相机",
            message: message,
            primaryTitle: "从相册导入",
            primaryAction: { requestImport() },
            showsImport: false
        )
    }

    private var loadingScreen: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    CameraCircleGlyph(name: "xmark")
                }
                .accessibilityLabel("关闭相机")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SLSpacing.medium)
            .padding(.top, SLSpacing.small)

            Spacer()

            VStack(spacing: SLSpacing.medium) {
                ProgressView().tint(.white)
                Text("正在启动相机…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .foregroundStyle(.white)
    }

    private func messageScreen(
        symbol: String,
        symbolTint: Color,
        title: String,
        message: String,
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        showsImport: Bool
    ) -> some View {
        VStack(spacing: SLSpacing.large) {
            Image(systemName: symbol)
                .font(.system(size: 52))
                .foregroundStyle(symbolTint)

            VStack(spacing: SLSpacing.small) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)

            VStack(spacing: SLSpacing.small) {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, minHeight: SLSize.minTouchTarget)

                if showsImport {
                    Button("从相册导入") { requestImport() }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, minHeight: SLSize.minTouchTarget)
                }

                Button("暂不拍摄") { dismiss() }
                    .foregroundStyle(.secondary)
                    .frame(minHeight: SLSize.minTouchTarget)
            }
        }
        .padding(SLSpacing.large)
    }

    // MARK: - 动作

    private func bootstrap() async {
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        switch authorization {
        case .authorized:
            recorder.start()
        case .notDetermined:
            showsPrePermission = true
        default:
            break
        }
    }

    /// 回到前台时重新读一次权限，并把界面切到对应分支。
    ///
    /// `authorization` 是 `@State`，只在首次进入与用户点了授权按钮时更新；
    /// 用户去系统设置里改完权限再切回来，不重读就会一直停在旧状态。
    private func refreshAuthorization() {
        let current = AVCaptureDevice.authorizationStatus(for: .video)
        guard current != authorization else { return }

        authorization = current
        switch current {
        case .authorized:
            showsPrePermission = false
            recorder.start()
        case .notDetermined:
            showsPrePermission = true
        default:
            break
        }
    }

    private func requestAccess() {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authorization = granted ? .authorized : .denied
            showsPrePermission = false
            if granted { recorder.start() }
        }
    }

    private func requestImport() {
        recorder.stop()
        onRequestImport()
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stopRecording()
        } else {
            recorder.startRecording { result in
                switch result {
                case .success(let output):
                    enterReview(output.url)
                    if output.stopReason == .reachedLimit {
                        reachedRecordingLimit = true
                    }
                case .failure(let error):
                    Haptics.error()
                    errorMessage = "录制没有完成：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 进入回看。
    ///
    /// 这一步刻意不做任何会阻塞主线程的事。切音频会话是同步的系统调用，原先就写在这里，
    /// 于是它有多慢、用户在「停止」之后就要多等多久；现在先把回看界面和播放器立起来，
    /// 音频交给 `CameraRecorder.activatePlaybackAudioSession` 在后台切，切完再开始播。
    /// 画面的第一帧不用等音频。
    ///
    /// 时长解析也提前到这里：用户正在看回放，这段时间足够把它算完，
    /// 点「保存」时就不必再等一次 `AVURLAsset` 加载。
    ///
    /// 切音频与暂停会话的先后顺序保持不变（音频在前）：两件事都排在 recorder 的
    /// 同一条串行队列上，顺序由这里的调用顺序决定。
    private func enterReview(_ url: URL) {
        cancelReviewTasks()

        reviewURL = url
        let player = AVPlayer(url: url)
        reviewPlayer = player
        Haptics.success()

        durationTask = Task { await VideoMetadata.duration(of: url) }
        playbackTask = Task {
            await recorder.activatePlaybackAudioSession()
            // 切音频的这段时间里可能已经重拍或把页面关掉了，那时这个播放器已经不是当前这一个
            guard !Task.isCancelled, reviewPlayer === player else { return }
            player.play()
        }

        recorder.pauseSession()
    }

    /// 取消回看期间的在途任务。重拍、关页面、以及进入下一次回看之前都要收干净。
    private func cancelReviewTasks() {
        playbackTask?.cancel()
        playbackTask = nil
        durationTask?.cancel()
        durationTask = nil
    }

    /// 取回看这一条的时长。
    ///
    /// 正常走 `enterReview` 里那条已经跑完（或快跑完）的后台任务；任务被取消过时
    /// 当场再解析一次，保证时长不会因为这条优化而丢掉。
    private func resolvedDuration(of url: URL) async -> TimeInterval? {
        guard let task = durationTask else { return await VideoMetadata.duration(of: url) }
        durationTask = nil
        return await task.value
    }

    private func retake() {
        guard !isSaving else { return }
        cancelReviewTasks()
        reviewPlayer?.pause()
        reviewPlayer = nil
        if let reviewURL {
            try? FileManager.default.removeItem(at: reviewURL)
        }
        reviewURL = nil
        recorder.resumeSession()
        Haptics.impact(.light)
    }

    /// 把回看的这一条存进分镜。
    ///
    /// - Parameter continuing: `true` 表示存完不关相机，回到取景继续拍同一个镜头。
    private func save(_ url: URL, continuing: Bool) {
        guard !isSaving else { return }
        isSaving = true

        Task {
            defer {
                isSaving = false
                if !isVisible {
                    try? FileManager.default.removeItem(at: url)
                    reviewURL = nil
                }
            }
            let duration = await resolvedDuration(of: url)
            do {
                try await store.addClip(from: url, duration: duration, to: shot.id)
                reviewPlayer?.pause()
                reviewPlayer = nil
                reviewURL = nil
                isSaving = false
                Haptics.success()

                guard isVisible else { return }
                if continuing {
                    recorder.resumeSession()
                } else {
                    recorder.stop()
                    dismiss()
                }
            } catch {
                guard isVisible else { return }
                Haptics.error()
                errorMessage = "没能保存这段视频：\(error.localizedDescription)"
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { presented in if !presented { errorMessage = nil } }
        )
    }
}

#Preview {
    CameraCaptureView(
        shot: Shot(number: 16, note: "手冲壶出水特写，收环境音；壶嘴贴住杯口，水线细一点，别让蒸汽糊住镜头。"),
        onRequestImport: {}
    )
    .environmentObject(ShotStore())
}
