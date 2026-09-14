import Foundation
import SwiftUI

/// 分镜数据仓库。
///
/// 职责：
/// - 维护内存中的分镜列表，并持久化为 JSON（Application Support/ShotList/shots.json）
/// - 管理磁盘上的分镜片段文件（Documents/分镜视频）
///
/// 由于 Documents 目录对「文件」App 与 Finder 可见（Info.plist 中开启了
/// `UIFileSharingEnabled` 与 `LSSupportsOpeningDocumentsInPlace`），
/// 用户可以直接把拍摄好的分镜片段拖到电脑上。
///
/// 一个镜头可以拍很多条，每条都是独立的文件，互不覆盖。
@MainActor
final class ShotStore: ObservableObject {

    /// 全部分镜，按拍摄顺序排列
    @Published private(set) var shots: [Shot] = []

    private let fileManager: FileManager
    private let metadataURL: URL

    /// 分镜片段统一存放目录
    let clipsDirectory: URL

    private static let clipNamePrefix = "镜头"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? documents

        let supportDirectory = applicationSupport.appendingPathComponent("ShotList", isDirectory: true)
        self.clipsDirectory = documents.appendingPathComponent("分镜视频", isDirectory: true)
        self.metadataURL = supportDirectory.appendingPathComponent("shots.json", isDirectory: false)

