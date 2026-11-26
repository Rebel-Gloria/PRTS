import AVFoundation
import SwiftUI
import UIKit

/// The session and rotation stay fixed for this SwiftUI identity. Updates never reattach the camera.
struct CaptureSessionPreview: UIViewRepresentable {
    enum Rotation {
        case portrait, interface

        func angle(for orientation: UIInterfaceOrientation?) -> CGFloat {
            switch (self, orientation) {
            case (.interface, .landscapeLeft): 180
            case (.interface, .landscapeRight): 0
            case (.interface, .portraitUpsideDown): 270
            default: 90
            }
        }
    }

    let session: AVCaptureSession
    let rotation: Rotation

    func makeUIView(context: Context) -> PreviewView {
        PreviewView(session: session, rotation: rotation)
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        private let rotation: Rotation
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        init(session: AVCaptureSession, rotation: Rotation) {
            self.rotation = rotation
            super.init(frame: .zero)
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspectFill
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { return nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            // The connection may not exist until the first frames arrive.
            let angle = rotation.angle(for: window?.windowScene?.interfaceOrientation)
            if let connection = previewLayer.connection,
                connection.isVideoRotationAngleSupported(angle)
            {
                connection.videoRotationAngle = angle
            }
        }
    }
}
