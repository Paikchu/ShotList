import CoreGraphics
import Foundation

// MARK: - 焦距

/// 倍率的显示文本：「1×」「0.5×」「2.3×」。
nonisolated enum SLZoomText {
    /// 小数点后最多一位；整数不写小数位。
    ///
    /// 手机上的焦距就是按「0.5× / 1× / 3×」这么说的，写成「1.0×」反而不像人话。
    static func text(_ factor: CGFloat) -> String {
        let rounded = (factor * 10).rounded() / 10
        if abs(rounded - rounded.rounded()) < 0.001 {
            return "\(Int(rounded.rounded()))×"
        }
        return String(format: "%.1f×", rounded)
    }
}

/// 一档焦距：原始倍率 + 给界面看的倍率。
///
/// 两个值并不总是相等。多摄设备上 `videoZoomFactor == 1` 指的是最广的那颗镜头
/// （iPhone Pro 上相当于 0.5×），系统用 `displayVideoZoomFactorMultiplier`
/// 把它换算成用户熟悉的倍率。界面只碰 `displayFactor`，写回设备时用 `factor`，
/// 两者分得越清楚，越不会出现「点 1× 却跳到 0.5×」这类偏差。
nonisolated struct ZoomStop: Identifiable, Equatable, Sendable {
    /// 写回 `AVCaptureDevice.videoZoomFactor` 的值
    let factor: CGFloat
    /// 界面上显示的倍率
    let displayFactor: CGFloat

    var id: CGFloat { factor }

    var text: String { SLZoomText.text(displayFactor) }
}

/// 界面允许滑到的缩放区间。
///
/// 口径取系统的推荐值，而不是设备能力极限：`minAvailable/maxAvailable` 回答的是
/// 「这台设备此刻物理上到得了哪」，`systemRecommendedVideoZoomRange` 回答的是
/// 「系统认为该让用户滑到哪」——后者正是内建相机缩放控件的取值范围。
///
/// 两者要取交集，不能直接采用推荐值。头文件对该属性特意写了一句：`minAvailable/maxAvailable`
/// 会在推荐区间**之内**再被收窄（例如把镜头切换锁到当前这颗时，下界会被抬到它的换镜头倍率）。
/// 只看推荐值，界面就可能给出设备此刻根本到不了的档位。
nonisolated enum ZoomRangePolicy {
    /// 拿不到系统推荐区间时用的上限。
    ///
    /// 设备实际允许的倍率能到十几倍，但再往上基本只剩数码放大，拍回来不能用。
    /// 这是换用系统推荐区间之前的老口径，只在系统没给推荐值（该属性允许为 nil）时兜底。
    static let fallbackMaximum: CGFloat = 8

    static func range(
        recommended: ClosedRange<CGFloat>?,
        availableLower: CGFloat,
        availableUpper: CGFloat
    ) -> ClosedRange<CGFloat> {
        let lower = min(availableLower, availableUpper)
        let upper = max(availableLower, availableUpper)

        guard let recommended else {
            // 兜底上限本身可能低于设备的可用下界（锁镜头时下界会被抬高），收口时不能再往下压
            return lower...min(upper, max(fallbackMaximum, lower))
        }

        let intersectedLower = max(recommended.lowerBound, lower)
        let intersectedUpper = min(recommended.upperBound, upper)
        // 两边完全错开时交集为空，而 `lower...upper` 这种越界构造会直接崩，退回实际可用区间
        guard intersectedLower <= intersectedUpper else { return lower...upper }
        return intersectedLower...intersectedUpper
    }
}

