import AVFoundation
import Combine
import UIKit

/// 相机录制控制器（AVFoundation）。
///
/// - 会话配置、切换摄像头等重活放在独立串行队列，避免阻塞主线程；
/// - `@Published` 属性的更新统一回到主线程；
/// - 没有可用摄像头时（例如 iOS 模拟器）进入 `.unavailable` 状态，
///   由界面给出「改用相册导入」的降级路径，而不是直接报错。
final class CameraRecorder: NSObject, ObservableObject {

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

    // MARK: - 对外状态

    @Published private(set) var status: Status = .idle
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var position: AVCaptureDevice.Position = .back
    @Published private(set) var isTorchAvailable = false
    @Published private(set) var isTorchOn = false

    let session = AVCaptureSession()

    // MARK: - 内部

    private let sessionQueue = DispatchQueue(label: "com.max.ShotList.camera.session")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var timer: Timer?
    private var recordingStart: Date?
    private var completion: ((Result<URL, Error>) -> Void)?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AnyObject?
    private var previewAngleObservation: NSKeyValueObservation?
    private var captureAngleObservation: NSKeyValueObservation?

    /// 单个镜头最长录制时长
    private let maximumDuration: TimeInterval = 600
    private static let maximumFileSize: Int64 = 600 * 1024 * 1024
    private static let maximumDurationSeconds: Double = 600

    // MARK: - 生命周期

    func start() {
        guard status == .idle || status.isUnavailable else { return }
        status = .configuring
        observeInterruptions()

        sessionQueue.async { [weak self] in
            guard let self else { return }
            switch self.configureIfNeeded() {
            case .success:
                self.configureAudioSession()
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async {
                    self.refreshCapabilities()
                    self.status = .ready
                    self.updateRotation()
                }
            case .failure(let error):
                DispatchQueue.main.async { self.status = .unavailable(error.localizedDescription) }
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
            self.session.startRunning()
        }
    }

    func stop() {
        stopTimer()
        recordingStart = nil
        if movieOutput.isRecording { movieOutput.stopRecording() }
        stopObservingInterruptions()

        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.deactivateAudioSession()
        }

        DispatchQueue.main.async {
            if self.isRecording { self.isRecording = false }
            if self.isTorchOn { self.isTorchOn = false }
        }
    }

    // MARK: - 预览层

    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        layer.session = session
        layer.videoGravity = .resizeAspectFill
        updateRotation()
    }

    func detachPreviewLayer() {
        previewAngleObservation = nil
        captureAngleObservation = nil
        rotationCoordinator = nil
        previewLayer?.session = nil
        previewLayer = nil
    }

    // MARK: - 录制

    func startRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        guard status == .ready, !isRecording, !movieOutput.isRecording else { return }
        guard movieOutput.connection(with: .video) != nil else { return }

        self.completion = completion
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shot-\(UUID().uuidString).mov", isDirectory: false)

        isRecording = true
        startTimer()
        Haptics.impact(.medium)
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    func stopRecording() {
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
    }

    // MARK: - 摄像头切换 / 补光

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

            DispatchQueue.main.async {
                guard self.videoInput?.device.position == target else { return }
                self.position = target
                self.refreshCapabilities()
                self.updateRotation()
                Haptics.selection()
            }
        }
    }

    func toggleTorch() {
        guard let device = videoInput?.device, device.hasTorch else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try device.lockForConfiguration()
                device.torchMode = device.torchMode == .on ? .off : .on
                let isOn = device.torchMode == .on
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.isTorchOn = isOn }
            } catch {
                // 补光不可用时静默忽略，录制本身不受影响
            }
        }
    }

    // MARK: - 会话配置

    private func configureIfNeeded() -> Result<Void, Error> {
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

    private func updateRotation() {
        previewAngleObservation = nil
        captureAngleObservation = nil
        rotationCoordinator = nil

        guard let layer = previewLayer, let device = videoInput?.device else { return }

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotationCoordinator = coordinator

        previewAngleObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak layer] _, change in
            guard let angle = change.newValue else { return }
            DispatchQueue.main.async {
                layer?.connection?.videoRotationAngle = angle
            }
        }

        captureAngleObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.initial, .new]
        ) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            DispatchQueue.main.async {
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

    private func startTimer() {
        stopTimer()
        recordingStart = Date()
        elapsed = 0

        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStart else { return }
            self.elapsed = Date().timeIntervalSince(start)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func refreshCapabilities() {
        let device = videoInput?.device
        isTorchAvailable = device?.hasTorch == true && device?.isTorchAvailable == true
        isTorchOn = device?.torchMode == .on
    }

    // MARK: - 中断处理

    private func observeInterruptions() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sessionWasInterrupted), name: .AVCaptureSessionWasInterrupted, object: session)
        center.addObserver(self, selector: #selector(sessionInterruptionEnded), name: .AVCaptureSessionInterruptionEnded, object: session)
        center.addObserver(self, selector: #selector(sessionRuntimeError), name: .AVCaptureSessionRuntimeError, object: session)
    }

    private func stopObservingInterruptions() {
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionWasInterrupted, object: session)
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionInterruptionEnded, object: session)
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionRuntimeError, object: session)
    }

    /// 来电、闹钟等打断时先把已拍的内容保存下来
    @objc private func sessionWasInterrupted(_ notification: Notification) {
        if movieOutput.isRecording { stopRecording() }
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        if movieOutput.isRecording { stopRecording() }
        DispatchQueue.main.async {
            self.status = .unavailable("相机被系统中断，请关闭后重新打开。")
        }
    }
}

// MARK: - 录制回调

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        DispatchQueue.main.async { self.isRecording = true }
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

        DispatchQueue.main.async {
            self.isRecording = false
            self.stopTimer()
            self.recordingStart = nil
            self.elapsed = 0
            let handler = self.completion
            self.completion = nil
            handler?(result)
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
private enum AVFileOutputErrorUserInfoKey {
    static let recordingSuccessfullyFinished = "AVErrorRecordingSuccessfullyFinishedKey"
}
