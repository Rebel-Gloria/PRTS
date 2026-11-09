import AVFoundation
import SwiftUI
import UIKit

/// What the main (wide) camera sees while reading text, for low-vision users and helpers.
struct TextCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        // The connection only exists once the session has its camera, so set portrait late.
        override func layoutSubviews() {
            super.layoutSubviews()
            if previewLayer.connection?.isVideoRotationAngleSupported(90) == true {
                previewLayer.connection?.videoRotationAngle = 90
            }
        }
    }
}
