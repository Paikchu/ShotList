import AVFoundation
import Foundation

// MARK: - 分辨率

/// 录制分辨率。
///
/// 只列真正会被用到的三档。设备能报出很多尺寸（1440×1080、960×540…），
/// 那些是同一颗摄像头为不同帧率准备的中间格式，对拍分镜的人没有意义，
/// 报出来只会让选择变难。
nonisolated enum CaptureResolution: String, CaseIterable, Identifiable, Sendable {
    case uhd4K
    case hd1080
    case hd720

    var id: String { rawValue }

    /// 画面宽高。设备格式一律按传感器方向（横着）报尺寸，
    /// 竖屏录制只是把画面转过来，不改变格式本身的宽高。
    var width: Int {
        switch self {
        case .uhd4K: return 3840
        case .hd1080: return 1920
        case .hd720: return 1280
        }
    }

    var height: Int {
        switch self {
        case .uhd4K: return 2160
        case .hd1080: return 1080
        case .hd720: return 720
        }
    }

    /// 「4K」「1080p」「720p」
    var title: String {
        switch self {
        case .uhd4K: return "4K"
        case .hd1080: return "1080p"
        case .hd720: return "720p"
        }
    }

    /// 「3840 × 2160」
    var dimensionsText: String { "\(width) × \(height)" }

    var pixelCount: Int { width * height }

    /// 设备格式是否就是这个分辨率。宽度与高度对调也算：
    /// 个别摄像头会以竖向尺寸报格式，换算方向不该影响「这档能不能选」。
    func matches(width otherWidth: Int, height otherHeight: Int) -> Bool {
        (otherWidth == width && otherHeight == height)
            || (otherWidth == height && otherHeight == width)
    }

    static func matching(width: Int, height: Int) -> CaptureResolution? {
        allCases.first { $0.matches(width: width, height: height) }
    }

    /// 首次进入相机时的默认分辨率。
    ///
    /// 早先版本用 `.high` 预设，在 iPhone 上落到的就是 1080p，默认值保持一致，
    /// 免得升级之后素材体积悄悄翻几倍。
    static let preferred: CaptureResolution = .hd1080
}

// MARK: - 帧率

/// 录制帧率。
///
/// 只给这三档。设备报的帧率范围常常是连续的（1–30 意味着 24、25、30 都能跑），
/// 把区间里每个整数都列出来只会把选择变难；而对拍分镜来说真正有区别的就是
/// 24（电影感）、30（常规）、60（运镜与慢放）。
nonisolated enum CaptureFrameRate: Int, CaseIterable, Identifiable, Sendable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }

    /// 「30 fps」
    var title: String { "\(rawValue) fps" }

    /// 对应的帧时长，写回 `activeVideoMin/MaxFrameDuration`
    var frameDuration: CMTime { CMTime(value: 1, timescale: CMTimeScale(rawValue)) }

    static let preferred: CaptureFrameRate = .fps30

    /// 目标帧率在可用档位里不存在时，退到最接近的一档。
    ///
    /// 优先往低退：低帧率占的空间小，画质也更稳；只有一档更低的都没有时才往上取。
    static func closest(to target: CaptureFrameRate, among available: [CaptureFrameRate]) -> CaptureFrameRate? {
        guard !available.isEmpty else { return nil }
        if available.contains(target) { return target }
        let lower = available.filter { $0.rawValue < target.rawValue }.max { $0.rawValue < $1.rawValue }
        return lower ?? available.min { $0.rawValue < $1.rawValue }
    }
}

// MARK: - 设备格式

/// 设备格式里与「选分辨率、选帧率」相关的那点信息。
///
/// 抽成轻量值是为了让选择逻辑能脱离摄像头验证：模拟器没有摄像头，
/// `AVCaptureDevice.formats` 永远是空的，而「哪一档能选、选不了退到哪一档」
/// 恰恰是最容易算错的地方。
nonisolated struct CaptureFormatDescriptor: Hashable, Sendable {
    var width: Int
    var height: Int
    var minimumFrameRate: Double
    var maximumFrameRate: Double

    init(width: Int, height: Int, minimumFrameRate: Double, maximumFrameRate: Double) {
        self.width = width
        self.height = height
        self.minimumFrameRate = minimumFrameRate
        self.maximumFrameRate = maximumFrameRate
    }

    /// 这份格式能不能跑指定帧率。
    ///
    /// 设备报的上限常是 29.97 / 59.94 这类近似值，与 30 / 60 最多差 0.06 fps。
    /// 因此比较时留半帧余量，否则「60 fps」会被 59.94 的上限挡在门外。
    func supports(_ frameRate: CaptureFrameRate) -> Bool {
        let target = Double(frameRate.rawValue)
        let slack = 0.5
        return target >= minimumFrameRate - slack && target <= maximumFrameRate + slack
    }
}

