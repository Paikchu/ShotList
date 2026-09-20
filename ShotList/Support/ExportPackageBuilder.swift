import Foundation
import Synchronization

/// 导出范围
nonisolated enum ExportScope: String, CaseIterable, Identifiable {
    /// 只导出已经拍好的镜头
    case recordedOnly
    /// 导出全部分镜，未拍摄的镜头在清单里标注
    case everything

    var id: String { rawValue }

    /// 写进导出包文档里的完整说法（给人和 AI 读，不改短）
    var title: String {
        switch self {
        case .recordedOnly: return "仅已拍镜头"
        case .everything: return "全部分镜"
        }
    }

    /// 界面上分段选择器里的短标签，与历史页的「已拍 / 全部」同一套说法
    var label: String {
        switch self {
        case .recordedOnly: return "已拍"
        case .everything: return "全部"
        }
    }
}

/// 导出时的视频格式：要不要转码、转成什么格式。
///
/// 导入与拍摄都保留原始文件（相册导入显式要求「原片」，见 `ImportedMovie`），
/// 所以默认导出就是原片——画质、体积、耗时都保持原样。要发给微信、或者在老设备上
/// 播放，才需要在这一步换一个格式：**导入只做一次，导出可以按需选**，
/// 不必为了某一次分享把库里的素材统一压一遍。
nonisolated enum ExportTranscodeOption: String, CaseIterable, Identifiable {
    /// 原片：不转码，直接复制
    case original
    /// 兼容优先：H.264，最高 1080p
    case compatible
    /// 体积优先：HEVC，最高 1080p
    case compact

    var id: String { rawValue }

    /// 转码后统一写 QuickTime 容器，扩展名与 `MediaTranscode.containerFileType` 同一处定义
    static var transcodeFileExtension: String { "mov" }

    /// 选项持久化的键。导出页与镜头面板读同一个键，取值只有一处来源。
    static let storageKey = "export.transcodeOption"

    var title: String {
        switch self {
        case .original: return "原片"
        case .compatible: return "H.264 · 1080p"
        case .compact: return "HEVC · 1080p"
        }
    }

    /// 写进 `导出说明.txt` 的格式说明
    var documentText: String {
        switch self {
        case .original: return "原片（未转码）"
        case .compatible: return "H.264 · 最高 1080p（导出时转码）"
        case .compact: return "HEVC · 最高 1080p（导出时转码）"
        }
    }

    /// 是否需要真的转码
    var needsTranscode: Bool { self != .original }

    /// 导出时用的扩展名：转码后统一 `mov`，不转码时沿用源文件。
    ///
    /// 镜头面板的文件名预览、导出页的示例名与实际打包都走这一个函数，
    /// 否则会出现「页面上写着 .mp4、导出的却是 .mov」这种漂移。
    func exportedFileExtension(sourceExtension: String) -> String {
        needsTranscode ? Self.transcodeFileExtension : sourceExtension
    }
}

/// 一次打包的输入。
///
/// 收成一个值而不是继续加参数：范围、格式这些「用户选了什么」每加一项，
/// 参数列表和调用点都要跟着改一遍。
nonisolated struct ExportRequest: Sendable, Equatable {
    let shots: [Shot]
    let clipsDirectory: URL
    let scope: ExportScope
    let option: ExportTranscodeOption
    /// 这次导出属于哪部影片。包名用它做前缀（为空时退回纯日期命名），
    /// 包内两个文本文件也写一行「影片：…」。
    ///
    /// 归到 request 而不是另开参数：它和范围、格式一样是「用户这次要导什么」，
    /// 加参数的话每个调用点都要跟着改一遍。
    let filmTitle: String
    /// 这部影片的剪辑风格：**一段描述**，原样写进包内的「剪辑风格.md」。
    ///
    /// 同样归到 request：导出期间用户在风格页改了这段描述，这份产物就不再对应当前设定。
    /// 留空表示这部片子没有特别要求，包里不会出现那个文件。
    let stylePrompt: String

    init(
        shots: [Shot],
        clipsDirectory: URL,
        scope: ExportScope,
        option: ExportTranscodeOption,
        filmTitle: String,
        stylePrompt: String = ""
    ) {
        self.shots = shots
        self.clipsDirectory = clipsDirectory
        self.scope = scope
        self.option = option
        self.filmTitle = filmTitle
        self.stylePrompt = stylePrompt
    }
}

