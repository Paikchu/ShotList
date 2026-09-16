import SwiftUI

// MARK: - 画幅与帧率

/// 成片画幅。
///
/// 只给竖屏两档：这个应用产出的是抖音/小红书竖屏 Vlog，横屏不在射程内。
/// 分辨率写成枚举而不是让用户填两个数字，是为了让「画幅」和「帧率」一样
/// 只有一个来源——导出规格与界面预览读同一个值，不会出现「预览是竖屏、
/// 导出说横屏」这种对不上的情况。
nonisolated enum FilmCanvas: String, CaseIterable, Identifiable, Codable, Sendable {
    /// 2160×3840，iPhone 原生 4K 竖屏
    case vertical4K
    /// 1080×1920，平台推荐的日常发布尺寸
    case vertical1080

    var id: String { rawValue }

    var width: Int {
        switch self {
        case .vertical4K: return 2160
        case .vertical1080: return 1080
        }
    }

    var height: Int {
        switch self {
        case .vertical4K: return 3840
        case .vertical1080: return 1920
        }
    }

    var title: String {
        switch self {
        case .vertical4K: return "竖屏 4K"
        case .vertical1080: return "竖屏 1080p"
        }
    }

    var detail: String { "\(width)×\(height)" }
}

/// 成片帧率
nonisolated enum FilmFrameRate: Int, CaseIterable, Identifiable, Codable, Sendable {
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }

    var title: String { "\(rawValue) fps" }
}

// MARK: - 文字样式

/// 字体族。
///
/// 这里存的是**族名**而不是字体文件路径：真正渲染文字的是剪辑侧（本机 ffmpeg
/// 没有 drawtext，走 Pillow 预渲染），字体路径归它决定。应用只声明「用黑体」，
/// 换一套渲染环境时不必改导出包。
nonisolated enum FilmFontFamily: String, CaseIterable, Identifiable, Codable, Sendable {
    /// 黑体：笔画等宽、无衬线，抖音字幕的常见选择
    case heiti
    /// 圆体：笔画末端圆润，语气更软
    case rounded
    /// 宋体：有衬线，适合正经口播
    case songti

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heiti: return "黑体"
        case .rounded: return "圆体"
        case .songti: return "宋体"
        }
    }

    /// 给渲染侧的提示：本机可用的近似字体。
    ///
    /// 写进导出规格里，省得剪辑侧每次都要翻一遍系统字体。
    var renderHint: String {
        switch self {
        case .heiti: return "/System/Library/Fonts/Hiragino Sans GB.ttc"
        case .rounded: return "/System/Library/Fonts/Hiragino Maru Gothic ProN.ttc"
        case .songti: return "/System/Library/Fonts/Songti.ttc"
        }
    }
}

/// 字重
nonisolated enum FilmFontWeight: String, CaseIterable, Identifiable, Codable, Sendable {
    case regular
    case medium
    case bold
    case heavy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .regular: return "常规"
        case .medium: return "中等"
        case .bold: return "粗体"
        case .heavy: return "特粗"
        }
    }

    /// `.ttc` 字体集合里的子字体索引：0 常规、1 粗体。
    ///
    /// 本机的 `Hiragino Sans GB.ttc` 只有这两档，中间档由渲染侧用描边加粗近似。
    var collectionIndex: Int {
        switch self {
        case .regular, .medium: return 0
        case .bold, .heavy: return 1
        }
    }

    /// SwiftUI 预览用的字重
    var swiftUIWeight: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }
}

/// 一套文字样式。
///
/// 尺寸一律用**占屏高的比例**而不是点数：成片可能导 4K 也可能导 1080p，
/// 点数只在某一个分辨率下成立，比例换哪个分辨率都对。实测基线取自
/// `9月14日.mov`（2160×3840）：字号 4.43%、描边 0.3%。
nonisolated struct TextTypography: Codable, Hashable, Sendable {
    /// 字体族
    var family: FilmFontFamily
    /// 字重
    var weight: FilmFontWeight
    /// 字号占屏高的比例
    var sizeRatio: Double
    /// 描边宽度占屏高的比例
    var strokeRatio: Double
    /// 文字色（`#RRGGBB`）
    var colorHex: String
    /// 描边色（`#RRGGBB`）
    var strokeColorHex: String

    init(
        family: FilmFontFamily = .heiti,
        weight: FilmFontWeight = .heavy,
        sizeRatio: Double = 0.044,
        strokeRatio: Double = 0.003,
        colorHex: String = "#FFFFFF",
        strokeColorHex: String = "#000000"
    ) {
        self.family = family
        self.weight = weight
        self.sizeRatio = sizeRatio
        self.strokeRatio = strokeRatio
        self.colorHex = colorHex
        self.strokeColorHex = strokeColorHex
    }
}

