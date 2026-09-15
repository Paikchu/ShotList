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
