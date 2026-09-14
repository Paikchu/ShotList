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
    /// 读取视频时长（秒）
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
/// 隔离域是刻意固定的：缓存只由主线程读写，解码（真正耗时的部分）用
/// `@concurrent` 丢到后台线程，完成后再回主线程写缓存并回调。
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 60
    }

    func cachedThumbnail(for url: URL) -> UIImage? {
        cache.object(forKey: url.path as NSString)
    }

    /// 生成缩略图并在主线程回调；命中缓存时立即回调
    func thumbnail(for url: URL, completion: @escaping (UIImage?) -> Void) {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }

        Task {
            let image = await Self.decodeThumbnail(for: url)
            if let image {
                cache.setObject(image, forKey: key)
            }
            completion(image)
        }
    }

    func invalidate(for url: URL) {
        cache.removeObject(forKey: url.path as NSString)
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
