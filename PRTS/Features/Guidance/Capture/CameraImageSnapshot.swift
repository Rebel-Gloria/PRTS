import CoreVideo
import Foundation
import SpatialCore

/// A retained sensor image shared by ARKit and the RGB-only camera. It carries no spatial state.
nonisolated final class CameraImageSnapshot: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let orientation: ImageOrientation
    let timestamp: TimeInterval
    let receivedAt: TimeInterval
    let frameID: UInt64?

    init(
        pixelBuffer: CVPixelBuffer,
        orientation: ImageOrientation,
        timestamp: TimeInterval,
        receivedAt: TimeInterval,
        frameID: UInt64? = nil
    ) {
        self.pixelBuffer = pixelBuffer
        self.orientation = orientation
        self.timestamp = timestamp
        self.receivedAt = receivedAt
        self.frameID = frameID
    }
}
