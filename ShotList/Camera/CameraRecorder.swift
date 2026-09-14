import AVFoundation
import Combine
import UIKit

/// 只在主线程使用的非 Sendable 值，跨隔离域往主线程带时套的壳。
///
/// 「安全」由调用处负责：值从产生它的线程带过来之后只在主线程使用，
/// 中间隔着一次 dispatch，先后顺序由 GCD 保证。AVFoundation 里
/// `AVCaptureDevice`、`Error` 这类对象都不是 `Sendable`，而它们又必须从
/// 队列侧交到界面上，这是表达「我知道这次传递是安全的」最窄的方式——
/// 比给整个类打开 `nonisolated(unsafe)` 要精确得多。
nonisolated struct MainOnly<T>: @unchecked Sendable {
    let value: T
}

/// 相机录制控制器（AVFoundation）。
///
/// ## 隔离约定
///
/// `AVCaptureSession.startRunning()` 是阻塞调用，不能放在主线程上，因此这个类
/// **刻意不落在主协程**，由它自己划分线程归属：
///
/// - **界面状态**（`status`、`isRecording`、`elapsed`、`position`、
///   `isTorchAvailable`、`isTorchOn`）显式标注 `@MainActor`，只有主线程能读写，
///   队列侧一律经 `onMain` 回来；
/// - **会话状态**（`session`、`movieOutput`、`videoInput`、`audioInput`、
///   `isConfigured`）只在 `sessionQueue` 上访问 —— 开录与停录也不例外，
///   这样它们与切摄像头、改旋转角度共享同一条串行队列，不会并发改连接；
/// - **录制回调**（`completion`）只在主线程读写，由 `onMain` 交回。
/// - **主线程资源**（`previewLayer`、旋转协调器、计时器）只在主线程访问。
///
/// 后两类由 `@unchecked Sendable` 兜住。之所以不拆成 actor：`AVCaptureSession`
/// 不是 `Sendable`，一旦关进 actor 就没法交给主线程上的
/// `AVCaptureVideoPreviewLayer` 显示预览。串行队列 + 上面的约定是这套框架的
/// 通行做法，因此这里显式声明并逐条落实，而不是让它隐式通过。
///
/// 没有可用摄像头时（例如 iOS 模拟器）进入 `.unavailable` 状态，
/// 由界面给出「改用相册导入」的降级路径，而不是直接报错。
nonisolated final class CameraRecorder: NSObject, ObservableObject, @unchecked Sendable {

    enum Status: Equatable {
        case idle
        case configuring
        case ready
        case unavailable(String)

        var isUnavailable: Bool {
            if case .unavailable = self { return true }
            return false
        }
    }

    // MARK: - 界面状态（主线程）

    @MainActor @Published private(set) var status: Status = .idle
    @MainActor @Published private(set) var isRecording = false
    @MainActor @Published private(set) var elapsed: TimeInterval = 0
    @MainActor @Published private(set) var position: AVCaptureDevice.Position = .back
    @MainActor @Published private(set) var isTorchAvailable = false
    @MainActor @Published private(set) var isTorchOn = false

    // MARK: - 会话状态（只在 sessionQueue 上访问）

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.max.ShotList.camera.session")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var recordingStart: Date?
    private var completion: (@MainActor (Result<URL, Error>) -> Void)?

    // MARK: - 主线程资源（只在主线程访问）

    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewAngleObservation: NSKeyValueObservation?
    private var captureAngleObservation: NSKeyValueObservation?
    private var timer: Timer?

    /// 单个镜头最长录制时长
    private static let maximumFileSize: Int64 = 600 * 1024 * 1024
    private static let maximumDurationSeconds: Double = 600

    // MARK: - 线程跳转

    /// 回到主线程更新界面状态。
    ///
    /// 用 `assumeIsolated` 而不是 `Task { @MainActor in }`：前者是同步的，
    /// 状态更新的顺序与入队顺序严格一致，不会被任务调度打乱。
    private func onMain(_ work: @MainActor @escaping @Sendable () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(work)
        }
    }

    // MARK: - 生命周期

    @MainActor
    func start() {
        guard status == .idle || status.isUnavailable else { return }
        status = .configuring
        observeInterruptions()

        // 当前使用哪颗摄像头属于界面状态，从主线程带到队列上
        let target = position
        sessionQueue.async { [weak self] in
            guard let self else { return }
            switch self.configureIfNeeded(position: target) {
            case .success:
                self.configureAudioSession()
                if !self.session.isRunning { self.session.startRunning() }
                self.onMain {
                    self.refreshCapabilities()
                    self.status = .ready
                    self.updateRotation()
                }
            case .failure(let error):
                // 错误对象不是 Sendable，在主线程那一侧只需要一句可读的说明
                let reason = error.localizedDescription
                self.onMain { self.status = .unavailable(reason) }
            }
        }
    }

    /// 进入回看等场景时暂停会话，节省电量
    func pauseSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func resumeSession() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            // 回看时音频会话被切成播放模式，回到取景前要切回录制模式，否则录不到声音
            self.configureAudioSession()
            self.session.startRunning()
        }
    }

    /// 关闭相机并收尾。
    ///
    /// 标 `@MainActor` 是因为它要碰计时器与 `recordingStart` 这两个主线程资源；
    /// 会话侧的收尾自己会跳 `sessionQueue`，因此标注不影响它的线程语义。
    @MainActor
    func stop() {
        stopTimer()
        recordingStart = nil
        stopObservingInterruptions()

        sessionQueue.async { [weak self] in
            guard let self else { return }
            // movieOutput 属于会话状态，收尾也留在 sessionQueue 上做
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
            self.deactivateAudioSession()
        }

        onMain {
            if self.isRecording { self.isRecording = false }
            if self.isTorchOn { self.isTorchOn = false }
        }
    }

    // MARK: - 预览层

    /// 预览层、旋转协调器与计时器都只在主线程访问，因此这几个方法统一标
    /// `@MainActor`——让签名（而不是类头的注释）来保证线程归属。
    @MainActor
    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        layer.session = session
        layer.videoGravity = .resizeAspectFill
        updateRotation()
    }

    @MainActor
    func detachPreviewLayer() {
        previewAngleObservation = nil
        captureAngleObservation = nil
        rotationCoordinator = nil
        previewLayer?.session = nil
        previewLayer = nil
    }

    // MARK: - 录制

    /// 开始录制。
    ///
    /// 界面状态（`status`、`isRecording`）在主线程判、在主线程置位，
    /// **会话状态一律交给 `sessionQueue`**：`movieOutput` 的归属地在那里，
    /// 与 `switchCamera` / `updateRotation` 对连接的修改排在同一条串行队列上，
    /// 不会并发抢同一个连接。
    ///
    /// `isRecording` 刻意留在主线程**同步**置位（而不是等队列确认后再回主线程），
    /// 否则连点两次录制按钮会在两次点击之间留下空档，同时启动两段录制。
    @MainActor
    func startRecording(completion: @MainActor @escaping (Result<URL, Error>) -> Void) {
        guard status == .ready, !isRecording else { return }

        self.completion = completion
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shot-\(UUID().uuidString).mov", isDirectory: false)

        isRecording = true
        startTimer()
        Haptics.impact(.medium)

        sessionQueue.async { [weak self] in
            guard let self else { return }
            // 会话侧确认能录。确认不了就把刚才乐观置位的界面状态回滚回去。
            guard !self.movieOutput.isRecording,
                  self.movieOutput.connection(with: .video) != nil else {
                self.onMain {
                    self.isRecording = false
                    self.stopTimer()
                    self.elapsed = 0
                    self.completion = nil
                }
                return
            }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self, self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
        }
    }

    // MARK: - 摄像头切换 / 补光

    @MainActor
    func switchCamera() {
        guard !isRecording, status == .ready else { return }
        let target: AVCaptureDevice.Position = position == .back ? .front : .back

        sessionQueue.async { [weak self] in
            guard let self, let device = Self.camera(position: target),
                  let newInput = try? AVCaptureDeviceInput(device: device) else { return }

            self.session.beginConfiguration()
            let previous = self.videoInput
            if let previous { self.session.removeInput(previous) }

            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoInput = newInput
            } else if let previous {
                self.session.addInput(previous)
            }
            self.session.commitConfiguration()

            let didSwitch = self.videoInput?.device.position == target
            self.onMain {
                guard didSwitch else { return }
                self.position = target
                self.refreshCapabilities()
                self.updateRotation()
                Haptics.selection()
            }
        }
    }

    func toggleTorch() {
        // 设备的读取也必须回到 sessionQueue，videoInput 的归属地在那里
        sessionQueue.async { [weak self] in
            guard let self,
                  let device = self.videoInput?.device,
                  device.hasTorch,
                  device.isTorchAvailable else { return }
            do {
                try device.lockForConfiguration()
                device.torchMode = device.torchMode == .on ? .off : .on
                let isOn = device.torchMode == .on
                device.unlockForConfiguration()
                self.onMain { self.isTorchOn = isOn }
            } catch {
                // 补光不可用时静默忽略，录制本身不受影响
            }
        }
    }

    // MARK: - 会话配置

    private func configureIfNeeded(position: AVCaptureDevice.Position) -> Result<Void, Error> {
        if isConfigured { return .success(()) }

        guard let device = Self.camera(position: position) else {
            return .failure(CameraError.noCameraAvailable)
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return .failure(CameraError.cannotAddInput) }
            session.addInput(input)
            videoInput = input
        } catch {
            return .failure(error)
        }

        guard session.canAddOutput(movieOutput) else { return .failure(CameraError.cannotAddOutput) }
        session.addOutput(movieOutput)

        movieOutput.maxRecordedDuration = CMTime(
            seconds: Self.maximumDurationSeconds,
            preferredTimescale: 600
        )
        movieOutput.maxRecordedFileSize = Self.maximumFileSize

        if let connection = movieOutput.connection(with: .video),
           connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .auto
        }

        // 麦克风属于加分项，取不到也不影响画面录制
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
            self.audioInput = audioInput
        }

        isConfigured = true
        return .success(())
    }

    private static func camera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInTripleCamera],
            mediaType: .video,
            position: position
        )
        if let device = discovery.devices.first { return device }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    // MARK: - 画面旋转

    /// 重新计算预览与录制画面的旋转角度。
    ///
    /// 设备对象在 sessionQueue 上取（那是它的归属地），协调器与预览层必须回到
    /// 主线程操作，因此中间隔着一次带壳的传递。
    @MainActor
    private func updateRotation() {
        previewAngleObservation = nil
        captureAngleObservation = nil
        rotationCoordinator = nil

        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            let boxed = MainOnly(value: device)
            self.onMain {
                guard let layer = self.previewLayer else { return }
                self.installRotation(device: boxed.value, layer: layer)
            }
        }
    }

    @MainActor
    private func installRotation(device: AVCaptureDevice, layer: AVCaptureVideoPreviewLayer) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotationCoordinator = coordinator

        previewAngleObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            self?.onMain {
                self?.previewLayer?.connection?.videoRotationAngle = angle
            }
        }

        captureAngleObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.initial, .new]
        ) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            // 录制的旋转角度属于会话配置，回到 sessionQueue 上设置
            self?.sessionQueue.async { [weak self] in
                guard let self,
                      let connection = self.movieOutput.connection(with: .video),
                      connection.isVideoRotationAngleSupported(angle) else { return }
                connection.videoRotationAngle = angle
            }
        }
    }

    // MARK: - 音频会话

    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
        try? audioSession.setActive(true, options: [])
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - 计时

    /// 计时器跑在主 runloop 上，因此这两个方法只在主线程调用。
    @MainActor
    private func startTimer() {
        stopTimer()
        recordingStart = Date()
        elapsed = 0

        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let start = self.recordingStart else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @MainActor
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// 补光能力取决于当前设备，读取在队列侧完成
    private func refreshCapabilities() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let device = self.videoInput?.device
            let isAvailable = device?.hasTorch == true && device?.isTorchAvailable == true
            let isOn = device?.torchMode == .on
            self.onMain {
                self.isTorchAvailable = isAvailable
                self.isTorchOn = isOn
            }
        }
    }

    // MARK: - 中断处理

    private func observeInterruptions() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sessionWasInterrupted), name: AVCaptureSession.wasInterruptedNotification, object: session)
        center.addObserver(self, selector: #selector(sessionInterruptionEnded), name: AVCaptureSession.interruptionEndedNotification, object: session)
        center.addObserver(self, selector: #selector(sessionRuntimeError), name: AVCaptureSession.runtimeErrorNotification, object: session)
    }

    private func stopObservingInterruptions() {
        NotificationCenter.default.removeObserver(self, name: AVCaptureSession.wasInterruptedNotification, object: session)
        NotificationCenter.default.removeObserver(self, name: AVCaptureSession.interruptionEndedNotification, object: session)
        NotificationCenter.default.removeObserver(self, name: AVCaptureSession.runtimeErrorNotification, object: session)
    }

    /// 来电、闹钟等打断时先把已拍的内容保存下来
    @objc private func sessionWasInterrupted(_ notification: Notification) {
        // 通知可能投递在任意线程上，这里不能直接读 movieOutput——
        // stopRecording() 自己会跳回 sessionQueue 并判断是否需要收尾
        stopRecording()
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        stopRecording()
        onMain {
            self.status = .unavailable("相机被系统中断，请关闭后重新打开。")
        }
    }
}

