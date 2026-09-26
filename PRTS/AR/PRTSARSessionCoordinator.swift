import Foundation
import ARKit
import Combine
import UIKit

@MainActor
final class PRTSARSessionCoordinator: NSObject, ObservableObject, ARSessionDelegate {
    @Published private(set) var state: PRTSARSessionState = .idle
    @Published private(set) var trackingState: PRTSARTrackingState = .unavailable
    @Published private(set) var supportsDepth = false
    @Published private(set) var supportsMesh = false
    @Published private(set) var latestSequence: UInt64 = 0

    let session = ARSession()
    var onFrame: ((PRTSARFrame) -> Void)?
    var onMeshUpdate: (([ARMeshAnchor]) -> Void)?

    private var sequence: UInt64 = 0
    private var viewportSize = CGSize(width: 1, height: 1)
    private var orientation: UIInterfaceOrientation = .portrait

    override init() {
        super.init()
        session.delegate = self
        refreshCapabilities()
    }

    func updateViewport(size: CGSize, orientation: UIInterfaceOrientation) {
        viewportSize = size
        self.orientation = orientation
    }

    func refreshCapabilities() {
        guard ARWorldTrackingConfiguration.isSupported else {
            state = .unavailable("AR world tracking is not supported on this device")
            supportsDepth = false
            supportsMesh = false
            return
        }
        supportsDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
            || ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
        supportsMesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
            || ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
        if case .unavailable = state { state = .idle }
    }

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            state = .unavailable("AR world tracking is not supported on this device")
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        session.run(configuration, options: [.removeExistingAnchors])
        state = .running
    }

    func pause() {
        session.pause()
        state = .paused
    }

    func stop() {
        session.pause()
        state = .idle
        trackingState = .unavailable
    }

    func resetTracking() {
        guard state == .running else { return }
        state = .relocalizing
        session.run(session.configuration ?? ARWorldTrackingConfiguration(), options: [.resetTracking, .removeExistingAnchors])
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor [weak self] in
            self?.emit(frame)
        }
    }

    private func emit(_ frame: ARFrame) {
        sequence &+= 1
        latestSequence = sequence
        trackingState = PRTSARTrackingState(frame.camera.trackingState)
        if state == .relocalizing, case .normal = trackingState {
            state = .running
        }
        let depth = frame.smoothedSceneDepth ?? frame.sceneDepth
        let output = PRTSARFrame(
            pixelBuffer: frame.capturedImage,
            depthMap: depth?.depthMap,
            confidenceMap: depth?.confidenceMap,
            timestamp: frame.timestamp,
            sequence: sequence,
            intrinsics: frame.camera.intrinsics,
            cameraTransform: frame.camera.transform,
            trackingState: frame.camera.trackingState,
            viewportSize: viewportSize,
            orientation: orientation
        )
        onFrame?(output)
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        publishMesh(anchors)
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        publishMesh(anchors)
    }

    private nonisolated func publishMesh(_ anchors: [ARAnchor]) {
        let meshes = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshes.isEmpty else { return }
        Task { @MainActor [weak self] in self?.onMeshUpdate?(meshes) }
    }

}
