/// Home-screen camera surface. It renders the same Metal view used by spatial analysis.

import SwiftUI
import SpatialCore

/// Uses the same aspect-fit renderer and the same ARSession as analysis.
struct CameraPreview: View {
    @ObservedObject var camera: CameraManager
    var body: some View {
        #if PRTS_DEV_CAPTURE
        metalView
        #else
        // The renderer letterboxes so dev builds see the whole image. Here the view is given the
        // image's own shape and overflows the screen instead, so the picture fills it edge to edge.
        GeometryReader { bounds in
            metalView
                .aspectRatio(imageAspect(portrait: bounds.size.height > bounds.size.width), contentMode: .fill)
                .frame(width: bounds.size.width, height: bounds.size.height)
                .clipped()
        }
        #endif
    }

    private var metalView: some View {
        CameraMetalView(store:camera.model.engine.store,diagnostics:camera.model.engine.diagnostics)
    }

    /// Width over height on screen; the sensor image is landscape.
    private func imageAspect(portrait: Bool) -> CGFloat {
        let size = camera.model.snapshot.frame.map { CGFloat($0.intrinsics.width) / CGFloat($0.intrinsics.height) } ?? 4/3
        return portrait ? 1/size : size
    }
}
