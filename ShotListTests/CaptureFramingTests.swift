import CoreGraphics
import XCTest
@testable import ShotList

/// 焦距档位与对焦框位置。
///
/// 同样不依赖摄像头：档位来自设备的换镜头倍率，显示倍率来自系统的换算系数，
/// 这两样在模拟器上都拿不到，只能在纯逻辑里把口径钉死。
final class CaptureFramingTests: XCTestCase, @unchecked Sendable {

    // MARK: - 倍率文本

    func testZoomTextDropsTrailingZero() {
        XCTAssertEqual(SLZoomText.text(1), "1×")
        XCTAssertEqual(SLZoomText.text(6), "6×")
        XCTAssertEqual(SLZoomText.text(2.0), "2×")
        XCTAssertEqual(SLZoomText.text(0.5), "0.5×")
        XCTAssertEqual(SLZoomText.text(2.34), "2.3×")
        // 1.99 按一位小数进位后是 2.0，应当写成 2× 而不是 2.0×
        XCTAssertEqual(SLZoomText.text(1.99), "2×")
    }

    // MARK: - 缩放区间

    /// 系统推荐的区间比设备能力窄时，听系统的，不按能力极限来。
    func testRangeFollowsSystemRecommendationWhenItIsNarrower() {
        let range = ZoomRangePolicy.range(recommended: 2...8, availableLower: 1, availableUpper: 25)
        XCTAssertEqual(range, 2...8)
    }

    /// 推荐区间比设备能力宽时以设备此刻允许的为准，否则界面会给出到不了的档位。
    func testRangeIsCappedByWhatTheDeviceActuallyAllows() {
        let range = ZoomRangePolicy.range(recommended: 0.5...20, availableLower: 2, availableUpper: 6)
        XCTAssertEqual(range, 2...6)
    }

    /// 两边各收一半：下界被设备抬高，上界被推荐值压住。
    func testRangeCombinesBothBounds() {
        let range = ZoomRangePolicy.range(recommended: 1...8, availableLower: 2, availableUpper: 25)
        XCTAssertEqual(range, 2...8)
    }

    /// 系统没给推荐值（这个属性允许为 nil）时退回老口径：能力极限再压一道固定上限。
    func testRangeFallsBackToTheCappedDeviceRange() {
        let range = ZoomRangePolicy.range(recommended: nil, availableLower: 1, availableUpper: 25)
        XCTAssertEqual(range, 1...ZoomRangePolicy.fallbackMaximum)
    }

    /// 兜底上限低于设备下界（锁镜头时下界会被抬高）时不能再往下压，否则区间会反转。
    func testFallbackNeverInvertsTheRange() {
        let range = ZoomRangePolicy.range(recommended: nil, availableLower: 12, availableUpper: 25)
        XCTAssertEqual(range, 12...12)
    }

    /// 推荐区间与设备可用区间完全错开时交集为空，退回可用区间而不是构造非法区间。
    func testDisjointRecommendationFallsBackToAvailableRange() {
        let range = ZoomRangePolicy.range(recommended: 12...20, availableLower: 1, availableUpper: 6)
        XCTAssertEqual(range, 1...6)
    }

    /// 设备报上来的上下界颠倒时也要给出合法区间。
    func testInvertedAvailableBoundsAreNormalised() {
        let range = ZoomRangePolicy.range(recommended: 1...6, availableLower: 6, availableUpper: 2)
        XCTAssertEqual(range, 2...6)
    }

    /// 交集恰好落到一个点上也要出得来。
    func testRangeSupportsASinglePointIntersection() {
        let range = ZoomRangePolicy.range(recommended: 1...4, availableLower: 4, availableUpper: 10)
        XCTAssertEqual(range, 4...4)
    }

    /// 区间收窄后，落在区间外的换镜头倍率不再出现在档位里。
    func testStopsDropSwitchOverFactorsOutsideTheResolvedRange() {
        let range = ZoomRangePolicy.range(recommended: 1...5, availableLower: 1, availableUpper: 25)
        let scale = ZoomScale(range: range, displayMultiplier: 0.5, switchOverFactors: [2, 6])
        XCTAssertEqual(scale.stops.map(\.text), ["0.5×", "1×"])
    }

    // MARK: - 档位

    /// iPhone Pro 这类三摄：最广一颗是 1.0，换镜头发生在 2.0 与 6.0，
    /// 显示倍率要乘 0.5 —— 也就是 0.5× / 1× / 3×。
    private let tripleCamera = ZoomScale(
        range: 1...8,
        displayMultiplier: 0.5,
        switchOverFactors: [2, 6]
    )

    func testStopsTranslateRawFactorsIntoDisplayFactors() {
        XCTAssertEqual(tripleCamera.stops.map(\.factor), [1, 2, 6])
        XCTAssertEqual(tripleCamera.stops.map(\.text), ["0.5×", "1×", "3×"])
    }

