import AVFoundation
import CoreMedia
import Foundation

/// 一条音轨的实测参数。
///
/// `index` 是这条音轨在文件里的次序（从 0 数），剪辑工具按它挑轨道（ffmpeg 里写作 `0:a:<index>`）。
/// iPhone 的空间音频（`apac`）多数剪辑工具解不了，而同一个文件里还写着一条兼容用的 AAC 立体声，
/// 两者的先后每条素材都可能不同，所以次序必须逐条给出，不能让剪辑侧按固定位置猜。
nonisolated struct AudioTrackInfo: Codable, Sendable, Equatable {
    let index: Int
    /// 编码。AAC 统一写 `aac`，其余按四字符码原样给（空间音频是 `apac`）。
    let codec: String
    let channels: Int?
    let sampleRate: Int?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        try container.encode(codec, forKey: .codec)
        try container.encode(channels, forKey: .channels)
        try container.encode(sampleRate, forKey: .sampleRate)
    }
}

/// 视频轨的实测参数。
nonisolated struct VideoTrackInfo: Codable, Sendable, Equatable {
    let codec: String?
    let bitDepth: Int?
    /// 编码宽高。竖屏素材多数是横着编码的，靠 `rotation` 转正。
    let codedSize: [Int]?
    /// 显示时要把画面转多少度（顺时针为正）。注意 ffprobe 报的符号与这里相反。
    let rotation: Int?
    /// 转正之后的宽高。算画幅、裁切一律用它，不要用 `codedSize`。
    let displaySize: [Int]?
    /// 平均帧率
    let fps: Double?
    /// 可变帧率：平均帧率与最快的那一帧对不上。iPhone 录的素材多数是这样，剪之前要统一成恒定帧率。
    let variableFrameRate: Bool?
    /// `HLG`、`PQ` 或 `nil`（SDR）
    let hdr: String?

    /// 读不出来的字段要写成 `null`，不能整个键消失：合成的编码器会跳过 `nil`，
    /// 剪辑侧就分不清「这一项没读到」和「这一版没有这个字段」。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(codec, forKey: .codec)
        try container.encode(bitDepth, forKey: .bitDepth)
        try container.encode(codedSize, forKey: .codedSize)
        try container.encode(rotation, forKey: .rotation)
        try container.encode(displaySize, forKey: .displaySize)
        try container.encode(fps, forKey: .fps)
        try container.encode(variableFrameRate, forKey: .variableFrameRate)
        try container.encode(hdr, forKey: .hdr)
    }
}

/// 一条素材的实测参数，写进导出包的 `manifest.json`。
nonisolated struct ClipMediaInfo: Codable, Sendable, Equatable {
    let duration: Double?
    /// 素材自带的拍摄时间。相册导入的素材靠它才能知道真正拍摄的时刻。
    let capturedAt: Date?
    let video: VideoTrackInfo?
    let audio: [AudioTrackInfo]
    /// 剪辑时该用哪条音轨：优先 AAC 立体声，其次任意 AAC；都没有时为 `nil`。
    let preferredAudioIndex: Int?

    /// 读不出来时的兜底：字段全空，打包照常完成（见 `MediaProbe.probe`）。
    static let unknown = ClipMediaInfo(duration: nil, capturedAt: nil, video: nil, audio: [], preferredAudioIndex: nil)
}