// MARK: - 图层

/// 图层贴在画面的哪个位置。
///
/// 四个位置**水平一律居中**：实测成片的角标与字幕居中偏差不超过 2px，
/// 而且竖屏两侧要留给平台按钮，居中之外的横向位置没有实际用途。
/// 留成枚举而不是让用户拖，是为了让导出规格里有一个稳定可读的名字
/// （`topCenter`），AI 不必从两个比例反推它是想贴顶还是想贴中。
nonisolated enum OverlayAnchor: String, CaseIterable, Identifiable, Codable, Sendable {
    case topCenter
    case center
    case lowerThird
    case bottomCenter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topCenter: return "顶部居中"
        case .center: return "画面正中"
        case .lowerThird: return "下三分"
        case .bottomCenter: return "底部居中"
        }
    }

    /// 文字块**中心**距屏幕顶部的比例。选位置时把它写进 `offsetYRatio`，
    /// 之后用户还能再微调——规格里最终以 `offsetYRatio` 为准，这个枚举只是
    /// 一个可读的位置名。
    var defaultOffsetYRatio: Double {
        switch self {
        case .topCenter: return 0.042
        case .center: return 0.500
        case .lowerThird: return 0.709
        case .bottomCenter: return 0.860
        }
    }
}

/// 图层文案从哪来。
///
/// 这就是「哪些是全局、哪些是内容」的分界线：全局配置只声明**图层长什么样、
/// 贴在哪儿**；每镜具体写什么，由用户在镜头面板里分别写进「屏幕字幕」与
/// 「角标数值」两个字段——与「分镜描述」（拍什么）是分开的三样东西。
nonisolated enum OverlayContentSource: String, CaseIterable, Identifiable, Codable, Sendable {
    /// 全片统一文案，写在 `text` 里（片尾卡、固定角标）
    case fixed
    /// 取自该镜头的屏幕文字：字幕取「屏幕字幕」，角标取「角标数值」
    case shotText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fixed: return "全片统一"
        case .shotText: return "每镜取自分镜文字"
        }
    }

    var detail: String {
        switch self {
        case .fixed: return "文字写在这里，每个镜头都一样"
        case .shotText: return "字幕取每镜的「屏幕字幕」，角标取「角标数值」，这里只留格式模板"
        }
    }
}

/// 一个常驻图层的样式。
///
/// 只管「贴在哪儿」和「文案从哪来」，不管「长什么样」——文字样式整片只有一套
/// （见 `FilmStyle.typography`）。三层文字在实测成片里字号、描边完全一致，
/// 再开一层「逐图层覆盖」只会多出一组没人用的旋钮。
nonisolated struct OverlayStyle: Codable, Hashable, Sendable {
    /// 是否出这个图层
    var isEnabled: Bool
    /// 位置名（给人看，也给 AI 一个稳定标识）
    var anchor: OverlayAnchor
    /// 文字块中心距屏幕顶部的比例。**规格里的权威数值**，换位置时随 `anchor` 一起写。
    var offsetYRatio: Double
    /// 最多几行，超出由渲染侧按断行规则处理
    var maxLines: Int
    /// 文案来源
    var contentSource: OverlayContentSource
    /// 文案模板。`contentSource == .shotText` 时，`{value}` 会被该镜头的
    /// 「角标数值」替换；也可留空表示整段文字都取自分镜文字。
    var text: String

    init(
        isEnabled: Bool = true,
        anchor: OverlayAnchor,
        offsetYRatio: Double? = nil,
        maxLines: Int = 1,
        contentSource: OverlayContentSource,
        text: String
    ) {
        self.isEnabled = isEnabled
        self.anchor = anchor
        self.offsetYRatio = offsetYRatio ?? anchor.defaultOffsetYRatio
        self.maxLines = maxLines
        self.contentSource = contentSource
        self.text = text
    }

    /// 常驻角标：贴在顶部居中，数值逐镜变化。对应实测成片里的「热量缺口：N千卡」。
    /// `{value}` 由该镜头的「角标数值」字段代入。
    static let persistentBadge = OverlayStyle(
        anchor: .topCenter,
        maxLines: 1,
        contentSource: .shotText,
        text: "热量缺口：{value}千卡"
    )

    /// 分镜字幕：贴在下三分，文案取自该镜头的「屏幕字幕」。
    static let shotCaption = OverlayStyle(
        anchor: .lowerThird,
        maxLines: 2,
        contentSource: .shotText,
        text: ""
    )
}