/// 打包进度。
///
/// 转码一段几十秒的素材可能要好几十秒，没有进度的话界面只剩一个转圈，
/// 用户会以为卡死了——包越大越明显，所以进度按「第几条 / 共几条」给出。
nonisolated struct ExportProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        /// 正在转码下一条
        case transcoding
        /// 正在压缩打包
        case packaging
    }

    let phase: Phase
    /// 已经处理完的片段数
    let completed: Int
    /// 本次要处理的片段总数
    let total: Int

    var fraction: Double {
        switch phase {
        case .transcoding: return total > 0 ? min(1, Double(completed) / Double(total)) : 0
        case .packaging: return 1
        }
    }

    var text: String {
        switch phase {
        case .transcoding: return "转码 \(completed + 1) / \(total)"
        case .packaging: return "打包中"
        }
    }
}

/// 取消信号。
///
/// 打包在后台线程上跑，置位的是主协程，所以它得是个能跨线程共享的引用类型；
/// 用原子量而不是锁，读它的地方（每段素材一次）不值得去争一把锁。
nonisolated final class ExportCancellation: Sendable {
    private let flag = Atomic<Bool>(false)

    var isCancelled: Bool { flag.load(ordering: .relaxed) }

    func cancel() { flag.store(true, ordering: .relaxed) }
}

