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

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let source = received.file
            let fileExtension = source.pathExtension.lowercased()
            let name = "import-\(UUID().uuidString)"
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
