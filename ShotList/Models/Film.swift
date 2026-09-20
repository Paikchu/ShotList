import Foundation

/// 一部影片 = 一次创作。
///
/// 「影片」是分镜之上的那一层。引入它之前，应用只有一份全局分镜清单，
/// 于是「重制」无处归档、「历史找回」没有可切换的对象、「每部影片一个标题」
/// 也没有挂靠的地方。补上这一层之后：
///
/// - 「重制」与「新建影片」在数据上是同一个动作；
/// - 「历史找回」不是复制数据，而是把 `FilmLibrary.currentFilmID` 切过去；
/// - 日期从「数据的组织轴」退化为影片的一个属性（`updatedAt`）。
///
/// 模型是纯值类型且 `nonisolated`：读它不该要求主线程。
nonisolated struct Film: Identifiable, Codable, Hashable {
    var id: UUID
    /// 影片标题。可以为空——空标题在界面上显示为「未命名影片」。
    var title: String
    /// 这部影片的剪辑风格：**一段描述**，怎么剪、哪些样式是全局的，都用自然语言写。
    ///
    /// 导出时原样写进 `剪辑风格.md` 交给剪辑工具。消费它的本来就是能读自然语言的
    /// 工具，所以这里不放固定选项——见 `FilmStylePrompt`。
    ///
    /// 挂在影片上而不是全局偏好里：它是「这一次创作要什么样子」，
    /// 换一部影片（重制 / 新建）就该重新写，而不是把上一部片子的要求带到新片里。
    var stylePrompt: String
    /// 这部影片的分镜模板：**一段纯文字**，镜头面板里「应用模板」时原样填进内容框。
    ///
    /// 空串表示没有自定义，用 `Film.defaultShotTemplate`。挂在影片上而不是全局偏好里：
    /// 每部片子要写的标签不同（有的要转场、有的只要字幕），换一部影片就该各用各的。
    var shotTemplate: String
    /// 这部影片的分镜，编号在影片内从 1 连续编排
    var shots: [Shot]
    var createdAt: Date
    /// 最后一次**用户编辑**的时间（增删改镜头、增删片段、改标题）。
    ///
    /// 自动的磁盘校正（`refreshStorageStats()` 发现外部删了文件）**不**刷新它：
    /// 用户什么都没做，影片在库里的排序不该因此往前跳。
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        stylePrompt: String = "",
        shotTemplate: String = "",
        shots: [Shot] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.stylePrompt = stylePrompt
        self.shotTemplate = shotTemplate
        self.shots = shots
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case stylePrompt
        case shotTemplate
        case shots
        case createdAt
        case updatedAt
        /// 旧版本的结构化风格。**只读不写**：解码时用来补出 `stylePrompt`，
        /// 编码走手写的 `encode(to:)`，不会再产生这个键。
        case legacyStyle = "style"
    }

    /// 手写解码而不是用合成的那个：`stylePrompt`、`shotTemplate` 是后加的字段，库里已有的
    /// 影片 JSON 里没有它们。合成解码器遇到缺键会整份抛错，那会把**所有**影片一起读不出来。
    ///
    /// 老数据分两种，都要接住：
    /// - 只有标题和分镜 → 风格留空，用户自己写；
    /// - 存着旧的结构化风格 → 翻译成一段描述写进去，别让调好的风格凭空消失。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""

        let stored = (try container.decodeIfPresent(String.self, forKey: .stylePrompt) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty {
            stylePrompt = stored
        } else if let legacy = (try? container.decodeIfPresent(LegacyFilmStyle.self, forKey: .legacyStyle)) ?? nil {
            stylePrompt = legacy.promptText
        } else {
            stylePrompt = ""
        }

        shotTemplate = (try container.decodeIfPresent(String.self, forKey: .shotTemplate) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        shots = try container.decodeIfPresent([Shot].self, forKey: .shots) ?? []
        let now = Date()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    /// 手写编码：只写 `stylePrompt`，不再写旧的 `style` 键。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(stylePrompt, forKey: .stylePrompt)
        try container.encode(shotTemplate, forKey: .shotTemplate)
        try container.encode(shots, forKey: .shots)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

/// 落盘结构：影片库 + 「当前影片」指针。
///
/// 指针与影片放在同一份文件里，是为了让「切到哪部影片」和「影片内容」一起
/// 原子落盘——分成两个文件就可能出现「指针指向一部不存在的影片」。
nonisolated struct FilmLibrary: Codable {
    var films: [Film]
    var currentFilmID: UUID?

    init(films: [Film] = [], currentFilmID: UUID? = nil) {
        self.films = films
        self.currentFilmID = currentFilmID
    }
}

/// 一部影片的磁盘口径统计。
///
/// 口径与导出包一致：只数**磁盘上确实存在**的片段。若按 JSON 里的 `hasClip` 算，
/// 一旦出现「记录还在、文件已经不在磁盘上」（外部删除 / 拷贝中断 / 备份恢复），
/// 界面会显示已拍、导出却给不出文件。
nonisolated struct FilmStats: Equatable {
    var shotCount = 0
    var clipCount = 0
    var duration: TimeInterval = 0
    var bytes: Int64 = 0

    static let empty = FilmStats()
}

// MARK: - 派生属性

nonisolated extension Film {
    /// 标题去掉首尾空白后的样子
    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var hasTitle: Bool { !trimmedTitle.isEmpty }

    /// 界面上展示的标题；未填时回退为「未命名影片」
    var displayTitle: String { hasTitle ? trimmedTitle : "未命名影片" }

    /// 一个镜头都还没写
    var isUnstarted: Bool { shots.isEmpty }

    /// 风格描述写完没有。留空就是「这部片子没特别要求」，
    /// 导出包里不会出现 `剪辑风格.md`。
    var hasStylePrompt: Bool { !stylePrompt.isEmpty }

    /// 没有自定义模板时用的默认模板：四行标签，标签后面留给用户写具体内容。
    static let defaultShotTemplate = "描述：\n字幕：\n上方角标：\n转场："

    /// 写过自己的模板没有。空串就是没写，用默认模板。
    var hasShotTemplate: Bool { !shotTemplate.isEmpty }

    /// 「应用模板」时真正填进去的文字：自定义的，没有就用默认的
    var effectiveShotTemplate: String { hasShotTemplate ? shotTemplate : Self.defaultShotTemplate }

    /// 什么都没写：没有镜头、没有标题，也没写风格描述与模板。
    ///
    /// 「切换影片」「重制」时按这个口径静默回收，否则影片库会堆一堆
    /// 用户早就忘了的空壳。
    ///
    /// 写过风格或模板的影片**不算空壳**：用户可能先把要求写好、再去拍，
    /// 按「无分镜 + 无标题」回收会把刚写好的那段一起丢掉。
    var isBlank: Bool { shots.isEmpty && !hasTitle && !hasStylePrompt && !hasShotTemplate }

    /// 这部影片的全部片段（跨镜头）
    var allClips: [ShotClip] { shots.flatMap(\.clips) }

    /// 这部影片引用到的全部片段文件名
    var clipFileNames: [String] { allClips.map(\.fileName) }

    /// 这一部影片是否引用了某个文件。
    ///
    /// 「未使用文件」的判据要覆盖**全部**影片：只看当前影片的话，切到影片 B
    /// 时影片 A 的素材会被判成孤儿，用户点一次清理就永久删掉了它们。
    static func referencedFileNames(in films: [Film]) -> Set<String> {
        Set(films.flatMap(\.clipFileNames))
    }

    /// 「3/5」这类进度数字，前面配一个勾选图标，不再写「已拍」。
    ///
    /// 已拍数由调用方给（磁盘口径），这样影片条、下拉项与导出页永远同一个数字。
    func progressText(recordedCount: Int) -> String {
        "\(min(recordedCount, shots.count))/\(shots.count)"
    }

    /// 导出包名里用的标题片段；没有标题时返回空串，由调用方退回纯日期命名
    var exportTitleToken: String { trimmedTitle }
}
