import ARKit

struct DeviceCapabilities: Sendable {
    let world: Bool, depth: Bool, meshClassification: Bool, smooth: Bool, planeClassification: Bool
    static func detect() -> DeviceCapabilities {
        #if targetEnvironment(simulator)
        return .init(
            world: false,
            depth: false,
            meshClassification: false,
            smooth: false,
            planeClassification: false
        )
        #else
        return .init(
            world: ARWorldTrackingConfiguration.isSupported,
            depth: ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
            meshClassification: ARWorldTrackingConfiguration.supportsSceneReconstruction(
                .meshWithClassification
            ),
            smooth: ARWorldTrackingConfiguration.supportsFrameSemantics([
                .sceneDepth, .smoothedSceneDepth,
            ]),
            planeClassification: ARPlaneAnchor.isClassificationSupported
        )
        #endif
    }
    var description: String {
        "世界追踪 \(world ? "✓" : "缺失") · sceneDepth \(depth ? "✓" : "缺失") · 网格分类 \(meshClassification ? "✓" : "缺失") · 平面分类 \(planeClassification ? "✓" : "缺失")"
    }
}
