import SwiftUI

/// 一条分镜记录。
///
/// 编号 `number` 决定拍摄顺序，同时也是导出时视频文件名与清单的前缀，
/// 因此在列表内始终按数组顺序连续编号（1、2、3…）。
struct Shot: Identifiable, Codable, Hashable {
    var id: UUID
    /// 镜头编号，从 1 开始连续编号
    var number: Int
    /// 镜头标题，例如「开场：城市天际线」
    var title: String
    /// 拍摄备注，例如运镜方式、口播要点
    var note: String
    /// 已拍摄视频的文件名（位于「分镜视频」目录内）
    var clipFileName: String?
    /// 完成拍摄的时间
    var recordedAt: Date?
    /// 视频时长（秒）
    var clipDuration: TimeInterval?

    init(
        id: UUID = UUID(),
        number: Int,
        title: String = "",
        note: String = "",
        clipFileName: String? = nil,
        recordedAt: Date? = nil,
        clipDuration: TimeInterval? = nil
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.note = note
        self.clipFileName = clipFileName
        self.recordedAt = recordedAt
        self.clipDuration = clipDuration
    }
}

// MARK: - 派生属性

extension Shot {
    /// 是否已经拍了视频
    var hasClip: Bool { clipFileName != nil }

    /// 展示用标题：标题为空时回退为「镜头 N」
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "镜头 \(number)" : trimmed
    }

    /// 两位编号，例如 01、02
    var paddedNumber: String { String(format: "%02d", number) }

    /// 备注是否为空
    var hasNote: Bool { !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 「0:12」形式的时长文本
    var durationText: String? {
        guard let clipDuration, clipDuration > 0 else { return nil }
        let total = Int(clipDuration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 拍摄时间文本
    var recordedAtText: String? {
        guard let recordedAt else { return nil }
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened)
            .locale(AppLocale.current)
        return recordedAt.formatted(style)
    }

    /// 相对今日的拍摄状态
    func status(relativeTo date: Date = Date(), calendar: Calendar = .current) -> ShotStatus {
        guard hasClip, let recordedAt else { return .notShot }
        return calendar.isDate(recordedAt, inSameDayAs: date) ? .shotToday : .shotEarlier
    }
}

// MARK: - 拍摄状态

/// 镜头拍摄状态。
///
/// 状态始终同时用「图标 + 文字 + 颜色」三重信息表达，
/// 保证色觉识别障碍用户同样能够区分。
enum ShotStatus: String, CaseIterable, Identifiable {
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

    var isRecorded: Bool { self != .notShot }
}

extension Shot {
    /// 无障碍朗读文本：一次读完编号、标题、状态与可执行动作。
    var accessibilityDescription: String {
        var parts: [String] = ["镜头 \(number)"]
        if hasNote || !title.isEmpty { parts.append(displayTitle) }
        parts.append(status().title)
        if let durationText { parts.append("时长 \(durationText)") }
        return parts.joined(separator: "，")
    }

    var accessibilityActionHint: String {
        hasClip ? "查看、替换或分享这段视频" : "添加视频：用相机拍摄或从相册导入"
    }
}