/// 片尾卡：整段黑底 + 一行结论。
///
/// 单独一个类型而不是复用 `OverlayStyle`：它除了文字样式，还要管背景色和时长，
/// 而这两项对普通图层没有意义。内部仍持有 `OverlayStyle`，位置、字号这些
/// 与其它图层同源，不另起一套。
nonisolated struct TailCardStyle: Codable, Hashable, Sendable {
    var overlay: OverlayStyle
    /// 片尾卡时长（秒）。实测成片是 0.7 秒。
    var duration: Double
    /// 背景色（`#RRGGBB`）
    var backgroundColorHex: String

    init(
        overlay: OverlayStyle = OverlayStyle(
            anchor: .center,
            maxLines: 2,
            contentSource: .fixed,
            text: "今日热量缺口：\n{value}千卡"
        ),
        duration: Double = 0.7,
        backgroundColorHex: String = "#000000"
    ) {
        self.overlay = overlay
        self.duration = duration
        self.backgroundColorHex = backgroundColorHex
    }

    var isEnabled: Bool { overlay.isEnabled }
}

// MARK: - 节奏与音轨

/// 剪辑节奏：总时长与单镜时长的约束。
///
/// 成片时长由**目标区间**反推，不由解说决定——每一镜分到多长，是拿总时长
/// 减去片尾卡之后、在单镜区间的约束下按素材长度加权分出来的。写成区间而不是
/// 一个定值，是因为素材长度不齐，凑不出恰好 20.0 秒时不至于被迫丢镜头或硬凑。
nonisolated struct PacingStyle: Codable, Hashable, Sendable {
    /// 成片总时长下限（秒），不含片尾卡
    var targetMinDuration: Double
    /// 成片总时长上限（秒），不含片尾卡
    var targetMaxDuration: Double
    /// 单个镜头的最短时长（秒）
    var shotMinDuration: Double
    /// 单个镜头的最长时长（秒）
    var shotMaxDuration: Double

    init(
        targetMinDuration: Double = 18,
        targetMaxDuration: Double = 22,
        shotMinDuration: Double = 0.6,
        shotMaxDuration: Double = 2.5
    ) {
        self.targetMinDuration = targetMinDuration
        self.targetMaxDuration = targetMaxDuration
        self.shotMinDuration = shotMinDuration
        self.shotMaxDuration = shotMaxDuration
    }

    /// 写进导出规格的一句话，人也能读
    var documentText: String {
        "总时长 \(slShort(targetMinDuration))–\(slShort(targetMaxDuration)) 秒，"
        + "单镜 \(slShort(shotMinDuration))–\(slShort(shotMaxDuration)) 秒"
    }

    /// 下限被拖到上限之上时的兜底：宁可按上限走，也不给出一条无解的空区间。
    var normalized: PacingStyle {
        var copy = self
        if copy.targetMaxDuration < copy.targetMinDuration {
            copy.targetMaxDuration = copy.targetMinDuration
        }
        if copy.shotMaxDuration < copy.shotMinDuration {
            copy.shotMaxDuration = copy.shotMinDuration
        }
        return copy
    }

    /// 这条区间能不能装下这么多镜头——装不下时界面要提前说，
    /// 而不是等导出后才发现 AI 把镜头砍了一截。
    func canHost(shotCount: Int, tailCardDuration: Double) -> Bool {
        guard shotCount > 0 else { return true }
        let budget = targetMaxDuration - tailCardDuration
        return budget >= Double(shotCount) * shotMinDuration
    }

    /// 这一段镜头的推荐单镜时长（秒）
    func suggestedShotDuration(shotCount: Int, tailCardDuration: Double) -> Double {
        guard shotCount > 0 else { return shotMinDuration }
        let budget = max(targetMaxDuration - tailCardDuration, 0) + max(targetMinDuration - tailCardDuration, 0)
        return min(max(budget / 2 / Double(shotCount), shotMinDuration), shotMaxDuration)
    }
}

