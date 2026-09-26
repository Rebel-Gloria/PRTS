import Foundation
import ARKit
import CoreVideo
import simd

struct PRTSARFrame {
    let pixelBuffer: CVPixelBuffer
    let depthMap: CVPixelBuffer?
    let confidenceMap: CVPixelBuffer?
    let timestamp: TimeInterval
    let sequence: UInt64
    let intrinsics: simd_float3x3
    let cameraTransform: simd_float4x4
    let trackingState: ARCamera.TrackingState
    let viewportSize: CGSize
    let orientation: UIInterfaceOrientation
}

