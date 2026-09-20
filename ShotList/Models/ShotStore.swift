import Foundation
import SwiftUI

nonisolated enum ShotStoreError: LocalizedError {
    case targetMissing
    var errorDescription: String? { "镜头已被删除" }
}

/// 让整个界面停下来的存储失败。
///
/// 带上类别是因为「读不出记录」和「删除收尾没做完」是两回事：前者数据本身不可用，
/// 后者记录读得好好的，只是清理没做完。共用一句话的话，错误页只能写一个
/// 对不上正文的标题，也没法告诉用户「记录没丢」。
nonisolated struct LoadFailure {
    enum Kind {
        /// `films.json` 读不出来，或素材还在却一份记录都没有
        case unreadable
        /// 旧版 `shots.json` 升级失败，原文件原样保留
        case upgradeFailed
        /// 记录读得好好的，只是删除补偿日志没清理完；重试会重走一次清理
        case deletionPending
    }

    let kind: Kind
    let message: String

    static func deletionPending(_ error: Error) -> LoadFailure {
        LoadFailure(
            kind: .deletionPending,
            message: "记录未丢失。请检查存储空间后重试。\n\(error.localizedDescription)"
        )
    }
}

/// 分镜数据仓库。
///
/// 职责：
/// - 维护内存中的**影片库**，并持久化为 JSON（Application Support/ShotList/films.json）
/// - 管理磁盘上的分镜片段文件（Documents/分镜视频）
///
/// 由于 Documents 目录对「文件」App 与 Finder 可见（Info.plist 中开启了
/// `UIFileSharingEnabled` 与 `LSSupportsOpeningDocumentsInPlace`），
/// 用户可以直接把拍摄好的分镜片段拖到电脑上。
///
/// 一个镜头可以拍很多条，每条都是独立的文件，互不覆盖。
/// 一部影片可以有很多镜头，镜头编号在**影片内**从 1 连续编排。
///
/// ## 影片与「当前影片」
///
/// 任一时刻只有一部「当前影片」，它就是分镜页正在编辑的那一部。
/// 切换影片不是覆盖——旧影片原样留在库里，随时可以切回来继续拍。
///
/// ## 为什么 `shots` 是只读计算属性
///
/// 视图层（分镜页 / 历史页 / 导出页 / 标签栏）原先读的是 `store.shots`，
/// 改造后仍然读 `store.shots`，只是它的含义变成「当前影片的镜头」。
/// 视图因此几乎不用改。重绘由 `films`、`currentFilmID` 的 `@Published` 驱动——
/// 它们一发出变更，视图 `body` 重算时重新求值 `shots`，拿到的就是新数据。
///
/// 内部写入走 `mutateCurrentFilm`（用户编辑，刷新 `updatedAt`）与
/// `repairCurrentFilm`（磁盘自愈，**不**刷新 `updatedAt`）两条路。区分是必要的：
/// 用户从「文件」App 里删了个视频，影片在库里的排序不该因此跳到最前。
@MainActor
final class ShotStore: ObservableObject {

    // MARK: - 影片库

    /// 全部影片
    @Published private(set) var films: [Film] = []

    /// 当前影片的 id。任一时刻只有一部。
    @Published private(set) var currentFilmID: UUID?

    /// 每部影片的磁盘口径统计。由 `applySnapshot` 在刷新时一次算好，
    /// 视图读的是缓存——`body` 里不做跨 N 个片段的同步文件 I/O。
    @Published private(set) var filmStats: [Film.ID: FilmStats] = [:]

    @Published private(set) var loadError: LoadFailure?

    @Published var saveError: String?
    private var committedFilms: [Film] = []
    private var committedCurrentFilmID: UUID?
    private var stagedFileNames: Set<String> = []

    private let fileManager: FileManager
    private let mediaFileCopy: MediaFileCopy
    private let metadataURL: URL
    /// 旧版元数据。只在升级路径上读一次，随后改名为 `shots.json.migrated`。
    private var legacyMetadataURL: URL { metadataURL.deletingLastPathComponent().appendingPathComponent("shots.json") }
    /// 升级后保留的旧文件。它就是回滚保险：把名字改回去，旧版本应用即可正常读取。
    private var migratedMetadataURL: URL { metadataURL.deletingLastPathComponent().appendingPathComponent("shots.json.migrated") }
    /// 字幕、角标并进描述之前的 `films.json` 原文。见 `backUpBeforeTextMerge`。
    private var preMergeBackupURL: URL { metadataURL.deletingLastPathComponent().appendingPathComponent("films.json.before-merge") }
    private var deletionRecoveryURL: URL { metadataURL.deletingLastPathComponent().appendingPathComponent("pending-deletions.json") }

    /// 分镜片段统一存放目录
    let clipsDirectory: URL

    private static let clipNamePrefix = "镜头"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.mediaFileCopy = MediaFileCopy(fileManager: fileManager)

        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? documents

        let supportDirectory = applicationSupport.appendingPathComponent("ShotList", isDirectory: true)
        self.clipsDirectory = documents.appendingPathComponent("分镜视频", isDirectory: true)
        self.metadataURL = supportDirectory.appendingPathComponent("films.json", isDirectory: false)

