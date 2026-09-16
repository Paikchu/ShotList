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
    /// 这部影片的剪辑风格：怎么剪、哪些样式是全局的。
    ///
    /// 挂在影片上而不是全局偏好里：它是「这一次创作要什么样子」，
    /// 换一部影片（重制 / 新建）就该回到默认，而不是把上一部片子的
    /// 字号和片尾卡带到新片里。
    var style: FilmStyle
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
        style: FilmStyle = FilmStyle(),
        shots: [Shot] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.style = style
        self.shots = shots
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case style
        case shots
        case createdAt
        case updatedAt
    }

    /// 手写解码而不是用合成的那个：`style` 是后加的字段，库里已有的影片 JSON
    /// 里没有它。合成解码器遇到缺键会整份抛错，那会把**所有**影片一起读不出来；
    /// 逐字段兜底之后，老数据只是拿到一套默认风格。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        style = ((try? container.decodeIfPresent(FilmStyle.self, forKey: .style)) ?? nil) ?? FilmStyle()
        shots = try container.decodeIfPresent([Shot].self, forKey: .shots) ?? []
        let now = Date()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
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

    /// 什么都没写：没有镜头、也没有标题，剪辑风格也是默认的那套。
    ///
    /// 「切换影片」「重制」时按这个口径静默回收，否则影片库会堆一堆
    /// 用户早就忘了的空壳。
    ///
    /// 调过风格的影片**不算空壳**：用户可能先把风格配好、再去拍，
    /// 按「无分镜 + 无标题」回收会把刚配好的那份风格一起丢掉。
    var isBlank: Bool { shots.isEmpty && !hasTitle && style == .standard }

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

    /// 「未开始」「3/5 已拍」这类进度文字。
    ///
    /// 已拍数由调用方给（磁盘口径），这样影片条、下拉项与导出页永远同一个数字。
    func progressText(recordedCount: Int) -> String {
        if shots.isEmpty { return "未开始" }
        if recordedCount >= shots.count { return "\(shots.count)/\(shots.count) 已拍完" }
        return "\(recordedCount)/\(shots.count) 已拍"
    }

    /// 影片条与下拉项上的副行，例如「9月14日更新 · 2/5 已拍」
    func subtitleText(recordedCount: Int) -> String {
        "\(SLDateText.monthDay(updatedAt))更新 · \(progressText(recordedCount: recordedCount))"
    }

    /// 导出包名里用的标题片段；没有标题时返回空串，由调用方退回纯日期命名
    var exportTitleToken: String { trimmedTitle }
}
