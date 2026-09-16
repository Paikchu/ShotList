#if DEBUG

import SwiftUI

/// 取景界面的验收入口（仅 Debug 构建）。
///
/// 模拟器没有摄像头：走真实路径只会停在「无法使用相机」那一屏，取景界面的排版、
/// 档位样式、描述卡片都没法看。这里用固定数据渲染 `CameraChrome`，让改这一页的人
/// 能像对待其他页面一样，起模拟器、截图、逐项核对。
///
/// ```bash
/// xcrun simctl launch <UDID> com.max.ShotList -chromeDemo 1   # 取景页：描述折叠 + 焦距档位
/// xcrun simctl launch <UDID> com.max.ShotList -chromeDemo 2   # 描述展开
/// xcrun simctl launch <UDID> com.max.ShotList -chromeDemo 3   # 拍摄中 + 对焦锁定 + 对焦框
/// xcrun simctl launch <UDID> com.max.ShotList -chromeDemo 4   # 拍摄设置（分辨率与帧率）
/// xcrun simctl launch <UDID> com.max.ShotList -chromeDemo 5   # 分镜还没写描述
/// ```
///
/// 画面里的背景是一块纯色：它只是衬托，不代表相机画面。
struct CameraChromeDemoScreen: View {
    @State private var isNoteExpanded = false
    @State private var isShowingSettings = false

    private var variant: Int {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-chromeDemo"), index + 1 < arguments.count else {
            return 1
        }
        return Int(arguments[index + 1]) ?? 1
    }

    /// 三摄那类设备的焦距表：最广一颗是超广角，换镜头发生在 2.0 与 6.0
    private var scale: ZoomScale {
        ZoomScale(range: 1...8, displayMultiplier: 0.5, switchOverFactors: [2, 6])
    }

    private var state: CameraChromeState {
        CameraChromeState(
            shotNumber: "16",
            note: variant == 5
                ? ""
                : "手冲壶出水特写，收环境音；壶嘴贴住杯口，水线细一点，别让蒸汽糊住镜头。拍完这一条再接下一个机位，中途不要停。",
            savedTakeCount: 2,
            isRecording: variant == 3,
            elapsed: variant == 3 ? 42 : 0,
            isTorchOn: false,
            isTorchAvailable: true,
            isSaving: false,
            zoomScale: scale,
            zoomFactor: variant == 3 ? 2.3 : scale.defaultFactor,
            settingsText: "4K·30",
            settingsAccessibilityText: "4K · 30 fps",
            isFocusLocked: variant == 3
        )
    }

    var body: some View {
        ZStack {
            Color(white: 0.12)
                .ignoresSafeArea()

            ZStack {
                if variant == 3 {
                    FocusReticle(
                        state: FocusReticleState(
                            normalizedPoint: CGPoint(x: 0.42, y: 0.46),
                            isLocked: true
                        ),
                        containerSize: CGSize(width: 393, height: 852)
                    )
                }
            }
            .ignoresSafeArea()

            CameraChrome(
                state: state,
                isNoteExpanded: $isNoteExpanded,
                onClose: {},
                onToggleNote: { isNoteExpanded.toggle() },
                onOpenSettings: { isShowingSettings = true },
                onToggleTorch: {},
                onToggleRecording: {},
                onSwitchCamera: {},
                onSelectZoom: { _ in },
                onUnlockFocus: {}
            )
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isShowingSettings) {
            CameraSettingsSheet(
                availableResolutions: [.uhd4K, .hd1080, .hd720],
                availableFrameRates: [.fps24, .fps30],
                resolution: .hd1080,
                frameRate: .fps30,
                isRecording: false,
                onSelectResolution: { _ in },
                onSelectFrameRate: { _ in },
                onDismiss: { isShowingSettings = false }
            )
            .presentationDetents([.large])
        }
        .task {
            isNoteExpanded = variant == 2
            isShowingSettings = variant == 4
        }
    }
}

/// 直接打开真实取景页（仅 Debug 构建），用来验收「没有摄像头时的降级链路」。
///
/// 这条路径上有权限、会话启动与配置失败三段真实分支，模拟器里点不到列表卡片，
/// 就由这个入口把页面直接拉起来。
///
/// ```bash
/// xcrun simctl launch <UDID> com.max.ShotList -cameraDemo
/// ```
struct CameraCaptureDemoScreen: View {
    @State private var isPresented = true
    @State private var store = ShotStore()

    var body: some View {
        Color.black
            .ignoresSafeArea()
            .fullScreenCover(isPresented: $isPresented) {
                CameraCaptureView(
                    shot: Shot(number: 16, note: "手冲壶出水特写，收环境音；壶嘴贴住杯口，水线细一点。"),
                    onRequestImport: {}
                )
                .environmentObject(store)
            }
    }
}

#endif
