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
        filmTitle: String = ""
    ) -> ExportRequest {
        ExportRequest(shots: shots, clipsDirectory: clipsDirectory, scope: scope, option: option, filmTitle: filmTitle)
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
                let name = "01-\(index)_Test.mov"
                XCTAssertTrue(fm.exportedFiles.contains { $0.key.hasSuffix(name) && $0.value == Data("video \(index)".utf8) })
                XCTAssertTrue(csv.contains("第 \(index) 条 / 共 3 条"))
                XCTAssertTrue(csv.contains(name))
                XCTAssertTrue(guide.contains(name))
            }
            XCTAssertTrue(guide.contains("主素材文件：01-\(remaining.max()!)_Test.mov"))
            for missing in Set(1...3).subtracting(remaining) {
                XCTAssertFalse(csv.contains("01-\(missing)_Test.mov"))
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
                    XCTAssertTrue(error.localizedDescription.contains("释放设备空间"))
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
        let preview = ExportPackageBuilder.exportedFileName(number: shot.number, takeIndex: shot.latestTakeIndex, note: shot.note, fileExtension: shot.mainFileExtension)
        _ = try await ExportPackageBuilder.build(request([shot], root), fileManager: fm)
        let guide = try XCTUnwrap(fm.exportedFiles.first { $0.key.hasSuffix("分镜文字内容指南.md") }).value
        XCTAssertTrue(String(decoding: guide, as: UTF8.self).contains("主素材文件：\(preview)"))
        XCTAssertEqual(preview, "01-1_Rollback.mov")
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
        XCTAssertEqual(recorder.names, ["01_Transcode.mov"])
        XCTAssertEqual(recorder.options, [.compatible])
        // 源文件不再复制，剩下的那一次是系统打 zip 自己做的拷贝
        XCTAssertEqual(fm.copyCount, 1)
        XCTAssertTrue(fm.exportedFiles.contains { $0.key.hasSuffix("01_Transcode.mov") && $0.value == Data("transcoded".utf8) })

        let csv = try XCTUnwrap(fm.exportedFiles.first { $0.key.hasSuffix("分镜清单.csv") }.map { String(decoding: $0.value, as: UTF8.self) })
        let readme = try XCTUnwrap(fm.exportedFiles.first { $0.key.hasSuffix("导出说明.txt") }.map { String(decoding: $0.value, as: UTF8.self) })
        let guide = try XCTUnwrap(fm.exportedFiles.first { $0.key.hasSuffix("分镜文字内容指南.md") }.map { String(decoding: $0.value, as: UTF8.self) })
        XCTAssertTrue(csv.contains("01_Transcode.mov"))
        XCTAssertTrue(csv.contains("01_Transcode.mp4") == false)
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
            XCTAssertEqual(fileName, "02_Broken.mov")
            XCTAssertTrue(error.localizedDescription.contains("改回「原片」"))
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

}