// MARK: - 录制回调

/// 必须显式标 `nonisolated`：默认主协程隔离下，extension 会自己落在主协程上，
/// 而录制回调是从 `sessionQueue` 上把 `self` 交给 AVFoundation 的，
/// 主协程隔离的一致性在这种上下文里用不了。
nonisolated extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        onMain { self.isRecording = true }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        // 达到时长或体积上限时 AVFoundation 会带 error 返回，但文件本身是完好的
        let finishedSuccessfully = (error as NSError?)?
            .userInfo[AVFileOutputErrorUserInfoKey.recordingSuccessfullyFinished] as? Bool ?? false

        let result: Result<URL, Error>
        if let error, !finishedSuccessfully {
            result = .failure(error)
        } else {
            result = .success(outputFileURL)
        }

        // `Error` 不是 Sendable，套壳带到主线程；随后只在主线程使用
        let boxed = MainOnly(value: result)
        onMain {
            self.isRecording = false
            self.stopTimer()
            self.recordingStart = nil
            self.elapsed = 0
            let handler = self.completion
            self.completion = nil
            handler?(boxed.value)
        }
    }
}

// MARK: - 错误

enum CameraError: LocalizedError {
    case noCameraAvailable
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noCameraAvailable:
            return "这台设备没有可用的摄像头。iOS 模拟器不提供摄像头，请改用「从相册导入」。"
        case .cannotAddInput:
            return "无法启用摄像头输入。"
        case .cannotAddOutput:
            return "无法启用视频录制输出。"
        }
    }
}

/// `AVFileOutputErrorUserInfoKey` 目前没有对应的 Swift 常量，这里显式声明。
///
/// 标 `nonisolated` 是必需的：录制回调在 `sessionQueue` 一侧读它，
/// 而默认主协程隔离下，文件级的静态属性本来归属主协程。
private nonisolated enum AVFileOutputErrorUserInfoKey {
    static let recordingSuccessfullyFinished = "AVErrorRecordingSuccessfullyFinishedKey"
}
