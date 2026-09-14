import Foundation

/// 导出范围
nonisolated enum ExportScope: String, CaseIterable, Identifiable {
    /// 只导出已经拍好的镜头
    case recordedOnly
    /// 导出全部分镜，未拍摄的镜头在清单里标注
    case everything

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recordedOnly: return "仅已拍镜头"
        case .everything: return "全部分镜"
        }
    }
}

/// 一次导出产出的文件包
nonisolated struct ExportPackage: Identifiable, Equatable {
    let id: UUID
    /// 打包好的 zip 位置
    let zipURL: URL
    /// 包内片段数量
    let clipCount: Int
    /// 没有可导出文件的镜头数量。
    ///
    /// 判据是**磁盘上有没有文件**，与包内 `导出说明.txt` 的「仍待补拍的镜头」
    /// 同源，因此两个数字永远一致。
    let pendingCount: Int
    let totalDuration: TimeInterval
    let byteCount: Int64
    let createdAt: Date

    var fileName: String { zipURL.lastPathComponent }

    var summary: String {
        var parts = ["\(clipCount) 段视频"]
        if pendingCount > 0 { parts.append("\(pendingCount) 个待拍") }
        parts.append(totalDuration.slDurationText)
        return parts.joined(separator: " · ")
    }
}

/// 打包结果，用于从后台线程回传到主线程。
///
/// 这里不能用 `Result`：`any Error` 不满足 `Sendable`，跨不过隔离边界。
/// 失败信息在回传前退化成一段文本，界面上本来就是直接展示它。
enum ExportOutcome: Sendable {
    case success(ExportPackage)
    case failure(String)
}

enum ExportError: LocalizedError {
    case noClips
    case packagingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noClips:
            return "还没有拍摄任何分镜，先拍一段再导出吧。"
        case .packagingFailed(let reason):
            return "打包失败：\(reason)"
        }
    }
}