        createDirectoryIfNeeded(supportDirectory)
        createDirectoryIfNeeded(clipsDirectory)
        load()
        applyLaunchFilmSelection()
    }

    // MARK: - 影片

    /// 当前影片。库里永远至少有一部，所以正常路径下不为 nil。
    var currentFilm: Film? {
        guard let currentFilmID else { return films.first }
        return films.first { $0.id == currentFilmID } ?? films.first
    }

    private var currentFilmIndex: Int? {
        guard let currentFilmID, let index = films.firstIndex(where: { $0.id == currentFilmID }) else {
            return films.indices.first
        }
        return index
    }

    /// 影片库：最近编辑过的排在最前。下拉菜单与影片库页都按这个顺序。
    var sortedFilms: [Film] {
        films.sorted { $0.updatedAt > $1.updatedAt }
    }

    func film(withID id: Film.ID) -> Film? {
        films.first { $0.id == id }
    }

    /// 某部影片的磁盘口径统计
    func stats(of film: Film) -> FilmStats { filmStats[film.id] ?? .empty }

    /// 某部影片已拍好的镜头数（磁盘口径）
    func recordedCount(of film: Film) -> Int { stats(of: film).shotCount }

    // MARK: - 当前影片的分镜

    /// 当前影片的分镜。
    ///
    /// **只读**对外接口：写入一律经 `mutateCurrentFilm` / `repairCurrentFilm`，
    /// 免得「改了分镜却没刷新影片更新时间」这类不一致悄悄发生。
    var shots: [Shot] { currentFilm?.shots ?? [] }

    /// 用户编辑引起的写入：同时把影片的最后更新时间推到此刻。
    ///
    /// 全应用只有这一条「写当前影片」的路。磁盘自愈（`reconcileClipsWithDisk`）
    /// 不经过这里——它直接改 `films`，**不**刷新 `updatedAt`：自愈不是用户编辑，
    /// 把它算进「最后更新」会让影片库的排序莫名其妙地跳。
    private func mutateCurrentFilm(_ body: (inout Film) -> Void) {
        guard let index = currentFilmIndex else { return }
        body(&films[index])
        films[index].updatedAt = Date()
    }

    // MARK: - 统计

    /// 「已拍」的磁盘口径：磁盘上确实存在、且被当前影片引用到的素材。
    ///
    /// 这三个数字与 `totalClipBytes`、导出包是**同一个口径**——都来自
    /// `refreshStorageStats()` 的那一次目录枚举。导出页读的就是它们：
    /// 若按 JSON 里的 `hasClip` 算，一旦出现「记录还在、文件已经不在磁盘上」
    /// （外部删除 / 拷贝中断 / 备份恢复），按钮仍然可点，最后会导出一个
    /// 一个视频都没有的空包。
    ///
    /// 枚举失败时保留上一次的值（见 `applySnapshot`），不会突然报 0。
    @Published private(set) var availableShotCount: Int = 0
    @Published private(set) var availableClipCount: Int = 0
    @Published private(set) var availableDuration: TimeInterval = 0

    /// 当前影片已经拍过的镜头数量（以磁盘上真的有文件为准）
    var recordedCount: Int { availableShotCount }

    /// 某个分镜是否「已拍」：至少有一条片段的文件确实在磁盘上。
    ///
    /// 全应用「已拍 / 未拍」只认这一个判据：每部影片的统计（`applySnapshot`）、
    /// 进度环、历史页与导出页的镜头列表都读它，导出包筛镜头也是同一条规则。
    /// 不要用 `Shot.hasClip`——它只看 JSON 里有没有记录，一旦「记录还在、文件不在磁盘上」
    /// （目录枚举失败时记录原样保留、写盘失败回滚旧记录），就会和进度环对不上。
    func isRecorded(_ shot: Shot) -> Bool {
        shot.clips.contains { existingClipFileNames.contains($0.fileName) }
    }

    /// 当前影片里已拍的镜头（磁盘口径）
    var recordedShots: [Shot] { shots.filter(isRecorded) }

    /// 当前影片里未拍的镜头（磁盘口径）。与 `recordedShots` 不重不漏，合起来就是 `shots`
    var pendingShots: [Shot] { shots.filter { !isRecorded($0) } }

    /// 当前影片的全部片段数量（只数磁盘上真的有文件的那几条）
    var clipCount: Int { availableClipCount }

    /// 当前影片全部片段的总时长（秒，只算磁盘上真的有文件的那几条）
    var totalDuration: TimeInterval { availableDuration }

    /// 当前影片的片段占用空间（字节）。
    ///
    /// 只统计**被当前影片引用到、且真的在磁盘上**的片段，因此和旁边那几个数字
    /// （已拍镜头数、段数、总时长）是同一个口径。目录里的未使用文件另有
    /// `orphanBytes`，两者相加才是这个目录真正占的磁盘。
    ///
    /// 这是**缓存值**，由 `refreshStorageStats()` 在启动与数据变更时刷新。
    /// 视图每次重绘都会读它，若在这里现算，一次重绘就要跨 N 个片段发系统调用
    /// （导出页连无障碍值要读两遍，就是 2×N 次）。
    @Published private(set) var totalClipBytes: Int64 = 0

    /// 目录里有、但**任何影片**都没有引用的文件。
    ///
    /// `Documents` 对「文件」App 与访达开放，用户完全可以把视频直接拖进来；
    /// 这些文件不进 JSON，于是既不出现在界面上，也不被导出带走。它们确实占着
    /// 磁盘，所以这里把它们找出来，交给导出页做一个清理入口——不然用户看不到
    /// 它们，也没有任何办法回收。
    ///
    /// 判据必须覆盖全部影片：只看当前影片的话，切到影片 B 时影片 A 的素材会被
    /// 算成未使用，用户点一次清理就永久删掉了它们。
    @Published private(set) var orphanFileNames: [String] = []

    /// 未使用文件占用的空间（字节）
    @Published private(set) var orphanBytes: Int64 = 0

    /// 未使用文件的数量
    var orphanFileCount: Int { orphanFileNames.count }

    /// 磁盘上实际存在的片段文件名。
    ///
    /// `clipURL(for:)` 被视图高频调用，每次都 `fileExists` 太贵，
    /// 改为在刷新统计时扫一遍目录缓存下来。
    private var existingClipFileNames: Set<String> = []

    /// 拍摄进度 0…1（按磁盘上真的有片段的镜头算，与导出页那几个数字同源）
    var progress: Double {
        shots.isEmpty ? 0 : Double(recordedCount) / Double(shots.count)
    }

    /// 下一个可用编号（当前影片内）
    var nextNumber: Int { (shots.map(\.number).max() ?? 0) + 1 }

    func shot(withID id: Shot.ID) -> Shot? {
        shots.first { $0.id == id }
    }

    func index(of id: Shot.ID) -> Int? {
        shots.firstIndex { $0.id == id }
    }

    /// 某个片段的磁盘位置
    func clipURL(for clip: ShotClip) -> URL? {
        guard existingClipFileNames.contains(clip.fileName) else { return nil }
        return clipsDirectory.appendingPathComponent(clip.fileName, isDirectory: false)
    }

    /// 某个分镜最近一条片段的磁盘位置（卡片缩略图、播放默认取这条）
    func clipURL(for shot: Shot) -> URL? {
        guard let latest = shot.latestClip else { return nil }
        return clipURL(for: latest)
    }

    /// 某个分镜全部片段的磁盘位置，按拍摄先后排列
    func clipURLs(for shot: Shot) -> [URL] {
        shot.clips.compactMap { clipURL(for: $0) }
    }

    // MARK: - 影片操作

    /// 新建一部空白影片并切过去。
    ///
    /// 「重制」走的就是这条路：结束当前作品、开始下一部。旧影片不会被删除，
    /// 它留在影片库里，随时可以载入回来继续拍。
    @discardableResult
    func createFilm(title: String = "") -> Film? {
        guard loadError == nil else { return nil }
        let film = Film(title: title)
        films.append(film)
        currentFilmID = film.id
        return persist() ? film : nil
    }

    /// 把某部历史影片设为当前影片——「历史找回」的全部实现。
    ///
    /// 这一步只是切换指针，**不复制、不移动、不删除**任何数据：旧影片原样留库。
    /// 切过去之后，分镜页编辑的就是它，新增的镜头与片段都进这一部。
    ///
    /// - Returns: 是否切换成功（目标不存在、已是当前影片、或落盘失败时返回 `false`）。
    @discardableResult
    func loadFilm(_ id: Film.ID) -> Bool {
        guard loadError == nil else { return false }
        guard films.contains(where: { $0.id == id }) else { return false }
        guard id != currentFilmID else { return true }

        let previous = currentFilmID
        currentFilmID = id
        discardBlankFilm(previous)
        guard persist() else { return false }
        return true
    }

    /// 重制：收起当前影片、开一部空白影片。
    ///
    /// 与「新建影片」是同一个动作的两种说法，所以全应用只有这一个入口。
    @discardableResult
    func remakeCurrentFilm(title: String = "") -> Film? {
        guard loadError == nil else { return nil }
        let previous = currentFilmID
        let film = Film(title: title)
        films.append(film)
        currentFilmID = film.id
        discardBlankFilm(previous)
        guard persist() else { return nil }
        return film
    }

    /// 改影片标题。
    func renameFilm(_ id: Film.ID, to title: String) {
        guard loadError == nil else { return }
        guard let index = films.firstIndex(where: { $0.id == id }) else { return }
        guard films[index].title != title else { return }
        films[index].title = title
        films[index].updatedAt = Date()
        persist()
    }

    /// 改影片的剪辑风格描述。
    ///
    /// 走 `mutateCurrentFilm` 的唯一写入口，因此写风格也算一次用户编辑：
    /// 影片在库里的排序会往前跳——这符合预期，刚写完要求的那部就是最近动过的。
    ///
    /// 值没有变化时直接返回，不刷新 `updatedAt`：风格页每敲一个字都会发一次，
    /// 删掉一个字又改回来不该算两次编辑。
    @discardableResult
    func updateStylePrompt(_ prompt: String) -> Bool {
        guard loadError == nil else { return false }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = currentFilm, current.stylePrompt != trimmed else { return false }
        mutateCurrentFilm { $0.stylePrompt = trimmed }
        persist()
        return true
    }

    /// 删除整部影片（连同它的片段）。
    func deleteFilm(_ id: Film.ID) {
        guard loadError == nil else { return }
        guard let index = films.firstIndex(where: { $0.id == id }) else { return }
        films.remove(at: index)
        if currentFilmID == id { currentFilmID = films.first?.id }
        ensureFilmExists()
        persist()
    }

    /// 删除当前影片。用于导出页的维护入口。
    func deleteCurrentFilm() {
        guard let index = currentFilmIndex else { return }
        deleteFilm(films[index].id)
    }

    /// 回收空影片：既没有镜头、标题也为空的那种。
    ///
    /// 切换影片与重制时调用——不回收的话，用户每点一次「重制」就在库里留下
    /// 一个空壳，攒到十几部之后影片库就没法看了。
    /// 库里只剩它一部时保留：界面永远需要一部「当前影片」。
    private func discardBlankFilm(_ id: Film.ID?) {
        guard let id, id != currentFilmID, films.count > 1 else { return }
        guard let index = films.firstIndex(where: { $0.id == id }) else { return }
        guard films[index].isBlank else { return }
        films.remove(at: index)
    }

    /// 库里一部影片都没有时补一部空的。
    ///
    /// 这样 `currentFilm` 在正常路径下永远不为 nil，调用方不必到处解可选值。
    @discardableResult
    private func ensureFilmExists() -> Bool {
        guard films.isEmpty else { return false }
        let film = Film()
        films = [film]
        currentFilmID = film.id
        return true
    }

    // MARK: - 增

    /// 新建一个分镜，编号接在当前影片末尾
    @discardableResult
    func addShot(note: String = "") -> Shot? {
        guard loadError == nil, currentFilmIndex != nil else { return nil }
        let shot = Shot(number: nextNumber, note: note)
        mutateCurrentFilm { $0.shots.append(shot) }
        normalize()
        return persist() ? shot : nil
    }

    /// 一次性批量新建多个空白分镜，对应「一次录完 1、2、3、4 号镜头」的场景
    @discardableResult
    func addShots(count: Int) -> [Shot] {
        guard loadError == nil, currentFilmIndex != nil else { return [] }
        guard count > 0 else { return [] }
        let start = shots.count
        let created = (0..<count).map { Shot(number: start + $0 + 1) }
        mutateCurrentFilm { $0.shots.append(contentsOf: created) }
        normalize()
        return persist() ? created : []
    }

    /// 在某个镜头后面插入一个新镜头。
    ///
    /// 编号即位置，所以插入之后的所有镜头编号都会 +1，`normalize()` 会一并把
    /// 磁盘上的片段文件名改好（`镜头03_…mov` → `镜头04_…mov`）。这是全应用
    /// 统一的做法：拖动排序、删除、改编号走的都是同一条路。
    ///
    /// - Returns: 新建的镜头；传入的 id 已经不在当前影片里时返回 `nil`。
    @discardableResult
    func insertShot(below shotID: Shot.ID, note: String = "") -> Shot? {
        guard loadError == nil else { return nil }
        guard let index = index(of: shotID) else { return nil }
        let shot = Shot(number: index + 2, note: note)
        mutateCurrentFilm { $0.shots.insert(shot, at: index + 1) }
        normalize()
        return persist() ? shot : nil
    }

    /// 复制一个已有分镜（不含片段）
    @discardableResult
    func duplicate(_ shot: Shot) -> Shot? {
        guard loadError == nil else { return nil }
        // 「复制」＝「在它后面插入一个内容相同的镜头」，共用同一处实现，
        // 免得两条路上的重编号与改名行为悄悄走岔。
        if index(of: shot.id) != nil {
            return insertShot(below: shot.id, note: shot.note)
        }
        return addShot(note: shot.note)
    }

    // MARK: - 改

    /// 更新分镜内容。若编号发生变化，则把它移动到对应位置。
    @discardableResult
    func update(_ edited: Shot) -> Bool {
        guard loadError == nil, let filmIndex = currentFilmIndex else { return false }
        guard let shotIndex = films[filmIndex].shots.firstIndex(where: { $0.id == edited.id }) else { return false }

        var updated = edited
        updated.clips = films[filmIndex].shots[shotIndex].clips
        films[filmIndex].shots[shotIndex] = updated

        let targetIndex = min(max(updated.number, 1), films[filmIndex].shots.count) - 1
        if targetIndex != shotIndex {
            let moved = films[filmIndex].shots.remove(at: shotIndex)
            films[filmIndex].shots.insert(moved, at: targetIndex)
        }

        films[filmIndex].updatedAt = Date()
        normalize()
        return persist()
    }

    /// 把**当前影片**按列表顺序重新编号，并让磁盘上的片段文件名跟着更新，
    /// 这样「文件」App 里看到的序号与应用内的分镜顺序始终一致。
    ///
    /// 只处理当前影片：别的影片的编号与文件名不属于这次编辑的范围，
    /// 顺手一起改会把不相干的影片也标成「刚更新过」。
    ///
    /// - Returns: 是否有编号被改动（调用方据此决定要不要落盘）。
    @discardableResult
    func normalize() -> Bool {
        guard loadError == nil, let filmIndex = currentFilmIndex else { return false }
        var renumbered = false
        for index in films[filmIndex].shots.indices where films[filmIndex].shots[index].number != index + 1 {
            films[filmIndex].shots[index].number = index + 1
            renumbered = true
        }
        let renamed = syncClipFileNames()
        return renumbered || renamed
    }

    /// 拖拽排序（当前影片内）
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard loadError == nil else { return }
        mutateCurrentFilm { $0.shots.move(fromOffsets: source, toOffset: destination) }
        normalize()
        persist()
    }

    // MARK: - 删

    func delete(_ shot: Shot) {
        guard loadError == nil else { return }
        guard let index = index(of: shot.id) else { return }
        mutateCurrentFilm { $0.shots.remove(at: index) }
        normalize()
        persist()
    }

    // MARK: - 片段

    /// 给某个镜头追加一段刚拍好（或刚导入）的视频。
    ///
    /// 同一个镜头可以拍很多条，这里只追加、不覆盖之前的片段。
    /// 目标镜头必须属于**当前影片**——`index(of:)` 只在当前影片里找，
    /// 所以切片途中在途的导入会自然失败，而不会把片段写进另一部影片。
    ///
    /// 来源文件在 JSON 提交成功前一直原样保留，失败可以重试；成功后才删除。
    func addClip(from sourceURL: URL, duration: TimeInterval?, to shotID: Shot.ID) async throws {
        try Task.checkCancellation()
        if let loadError { throw NSError(domain: "ShotStore", code: 1, userInfo: [NSLocalizedDescriptionKey: loadError.message]) }
        guard index(of: shotID) != nil else { throw ShotStoreError.targetMissing }

        var target = try clipTarget(for: shotID, sourceURL: sourceURL)
        do {
            // 两个来源（相机录制的 shot-*、相册导入的 import-*）都已经是本应用临时目录里的完整文件，
            // 与「分镜视频」同卷：用硬链接把它挂到目标名下，不再复制一份。
            // 硬链接要么立刻完成、要么立刻失败，不像 copyItem 在无法克隆时会退化成整份复制而卡住主线程。
            // 来源名原样保留：提交失败时回滚只删目标名，来源仍可重试。
            try fileManager.linkItem(at: sourceURL, to: target.destination)
        } catch {
            // 链接不了（跨卷等）才真复制。大文件复制显式离开主协程，暂存文件不进入素材枚举和孤儿清理范围。
            let prepared = try await mediaFileCopy.temporaryCopy(of: sourceURL)
            defer { try? fileManager.removeItem(at: prepared) }
            try Task.checkCancellation()
            if let loadError { throw NSError(domain: "ShotStore", code: 1, userInfo: [NSLocalizedDescriptionKey: loadError.message]) }
            // 等待期间分镜可能被删除、重排，甚至整部影片被切走，必须重新解析目标和编号。
            target = try clipTarget(for: shotID, sourceURL: sourceURL)
            try fileManager.moveItem(at: prepared, to: target.destination)
        }
        stagedFileNames.insert(target.fileName)

        films[target.filmIndex].shots[target.shotIndex].clips.append(
            ShotClip(fileName: target.fileName, duration: duration, recordedAt: Date())
        )
        films[target.filmIndex].updatedAt = Date()
        try commit()
        try? fileManager.removeItem(at: sourceURL)
    }

    /// 目标镜头在当前影片里的位置，以及新片段在片段目录里的不重名路径。
    private func clipTarget(
        for shotID: Shot.ID,
        sourceURL: URL
    ) throws -> (filmIndex: Int, shotIndex: Int, fileName: String, destination: URL) {
        guard let filmIndex = currentFilmIndex,
              let shotIndex = films[filmIndex].shots.firstIndex(where: { $0.id == shotID })
        else { throw ShotStoreError.targetMissing }

        let fileName = makeClipFileName(
            number: films[filmIndex].shots[shotIndex].number,
            fileExtension: Self.fileExtension(ofFileName: sourceURL.lastPathComponent)
        )
        return (filmIndex, shotIndex, fileName, clipsDirectory.appendingPathComponent(fileName, isDirectory: false))
    }

    /// 删除某一个片段，镜头与其它的片段都保留
    func removeClip(_ clipID: ShotClip.ID, from shotID: Shot.ID) {
        guard loadError == nil, let filmIndex = currentFilmIndex else { return }
        guard let shotIndex = films[filmIndex].shots.firstIndex(where: { $0.id == shotID }),
              let clipIndex = films[filmIndex].shots[shotIndex].clips.firstIndex(where: { $0.id == clipID })
        else { return }

        films[filmIndex].shots[shotIndex].clips.remove(at: clipIndex)
        films[filmIndex].updatedAt = Date()
        persist()
    }

    /// 清空某个镜头的全部片段，镜头本身保留
    func removeAllClips(for shotID: Shot.ID) {
        guard loadError == nil, let filmIndex = currentFilmIndex else { return }
        guard let shotIndex = films[filmIndex].shots.firstIndex(where: { $0.id == shotID }) else { return }
        films[filmIndex].shots[shotIndex].clips.removeAll()
        films[filmIndex].updatedAt = Date()
        persist()
    }

    /// 某个片段是这个镜头的第几条（从 1 开始）
    func takeIndex(of clip: ShotClip, in shot: Shot) -> Int {
        (shot.clips.firstIndex { $0.id == clip.id } ?? 0) + 1
    }

    // MARK: - 持久化

    /// 扫一遍片段目录，把内存对齐到磁盘实况，并刷新统计缓存。
    ///
    /// 这是「启动 / 数据变更 / 从后台回到前台」三处共用的入口——用户可能在
    /// 「文件」App 里删过或拖进过文件，回到前台就该看见真实情况，而不是等到
    /// 下次启动才自愈。
    ///
    /// 只在启动、数据变更、以及切回前台时调用。视图读到的都是缓存值，
    /// `body` 里不再做同步文件 I/O。
    func refreshStorageStats() {
        guard loadError == nil else { return }
        let snapshot = diskSnapshot()

        if reconcileClipsWithDisk(snapshot) {
            // 校正可能改过磁盘上的文件名（重排编号会让文件跟着改名），
            // 旧快照里的名字已经失效，得重扫一遍再算统计
            persist()
            return
        }

        applySnapshot(snapshot)
    }

    /// 一次目录枚举的结果
    private struct DiskSnapshot {
        /// 文件名 → 字节数
        let sizes: [String: Int64]
        /// 目录是否枚举成功。读不到时为 `false`——此时「文件不存在」与
        /// 「整个目录都读不到」是同一个结果，绝不能据此删记录。
        let isComplete: Bool

        static let unreadable = DiskSnapshot(sizes: [:], isComplete: false)
    }

    private func diskSnapshot() -> DiskSnapshot {
        do {
            let urls = try fileManager.contentsOfDirectory(
                at: clipsDirectory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            var sizes: [String: Int64] = [:]
            sizes.reserveCapacity(urls.count)
            for url in urls {
                // 目录枚举时已经预取了 fileSize，这里再读一次命中的是缓存，不发系统调用
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                sizes[url.lastPathComponent] = Int64(size)
            }
            return DiskSnapshot(sizes: sizes, isComplete: true)
        } catch {
            return .unreadable
        }
    }

    /// 把内存里的分镜对齐到磁盘：剔除文件已经不在的片段，并在当前影片内重排编号。
    ///
    /// **只有枚举成功时才敢动数据。** 目录读不到时（外部卷没挂上、沙盒权限异常），
    /// 「文件不存在」与「整个目录读不到」得到的结果一模一样；按「文件不存在」
    /// 处理会一次把全部片段记录抹掉，而磁盘上的文件一个都没少——记录删了就回不来。
    /// 判据交给返回的 `isComplete`，不靠调用方自觉。
    ///
    /// 遍历的是**全部影片**：任何一部影片里失效的记录都该被清掉，不能等切过去才修。
    /// 重编号只走当前影片（见 `normalize()`）。
    ///
    /// - Returns: 是否改动过（调用方据此决定要不要落盘）。
    @discardableResult
    private func reconcileClipsWithDisk(_ snapshot: DiskSnapshot) -> Bool {
        guard snapshot.isComplete else { return false }

        var didRepair = false
        for filmIndex in films.indices {
            for shotIndex in films[filmIndex].shots.indices {
                let existing = films[filmIndex].shots[shotIndex].clips.filter { snapshot.sizes[$0.fileName] != nil }
                guard existing.count != films[filmIndex].shots[shotIndex].clips.count else { continue }
                films[filmIndex].shots[shotIndex].clips = existing
                didRepair = true
            }
        }

        if normalize() { didRepair = true }
        return didRepair
    }

    /// 用一次枚举的结果刷新「磁盘上有哪些片段」、每部影片的统计与「未使用文件」。
    private func applySnapshot(_ snapshot: DiskSnapshot) {
        // 枚举失败时保留上一次的统计：宁可数字旧一点，也不要突然报 0
        guard snapshot.isComplete else { return }

        existingClipFileNames = Set(snapshot.sizes.keys)

        var used: Set<String> = []
        var statsByFilm: [Film.ID: FilmStats] = [:]

        for film in films {
            var stats = FilmStats()
            for shot in film.shots {
                for clip in shot.clips {
                    // 只认磁盘上真的有的文件：不在的不计段数、不计时长、不计空间。
                    // 走到这里时 `shot.clips` 通常已经与磁盘对齐（见
                    // `reconcileClipsWithDisk`），这一层判断是为了在枚举中途失败、
                    // 校正没跑成的情况下也不会给出「占用空间掉下来了、段数还挂着」
                    // 这种自相矛盾的界面。
                    guard let bytes = snapshot.sizes[clip.fileName] else { continue }
                    used.insert(clip.fileName)
                    stats.clipCount += 1
                    stats.duration += clip.duration ?? 0
                    stats.bytes += bytes
                }
                // 与界面列表共用 `isRecorded`；它读的 `existingClipFileNames` 在上面已经更新过
                if isRecorded(shot) { stats.shotCount += 1 }
            }
            statsByFilm[film.id] = stats
        }

        filmStats = statsByFilm

        let current = currentFilmID.flatMap { statsByFilm[$0] } ?? .empty
        availableShotCount = current.shotCount
        availableClipCount = current.clipCount
        availableDuration = current.duration
        totalClipBytes = current.bytes

        // 判据覆盖**全部**影片：只看当前影片，会把别的影片的素材误判成未使用文件
        let orphans = snapshot.sizes.keys.filter { !used.contains($0) }.sorted()
        orphanFileNames = orphans
        orphanBytes = orphans.reduce(into: Int64(0)) { $0 += snapshot.sizes[$1] ?? 0 }
    }

    /// 删掉目录里那些没有任何影片引用的文件。
    ///
    /// - Returns: 实际删掉的数量。
    @discardableResult
    func removeOrphanFiles() -> Int {
        guard loadError == nil else { return 0 }
        var removed = 0
        var failed: [String] = []
        for name in orphanFileNames {
            if removeFile(named: name) { removed += 1 } else { failed.append(name) }
        }
        refreshStorageStats()
        if !failed.isEmpty { reportDeletionFailures(failed) }
        return removed
    }

    /// 从磁盘读取，并把内存对齐到磁盘实况。
    ///
    /// 片段文件可能已被用户从「文件」App 里删掉，编号也可能被外部改乱，
    /// 这里做一次一致性校正，**校正过就立刻落盘**：只改内存不写回的话，
    /// 磁盘上的文件名与 JSON 记录会一直对不上，下次启动按「文件不存在」
    /// 过滤就会让片段在界面上凭空消失（文件其实还在磁盘上）。
    func retryLoad() {
        guard loadError != nil else { return }
        load()
    }

    /// 支持调试启动参数 `-preselectFilm <序号>`：验收截图可以直接停在影片库里的某一部。
    ///
    /// 序号按 `sortedFilms`（最近更新在前）计，0 表示最近更新的那一部。
    /// 与 `-preselectTab` 同一套用法，见 Tools/seed-simulator.py 的验收流程。
    private func applyLaunchFilmSelection() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-preselectFilm"),
              flag + 1 < arguments.count,
              let index = Int(arguments[flag + 1]),
              sortedFilms.indices.contains(index)
        else { return }

        let target = sortedFilms[index]
        guard target.id != currentFilmID else { return }
        currentFilmID = target.id
        persist()
    }

    // MARK: - 读取与升级

    private func load() {
        if loadStoredLibrary() {
            refreshStorageStats()
            return
        }
        if loadLegacyLibrary() {
            refreshStorageStats()
            return
        }
        startEmptyLibrary()
        refreshStorageStats()
    }

    /// 读取 `films.json`。
    ///
    /// - Returns: `true` 表示已经处理完毕——成功加载，或者失败并已置 `loadError`
    ///   让界面停下来；`false` 表示文件不存在，应该继续尝试从旧版数据升级。
    private func loadStoredLibrary() -> Bool {
        let library: FilmLibrary
        let stored: Data
        do {
            stored = try Data(contentsOf: metadataURL)
            library = try JSONDecoder().decode(FilmLibrary.self, from: stored)
        } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain, failure.code == NSFileReadNoSuchFileError {
                return false
            }
            loadError = LoadFailure(
                kind: .unreadable,
                message: "原文件未改动。\n\(error.localizedDescription)"
            )
            films = []
            currentFilmID = nil
            orphanFileNames = []
            orphanBytes = 0
            return true
        }

        backUpBeforeTextMerge(stored)
        films = library.films
        // 指针可能指向一部已经不存在的影片（外部编辑过 JSON），回落到第一部
        currentFilmID = library.currentFilmID.flatMap { id in
            films.contains { $0.id == id } ? id : nil
        } ?? films.first?.id
        committedFilms = films
        committedCurrentFilmID = currentFilmID
        loadError = nil
        do {
            try recoverPendingDeletions()
        } catch {
            // 记录是读出来了的，只是删除补偿日志没清理完：不能算「读不出记录」，
            // 内存也不清空——与 `commit()` 里同一种失败保持一致，重试会重走一次清理。
            loadError = .deletionPending(error)
            return true
        }
        if ensureFilmExists() { persist() }
        return true
    }

    /// 读到还带着独立字幕、角标字段的 `films.json` 时，先把原文留一份。
    ///
    /// 读取时字幕与角标会并进描述（见 `Shot.mergedNote`），下一次写盘后原来的两个键
    /// 就没有了。那是用户一个字一个字敲进去的内容，合并万一出错，不该连原文都找不回来——
    /// 与 `shots.json.migrated` 同一个思路：出问题时把这份改回 `films.json` 即可。
    /// 备份只留第一份：之后写盘的记录里已经没有这两个键，不会再触发，
    /// 也就不会拿合并之后的内容盖掉真正的原文。
    ///
    /// 这里按键名做字节匹配而不是逐镜头解码：只是决定要不要留一份，
    /// 撞上同名文字最多多留一份备份，无害。
    private func backUpBeforeTextMerge(_ stored: Data) {
        let markers = ["\"caption\"", "\"badgeText\"", "\"badgeValue\""]
        guard markers.contains(where: { stored.range(of: Data($0.utf8)) != nil }) else { return }
        guard !fileManager.fileExists(atPath: preMergeBackupURL.path) else { return }
        try? stored.write(to: preMergeBackupURL, options: .atomic)
    }

    /// 把旧版 `shots.json`（一份全局分镜清单）升级成影片库。
    ///
    /// 顺序不能颠倒——**先恢复、后迁移**：磁盘上可能残留旧格式的删除补偿日志
    /// （`[Shot]`），一旦先写成 `FilmLibrary` 格式，那份日志就再也读不懂了。
    /// 因此这里先把旧清单装成一部影片，趁格式还是「一份清单」时把日志消费掉，
    /// 确认无误后再落新格式、把旧文件改名。
    ///
    /// 旧文件改名保留为 `shots.json.migrated` 而**不是删除**——它就是回滚保险：
    /// 万一 `films.json` 事后损坏，把名字改回去，旧版本应用即可正常读取。
    ///
    /// - Returns: `true` 表示已经处理完毕（升级成功，或失败并已置 `loadError`）。
    private func loadLegacyLibrary() -> Bool {
        guard fileManager.fileExists(atPath: legacyMetadataURL.path) else { return false }

        do {
            let legacy = try JSONDecoder().decode([Shot].self, from: Data(contentsOf: legacyMetadataURL))
            let stamp = (try? legacyMetadataURL
                .resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date()
            let film = Film(title: "", shots: legacy, createdAt: stamp, updatedAt: stamp)

            films = [film]
            currentFilmID = film.id
            committedFilms = films
            committedCurrentFilmID = currentFilmID
            loadError = nil

            try recoverPendingDeletions()
            try writeLibrary()
            try fileManager.moveItem(at: legacyMetadataURL, to: migratedMetadataURL)
            return true
        } catch {
            loadError = LoadFailure(
                kind: .upgradeFailed,
                message: "原文件未改动。请检查存储空间后重试。\n\(error.localizedDescription)"
            )
            films = []
            currentFilmID = nil
            orphanFileNames = []
            orphanBytes = 0
            return true
        }
    }

    /// 两份元数据都不存在时的处理。
    ///
    /// 只有素材目录确实为空才能视为首次启动。目录里还有视频却一份记录都没有，
    /// 说明记录丢了（外部删除 / 备份恢复），此时必须停下来：当成空库继续跑，
    /// 那些视频会在下一次「清理未使用的文件」里被当成孤儿清掉。
    private func startEmptyLibrary() {
        let snapshot = diskSnapshot()
        guard snapshot.isComplete, snapshot.sizes.isEmpty else {
            loadError = LoadFailure(
                kind: .unreadable,
                message: "原文件未改动。"
            )
            films = []
            currentFilmID = nil
            orphanFileNames = []
            orphanBytes = 0
            return
        }

        films = [Film()]
        currentFilmID = films[0].id
        committedFilms = films
        committedCurrentFilmID = currentFilmID
        loadError = nil
        persist()
    }

    /// 所有元数据变更共用一次提交；失败回滚内存，并保留旧 JSON 引用的文件。
    @discardableResult
    private func persist() -> Bool {
        do {
            saveError = nil
            try commit()
            return true
        } catch {
            saveError = "保存失败，已保留原内容。请检查存储空间后重试。\n\(error.localizedDescription)"
            return false
        }
    }

    private func commit() throws {
        // 先持久化删除前的关联。JSON 提交后若进程中断或文件删不掉，重启仍可找回归属。
        let recovery = FilmLibrary(films: committedFilms, currentFilmID: committedCurrentFilmID)
        do {
            try JSONEncoder().encode(recovery).write(to: deletionRecoveryURL, options: .atomic)
            try writeLibrary()
        } catch {
            films = committedFilms
            currentFilmID = committedCurrentFilmID
            for name in stagedFileNames { removeFile(named: name) }
            stagedFileNames.removeAll()
            applySnapshot(diskSnapshot())
            throw error
        }

        let previous = Film.referencedFileNames(in: committedFilms)
        let current = Film.referencedFileNames(in: films)
        committedFilms = films
        committedCurrentFilmID = currentFilmID
        let failures = previous.union(stagedFileNames).subtracting(current).sorted().filter { !removeFile(named: $0) }
        stagedFileNames.removeAll()
        do {
            try recoverPendingDeletions()
        } catch {
            // 恢复日志仍在磁盘上；暂停变更，不能让下一次提交覆盖尚未恢复的关联。
            loadError = .deletionPending(error)
        }
        if !failures.isEmpty { reportDeletionFailures(failures) }
        applySnapshot(diskSnapshot())
    }

    /// 消费删除补偿日志，把「JSON 里已经删掉、但文件没删成功」的关联找回来。
    ///
    /// 日志有两种格式：新版写 `FilmLibrary`，升级路径上可能残留旧版的 `[Shot]`。
    /// 两者都读——旧格式按「当前影片」恢复，因为升级那一刻库里只有那一部。
    /// 两种都解不开的日志视为损坏，直接丢弃。
    private func recoverPendingDeletions() throws {
        guard fileManager.fileExists(atPath: deletionRecoveryURL.path) else { return }
        let data = try Data(contentsOf: deletionRecoveryURL)

        var restored = false
        var lastRecoveredFilmID: UUID?
        if let library = try? JSONDecoder().decode(FilmLibrary.self, from: data) {
            for old in library.films {
                if let index = films.firstIndex(where: { $0.id == old.id }) {
                    if mergeRecovered(old.shots, intoFilmAt: index) { restored = true }
                    continue
                }
                // 影片本身也被删掉了：整部找回，只保留磁盘上还有文件的片段
                let salvaged = survivingShots(of: old)
                guard !salvaged.isEmpty else { continue }
                var recovered = old
                recovered.shots = salvaged
                films.append(recovered)
                lastRecoveredFilmID = recovered.id
                restored = true
            }
        } else if let legacy = try? JSONDecoder().decode([Shot].self, from: data) {
            if let index = currentFilmIndex {
                if mergeRecovered(legacy, intoFilmAt: index) { restored = true }
            } else {
                let salvaged = survivingShots(of: Film(shots: legacy))
                guard !salvaged.isEmpty else {
                    try fileManager.removeItem(at: deletionRecoveryURL)
                    return
                }
                films = [Film(shots: salvaged)]
                currentFilmID = films[0].id
                restored = true
            }
        } else {
            // 两种格式都解不开：这份日志已经损坏，重试多少次都读不懂。它只是上一次提交前的
            // 旧快照，丢掉最多让「文件没删成功」的那几个片段不再被自动找回——文件还在磁盘上，
            // 会作为「未使用的文件」出现，由用户决定清不清。留着它只会让每次启动都卡在这里。
            // 读不出来（`Data(contentsOf:)` 抛错）则不算损坏，仍按清理失败处理、可重试。
            try fileManager.removeItem(at: deletionRecoveryURL)
            return
        }

        if restored {
            for filmIndex in films.indices {
                for shotIndex in films[filmIndex].shots.indices {
                    films[filmIndex].shots[shotIndex].number = shotIndex + 1
                }
            }
            // 当前影片可能是刚自动补出来的空壳（删掉最后一部影片时补的）。
            // 既然有影片被找回来了，就把它顶上来——用户此刻要看的是被找回来的那部，
            // 而不是一部什么都没有的新片。
            if let recovered = lastRecoveredFilmID,
               let index = films.firstIndex(where: { $0.id == currentFilmID }),
               films[index].isBlank,
               films.count > 1 {
                currentFilmID = recovered
            }
            try writeLibrary()
            committedFilms = films
            committedCurrentFilmID = currentFilmID
        }
        try fileManager.removeItem(at: deletionRecoveryURL)
    }

    /// 从一份旧快照里挑出磁盘上还有文件的镜头
    private func survivingShots(of film: Film) -> [Shot] {
        film.shots.compactMap { shot -> Shot? in
            let clips = shot.clips.filter { clipFileExists($0.fileName) }
            guard !clips.isEmpty else { return nil }
            var recovered = shot
            recovered.clips = clips
            return recovered
        }
    }

    /// 把一份旧快照里「磁盘上还有文件、当前记录里已经没有」的片段找回来。
    ///
    /// 已有记录的片段保持当前顺序，找回的排在后面；原镜头已经不在了就整条插回。
    ///
    /// - Returns: 是否找回过来东西。
    private func mergeRecovered(_ pending: [Shot], intoFilmAt filmIndex: Int) -> Bool {
        let known = Set(films[filmIndex].allClips.map(\.id))
        var restored = false

        for (position, old) in pending.enumerated() {
            let remaining = old.clips.filter { !known.contains($0.id) && clipFileExists($0.fileName) }
            guard !remaining.isEmpty else { continue }

            if let shotIndex = films[filmIndex].shots.firstIndex(where: { $0.id == old.id }) {
                let combined = films[filmIndex].shots[shotIndex].clips + remaining
                let byID = Dictionary(uniqueKeysWithValues: combined.map { ($0.id, $0) })
                let oldIDs = Set(old.clips.map(\.id))
                films[filmIndex].shots[shotIndex].clips =
                    old.clips.compactMap { byID[$0.id] } + combined.filter { !oldIDs.contains($0.id) }
            } else {
                var recovered = old
                recovered.clips = remaining
                films[filmIndex].shots.insert(recovered, at: min(position, films[filmIndex].shots.count))
            }
            restored = true
        }
        return restored
    }

    private func clipFileExists(_ fileName: String) -> Bool {
        fileManager.fileExists(atPath: clipsDirectory.appendingPathComponent(fileName, isDirectory: false).path)
    }

    private func reportDeletionFailures(_ names: [String]) {
        saveError = "\(names.count) 个文件未能删除，可稍后重试。\n" + names.joined(separator: "\n")
    }

    private func writeLibrary() throws {
        if let loadError {
            throw NSError(domain: "ShotStore", code: 1, userInfo: [NSLocalizedDescriptionKey: loadError.message])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(FilmLibrary(films: films, currentFilmID: currentFilmID))
        try data.write(to: metadataURL, options: .atomic)
    }

    private func createDirectoryIfNeeded(_ url: URL) {
        guard !fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: - 文件名

    /// 生成一个不重名的片段文件名，形如「镜头01_20260914_120001.mov」
    private func makeClipFileName(number: Int, fileExtension: String) -> String {
        let token = Self.timestampToken()
        var candidate = Self.clipFileName(number: number, token: token, fileExtension: fileExtension)
        var attempt = 2
        while fileManager.fileExists(atPath: clipsDirectory.appendingPathComponent(candidate).path) {
            candidate = Self.clipFileName(
                number: number,
                token: "\(token)-\(attempt)",
                fileExtension: fileExtension
            )
            attempt += 1
        }
        return candidate
    }

    /// 编号变化时先复制到新文件名；JSON 提交成功后才删除旧文件，失败仍能读取旧记录。
    ///
    /// 只处理当前影片。别的影片的文件名不属于这次编辑的范围，顺手一起改会把
    /// 不相干的影片也搅进来；而且不同影片的「镜头01」本来就允许同名共存
    /// （文件名带秒级时间戳，重名时由 attempt 后缀区分，不会互相覆盖）。
    ///
    /// 扩展名跟着文件自己走：导入的 mp4 换编号之后仍然是 mp4。
    private func syncClipFileNames() -> Bool {
        guard let filmIndex = currentFilmIndex else { return false }
        var renamed = false

        for shotIndex in films[filmIndex].shots.indices {
            let number = films[filmIndex].shots[shotIndex].number
            for clipIndex in films[filmIndex].shots[shotIndex].clips.indices {
                let current = films[filmIndex].shots[shotIndex].clips[clipIndex].fileName
                guard let token = Self.token(from: current) else { continue }

                var expected = Self.clipFileName(
                    number: number,
                    token: token,
                    fileExtension: Self.fileExtension(ofFileName: current)
                )
                guard expected != current else { continue }

                let source = clipsDirectory.appendingPathComponent(current, isDirectory: false)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                // 旧文件在 JSON 提交前仍被引用；冲突时使用同编号的唯一文件名，不能覆盖或跳过。
                var attempt = 2
                while fileManager.fileExists(atPath: clipsDirectory.appendingPathComponent(expected).path) {
                    expected = Self.clipFileName(number: number, token: "\(token)-\(attempt)",
                                                 fileExtension: Self.fileExtension(ofFileName: current))
                    attempt += 1
                }
                let destination = clipsDirectory.appendingPathComponent(expected, isDirectory: false)

                do {
                    try fileManager.copyItem(at: source, to: destination)
                    stagedFileNames.insert(expected)
                    films[filmIndex].shots[shotIndex].clips[clipIndex].fileName = expected
                    renamed = true
                } catch {
                    continue
                }
            }
        }
        return renamed
    }

    private static func clipFileName(number: Int, token: String, fileExtension: String) -> String {
        String(format: "%@%02d_%@.%@", clipNamePrefix, number, token, fileExtension)
    }

    /// 从「镜头01_20260914_120001.mov」里取出时间戳部分（不含扩展名）
    private static func token(from fileName: String) -> String? {
        guard fileName.hasPrefix(clipNamePrefix),
              let separator = fileName.firstIndex(of: "_") else { return nil }
        var token = String(fileName[fileName.index(after: separator)...])
        if let dot = token.lastIndex(of: ".") {
            token = String(token[token.startIndex..<dot])
        }
        return token.isEmpty ? nil : token
    }

    /// 文件名里的扩展名；没有扩展名时按 `mov` 兜底。
    ///
    /// 不写死扩展名，是为了让相册导入的 mp4 一直保持 mp4——
    /// 容器与扩展名不符的文件交给剪映可能打不开。
    private static func fileExtension(ofFileName fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "mov" : ext
    }

    @discardableResult
    private func removeFile(named fileName: String) -> Bool {
        let url = clipsDirectory.appendingPathComponent(fileName, isDirectory: false)
        do { try fileManager.removeItem(at: url) }
        catch {
            let error = error as NSError
            guard error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError else { return false }
        }
        // 文件名带着时间戳，删掉之后同一个路径有可能被新片段用上；
        // 缓存里的旧图必须一起清掉，否则新片段会显示上一个视频的首帧
        ThumbnailLoader.shared.invalidate(for: url)
        return true
    }

    private static func timestampToken() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}
