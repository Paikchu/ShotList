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

    @Published private(set) var loadError: String?

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
    }

    // MARK: - 统计

    /// 「已拍」的磁盘口径：磁盘上确实存在、且被分镜引用到的素材。
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

    /// 已经拍过的镜头数量（以磁盘上真的有文件为准）
    var recordedCount: Int { availableShotCount }

    /// 全部片段数量（只数磁盘上真的有文件的那几条）
    var clipCount: Int { availableClipCount }

    // MARK: - 按天统计

    /// 某天拍过的镜头（当天至少有一条片段），按镜头顺序排列。
    ///
    /// 历史页按这个口径列出「当天已拍」。
    func recordedShots(on day: Date, calendar: Calendar = .current) -> [Shot] {
        shots.filter { shot in
            shot.clips.contains { calendar.isDate($0.recordedAt, inSameDayAs: day) }
        }
    }

    /// 某天还没拍的镜头：当天没有片段的都算——含「从未拍过」与「别天拍过」两类，
    /// 站在那一天的角度，两者都还欠一条。标签栏徽标与当天进度环走这一个口径，
    /// 免得出现「进度 0%，却提示都拍完了」这种自相矛盾的界面。
    func pendingShots(on day: Date, calendar: Calendar = .current) -> [Shot] {
        let recorded = Set(recordedShots(on: day, calendar: calendar).map(\.id))
        return shots.filter { !recorded.contains($0.id) }
    }

    /// 某天的拍摄进度 0…1
    func progress(on day: Date, calendar: Calendar = .current) -> Double {
        shots.isEmpty
            ? 0
            : Double(recordedShots(on: day, calendar: calendar).count) / Double(shots.count)
    }

    /// 某个镜头在某天拍的片段，按拍摄先后排列。历史页的卡片按这个口径取当天素材。
    func clips(of shot: Shot, recordedOn day: Date, calendar: Calendar = .current) -> [ShotClip] {
        shot.clips.filter { calendar.isDate($0.recordedAt, inSameDayAs: day) }
    }

    /// 全部片段的总时长（秒，只算磁盘上真的有文件的那几条）
    var totalDuration: TimeInterval { availableDuration }

    /// 全部片段占用空间（字节）。
    ///
    /// 只统计**被分镜引用到、且真的在磁盘上**的片段，因此和旁边那几个数字
    /// （已拍镜头数、段数、总时长）是同一个口径。目录里的未使用文件另有
    /// `orphanBytes`，两者相加才是这个目录真正占的磁盘。
    ///
    /// 这是**缓存值**，由 `refreshStorageStats()` 在启动与数据变更时刷新。
    /// 视图每次重绘都会读它，若在这里现算，一次重绘就要跨 N 个片段发系统调用
    /// （导出页连无障碍值要读两遍，就是 2×N 次）。
    @Published private(set) var totalClipBytes: Int64 = 0

    /// 目录里有、但没有任何分镜引用的文件。
    ///
    /// `Documents` 对「文件」App 与访达开放，用户完全可以把视频直接拖进来；
    /// 这些文件不进 JSON，于是既不出现在界面上，也不被导出带走。它们确实占着
    /// 磁盘，所以这里把它们找出来，交给导出页做一个清理入口——不然用户看不到
    /// 它们，也没有任何办法回收。
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
    func addShot(note: String = "") -> Shot? {
        guard loadError == nil else { return nil }
        let shot = Shot(number: nextNumber, note: note)
        shots.append(shot)
        normalize()
        persist()
        return shot
    }

    /// 一次性批量新建多个空白分镜，对应「一次录完 1、2、3、4 号镜头」的场景
    @discardableResult
    func addShots(count: Int) -> [Shot] {
        guard loadError == nil else { return [] }
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

    /// 在某个镜头后面插入一个新镜头。
    ///
    /// 编号即位置，所以插入之后的所有镜头编号都会 +1，`normalize()` 会一并把
    /// 磁盘上的片段文件名改好（`镜头03_…mov` → `镜头04_…mov`）。这是全应用
    /// 统一的做法：拖动排序、删除、改编号走的都是同一条路。
    ///
    /// - Returns: 新建的镜头；传入的 id 已经不在列表里时返回 `nil`。
    @discardableResult
    func insertShot(below shotID: Shot.ID, note: String = "") -> Shot? {
        guard loadError == nil else { return nil }
        guard let index = index(of: shotID) else { return nil }
        let shot = Shot(number: index + 2, note: note)
        shots.insert(shot, at: index + 1)
        normalize()
        persist()
        return shot
    }

    /// 复制一个已有分镜（不含片段）
    @discardableResult
    func duplicate(_ shot: Shot) -> Shot? {
        guard loadError == nil else { return nil }
        // 「复制」＝「在它后面插入一个内容相同的镜头」，共用同一处实现，
        // 免得两条路上的重编号与改名行为悄悄走岔
        if let copy = insertShot(below: shot.id, note: shot.note) { return copy }
        return addShot(note: shot.note)
    }

    // MARK: - 改

    /// 更新分镜内容。若编号发生变化，则把它移动到对应位置。
    func update(_ edited: Shot) {
        guard loadError == nil else { return }
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
        guard loadError == nil else { return false }
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
        guard loadError == nil else { return }
        shots.move(fromOffsets: source, toOffset: destination)
        normalize()
        persist()
    }

    // MARK: - 删

    func delete(_ shot: Shot) {
        guard loadError == nil else { return }
        guard let index = index(of: shot.id) else { return }
        removeClipFiles(of: shots[index])
        shots.remove(at: index)
        normalize()
        persist()
    }

    /// 删除全部分镜与片段（用于「清空重来」）
    func deleteEverything() {
        guard loadError == nil else { return }
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
        if let loadError { throw NSError(domain: "ShotStore", code: 1, userInfo: [NSLocalizedDescriptionKey: loadError]) }
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
        guard loadError == nil else { return }
        guard let shotIndex = index(of: shotID),
              let clipIndex = shots[shotIndex].clips.firstIndex(where: { $0.id == clipID })
        else { return }

        let clip = shots[shotIndex].clips.remove(at: clipIndex)
        removeFile(named: clip.fileName)
        persist()
    }

    /// 清空某个镜头的全部片段，镜头本身保留
    func removeAllClips(for shotID: Shot.ID) {
        guard loadError == nil else { return }
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
            writeMetadata()
            applySnapshot(diskSnapshot())
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

    /// 把内存里的分镜对齐到磁盘：剔除文件已经不在的片段，并按需重排编号。
    ///
    /// **只有枚举成功时才敢动数据。** 目录读不到时（外部卷没挂上、沙盒权限异常），
    /// 「文件不存在」与「整个目录读不到」得到的结果一模一样；按「文件不存在」
    /// 处理会一次把全部片段记录抹掉，而磁盘上的文件一个都没少——记录删了就回不来。
    /// 判据交给返回的 `isComplete`，不靠调用方自觉。
    ///
    /// - Returns: 是否改动过（调用方据此决定要不要落盘）。
    @discardableResult
    private func reconcileClipsWithDisk(_ snapshot: DiskSnapshot) -> Bool {
        guard snapshot.isComplete else { return false }

        var didRepair = false
        for index in shots.indices {
            let existing = shots[index].clips.filter { snapshot.sizes[$0.fileName] != nil }
            guard existing.count != shots[index].clips.count else { continue }
            shots[index].clips = existing
            didRepair = true
        }

        if normalize() { didRepair = true }
        return didRepair
    }

    /// 用一次枚举的结果刷新「磁盘上有哪些片段」「素材占用空间」与「未使用文件」。
    private func applySnapshot(_ snapshot: DiskSnapshot) {
        // 枚举失败时保留上一次的统计：宁可数字旧一点，也不要突然报 0
        guard snapshot.isComplete else { return }

        existingClipFileNames = Set(snapshot.sizes.keys)

        var used: Set<String> = []
        var materialBytes: Int64 = 0
        var clipCount = 0
        var duration: TimeInterval = 0
        var shotCount = 0

        for shot in shots {
            var hasMaterial = false
            for clip in shot.clips {
                // 只认磁盘上真的有的文件：不在的不计段数、不计时长、不计空间。
                // 走到这里时 `shot.clips` 通常已经与磁盘对齐（见
                // `reconcileClipsWithDisk`），这一层判断是为了在枚举中途失败、
                // 校正没跑成的情况下也不会给出「占用空间掉下来了、段数还挂着」
                // 这种自相矛盾的界面。
                guard let bytes = snapshot.sizes[clip.fileName] else { continue }
                used.insert(clip.fileName)
                materialBytes += bytes
                duration += clip.duration ?? 0
                clipCount += 1
                hasMaterial = true
            }
            if hasMaterial { shotCount += 1 }
        }

        totalClipBytes = materialBytes
        availableClipCount = clipCount
        availableDuration = duration
        availableShotCount = shotCount

        let orphans = snapshot.sizes.keys.filter { !used.contains($0) }.sorted()
        orphanFileNames = orphans
        orphanBytes = orphans.reduce(into: Int64(0)) { $0 += snapshot.sizes[$1] ?? 0 }
    }

    /// 删掉目录里那些没有任何分镜引用的文件。
    ///
    /// - Returns: 实际删掉的数量。
    @discardableResult
    func removeOrphanFiles() -> Int {
        guard loadError == nil else { return 0 }
        let removed = orphanFileNames
        for name in removed {
            removeFile(named: name)
        }
        refreshStorageStats()
        return removed.count
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

    private func load() {
        do {
            let data = try Data(contentsOf: metadataURL)
            let decoded = try JSONDecoder().decode([Shot].self, from: data)
            shots = decoded
            loadError = nil
        } catch {
            let failure = error as NSError
            let snapshot = diskSnapshot()
            // 只有元数据不存在且素材目录确实为空，才能视为首次启动。
            if failure.domain == NSCocoaErrorDomain,
               failure.code == NSFileReadNoSuchFileError,
               snapshot.isComplete, snapshot.sizes.isEmpty {
                shots = []
                loadError = nil
            } else {
                loadError = "无法读取分镜记录，已暂停编辑和文件清理，原文件不会被覆盖。请恢复可用的分镜记录后重试。\n\(error.localizedDescription)"
                orphanFileNames = []
                orphanBytes = 0
                return
            }
        }
        refreshStorageStats()
    }

    private func persist() {
        writeMetadata()
        refreshStorageStats()
    }

    private func writeMetadata() {
        guard loadError == nil else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(shots) else { return }
        try? data.write(to: metadataURL, options: .atomic)
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