/// 把分镜与片段打包成一个可分享的 zip。
///
/// 一个镜头可能拍了好几条，导出时把最新的一条放在根目录当主素材，
/// 更早的片段收进「备用片段」目录，这样导入剪映时主素材顺序干净，
/// 想换某一条也有备份可选。
///
/// 包内结构：
/// ```
/// 分镜导出_20260914/
/// ├── 01_无人机缓慢上升.mov      每个镜头的最新一条
/// ├── 02_街景横摇.mov
/// ├── 备用片段/
/// │   ├── 01-1_无人机缓慢上升.mov  同一个镜头更早拍的
/// │   └── 01-2_无人机缓慢上升.mov
/// ├── 分镜清单.csv
/// ├── 分镜文字内容指南.md        给 AI 剪辑用的分镜文字内容与素材对应表
/// └── 导出说明.txt
/// ```
/// 视频按编号加前缀命名，这样导入剪映后素材顺序与分镜顺序一致。
///
/// 三类文本文件分工不同：`分镜清单.csv` 是给人看的表格；
/// `导出说明.txt` 讲怎么导入剪映、怎么传到电脑；
/// `分镜文字内容指南.md` 面向 AI——把每个镜头的文字描述与视频文件名严格绑定，
/// 并写明按分镜处理视频的规则，AI 拿到压缩包就能直接按分镜干活。
///
/// 整个类型是 `nonisolated`：它不持有状态，只按入参算结果，
/// 因此可以在任意线程上跑，不必占用主协程。
nonisolated enum ExportPackageBuilder {

    /// 备用片段子目录名
    static let alternateFolderName = "备用片段"

    /// 在后台线程打包。
    ///
    /// 打包要复制全部视频再压缩，属于重 I/O。用 `@concurrent` 明确要求它跑在
    /// 后台线程——按「非隔离的 async 函数」的默认语义，它会留在调用方所在的
    /// 主协程上，界面照样卡住。
    @concurrent
    static func buildOffMain(
        shots: [Shot],
        clipsDirectory: URL,
        scope: ExportScope
    ) async -> ExportOutcome {
        do {
            return .success(try build(shots: shots, clipsDirectory: clipsDirectory, scope: scope))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    static func build(
        shots: [Shot],
        clipsDirectory: URL,
        scope: ExportScope,
        fileManager: FileManager = .default
    ) throws -> ExportPackage {

        let recorded = shots.filter(\.hasClip)
        guard !recorded.isEmpty else { throw ExportError.noClips }

        let included: [Shot] = scope == .recordedOnly ? recorded : shots

        let now = Date()
        let folderName = "分镜导出_\(Self.dayToken(now))"
        let workingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ShotListExport", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = workingRoot.appendingPathComponent(folderName, isDirectory: true)

        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ExportError.packagingFailed(error.localizedDescription)
        }
        defer { try? fileManager.removeItem(at: workingRoot) }

        let alternateFolder = folder.appendingPathComponent(alternateFolderName, isDirectory: true)
        var didCreateAlternateFolder = false

        var totalDuration: TimeInterval = 0
        var manifest: [ManifestRow] = []

        for shot in included {
            let available = shot.clips.filter { clip in
                let url = clipsDirectory.appendingPathComponent(clip.fileName, isDirectory: false)
                return fileManager.fileExists(atPath: url.path)
            }

            guard let latest = available.latestByRecordedAt else {
                manifest.append(ManifestRow(pendingShot: shot))
                continue
            }

            let takeTotal = available.count

            for (offset, clip) in available.enumerated() {
                let takeIndex = offset + 1
                let isMain = clip.id == latest.id
                let fileName = Self.exportedFileName(
                    for: shot,
                    takeIndex: isMain ? nil : takeIndex,
                    fileExtension: Self.fileExtension(ofFileName: clip.fileName)
                )

                let destination: URL
                let exportedPath: String
                if isMain {
                    destination = folder.appendingPathComponent(fileName, isDirectory: false)
                    exportedPath = fileName
                } else {
                    if !didCreateAlternateFolder {
                        do {
                            try fileManager.createDirectory(at: alternateFolder, withIntermediateDirectories: true)
                            didCreateAlternateFolder = true
                        } catch {
                            throw ExportError.packagingFailed(error.localizedDescription)
                        }
                    }
                    destination = alternateFolder.appendingPathComponent(fileName, isDirectory: false)
                    exportedPath = "\(alternateFolderName)/\(fileName)"
                }

                let source = clipsDirectory.appendingPathComponent(clip.fileName, isDirectory: false)
                do {
                    try fileManager.copyItem(at: source, to: destination)
                } catch {
                    throw ExportError.packagingFailed(error.localizedDescription)
                }

                totalDuration += clip.duration ?? 0
                manifest.append(
                    ManifestRow(
                        shot: shot,
                        clip: clip,
                        takeIndex: takeIndex,
                        takeTotal: takeTotal,
                        exportedPath: exportedPath,
                        isMain: isMain
                    )
                )
            }
        }

        // 清单行是按**磁盘可用性**判的（`available.isEmpty` → 写一条无文件的行）。
        // 界面上那句「N 个待拍」必须读同一份结果，所以这里从清单里数，
        // 不再拿 JSON 的 `hasClip` 单独算一遍——两套判据会在「有记录、无文件」时打架。
        let pendingCount = manifest.filter { $0.exportedPath == nil }.count
        let clipCount = manifest.count - pendingCount
        guard clipCount > 0 else { throw ExportError.noClips }

        try Self.writeManifest(manifest, to: folder)
        try Self.writeReadme(manifest: manifest, folderName: folderName, scope: scope, to: folder)
        try Self.writeTextGuide(
            manifest: manifest,
            folderName: folderName,
            scope: scope,
            totalDuration: totalDuration,
            to: folder
        )

        let zipURL = try Self.zip(folder: folder, folderName: folderName, fileManager: fileManager)
        let size = (try? zipURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0

        return ExportPackage(
            id: UUID(),
            zipURL: zipURL,
            clipCount: clipCount,
            pendingCount: pendingCount,
            totalDuration: totalDuration,
            byteCount: size,
            createdAt: now
        )
    }

    /// 清空历史导出包所在的临时目录。
    ///
    /// 导出包是中间产物，只对生成它的那次会话有意义，因此应用启动时调用一次，
    /// 避免临时目录随着每次导出一直变大。
    static func cleanUp(fileManager: FileManager = .default) {
        let root = fileManager.temporaryDirectory.appendingPathComponent("ShotListExport", isDirectory: true)
        try? fileManager.removeItem(at: root)
    }

    /// 只保留最新一份 zip。
    ///
    /// 单次会话里连续导出多次时，历史包没有引用者（界面只展示最近一次的结果），
    /// 每次打完新包就把同目录里的旧包删掉，一次会话最多占一份全量体积。
    private static func pruneZips(in directory: URL, keeping current: URL, fileManager: FileManager) {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where url != current && url.pathExtension == "zip" {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - 内部实现

    private struct ManifestRow {
        let number: Int
        let detail: String
        let statusText: String
        let takeText: String
        let recordedAtText: String
        let durationText: String
        let exportedPath: String?
        /// 是否是这个镜头的主素材 —— 也就是收在根目录、而非「备用片段」目录里的那一条。
        ///
        /// 由 `build()` 在落盘时传进来。**不能**用「是不是最后一条」反推：
        /// 多条片段拍摄时间戳并列时，`max(by:)` 取的是第一条，反推出来的结论
        /// 会和真实落盘位置正好相反。
        let isMain: Bool

        /// 是否是「备用片段」目录里的更早片段
        var isAlternate: Bool { !isMain }

        /// 已拍片段
        init(
            shot: Shot,
            clip: ShotClip,
            takeIndex: Int,
            takeTotal: Int,
            exportedPath: String,
            isMain: Bool
        ) {
            self.number = shot.number
            self.detail = shot.displayDetail
            self.statusText = shot.status().title
            self.takeText = takeTotal > 1 ? "第 \(takeIndex) 条 / 共 \(takeTotal) 条" : "第 1 条"
            self.recordedAtText = clip.recordedAtText ?? ""
            self.durationText = clip.durationText ?? ""
            self.exportedPath = exportedPath
            self.isMain = isMain
        }

        /// 还没拍的镜头
        init(pendingShot shot: Shot) {
            self.number = shot.number
            self.detail = shot.displayDetail
            self.statusText = shot.status().title
            self.takeText = ""
            self.recordedAtText = ""
            self.durationText = ""
            self.exportedPath = nil
            self.isMain = false
        }
    }

    /// 主素材的文件名，例如「01_无人机缓慢上升.mov」。
    ///
    /// 编辑页拿它做实时预览，导出时走的是同一个函数，规则改动两边一起变。
    /// 扩展名由调用方给出（取自片段本身）：相册导入的 mp4 不该在这里被写成 `.mov`。
    static func mainFileName(number: Int, note: String, fileExtension: String = "mov") -> String {
        String(format: "%02d_%@.%@", number, sanitize(note), fileExtension)
    }

    /// 主素材（最新一条）不加序号后缀，备用片段带「-第几条」后缀
    private static func exportedFileName(
        for shot: Shot,
        takeIndex: Int?,
        fileExtension: String
    ) -> String {
        if let takeIndex {
            return String(format: "%02d-%d_%@.%@", shot.number, takeIndex, sanitize(shot.fileNameBase), fileExtension)
        }
        return mainFileName(number: shot.number, note: shot.fileNameBase, fileExtension: fileExtension)
    }

    /// 导出命名沿用源文件的扩展名，保证容器与扩展名一致
    private static func fileExtension(ofFileName fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "mov" : ext
    }

    /// 去掉文件名里不安全的字符，同时保留中文
    private static func sanitize(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = raw.components(separatedBy: illegal).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = trimmed.count > 24 ? String(trimmed.prefix(24)) : trimmed
        return limited.isEmpty ? "镜头" : limited
    }

    private static func writeManifest(_ rows: [ManifestRow], to folder: URL) throws {
        var csv = "编号,分镜描述,状态,片段,拍摄时间,时长,导出文件名\n"
        for row in rows {
            let fields = [
                String(format: "%02d", row.number),
                row.detail,
                row.statusText,
                row.takeText,
                row.recordedAtText,
                row.durationText,
                row.exportedPath ?? ""
            ]
            csv += fields.map(Self.csvField).joined(separator: ",") + "\n"
        }

        // 带 UTF-8 BOM，Excel / Numbers 打开中文不乱码
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(csv.utf8))

        let url = folder.appendingPathComponent("分镜清单.csv", isDirectory: false)
        try data.write(to: url, options: .atomic)
    }

    /// 按 CSV 规则转义一个字段。
    ///
    /// 逗号、引号、换行都必须整体加引号：分镜描述支持多行输入，
    /// 漏掉换行会把一条记录拆成两行，后面所有列跟着错位。
    private static func csvField(_ value: String) -> String {
        let needsQuoting = value.contains(",")
            || value.contains("\"")
            || value.contains("\n")
            || value.contains("\r")
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func writeReadme(
        manifest: [ManifestRow],
        folderName: String,
        scope: ExportScope,
        to folder: URL
    ) throws {
        let exported = manifest.filter { $0.exportedPath != nil }
        let shotCount = Set(exported.map(\.number)).count
        let alternateCount = exported.filter(\.isAlternate).count
        let pendingRows = manifest.filter { $0.exportedPath == nil }

        var text = """
        分镜助手 · 导出说明
        ============================

        导出时间：\(SLDateText.monthDayTime(Date()))
        导出范围：\(scope.title)
        镜头数量：\(shotCount)
        视频片段：\(exported.count)

        目录内容
        ----------------------------
        * 01_xxx.mov          每个镜头的主素材，取其最新拍的一条，文件名前缀即镜头编号
        * 备用片段/           同一个镜头更早拍的片段，命名形如 01-1_xxx.mov（第 1 条）
        * 分镜清单.csv        每个镜头的描述、状态与每条片段的时长、文件名
        * 分镜文字内容指南.md  每个镜头的文字内容与视频文件名对照表，供 AI 按分镜处理视频
        * 导出说明.txt        本文件

        导入剪映
        ----------------------------
        1. 解压本压缩包；
        2. 打开剪映，新建项目后点「导入」，选择根目录下的视频文件；
        3. 全部文件按编号前缀排序，导入顺序与分镜顺序一致；
        4. 想换某个镜头的素材，就到「备用片段」目录里挑，不导入时它们不占时间线。

        导入电脑
        ----------------------------
        * 隔空投送：在本 App 的「导出」页直接把压缩包 AirDrop 到 Mac；
        * 数据线：连接 iPhone 后，在「文件」App 的「我的 iPhone / 分镜助手」
          里可以找到全部分镜片段，直接拖到电脑即可；
        * 也可以在本 App「导出」页，选择「存储到文件」保存到 iCloud 云盘。

        """

        if alternateCount > 0 {
            text += "\n备用片段（\(alternateCount) 条）\n----------------------------\n"
            text += "主素材取每个镜头最新的一条，以下是同一个镜头更早拍的片段：\n"
            for row in exported where row.isAlternate {
                text += String(format: "%@  %@\n", row.exportedPath ?? "", row.detail)
            }
        }

        if !pendingRows.isEmpty {
            text += "\n仍待补拍的镜头\n----------------------------\n"
            for row in pendingRows {
                text += String(format: "%02d  %@\n", row.number, row.detail)
            }
        }

        let url = folder.appendingPathComponent("导出说明.txt", isDirectory: false)
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    // MARK: - 分镜文字内容指南（给 AI）

    /// 按编号把清单行并成「一个镜头一组」。
    ///
    /// 同一个镜头的多条片段在清单里是连续追加的，所以顺序扫一遍按编号合并即可，
    /// 不需要额外的字典。未拍的镜头也占一组，保证编号连续、不丢条目。
    private static func shotGroups(from manifest: [ManifestRow]) -> [(number: Int, rows: [ManifestRow])] {
        var groups: [(number: Int, rows: [ManifestRow])] = []
        for row in manifest {
            if let last = groups.last, last.number == row.number {
                groups[groups.count - 1].rows.append(row)
            } else {
                groups.append((row.number, [row]))
            }
        }
        return groups
    }

    /// 把描述压成单行：markdown 里一行一个字段，换行会打断对照关系。
    private static func singleLine(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "；")
    }

    /// 生成「分镜文字内容指南.md」。
    ///
    /// 面向 AI：把每个镜头的文字描述与包内视频文件名严格绑定，并写明处理规则。
    /// 字段固定、一行一项，换一个模型或换一次对话也能稳定解析。
    private static func writeTextGuide(
        manifest: [ManifestRow],
        folderName: String,
        scope: ExportScope,
        totalDuration: TimeInterval,
        to folder: URL
    ) throws {
        let groups = shotGroups(from: manifest)
        let clipCount = manifest.filter { $0.exportedPath != nil }.count
        let shotCount = groups.count
        let recordedShotCount = groups.filter { $0.rows.contains { $0.exportedPath != nil } }.count

        var text = """
        # 分镜文字内容指南

        本文件是「分镜助手」导出包的文字分镜表：把每个分镜的文字内容与同目录下的
        视频文件名绑定在一起。AI 剪辑工具可以直接按本文件处理视频，无需再问用户
        「哪段视频对应哪个镜头」。

        ## 一、素材与分镜的对应关系

        - 视频文件名以两位编号开头，编号即分镜编号，与「三、镜头清单」一一对应。
        - 根目录里的视频是每个镜头的主素材（该镜头最新拍的一条）。
        - 「备用片段」目录里是同一个镜头更早拍的片段，主素材不合适时用它替换；
          不需要替换时不要导入它们。
        - 未拍摄的镜头没有对应文件，按编号跳过，不占时间线。

        ## 二、按分镜处理视频的规则

        每个镜头的「分镜文字内容」就是这一段要表达的内容（拍摄对象、运镜方式、
        口播要点等），处理时一律以它为准：

        1. 按编号从小到大排列片段，编号顺序就是成片顺序；不要按文件名、
           文件大小或修改时间重新排序。
        2. 每个镜头只取一条素材：默认取主素材，需要替换时才到「备用片段」里
           挑同编号的其它片段。
        3. 分镜文字内容决定这一段的处理方式：
           - 描述画面或运镜的，作为画面选取与调色的依据；
           - 描述口播要点的，作为字幕文案依据，不要自行扩写或改写语义；
           - 描述动作或道具的，作为该段裁剪起止点的依据。
        4. 「时长」是该条素材的实际长度，用来估算成片节奏；不要臆造未提供的时长。
        5. 每个镜头的处理边界就是它自己的那段素材，不要把相邻镜头的内容并进一段。
        6. 标注「未拍摄」的镜头没有素材，直接跳过；若必须补齐，保留同样编号的空位。

        ## 三、镜头清单

        """

        for group in groups {
            let head = group.rows[0]
            text += "### 镜头 \(String(format: "%02d", group.number)) · \(singleLine(head.detail))\n"
            text += "- 分镜文字内容：\(singleLine(head.detail))\n"

            let exported = group.rows.filter { $0.exportedPath != nil }
            let main = exported.first { $0.isMain }

            if let main {
                text += "- 主素材文件：\(main.exportedPath ?? "")\n"
                text += "- 时长：\(main.durationText.isEmpty ? "未知" : main.durationText)\n"
                text += "- 拍摄时间：\(main.recordedAtText)\n"
                text += "- 状态：\(main.statusText)\n"
            } else {
                text += "- 未拍摄，无视频素材\n"
            }

            let alternates = exported.filter(\.isAlternate)
            if !alternates.isEmpty {
                let listed = alternates
                    .map { "\($0.exportedPath ?? "")（\($0.takeText)）" }
                    .joined(separator: "、")
                text += "- 备用片段：\(listed)\n"
            }

            text += "\n"
        }

        text += """
        ## 四、汇总

        - 导出范围：\(scope.title)
        - 分镜数量：\(shotCount)（已拍 \(recordedShotCount)，未拍 \(shotCount - recordedShotCount)）
        - 视频片段：\(clipCount)
        - 总时长：\(totalDuration.slDurationText)
        - 素材根目录：\(folderName)/

        """

        let url = folder.appendingPathComponent("分镜文字内容指南.md", isDirectory: false)
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// 使用 `NSFileCoordinator` 的系统压缩能力，把目录打成 zip。
    /// 协调器给出的临时 zip 在闭包结束后就会被删除，因此必须在闭包内完成拷贝。
    /// 打包成功后只保留这一份，同目录下的旧包一并清掉。
    private static func zip(folder: URL, folderName: String, fileManager: FileManager) throws -> URL {
        let outputDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ShotListExport", isDirectory: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let destination = outputDirectory
            .appendingPathComponent("\(folderName)_\(Self.timeToken(Date())).zip", isDirectory: false)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        var coordinatorError: NSError?
        var copyError: Error?
        var didCopy = false

        NSFileCoordinator().coordinate(
            readingItemAt: folder,
            options: [.forUploading],
            error: &coordinatorError
        ) { temporaryZipURL in
            do {
                try fileManager.copyItem(at: temporaryZipURL, to: destination)
                didCopy = true
            } catch {
                copyError = error
            }
        }

        if let coordinatorError {
            throw ExportError.packagingFailed(coordinatorError.localizedDescription)
        }
        if let copyError {
            throw ExportError.packagingFailed(copyError.localizedDescription)
        }
        guard didCopy else {
            throw ExportError.packagingFailed("系统未能生成压缩包")
        }
        Self.pruneZips(in: outputDirectory, keeping: destination, fileManager: fileManager)
        return destination
    }

    private static func dayToken(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    private static func timeToken(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HHmmss"
        return formatter.string(from: date)
    }
}
