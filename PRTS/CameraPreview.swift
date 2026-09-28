import SwiftUI

/// Uses the same aspect-fit renderer and the same ARSession as analysis.
struct CameraPreview: View {
    @ObservedObject var camera: CameraManager
    var body: some View {
        CameraMetalView(store:camera.model.engine.store,diagnostics:camera.model.engine.diagnostics)
    }
}
