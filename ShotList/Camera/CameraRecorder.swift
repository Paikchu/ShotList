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

/// 一份设备格式，以及它在「分辨率 / 帧率」上的摘要。
///
/// 两者必须成对保存：同一个分辨率下常有多份格式（1080p 就有到 30 与到 60 两份），
/// 只按宽高去找会拿错那一份。
private nonisolated struct FormatEntry {
    let format: AVCaptureDevice.Format
    let descriptor: CaptureFormatDescriptor
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
/// - **录制回调**（`completion`）只在主线程读写，由 `onMain` 交回；
///   关相机时会被清空，收尾回调据此丢掉那段视频（连临时文件一起）。
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

    /// 一次成功的录制是怎么停下来的。
    ///
    /// `reachedLimit`：撞到本类自己设的体积或时长上限——素材完好、判定为成功，
    /// 但用户看到的只是「自己停了」，界面需要据此补一句说明。来电、切后台、
    /// 主动点停止都经同一个 `stopRecording()` 收尾，不带这两种 error code，
    /// 因此仍归为 `userRequested`，不会被误报成撞上限。
    enum StopReason: Equatable {
        case userRequested
        case reachedLimit
    }

    /// 一次录制成功结束时的产出：文件地址，以及它是怎么停下来的。
    struct RecordingOutput {
        let url: URL
        let stopReason: StopReason
    }

    // MARK: - 界面状态（主线程）

    @MainActor @Published private(set) var status: Status = .idle
    @MainActor @Published private(set) var isRecording = false
    @MainActor @Published private(set) var elapsed: TimeInterval = 0
    @MainActor @Published private(set) var position: AVCaptureDevice.Position = .back
    @MainActor @Published private(set) var isTorchAvailable = false
    @MainActor @Published private(set) var isTorchOn = false

    /// 当前焦距（原始 `videoZoomFactor`）与这台摄像头的档位表
    @MainActor @Published private(set) var zoomScale = ZoomScale()
    @MainActor @Published private(set) var zoomFactor: CGFloat = 1

    /// 对焦与曝光是否被长按锁住
    @MainActor @Published private(set) var isFocusLocked = false

    /// 这台摄像头支持的（分辨率、帧率）组合，以及当前实际生效的那一档
    @MainActor @Published private(set) var formatCatalog = CaptureFormatCatalog()
    @MainActor @Published private(set) var resolution: CaptureResolution?
    @MainActor @Published private(set) var frameRate: CaptureFrameRate?

    /// 改画质失败时的说明。只用来告诉用户「没改成」，不拦截录制。
    @MainActor @Published var settingsError: String?

    /// 上次选过的分辨率与帧率，进相机时沿用
    let preferences = CameraPreferences()

    // MARK: - 会话状态（只在 sessionQueue 上访问）

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.max.ShotList.camera.session")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var recordingStart: Date?

    /// 用户想要的画质，留在队列侧作为会话状态的一部分。
    ///
    /// 记的是**想要的**而不是实际生效的：前置摄像头多数没有 4K，切过去只能降到 1080p，
    /// 但这只是这台设备配不上，切回后摄时仍应回到 4K，不该把用户的选择改掉。
    private var desiredSettings: (resolution: CaptureResolution, frameRate: CaptureFrameRate)?

    // MARK: - 录制回调（只在主线程读写）

    /// 当前这一次录制的回调。
    ///
    /// `startRecording` 在主线程写入，收尾回调经 `onMain` 回来读它并清空，
    /// `stop()` 关相机时也由主线程清空——清空之后收尾回调不会再往一个已经
    /// 消失的页面上跑（那会把音频会话切成播放模式，还会留下一个没人回收的
    /// 临时文件，见 `stop()`）。
    private var completion: (@MainActor (Result<RecordingOutput, Error>) -> Void)?

    // MARK: - 主线程资源（只在主线程访问）

    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewAngleObservation: NSKeyValueObservation?
    private var captureAngleObservation: NSKeyValueObservation?
    private var zoomObservation: NSKeyValueObservation?
    private var timer: Timer?

    /// 体积、时长上限。
    ///
    /// `maximumFileSize` 是查不到设备实际码率时的兜底值，也是任何格式下的下限——
    /// 见 `updateMaximumFileSize`，它只会把上限往宽估，不会比这个值更严格。
    /// `maximumDurationSeconds` 是单个镜头最长录制时长。
    private static let maximumFileSize: Int64 = 600 * 1024 * 1024
    private static let maximumDurationSeconds: Double = 600

    /// 录制中的临时文件前缀。
    ///
    /// 创建（`startRecording`）与回收（`cleanUpTemporaryRecordings`）都按它认领，
    /// 写两遍就会出现「建得出来、清不掉」的孤儿文件。
    private static let temporaryFilePrefix = "shot-"

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

        // 当前使用哪颗摄像头、要录多大的画面都属于界面状态，从主线程带到队列上
        let target = position
        let preferred = (
            resolution: preferences.resolution ?? CaptureResolution.preferred,
            frameRate: preferences.frameRate ?? CaptureFrameRate.preferred
        )
        sessionQueue.async { [weak self] in
            guard let self else { return }
            switch self.configureIfNeeded(position: target, preferred: preferred) {
            case .success:
                self.configureAudioSession()
                if !self.session.isRunning { self.session.startRunning() }
                // 会话跑起来之后才调焦距：虚拟摄像头要会话在跑才肯换那颗镜头
                self.resetZoomAndFocus()
                self.onMain {
                    self.refreshDeviceCapabilities()
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

    /// 把音频会话切到回看用的播放模式，切完再返回。
    ///
    /// `setCategory` + `setActive` 是**同步**的系统调用，要等音频路由真的切过去才返回，
    /// 耗时取决于当前的输出设备（外放、蓝牙耳机差别很大）。它原先写在
    /// 「停止录制 → 进回看」那一步的主线程上，这段时间里界面画不了东西。
    ///
    /// 挪到 `sessionQueue` 而不是随便一条后台队列，是因为切回录制模式的
    /// `resumeSession()` 也走它：两个方向的切换排在同一条串行队列上按入队顺序执行，
    /// 「回看 → 重拍」不会出现播放模式后到、把刚设好的录制模式盖掉，
    /// 结果回到取景却录不到声音。
    ///
    /// 调用方要自己处理「等这一下的工夫里页面已经不在了」：这里只保证切换完成，
    /// 不关心谁还在等。
    func activatePlaybackAudioSession() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                let audioSession = AVAudioSession.sharedInstance()
                try? audioSession.setCategory(.playback, mode: .moviePlayback)
                try? audioSession.setActive(true)
                continuation.resume()
            }
        }
    }

    /// 关闭相机并收尾。
    ///
    /// 标 `@MainActor` 是因为它要碰计时器与 `recordingStart` 这两个主线程资源；
    /// 会话侧的收尾自己会跳 `sessionQueue`，因此标注不影响它的线程语义。
    ///
    /// **关相机时会把正在录的那一条作废**：先摘掉 `completion`，收尾回调回来时
    /// 就没有接收者了（它会顺手把文件删掉，见 `didFinishRecordingTo`）。不摘的话，
    /// 回调会回到一个已经消失的页面上执行「进入回看」——把音频会话切成
    /// `.playback + active`，而唯一会归还焦点的 `onDisappear` 早就跑完了。
    ///
    /// 同时把焦距与对焦锁定放回默认：这两样记在**设备**上，不随会话结束而失效。
    /// 不放开的话，下次打开取景会一直停在上一页锁住的那一档，界面上还看不出原因。
    @MainActor
    func stop() {
        stopTimer()
        recordingStart = nil
        zoomObservation = nil
        stopObservingInterruptions()
        completion = nil

        sessionQueue.async { [weak self] in
            guard let self else { return }
            // movieOutput 属于会话状态，收尾也留在 sessionQueue 上做
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            self.resetZoomAndFocus()
            if self.session.isRunning { self.session.stopRunning() }
            self.deactivateAudioSession()
        }

        onMain {
            if self.isRecording { self.isRecording = false }
            if self.isTorchOn { self.isTorchOn = false }
            if self.isFocusLocked { self.isFocusLocked = false }
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
    func startRecording(completion: @MainActor @escaping (Result<RecordingOutput, Error>) -> Void) {
        guard status == .ready, !isRecording else { return }

        self.completion = completion
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.temporaryFilePrefix)\(UUID().uuidString).mov", isDirectory: false)

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
            if didSwitch {
                // 换了一颗摄像头：格式与焦距都要按新设备重新配一遍
                if let desired = self.desiredSettings {
                    // 前后摄支持的格式往往不一样（前置多数没有 4K），按用户想要的档位重新配；
                    // 配不上就退回它自己支持的最好一档，界面上的选项也跟着更新。
                    self.applyFormatLocked(desired.resolution, desired.frameRate, to: device)
                }
                self.resetZoomAndFocus()
            }
            self.onMain {
                guard didSwitch else { return }
                self.position = target
                self.refreshDeviceCapabilities()
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

    // MARK: - 焦距

    /// 缩放到指定倍率。
    ///
    /// - Parameter ramped: 点档位胶囊时用平滑过渡（画面一点点推过去，看得清推到了哪），
    ///   双指跟手缩放时直接落到手指指定的倍率。
    func setZoom(_ factor: CGFloat, ramped: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }

            let target = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            let isRamping = device.isRampingVideoZoom
            if !isRamping, abs(device.videoZoomFactor - target) < 0.001 { return }

            do {
                try device.lockForConfiguration()
                if isRamping { device.cancelVideoZoomRamp() }
                if ramped {
                    device.ramp(toVideoZoomFactor: target, withRate: 12)
                } else {
                    device.videoZoomFactor = target
                }
                device.unlockForConfiguration()
                // 倍率由设备侧观察回传（见 refreshDeviceCapabilities），
                // 这里只在平滑过渡时先把目标值报给界面，胶囊不会等一秒钟才亮
                if ramped { self.onMain { self.zoomFactor = target } }
            } catch {
                // 变焦失败不影响录制，静默忽略
            }
        }
    }

    // MARK: - 对焦

    /// 把对焦与曝光的兴趣点挪到这个位置。
    ///
    /// - Parameter lock: `true` 表示长按锁定（对焦与曝光都不再自动调整），
    ///   `false` 表示点按重新自动对焦一次。
    ///
    /// 兴趣点用的是设备坐标（左上 (0,0) — 右下 (1,1)），由预览层换算，
    /// 不在这里自己算——画面既有缩放又有旋转，正着算容易差半屏。
    func focus(atDevicePoint point: CGPoint, lock: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }

            let applied: Bool
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                applied = lock
                    ? self.lockFocusAndExposure(device, at: point)
                    : self.focus(device, at: point)
            } catch {
                // 对焦设置失败不影响录制，静默忽略
                return
            }

            guard applied else { return }
            self.onMain { self.isFocusLocked = lock }
        }
    }

    /// 点按对焦：把兴趣点挪过去，并重新走一次自动对焦。
    private func focus(_ device: AVCaptureDevice, at point: CGPoint) -> Bool {
        var applied = false

        let autoMode: AVCaptureDevice.FocusMode? = device.isFocusModeSupported(.autoFocus)
            ? .autoFocus
            : (device.isFocusModeSupported(.continuousAutoFocus) ? .continuousAutoFocus : nil)

        if device.isFocusPointOfInterestSupported, let autoMode {
            device.focusPointOfInterest = point
            // 先落回连续对焦再切一次性对焦，重复点同一个点也会重新对一次，
            // 否则「刚才没对上，再点一下」会毫无反应。
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.focusMode = autoMode
            applied = true
        }

        if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposurePointOfInterest = point
            device.exposureMode = .continuousAutoExposure
            applied = true
        }

        return applied
    }

    /// 长按锁定：对焦与曝光都停在这一刻，画面不会再自己调整。
    private func lockFocusAndExposure(_ device: AVCaptureDevice, at point: CGPoint) -> Bool {
        guard device.isFocusModeSupported(.locked) else { return false }

        device.focusPointOfInterest = point
        device.focusMode = .locked

        if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.locked) {
            device.exposurePointOfInterest = point
            device.exposureMode = .locked
        }

        return true
    }

    // MARK: - 画质（分辨率与帧率）

    /// 切换分辨率与帧率。拍摄中不允许改：会话正在用这份格式往文件里写。
    func applyCaptureSettings(resolution: CaptureResolution, frameRate: CaptureFrameRate) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }

            guard !self.movieOutput.isRecording else {
                self.onMain { self.settingsError = "正在拍摄，先停止拍摄才能改画质。" }
                return
            }

            // 先记下用户想要的那一档：实际配不配得上另说，用户的意图不该被设备改掉
            self.desiredSettings = (resolution, frameRate)

            // 界面只列出可选的档位，理论上不会挑出跑不了的组合；真挑不出来就如实说明，
            // 而不是悄悄按别的档位录下去。
            guard let applied = self.applyFormatLocked(resolution, frameRate, to: device) else {
                self.publishFormatCapabilities(device)
                self.onMain { self.settingsError = "这台摄像头不支持 \(resolution.title) 的 \(frameRate.title)，画质保持原样。" }
                return
            }

            let boxed = MainOnly(value: applied)
            self.onMain {
                self.resolution = boxed.value.0
                self.frameRate = boxed.value.1
                self.preferences.resolution = resolution
                self.preferences.frameRate = frameRate
                self.refreshDeviceCapabilities()
            }
        }
    }

    /// 把设备配成指定的分辨率与帧率，返回实际生效的组合。
    ///
    /// 同一个分辨率下常有多份设备格式（1080p 就有到 30 与到 60 两份），
    /// 所以格式必须与（分辨率、帧率）成对地挑，只按宽高挑会选错那一份。
    ///
    /// 会话预设要切成 `.inputPriority`：只要还用 `.high` 这类预设，
    /// 格式就由会话决定，手动设的 `activeFormat` 会被它改回去。
    @discardableResult
    private func applyFormatLocked(
        _ resolution: CaptureResolution,
        _ frameRate: CaptureFrameRate,
        to device: AVCaptureDevice
    ) -> (CaptureResolution, CaptureFrameRate)? {
        let catalog = Self.catalog(for: device)

        let targetResolution = catalog.resolutions.contains(resolution) ? resolution : catalog.resolutions.first
        guard let targetResolution,
              let targetFrameRate = CaptureFrameRate.closest(
                to: frameRate,
                among: catalog.frameRates(for: targetResolution)
              ),
              let descriptor = catalog.descriptor(for: targetResolution, frameRate: targetFrameRate),
              let format = Self.format(in: device, matching: descriptor) else {
            return nil
        }

        session.beginConfiguration()

        if session.sessionPreset != .inputPriority { session.sessionPreset = .inputPriority }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            device.activeFormat = format

            // 帧率由设备自动调整时不允许写帧时长（会抛异常），先关掉它。
            // 换 activeFormat 本身会把它重置为 false，这里只是把两条路径都兜住。
            if device.isAutoVideoFrameRateEnabled { device.isAutoVideoFrameRateEnabled = false }
            device.activeVideoMinFrameDuration = targetFrameRate.frameDuration
            device.activeVideoMaxFrameDuration = targetFrameRate.frameDuration
        } catch {
            session.commitConfiguration()
            return nil
        }

        session.commitConfiguration()

        // 体积上限按新格式的实际码率重新估算：不这样做的话，它会一直停在
        // 兜底的固定值上，4K / 60 fps 这类高码率格式就会远早于时长上限被截断
        // （即 P2-36 的根因）。
        updateMaximumFileSize()

        return (targetResolution, targetFrameRate)
    }

    /// 按当前生效格式重新估算体积上限，避免固定值在高分辨率、高帧率下
    /// 远早于时长上限触发。
    ///
    /// `outputSettings(for:)` 返回 AVFoundation 就当前 `activeFormat` 实际会用的
    /// 编码参数（含平均码率），比自己按宽高、帧率去估算更准，也不需要跟着
    /// 新机型的编码器选择逐个调整。取不到码率时退回固定的 600 MB，上限依然存在。
    ///
    /// 只在估算值比固定档更宽松时才采用（`max` 兜底）：画质调低不该反而把
    /// 上限收紧，否则退回 1080p 之后，原本录得完的时长反而录不完。
    private func updateMaximumFileSize() {
        guard let connection = movieOutput.connection(with: .video) else { return }

        let settings = movieOutput.outputSettings(for: connection)
        guard let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any],
              let averageBitRate = (compression[AVVideoAverageBitRateKey] as? NSNumber)?.doubleValue,
              averageBitRate > 0 else {
            movieOutput.maxRecordedFileSize = Self.maximumFileSize
            return
        }

        // 留 15% 余量：平均码率会因画面复杂度、音轨与封装开销上下浮动，
        // 卡在整点上会让体积上限比时长上限先一步触发，回到修复前的问题。
        let estimatedBytes = averageBitRate / 8 * Self.maximumDurationSeconds * 1.15
        movieOutput.maxRecordedFileSize = max(Int64(estimatedBytes), Self.maximumFileSize)
    }

    /// 回到默认焦距，并放开对焦与曝光的锁定。
    ///
    /// 两样都记在设备上、跨会话留着：不收回去的话，下一次打开取景会莫名停在上一次的
    /// 构图与对焦上。开了相机、换了摄像头、关掉相机各调一次，行为才和系统相机一样。
    private func resetZoomAndFocus() {
        guard let device = videoInput?.device else { return }
        let defaultZoom = Self.zoomScale(for: device).defaultFactor

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if abs(device.videoZoomFactor - defaultZoom) > 0.001 {
                if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
                device.videoZoomFactor = defaultZoom
            }

            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        } catch {
            // 收尾时的清理失败没有可执行的补救，忽略
        }
    }

    // MARK: - 会话配置

    private func configureIfNeeded(
        position: AVCaptureDevice.Position,
        preferred: (resolution: CaptureResolution, frameRate: CaptureFrameRate)
    ) -> Result<Void, Error> {
        if isConfigured { return .success(()) }

        guard let device = Self.camera(position: position) else {
            return .failure(CameraError.noCameraAvailable)
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // 分辨率与帧率由自己指定（见 applyFormatLocked）。只要还挂着 .high 这类预设，
        // 选哪份设备格式就由会话说了算，界面上的分辨率按钮会变成摆设。
        session.sessionPreset = .inputPriority

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

        // 挑不到目标档位就保持设备默认格式，界面会按实际生效的组合显示，不谎报
        desiredSettings = preferred
        applyFormatLocked(preferred.resolution, preferred.frameRate, to: device)

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

    /// 设备能力（补光、焦距档位、可选画质）都取决于当前这颗摄像头，统一在队列侧读一次。
    ///
    /// 界面上的档位与选项全部来自这里，而不是自己攒一份——换摄像头、系统自动换镜头
    /// 都会让它们变，只有每次重新问设备才不会显示一份过期的能力表。
    private func refreshDeviceCapabilities() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let device = self.videoInput?.device else {
                self.onMain {
                    self.isTorchAvailable = false
                    self.isTorchOn = false
                }
                return
            }

            let boxed = MainOnly(value: (
                device: device,
                scale: Self.zoomScale(for: device),
                zoom: device.videoZoomFactor,
                isTorchAvailable: device.hasTorch && device.isTorchAvailable,
                isTorchOn: device.torchMode == .on
            ))

            self.onMain {
                self.isTorchAvailable = boxed.value.isTorchAvailable
                self.isTorchOn = boxed.value.isTorchOn
                self.zoomScale = boxed.value.scale
                self.zoomFactor = boxed.value.zoom
                self.observeZoom(of: boxed.value.device)
            }

            self.publishFormatCapabilities(device)
        }
    }

    /// 把这颗摄像头实际支持的画质、以及当前生效的那一档报给界面。
    ///
    /// 报的是**实际**生效的组合：前后摄支持的档位不一样，切到前置后可能比用户选的
    /// 低一档，界面必须显示真的在录什么，而不是用户以为自己选了什么。
    private func publishFormatCapabilities(_ device: AVCaptureDevice) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let seconds = device.activeVideoMinFrameDuration.seconds
        let boxed = MainOnly(value: (
            catalog: Self.catalog(for: device),
            resolution: CaptureResolution.matching(
                width: Int(dimensions.width),
                height: Int(dimensions.height)
            ),
            frameRate: seconds > 0
                ? CaptureFrameRate(rawValue: Int((1 / seconds).rounded()))
                : nil
        ))

        onMain {
            self.formatCatalog = boxed.value.catalog
            self.resolution = boxed.value.resolution
            self.frameRate = boxed.value.frameRate
        }
    }

    /// 变焦倍率由设备侧连续变化（平滑过渡、在几颗镜头之间自动切换），
    /// 观察它而不是自己记账，界面显示的倍率才不会和取景画面脱节。
    @MainActor
    private func observeZoom(of device: AVCaptureDevice) {
        zoomObservation = device.observe(\.videoZoomFactor, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            self?.onMain { self?.zoomFactor = value }
        }
    }

    // MARK: - 设备格式

    /// 这台摄像头的变焦区间与档位。
    ///
    /// 区间交给 `ZoomRangePolicy` 结算：它优先用系统的推荐区间（也就是内建相机缩放控件的
    /// 取值区间），而不是设备的能力极限再压一道固定上限。推荐区间挂在 `activeFormat` 上，
    /// 所以每次换格式（换分辨率/帧率、切前后摄）之后都必须重新问一次。
    private static func zoomScale(for device: AVCaptureDevice) -> ZoomScale {
        ZoomScale(
            range: ZoomRangePolicy.range(
                recommended: device.activeFormat.systemRecommendedVideoZoomRange,
                availableLower: device.minAvailableVideoZoomFactor,
                availableUpper: device.maxAvailableVideoZoomFactor
            ),
            displayMultiplier: device.displayVideoZoomFactorMultiplier,
            switchOverFactors: device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        )
    }

    private static func catalog(for device: AVCaptureDevice) -> CaptureFormatCatalog {
        CaptureFormatCatalog(descriptors: formatEntries(for: device).map(\.descriptor))
    }

    /// 找出与摘要完全对应的那份设备格式。
    ///
    /// 摘要里带着帧率区间，不能只比宽高：同一个分辨率下常有多份格式
    /// （1080p 有到 30 与到 60 两份），只看宽高会拿错那一份。
    private static func format(
        in device: AVCaptureDevice,
        matching descriptor: CaptureFormatDescriptor
    ) -> AVCaptureDevice.Format? {
        formatEntries(for: device).first { $0.descriptor == descriptor }?.format
    }

    private static func formatEntries(for device: AVCaptureDevice) -> [FormatEntry] {
        device.formats.map { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let ranges = format.videoSupportedFrameRateRanges
            return FormatEntry(
                format: format,
                descriptor: CaptureFormatDescriptor(
                    width: Int(dimensions.width),
                    height: Int(dimensions.height),
                    minimumFrameRate: ranges.map(\.minFrameRate).min() ?? 0,
                    maximumFrameRate: ranges.map(\.maxFrameRate).max() ?? 0
                )
            )
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

        let result: Result<RecordingOutput, Error>
        if let error, !finishedSuccessfully {
            result = .failure(error)
        } else {
            let output = RecordingOutput(url: outputFileURL, stopReason: Self.stopReason(matching: error))
            result = .success(output)
        }

        // `Error` 不是 Sendable，套壳带到主线程；随后只在主线程使用
        let boxed = MainOnly(value: result)
        onMain {
            self.isRecording = false
            self.stopTimer()
            self.recordingStart = nil
            self.elapsed = 0

            // 没人等这条视频时（相机已经关掉，这次录制被作废）就地删掉，
            // 不留一个谁都收不回的临时文件。文件是 AVFoundation 刚写完的，
            // 删早了它还会再写一遍，所以只在回调里删、不在 stop() 里删。
            guard let handler = self.completion else {
                try? FileManager.default.removeItem(at: outputFileURL)
                return
            }
            self.completion = nil
            handler(boxed.value)
        }
    }

    /// 区分「用户 / 系统主动停止」与「撞到本类自己设的体积、时长上限」。
    ///
    /// 撞上限时 AVFoundation 会带着具体的 `AVError`（`.maximumFileSizeReached` /
    /// `.maximumDurationReached`）：素材完好、判定为成功，但用户看到的只是
    /// 「自己停了」，界面需要据此补一句说明。来电、切后台等中断都经
    /// `stopRecording()` 主动收尾（`error` 为 nil 或不是这两种 code），因此仍归为
    /// `userRequested`，不会被误报成撞上限。
    private static func stopReason(matching error: Error?) -> StopReason {
        guard let avError = error as? AVError else { return .userRequested }
        switch avError.code {
        case .maximumFileSizeReached, .maximumDurationReached:
            return .reachedLimit
        default:
            return .userRequested
        }
    }
}

// MARK: - 临时文件回收

nonisolated extension CameraRecorder {
    /// 清掉上一次会话残留在临时目录里的录制文件。
    ///
    /// 录完的片段正常有两条去处：交给 `ShotStore` 存进「分镜视频」，或由「重拍」
    /// 删掉。但关相机、被系统杀掉、刚起头就失败这些中断路径会留下
    /// `shot-*.mov`，而系统什么时候清临时目录由 iOS 决定。启动时统一收一次，
    /// 免得它们一直占着磁盘。
    static func cleanUpTemporaryRecordings(fileManager: FileManager = .default) {
        let root = fileManager.temporaryDirectory
        let contents = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where url.lastPathComponent.hasPrefix(temporaryFilePrefix) {
            try? fileManager.removeItem(at: url)
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
