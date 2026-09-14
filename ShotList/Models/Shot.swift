import SwiftUI

/// 一个镜头的一次拍摄产出。
///
/// 同一个镜头可以反复拍（「这条没过，再拍一条」），每次拍摄都会追加一个
/// `ShotClip`，而不是把上一条覆盖掉。拍完之后在应用里对比，或者整个导出到
/// 剪映里挑。
///
/// 模型整体是 `nonisolated`：它是纯值类型，读它不该要求主线程。
/// 只有真正绑定界面的东西才归属主协程。
nonisolated struct ShotClip: Identifiable, Codable, Hashable {
    var id: UUID
    /// 视频文件名（位于「分镜视频」目录内）
    var fileName: String
    /// 时长（秒）
    var duration: TimeInterval?
    /// 这一条的拍摄时间
    var recordedAt: Date

    init(
        id: UUID = UUID(),
        fileName: String,
        duration: TimeInterval? = nil,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.fileName = fileName
        self.duration = duration
        self.recordedAt = recordedAt
    }

    /// 「0:12」形式的时长文本
    var durationText: String? { SLTimecode.text(for: duration) }

    /// 拍摄时间文本，例如「9月14日 22:14」。用于导出清单与无障碍朗读。
    var recordedAtText: String? { SLDateText.monthDayTime(recordedAt) }

    /// 紧凑的相对时间，例如「今天 22:14」「昨天 21:46」「9月13日 21:46」
    func shortRecordedAtText(relativeTo now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = SLDateText.time(recordedAt)

        if calendar.isDate(recordedAt, inSameDayAs: now) { return "今天 \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(recordedAt, inSameDayAs: yesterday) {
            return "昨天 \(time)"
        }

        return "\(SLDateText.monthDay(recordedAt, relativeTo: now, calendar: calendar)) \(time)"
    }
}

/// 片段集合的取「最新一条」规则。
///
/// 缩略图、播放默认条、导出主素材都走这里，保证全应用只有一个口径。
/// 时间戳并列时取数组里靠后的一条：片段是按拍摄先后追加的，靠后的才是更晚拍的，
/// 而 `max(by:)` 在并列时返回的是**第一个**最大值，直接用会把老片段当成主素材。
nonisolated extension Array where Element == ShotClip {
    var latestByRecordedAt: ShotClip? {
        reversed().max { $0.recordedAt < $1.recordedAt }
    }
}

/// 一条分镜记录。
///
/// 编号 `number` 决定拍摄顺序，同时也是导出时视频文件名与清单的前缀，
/// 因此在列表内始终按数组顺序连续编号（1、2、3…）。
nonisolated struct Shot: Identifiable, Codable, Hashable {
    var id: UUID
    /// 镜头编号，从 1 开始连续编号
    var number: Int
    /// 分镜描述：这个镜头要拍什么（运镜方式、口播要点、道具…）
    var note: String
    /// 这个镜头拍过的全部片段，按拍摄先后排列
    var clips: [ShotClip]

    enum CodingKeys: String, CodingKey {
        case id
        case number
        case note
        case clips
    }

    init(
        id: UUID = UUID(),
        number: Int,
        note: String = "",
        clips: [ShotClip] = []
    ) {
        self.id = id
        self.number = number
        self.note = note
        self.clips = clips
    }
}

// MARK: - 兼容旧版本数据

nonisolated extension Shot {
    private enum LegacyKeys: String, CodingKey {
        case title
        case clipFileName
        case recordedAt
        case clipDuration
    }

    /// 早期版本每个镜头只存一段视频（`clipFileName` / `clipDuration` / `recordedAt`），
    /// 读取时自动折算成一条片段；`title` 字段已经废弃，直接忽略。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        number = try container.decodeIfPresent(Int.self, forKey: .number) ?? 1
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""

        if let stored = try container.decodeIfPresent([ShotClip].self, forKey: .clips), !stored.isEmpty {
            clips = stored.sorted { $0.recordedAt < $1.recordedAt }
            return
        }

        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        if let fileName = try legacy.decodeIfPresent(String.self, forKey: .clipFileName) {
            clips = [
                ShotClip(
                    fileName: fileName,
                    duration: try legacy.decodeIfPresent(TimeInterval.self, forKey: .clipDuration),
                    recordedAt: try legacy.decodeIfPresent(Date.self, forKey: .recordedAt) ?? Date()
                )
            ]
        } else {
            clips = []
        }
    }
}

// MARK: - 派生属性

