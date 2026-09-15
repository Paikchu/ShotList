import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// 从相册挑选出来的视频。
///
/// `PhotosPicker` 给出的地址是系统托管的临时位置，这里立刻拷贝一份到自己的
/// 临时目录，之后再由 `ShotStore` 接管搬进「分镜视频」目录。
///
/// 拾取时显式要求 `.current`（见 `ShotFlowModifier`），拿到的是相册里的**原片**：
/// 默认的 `.automatic` 会先转一次码，一段 4K 素材要等好几分钟，画质也会被降一档。
/// 需要别的格式时到「导出」页按需转码，导入这一步只负责把原文件拿到手。
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
        try await store.addClip(from: url, duration: duration, to: shotID)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let destination = try await MediaFileCopy.shared.temporaryCopy(of: received.file)
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

// MARK: - 批量导入的推进

/// 批量导入的推进逻辑：与相册、与具体文件类型都无关，只保证「一段一段来、失败不打断」。
///
/// 单独抽出来是为了能验证：顺序有没有变、中间某一段失败后面还继不继续、失败算得准不准。
/// 相册选片那一步没法自动化，这条逻辑至少要有自己的证据。
enum MovieImporter {
    /// 按顺序逐段执行，收集每一段的失败原因。
    ///
    /// - Parameter onProgress: 每段**开始前**回调，参数是这一段的下标（从 0 开始）。
    /// - Returns: 失败原因（本地化描述），按发生顺序；成功的段不出现在里面。
    static func run<Item>(
        _ items: [Item],
        onProgress: (Int) -> Void = { _ in },
        onEach: (Item) async throws -> Void
    ) async -> [String] {
        var failures: [String] = []
        for (index, item) in items.enumerated() {
            onProgress(index)
            do {
                try await onEach(item)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        return failures
    }
}

/// 明确在通用执行器上复制；取消或失败时回收半成品，调用者只会拿到完整文件。
nonisolated final class MediaFileCopy: @unchecked Sendable {
    static let shared = MediaFileCopy(fileManager: .default)
    // FileManager 的基本文件操作可跨线程调用；这里不设置 delegate，也不共享可变的复制状态。
    private let fileManager: FileManager
    init(fileManager: FileManager) { self.fileManager = fileManager }

    @concurrent
    func temporaryCopy(of source: URL) async throws -> URL {
        let ext = source.pathExtension.lowercased()
        let name = ImportedMovie.temporaryFilePrefix + UUID().uuidString + "." + (ext.isEmpty ? "mov" : ext)
        let destination = fileManager.temporaryDirectory.appendingPathComponent(name)
        do {
            try Task.checkCancellation()
            try fileManager.copyItem(at: source, to: destination)
            try Task.checkCancellation()
            return destination
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }
}
