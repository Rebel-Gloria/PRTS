import SwiftUI
import ARKit
import SceneKit

struct PRTSARPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = false
        view.scene = SCNScene()
        view.preferredFramesPerSecond = 30
        view.rendersCameraGrain = false
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        if view.session !== session { view.session = session }
    }
}