nonisolated extension Shot {
    /// 这个镜头是否至少拍过一条
    var hasClip: Bool { !clips.isEmpty }

    /// 拍了几条
    var clipCount: Int { clips.count }

    /// 最近拍的那一条。卡片缩略图、播放与导出主素材都以它为准。
    var latestClip: ShotClip? {
        clips.latestByRecordedAt
    }

    /// 两位编号，例如 01、02
    var paddedNumber: String { String(format: "%02d", number) }

    /// 备注是否为空
    var hasNote: Bool { !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 界面上展示的描述文本，为空时回退为「镜头 N」
    var displayDetail: String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "镜头 \(number)" : trimmed
    }

    /// 导出文件名用的描述，为空时回退为「镜头」
    var fileNameBase: String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "镜头" : trimmed
    }

    /// 最近一条的时长文本
    var durationText: String? { latestClip?.durationText }

    /// 主素材（最近一条）的文件扩展名。
    ///
    /// 相册导入的视频保留原本的扩展名（mov、mp4…），导出命名必须跟着走，
    /// 不能一律写成 `.mov`，否则容器与扩展名不符。没有片段时按 `mov` 兜底。
    var mainFileExtension: String {
        let ext = ((latestClip?.fileName ?? "") as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "mov" : ext
    }

    /// 最近一条的拍摄时间文本（完整）
    var recordedAtText: String? { latestClip?.recordedAtText }

    /// 最近一条的紧凑时间，卡片上用它，避免完整日期在窄栏里被截断
    var shortRecordedAtText: String? { latestClip?.shortRecordedAtText() }

    /// 这个镜头全部片段的总时长
    var totalDuration: TimeInterval {
        clips.reduce(0) { $0 + ($1.duration ?? 0) }
    }

    /// 相对今日的拍摄状态（以最近一条为准）
    func status(relativeTo date: Date = Date(), calendar: Calendar = .current) -> ShotStatus {
        guard let latest = latestClip else { return .notShot }
        return calendar.isDate(latest.recordedAt, inSameDayAs: date) ? .shotToday : .shotEarlier
    }
}

// MARK: - 日期格式化

/// 日期文本统一走这里，卡片、面板与导出清单保持同一套写法。
///
/// 年份是不常变化的信息，日常翻看时属于噪声，因此**同年一律不写年份**，
/// 只有跨年时才补上——既短，又不会产生歧义。
nonisolated enum SLDateText {
    /// 「22:14」
    static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().hour().minute().locale(AppLocale.current))
    }

    /// 「9月14日」；跨年时是「2025年9月14日」
    ///
    /// 月份用 `.wide` 而不是 `.defaultDigits`：后者在中文下会输出 `9/14` 这种数字写法。
    static func monthDay(
        _ date: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        var style = Date.FormatStyle()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return date.formatted(
            style.month(.wide).day().locale(AppLocale.current)
        )
    }

    /// 「9月14日 22:14」
    static func monthDayTime(
        _ date: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        "\(monthDay(date, relativeTo: now, calendar: calendar)) \(time(date))"
    }

    /// 「9月14日 星期一」
    static func monthDayWeekday(_ date: Date) -> String {
        let day = date.formatted(
            Date.FormatStyle().month(.wide).day().locale(AppLocale.current)
        )
        let weekday = date.formatted(
            Date.FormatStyle().weekday(.wide).locale(AppLocale.current)
        )
        return "\(day) \(weekday)"
    }
}

// MARK: - 时长格式化

/// 时长文本统一走这里，卡片、播放页与导出清单保持一致。
nonisolated enum SLTimecode {
    /// 「0:12」形式；没有有效时长时返回 nil
    static func text(for duration: TimeInterval?) -> String? {
        guard let duration, duration > 0 else { return nil }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 拍摄状态

/// 镜头拍摄状态。
///
/// 状态始终同时用「图标 + 文字 + 颜色」三重信息表达，
/// 保证色觉识别障碍用户同样能够区分。
nonisolated enum ShotStatus: String, CaseIterable, Identifiable {
    /// 还没有拍
    case notShot
    /// 今天拍的
    case shotToday
    /// 今天以前拍的
    case shotEarlier

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notShot: return "未拍"
        case .shotToday: return "今日已拍"
        case .shotEarlier: return "往日已拍"
        }
    }

    var symbolName: String {
        switch self {
        case .notShot: return "circle.dashed"
        case .shotToday: return "checkmark.circle.fill"
        case .shotEarlier: return "clock.badge.checkmark"
        }
    }

    /// 语义色。`Color.indigo` 与绿色差异明显，避免「往日已拍」与「今日已拍」混淆。
    var tint: Color {
        switch self {
        case .notShot: return .orange
        case .shotToday: return .green
        case .shotEarlier: return .indigo
        }
    }
}

nonisolated extension Shot {
    /// 无障碍朗读文本：一次读完编号、描述、拍摄状态与片段数量。
    var accessibilityDescription: String {
        var parts: [String] = ["镜头 \(number)"]
        if hasNote { parts.append(displayDetail) }
        parts.append(status().title)
        if clipCount > 1 { parts.append("共 \(clipCount) 段") }
        if let durationText { parts.append("最近一段时长 \(durationText)") }
        return parts.joined(separator: "，")
    }

    var accessibilityActionHint: String {
        hasClip ? "查看、播放或分享拍好的片段" : "添加视频：用相机拍摄或从相册导入"
    }
}
