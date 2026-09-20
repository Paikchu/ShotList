import Foundation

// MARK: - 剪辑风格是一段描述，不是一组选项

/// 「剪辑风格」这一层现在是**一段自然语言**：一次写好，整部影片共用，
/// 导出时原样写进 `剪辑风格.md`，交给剪辑工具照着剪。
///
/// 换成描述而不是一组固定选项，是因为：
///
/// 1. **消费它的本来就是能读自然语言的工具**。为每种风格加一个旋钮既加不完，
///    也表达不了旋钮之外的偏好——「快切不拖沓」「别加音乐」「转场别花」
///    这些要求没有对应的控件，却是用户真正想说的事。
/// 2. 固定选项只覆盖**已经想到的那些**。想到第十一种的时候，用户只能等应用加旋钮。
///
/// 于是这一层只剩两个职责：给空输入框一句像样的示例，以及把旧数据搬过来。
nonisolated enum FilmStylePrompt {

    /// 输入框为空时显示的示例（灰色占位，**不是**已填内容）。
    ///
    /// 刻意把「可以写哪几类」都点到一遍：照着改比从零写容易得多。
    /// 数值取实测成片（`9月14日.mov`）的基线，抄下来就是那条片子的观感。
    static let placeholder = """
    竖屏 1080×1920、30fps，总长 20 秒左右，单镜 0.5–2.5 秒，快切不拖沓。
    保留现场原声，不加解说、不加背景音乐。
    顶部居中一行角标（顶边距屏高约 2%）、底部居中两行以内字幕（块中心约屏高 71%），
    都是白色粗体加黑描边，字高约占屏高 4.4%。
    结尾 0.7 秒黑底卡，居中写一句收尾。
    """

    /// 「可写」清单：只列类别名，告诉用户能写哪几类。
    ///
    /// 只是提示，**不是必填项，也不限制写法**——清单之外的偏好照样有效。
    /// 例句都在上面的 `placeholder` 里，这里不再重复。
    static let guidance: [String] = [
        "画幅与帧率",
        "时长与节奏",
        "音轨",
        "文字位置",
        "文字样式",
        "片尾卡",
        "转场与调色",
    ]
}

// MARK: - 把旧的结构化风格读成一段描述