        createDirectoryIfNeeded(supportDirectory)
        createDirectoryIfNeeded(clipsDirectory)
        load()
        refreshStorageStats()
    }

    // MARK: - 统计

    /// 已经拍过的镜头数量
    var recordedCount: Int { shots.filter(\.hasClip).count }

    /// 全部片段数量（一个镜头可能有好几条）
    var clipCount: Int { shots.reduce(0) { $0 + $1.clipCount } }

    /// 今日已拍摄的镜头（以最近一条片段的拍摄日期为准）
    var todayRecordedShots: [Shot] {
        let today = Date()
        return shots.filter { $0.status(relativeTo: today) == .shotToday }
    }

    /// 今日仍未拍摄的镜头。
    ///
    /// 含「从未拍过」与「往日拍过」两类——站在今天的角度，两者都还欠一条。
    /// 今日页的进度环、「下一个」提示与标签栏徽标都走这一个口径，
    /// 免得出现「进度 0%，却提示今天都拍完了」这种自相矛盾的界面。
    var todayPendingShots: [Shot] {
        let today = Date()
        return shots.filter { $0.status(relativeTo: today) != .shotToday }
    }

    /// 今日已拍摄的镜头数量
    var todayRecordedCount: Int { todayRecordedShots.count }

    /// 今日仍未拍摄的镜头数量
    var todayPendingCount: Int { todayPendingShots.count }

    /// 全部片段的总时长（秒）
    var totalDuration: TimeInterval {
        shots.reduce(0) { $0 + $1.totalDuration }
    }

    /// 全部片段占用空间（字节）。
    ///
    /// 这是**缓存值**，由 `refreshStorageStats()` 在启动与数据变更时刷新。
    /// 视图每次重绘都会读它，若在这里现算，一次重绘就要跨 N 个片段发系统调用
    /// （导出页连无障碍值要读两遍，就是 2×N 次）。
    @Published private(set) var totalClipBytes: Int64 = 0

    /// 磁盘上实际存在的片段文件名。
    ///
    /// `clipURL(for:)` 被视图高频调用，每次都 `fileExists` 太贵，
    /// 改为在刷新统计时扫一遍目录缓存下来。
    private var existingClipFileNames: Set<String> = []

    /// 拍摄进度 0…1
    var progress: Double {
        shots.isEmpty ? 0 : Double(recordedCount) / Double(shots.count)
    }

    /// 今日拍摄进度 0…1
    var todayProgress: Double {
        shots.isEmpty ? 0 : Double(todayRecordedCount) / Double(shots.count)
    }

    /// 下一个可用编号
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

    // MARK: - 增

    /// 新建一个分镜，编号接在末尾
    @discardableResult
    func addShot(note: String = "") -> Shot {
        let shot = Shot(number: nextNumber, note: note)
        shots.append(shot)
        normalize()
        persist()
        return shot
    }

    /// 一次性批量新建多个空白分镜，对应「一次录完 1、2、3、4 号镜头」的场景
    @discardableResult
    func addShots(count: Int) -> [Shot] {
        guard count > 0 else { return [] }
        var created: [Shot] = []
        for _ in 0..<count {
            created.append(Shot(number: shots.count + created.count + 1))
        }
        shots.append(contentsOf: created)
        normalize()
        persist()
        return created
    }

    /// 复制一个已有分镜（不含片段）
    @discardableResult
    func duplicate(_ shot: Shot) -> Shot {
        var copy = Shot(number: nextNumber, note: shot.note)
        if let index = index(of: shot.id) {
            copy.number = index + 2
            shots.insert(copy, at: index + 1)
        } else {
            shots.append(copy)
        }
        normalize()
        persist()
        return copy
    }

    // MARK: - 改

    /// 更新分镜内容。若编号发生变化，则把它移动到对应位置。
    func update(_ edited: Shot) {
        guard let currentIndex = index(of: edited.id) else { return }

        var updated = edited
        updated.clips = shots[currentIndex].clips
        shots[currentIndex] = updated

        let targetIndex = min(max(updated.number, 1), shots.count) - 1
        if targetIndex != currentIndex {
            let moved = shots.remove(at: currentIndex)
            shots.insert(moved, at: targetIndex)
        }

        normalize()
        persist()
    }

    /// 按列表顺序重新编号，并让磁盘上的片段文件名跟着更新，
    /// 这样「文件」App 里看到的序号与应用内的分镜顺序始终一致。
    ///
    /// - Returns: 是否有编号被改动（调用方据此决定要不要落盘）。
    @discardableResult
    func normalize() -> Bool {
        var renumbered = false
        for index in shots.indices where shots[index].number != index + 1 {
            shots[index].number = index + 1
            renumbered = true
        }
        if renumbered { syncClipFileNames() }
        return renumbered
    }

    /// 拖拽排序
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        shots.move(fromOffsets: source, toOffset: destination)
        normalize()
        persist()
    }

    // MARK: - 删

    func delete(_ shot: Shot) {
        guard let index = index(of: shot.id) else { return }
        removeClipFiles(of: shots[index])
        shots.remove(at: index)
        normalize()
        persist()
    }

    func deleteShots(withIDs ids: [Shot.ID]) {
        for shot in shots where ids.contains(shot.id) {
            removeClipFiles(of: shot)
        }
        shots.removeAll { ids.contains($0.id) }
        normalize()
        persist()
    }

    /// 删除全部分镜与片段（用于「清空重来」）
    func deleteEverything() {
        try? fileManager.removeItem(at: clipsDirectory)
        createDirectoryIfNeeded(clipsDirectory)
        shots.removeAll()
        ThumbnailLoader.shared.removeAll()
        persist()
    }

    // MARK: - 片段

    /// 给某个镜头追加一段刚拍好（或刚导入）的视频。
    ///
    /// 同一个镜头可以拍很多条，这里只追加、不覆盖之前的片段。
    func addClip(from sourceURL: URL, duration: TimeInterval?, to shotID: Shot.ID) throws {
        guard let index = index(of: shotID) else { return }

        let fileName = makeClipFileName(
            number: shots[index].number,
            fileExtension: Self.fileExtension(ofFileName: sourceURL.lastPathComponent)
        )
        let destination = clipsDirectory.appendingPathComponent(fileName, isDirectory: false)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        try? fileManager.removeItem(at: sourceURL)

        shots[index].clips.append(
            ShotClip(fileName: fileName, duration: duration, recordedAt: Date())
        )
        persist()
    }

    /// 删除某一个片段，镜头与其它的片段都保留
    func removeClip(_ clipID: ShotClip.ID, from shotID: Shot.ID) {
        guard let shotIndex = index(of: shotID),
              let clipIndex = shots[shotIndex].clips.firstIndex(where: { $0.id == clipID })
        else { return }

        let clip = shots[shotIndex].clips.remove(at: clipIndex)
        removeFile(named: clip.fileName)
        persist()
    }

    /// 清空某个镜头的全部片段，镜头本身保留
    func removeAllClips(for shotID: Shot.ID) {
        guard let index = index(of: shotID) else { return }
        removeClipFiles(of: shots[index])
        shots[index].clips.removeAll()
        persist()
    }

    /// 某个片段是这个镜头的第几条（从 1 开始）
    func takeIndex(of clip: ShotClip, in shot: Shot) -> Int {
        (shot.clips.firstIndex { $0.id == clip.id } ?? 0) + 1
    }

    // MARK: - 持久化

    /// 扫一遍片段目录，刷新「磁盘上存在哪些片段」与「占用空间」两个缓存。
    ///
    /// 只在启动、数据变更、以及从后台回到前台（用户可能在「文件」App 里删过
    /// 片段）时调用。视图读到的都是缓存值，`body` 里不再做同步文件 I/O。
    func refreshStorageStats() {
        let urls = (try? fileManager.contentsOfDirectory(
            at: clipsDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var sizes: [String: Int64] = [:]
        sizes.reserveCapacity(urls.count)
        for url in urls {
            // 目录枚举时已经预取了 fileSize，这里再读一次命中的是缓存，不发系统调用
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            sizes[url.lastPathComponent] = Int64(size)
        }

        existingClipFileNames = Set(sizes.keys)
        totalClipBytes = shots.reduce(into: Int64(0)) { total, shot in
            for clip in shot.clips { total += sizes[clip.fileName] ?? 0 }
        }
    }

    /// 从磁盘读取。
    ///
    /// 片段文件可能已被用户从「文件」App 里删掉，编号也可能被外部改乱，
    /// 这里做一次一致性校正，**校正过就立刻落盘**：只改内存不写回的话，
    /// 磁盘上的文件名与 JSON 记录会一直对不上，下次启动按「文件不存在」
    /// 过滤就会让片段在界面上凭空消失（文件其实还在磁盘上）。
    private func load() {
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([Shot].self, from: data) else {
            return
        }

        var didRepair = false

        shots = decoded.map { shot in
            var fixed = shot
            let existing = shot.clips.filter { clip in
                let url = clipsDirectory.appendingPathComponent(clip.fileName, isDirectory: false)
                return fileManager.fileExists(atPath: url.path)
            }
            if existing.count != shot.clips.count { didRepair = true }
            fixed.clips = existing
            return fixed
        }

        if normalize() { didRepair = true }
        if didRepair { persist() }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(shots) else { return }
        try? data.write(to: metadataURL, options: .atomic)
        refreshStorageStats()
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

    /// 编号变化后同步磁盘上的文件名。改名失败时保留原名，不会丢文件。
    ///
    /// 扩展名跟着文件自己走：导入的 mp4 换编号之后仍然是 mp4。
    private func syncClipFileNames() {
        for shotIndex in shots.indices {
            let number = shots[shotIndex].number
            for clipIndex in shots[shotIndex].clips.indices {
                let current = shots[shotIndex].clips[clipIndex].fileName
                guard let token = Self.token(from: current) else { continue }

                let expected = Self.clipFileName(
                    number: number,
                    token: token,
                    fileExtension: Self.fileExtension(ofFileName: current)
                )
                guard expected != current else { continue }

                let source = clipsDirectory.appendingPathComponent(current, isDirectory: false)
                let destination = clipsDirectory.appendingPathComponent(expected, isDirectory: false)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                guard !fileManager.fileExists(atPath: destination.path) else { continue }

                do {
                    try fileManager.moveItem(at: source, to: destination)
                    shots[shotIndex].clips[clipIndex].fileName = expected
                } catch {
                    continue
                }
            }
        }
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

    private func removeClipFiles(of shot: Shot) {
        for clip in shot.clips {
            removeFile(named: clip.fileName)
        }
    }

    private func removeFile(named fileName: String) {
        let url = clipsDirectory.appendingPathComponent(fileName, isDirectory: false)
        try? fileManager.removeItem(at: url)
        // 文件名带着时间戳，删掉之后同一个路径有可能被新片段用上；
        // 缓存里的旧图必须一起清掉，否则新片段会显示上一个视频的首帧
        ThumbnailLoader.shared.invalidate(for: url)
    }

    private static func timestampToken() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}
