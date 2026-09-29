import ARKit

import CoreImage
import ImageIO
import SpatialCore

/// Encodes a retained AR frame on the worker task, never starts a second camera session.
/// Rotation precedes proportional downsampling; no crop, overlay, or metadata is exported.
nonisolated enum PhotoImageEncoder {
    static func jpeg(frame: FrameSnapshot) throws -> Data {
        try jpeg(pixelBuffer: frame.frame.capturedImage, orientation: frame.orientation)
    }

    static func jpeg(pixelBuffer: CVPixelBuffer, orientation imageOrientation: ImageOrientation) throws -> Data {
        let orientation: CGImagePropertyOrientation
        switch imageOrientation {
        case .portrait: orientation = .right
        case .portraitUpsideDown: orientation = .left
        case .landscapeLeft: orientation = .down
        case .landscapeRight: orientation = .up
        }
        var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let scale = min(1, 1280 / max(image.extent.width, image.extent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = context.jpegRepresentation(of: image, colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]) else {
            throw PhotoChatError.emptyInput
        }
        return data
    }
}