/// 读取一条素材的实测参数。
///
/// 读的是**打进包里的那份文件**：选了转码时，剪辑侧拿到的是转码结果，参数必须对得上它。
///
/// 任何一项读不出来都不抛错，只把对应字段留空——导出的主产物是视频，不能因为读不到元数据就失败。
nonisolated enum MediaProbe {

    /// `@concurrent` 不能省：解析媒体文件要走磁盘，按「非隔离 async 留在调用方线程」的默认语义，
    /// 它会跟着打包一起压在调用方所在的协程上。
    @concurrent
    static func probe(_ url: URL) async -> ClipMediaInfo {
        let asset = AVURLAsset(url: url)

        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds).flatMap { seconds in
            seconds.isFinite && seconds > 0 ? (seconds * 1000).rounded() / 1000 : nil
        }

        var capturedAt: Date?
        if let item = try? await asset.load(.creationDate) {
            capturedAt = try? await item.load(.dateValue)
        }

        let audio = await audioTracks(of: asset)

        return ClipMediaInfo(
            duration: duration,
            capturedAt: capturedAt,
            video: await videoTrack(of: asset),
            audio: audio,
            preferredAudioIndex: preferredAudioIndex(in: audio)
        )
    }

    /// AAC 立体声优先，其次任意 AAC。空间音频（`apac`）声道更多，但多数工具解不了，不能按声道数挑。
    static func preferredAudioIndex(in tracks: [AudioTrackInfo]) -> Int? {
        tracks.first { $0.codec == "aac" && $0.channels == 2 }?.index
            ?? tracks.first { $0.codec == "aac" }?.index
    }

    // MARK: - 逐轨读取

    private static func videoTrack(of asset: AVURLAsset) async -> VideoTrackInfo? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }

        let size = try? await track.load(.naturalSize)
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let nominalFrameRate = (try? await track.load(.nominalFrameRate)).map(Double.init)
        let minFrameDuration = try? await track.load(.minFrameDuration)
        let isHDR = ((try? await track.load(.mediaCharacteristics)) ?? []).contains(.containsHDRVideo)
        let description = (try? await track.load(.formatDescriptions))?.first

        let rotation = Int(atan2(transform.b, transform.a) * 180 / .pi)
        let display = size?.applying(transform)

        return VideoTrackInfo(
            codec: description.map { codecName(CMFormatDescriptionGetMediaSubType($0)) },
            bitDepth: description.flatMap { extensionValue($0, "BitsPerComponent") as? Int },
            codedSize: size.map { [Int($0.width.rounded()), Int($0.height.rounded())] },
            rotation: rotation,
            displaySize: display.map { [Int(abs($0.width).rounded()), Int(abs($0.height).rounded())] },
            fps: nominalFrameRate.map { ($0 * 1000).rounded() / 1000 },
            variableFrameRate: variableFrameRate(nominal: nominalFrameRate, minFrameDuration: minFrameDuration),
            hdr: isHDR ? transferFunction(description) : nil
        )
    }

    private static func audioTracks(of asset: AVURLAsset) async -> [AudioTrackInfo] {
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        var result: [AudioTrackInfo] = []
        for (index, track) in tracks.enumerated() {
            guard let description = (try? await track.load(.formatDescriptions))?.first,
                  let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { continue }
            result.append(
                AudioTrackInfo(
                    index: index,
                    codec: basic.mFormatID == kAudioFormatMPEG4AAC ? "aac" : fourCharCode(basic.mFormatID),
                    channels: Int(basic.mChannelsPerFrame),
                    sampleRate: basic.mSampleRate > 0 ? Int(basic.mSampleRate) : nil
                )
            )
        }
        return result
    }

    /// 平均帧率（`nominalFrameRate`）与最快的一帧（`minFrameDuration`）对不上就是可变帧率。
    ///
    /// 两者的差距很小（实测 59.88 对 59.94），所以门限取千分之一，不能按常见的百分之几判。
    private static func variableFrameRate(nominal: Double?, minFrameDuration: CMTime?) -> Bool? {
        guard let nominal, nominal > 0,
              let minFrameDuration, minFrameDuration.isValid, minFrameDuration.seconds > 0 else { return nil }
        let fastest = 1 / minFrameDuration.seconds
        return abs(fastest - nominal) > max(nominal * 0.001, 0.01)
    }

    private static func transferFunction(_ description: CMFormatDescription?) -> String? {
        guard let value = description.flatMap({ extensionValue($0, kCMFormatDescriptionExtension_TransferFunction as String) }) as? String
        else { return nil }
        switch value {
        case String(kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG): return "HLG"
        case String(kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ): return "PQ"
        default: return value
        }
    }

    private static func extensionValue(_ description: CMFormatDescription, _ key: String) -> Any? {
        CMFormatDescriptionGetExtension(description, extensionKey: key as CFString)
    }

    private static func codecName(_ code: FourCharCode) -> String {
        switch code {
        case kCMVideoCodecType_HEVC: return "hevc"
        case kCMVideoCodecType_H264: return "h264"
        default: return fourCharCode(code)
        }
    }

    private static func fourCharCode(_ code: FourCharCode) -> String {
        let bytes = [UInt8(code >> 24 & 0xFF), UInt8(code >> 16 & 0xFF), UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)]
        let text = String(bytes: bytes, encoding: .ascii) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "\(code)" : trimmed
    }
}
