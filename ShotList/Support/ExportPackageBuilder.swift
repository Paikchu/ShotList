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

    var footnote: String {
        switch self {
        case .recordedOnly: return "只打包已经拍摄的视频文件，适合直接拖进剪映剪辑。"
        case .everything: return "打包所有视频，并在清单里列出未拍镜头，方便补拍。"
        }
    }
}

/// 一次导出产出的文件包
struct ExportPackage: Identifiable, Equatable {
    let id: UUID
    /// 打包好的 zip 位置
    let zipURL: URL
    /// 包内视频数量
    let clipCount: Int
    /// 未拍摄的镜头数量
    let pendingCount: Int
    let totalDuration: TimeInterval
    let byteCount: Int64
    let createdAt: Date

    var fileName: String { zipURL.lastPathComponent }

    var summary: String {
        var parts = ["\(clipCount) 个视频"]
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

/// 把分镜与视频打包成一个可分享的 zip。
///
/// 包内结构：
/// ```
/// 分镜导出_20260914/
/// ├── 01_开场-城市天际线.mov
/// ├── 02_街景-慢速横摇.mov
/// ├── 分镜清单.csv
/// └── 导出说明.txt
/// ```
/// 视频按编号加前缀命名，这样导入剪映后素材顺序与分镜顺序一致。
enum ExportPackageBuilder {

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

        var totalDuration: TimeInterval = 0
        var manifest: [ManifestRow] = []

        for shot in included {
            guard let fileName = shot.clipFileName else {
                manifest.append(ManifestRow(shot: shot, exportedName: nil))
                continue
            }
            let source = clipsDirectory.appendingPathComponent(fileName, isDirectory: false)
            guard fileManager.fileExists(atPath: source.path) else {
                manifest.append(ManifestRow(shot: shot, exportedName: nil))
                continue
            }

            let exportedName = Self.exportedFileName(for: shot)
            let destination = folder.appendingPathComponent(exportedName, isDirectory: false)
            do {
                try fileManager.copyItem(at: source, to: destination)
            } catch {
                throw ExportError.packagingFailed(error.localizedDescription)
            }

            totalDuration += shot.clipDuration ?? 0
            manifest.append(ManifestRow(shot: shot, exportedName: exportedName))
        }

        try Self.writeManifest(manifest, to: folder)
        try Self.writeReadme(manifest: manifest, folderName: folderName, scope: scope, to: folder)

        let zipURL = try Self.zip(folder: folder, folderName: folderName, fileManager: fileManager)
        let size = (try? zipURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0

        return ExportPackage(
            id: UUID(),
            zipURL: zipURL,
            clipCount: manifest.filter { $0.exportedName != nil }.count,
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
        let title: String
        let statusText: String
        let recordedAtText: String
        let durationText: String
        let note: String
        let exportedName: String?

        init(shot: Shot, exportedName: String?) {
            self.number = shot.number
            self.title = shot.displayTitle
            self.statusText = shot.status().title
            self.recordedAtText = shot.recordedAtText ?? ""
            self.durationText = shot.durationText ?? ""
            self.note = shot.note.replacingOccurrences(of: "\n", with: " ")
            self.exportedName = exportedName
        }
    }

    private static func exportedFileName(for shot: Shot) -> String {
        let sanitized = sanitize(shot.displayTitle)
        return String(format: "%02d_%@.mov", shot.number, sanitized)
    }

    /// 去掉文件名里不安全的字符，同时保留中文
    private static func sanitize(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = raw.components(separatedBy: illegal).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = trimmed.count > 40 ? String(trimmed.prefix(40)) : trimmed
        return limited.isEmpty ? "镜头" : limited
    }

    private static func writeManifest(_ rows: [ManifestRow], to folder: URL) throws {
        var csv = "编号,标题,状态,拍摄时间,时长,导出文件名,备注\n"
        for row in rows {
            let fields = [
                String(format: "%02d", row.number),
                row.title,
                row.statusText,
                row.recordedAtText,
                row.durationText,
                row.exportedName ?? "",
                row.note
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
        let recordedCount = manifest.filter { $0.exportedName != nil }.count
        let pendingCount = manifest.count - recordedCount

        var text = """
        分镜助手 · 导出说明
        ============================

        导出时间：\(Date().formatted(Date.FormatStyle(date: .long, time: .shortened).locale(AppLocale.current)))
        导出范围：\(scope.title)
        视频数量：\(recordedCount)
        待拍镜头：\(pendingCount)

        目录内容
        ----------------------------
        * 01_xxx.mov  已拍摄的分镜视频，文件名前缀即镜头编号
        * 分镜清单.csv 每个镜头的编号、标题、状态、时长与备注
        * 导出说明.txt 本文件

        导入剪映
        ----------------------------
        1. 解压本压缩包；
        2. 打开剪映，新建项目后点「导入」，选择解压出的视频文件；
        3. 全部文件按编号前缀排序，导入顺序与分镜顺序一致。

        导入电脑
        ----------------------------
        * 隔空投送：在本 App 的「导出」页直接把压缩包 AirDrop 到 Mac；
        * 数据线：连接 iPhone 后，在「文件」App 的「我的 iPhone / 分镜助手」
          里可以找到全部分镜视频，直接拖到电脑即可；
        * 也可以在本 App「导出」页，选择「存储到文件」保存到 iCloud 云盘。

        """

        if pendingCount > 0 {
            text += "\n仍待补拍的镜头\n----------------------------\n"
            for row in manifest where row.exportedName == nil {
                text += String(format: "%02d  %@\n", row.number, row.title)
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