/// 一台摄像头支持的（分辨率、帧率）组合。
nonisolated struct CaptureFormatCatalog: Equatable, Sendable {
    private(set) var descriptors: [CaptureFormatDescriptor]

    init(descriptors: [CaptureFormatDescriptor] = []) {
        self.descriptors = descriptors
    }

    var isEmpty: Bool { descriptors.isEmpty }

    /// 可用分辨率，按像素从多到少：设置面板与档位列表都按这个顺序展示。
    var resolutions: [CaptureResolution] {
        CaptureResolution.allCases
            .filter { resolution in
                descriptors.contains { resolution.matches(width: $0.width, height: $0.height) }
            }
            .sorted { $0.pixelCount > $1.pixelCount }
    }

    /// 某个分辨率下可用的帧率，从小到大。
    ///
    /// 帧率与分辨率不是独立的两件事：4K 常常只到 30，60 fps 往往只有 1080p 有。
    /// 所以可用帧率必须按所选分辨率现算，不能在进相机时算一次就一直用。
    func frameRates(for resolution: CaptureResolution) -> [CaptureFrameRate] {
        CaptureFrameRate.allCases.filter { candidate in
            descriptors.contains {
                resolution.matches(width: $0.width, height: $0.height) && $0.supports(candidate)
            }
        }
    }

    /// 挑出用于指定的那一份设备格式。
    ///
    /// 同一个分辨率下常有多份格式（例如 1080p 分别有 30 与 60 上限的两份），
    /// 取「刚好够用」的那份：上限最低，其次像素最少。拿一份 60 上限的格式去录 30 fps
    /// 并不省钱，高带宽格式会一直占着管线。
    func descriptor(for resolution: CaptureResolution, frameRate: CaptureFrameRate) -> CaptureFormatDescriptor? {
        descriptors
            .filter { resolution.matches(width: $0.width, height: $0.height) && $0.supports(frameRate) }
            .min { lhs, rhs in
                (lhs.maximumFrameRate, lhs.width * lhs.height) < (rhs.maximumFrameRate, rhs.width * rhs.height)
            }
    }

    /// 只按分辨率挑：目标帧率在这档分辨率下不可用时用（退档后重新挑格式）。
    func descriptor(for resolution: CaptureResolution) -> CaptureFormatDescriptor? {
        descriptors
            .filter { resolution.matches(width: $0.width, height: $0.height) }
            .min { lhs, rhs in
                (lhs.maximumFrameRate, lhs.width * lhs.height) < (rhs.maximumFrameRate, rhs.width * rhs.height)
            }
    }
}

// MARK: - 展示文本

nonisolated enum CaptureSettingsText {
    /// 「4K · 60 fps」。两个值都还不知道时返回 nil，由界面自己决定写什么。
    static func summary(resolution: CaptureResolution?, frameRate: CaptureFrameRate?) -> String? {
        switch (resolution, frameRate) {
        case (let resolution?, let frameRate?):
            return "\(resolution.title) · \(frameRate.title)"
        case (let resolution?, nil):
            return resolution.title
        case (nil, let frameRate?):
            return frameRate.title
        case (nil, nil):
            return nil
        }
    }

    /// 顶栏上的紧凑写法：「4K·30」。
    ///
    /// 取景页顶部的空间要留给分镜描述，画质只报一个「多少 pixel、多少帧」就够，
    /// 完整说法（含 fps 单位）留给设置面板与无障碍标签。
    static func compactSummary(resolution: CaptureResolution?, frameRate: CaptureFrameRate?) -> String? {
        switch (resolution, frameRate) {
        case (let resolution?, let frameRate?):
            return "\(resolution.title)·\(frameRate.rawValue)"
        case (let resolution?, nil):
            return resolution.title
        case (nil, let frameRate?):
            return "\(frameRate.rawValue)fps"
        case (nil, nil):
            return nil
        }
    }
}

// MARK: - 偏好

/// 记住上一次选的分辨率与帧率，下次进相机沿用。
///
/// 分镜是连着拍很多条的活儿，每次进相机都重挑一遍分辨率没有道理。
nonisolated struct CameraPreferences {
    private enum Key {
        static let resolution = "camera.captureResolution"
        static let frameRate = "camera.captureFrameRate"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var resolution: CaptureResolution? {
        get {
            defaults.string(forKey: Key.resolution).flatMap(CaptureResolution.init(rawValue:))
        }
        nonmutating set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: Key.resolution)
            } else {
                defaults.removeObject(forKey: Key.resolution)
            }
        }
    }

    var frameRate: CaptureFrameRate? {
        get {
            guard let stored = defaults.object(forKey: Key.frameRate) as? Int else { return nil }
            return CaptureFrameRate(rawValue: stored)
        }
        nonmutating set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: Key.frameRate)
            } else {
                defaults.removeObject(forKey: Key.frameRate)
            }
        }
    }
}