/// 一次打包的运行上下文：进度回传 + 取消信号。
///
/// 打包侧与界面侧只通过这一个值联系。它自己是 `Sendable` 的，所以调用方不必
/// 为每个参数单独标注，测试也能直接传一个空的上下文进来。
nonisolated struct ExportRun: Sendable {
    let cancellation: ExportCancellation
    let publish: @Sendable (ExportProgress) async -> Void

    init(
        cancellation: ExportCancellation = ExportCancellation(),
        publish: @Sendable @escaping (ExportProgress) async -> Void = { _ in }
    ) {
        self.cancellation = cancellation
        self.publish = publish
    }

    /// 本次已作废。转码是几十秒级别的事，作废之后必须尽快停手。
    func checkCancellation() throws {
        if cancellation.isCancelled { throw CancellationError() }
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
        var parts = ["\(clipCount) 段"]
        if pendingCount > 0 { parts.append("待拍 \(pendingCount)") }
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
    case transcodeFailed(fileName: String, reason: String)
    case insufficientSpace(required: Int64?, available: Int64?)

    var errorDescription: String? {
        switch self {
        case .noClips:
            return "无可导出的视频"
        case .transcodeFailed(let fileName, let reason):
            return "转码失败：\(fileName)（\(reason)）。请将格式改为「原片」后重试。"
        case .insufficientSpace(let required, let available):
            if let required, let available {
                return "存储空间不足：需要 \(required.slByteText)，可用 \(available.slByteText)。请释放空间后重试。"
            }
            return "存储空间不足。请释放空间后重试。"
        case .packagingFailed(let reason):
            return "打包失败：\(reason)"
        }
    }
}

/// 把分镜与片段打包成一个可分享的 zip。
///
/// 一个镜头可能拍了好几条，导出时**每一条都会进包**：最新的一条放在根目录当主素材，
/// 更早的片段收进「备用片段」目录，这样导入剪映时主素材顺序干净，
/// 想换某一条也有备份可选。
///
/// 命名规则：`影片标题-分镜号[-片段序号]`。同一个分镜拍了好几条、需要二选一时，
/// 靠片段序号区分（数字越大拍得越晚）：`夏日vlog-01-1.mov`、`夏日vlog-01-2.mov`、
/// `夏日vlog-01-3.mov`（第 3 条是主素材）；只拍一条的镜头不带片段序号，写作
/// `夏日vlog-02.mov`。**分镜描述不进文件名**（见 `exportedFileName`）。
///
/// 包内结构（影片「夏日vlog」，镜头 01 拍了 3 条、镜头 02 拍了 1 条）：
/// ```
/// 分镜导出_夏日vlog_20260914/
/// ├── 夏日vlog-01-3.mov   每个镜头的最新一条
/// ├── 夏日vlog-02.mov
/// ├── 备用片段/
/// │   ├── 夏日vlog-01-1.mov  同一个镜头更早拍的
/// │   └── 夏日vlog-01-2.mov
/// ├── 分镜清单.csv
/// ├── 分镜文字内容指南.md        给 AI 剪辑用的分镜文字内容与素材对应表
/// ├── 剪辑风格.md                这部影片的剪辑要求（用户写的一段话），没有要求时不产出
/// └── 导出说明.txt
/// ```
/// 同一部影片的每个片段都带同一个片名前缀，后面的分镜号才是排序依据，
/// 因此导入剪映后素材顺序仍与分镜顺序一致。
///
/// 视频格式默认是**原片**（导入与拍摄都保留原始文件），需要小体积或更好的兼容性时，
/// 由用户在导出页选一个转码格式（`ExportTranscodeOption`）——打包时逐条重编，
/// 不转码就逐条复制。
///
/// 四个文本文件分工不同：`分镜清单.csv` 是给人看的表格（也便于脚本解析，
/// 逐镜的屏幕字幕与角标文字都在这里）；`导出说明.txt` 讲怎么导入剪映、怎么传到电脑；
/// `分镜文字内容指南.md` 面向 AI——把每个镜头的三样文字（描述、字幕、角标）
/// 与视频文件名严格绑定，并写明按分镜处理视频的规则；`剪辑风格.md` 也面向 AI，
/// 但管的是**影片级**的那一层——怎么剪、要什么观感。
///
/// 影片级与镜头级的分界：**怎么剪**（画幅、节奏、时长、图层位置与样式）是整片一套，
/// 由用户写在那段风格描述里；**内容**（每镜写什么字）在指南与 CSV 里，逐镜给出。
/// 这条线让「不要自行扩写或改写语义」成为可执行的要求：要显示的字已经写好了，
/// 剪辑侧没有需要猜的地方。
///
/// 整个类型是 `nonisolated`：它不持有状态，只按入参算结果，
/// 因此可以在任意线程上跑，不必占用主协程。
nonisolated enum ExportPackageBuilder {

    /// 备用片段子目录名
    static let alternateFolderName = "备用片段"

    /// 在后台线程打包。
    ///
    /// 打包要复制或转码全部视频再压缩，属于重 I/O 与重 CPU。用 `@concurrent` 明确要求
    /// 它跑在后台线程——按「非隔离的 async 函数」的默认语义，它会留在调用方所在的
    /// 主协程上，界面照样卡住。
    ///
    /// `run` 里的进度回调每处理完一段素材触发一次，调用方负责把它送回主协程。
    /// 这里每次都 `await` 完再继续，所以进度只会往前走，不会跳回去。
    @concurrent
    static func buildOffMain(_ request: ExportRequest, run: ExportRun = ExportRun()) async -> ExportOutcome {
        do {
            return .success(try await build(request, run: run))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// 打包一次导出。
    ///
    /// `transcode` 可注入：单元测试里换成假实现，就能在不准备真实视频文件的前提下
    /// 验证「选了转码就不再复制源文件」这条接线。
    static func build(
        _ request: ExportRequest,
        run: ExportRun = ExportRun(),
        fileManager: FileManager = .default,
        availableCapacity: (URL) throws -> Int64? = availableCapacity,
        transcode: @Sendable (URL, URL, ExportTranscodeOption) async throws -> Void = {
            try await MediaTranscode.export(source: $0, to: $1, option: $2)
        }
    ) async throws -> ExportPackage {
        do {
            return try await buildChecked(request, run: run, fileManager: fileManager,
                                          availableCapacity: availableCapacity, transcode: transcode)
        } catch {
            throw exportFailure(error)
        }
    }

    private static func buildChecked(
        _ request: ExportRequest, run: ExportRun, fileManager: FileManager,
        availableCapacity: (URL) throws -> Int64?,
        transcode: @Sendable (URL, URL, ExportTranscodeOption) async throws -> Void
    ) async throws -> ExportPackage {

        let shots = request.shots
        let clipsDirectory = request.clipsDirectory
        let scope = request.scope
        let option = request.option
        // 影片标题也是这次导出的输入：包名与包内两个文本文件都要用它，
        // 所以跟范围、格式一起装在 request 里，而不是再挂一个参数。
        let filmTitle = request.filmTitle
        // 剪辑风格描述也是这次导出的输入：它整段写进包内的「剪辑风格.md」，
        // 包里那份要求必须与用户按下「生成导出包」那一刻写的一致。
        //
        // 在这里就裁掉首尾空白：空描述等于没写（不产出文件），而指南里那句
        // 「本片有那份文件」必须与「文件到底写没写」同源，不能一处按原文判、一处按裁过判。
        let stylePrompt = request.stylePrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        // 「有东西可导」以**磁盘**为准：JSON 里记着片段、文件却已经不在磁盘上时
        // （外部删除 / 拷贝中断 / 备份恢复），按 `hasClip` 判定会一路走到
        // 「每个镜头都是待拍」，最后产出一个一个视频都没有的空包。
        let recorded = shots.filter { shot in
            shot.clips.contains { clip in
                fileManager.fileExists(
                    atPath: clipsDirectory.appendingPathComponent(clip.fileName, isDirectory: false).path
                )
            }
        }
        guard !recorded.isEmpty else { throw ExportError.noClips }

        let included: [Shot] = scope == .recordedOnly ? recorded : shots

        // 按未压缩体积估算工作副本、系统临时 zip 和最终 zip 的同时占用，
        // 再留文本/压缩开销余量。这是保守预算，不是声称实际峰值固定为三倍。
        // 转码时工作副本是重编出来的，可能比源文件还大（H.264 的码率高于 HEVC），
        // 所以这一档再放宽一份。
        let required = try storageBudget(
            for: included, clipsDirectory: clipsDirectory, fileManager: fileManager,
            workingCopyMultiplier: option.needsTranscode ? 4 : 3
        )
        if let available = try? availableCapacity(fileManager.temporaryDirectory), available < required {
            throw ExportError.insufficientSpace(required: required, available: max(0, available))
        }

        // 进度分母：磁盘上真有文件、会进包的片段数
        let totalClips = included.reduce(0) { sum, shot in
            sum + shot.clips.filter { clip in
                fileManager.fileExists(
                    atPath: clipsDirectory.appendingPathComponent(clip.fileName, isDirectory: false).path
                )
            }.count
        }
        var processedClips = 0

        let now = Date()
        let folderName = Self.folderName(filmTitle: filmTitle, date: now)
        let workingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ShotListExport", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = workingRoot.appendingPathComponent(folderName, isDirectory: true)

        defer { try? fileManager.removeItem(at: workingRoot) }
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw Self.exportFailure(error)
        }

        let alternateFolder = folder.appendingPathComponent(alternateFolderName, isDirectory: true)
        var didCreateAlternateFolder = false

        var totalDuration: TimeInterval = 0
        var manifest: [ManifestRow] = []

        for shot in included {
            try run.checkCancellation()

            let available = shot.clips.enumerated().filter { _, clip in
                let url = clipsDirectory.appendingPathComponent(clip.fileName, isDirectory: false)
                return fileManager.fileExists(atPath: url.path)
            }

            guard let latest = available.map(\.element).latestByRecordedAt else {
                manifest.append(ManifestRow(pendingShot: shot))
                continue
            }

            let takeTotal = shot.clips.count

            for (offset, clip) in available {
                try run.checkCancellation()

                let takeIndex = offset + 1
                let isMain = clip.id == latest.id
                let fileName = Self.exportedFileName(
                    // 影片标题进文件名：同一个导出包里的片段一眼看出属于哪部片子。
                    filmTitle: filmTitle,
                    number: shot.number,
                    // 使用快照里的原始条号，缺失素材留下空号，不重编号。
                    // 只有一条时不带片段序号。
                    takeIndex: takeTotal > 1 ? takeIndex : nil,
                    // 扩展名跟随源文件；选了转码就换成转码后的容器，
                    // 与镜头面板、导出页示例读的是同一处规则。
                    fileExtension: option.exportedFileExtension(
                        sourceExtension: Self.fileExtension(ofFileName: clip.fileName)
                    )
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
                            throw Self.exportFailure(error)
                        }
                    }
                    destination = alternateFolder.appendingPathComponent(fileName, isDirectory: false)
                    exportedPath = "\(alternateFolderName)/\(fileName)"
                }

                let source = clipsDirectory.appendingPathComponent(clip.fileName, isDirectory: false)
                // 进度要在**动手之前**报：转码一段素材是几十秒级别的事，
                // 报在后面等于整段时间界面都停在「上一条的进度」上。
                if option.needsTranscode {
                    await run.publish(
                        ExportProgress(phase: .transcoding, completed: processedClips, total: totalClips)
                    )
                }
                do {
                    if option.needsTranscode {
                        try await transcode(source, destination, option)
                    } else {
                        try fileManager.copyItem(at: source, to: destination)
                    }
                } catch {
                    // 取消不是失败，别把它翻译成「转码失败」让用户去改格式
                    if error is CancellationError { throw error }
                    if option.needsTranscode {
                        throw ExportError.transcodeFailed(fileName: fileName, reason: error.localizedDescription)
                    }
                    throw Self.exportFailure(error)
                }
                processedClips += 1

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

        // 素材都到位了，剩下的是压缩打包
        await run.publish(ExportProgress(phase: .packaging, completed: totalClips, total: totalClips))
        try run.checkCancellation()

        try Self.writeManifest(manifest, to: folder)
        try Self.writeReadme(manifest: manifest, folderName: folderName, scope: scope,
                             filmTitle: filmTitle, option: option, to: folder)
        try Self.writeTextGuide(
            manifest: manifest,
            folderName: folderName,
            scope: scope,
            filmTitle: filmTitle,
            option: option,
            hasStylePrompt: !stylePrompt.isEmpty,
            totalDuration: totalDuration,
            to: folder
        )
        try Self.writeStylePrompt(stylePrompt, filmTitle: filmTitle, to: folder)

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

    private static func availableCapacity(at url: URL) throws -> Int64? {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init)
    }

    /// 估算本次导出要预留的空间。
    ///
    /// `workingCopyMultiplier` 是工作副本的放大系数：不转码时工作副本就是源文件
    /// 的克隆（占 1 份），转码时是重编出来的新文件，源文件还在，且 H.264 的体积
    /// 可能超过 HEVC 源文件，所以调高一份。两者都再叠加系统临时 zip 与最终 zip。
    private static func storageBudget(
        for shots: [Shot],
        clipsDirectory: URL,
        fileManager: FileManager,
        workingCopyMultiplier: Int64 = 3
    ) throws -> Int64 {
        var bytes: Int64 = 0
        var textBytes: Int64 = 0
        for shot in shots {
            textBytes += Int64(shot.note.utf8.count) * 8 + 4096
            for clip in shot.clips {
                let url = clipsDirectory.appendingPathComponent(clip.fileName)
                guard fileManager.fileExists(atPath: url.path) else { continue }
                bytes += Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                textBytes += 4096
            }
        }
        return bytes * workingCopyMultiplier + bytes / 50 + textBytes * 3 + 16 * 1024 * 1024
    }

    /// 保留系统错误类型直到这里，避免嵌套的磁盘满错误提前退化成普通字符串。
    static func exportFailure(_ error: Error) -> ExportError {
        if let error = error as? ExportError { return error }
        let failure = error as NSError
        if (failure.domain == NSCocoaErrorDomain && failure.code == NSFileWriteOutOfSpaceError)
            || (failure.domain == NSPOSIXErrorDomain && failure.code == POSIXErrorCode.ENOSPC.rawValue) {
            return .insufficientSpace(required: nil, available: nil)
        }
        if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? Error,
           case .insufficientSpace = exportFailure(underlying) {
            return .insufficientSpace(required: nil, available: nil)
        }
        return .packagingFailed(error.localizedDescription)
    }

    /// 清空历史导出包所在的临时目录。
    ///
    /// 导出包是中间产物，只对生成它的那次会话有意义，因此应用启动时调用一次，
    /// 避免临时目录随着每次导出一直变大。
    static func cleanUp(fileManager: FileManager = .default) {
        let root = fileManager.temporaryDirectory.appendingPathComponent("ShotListExport", isDirectory: true)
        try? fileManager.removeItem(at: root)
    }

    // MARK: - 内部实现

    private struct ManifestRow {
        let number: Int
        let detail: String
        /// 屏幕字幕文案（用户自己写的，剪辑侧原样使用）
        let caption: String
        /// 常驻角标文字（用户写的完整文字，例如「热量缺口：1758千卡」）
        let badgeText: String
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
            // 字幕与角标是**镜头级**的，会在同一个镜头的每一条片段上重复。
            // 与 `detail` 一样是按镜头而非按片段的信息，重复是为了让每一行自洽：
            // 剪辑侧挑中「备用片段」那一行时，字幕与角标不用回头再找。
            self.caption = shot.trimmedCaption
            self.badgeText = shot.trimmedBadgeText
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
            self.caption = shot.trimmedCaption
            self.badgeText = shot.trimmedBadgeText
            self.statusText = shot.status().title
            self.takeText = ""
            self.recordedAtText = ""
            self.durationText = ""
            self.exportedPath = nil
            self.isMain = false
        }
    }

    /// 导出文件名：`影片标题-分镜号[-片段序号]`，扩展名由调用方给出。
    ///
    /// 例：`夏日vlog-01.mov`（这个分镜只拍了一条）、`夏日vlog-01-3.mov`（第 3 条）。
    ///
    /// `takeIndex` 非 nil 时带上片段序号——同一个分镜拍了好几条、要在里面挑一条时，
    /// 靠它区分先后（数字越大拍得越晚）；只拍一条时不带，名字短一截，也不会让人
    /// 误以为还有别的候选。
    ///
    /// **分镜描述不进文件名**：描述是给人读的整句话，进了文件名会又长又容易重名
    /// （同一部片子里好几个镜头写着差不多的描述），而且改一次描述就换一次文件名。
    /// 编号才是稳定的身份，描述与编号的对应关系写在包内的「分镜清单.csv」与
    /// 「分镜文字内容指南.md」里。
    ///
    /// 影片标题为空时省掉标题那一节（`01.mov`），不写「未命名影片」：
    /// 那几个字对辨认没有帮助，只会让每个文件名都长一截。
    static func exportedFileName(
        filmTitle: String,
        number: Int,
        takeIndex: Int?,
        fileExtension: String
    ) -> String {
        let numberPart = takeIndex.map { String(format: "%02d-%d", number, $0) }
            ?? String(format: "%02d", number)
        let title = sanitizedToken(filmTitle)
        let base = title.isEmpty ? numberPart : "\(title)-\(numberPart)"
        return "\(base).\(fileExtension)"
    }

    /// 导出命名沿用源文件的扩展名，保证容器与扩展名一致
    private static func fileExtension(ofFileName fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "mov" : ext
    }

    /// 清掉文件名里不安全的字符（中文保留），并裁到 24 字。
    ///
    /// 清完什么都不剩时返回空串，由调用方决定怎么兜底：目录名要写「镜头」，
    /// 影片标题则应该整节省掉——文件名里塞一个占位词只让名字更长。
    private static func sanitizedToken(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = raw.components(separatedBy: illegal).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 24 ? String(trimmed.prefix(24)) : trimmed
    }

    /// 目录名用的清理：不允许空串，兜底为「镜头」
    private static func sanitize(_ raw: String) -> String {
        let cleaned = sanitizedToken(raw)
        return cleaned.isEmpty ? "镜头" : cleaned
    }

    /// 生成「分镜清单.csv」。
    ///
    /// 列顺序刻意把**内容**放在前面（描述、字幕、角标），拍摄相关的元数据靠后：
    /// 剪辑侧与用户真正要读的是前三列，元数据是补充。
    ///
    /// 「屏幕字幕」与「角标文字」是镜头级字段，同一个镜头的每条片段都会重复一遍
    /// ——这两列在任何一行上取都是对的，不必回头去别的行找。
    private static func writeManifest(_ rows: [ManifestRow], to folder: URL) throws {
        var csv = "编号,分镜描述,屏幕字幕,角标文字,状态,片段,拍摄时间,时长,导出文件名\n"
        for row in rows {
            let fields = [
                String(format: "%02d", row.number),
                row.detail,
                row.caption,
                row.badgeText,
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

    /// 生成「剪辑风格.md」：用户在风格页写的那段描述，原样落盘。
    ///
    /// 这是包里唯一说明**怎么剪**的文件。以前这一层是 `剪辑规格.json`（十几项硬参数），
    /// 现在改成一段自然语言——消费它的本来就是能读自然语言的剪辑工具，
    /// 而固定字段既加不完，也表达不了字段之外的偏好（「快切不拖沓」「别加音乐」）。
    ///
    /// 只加一行标题说明它是什么，正文**一字不改**：用户写的就是要执行的。
    /// 描述为空时整个文件不产出——一个空文件会让剪辑侧以为「有要求但没写清」，
    /// 而事实是这条片子没有特别要求。入参已由调用方裁掉首尾空白，这里的判空
    /// 与指南里那句「本片有没有那份文件」用的是同一个值。
    private static func writeStylePrompt(_ prompt: String, filmTitle: String, to folder: URL) throws {
        guard !prompt.isEmpty else { return }

        let text = """
        # 剪辑风格 · \(filmDisplayTitle(filmTitle))

        下面是这部影片的剪辑要求，**照它剪**。写到哪几条就按哪几条来，
        没提到的部分按常规处理；本片的分镜内容见同目录「分镜文字内容指南.md」。

        ---

        \(prompt)

        """

        let url = folder.appendingPathComponent("剪辑风格.md", isDirectory: false)
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// 按 CSV 规则转义一个字段。
    ///
    /// 逗号、引号、换行都必须整体加引号：分镜描述与屏幕字幕都支持多行输入，
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
        filmTitle: String,
        option: ExportTranscodeOption,
        to folder: URL
    ) throws {
        let exported = manifest.filter { $0.exportedPath != nil }
        let shotCount = Set(exported.map(\.number)).count
        let alternateCount = exported.filter(\.isAlternate).count
        let pendingRows = manifest.filter { $0.exportedPath == nil }

        // 目录说明里的例子由命名函数生成，而不是写死一段文案：
        // 片名有没有、扩展名换成什么，说明里的例子都跟着实际落盘的名字一起变。
        let singleName = exportedFileName(filmTitle: filmTitle, number: 1, takeIndex: nil, fileExtension: "mov")
        let multiName = exportedFileName(filmTitle: filmTitle, number: 1, takeIndex: 3, fileExtension: "mov")
        let alternateName = exportedFileName(filmTitle: filmTitle, number: 1, takeIndex: 1, fileExtension: "mov")

        var text = """
        分镜助手 · 导出说明
        ============================

        影片：\(filmDisplayTitle(filmTitle))
        导出时间：\(SLDateText.monthDayTime(Date()))
        导出范围：\(scope.title)
        视频格式：\(option.documentText)
        镜头数量：\(shotCount)
        视频片段：\(exported.count)

        目录
        ----------------------------
        * \(singleName)          主素材（每个镜头最新一条），数字为镜头编号；多条时带片段序号，如 \(multiName)
        * 备用片段/               更早的片段，如 \(alternateName)
        * 分镜清单.csv            各镜头的描述、字幕、角标与片段信息
        * 分镜文字内容指南.md      文字内容与文件名对照，供 AI 使用
        * 剪辑风格.md             剪辑要求
        * 导出说明.txt            本文件

        导入剪映
        ----------------------------
        1. 解压。
        2. 剪映：新建项目 › 导入，选择根目录下的视频。
        3. 按文件名排序即分镜顺序。
        4. 换素材：从「备用片段」中选取。

        传到电脑
        ----------------------------
        * 隔空投送：在「导出」页分享压缩包。
        * 数据线：「文件」› 我的 iPhone › 分镜助手。
        * iCloud：分享 › 存储到「文件」。

        """

        if alternateCount > 0 {
            text += "\n备用片段（\(alternateCount)）\n----------------------------\n"
            for row in exported where row.isAlternate {
                text += String(format: "%@  %@\n", row.exportedPath ?? "", row.detail)
            }
        }

        if !pendingRows.isEmpty {
            text += "\n待拍\n----------------------------\n"
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

    /// 把一条逐镜文字写成「要原样显示的字」或「这一镜没有」。
    ///
    /// 有内容时用反引号包起来（换行写成 `\n`），空的时候写 `—`。
    /// 反引号是这套文件里「这是字面内容」的约定：剪辑侧看到反引号就照抄，
    /// 看到 `—` 就知道这一镜不该有这一项，不必再去猜一行空白是「没填」还是「故意留空」。
    private static func quotedIfPresent(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }
        // 换行写成 `\n` 而不是真的断行：这一行的字段是「字幕文案」，
        // 真的断行会让它看起来像两条不同的字段。
        let escaped = trimmed.replacingOccurrences(of: "\n", with: "\\n")
        return "`\(escaped)`"
    }

    /// 生成「分镜文字内容指南.md」。
    ///
    /// 面向 AI：把每个镜头的文字描述与包内视频文件名严格绑定，并写明处理规则。
    /// 字段固定、一行一项，换一个模型或换一次对话也能稳定解析。
    ///
    /// 「怎么剪」不在这个文件里——那是影片级的一段描述，写在同目录的「剪辑风格.md」。
    /// 这里只负责逐镜的**内容**与素材对应关系。
    private static func writeTextGuide(
        manifest: [ManifestRow],
        folderName: String,
        scope: ExportScope,
        filmTitle: String,
        option: ExportTranscodeOption,
        hasStylePrompt: Bool,
        totalDuration: TimeInterval,
        to folder: URL
    ) throws {
        let groups = shotGroups(from: manifest)
        let clipCount = manifest.filter { $0.exportedPath != nil }.count
        let shotCount = groups.count
        let recordedShotCount = groups.filter { $0.rows.contains { $0.exportedPath != nil } }.count
        // 指向「剪辑风格.md」的那句话分两版：没有那个文件时不能只说「照它执行」，
        // 否则剪辑侧会去找一个不存在的文件，或者以为有要求但没读到。
        let styleLine = hasStylePrompt
            ? "本片有那份文件，开始前先读它。"
            : "本片没有那份文件，说明用户没有特别要求，这几项由你按常规判断。"

        // 例子由命名函数生成，而不是写死一段文案：片名有没有、扩展名是什么，
        // 这份说明里的例子都跟着实际落盘的名字一起变。
        let singleName = exportedFileName(filmTitle: filmTitle, number: 1, takeIndex: nil, fileExtension: "mov")
        let takeNames = (1...3)
            .map { exportedFileName(filmTitle: filmTitle, number: 1, takeIndex: $0, fileExtension: "mov") }
            .joined(separator: "、")

        var text = """
        # 分镜文字内容指南

        影片：\(filmDisplayTitle(filmTitle))

        本文件是「分镜助手」导出包的文字分镜表：把每个分镜的文字内容与同目录下的
        视频文件名绑定在一起。AI 剪辑工具可以直接按本文件处理视频，无需再问用户
        「哪段视频对应哪个镜头」。

        每个镜头有三样文字：**分镜描述**（拍什么，你的处理依据）、
        **屏幕字幕**（成片上显示的那句话）、**角标**（常驻角标显示的内容）。
        后两样由用户写定，在第「三」节逐镜给出，**原样使用**。

        ## 剪辑风格看哪

        **本文件不含画幅、节奏、时长、图层位置、文字样式、音轨这些影片级的要求**，
        它们在同目录的「剪辑风格.md」里，是用户自己写的一段话，**照它执行**。
        \(styleLine)

        ## 一、素材与分镜的对应关系

        - 视频文件名由「影片标题-分镜号-片段序号」组成，例如 \(singleName)；
          片名后面的**两位数字就是分镜编号**，与「三、镜头清单」一一对应。
        - 编号后面还有数字时，那是片段序号：同一个分镜拍了好几条，文件名形如
          \(takeNames)，数字越大拍得越晚；只拍一条的分镜就是 \(singleName)，
          不带片段序号。
        - 文件名里**没有分镜描述**，这是有意的：描述是整句话，进了文件名又长又容易
          重名，改一个字还会换一次名。这一镜拍的是什么，以本文件与同目录的
          「分镜清单.csv」为准，不要从文件名去猜。
        - 根目录里的视频是每个镜头的主素材（该镜头最新拍的一条，即片段序号最大的那条）。
        - 「备用片段」目录里是同一个镜头更早拍的片段，主素材不合适时用它替换；
          不需要替换时不要导入它们。
        - 未拍摄的镜头没有对应文件，按编号跳过，不占时间线。

        ## 二、按分镜处理视频的规则

        每个镜头带三样文字，各管一件事，**不要互相顶替**：
        「分镜描述」是这一段拍的是什么；「屏幕字幕」是成片上要显示的那句话；
        「角标」是常驻角标上显示的内容。前一样是你的处理依据，后两样是要照抄上去的字。

        1. 按编号从小到大排列片段，编号顺序就是成片顺序；不要按文件名、
           文件大小或修改时间重新排序。
        2. 每个镜头只取一条素材：默认取主素材，需要替换时才到「备用片段」里
           挑同编号的其它片段。
        3. 分镜描述只用来决定**怎么处理这段素材**：挑哪一段画面、从哪起止、怎么调色。
           它**不是**字幕文案，不要在它基础上写字幕、也不要因为它而改字幕。
        4. 屏幕字幕与角标在两处给出的写法是：
           - `反引号` 包起来的是**要原样显示的完整文字**，一个字都不要增删改：
             不扩写、不精简、不总结、不换同义词、不调语序。
           - `—` 表示这一镜没有这一项，**不要自己补一条**。
        5. 「时长」是该条素材的实际长度，用来估算成片节奏；不要臆造未提供的时长。
        6. 每个镜头的处理边界就是它自己的那段素材，不要把相邻镜头的内容并进一段。
        7. 标注「未拍摄」的镜头没有素材，直接跳过；若必须补齐，保留同样编号的空位。
        8. 画幅、节奏、时长与文字图层的位置样式一律按「剪辑风格.md」执行，
           不要自己另定一套——那是影片级的，整部片子只有一套。

        ### 字幕与角标怎么用

        - 字幕直接当一句话使用，`\n` 表示在这一处换行（不是要显示的字面反斜杠加 n）。
        - 角标那一行就是**最终要显示的字**（例如「热量缺口：1758千卡」），照它显示即可，
          不要自己前后拼词、也不要推算或换算其中的数字。
        - 断行与字号上限按「剪辑风格.md」里写的来；超宽由你折行，
          但**不要为了塞进去而删字或改字**。

        ## 三、镜头清单

        """

        for group in groups {
            let head = group.rows[0]
            text += "### 镜头 \(String(format: "%02d", group.number)) · \(singleLine(head.detail))\n"
            text += "- 分镜描述：\(singleLine(head.detail))\n"
            // 两行都无条件列出：图层的开关现在只写在「剪辑风格.md」那段描述里，
            // 指南这边没有依据判断「整片出不出这一层」，所以一律给出行、由 `—` 表示这一镜没有。
            text += "- 屏幕字幕：\(quotedIfPresent(head.caption))\n"
            text += "- 角标：\(quotedIfPresent(head.badgeText))\n"

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

        - 影片：\(filmDisplayTitle(filmTitle))
        - 导出范围：\(scope.title)
        - 视频格式：\(option.documentText)
        - 剪辑风格：\(hasStylePrompt ? "见同目录「剪辑风格.md」" : "未指定，按常规处理")
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
    /// 每次生成独立文件；由持有导出结果的会话回收旧包，迟到结果不能删除新包。
    private static func zip(folder: URL, folderName: String, fileManager: FileManager) throws -> URL {
        let outputDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ShotListExport", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let destination = outputDirectory
            .appendingPathComponent("\(folderName)_\(Self.timeToken(Date())).zip", isDirectory: false)

        var completed = false
        defer { if !completed { try? fileManager.removeItem(at: outputDirectory) } }
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
            throw Self.exportFailure(coordinatorError)
        }
        if let copyError {
            throw Self.exportFailure(copyError)
        }
        guard didCopy else {
            throw ExportError.packagingFailed("无法生成压缩包")
        }
        completed = true
        return destination
    }

    /// 导出目录名：`分镜导出_[影片标题_]日期`。
    ///
    /// 没有标题时退回纯日期、不写「未命名」——压缩包名是给人快速辨认用的，
    /// 那三个字帮不上忙；有标题时它就是辨认这部影片最直接的线索。
    static func folderName(filmTitle: String, date: Date) -> String {
        let trimmed = filmTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "分镜导出_\(dayToken(date))" }
        return "分镜导出_\(sanitize(trimmed))_\(dayToken(date))"
    }

    /// 导出文本里对影片的称呼。
    ///
    /// 压缩包名可以不写「未命名影片」，但说明文件里留空会让人以为漏了信息，
    /// 所以两处的兜底写法刻意不同。
    private static func filmDisplayTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名影片" : trimmed
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
