/// Home-screen camera surface for spatial capture or low-vision RGB capture.

import AVFoundation
import SpatialCore
import SwiftUI
import UIKit

struct CameraPreview: View {
    @ObservedObject var camera: CameraManager
    var body: some View {
        if camera.lowVisionMode {
            RGBPreview(session: camera.rgbSession)
        } else {
            // Give the letterboxed renderer the camera image's shape to fill the preview.
            GeometryReader { bounds in
                metalView
                    .aspectRatio(
                        imageAspect(portrait: bounds.size.height > bounds.size.width),
                        contentMode: .fill
                    )
                    .frame(width: bounds.size.width, height: bounds.size.height)
                    .clipped()
            }
        }
    }

    private var metalView: some View {
        CameraMetalView(
            store: camera.model.engine.store,
            diagnostics: camera.model.engine.diagnostics
        )
    }

    /// Width over height on screen; the sensor image is landscape.
    private func imageAspect(portrait: Bool) -> CGFloat {
        let size =
            camera.model.snapshot.frame.map {
                CGFloat($0.intrinsics.width) / CGFloat($0.intrinsics.height)
            } ?? 4 / 3
        return portrait ? 1 / size : size
    }
}

/// Previewing the RGB session does not instantiate the spatial renderer or any spatial work.
private struct RGBPreview: UIViewRepresentable {
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

        override func layoutSubviews() {
            super.layoutSubviews()
            let orientation = window?.windowScene?.interfaceOrientation ?? .portrait
            let angle: CGFloat
            switch orientation {
            case .landscapeLeft: angle = 180
            case .landscapeRight: angle = 0
            case .portraitUpsideDown: angle = 270
            default: angle = 90
            }
            if previewLayer.connection?.isVideoRotationAngleSupported(angle) == true {
                previewLayer.connection?.videoRotationAngle = angle
            }
        }
    }
}
