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

enum PRTSARSessionState: Equatable {
    case unavailable(String)
    case idle
    case running
    case paused
    case relocalizing
}

enum PRTSARTrackingState: Equatable {
    case unavailable
    case initializing
    case limited(String)
    case normal

    init(_ state: ARCamera.TrackingState) {
        switch state {
        case .notAvailable: self = .unavailable
        case .normal: self = .normal
        case .limited(let reason): self = .limited(String(describing: reason))
        @unknown default: self = .limited("unknown")
        }
    }
}
