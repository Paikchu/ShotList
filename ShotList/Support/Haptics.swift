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

/// 视频元数据读取。
enum VideoMetadata {
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
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 60
    }

    func cachedThumbnail(for url: URL) -> UIImage? {
        cache.object(forKey: url.path as NSString)
    }

    /// 异步生成缩略图，回到主线程回调
    func thumbnail(for url: URL, completion: @escaping (UIImage?) -> Void) {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            let image = await Self.makeThumbnail(for: url)
            if let image, let self {
                self.cache.setObject(image, forKey: key)
            }
            await MainActor.run { completion(image) }
        }
    }

    func invalidate(for url: URL) {
        cache.removeObject(forKey: url.path as NSString)
    }

    private static func makeThumbnail(for url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.4, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.4, preferredTimescale: 600)

        let time = CMTime(seconds: 0.2, preferredTimescale: 600)

        if #available(iOS 18.0, *) {
            guard let cgImage = try? await generator.image(at: time).image else { return nil }
            return UIImage(cgImage: cgImage)
        } else {
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
            return UIImage(cgImage: cgImage)
        }
    }
}
