import Foundation

/// 导出时带上的影片模板：名称与模板文字。
///
/// 模板文字里的标签（「字幕：」「上方角标：」这类行首词）决定了这部影片的内容是按哪几个标签写的，
/// 剪辑侧据此才知道哪几行要上屏。挂在导出请求上，与范围、格式一样是「这次导出要导什么」。
nonisolated struct ExportTemplate: Sendable, Equatable {
    let name: String
    let content: String
}

/// 导出包里的 `manifest.json`：逐镜内容原文 + 每条素材的实测参数，给剪辑工具按字段读。
///
/// 与包内三个文本文件的分工：`分镜清单.csv` 和 `导出说明.txt` 给人看，`AGENTS.md` 写怎么剪，
/// 这一份只管**事实**——时长、尺寸、帧率、HDR、音轨这些必须精确、可解析，
/// 不能让剪辑侧从给人看的「0:02」这类取整文本里去猜。
nonisolated struct ExportManifest: Codable, Sendable, Equatable {
    /// 字段含义变了就加 1，剪辑侧据此判断自己认不认得这一份
    let schemaVersion: Int
    let package: PackageInfo
    let film: FilmInfo
    let shots: [ShotEntry]

    nonisolated struct PackageInfo: Codable, Sendable, Equatable {
        let exportedAt: Date
        /// `recordedOnly` / `everything`
        let scope: String
        /// `original` / `compatible` / `compact`
        let format: String
    }

    nonisolated struct FilmInfo: Codable, Sendable, Equatable {
        let id: UUID?
        let title: String
        let template: TemplateInfo?
        /// 本片内容里实际用到的标签，按模板里的顺序
        let labels: [String]
        let hasStylePrompt: Bool

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encode(template, forKey: .template)
            try container.encode(labels, forKey: .labels)
            try container.encode(hasStylePrompt, forKey: .hasStylePrompt)
        }
    }

    nonisolated struct TemplateInfo: Codable, Sendable, Equatable {
        let name: String
        let content: String
    }

    nonisolated struct ShotEntry: Codable, Sendable, Equatable {
        let id: UUID
        let number: Int
        /// `recorded` / `notShot`
        let status: String
        /// 内容原文，逐字逐行照抄，不做任何解析
        let note: String
        let clips: [ClipEntry]
    }

    nonisolated struct ClipEntry: Codable, Sendable, Equatable {
        let id: UUID
        /// 这个镜头的第几条（缺失素材时留空号，与文件名里的片段序号一致）
        let take: Int
        /// `main`（根目录里的主素材）/ `alternate`（备用片段）
        let role: String
        /// 包内相对路径
        let path: String
        /// 这一条加入 App 的时间。相册导入的素材，它不是拍摄时间，拍摄时间看 `capturedAt`。
        let addedAt: Date
        let capturedAt: Date?
        let duration: Double?
        let sizeBytes: Int64?
        let video: VideoTrackInfo?
        let audio: [AudioTrackInfo]
        let preferredAudioIndex: Int?

        /// 同 `VideoTrackInfo.encode(to:)`：读不出来的字段写 `null`，键不能消失。
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(take, forKey: .take)
            try container.encode(role, forKey: .role)
            try container.encode(path, forKey: .path)
            try container.encode(addedAt, forKey: .addedAt)
            try container.encode(capturedAt, forKey: .capturedAt)
            try container.encode(duration, forKey: .duration)
            try container.encode(sizeBytes, forKey: .sizeBytes)
            try container.encode(video, forKey: .video)
            try container.encode(audio, forKey: .audio)
            try container.encode(preferredAudioIndex, forKey: .preferredAudioIndex)
        }
    }
}

// MARK: - 落盘

nonisolated extension ExportManifest {
    /// 时间一律写成带时区的 ISO 8601：给人看的「9月18日 22:14」少了年份与时区，机器读不出确切时刻。
    static var encoder: JSONEncoder {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    func jsonData() throws -> Data {
        var data = try Self.encoder.encode(self)
        data.append(0x0A)
        return data
    }
}

// MARK: - 标签

/// 模板与镜头内容里的「标签：内容」。
///
/// 标签只认模板里出现过的那些：内容里带冒号的普通句子（「热量缺口：1758千卡」）不能被当成标签，
/// 否则剪辑侧会把半句话当成一个新图层。
nonisolated enum ExportLabels {

    /// 模板文字里的标签名，按模板里的顺序，去重。
    static func names(in template: String) -> [String] {
        var names: [String] = []
        for line in template.components(separatedBy: .newlines) {
            guard let name = labelName(of: line), !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    /// 本片实际用到的标签：模板里有、且至少一个镜头的内容用它起过行。
    ///
    /// 绑定的模板排在前面——那是这部影片写内容时照着的那一份。
    static func used(in shots: [Shot], boundTemplate: ExportTemplate?, templates: [ExportTemplate]) -> [String] {
        var candidates: [String] = []
        for template in ([boundTemplate].compactMap { $0 } + templates) {
            for name in names(in: template.content) where !candidates.contains(name) {
                candidates.append(name)
            }
        }
        return candidates.filter { name in
            shots.contains { shot in
                shot.note.components(separatedBy: .newlines).contains { isLabelLine($0, name) }
            }
        }
    }

    /// 按 AGENTS.md 的规则把一段内容拆成「标签 → 文字」：
    /// 标签后面的空格与紧跟的换行不算内容，行尾空格去掉，其余换行原样保留；
    /// 一个标签的内容一直到下一个标签行为止。第一个标签行之前的文字是描述，不在结果里。
    static func labeled(_ note: String, labels: [String]) -> [(label: String, text: String)] {
        var result: [(label: String, text: String)] = []
        var current: String?
        var lines: [String] = []

        func flush() {
            guard let label = current else { return }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append((label, text))
            }
            lines = []
        }

        for line in note.components(separatedBy: .newlines) {
            if let label = labels.first(where: { isLabelLine(line, $0) }) {
                flush()
                current = label
                let rest = String(line.dropFirst(label.count + 1)).trimmingCharacters(in: .whitespaces)
                lines = rest.isEmpty ? [] : [rest]
            } else if current != nil {
                lines.append(line.replacingOccurrences(of: "[ \t]+$", with: "", options: .regularExpression))
            }
        }
        flush()
        return result
    }

    /// 一行是不是这个标签的标签行：以「标签」加全角或半角冒号开头
    private static func isLabelLine(_ line: String, _ label: String) -> Bool {
        line.hasPrefix(label + "：") || line.hasPrefix(label + ":")
    }

    /// 一行的标签名：第一个冒号（全角或半角）前面的字，没有冒号或冒号在最前面时为 `nil`
    private static func labelName(of line: String) -> String? {
        guard let colon = line.firstIndex(where: { $0 == "：" || $0 == ":" }) else { return nil }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
