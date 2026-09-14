import AVFoundation
import AVKit
import SwiftUI

/// 应用内相机，直接为某个分镜录制视频。
///
/// 权限在用户点开相机时才申请，并且先给出自定义说明再触发系统弹窗。
/// 没有摄像头时（例如 iOS 模拟器）给出「改用相册导入」的降级路径。
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
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isBlinking = false

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
        .task { await bootstrap() }
        .onChange(of: scenePhase) { _, phase in
            // 切到后台、来电等场景先把已经拍到的部分保存下来
            if phase != .active, recorder.isRecording { recorder.stopRecording() }
        }
        .onDisappear {
            recorder.stop()
            recorder.detachPreviewLayer()
            reviewPlayer?.pause()
            reviewPlayer = nil
        }
        .alert("拍摄出现问题", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
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
            CameraPreview(recorder: recorder)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if recorder.isRecording {
                    recordingIndicator
                        .padding(.bottom, SLSpacing.medium)
                }
                bottomControls
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: SLSpacing.small) {
            Button {
                dismiss()
            } label: {
                cameraCircleGlyph("xmark")
            }
            .accessibilityLabel("关闭相机")

            Spacer(minLength: 0)

            VStack(spacing: 0) {
                Text("镜头 \(shot.paddedNumber)")
                    .font(.subheadline.weight(.semibold))
                if shot.hasNote {
                    Text(shot.note)
                        .font(.caption2)
                        .opacity(0.85)
                        .lineLimit(1)
                } else if savedTakeCount > 0 {
                    Text("已拍 \(savedTakeCount) 条")
                        .font(.caption2)
                        .opacity(0.85)
                }
            }
            .padding(.horizontal, SLSpacing.medium)
            .padding(.vertical, SLSpacing.small)
            .background(.ultraThinMaterial, in: Capsule())

            Spacer(minLength: 0)

            Color.clear.frame(width: SLSize.minTouchTarget, height: SLSize.minTouchTarget)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, SLSpacing.medium)
        .padding(.top, SLSpacing.small)
    }

    private var bottomControls: some View {
        HStack {
            Button { recorder.toggleTorch() } label: {
                cameraCircleGlyph(recorder.isTorchOn ? "bolt.fill" : "bolt.slash.fill")
            }
            .disabled(!recorder.isTorchAvailable)
            .opacity(recorder.isTorchAvailable ? 1 : 0.35)
            .accessibilityLabel(recorder.isTorchOn ? "关闭补光" : "打开补光")

            Spacer(minLength: 0)

            recordButton

            Spacer(minLength: 0)

            Button { recorder.switchCamera() } label: {
                cameraCircleGlyph("arrow.triangle.2.circlepath.camera.fill")
            }
            .disabled(recorder.isRecording)
            .opacity(recorder.isRecording ? 0.35 : 1)
            .accessibilityLabel("切换前后摄像头")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, SLSpacing.huge)
        .padding(.top, SLSpacing.large)
        .padding(.bottom, SLSpacing.large)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
    }

    private func cameraCircleGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.headline)
            .frame(width: SLSize.minTouchTarget, height: SLSize.minTouchTarget)
            .background(.ultraThinMaterial, in: Circle())
    }

    private var recordButton: some View {
        Button {
            toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 5)
                    .frame(width: SLSize.recordButton, height: SLSize.recordButton)
                RoundedRectangle(cornerRadius: recorder.isRecording ? 6 : 28, style: .continuous)
                    .fill(.red)
                    .frame(
                        width: recorder.isRecording ? 32 : SLSize.recordButton - 18,
                        height: recorder.isRecording ? 32 : SLSize.recordButton - 18
                    )
            }
            .frame(width: SLSize.recordButton, height: SLSize.recordButton)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityLabel(recorder.isRecording ? "停止拍摄" : "开始拍摄")
        .accessibilityHint("拍完可以回看，确认后再保存。同一个镜头可以拍很多条，后拍的不会覆盖前面的。")
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: recorder.isRecording)
    }

    private var recordingIndicator: some View {
        HStack(spacing: SLSpacing.small) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .opacity(isBlinking && !reduceMotion ? 0.25 : 1)
            Text(Self.timeText(recorder.elapsed))
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, SLSpacing.medium)
        .padding(.vertical, SLSpacing.small)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在拍摄")
        .accessibilityValue(Self.timeText(recorder.elapsed))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                isBlinking = true
            }
        }
        .onDisappear { isBlinking = false }
    }

    // MARK: - 回看

    private func reviewScreen(url: URL) -> some View {
        VStack(spacing: SLSpacing.medium) {
            HStack {
                Button("重拍") { retake() }
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
        VStack {
            topBar
            Spacer()
            VStack(spacing: SLSpacing.medium) {
                ProgressView().tint(.white)
                Text("正在启动相机…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
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
                case .success(let url):
                    enterReview(url)
                case .failure(let error):
                    Haptics.error()
                    errorMessage = "录制没有完成：\(error.localizedDescription)"
                }
            }
        }
    }

    private func enterReview(_ url: URL) {
        recorder.pauseSession()

        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .moviePlayback)
        try? audioSession.setActive(true)

        reviewURL = url
        let player = AVPlayer(url: url)
        reviewPlayer = player
        player.play()
        Haptics.success()
    }

    private func retake() {
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
            let duration = await VideoMetadata.duration(of: url)
            do {
                try store.addClip(from: url, duration: duration, to: shot.id)
                reviewPlayer?.pause()
                reviewPlayer = nil
                reviewURL = nil
                isSaving = false
                Haptics.success()

                if continuing {
                    recorder.resumeSession()
                } else {
                    recorder.stop()
                    dismiss()
                }
            } catch {
                isSaving = false
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

    private static func timeText(_ elapsed: TimeInterval) -> String {
        let total = Int(elapsed.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

#Preview {
    CameraCaptureView(shot: Shot(number: 1, note: "无人机缓慢上升，配一句开场旁白"), onRequestImport: {})
        .environmentObject(ShotStore())
}
