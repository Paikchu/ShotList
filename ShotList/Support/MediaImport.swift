import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// 从相册挑选出来的视频。
///
/// `PhotosPicker` 给出的地址是系统托管的临时位置，这里立刻拷贝一份到自己的
/// 临时目录，之后再由 `ShotStore` 接管搬进「分镜视频」目录。
struct ImportedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-\(UUID().uuidString).mov", isDirectory: false)

            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: received.file, to: destination)
            return ImportedMovie(url: destination)
        }
    }
}