/// 旧版本存在影片里的结构化风格（`Film.style`）。
///
/// 风格改成一段描述之后，这个类型只剩一个用途：**把已经调好的旧配置翻译成文字**，
/// 一次性写进 `Film.stylePrompt`。用户调过的风格不该因为换了表达方式就凭空消失。
///
/// 字段全部按旧版的**原始值**解（枚举解成 `String` / `Int`），所以不依赖任何旧类型；
/// 它只读不写——`Film` 的编码是手写的，落盘不会再产生 `style` 这个键。
///
/// 这是一次性的兼容层：等库里再没有带 `style` 的影片文件，整个类型可以删掉。
nonisolated struct LegacyFilmStyle: Decodable {
    private var width = 2160
    private var height = 3840
    private var fps = 30

    private var targetMinDuration = 18.0
    private var targetMaxDuration = 22.0
    private var shotMinDuration = 0.6
    private var shotMaxDuration = 2.5

    private var family = "heiti"
    private var weight = "heavy"
    private var sizeRatio = 0.044
    private var strokeRatio = 0.003
    private var colorHex = "#FFFFFF"
    private var strokeColorHex = "#000000"

    private var badgeEnabled = true
    private var badgeAnchor = "topCenter"
    private var badgeOffsetYRatio = 0.042
    private var badgeMaxLines = 1

    private var captionEnabled = true
    private var captionAnchor = "lowerThird"
    private var captionOffsetYRatio = 0.709
    private var captionMaxLines = 2

    private var tailEnabled = true
    private var tailAnchor = "center"
    private var tailOffsetYRatio = 0.5
    private var tailMaxLines = 2
    private var tailDuration = 0.7
    private var tailBackgroundHex = "#000000"
    private var tailText = "今日热量缺口：\n{value}千卡"

    private var audioSilent = false
    private var audioGain = 1.0

    private enum RootKey: String, CodingKey {
        case canvas, frameRate, pacing, typography, badge, caption, tailCard, audio
    }

    private enum PacingKey: String, CodingKey {
        case targetMinDuration, targetMaxDuration, shotMinDuration, shotMaxDuration
    }

    private enum TypographyKey: String, CodingKey {
        case family, weight, sizeRatio, strokeRatio, colorHex, strokeColorHex
    }

    private enum OverlayKey: String, CodingKey {
        case isEnabled, anchor, offsetYRatio, maxLines, text
    }

    private enum TailCardKey: String, CodingKey {
        case overlay, duration, backgroundColorHex
    }

    private enum AudioKey: String, CodingKey {
        case mode, originalGain
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKey.self)

        // 画幅在旧数据里是枚举原始值，宽高由它推出来
        if root.slValue(.canvas, default: "vertical4K") == "vertical1080" {
            width = 1080
            height = 1920
        }
        fps = root.slValue(.frameRate, default: 30)

        let pacing = try? root.nestedContainer(keyedBy: PacingKey.self, forKey: .pacing)
        targetMinDuration = pacing?.slValue(.targetMinDuration, default: 18) ?? 18
        targetMaxDuration = pacing?.slValue(.targetMaxDuration, default: 22) ?? 22
        shotMinDuration = pacing?.slValue(.shotMinDuration, default: 0.6) ?? 0.6
        shotMaxDuration = pacing?.slValue(.shotMaxDuration, default: 2.5) ?? 2.5

        let typography = try? root.nestedContainer(keyedBy: TypographyKey.self, forKey: .typography)
        family = typography?.slValue(.family, default: "heiti") ?? "heiti"
        weight = typography?.slValue(.weight, default: "heavy") ?? "heavy"
        sizeRatio = typography?.slValue(.sizeRatio, default: 0.044) ?? 0.044
        strokeRatio = typography?.slValue(.strokeRatio, default: 0.003) ?? 0.003
        colorHex = typography?.slValue(.colorHex, default: "#FFFFFF") ?? "#FFFFFF"
        strokeColorHex = typography?.slValue(.strokeColorHex, default: "#000000") ?? "#000000"

        if let badge = try? root.nestedContainer(keyedBy: OverlayKey.self, forKey: .badge) {
            badgeEnabled = badge.slValue(.isEnabled, default: true)
            badgeAnchor = badge.slValue(.anchor, default: "topCenter")
            badgeOffsetYRatio = badge.slValue(.offsetYRatio, default: 0.042)
            badgeMaxLines = badge.slValue(.maxLines, default: 1)
        }

        if let caption = try? root.nestedContainer(keyedBy: OverlayKey.self, forKey: .caption) {
            captionEnabled = caption.slValue(.isEnabled, default: true)
            captionAnchor = caption.slValue(.anchor, default: "lowerThird")
            captionOffsetYRatio = caption.slValue(.offsetYRatio, default: 0.709)
            captionMaxLines = caption.slValue(.maxLines, default: 2)
        }

        if let tail = try? root.nestedContainer(keyedBy: TailCardKey.self, forKey: .tailCard) {
            tailDuration = tail.slValue(.duration, default: 0.7)
            tailBackgroundHex = tail.slValue(.backgroundColorHex, default: "#000000")
            if let overlay = try? tail.nestedContainer(keyedBy: OverlayKey.self, forKey: .overlay) {
                tailEnabled = overlay.slValue(.isEnabled, default: true)
                tailAnchor = overlay.slValue(.anchor, default: "center")
                tailOffsetYRatio = overlay.slValue(.offsetYRatio, default: 0.5)
                tailMaxLines = overlay.slValue(.maxLines, default: 2)
                tailText = overlay.slValue(.text, default: "")
            }
        }

        if let audio = try? root.nestedContainer(keyedBy: AudioKey.self, forKey: .audio) {
            audioSilent = audio.slValue(.mode, default: "original") == "silent"
            audioGain = audio.slValue(.originalGain, default: 1)
        }
    }

    /// 翻译成一段风格描述。句式与「剪辑风格」页里让人手写的一致，
    /// 用户接手之后可以在原文上直接改。
    ///
    /// 角标与字幕只写**位置和行数**，不写文案模板——文案按新的口径由各分镜自己填。
    var promptText: String {
        var lines: [String] = []
        lines.append("竖屏 \(width)×\(height)、\(fps)fps。")
        lines.append(
            "总长 \(slShort(targetMinDuration))–\(slShort(targetMaxDuration)) 秒，"
            + "单镜 \(slShort(shotMinDuration))–\(slShort(shotMaxDuration)) 秒。"
        )
        if audioSilent {
            lines.append("成片不带音轨，静音。")
        } else {
            lines.append("保留各镜现场原声（音量 \(Int((audioGain * 100).rounded()))%）。")
        }
        if badgeEnabled {
            lines.append(
                "\(Self.anchorTitle(badgeAnchor))一行常驻角标，"
                + "文字块中心距屏顶约 \(Self.percent(badgeOffsetYRatio))，最多 \(badgeMaxLines) 行；"
                + "文字由各分镜自己填。"
            )
        }
        if captionEnabled {
            lines.append(
                "\(Self.anchorTitle(captionAnchor))屏幕字幕，"
                + "文字块中心距屏顶约 \(Self.percent(captionOffsetYRatio))，最多 \(captionMaxLines) 行；"
                + "文字由各分镜自己填。"
            )
        }
        if tailEnabled {
            let text = tailText
                .replacingOccurrences(of: "\n", with: " / ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 片尾卡是老数据里唯一「全片统一」的文案，`{value}` 是它自己的占位符。
            // 逐镜的角标已经改成整段文字，没有模板机制了，所以这里要把占位符说清楚，
            // 否则剪辑侧看到一个字面的 `{value}` 不知道填什么。
            let hint = text.contains("{value}") ? "（其中 {value} 换成当天的数字）" : ""
            lines.append(
                "片尾卡 \(slShort(tailDuration)) 秒：\(tailBackgroundHex) 底，"
                + "居中\(Self.anchorTitle(tailAnchor))、最多 \(tailMaxLines) 行，"
                + "文案「\(text)」\(hint)。"
            )
        }
        lines.append(
            "文字样式整片统一：\(Self.familyTitle(family)) · \(Self.weightTitle(weight))，"
            + "字高约占屏高 \(Self.percent(sizeRatio))，描边约占屏高 \(Self.percent(strokeRatio))，"
            + "\(colorHex) 文字 + \(strokeColorHex) 描边。"
        )
        return lines.joined(separator: "\n")
    }

    private static func anchorTitle(_ raw: String) -> String {
        switch raw {
        case "topCenter": return "顶部居中"
        case "center": return "画面正中"
        case "lowerThird": return "下三分"
        case "bottomCenter": return "底部居中"
        default: return raw
        }
    }

    private static func familyTitle(_ raw: String) -> String {
        switch raw {
        case "heiti": return "黑体"
        case "rounded": return "圆体"
        case "songti": return "宋体"
        default: return raw
        }
    }

    private static func weightTitle(_ raw: String) -> String {
        switch raw {
        case "regular": return "常规"
        case "medium": return "中等"
        case "bold": return "粗体"
        case "heavy": return "特粗"
        default: return raw
        }
    }

    /// `0.044` → `4.4%`
    private static func percent(_ ratio: Double) -> String {
        String(format: "%.1f%%", ratio * 100)
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
    /// `LegacyFilmStyle` 靠它读旧数据：旧风格是**随版本增加过字段**的结构，
    /// 合成解码器读缺键的 JSON 会整块失败，把用户已经调好的风格一起丢掉。
    func slValue<T: Decodable>(_ key: Key, default fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}