/// 音轨
nonisolated enum FilmAudioMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// 保留素材现场声
    case original
    /// 全片静音，后期自己配乐
    case silent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "保留原声"
        case .silent: return "静音"
        }
    }

    var detail: String {
        switch self {
        case .original: return "直接使用各镜素材的现场声"
        case .silent: return "成片不带音轨，后期自行配乐"
        }
    }
}

nonisolated struct AudioStyle: Codable, Hashable, Sendable {
    var mode: FilmAudioMode
    /// 原声音量（0–1）
    var originalGain: Double

    init(mode: FilmAudioMode = .original, originalGain: Double = 1.0) {
        self.mode = mode
        self.originalGain = originalGain
    }
}

// MARK: - 影片级剪辑风格

/// 一部影片的剪辑风格。
///
/// 这是「影片级」的那一层：一次设定，全片所有镜头共用。它只回答两个问题——
/// **怎么剪**（画幅、帧率、总时长、单镜时长、音轨）和**哪些样式是全局的**
/// （常驻图层的位置与文字样式）。
///
/// 它**不**回答「这一镜写什么」：每镜的屏幕字幕、角标数值写在镜头自己的
/// `Shot.caption` / `Shot.badgeValue` 里，由用户自己写。分界线就是
/// `OverlayContentSource`——全局这一层只声明图层的存在、位置、格式模板，
/// 具体文字是内容，不进这个结构。
///
/// 默认值全部取自成片 `9月14日.mov` 的实测结果，所以「不配置」就等于
/// 「按已经剪出来的那条片子剪」。
nonisolated struct FilmStyle: Codable, Hashable, Sendable {
    /// 画幅
    var canvas: FilmCanvas
    /// 帧率
    var frameRate: FilmFrameRate
    /// 节奏约束
    var pacing: PacingStyle
    /// 全局文字样式：没有单独覆盖的图层都用它
    var typography: TextTypography
    /// 常驻角标（长挂在画面上的那一条，例如热量缺口）
    var badge: OverlayStyle
    /// 分镜字幕
    var caption: OverlayStyle
    /// 片尾卡
    var tailCard: TailCardStyle
    /// 音轨
    var audio: AudioStyle

    init(
        canvas: FilmCanvas = .vertical4K,
        frameRate: FilmFrameRate = .fps30,
        pacing: PacingStyle = PacingStyle(),
        typography: TextTypography = TextTypography(),
        badge: OverlayStyle = .persistentBadge,
        caption: OverlayStyle = .shotCaption,
        tailCard: TailCardStyle = TailCardStyle(),
        audio: AudioStyle = AudioStyle()
    ) {
        self.canvas = canvas
        self.frameRate = frameRate
        self.pacing = pacing
        self.typography = typography
        self.badge = badge
        self.caption = caption
        self.tailCard = tailCard
        self.audio = audio
    }

    /// 与实测成片一致的默认风格
    static let standard = FilmStyle()
}

// MARK: - 派生属性

nonisolated extension FilmStyle {
    /// 输出画幅的一句话，例如「2160×3840 · 30 fps」
    var canvasText: String {
        "\(canvas.width)×\(canvas.height) · \(frameRate.title)"
    }

    /// 导出页那一行摘要
    var summaryText: String {
        var parts = [canvas.title, pacing.documentText]
        if badge.isEnabled { parts.append("角标") }
        if caption.isEnabled { parts.append("字幕") }
        if tailCard.isEnabled { parts.append("片尾卡") }
        return parts.joined(separator: " · ")
    }

    /// 影片里有没有开任何图层——一个都没开时，导出的成片只有画面本身
    var hasVisibleOverlay: Bool {
        badge.isEnabled || caption.isEnabled || tailCard.isEnabled
    }
}

