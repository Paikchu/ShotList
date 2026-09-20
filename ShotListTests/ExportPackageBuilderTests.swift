import XCTest
@testable import ShotList

final class ExportTestFileManager: FileManager, @unchecked Sendable {
    let root: URL
    var exportedFiles: [String: Data] = [:]
    var copyCount = 0
    var failCopyExtension: String?
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        copyCount += 1
        if dstURL.pathExtension == failCopyExtension {
            try Data("partial".utf8).write(to: dstURL)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOSPC.rawValue))
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }
    init(root: URL) { self.root = root; super.init() }
    override var temporaryDirectory: URL { root }
    override func removeItem(at url: URL) throws {
        // 在生产代码清理工作目录前，读取实际生成的文件以验证包内对应关系。
        if let iterator = enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let file as URL in iterator {
                if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    exportedFiles[file.path.replacingOccurrences(of: url.path + "/", with: "")] = try Data(contentsOf: file)
                }
            }
        }
        try super.removeItem(at: url)
    }
}

/// 记录调用了哪几条转码。打包侧在后台线程回调，这里按线程安全的方式收。
final class TranscodeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(name: String, option: ExportTranscodeOption)] = []

    func record(name: String, option: ExportTranscodeOption) {
        lock.lock(); defer { lock.unlock() }
        entries.append((name, option))
    }

    var names: [String] { lock.lock(); defer { lock.unlock() }; return entries.map(\.name) }
    var options: [ExportTranscodeOption] { lock.lock(); defer { lock.unlock() }; return entries.map(\.option) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
}

final class ExportPackageBuilderTests: XCTestCase {
    private func request(
        _ shots: [Shot],
        _ clipsDirectory: URL,
        scope: ExportScope = .recordedOnly,
        option: ExportTranscodeOption = .original,
        filmTitle: String = "",
        stylePrompt: String = ""
    ) -> ExportRequest {
        ExportRequest(shots: shots, clipsDirectory: clipsDirectory, scope: scope,
                      option: option, filmTitle: filmTitle, stylePrompt: stylePrompt)
    }