    func testStopsIgnoreOutOfRangeAndDuplicatedSwitchOverFactors() {
        let scale = ZoomScale(range: 1...3, displayMultiplier: 1, switchOverFactors: [2, 2, 6])
        XCTAssertEqual(scale.stops.map(\.factor), [1, 2])
    }

    func testSingleLensCameraFallsBackToDigitalStops() {
        // 前置、或者只有一颗广角时没有换镜头倍率，给几档数码变焦才按得动
        let front = ZoomScale(range: 1...5, displayMultiplier: 1, switchOverFactors: [])
        XCTAssertEqual(front.stops.map(\.factor), [1, 2, 3, 5])
    }

    func testNonZoomableDeviceOffersSingleStop() {
        let fixed = ZoomScale(range: 1...1, displayMultiplier: 1, switchOverFactors: [])
        XCTAssertFalse(fixed.isZoomable)
        XCTAssertEqual(fixed.stops.map(\.text), ["1×"])
    }

    func testDisplayedStopsReplaceNearestStopInsteadOfAddingOne() {
        // 2.3 落在 2 与 6 之间，离 2 更近：顶替 2 那一格，胶囊数量不变
        let displayed = tripleCamera.stops(current: 2.3)
        XCTAssertEqual(displayed.map(\.factor), [1, 2.3, 6])
        XCTAssertEqual(displayed.map(\.text), ["0.5×", "1.2×", "3×"])
    }

    func testDisplayedStopsStayPutWhenCurrentSitsOnAStop() {
        XCTAssertEqual(tripleCamera.stops(current: 2).map(\.factor), [1, 2, 6])
        XCTAssertTrue(tripleCamera.isAtStop(2))
        XCTAssertFalse(tripleCamera.isAtStop(2.3))
    }

    func testSnapOnlyAppliesNearAStop() {
        XCTAssertEqual(tripleCamera.stopToSnap(to: 1.97)?.factor, 2)
        XCTAssertEqual(tripleCamera.stopToSnap(to: 0.99)?.factor, 1)
        XCTAssertNil(tripleCamera.stopToSnap(to: 1.5))
    }

    func testClampingKeepsZoomInsideDeviceRange() {
        XCTAssertEqual(tripleCamera.clamped(12), 8)
        XCTAssertEqual(tripleCamera.clamped(0.2), 1)
        XCTAssertEqual(tripleCamera.clamped(3), 3)
        XCTAssertEqual(tripleCamera.displayFactor(4), 2)
    }

    func testDefaultFactorIsTheDisplayOneTimeStop() {
        // 三摄：显示倍率 1× 落在原始倍率 2.0 上，不能一进相机就停在 0.5×
        XCTAssertEqual(tripleCamera.defaultFactor, 2)
        XCTAssertEqual(SLZoomText.text(tripleCamera.displayFactor(tripleCamera.defaultFactor)), "1×")

        // 单颗广角：原始 1.0 就是 1×
        let single = ZoomScale(range: 1...8, displayMultiplier: 1, switchOverFactors: [])
        XCTAssertEqual(single.defaultFactor, 1)

        // 换算出来的默认值超出这台设备的范围时收进范围里
        let limited = ZoomScale(range: 1...1.5, displayMultiplier: 0.5, switchOverFactors: [])
        XCTAssertEqual(limited.defaultFactor, 1.5)
    }

    func testZoomlessDeviceKeepsStopsEmptyWhenRangeCollapses() {
        let unknown = ZoomScale()
        XCTAssertEqual(unknown.stops.count, 1)
        XCTAssertFalse(unknown.isZoomable)
    }

    // MARK: - 对焦框位置

    func testReticleSitsOnTheTappedPoint() {
        let reticle = FocusReticleState(normalizedPoint: CGPoint(x: 0.5, y: 0.25), isLocked: false)
        let position = reticle.position(in: CGSize(width: 400, height: 800))
        XCTAssertEqual(position.x, 200, accuracy: 0.001)
        XCTAssertEqual(position.y, 200, accuracy: 0.001)
    }

    func testReticleIsPushedAwayFromEdgesByTheInset() {
        let reticle = FocusReticleState(normalizedPoint: CGPoint(x: 0, y: 1), isLocked: false)
        let position = reticle.position(in: CGSize(width: 400, height: 800), edgeInset: 40)
        XCTAssertEqual(position.x, 40, accuracy: 0.001)
        XCTAssertEqual(position.y, 760, accuracy: 0.001)
    }

    func testReticleHandlesDegenerateSize() {
        let reticle = FocusReticleState(normalizedPoint: CGPoint(x: 0.5, y: 0.5), isLocked: true)
        XCTAssertEqual(reticle.position(in: .zero), .zero)
    }
}
