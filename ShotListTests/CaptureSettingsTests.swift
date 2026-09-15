import AVFoundation
import XCTest
@testable import ShotList

/// 分辨率与帧率的选择逻辑。
///
/// 这些用例全部用合成的格式描述符跑，不依赖摄像头——模拟器没有摄像头，
/// 而「哪一档能选、选不了退到哪一档」正是最容易算错的地方。
final class CaptureSettingsTests: XCTestCase, @unchecked Sendable {

    // MARK: - 设备格式目录

    private let catalog = CaptureFormatCatalog(descriptors: [
        // 4K 只到 30
        CaptureFormatDescriptor(width: 3840, height: 2160, minimumFrameRate: 24, maximumFrameRate: 30),
        // 1080p 有两份：一份正常帧率，一份到 60
        CaptureFormatDescriptor(width: 1920, height: 1080, minimumFrameRate: 24, maximumFrameRate: 30),
        CaptureFormatDescriptor(width: 1920, height: 1080, minimumFrameRate: 30, maximumFrameRate: 60),
        // 720p 一路到 60
        CaptureFormatDescriptor(width: 1280, height: 720, minimumFrameRate: 24, maximumFrameRate: 60),
        // 与三档分辨率都对不上的中间格式，必须被忽略
        CaptureFormatDescriptor(width: 1440, height: 1080, minimumFrameRate: 24, maximumFrameRate: 30)
    ])

    func testResolutionsAreReportedLargestFirst() {
        XCTAssertEqual(catalog.resolutions, [.uhd4K, .hd1080, .hd720])
    }

    func testFrameRatesAreComputedPerResolution() {
        XCTAssertEqual(catalog.frameRates(for: .uhd4K), [.fps24, .fps30])
        XCTAssertEqual(catalog.frameRates(for: .hd1080), [.fps24, .fps30, .fps60])
        XCTAssertEqual(catalog.frameRates(for: .hd720), [.fps24, .fps30, .fps60])
    }

    func testFrameRateSupportToleratesReportedApproximations() {
        // 设备常报 59.94 这类近似上限，不能因此把 60 fps 判成不可用
        let approximate = CaptureFormatDescriptor(
            width: 1920, height: 1080, minimumFrameRate: 29.97, maximumFrameRate: 59.94
        )
        XCTAssertTrue(approximate.supports(.fps30))
        XCTAssertTrue(approximate.supports(.fps60))
        XCTAssertFalse(approximate.supports(.fps24))
    }

    func testDescriptorPicksLowestBandwidthFormatCoveringTargetFrameRate() {
        // 30 fps 应该选 24–30 那份，而不是带宽更高的 30–60 那份
        XCTAssertEqual(
            catalog.descriptor(for: .hd1080, frameRate: .fps30),
            CaptureFormatDescriptor(width: 1920, height: 1080, minimumFrameRate: 24, maximumFrameRate: 30)
        )
        XCTAssertEqual(
            catalog.descriptor(for: .hd1080, frameRate: .fps60),
            CaptureFormatDescriptor(width: 1920, height: 1080, minimumFrameRate: 30, maximumFrameRate: 60)
        )
        // 4K 没有 60 fps 的格式，就不该硬凑一份
        XCTAssertNil(catalog.descriptor(for: .uhd4K, frameRate: .fps60))
    }

    func testEmptyCatalogReportsNothing() {
        let empty = CaptureFormatCatalog()
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(empty.resolutions.isEmpty)
        XCTAssertTrue(empty.frameRates(for: .hd1080).isEmpty)
        XCTAssertNil(empty.descriptor(for: .hd1080, frameRate: .fps30))
    }

    func testResolutionMatchingAcceptsSwappedDimensions() {
        XCTAssertEqual(CaptureResolution.matching(width: 3840, height: 2160), .uhd4K)
        XCTAssertEqual(CaptureResolution.matching(width: 1080, height: 1920), .hd1080)
        XCTAssertNil(CaptureResolution.matching(width: 1440, height: 1080))
        XCTAssertTrue(CaptureResolution.hd1080.matches(width: 1080, height: 1920))
    }

    // MARK: - 帧率退档

    func testClosestFrameRateFallsBackDownFirst() {
        XCTAssertEqual(CaptureFrameRate.closest(to: .fps60, among: [.fps24, .fps30]), .fps30)
        XCTAssertEqual(CaptureFrameRate.closest(to: .fps24, among: [.fps30, .fps60]), .fps30)
        XCTAssertEqual(CaptureFrameRate.closest(to: .fps30, among: [.fps24, .fps30, .fps60]), .fps30)
        XCTAssertNil(CaptureFrameRate.closest(to: .fps30, among: []))
    }

    // MARK: - 展示文本

    func testSettingsSummary() {
        XCTAssertEqual(CaptureSettingsText.summary(resolution: .uhd4K, frameRate: .fps30), "4K · 30 fps")
        XCTAssertEqual(CaptureSettingsText.summary(resolution: .hd1080, frameRate: nil), "1080p")
        XCTAssertEqual(CaptureSettingsText.summary(resolution: nil, frameRate: .fps60), "60 fps")
        XCTAssertNil(CaptureSettingsText.summary(resolution: nil, frameRate: nil))
    }

    func testCompactSettingsSummary() {
        XCTAssertEqual(CaptureSettingsText.compactSummary(resolution: .uhd4K, frameRate: .fps60), "4K·60")
        XCTAssertEqual(CaptureSettingsText.compactSummary(resolution: .hd720, frameRate: nil), "720p")
        XCTAssertEqual(CaptureSettingsText.compactSummary(resolution: nil, frameRate: .fps24), "24fps")
        XCTAssertNil(CaptureSettingsText.compactSummary(resolution: nil, frameRate: nil))
    }

    // MARK: - 偏好

    func testPreferencesRoundTripAndClear() {
        let suiteName = "com.max.ShotList.tests.camera-preferences"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = CameraPreferences(defaults: defaults)
        XCTAssertNil(preferences.resolution)
        XCTAssertNil(preferences.frameRate)

        preferences.resolution = .uhd4K
        preferences.frameRate = .fps60

        let reloaded = CameraPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.resolution, .uhd4K)
        XCTAssertEqual(reloaded.frameRate, .fps60)

        reloaded.resolution = nil
        XCTAssertNil(CameraPreferences(defaults: defaults).resolution)
        XCTAssertEqual(CameraPreferences(defaults: defaults).frameRate, .fps60)
    }

    func testPreferencesIgnoreUnknownStoredValues() {
        let suiteName = "com.max.ShotList.tests.camera-preferences-corrupt"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("8K", forKey: "camera.captureResolution")
        defaults.set(120, forKey: "camera.captureFrameRate")

        let preferences = CameraPreferences(defaults: defaults)
        XCTAssertNil(preferences.resolution)
        XCTAssertNil(preferences.frameRate)
    }
}
