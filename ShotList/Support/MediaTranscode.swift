import AVFoundation
import Foundation

nonisolated enum MediaTranscodeError: LocalizedError {
    /// 用户选的是「原片」，却调到了这里——调用方应该在 `needsTranscode` 上判过
    case notATranscodeOption
    /// 系统无法为这段素材建起导出会话
    case sessionUnavailable
    /// 目标容器不在系统支持的列表里
    case unsupportedContainer

    var errorDescription: String? {
        switch self {
        case .notATranscodeOption: return "没有指定转码格式"
        case .sessionUnavailable: return "系统无法处理这段视频"
        case .unsupportedContainer: return "系统不支持写入 QuickTime 容器"
        }
    }
}

/// 导出时的按需转码。
///
/// 导入与拍摄都保留原始文件，因此默认导出就是原片；只有用户在「导出」页显式选了
/// 某个格式才走这里。放在独立文件里，是为了让 `ExportPackageBuilder` 继续只管
/// 包内结构与命名——「怎么编码」是另一件事，混在一起会让那些纯逻辑也得带上 AVFoundation。
nonisolated enum MediaTranscode {
    /// 转码后的容器。
    ///
    /// 固定用 QuickTime：`supportedFileTypes` 实测在三种预设下都包含它，
    /// 扩展名与容器不会打架，与相机拍出来的片段也是同一种容器。
    static let containerFileType: AVFileType = .mov

    /// 把 `source` 按目标格式转码写入 `destination`。
    ///
    /// - 失败或取消时删掉半成品：调用方只会拿到「没有这个文件」或者一个错误，
    ///   不会在包里留下一个播不了的残片。
    /// - `@concurrent` 不能省：转码是重 CPU，留在主协程会把界面按住。
    @concurrent
    static func export(source: URL, to destination: URL, option: ExportTranscodeOption) async throws {
        guard let preset = option.transcodePresetName else {
            throw MediaTranscodeError.notATranscodeOption
        }

        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MediaTranscodeError.sessionUnavailable
        }
        guard session.supportedFileTypes.contains(containerFileType) else {
            throw MediaTranscodeError.unsupportedContainer
        }

        do {
            try await session.export(to: destination, as: containerFileType)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

nonisolated extension ExportTranscodeOption {
    /// 转码时交给 AVFoundation 的预设；「原片」没有预设，返回 `nil`。
    ///
    /// 两个预设都是**上限**语义：实测 640×360 的素材走 1080p 预设出来仍是 640×360，
    /// 不会被放大，所以小素材不会因为选了这个格式反而变大。
    /// 另外源文件本来就符合目标格式时，系统会直接免掉重编码（1080p H.264 走
    /// H.264 预设只花几十毫秒），所以「选了转码」不等于一定会重编一遍。
    var transcodePresetName: String? {
        switch self {
        case .original: return nil
        case .compatible: return AVAssetExportPreset1920x1080
        case .compact: return AVAssetExportPresetHEVC1920x1080
        }
    }
}