/// 当前摄像头的变焦范围与档位。
nonisolated struct ZoomScale: Equatable, Sendable {
    /// 原始倍率的可用范围
    var range: ClosedRange<CGFloat> = 1...1
    /// 原始倍率 → 显示倍率的换算系数
    var displayMultiplier: CGFloat = 1
    /// 设备在哪些原始倍率上会切到下一颗镜头
    var switchOverFactors: [CGFloat] = []

    /// 没有换镜头档位时（单摄、前置）给的兜底档位：数码变焦也有几档好按。
    private static let digitalStops: [CGFloat] = [2, 3, 5]

    var isZoomable: Bool { range.upperBound > range.lowerBound * 1.01 }

    /// 默认焦距：显示倍率为 1× 的那一档。
    ///
    /// 多摄设备上最广的一颗往往是超广角——原始倍率 1.0 显示出来是 0.5×。一进相机就停在
    /// 超广角，人会以为「怎么这么宽」；系统相机进去就是 1×，这里也照做：
    /// 显示倍率 1× 对应的原始倍率才是默认值。
    var defaultFactor: CGFloat {
        guard displayMultiplier > 0 else { return clamped(1) }
        return clamped(1 / displayMultiplier)
    }

    /// 一排档位：最广的一档 + 每次换镜头的倍率，去重、去越界后从小到大排。
    var stops: [ZoomStop] {
        guard isZoomable else {
            return [stop(at: range.lowerBound)]
        }

        var factors: [CGFloat] = [range.lowerBound]
        factors.append(contentsOf: switchOverFactors.filter { $0 > range.lowerBound && $0 <= range.upperBound })

        if factors.count == 1 {
            factors.append(contentsOf: Self.digitalStops.filter { $0 <= range.upperBound })
        }

        var unique: [CGFloat] = []
        for factor in factors.sorted() {
            let rounded = (factor * 100).rounded() / 100
            if let last = unique.last, abs(rounded - last) <= 0.05 { continue }
            unique.append(rounded)
        }

        return unique.map { stop(at: $0) }
    }

    func stop(at factor: CGFloat) -> ZoomStop {
        ZoomStop(factor: factor, displayFactor: displayFactor(factor))
    }

    func clamped(_ factor: CGFloat) -> CGFloat {
        min(max(factor, range.lowerBound), range.upperBound)
    }

    func displayFactor(_ factor: CGFloat) -> CGFloat {
        factor * displayMultiplier
    }

    /// 当前倍率是否正好落在某个档位上（相对误差 1% 以内）。
    func isAtStop(_ factor: CGFloat) -> Bool {
        stops.contains { closeEnough($0.factor, factor) }
    }

    /// 松手时吸附：离档位足够近就对上去，免得停在 1.97× 这种位置。
    func stopToSnap(to factor: CGFloat, tolerance: CGFloat = 0.03) -> ZoomStop? {
        stops
            .filter { abs($0.factor - factor) <= max($0.factor, factor) * tolerance }
            .min { abs($0.factor - factor) < abs($1.factor - factor) }
    }

    /// 界面实际画出来的一排胶囊。
    ///
    /// 双指缩放时倍率多半不落在档位上。这时用当前倍率顶替最接近的那一档，
    /// 而不是插一格新的：胶囊的个数与宽度都保持不变，一排按钮不会随着手指左右乱跳。
    func stops(current: CGFloat) -> [ZoomStop] {
        let all = stops
        guard !all.isEmpty, !isAtStop(current) else { return all }

        let index = all.indices.min {
            logRatio(all[$0].factor, current) < logRatio(all[$1].factor, current)
        }
        guard let index else { return all }

        var displayed = all
        displayed[index] = stop(at: current)
        return displayed
    }

    /// 两个倍率的「相对远近」。用对数值比较，2×↔4× 与 1×↔2× 才算一样远。
    private func logRatio(_ lhs: CGFloat, _ rhs: CGFloat) -> Double {
        guard lhs > 0, rhs > 0 else { return .infinity }
        return abs(log(Double(lhs / rhs)))
    }

    private func closeEnough(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        guard lhs != 0, rhs != 0 else { return lhs == rhs }
        return abs(lhs - rhs) <= max(abs(lhs), abs(rhs)) * 0.01
    }
}

// MARK: - 对焦

/// 点按取景画面时得到的两份坐标。
///
/// 两份都要：设备坐标交给 AVFoundation 设对焦点，视图内的归一化位置用来把对焦框
/// 画在手指点上的同一处。设备坐标由预览层自己换算，绕开缩放与旋转的正反算。
nonisolated struct PreviewFocusPoint: Equatable, Sendable {
    /// 设备坐标系（左上 (0,0) — 右下 (1,1)）
    let devicePoint: CGPoint
    /// 预览视图内的归一化位置（左上 (0,0) — 右下 (1,1)）
    let normalizedPoint: CGPoint
}

/// 对焦框的界面状态。
nonisolated struct FocusReticleState: Equatable, Sendable {
    let normalizedPoint: CGPoint
    let isLocked: Bool

    /// 对焦框中心的屏幕位置。
    ///
    /// 归一化位置是按预览视图量的，屏幕尺寸只有界面自己知道，所以在这里换算。
    /// 靠近边缘时往里收一点：对焦框是画在画面上的，贴边会有一半看不见。
    func position(in size: CGSize, edgeInset: CGFloat = 0) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        let marginX = min(0.5, max(0, edgeInset / size.width))
        let marginY = min(0.5, max(0, edgeInset / size.height))
        let x = min(max(normalizedPoint.x, marginX), 1 - marginX)
        let y = min(max(normalizedPoint.y, marginY), 1 - marginY)
        return CGPoint(x: x * size.width, y: y * size.height)
    }
}
