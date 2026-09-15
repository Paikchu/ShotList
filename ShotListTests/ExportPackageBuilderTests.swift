import XCTest
@testable import ShotList

final class ExportTestFileManager: FileManager, @unchecked Sendable {
    let root: URL
    var exportedFiles: [String: Data] = [:]
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

final class ExportPackageBuilderTests: XCTestCase {
    func testMissingClipsKeepOriginalTakeNumbersInFilesCSVAndGuide() throws {
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
            let result = try ExportPackageBuilder.build(shots: [shot], clipsDirectory: clips, scope: .recordedOnly, fileManager: fm)
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
}
