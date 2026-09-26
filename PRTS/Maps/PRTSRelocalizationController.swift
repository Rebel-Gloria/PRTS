import Foundation
import ARKit

@MainActor
final class PRTSRelocalizationController: ObservableObject {
    enum State: Equatable { case idle, loading, searching, localized, failed(String) }
    @Published private(set) var state: State = .idle

    func load(_ worldMap: ARWorldMap, into session: ARSession) {
        state = .loading
        let configuration = ARWorldTrackingConfiguration()
        configuration.initialWorldMap = worldMap
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        state = .searching
    }

    func update(_ trackingState: ARCamera.TrackingState) {
        switch trackingState {
        case .normal: state = .localized
        case .limited(let reason): state = .failed(String(describing: reason))
        case .notAvailable: state = .failed("tracking unavailable")
        @unknown default: state = .failed("unknown tracking state")
        }
    }
}
