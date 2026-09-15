import AVFoundation
import UIKit

/// 触觉反馈统一入口。系统会自动遵循用户的触觉设置。
enum Haptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

/// 视频元数据读取。无状态，因此不属于主协程。
nonisolated enum VideoMetadata {
    /// 读取视频时长（秒）。
    ///
    /// `@concurrent` 不能省：默认主协程隔离下，裸的 `nonisolated async` 会留在
    /// 调用方所在的主协程上，`AVURLAsset` 的构造与后续解析就都压在主线程。
    /// 与本文件里 `decodeThumbnail` 走的是同一条规则。
    @concurrent
    static func duration(of url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }
}

/// 视频首帧缩略图加载器，带内存缓存，避免列表滚动时重复解码。
///
/// 隔离域是刻意固定的：缓存与在途任务表只由主线程读写，解码（真正耗时的部分）
/// 用 `@concurrent` 丢到后台线程，完成后再回主线程写缓存。
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private final class CachedImage {
        let requestID: UUID
        let image: UIImage
        init(requestID: UUID, image: UIImage) { self.requestID = requestID; self.image = image }
    }
    private struct Request {
        let id: UUID
        let task: Task<UIImage?, Never>
    }
    private let cache = NSCache<NSString, CachedImage>()
    private let decode: (URL) async -> UIImage?

    /// 正在解码的任务。列表滚动时同一张图会被多张卡片同时请求，
    /// 复用同一个任务可以避免重复解码同一帧。
    private var inFlight: [String: Request] = [:]

    init(decode: @escaping (URL) async -> UIImage? = { await ThumbnailLoader.decodeThumbnail(for: $0) }) {
        self.decode = decode
        cache.countLimit = 60
    }

    func cachedThumbnail(for url: URL) -> UIImage? {
        cache.object(forKey: url.path as NSString)?.image
    }

    /// 生成缩略图。命中缓存、或同一张图已有任务在跑时，直接复用结果。
    ///
    /// 调用方在 `await` 之后必须自行判断是否已经被取消（`Task.isCancelled`）：
    /// url 变了说明这张图已经不是当前要显示的那张，迟到的结果要丢掉。
    func thumbnail(for url: URL) async -> UIImage? {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached.image }

        let path = url.path
        let request: Request
        if let running = inFlight[path] {
            request = running
        } else {
            request = Request(id: UUID(), task: Task { await decode(url) })
            inFlight[path] = request
        }

        let image = await request.task.value
        // 同一任务的另一位等待者可能已写入缓存，所以同时核对在途与缓存标识。
        // 失效会移除二者；旧任务不能写回旧图，也不能清掉新一代任务。
        guard inFlight[path]?.id == request.id || cache.object(forKey: key)?.requestID == request.id else { return nil }
        if inFlight[path]?.id == request.id {
            inFlight[path] = nil
            if let image { cache.setObject(CachedImage(requestID: request.id, image: image), forKey: key) }
        }
        return Task.isCancelled ? nil : image
    }

    func invalidate(for url: URL) {
        cache.removeObject(forKey: url.path as NSString)
        inFlight.removeValue(forKey: url.path)?.task.cancel()
    }

    /// 清空全部缓存（清空所有分镜时调用）
    func removeAll() {
        cache.removeAllObjects()
        for request in inFlight.values { request.task.cancel() }
        inFlight.removeAll()
    }

    /// 解码首帧。`@concurrent` 保证它离开主线程；
    /// 放在这里而不是调用处，是为了让「缓存只由主线程碰」这条约束保持完整。
    @concurrent
    private static func decodeThumbnail(for url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.4, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.4, preferredTimescale: 600)

        let time = CMTime(seconds: 0.2, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
