import Foundation

/// 导出范围
enum ExportScope: String, CaseIterable, Identifiable {
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
struct ExportPackage: Identifiable, Equatable {
    let id: UUID
    /// 打包好的 zip 位置
    let zipURL: URL
    /// 包内片段数量
    let clipCount: Int
    /// 未拍摄的镜头数量
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
/// └── 导出说明.txt
/// ```
/// 视频按编号加前缀命名，这样导入剪映后素材顺序与分镜顺序一致。
enum ExportPackageBuilder {

    /// 备用片段子目录名
    static let alternateFolderName = "备用片段"

    static func build(
        shots: [Shot],
        clipsDirectory: URL,
        scope: ExportScope,
        fileManager: FileManager = .default
    ) throws -> ExportPackage {

        let recorded = shots.filter(\.hasClip)
        guard !recorded.isEmpty else { throw ExportError.noClips }

        let included: [Shot] = scope == .recordedOnly ? recorded : shots
        let pending = included.filter { !$0.hasClip }

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

            guard let latest = available.max(by: { $0.recordedAt < $1.recordedAt }) else {
                manifest.append(ManifestRow(pendingShot: shot))
                continue
            }

            let takeTotal = available.count

            for (offset, clip) in available.enumerated() {
                let takeIndex = offset + 1
                let isMain = clip.id == latest.id
                let fileName = Self.exportedFileName(for: shot, takeIndex: isMain ? nil : takeIndex)

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
                        exportedPath: exportedPath
                    )
                )
            }
        }

        try Self.writeManifest(manifest, to: folder)
        try Self.writeReadme(manifest: manifest, folderName: folderName, scope: scope, to: folder)

        let zipURL = try Self.zip(folder: folder, folderName: folderName, fileManager: fileManager)
        let size = (try? zipURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0

        return ExportPackage(
            id: UUID(),
            zipURL: zipURL,
            clipCount: manifest.filter { $0.exportedPath != nil }.count,
            pendingCount: pending.count,
            totalDuration: totalDuration,
            byteCount: size,
            createdAt: now
        )
    }

    /// 清理历史导出包，避免临时目录堆积
    static func cleanUp(fileManager: FileManager = .default) {
        let root = fileManager.temporaryDirectory.appendingPathComponent("ShotListExport", isDirectory: true)
        try? fileManager.removeItem(at: root)
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
        /// 是否是「备用片段」目录里的更早片段
        let isAlternate: Bool

        /// 已拍片段
        init(shot: Shot, clip: ShotClip, takeIndex: Int, takeTotal: Int, exportedPath: String) {
            self.number = shot.number
            self.detail = shot.displayDetail
            self.statusText = shot.status().title
            self.takeText = takeTotal > 1 ? "第 \(takeIndex) 条 / 共 \(takeTotal) 条" : "第 1 条"
            self.recordedAtText = clip.recordedAtText ?? ""
            self.durationText = clip.durationText ?? ""
            self.exportedPath = exportedPath
            self.isAlternate = takeTotal > 1 && takeIndex != takeTotal
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
            self.isAlternate = false
        }
    }

    /// 主素材的文件名，例如「01_无人机缓慢上升.mov」。
    ///
    /// 编辑页拿它做实时预览，导出时走的是同一个函数，规则改动两边一起变。
    static func mainFileName(number: Int, note: String) -> String {
        String(format: "%02d_%@.mov", number, sanitize(note))
    }

    /// 主素材（最新一条）不加序号后缀，备用片段带「-第几条」后缀
    private static func exportedFileName(for shot: Shot, takeIndex: Int?) -> String {
        if let takeIndex {
            return String(format: "%02d-%d_%@.mov", shot.number, takeIndex, sanitize(shot.fileNameBase))
        }
        return mainFileName(number: shot.number, note: shot.fileNameBase)
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

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") else { return value }
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
        * 01_xxx.mov   每个镜头的主素材，取其最新拍的一条，文件名前缀即镜头编号
        * 备用片段/    同一个镜头更早拍的片段，命名形如 01-1_xxx.mov（第 1 条）
        * 分镜清单.csv 每个镜头的描述、状态与每条片段的时长、文件名
        * 导出说明.txt 本文件

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

    /// 使用 `NSFileCoordinator` 的系统压缩能力，把目录打成 zip。
    /// 协调器给出的临时 zip 在闭包结束后就会被删除，因此必须在闭包内完成拷贝。
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
