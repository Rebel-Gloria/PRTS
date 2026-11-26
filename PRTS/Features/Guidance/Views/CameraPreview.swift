/// Home-screen camera surface for spatial capture or low-vision RGB capture.

import SpatialCore
import SwiftUI

struct CameraPreview: View {
    @ObservedObject var camera: CameraManager
    var body: some View {
        if camera.lowVisionMode {
            CaptureSessionPreview(session: camera.rgbSession, rotation: .interface)
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