// MARK: - 单镜头有多长

/// 单镜时长的显示文本，例如「1.4 秒」
nonisolated func slShort(_ seconds: Double) -> String {
    let rounded = (seconds * 10).rounded() / 10
    if rounded == rounded.rounded() { return "\(Int(rounded))" }
    return String(format: "%.1f", rounded)
}

// MARK: - 兼容旧版本数据

nonisolated extension KeyedDecodingContainer {
    /// 取一个可选键，缺失或类型不符时返回兜底值。
    ///
    /// `FilmStyle` 的每个字段都靠它读：风格配置是**会随版本增加字段**的结构，
    /// 用合成的解码器读旧 JSON 会因为少一个键而整块解码失败，把用户已经调好的
    /// 风格一起丢掉。逐字段兜底之后，新增字段对旧数据就是「取默认值」。
    func slValue<T: Decodable>(_ key: Key, default fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

nonisolated extension TextTypography {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            family: c.slValue(.family, default: .heiti),
            weight: c.slValue(.weight, default: .heavy),
            sizeRatio: c.slValue(.sizeRatio, default: 0.044),
            strokeRatio: c.slValue(.strokeRatio, default: 0.003),
            colorHex: c.slValue(.colorHex, default: "#FFFFFF"),
            strokeColorHex: c.slValue(.strokeColorHex, default: "#000000")
        )
    }
}

nonisolated extension OverlayStyle {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let anchor = c.slValue(.anchor, default: OverlayAnchor.topCenter)
        self.init(
            isEnabled: c.slValue(.isEnabled, default: true),
            anchor: anchor,
            offsetYRatio: c.slValue(.offsetYRatio, default: anchor.defaultOffsetYRatio),
            maxLines: c.slValue(.maxLines, default: 1),
            contentSource: c.slValue(.contentSource, default: .shotText),
            text: c.slValue(.text, default: "")
        )
    }
}

nonisolated extension TailCardStyle {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            overlay: c.slValue(.overlay, default: OverlayStyle(
                anchor: .center,
                maxLines: 2,
                contentSource: .fixed,
                text: "今日热量缺口：\n{value}千卡"
            )),
            duration: c.slValue(.duration, default: 0.7),
            backgroundColorHex: c.slValue(.backgroundColorHex, default: "#000000")
        )
    }
}

nonisolated extension PacingStyle {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            targetMinDuration: c.slValue(.targetMinDuration, default: 18),
            targetMaxDuration: c.slValue(.targetMaxDuration, default: 22),
            shotMinDuration: c.slValue(.shotMinDuration, default: 0.6),
            shotMaxDuration: c.slValue(.shotMaxDuration, default: 2.5)
        )
    }
}

nonisolated extension AudioStyle {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: c.slValue(.mode, default: .original),
            originalGain: c.slValue(.originalGain, default: 1.0)
        )
    }
}

nonisolated extension FilmStyle {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            canvas: c.slValue(.canvas, default: .vertical4K),
            frameRate: c.slValue(.frameRate, default: .fps30),
            pacing: c.slValue(.pacing, default: PacingStyle()),
            typography: c.slValue(.typography, default: TextTypography()),
            badge: c.slValue(.badge, default: .persistentBadge),
            caption: c.slValue(.caption, default: .shotCaption),
            tailCard: c.slValue(.tailCard, default: TailCardStyle()),
            audio: c.slValue(.audio, default: AudioStyle())
        )
    }
}

// MARK: - 内置方案

/// 一套命名好的风格方案，供导出页一键套用。
///
/// 目前只有一套——就是成片实测出来的那套。方案列表留在这里而不是散在界面里，
/// 是为了让「套用」与「导出规格里写什么」读同一个结构。
nonisolated struct FilmStylePreset: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String
    let style: FilmStyle

    /// 图文卡点：无解说，靠常驻角标和分镜字幕叙事，快节奏切镜
    static let cardPacing = FilmStylePreset(
        id: "card-pacing",
        title: "图文卡点",
        detail: "无解说，顶部常驻角标 + 下三分字幕，快节奏切镜",
        style: FilmStyle()
    )

    static let all: [FilmStylePreset] = [.cardPacing]
}

