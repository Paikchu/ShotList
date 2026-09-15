import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// 从相册挑选出来的视频。
///
/// `PhotosPicker` 给出的地址是系统托管的临时位置，这里立刻拷贝一份到自己的
/// 临时目录，之后再由 `ShotStore` 接管搬进「分镜视频」目录。
///
/// 文件名保留来源文件真实的扩展名：相册里的 mp4 被强行改名成 `.mov` 之后，
/// 文件内容（容器）与扩展名就对不上了，导出后交给剪映可能打不开。
struct ImportedMovie: Transferable {
    let url: URL

    /// 中转文件属于这次相册导入；无论成功或失败都由此处回收。
    @MainActor
    func save(to store: ShotStore, shotID: Shot.ID) async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let duration = await VideoMetadata.duration(of: url)
        try store.addClip(from: url, duration: duration, to: shotID)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let source = received.file
            let fileExtension = source.pathExtension.lowercased()
            let name = "\(ImportedMovie.temporaryFilePrefix)\(UUID().uuidString)"
                + (fileExtension.isEmpty ? ".mov" : ".\(fileExtension)")

            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(name, isDirectory: false)

            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
            return ImportedMovie(url: destination)
        }
    }
}

// MARK: - 中转文件回收

nonisolated extension ImportedMovie {
    /// 导入中转文件的前缀。创建与回收都按它认领。
    fileprivate static let temporaryFilePrefix = "import-"

    /// 清掉上一次会话残留在临时目录里的导入中转文件。
    ///
    /// 导入成功时 `ShotStore.addClip` 会把它搬进「分镜视频」并删掉原文件，
    /// 但保存失败、页面被提前关掉这些路径会留下 `import-*`，而系统什么时候清
    /// 临时目录由 iOS 决定。启动时统一收一次。
    static func cleanUpTemporaryImports(fileManager: FileManager = .default) {
        let root = fileManager.temporaryDirectory
        let contents = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where url.lastPathComponent.hasPrefix(temporaryFilePrefix) {
            try? fileManager.removeItem(at: url)
        }
    }
}