    /// 一个带隔离文件系统的临时根目录，用完自动回收
    private func makeTempRoot() throws -> (URL, ExportTestFileManager) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, ExportTestFileManager(root: root))
    }

    /// 取出包里某个文本文件的内容
    private func exportedText(_ fm: ExportTestFileManager, _ suffix: String) throws -> String {
        let data = try XCTUnwrap(
            fm.exportedFiles.first { $0.key.hasSuffix(suffix) }?.value,
            "导出包里没有 \(suffix)"
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// 塞一个镜头 + 一条真素材，返回落盘根目录
    private func singleShotRoot(
        _ shot: Shot,
        fileName: String = "a.mov"
    ) throws -> (URL, ExportTestFileManager) {
        let (root, fm) = try makeTempRoot()
        try Data("video".utf8).write(to: root.appendingPathComponent(fileName))
        return (root, fm)
    }

    func testMissingClipsKeepOriginalTakeNumbersInFilesCSVAndGuide() async throws {
        for remaining in [[1, 2, 3], [2, 3], [3], [1, 2]] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let fm = ExportTestFileManager(root: root)
            let clips = root.appendingPathComponent("clips")
            try fm.createDirectory(at: clips, withIntermediateDirectories: true)
            var shot = Shot(number: 1, note: "Test")
            shot.clips = (1...3).map { ShotClip(fileName: "take\($0).mov", duration: 1, recordedAt: Date(timeIntervalSince1970: Double($0))) }
            for index in remaining { try Data("video \(index)".utf8).write(to: clips.appendingPathComponent("take\(index).mov")) }
            let result = try await ExportPackageBuilder.build(request([shot], clips), fileManager: fm)
            XCTAssertEqual(result.clipCount, remaining.count)
            XCTAssertTrue(fm.fileExists(atPath: result.zipURL.path))
            let csv = try XCTUnwrap(fm.exportedFiles.first { $0.key.hasSuffix("分镜清单.csv") }.map { String(decoding: $0.value, as: UTF8.self) })
            let guide = try XCTUnwrap(fm.exportedFiles.first { $0.key.hasSuffix("分镜文字内容指南.md") }.map { String(decoding: $0.value, as: UTF8.self) })
            for index in remaining {
                let name = "01-\(index).mov"
                XCTAssertTrue(fm.exportedFiles.contains { $0.key.hasSuffix(name) && $0.value == Data("video \(index)".utf8) })
                XCTAssertTrue(csv.contains("第 \(index) 条 / 共 3 条"))
                XCTAssertTrue(csv.contains(name))
                XCTAssertTrue(guide.contains(name))
            }
            XCTAssertTrue(guide.contains("主素材文件：01-\(remaining.max()!).mov"))
            for missing in Set(1...3).subtracting(remaining) {
                XCTAssertFalse(csv.contains("01-\(missing).mov"))
            }
        }
    }
    func testSpacePreflightAndRuntimeFailureCleanup() async throws {
        for mode in ["preflight", "copy", "zip", "unknown", "enough"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let fm = ExportTestFileManager(root: root)
            var shot = Shot(number: 1, note: "Space test")
            shot.clips = [ShotClip(fileName: "source.mov")]
            let source = root.appendingPathComponent("source.mov")
            try Data("video".utf8).write(to: source)
            fm.failCopyExtension = mode == "copy" ? "mov" : mode == "zip" ? "zip" : nil
            let available: Int64? = mode == "preflight" ? 0 : mode == "unknown" ? nil : Int64.max
            if mode == "unknown" || mode == "enough" {
                let result = try await ExportPackageBuilder.build(request([shot], root), fileManager: fm, availableCapacity: { _ in available })
                XCTAssertTrue(fm.fileExists(atPath: result.zipURL.path))
            } else {
                do {
                    _ = try await ExportPackageBuilder.build(request([shot], root), fileManager: fm, availableCapacity: { _ in available })
                    XCTFail("应当因空间不足失败：\(mode)")
                } catch {
                    guard case ExportError.insufficientSpace = error else { return XCTFail("Expected space error: \(error)") }
                    XCTAssertTrue(error.localizedDescription.contains("释放空间"))
                }
                if mode == "preflight" { XCTAssertEqual(fm.copyCount, 0) }
                let exportRoot = root.appendingPathComponent("ShotListExport")
                XCTAssertTrue((try? fm.contentsOfDirectory(atPath: exportRoot.path))?.isEmpty ?? true)
            }
            XCTAssertEqual(try Data(contentsOf: source), Data("video".utf8))
        }
    }

    func testNestedDiskFullErrorIsActionable() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)])
        guard case .insufficientSpace = ExportPackageBuilder.exportFailure(error) else { return XCTFail("Lost underlying disk-full error") }
        guard case .packagingFailed = ExportPackageBuilder.exportFailure(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)) else { return XCTFail("Misclassified permission failure") }
    }

    func testClockRollbackPreviewMatchesExportedMainTake() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = ExportTestFileManager(root: root)
        let shot = Shot(number: 1, note: "Rollback", clips: [
            ShotClip(fileName: "first.mov", recordedAt: Date(timeIntervalSince1970: 200)),
            ShotClip(fileName: "second.mov", recordedAt: Date(timeIntervalSince1970: 100))
        ])
        for clip in shot.clips { try Data(clip.fileName.utf8).write(to: root.appendingPathComponent(clip.fileName)) }
        XCTAssertEqual(shot.latestTakeIndex, 1)
        let preview = ExportPackageBuilder.exportedFileName(
            filmTitle: "夏日vlog", number: shot.number, takeIndex: shot.latestTakeIndex,
            fileExtension: shot.mainFileExtension
        )
        _ = try await ExportPackageBuilder.build(request([shot], root, filmTitle: "夏日vlog"), fileManager: fm)
        let guide = try XCTUnwrap(fm.exportedFiles.first { $0.key.hasSuffix("分镜文字内容指南.md") }).value
        XCTAssertTrue(String(decoding: guide, as: UTF8.self).contains("主素材文件：\(preview)"))
        XCTAssertEqual(preview, "夏日vlog-01-1.mov")
        XCTAssertNil(Shot(number: 2).latestTakeIndex)
    }

    // MARK: - 影片标题

    func testFolderNameCarriesFilmTitleAndFallsBackToDate() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 14
        let date = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: components))

        XCTAssertEqual(
            ExportPackageBuilder.folderName(filmTitle: "夏日vlog", date: date),
            "分镜导出_夏日vlog_20260914"
        )
        // 没起名字就退回纯日期：压缩包名是给人快速辨认用的，「未命名」三个字帮不上忙
        XCTAssertEqual(ExportPackageBuilder.folderName(filmTitle: "   ", date: date), "分镜导出_20260914")
        // 文件名里不安全的字符要被换掉，中文保留
        XCTAssertEqual(ExportPackageBuilder.folderName(filmTitle: "a/b:c", date: date), "分镜导出_a-b-c_20260914")
    }

    func testExportedTextFilesCarryFilmTitle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = ExportTestFileManager(root: root)
        let shot = Shot(number: 1, note: "开场", clips: [ShotClip(fileName: "a.mov", duration: 3)])
        try Data("video".utf8).write(to: root.appendingPathComponent("a.mov"))

        let result = try await ExportPackageBuilder.build(
            request([shot], root, filmTitle: "夏日vlog"),
            fileManager: fm
        )
        XCTAssertTrue(result.zipURL.lastPathComponent.hasPrefix("分镜导出_夏日vlog_"))
        // 片名同时进每个视频文件名
        XCTAssertTrue(fm.exportedFiles.keys.contains { $0.hasSuffix("夏日vlog-01.mov") })

        let guide = try XCTUnwrap(
            fm.exportedFiles.first { $0.key.hasSuffix("分镜文字内容指南.md") }
                .map { String(decoding: $0.value, as: UTF8.self) }
        )
        let readme = try XCTUnwrap(
            fm.exportedFiles.first { $0.key.hasSuffix("导出说明.txt") }
                .map { String(decoding: $0.value, as: UTF8.self) }
        )
        XCTAssertTrue(guide.contains("影片：夏日vlog"))
        XCTAssertTrue(readme.contains("影片：夏日vlog"))
        // 包内说明与指南里的示范名也带片名：这两处由命名函数生成，不是写死的文案，
        // 所以片名一改（或以后命名规则再变）它们跟着一起变，不会留下过期的例子。
        XCTAssertTrue(readme.contains("夏日vlog-01.mov"))
        XCTAssertTrue(readme.contains("夏日vlog-01-3.mov"))
        XCTAssertTrue(guide.contains("夏日vlog-01-1.mov"))
    }

    func testUntitledFilmStillNamesItselfInTextFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = ExportTestFileManager(root: root)
        let shot = Shot(number: 1, note: "开场", clips: [ShotClip(fileName: "a.mov", duration: 3)])
        try Data("video".utf8).write(to: root.appendingPathComponent("a.mov"))

        let result = try await ExportPackageBuilder.build(request([shot], root), fileManager: fm)
        // 压缩包名退回纯日期，但说明文件里留空会让人以为漏了信息，所以写「未命名影片」
        XCTAssertTrue(result.zipURL.lastPathComponent.hasPrefix("分镜导出_2026"))
        let guide = try XCTUnwrap(
            fm.exportedFiles.first { $0.key.hasSuffix("分镜文字内容指南.md") }
                .map { String(decoding: $0.value, as: UTF8.self) }
        )
        XCTAssertTrue(guide.contains("影片：未命名影片"))
    }

    // MARK: - 导出文件名

    /// 命名规则：`影片标题-分镜号[-片段序号]`，分镜内容不参与。
    func testExportedFileNameCarriesFilmTitleShotNumberAndTakeIndex() {
        XCTAssertEqual(
            ExportPackageBuilder.exportedFileName(filmTitle: "夏日vlog", number: 1, takeIndex: nil, fileExtension: "mov"),
            "夏日vlog-01.mov"
        )
        // 同一个分镜的多条候选靠片段序号区分
        XCTAssertEqual(
            ExportPackageBuilder.exportedFileName(filmTitle: "夏日vlog", number: 2, takeIndex: 3, fileExtension: "mov"),
            "夏日vlog-02-3.mov"
        )
        // 没起片名时整节省掉，不写「未命名影片」这类占位词
        XCTAssertEqual(
            ExportPackageBuilder.exportedFileName(filmTitle: "   ", number: 5, takeIndex: nil, fileExtension: "mp4"),
            "05.mp4"
        )
        // 标题里不安全的字符换成短横，中文保留
        XCTAssertEqual(
            ExportPackageBuilder.exportedFileName(filmTitle: "a/b:c", number: 1, takeIndex: nil, fileExtension: "mov"),
            "a-b-c-01.mov"
        )
    }

    /// 内容不进包内文件名：它又长又会重名，改一次内容不该换一次文件名。
    /// 内容与编号的对应关系落在 CSV 与指南里，剪辑侧照样找得到。
    func testContentStaysOutOfFileNamesAndLivesInTextFiles() async throws {
        let shot = Shot(
            number: 1,
            note: "无人机缓慢上升，配一句开场旁白",
            clips: [ShotClip(fileName: "a.mov", duration: 3)]
        )
        let (root, fm) = try singleShotRoot(shot)

        _ = try await ExportPackageBuilder.build(request([shot], root, filmTitle: "夏日vlog"), fileManager: fm)

        XCTAssertTrue(fm.exportedFiles.keys.contains { $0.hasSuffix("夏日vlog-01.mov") })
        XCTAssertFalse(fm.exportedFiles.keys.contains { $0.contains("无人机") })
        XCTAssertTrue(try exportedText(fm, "分镜清单.csv").contains("无人机缓慢上升，配一句开场旁白"))
        XCTAssertTrue(
            try exportedText(fm, "分镜文字内容指南.md").contains("无人机缓慢上升，配一句开场旁白")
        )
    }

    // MARK: - 格式选项

    /// 扩展名规则：不转码跟随源文件，转码后统一 QuickTime。
    /// 镜头面板的预览与实际打包都读这一个函数，所以它不能只在导出侧生效。
    func testExtensionFollowsSourceUnlessTranscoding() {
        XCTAssertEqual(ExportTranscodeOption.original.exportedFileExtension(sourceExtension: "mp4"), "mp4")
        XCTAssertEqual(ExportTranscodeOption.original.exportedFileExtension(sourceExtension: "mov"), "mov")
        XCTAssertEqual(ExportTranscodeOption.compatible.exportedFileExtension(sourceExtension: "mp4"), "mov")
        XCTAssertEqual(ExportTranscodeOption.compact.exportedFileExtension(sourceExtension: "mp4"), "mov")
        XCTAssertFalse(ExportTranscodeOption.original.needsTranscode)
        XCTAssertTrue(ExportTranscodeOption.compatible.needsTranscode)
        XCTAssertTrue(ExportTranscodeOption.compact.needsTranscode)
    }

    /// 选了转码就逐条重编、不再复制源文件，包内文件名与清单/说明同步换成转码后的容器。
    func testTranscodeReplacesCopyAndKeepsNamesInSync() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = ExportTestFileManager(root: root)
        var shot = Shot(number: 1, note: "Transcode")
        shot.clips = [ShotClip(fileName: "source.mp4", duration: 1)]
        try Data("video".utf8).write(to: root.appendingPathComponent("source.mp4"))

        let recorder = TranscodeRecorder()
        let result = try await ExportPackageBuilder.build(
            request([shot], root, option: .compatible),
            fileManager: fm,
            transcode: { _, destination, option in
                recorder.record(name: destination.lastPathComponent, option: option)
                try Data("transcoded".utf8).write(to: destination)
            }
        )

        XCTAssertEqual(result.clipCount, 1)
        XCTAssertEqual(recorder.names, ["01.mov"])
        XCTAssertEqual(recorder.options, [.compatible])
        // 源文件不再复制，剩下的那一次是系统打 zip 自己做的拷贝
        XCTAssertEqual(fm.copyCount, 1)
        XCTAssertTrue(fm.exportedFiles.contains { $0.key.hasSuffix("01.mov") && $0.value == Data("transcoded".utf8) })

        let csv = try XCTUnwrap(fm.exportedFiles.first { $0.key.hasSuffix("分镜清单.csv") }.map { String(decoding: $0.value, as: UTF8.self) })
        let readme = try XCTUnwrap(fm.exportedFiles.first { $0.key.hasSuffix("导出说明.txt") }.map { String(decoding: $0.value, as: UTF8.self) })
        let guide = try XCTUnwrap(fm.exportedFiles.first { $0.key.hasSuffix("分镜文字内容指南.md") }.map { String(decoding: $0.value, as: UTF8.self) })
        XCTAssertTrue(csv.contains("01.mov"))
        XCTAssertTrue(csv.contains("01.mp4") == false)
        XCTAssertTrue(readme.contains(ExportTranscodeOption.compatible.documentText))
        XCTAssertTrue(guide.contains(ExportTranscodeOption.compatible.documentText))
    }

    /// 转码失败要指名是哪条素材，并且给出可执行的下一步（改回原片）。
    func testTranscodeFailureNamesTheFileAndSuggestsFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = ExportTestFileManager(root: root)
        var shot = Shot(number: 2, note: "Broken")
        shot.clips = [ShotClip(fileName: "broken.mov", duration: 1)]
        try Data("video".utf8).write(to: root.appendingPathComponent("broken.mov"))

        do {
            _ = try await ExportPackageBuilder.build(
                request([shot], root, option: .compact),
                fileManager: fm,
                transcode: { _, _, _ in throw MediaTranscodeError.sessionUnavailable }
            )
            XCTFail("应当报转码失败")
        } catch {
            guard case ExportError.transcodeFailed(let fileName, _) = error else { return XCTFail("Expected transcode error: \(error)") }
            XCTAssertEqual(fileName, "02.mov")
            XCTAssertTrue(error.localizedDescription.contains("「原片」"))
        }
        // 失败后工作目录要清干净，不能留下半成品
        let exportRoot = root.appendingPathComponent("ShotListExport")
        XCTAssertTrue((try? fm.contentsOfDirectory(atPath: exportRoot.path))?.isEmpty ?? true)
    }

    /// 打包已作废（用户改了范围或格式）时，不该再动手转码。
    func testCancelledRunNeverStartsTranscoding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = ExportTestFileManager(root: root)
        var shot = Shot(number: 1, note: "Cancelled")
        shot.clips = [ShotClip(fileName: "source.mov", duration: 1)]
        try Data("video".utf8).write(to: root.appendingPathComponent("source.mov"))

        let cancellation = ExportCancellation()
        cancellation.cancel()
        let recorder = TranscodeRecorder()
        do {
            _ = try await ExportPackageBuilder.build(
                request([shot], root, option: .compatible),
                run: ExportRun(cancellation: cancellation),
                fileManager: fm,
                transcode: { _, destination, option in
                    recorder.record(name: destination.lastPathComponent, option: option)
                }
            )
            XCTFail("应当被取消")
        } catch {
            XCTAssertEqual(recorder.count, 0)
            XCTAssertEqual(fm.copyCount, 0)
        }
    }

    // MARK: - 剪辑风格

    /// 剪辑风格是用户写的一段话，原样进包：`剪辑风格.md` 是剪辑侧唯一的「怎么剪」依据，
    /// 指南必须指向它，而固定字段的规格文件不该再出现——留一个空壳会让剪辑侧以为
    /// 参数在别处，反而不知道该信哪一份。
    func testStylePromptGoesIntoPackageVerbatim() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = ExportTestFileManager(root: root)
        let shot = Shot(number: 1, note: "开场", clips: [ShotClip(fileName: "a.mov", duration: 3)])
        try Data("video".utf8).write(to: root.appendingPathComponent("a.mov"))

        let prompt = """
        竖屏 1080×1920、60fps。
        节奏偏快，单镜 0.5–2 秒，全片控制在 10–12 秒，不加音乐、留现场声。
        角标固定在画面正中，白色文字加描边。片尾不加卡。
        """

        _ = try await ExportPackageBuilder.build(
            request([shot], root, filmTitle: "减脂日记", stylePrompt: prompt),
            fileManager: fm
        )

        XCTAssertFalse(fm.exportedFiles.keys.contains { $0.hasSuffix("剪辑规格.json") })

        let styleFile = try exportedText(fm, "剪辑风格.md")
        XCTAssertTrue(styleFile.contains("# 剪辑风格 · 减脂日记"))
        // 正文一字不改：用户写的就是要执行的
        XCTAssertTrue(styleFile.contains(prompt))

        let guide = try exportedText(fm, "分镜文字内容指南.md")
        XCTAssertTrue(guide.contains("## 剪辑风格看哪"))
        XCTAssertTrue(guide.contains("剪辑风格.md"))
        XCTAssertTrue(guide.contains("本片有那份文件，开始前先读它。"))
        XCTAssertTrue(guide.contains("剪辑风格：见同目录「剪辑风格.md」"))
        // 汇总节顺延为第四节，编号不与新增的风格节撞车
        XCTAssertTrue(guide.contains("## 四、汇总"))

        let readme = try exportedText(fm, "导出说明.txt")
        XCTAssertTrue(readme.contains("剪辑风格.md"))
        XCTAssertFalse(readme.contains("剪辑规格.json"))
    }

    /// 没写风格描述就不产出那个文件，指南也必须改口说明「按常规处理」——
    /// 否则剪辑侧会去找一个不存在的文件，或者以为有要求却没读到。
    func testEmptyStylePromptProducesNoFileAndSaysSoInGuide() async throws {
        let shot = Shot(number: 1, note: "开场", clips: [ShotClip(fileName: "a.mov", duration: 3)])
        let (root, fm) = try singleShotRoot(shot)

        _ = try await ExportPackageBuilder.build(request([shot], root), fileManager: fm)

        XCTAssertFalse(fm.exportedFiles.keys.contains { $0.hasSuffix("剪辑风格.md") })

        let guide = try exportedText(fm, "分镜文字内容指南.md")
        XCTAssertTrue(guide.contains("本片没有那份文件，说明用户没有特别要求，这几项由你按常规判断。"))
        XCTAssertTrue(guide.contains("剪辑风格：未指定，按常规处理"))
    }

    /// 只有空白的描述等同于没写。判「有没有那份文件」和「写不写那个文件」
    /// 必须是同一个值，不能一处按原文判、一处按裁过判。
    func testWhitespaceOnlyStylePromptCountsAsNothing() async throws {
        let shot = Shot(number: 1, note: "开场", clips: [ShotClip(fileName: "a.mov", duration: 3)])
        let (root, fm) = try singleShotRoot(shot)

        _ = try await ExportPackageBuilder.build(
            request([shot], root, stylePrompt: "  \n\n  "),
            fileManager: fm
        )

        XCTAssertFalse(fm.exportedFiles.keys.contains { $0.hasSuffix("剪辑风格.md") })
        let guide = try exportedText(fm, "分镜文字内容指南.md")
        XCTAssertTrue(guide.contains("本片没有那份文件"))
    }

    // MARK: - 逐镜的文字内容

    /// 一个镜头的文字只有一段：CSV 一列、指南里一个代码围栏，逐行原样。
    /// 不再按描述、字幕、角标拆开——AI 直接读文字。
    func testShotContentGoesVerbatimToCSVAndGuide() async throws {
        let shot = Shot(
            number: 1,
            note: "描述：早上起床称体重\n字幕：今日体重114.1KG\n上方角标：热量缺口：1758千卡",
            clips: [ShotClip(fileName: "a.mov", duration: 3)]
        )
        let (root, fm) = try singleShotRoot(shot)

        _ = try await ExportPackageBuilder.build(request([shot], root), fileManager: fm)

        let csv = try exportedText(fm, "分镜清单.csv")
        XCTAssertTrue(csv.contains("编号,分镜内容,状态,片段,拍摄时间,时长,导出文件名"))
        XCTAssertFalse(csv.contains("屏幕字幕"))
        // 多行内容整体加引号，留在同一格里
        XCTAssertTrue(csv.contains("01,\"描述：早上起床称体重\n字幕：今日体重114.1KG\n上方角标：热量缺口：1758千卡\","))

        let guide = try exportedText(fm, "分镜文字内容指南.md")
        XCTAssertTrue(guide.contains(
            "内容：\n```text\n描述：早上起床称体重\n字幕：今日体重114.1KG\n上方角标：热量缺口：1758千卡\n```"
        ))
        XCTAssertFalse(guide.contains("- 屏幕字幕："))
        XCTAssertFalse(guide.contains("- 角标："))
    }

    /// 没写内容就是「这一镜没有要求」，指南里写成 `—`，CSV 里留空；
    /// 不再回退成「镜头 N」，那会被当成用户写下的内容。
    func testMissingContentReadsAsNone() async throws {
        let shot = Shot(number: 1, clips: [ShotClip(fileName: "a.mov", duration: 3)])
        let (root, fm) = try singleShotRoot(shot)

        _ = try await ExportPackageBuilder.build(request([shot], root), fileManager: fm)

        let guide = try exportedText(fm, "分镜文字内容指南.md")
        XCTAssertTrue(guide.contains("内容：—"))
        XCTAssertTrue(try exportedText(fm, "分镜清单.csv").contains("\n01,,"))
    }

    /// 内容本身带反引号时，代码围栏要比它更长，否则内容会提前把围栏截断。
    func testFenceOutgrowsBackticksInContent() async throws {
        let shot = Shot(
            number: 1,
            note: "字幕：用 ``` 包起来",
            clips: [ShotClip(fileName: "a.mov", duration: 3)]
        )
        let (root, fm) = try singleShotRoot(shot)

        _ = try await ExportPackageBuilder.build(request([shot], root), fileManager: fm)

        XCTAssertTrue(try exportedText(fm, "分镜文字内容指南.md").contains("````text\n字幕：用 ``` 包起来\n````"))
    }

    /// 内容是整镜共用的，同一个镜头拍了几条片段，CSV 的每一行都该带上它，
    /// 剪辑侧挑中「备用片段」那一行时不用回头去别的行找。
    func testContentRepeatsOnEveryTakeRow() async throws {
        var shot = Shot(number: 1, note: "字幕：器械划船 ⌄ 45KG * 4 * 10")
        shot.clips = (1...3).map {
            ShotClip(fileName: "take\($0).mov", duration: 2, recordedAt: Date(timeIntervalSince1970: Double($0)))
        }
        let (root, fm) = try makeTempRoot()
        let clips = root.appendingPathComponent("clips")
        try fm.createDirectory(at: clips, withIntermediateDirectories: true)
        for index in 1...3 {
            try Data("video \(index)".utf8).write(to: clips.appendingPathComponent("take\(index).mov"))
        }

        _ = try await ExportPackageBuilder.build(request([shot], clips), fileManager: fm)

        let csv = try exportedText(fm, "分镜清单.csv")
        let rows = csv.split(separator: "\n").filter { $0.hasPrefix("01,") }
        XCTAssertEqual(rows.count, 3)
        for row in rows {
            XCTAssertTrue(row.contains(",字幕：器械划船 ⌄ 45KG * 4 * 10,"), "片段行缺少镜头级的内容：\(row)")
        }
    }

}
