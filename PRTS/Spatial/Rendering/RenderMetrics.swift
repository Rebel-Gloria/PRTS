import ARKit
import Foundation
import SpatialCore
import simd

nonisolated struct RenderMetrics: Sendable {
    var fps: Double = 0
    var cpuMS: Double = 0
    var gpuMS: Double = 0
    var presentAgeMS: Double?
    var analysisDisplayDeltaMS: Double?
    var renderedFrameID: UInt64 = 0
}