// MARK: - 导出规格

nonisolated extension FilmStyle {
    /// 写进导出包的「剪辑规格.json」。
    ///
    /// 用机器可读的 JSON 而不是只写在 markdown 里：这份规格有十几项硬参数，
    /// 让剪辑侧从自然语言里解析必然出错，而 JSON 的键名是稳定的——加字段时
    /// 老字段还在原位，换一个模型或换一次对话也能稳定读出来。
    ///
    /// 所有数值都是**权威值**，剪辑侧不要再按自己的理解换算：位置只看
    /// `offsetYRatio`，字号只看 `sizeRatio`，比例一律相对屏高。
    ///
    /// 比例在文件里是原样的 `Double`，序列化后会是 `0.043999999999999997`
    /// 这种 17 位有效数字——这是 `JSONSerialization` 的写法，值本身没错，
    /// 换成 4 位小数也没用（二进制浮点存不下 0.044）。要给人看百分数就看
    /// 「分镜文字内容指南.md」里的「四、成片规格」，那一节按 `%.1f%%` 输出。
    ///
    /// 文件里不写各镜的屏幕字幕与角标数值——那是内容，写在各镜头的
    /// `caption` / `badgeValue` 里，由「分镜文字内容指南.md」逐镜提供。
    func exportedJSON(filmTitle: String, exportedAt: Date) -> [String: Any] {
        // 片尾卡关掉时时长按 0 下发：剪辑侧不必再猜「enabled=false 是不是还要留黑屏」。
        // 类型写死成 Double（而不是直接写 `0` 字面量）——`[String: Any]` 里字面量
        // 会被推断成 Int，同一份规格里出现「0」与「0.7」两种数字类型，读它的脚本
        // 按浮点取值时会拿到 nil。
        let tailCardDuration: Double = tailCard.isEnabled ? tailCard.duration : 0
        let normalizedPacing = pacing.normalized

        return [
            "specVersion": 1,
            "film": [
                "title": filmTitle.isEmpty ? "未命名影片" : filmTitle,
                "exportedAt": ISO8601DateFormatter().string(from: exportedAt)
            ],
            "canvas": [
                "width": canvas.width,
                "height": canvas.height,
                "fps": frameRate.rawValue,
                "orientation": "portrait",
                "sourceNote": "素材常见 rotation=-90，编码尺寸报横屏但实际为竖屏；"
                    + "判断方向请看本字段，不要用 ffprobe 的 width/height"
            ],
            "pacing": [
                "targetDuration": [normalizedPacing.targetMinDuration, normalizedPacing.targetMaxDuration],
                "shotDuration": [normalizedPacing.shotMinDuration, normalizedPacing.shotMaxDuration],
                "tailCardDuration": tailCardDuration
            ],
            "typography": [
                "family": typography.family.rawValue,
                "fontFileHint": typography.family.renderHint,
                "weight": typography.weight.rawValue,
                "sizeRatio": typography.sizeRatio,
                "strokeRatio": typography.strokeRatio,
                "color": typography.colorHex,
                "strokeColor": typography.strokeColorHex
            ],
            "overlays": [
                "badge": overlayJSON(badge),
                "caption": overlayJSON(caption),
                "tailCard": tailCardJSON(tailCardDuration: tailCardDuration)
            ],
            "audio": [
                "mode": audio.mode.rawValue,
                "originalGain": audio.mode == .silent ? 0.0 : audio.originalGain
            ]
        ]
    }

    /// 单个图层。文字样式不在这里重复——整片只有一套，写在顶层 `typography` 里。
    private func overlayJSON(_ overlay: OverlayStyle) -> [String: Any] {
        [
            "enabled": overlay.isEnabled,
            "anchor": overlay.anchor.rawValue,
            "offsetYRatio": overlay.offsetYRatio,
            "horizontalAlignment": "center",
            "maxLines": overlay.maxLines,
            "contentSource": overlay.contentSource.rawValue,
            "text": overlay.text
        ]
    }

    private func tailCardJSON(tailCardDuration: Double) -> [String: Any] {
        var json = overlayJSON(tailCard.overlay)
        json["duration"] = tailCardDuration
        json["backgroundColor"] = tailCard.backgroundColorHex
        return json
    }
}
