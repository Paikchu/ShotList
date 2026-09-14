import AVFoundation
import SwiftUI

/// 把 `AVCaptureVideoPreviewLayer` 桥接进 SwiftUI。
struct CameraPreview: UIViewRepresentable {
    let recorder: CameraRecorder

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        recorder.attachPreviewLayer(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        if uiView.previewLayer.session !== recorder.session {
            recorder.attachPreviewLayer(uiView.previewLayer)
        }
    }

    static func dismantleUIView(_ uiView: CameraPreviewView, coordinator: ()) {
        uiView.previewLayer.session = nil
    }
}

/// 以预览层作为 backing layer，省去手动同步 frame 的麻烦。
final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            preconditionFailure("CameraPreviewView 的 backing layer 必须是 AVCaptureVideoPreviewLayer")
        }
        return layer
    }
}
