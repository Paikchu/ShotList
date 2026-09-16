import AVFoundation
import SwiftUI
import UIKit

/// 把 `AVCaptureVideoPreviewLayer` 桥接进 SwiftUI，并把取景画面上的三种手势交回界面：
/// 点按对焦、长按锁定对焦与曝光、双指调整焦距。
///
/// 手势放在 UIKit 这一层而不是 SwiftUI 覆盖层上，是为了拿到
/// `captureDevicePointConverted(fromLayerPoint:)`：画面既有缩放又有旋转，
/// 自己把手指位置换算成设备坐标容易差半屏，交给预览层换算最稳。
/// 顺带也避开了 SwiftUI 手势与 UIKit 手势互相抢触摸的问题。
struct CameraPreview: UIViewRepresentable {
    let recorder: CameraRecorder

    /// 点按 / 长按取景画面。第二个参数为 `true` 表示锁定。
    var onFocus: @MainActor (PreviewFocusPoint, Bool) -> Void
    /// 双指缩放。`scale` 是这次手势开始以来的累计倍数。
    var onPinch: @MainActor (CGFloat, UIGestureRecognizer.State) -> Void

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onFocus = onFocus
        view.onPinch = onPinch
        recorder.attachPreviewLayer(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        // 每次刷新都重新绑一遍：闭包会捕获新的界面状态，绑一次就不再更新的话，
        // 手势里读到的会是第一次渲染时的值
        uiView.onFocus = onFocus
        uiView.onPinch = onPinch
        if uiView.previewLayer.session !== recorder.session {
            recorder.attachPreviewLayer(uiView.previewLayer)
        }
    }

    static func dismantleUIView(_ uiView: CameraPreviewView, coordinator: ()) {
        uiView.previewLayer.session = nil
    }
}

/// 以预览层作为 backing layer，省去手动同步 frame 的麻烦；
/// 三种手势也挂在这里，位置换算直接用预览层自己的方法。
final class CameraPreviewView: UIView {
    var onFocus: (@MainActor (PreviewFocusPoint, Bool) -> Void)?
    var onPinch: (@MainActor (CGFloat, UIGestureRecognizer.State) -> Void)?

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            preconditionFailure("CameraPreviewView 的 backing layer 必须是 AVCaptureVideoPreviewLayer")
        }
        return layer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        press.minimumPressDuration = 0.45
        addGestureRecognizer(press)

        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CameraPreviewView 只从代码创建")
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let point = focusPoint(of: recognizer) else { return }
        onFocus?(point, false)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let point = focusPoint(of: recognizer) else { return }
        onFocus?(point, true)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        onPinch?(recognizer.scale, recognizer.state)
    }

    /// 手指位置的两份换算：设备坐标交给 AVFoundation，视图内归一化位置用来画对焦框。
    private func focusPoint(of recognizer: UIGestureRecognizer) -> PreviewFocusPoint? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let location = recognizer.location(in: self)
        return PreviewFocusPoint(
            devicePoint: previewLayer.captureDevicePointConverted(fromLayerPoint: location),
            normalizedPoint: CGPoint(x: location.x / bounds.width, y: location.y / bounds.height)
        )
    }
}
